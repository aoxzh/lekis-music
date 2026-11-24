//! 曲目查询。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{
    now_ms, ArtworkId, LekisError, ReplayGain, Result, Track, TrackId, TrackOverlay, TrackQuery,
    TrackRow, TrackSort, TrackSourceScope, TrackTagOverrides, TrackUid,
};
use rusqlite::{params, OptionalExtension, Row};

/// 一首歌对应的一个可播放文件。
#[derive(Debug, Clone, PartialEq)]
pub struct TrackFile {
    /// 所在音源。
    pub source_id: lekis_types::SourceId,
    /// 音源类型（选源时用来判断"是不是要走网络"）。
    pub source_kind: lekis_types::SourceKind,
    /// 源内路径（服务器源为空，播放时用 `external_id`）。
    pub path: String,
    /// 服务器 / 插件源里的 ID（文件系统类源为空）。
    pub external_id: Option<String>,
    /// 音质分（SRC-13，越大越好）。
    pub quality_score: i64,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// ReplayGain。
    pub replaygain: ReplayGain,
}

/// 一个可以"整体播放"的浏览上下文（列表页的数据来源）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrackContext {
    /// 全部曲目，按某个维度排序（和 `list_track_rows` 一致）。
    Library(TrackSort),
    /// A source-filtered song list in its current display order.
    SourceLibrary(TrackSourceScope, TrackSort),
    /// 一张专辑（碟号 + 曲号）。
    Album(lekis_types::AlbumId),
    /// 一位艺人参与的曲目。
    Artist(lekis_types::ArtistId),
    /// 一个流派。
    Genre(String),
    /// 一个歌单（含占位条目）。
    Playlist(lekis_types::PlaylistId),
    /// 收藏列表。
    Loved,
    /// 一个文件夹的直属曲目（按文件名，和 `folder_tracks` 一致）。
    Folder {
        /// 音源 ID。
        source_id: lekis_types::SourceId,
        /// 相对音源根目录的文件夹路径（`/` 分隔，空串 = 根目录）。
        path: String,
    },
}

pub(crate) const TRACK_ROW_COLUMNS: &str = "t.id, t.title, t.artist_line, a.title, t.duration_ms,
     COALESCE(t.artwork_id, a.artwork_id),
     t.quality_badge, COALESCE(u.loved, 0), t.overlay_json, t.tag_overrides_json,
     EXISTS(SELECT 1 FROM track_file tf JOIN source src ON src.id = tf.source_id
            WHERE tf.track_id = t.id AND src.kind = 'local')";

pub(crate) fn map_track_row(r: &Row<'_>) -> rusqlite::Result<TrackRow> {
    let overlay = r
        .get::<_, Option<String>>(8)?
        .as_deref()
        .and_then(|s| serde_json::from_str::<TrackOverlay>(s).ok());
    let tag_overrides = r
        .get::<_, Option<String>>(9)?
        .as_deref()
        .and_then(|s| serde_json::from_str::<TrackTagOverrides>(s).ok());
    let (title, artist_line, album_title) = merged_display_values(
        r.get(1)?,
        r.get(2)?,
        r.get(3)?,
        overlay.as_ref(),
        tag_overrides.as_ref(),
    );
    Ok(TrackRow {
        id: TrackId(r.get(0)?),
        title,
        artist_line,
        album_title,
        duration_ms: r.get::<_, i64>(4)?.max(0) as u64,
        artwork_id: r.get::<_, Option<i64>>(5)?.map(ArtworkId),
        quality_badge: r.get(6)?,
        loved: r.get::<_, i64>(7)? != 0,
        is_local: r.get::<_, i64>(10)? != 0,
    })
}

/// 展示时合并三层数据：文件标签（数据库里的原值）→ 补全覆盖层 → 手工标签覆盖层。
///
/// 手工标签（LIB-13）永远最后生效；远程曲目没有手工覆盖层，所以结果不变。
pub(crate) fn merged_display_values(
    base_title: String,
    base_artist_line: String,
    base_album_title: Option<String>,
    overlay: Option<&TrackOverlay>,
    tag_overrides: Option<&TrackTagOverrides>,
) -> (String, String, Option<String>) {
    let mut title = base_title;
    let mut artist_line = base_artist_line;
    let mut album_title = base_album_title;

    if let Some(overlay) = overlay {
        if let Some(value) = &overlay.title {
            title = value.clone();
        }
        if let Some(names) = &overlay.artists {
            artist_line = names.join(" / ");
        }
        if let Some(value) = &overlay.album_title {
            album_title = Some(value.clone());
        }
    }

    if let Some(tags) = tag_overrides {
        if let Some(value) = &tags.title {
            title = value.clone();
        }
        if let Some(value) = &tags.artist {
            artist_line = value.clone();
        }
        if let Some(value) = &tags.album {
            album_title = Some(value.clone());
        }
    }

    (title, artist_line, album_title)
}

pub(crate) fn split_tag_genres(genre: &str) -> Vec<String> {
    genre
        .split(';')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

fn track_order(sort: TrackSort) -> &'static str {
    match sort {
        TrackSort::Title => "t.title_sort_key, t.id",
        TrackSort::Artist => "t.artist_line, a.title, t.disc_no, t.track_no, t.id",
        TrackSort::Album => "a.title, t.disc_no, t.track_no, t.id",
        TrackSort::RecentlyAdded => "t.created_at DESC, t.id DESC",
        TrackSort::MostPlayed => "COALESCE(u.play_count, 0) DESC, t.id",
    }
}

impl Library {
    /// 分页列出曲目（列表页用）。
    pub async fn list_track_rows(&self, q: TrackQuery) -> Result<Vec<TrackRow>> {
        self.query_track_rows(q, None).await
    }

    /// List one row per track having a matching source copy.
    pub async fn list_tracks_by_source(
        &self,
        scope: TrackSourceScope,
        q: TrackQuery,
    ) -> Result<Vec<TrackRow>> {
        self.query_track_rows(q, Some(scope)).await
    }

    async fn query_track_rows(
        &self,
        q: TrackQuery,
        scope: Option<TrackSourceScope>,
    ) -> Result<Vec<TrackRow>> {
        if q.limit == 0 || q.limit > TrackQuery::MAX_LIMIT {
            return Err(LekisError::invalid(format!(
                "limit must be 1..={}",
                TrackQuery::MAX_LIMIT
            )));
        }
        let order = track_order(q.sort);
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM catalog_track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             ORDER BY {order}
             LIMIT ? OFFSET ?"
        );
        let (sql, mut args) = crate::catalog::scoped_query(scope, &sql);
        args.push(q.limit.into());
        args.push(q.offset.into());
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(args), map_track_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 取一首歌的完整信息。
    ///
    /// 艺人署名（`track_artist` 按 role/position）、流派、音频属性（取音质最高的那个文件的
    /// `file.audio_json`）都会补齐；`overlay_json` 里的用户修正（ENR / LIB-13）优先于文件标签，
    /// 目前只覆盖标题、艺人、专辑三个字段。
    pub async fn get_track(&self, id: TrackId) -> Result<Track> {
        self.read(move |c| {
            let track = c
                .query_row(
                    "SELECT t.id, t.uid, t.title, t.sort_title, t.album_id, a.title, t.track_no,
                            t.disc_no, t.year, t.duration_ms, t.mbid_recording, t.replaygain_json,
                            t.artwork_id, t.overlay_json, t.tag_overrides_json,
                            EXISTS(SELECT 1 FROM track_file tf JOIN source src ON src.id = tf.source_id
                                   WHERE tf.track_id = t.id AND src.kind = 'local')
                     FROM track t LEFT JOIN album a ON a.id = t.album_id
                     WHERE t.id = ?1",
                    params![id.0],
                    |r| {
                        let rg: Option<String> = r.get(11)?;
                        Ok((
                            Track {
                                id: TrackId(r.get(0)?),
                                uid: TrackUid(r.get(1)?),
                                title: r.get(2)?,
                                sort_title: r.get(3)?,
                                artists: Vec::new(),
                                album_id: r.get::<_, Option<i64>>(4)?.map(lekis_types::AlbumId),
                                album_title: r.get(5)?,
                                track_no: r.get(6)?,
                                disc_no: r.get(7)?,
                                year: r.get(8)?,
                                duration_ms: r.get::<_, i64>(9)?.max(0) as u64,
                                genres: Vec::new(),
                                mbid_recording: r.get(10)?,
                                audio: None,
                                replaygain: rg
                                    .and_then(|s| serde_json::from_str::<ReplayGain>(&s).ok())
                                    .unwrap_or_default(),
                                artwork_id: r.get::<_, Option<i64>>(12)?.map(ArtworkId),
                                overlay: r
                                    .get::<_, Option<String>>(13)?
                                    .and_then(|s| serde_json::from_str::<TrackOverlay>(&s).ok()),
                                is_local: r.get::<_, i64>(15)? != 0,
                            },
                            r.get::<_, Option<String>>(14)?
                                .and_then(|s| serde_json::from_str::<TrackTagOverrides>(&s).ok()),
                        ))
                    },
                )
                .optional()
                .db()?;

            let Some((mut track, tag_overrides)) = track else {
                return Err(LekisError::not_found(format!("track {id}")));
            };

            // 艺人署名。
            let mut stmt = c
                .prepare_cached(
                    "SELECT ar.id, ar.name, ta.role
                     FROM track_artist ta JOIN artist ar ON ar.id = ta.artist_id
                     WHERE ta.track_id = ?1
                     ORDER BY ta.position, ar.name",
                )
                .db()?;
            let credits = stmt
                .query_map(params![id.0], |r| {
                    let role: String = r.get(2)?;
                    Ok(lekis_types::ArtistCredit {
                        artist_id: Some(lekis_types::ArtistId(r.get(0)?)),
                        name: r.get(1)?,
                        role: lekis_types::ArtistRole::from_db(&role),
                    })
                })
                .db()?;
            track.artists = credits.collect::<rusqlite::Result<Vec<_>>>().db()?;

            // 流派。
            let mut stmt = c
                .prepare_cached(
                    "SELECT g.name FROM track_genre tg JOIN genre g ON g.id = tg.genre_id
                     WHERE tg.track_id = ?1 ORDER BY g.name",
                )
                .db()?;
            let genres = stmt
                .query_map(params![id.0], |r| r.get::<_, String>(0))
                .db()?;
            track.genres = genres.collect::<rusqlite::Result<Vec<_>>>().db()?;

            // 音频属性：取音质最高的那个文件（和选源打分一致）。
            let audio_json: Option<String> = c
                .query_row(
                    "SELECT f.audio_json FROM track_file tf JOIN file f ON f.id = tf.file_id
                     WHERE tf.track_id = ?1 AND f.audio_json IS NOT NULL
                     ORDER BY tf.quality_score DESC LIMIT 1",
                    params![id.0],
                    |r| r.get(0),
                )
                .optional()
                .db()?
                .flatten();
            track.audio = audio_json.and_then(|s| serde_json::from_str(&s).ok());

            // 专辑封面的回落：曲目没自己封面时用专辑的。
            if track.artwork_id.is_none() {
                if let Some(album_id) = track.album_id {
                    track.artwork_id = c
                        .query_row(
                            "SELECT artwork_id FROM album WHERE id = ?1",
                            params![album_id.0],
                            |r| r.get::<_, Option<i64>>(0),
                        )
                        .optional()
                        .db()?
                        .flatten()
                        .map(ArtworkId);
                }
            }

            // 覆盖层（用户修正 / 补全结果）优先于文件标签。
            if let Some(overlay) = &track.overlay {
                if let Some(title) = &overlay.title {
                    track.title = title.clone();
                }
                if let Some(album) = &overlay.album_title {
                    track.album_title = Some(album.clone());
                }
                if let Some(artists) = &overlay.artists {
                    track.artists = artists
                        .iter()
                        .map(|name| lekis_types::ArtistCredit {
                            artist_id: None,
                            name: name.clone(),
                            role: lekis_types::ArtistRole::Main,
                        })
                        .collect();
                }
                if let Some(year) = overlay.year {
                    track.year = Some(year);
                }
                if let Some(track_no) = overlay.track_no {
                    track.track_no = Some(track_no);
                }
                if let Some(disc_no) = overlay.disc_no {
                    track.disc_no = Some(disc_no);
                }
                if let Some(genres) = &overlay.genres {
                    track.genres = genres.clone();
                }
            }

            // 手工标签覆盖层（LIB-13）最后生效，优先级高于补全结果。
            if let Some(tags) = tag_overrides {
                if let Some(title) = tags.title {
                    track.title = title;
                }
                if let Some(artist) = tags.artist {
                    track.artists = vec![lekis_types::ArtistCredit {
                        artist_id: None,
                        name: artist,
                        role: lekis_types::ArtistRole::Main,
                    }];
                }
                if let Some(album) = tags.album {
                    track.album_title = Some(album);
                }
                if let Some(year) = tags.year {
                    track.year = Some(year);
                }
                if let Some(track_no) = tags.track_no {
                    track.track_no = Some(track_no);
                }
                if let Some(disc_no) = tags.disc_no {
                    track.disc_no = Some(disc_no);
                }
                if let Some(genre) = tags.genre {
                    track.genres = split_tag_genres(&genre);
                }
                if let Some(mbid) = tags.musicbrainz_track_id {
                    track.mbid_recording = Some(mbid);
                }
            }

            Ok(track)
        })
        .await
    }

    /// 列出一首歌所有可用的文件（按质量从高到低），播放时由 lekis-core 选源。
    pub async fn track_files(&self, id: TrackId) -> Result<Vec<TrackFile>> {
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT tf.source_id, s.kind, COALESCE(f.path, ''), NULLIF(tf.external_id, ''),
                            tf.quality_score, t.duration_ms, t.replaygain_json
                     FROM track_file tf
                     JOIN track t ON t.id = tf.track_id
                     JOIN source s ON s.id = tf.source_id
                     LEFT JOIN file f ON f.id = tf.file_id
                     WHERE tf.track_id = ?1
                     ORDER BY tf.quality_score DESC",
                )
                .db()?;
            let rows = stmt
                .query_map(params![id.0], |r| {
                    let rg: Option<String> = r.get(6)?;
                    let kind: String = r.get(1)?;
                    Ok(TrackFile {
                        source_id: lekis_types::SourceId(r.get(0)?),
                        source_kind: serde_json::from_value(serde_json::Value::String(kind))
                            .unwrap_or(lekis_types::SourceKind::Local),
                        path: r.get(2)?,
                        external_id: r.get(3)?,
                        quality_score: r.get::<_, i64>(4)?,
                        duration_ms: r.get::<_, i64>(5)?.max(0) as u64,
                        replaygain: rg
                            .and_then(|s| serde_json::from_str::<ReplayGain>(&s).ok())
                            .unwrap_or_default(),
                    })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 曲目总数。
    pub async fn track_count(&self) -> Result<u64> {
        self.read(|c| {
            c.query_row(
                &crate::catalog::query("SELECT COUNT(*) FROM catalog_track"),
                [],
                |r| r.get::<_, i64>(0),
            )
            .db()
            .map(|n| n as u64)
        })
        .await
    }

    /// 单首曲目的列表行（播放队列页用）。
    pub async fn track_row(&self, id: TrackId) -> Result<TrackRow> {
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE t.id = ?1"
        );
        self.read(move |c| {
            c.query_row(&sql, params![id.0], map_track_row)
                .optional()
                .db()?
                .ok_or_else(|| LekisError::not_found(format!("track {id}")))
        })
        .await
    }

    /// 专辑总数（滚动条用）。
    pub async fn album_count(&self) -> Result<u64> {
        self.count(
            &crate::catalog::query("SELECT COUNT(*) FROM catalog_album"),
            None,
        )
        .await
    }

    /// 艺人总数（滚动条用）。
    pub async fn artist_count(&self) -> Result<u64> {
        self.count(
            &crate::catalog::query("SELECT COUNT(*) FROM catalog_artist"),
            None,
        )
        .await
    }

    /// 某个流派的曲目数。
    pub async fn genre_track_count(&self, name: &str) -> Result<u64> {
        self.count(
            &crate::catalog::query(
                "SELECT COUNT(*) FROM track_genre tg JOIN genre g ON g.id = tg.genre_id
              JOIN catalog_track t ON t.id = tg.track_id WHERE g.name = ?1",
            ),
            Some(name.to_string()),
        )
        .await
    }

    /// 收藏的曲目数。
    pub async fn loved_count(&self) -> Result<u64> {
        self.count(
            &crate::catalog::query(
                "SELECT COUNT(*) FROM user_state u JOIN catalog_track t ON t.uid = u.track_uid
              WHERE u.loved = 1",
            ),
            None,
        )
        .await
    }

    async fn count(&self, sql: &str, arg: Option<String>) -> Result<u64> {
        let sql = sql.to_owned();
        self.read(move |c| {
            let n: i64 = match arg {
                Some(a) => c.query_row(&sql, params![a], |r| r.get(0)),
                None => c.query_row(&sql, [], |r| r.get(0)),
            }
            .db()?;
            Ok(n.max(0) as u64)
        })
        .await
    }

    /// 最近播放过的曲目（首页"继续收听"），按最后播放时间倒序。
    pub async fn recently_played(&self, limit: u32) -> Result<Vec<TrackRow>> {
        if limit == 0 || limit > TrackQuery::MAX_LIMIT {
            return Err(LekisError::invalid(format!(
                "limit must be 1..={}",
                TrackQuery::MAX_LIMIT
            )));
        }
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM catalog_track t
             JOIN user_state u ON u.track_uid = t.uid
             LEFT JOIN album a ON a.id = t.album_id
             WHERE u.last_played IS NOT NULL
             ORDER BY u.last_played DESC, t.id
             LIMIT ?1"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt.query_map(params![limit], map_track_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 一个浏览上下文里的全部曲目 ID，顺序和对应列表页一致（"从这里开始播放整个列表"用）。
    ///
    /// 歌单里的占位条目（曲目暂时不可用，PL-05）用 `None` 表示，这样调用方能把 UI 的行号
    /// 换算成真正的队列下标。
    pub async fn context_track_ids(&self, context: TrackContext) -> Result<Vec<Option<TrackId>>> {
        const PAGE: u32 = TrackQuery::MAX_LIMIT;
        /// 防御：一个队列最多这么多首（超大资料库也不会把内存吃光）。
        const CAP: usize = 100_000;
        // 智能歌单的条目不在 playlist_item 里，必须走规则求值；普通歌单仍然读条目表。
        let playlist_is_smart = match &context {
            TrackContext::Playlist(id) => {
                self.get_playlist(*id).await?.kind == crate::playlists::PlaylistKind::Smart
            }
            _ => false,
        };
        let mut out: Vec<Option<TrackId>> = Vec::new();
        let mut offset = 0u32;
        loop {
            let page: Vec<Option<TrackId>> = match &context {
                TrackContext::SourceLibrary(scope, sort) => {
                    let select = format!(
                        "SELECT t.id FROM catalog_track t
                        LEFT JOIN album a ON a.id = t.album_id
                        LEFT JOIN user_state u ON u.track_uid = t.uid
                        ORDER BY {} LIMIT {CAP}",
                        track_order(*sort)
                    );
                    let (sql, args) = crate::catalog::scoped_query(Some(scope.clone()), &select);
                    return self
                        .read(move |connection| {
                            let mut statement = connection.prepare_cached(&sql).db()?;
                            let rows = statement
                                .query_map(rusqlite::params_from_iter(args), |row| {
                                    Ok(Some(TrackId(row.get(0)?)))
                                })
                                .db()?;
                            rows.collect::<rusqlite::Result<Vec<_>>>().db()
                        })
                        .await;
                }
                TrackContext::Library(sort) => self
                    .list_track_rows(TrackQuery {
                        sort: *sort,
                        offset,
                        limit: PAGE,
                    })
                    .await?
                    .into_iter()
                    .map(|r| Some(r.id))
                    .collect(),
                TrackContext::Album(id) => self
                    .album_tracks(*id, offset, PAGE)
                    .await?
                    .into_iter()
                    .map(|r| Some(r.id))
                    .collect(),
                TrackContext::Artist(id) => self
                    .artist_tracks(*id, offset, PAGE)
                    .await?
                    .into_iter()
                    .map(|r| Some(r.id))
                    .collect(),
                TrackContext::Genre(name) => self
                    .genre_tracks(name, offset, PAGE)
                    .await?
                    .into_iter()
                    .map(|r| Some(r.id))
                    .collect(),
                TrackContext::Loved => self
                    .list_loved(offset, PAGE)
                    .await?
                    .into_iter()
                    .map(|r| Some(r.id))
                    .collect(),
                TrackContext::Playlist(id) => {
                    if playlist_is_smart {
                        self.smart_playlist_tracks(*id, offset, PAGE)
                            .await?
                            .into_iter()
                            .map(|r| Some(r.id))
                            .collect()
                    } else {
                        self.playlist_items(*id, offset, PAGE)
                            .await?
                            .into_iter()
                            .map(|e| e.track.map(|t| t.id))
                            .collect()
                    }
                }
                TrackContext::Folder { source_id, path } => self
                    .folder_track_ids(*source_id, path, offset, PAGE)
                    .await?
                    .into_iter()
                    .map(Some)
                    .collect(),
            };
            let got = page.len() as u32;
            out.extend(page);
            if got < PAGE || out.len() >= CAP {
                break;
            }
            offset += got;
        }
        out.truncate(CAP);
        Ok(out)
    }

    /// 设置收藏状态。
    ///
    /// 同步操作由 `lekis-core` 负责写进 `sync_outbox`（见 `lekis-core/src/sync_engine.rs`）。
    pub async fn set_loved(&self, uid: TrackUid, loved: bool) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "INSERT INTO user_state (track_uid, loved) VALUES (?1, ?2)
                 ON CONFLICT (track_uid) DO UPDATE SET loved = excluded.loved",
                params![uid.0, loved as i64],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 设置评分（1~5，0 表示清除）。
    pub async fn set_rating(&self, uid: TrackUid, rating: i64) -> Result<()> {
        let rating = rating.clamp(0, 5);
        self.write(move |c| {
            c.execute(
                "INSERT INTO user_state (track_uid, rating) VALUES (?1, NULLIF(?2, 0))
                 ON CONFLICT (track_uid) DO UPDATE SET rating = excluded.rating",
                params![uid.0, rating],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 读取某首歌的用户状态（收藏、评分、播放次数）。
    pub async fn user_state(&self, uid: TrackUid) -> Result<TrackUserState> {
        self.read(move |c| {
            let row: Option<TrackUserState> = c
                .query_row(
                    "SELECT loved, rating, play_count, updated_hlc FROM user_state WHERE track_uid = ?1",
                    params![uid.0],
                    |r| {
                        Ok(TrackUserState {
                            loved: r.get::<_, i64>(0)? != 0,
                            rating: r.get::<_, Option<i64>>(1)?,
                            play_count: r.get::<_, i64>(2)?,
                            updated_hlc: r.get(3)?,
                        })
                    },
                )
                .optional()
                .db()?;
            Ok(row.unwrap_or_default())
        })
        .await
    }

    /// 写入（或清除）曲目覆盖层（LIB-13 / ENR）。
    ///
    /// 覆盖层只改库里的显示与排序，**不动原始文件**；传 `None` 或空覆盖层等于清除。
    /// 写过覆盖层之后 `get_track` 的标题 / 艺人 / 专辑会是覆盖后的值。
    pub async fn set_track_overlay(
        &self,
        id: TrackId,
        overlay: Option<lekis_types::TrackOverlay>,
    ) -> Result<()> {
        let json = match &overlay {
            Some(o) if !o.is_empty() => Some(
                serde_json::to_string(o)
                    .map_err(|e| LekisError::internal(format!("serialize overlay: {e}")))?,
            ),
            _ => None,
        };
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            // 曲目必须存在（否则 UPDATE 会静默成功但什么都没改）。
            let exists: Option<i64> = tx
                .query_row("SELECT id FROM track WHERE id = ?1", params![id.0], |r| {
                    r.get(0)
                })
                .optional()
                .db()?;
            if exists.is_none() {
                return Err(LekisError::not_found(format!("track {id}")));
            }
            tx.execute(
                "UPDATE track SET overlay_json = ?2, updated_at = ?3 WHERE id = ?1",
                params![id.0, json, now_ms()],
            )
            .db()?;
            // 覆盖层可能改了标题 / 艺人，搜索索引要跟着重建。
            crate::browse::refresh_track_index(&tx, id.0)?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }

    /// 记一次播放（DIS-06 播放统计）：写 `play_event`、累加 `user_state.play_count`。
    ///
    /// `ms_played` 是真实播放时长（用于 scrobble 判定：超过一半或 4 分钟才算一次）。
    pub async fn record_play(
        &self,
        uid: TrackUid,
        device_id: String,
        ms_played: u64,
        at_ms: i64,
    ) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "INSERT INTO play_event (track_uid, device_id, started_at, played_ms)
                 VALUES (?1, ?2, ?3, ?4)",
                params![uid.0, device_id, at_ms, ms_played as i64],
            )
            .db()?;
            c.execute(
                "INSERT INTO user_state (track_uid, play_count, last_played)
                 VALUES (?1, 1, ?2)
                 ON CONFLICT (track_uid) DO UPDATE SET
                   play_count = user_state.play_count + 1,
                   last_played = excluded.last_played",
                params![uid.0, at_ms],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 播放次数最多的曲目（DIS-06）。
    pub async fn most_played(&self, limit: u32) -> Result<Vec<TrackRow>> {
        if limit == 0 || limit > TrackQuery::MAX_LIMIT {
            return Err(LekisError::invalid(format!(
                "limit must be 1..={}",
                TrackQuery::MAX_LIMIT
            )));
        }
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM catalog_track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE COALESCE(u.play_count, 0) > 0
             ORDER BY u.play_count DESC, u.last_played DESC
             LIMIT ?1"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt.query_map(params![limit], map_track_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 收藏的曲目（PL-02，`getStarred2` 用）。
    pub async fn list_loved(&self, offset: u32, limit: u32) -> Result<Vec<TrackRow>> {
        if limit == 0 || limit > TrackQuery::MAX_LIMIT {
            return Err(LekisError::invalid(format!(
                "limit must be 1..={}",
                TrackQuery::MAX_LIMIT
            )));
        }
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM catalog_track t
             JOIN user_state u ON u.track_uid = t.uid
             LEFT JOIN album a ON a.id = t.album_id
             WHERE u.loved = 1
             ORDER BY t.title_sort_key, t.id
             LIMIT ?1 OFFSET ?2"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt.query_map(params![limit, offset], map_track_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }
}

/// 一首歌的用户状态（跨设备同步的部分）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TrackUserState {
    /// 是否收藏。
    pub loved: bool,
    /// 评分 1~5。
    pub rating: Option<i64>,
    /// 播放次数。
    pub play_count: i64,
    /// 最后一次修改的 HLC（同步合并用）。
    pub updated_hlc: Option<String>,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{ScannedFile, ScannedTags};
    use lekis_types::{
        AudioProps, Codec, SourceConfig, SourceId, SourceKind, TrackOverlay, TrackSort,
    };
    use std::collections::BTreeMap;

    async fn source(lib: &Library) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind: SourceKind::Local,
            name: "local".into(),
            addresses: vec![],
            root_path: "/music".into(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    async fn seed(lib: &Library, source: SourceId, path: &str, title: &str) -> Result<TrackId> {
        lib.upsert_scanned(vec![ScannedFile {
            source_id: source,
            path: path.into(),
            size: 1,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec!["周杰伦".into(), "费玉清".into()],
                album: Some("叶惠美".into()),
                genres: vec!["华语流行".into()],
                duration_ms: 2000,
                replaygain: lekis_types::ReplayGain {
                    track_gain_db: Some(-3.5),
                    ..Default::default()
                },
                audio: Some(AudioProps {
                    codec: Codec::Flac,
                    sample_rate: 96_000,
                    bit_depth: Some(24),
                    channels: 2,
                    bitrate_kbps: Some(2000),
                }),
                ..Default::default()
            },
        }])
        .await?;
        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 50,
            })
            .await?;
        rows.iter()
            .find(|r| r.title == title)
            .map(|r| r.id)
            .ok_or_else(|| LekisError::internal(format!("track {title} not found after scan")))
    }

    #[tokio::test]
    async fn get_track_fills_credits_genres_and_audio() -> Result<()> {
        let lib = temp_library("tracks-detail")?;
        let src = source(&lib).await?;
        let id = seed(&lib, src, "a.flac", "晴天").await?;

        let t = lib.get_track(id).await?;
        assert_eq!(
            t.artists
                .iter()
                .map(|a| a.name.as_str())
                .collect::<Vec<_>>(),
            vec!["周杰伦", "费玉清"]
        );
        assert_eq!(t.artists[0].role, lekis_types::ArtistRole::Main);
        assert!(t.artists[0].artist_id.is_some());
        assert_eq!(t.genres, vec!["华语流行".to_string()]);
        let audio = t.audio.expect("音频属性要补上");
        assert_eq!(audio.codec, Codec::Flac);
        assert_eq!(audio.bit_depth, Some(24));
        assert_eq!(t.replaygain.track_gain_db, Some(-3.5));
        assert!(t.overlay.is_none());

        assert_eq!(
            lib.get_track(TrackId(9_999)).await.unwrap_err().code,
            lekis_types::ErrorCode::NotFound
        );
        Ok(())
    }

    #[tokio::test]
    async fn overlay_wins_and_rebuilds_search_index() -> Result<()> {
        let lib = temp_library("tracks-overlay")?;
        let src = source(&lib).await?;
        let id = seed(&lib, src, "a.flac", "晴天").await?;

        lib.set_track_overlay(
            id,
            Some(TrackOverlay {
                title: Some("Qing Tian (Live)".into()),
                artists: Some(vec!["Jay Chou".into()]),
                source: Some("manual".into()),
                ..Default::default()
            }),
        )
        .await?;

        let t = lib.get_track(id).await?;
        assert_eq!(t.title, "Qing Tian (Live)");
        assert_eq!(t.artists.len(), 1);
        assert_eq!(t.artists[0].name, "Jay Chou");
        assert!(t.artists[0].artist_id.is_none(), "覆盖出来的艺人不绑 ID");
        assert_eq!(
            t.overlay.as_ref().and_then(|o| o.source.as_deref()),
            Some("manual")
        );

        // 覆盖层进了搜索索引。
        let found = lib.search("Qing Tian", 10).await?;
        assert_eq!(found.tracks.len(), 1);
        assert_eq!(found.tracks[0].id, id);
        assert!(
            lib.search("晴天", 10).await?.tracks.is_empty(),
            "旧标题不再命中"
        );

        // 空覆盖层等于清除。
        lib.set_track_overlay(id, Some(TrackOverlay::default()))
            .await?;
        assert_eq!(lib.get_track(id).await?.title, "晴天");
        assert!(lib.search("晴天", 10).await?.tracks.len() == 1);

        assert_eq!(
            lib.set_track_overlay(TrackId(9_999), None)
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::NotFound
        );
        Ok(())
    }

    #[tokio::test]
    async fn play_stats_and_loved_lists() -> Result<()> {
        let lib = temp_library("tracks-stats")?;
        let src = source(&lib).await?;
        let a = seed(&lib, src, "a.flac", "晴天").await?;
        let b = seed(&lib, src, "b.flac", "以父之名").await?;
        let ua = lib.get_track(a).await?.uid;
        let ub = lib.get_track(b).await?.uid;

        lib.record_play(ua.clone(), "dev-a".into(), 180_000, 1_000)
            .await?;
        lib.record_play(ua.clone(), "dev-a".into(), 180_000, 2_000)
            .await?;
        lib.record_play(ub.clone(), "dev-b".into(), 60_000, 3_000)
            .await?;

        assert_eq!(lib.user_state(ua.clone()).await?.play_count, 2);
        let top = lib.most_played(10).await?;
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].id, a, "播放次数多的排前面");

        lib.set_loved(ua.clone(), true).await?;
        lib.set_loved(ub.clone(), true).await?;
        lib.set_loved(ub.clone(), false).await?;
        let loved = lib.list_loved(0, 10).await?;
        assert_eq!(loved.len(), 1);
        assert_eq!(loved[0].id, a);
        assert!(loved[0].loved);

        assert_eq!(
            lib.most_played(0).await.unwrap_err().code,
            lekis_types::ErrorCode::InvalidArgument
        );
        Ok(())
    }
}
