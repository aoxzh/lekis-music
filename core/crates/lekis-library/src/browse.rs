//! 浏览维度（LIB-06）：专辑、艺人、流派。
//!
//! 曲目列表在 `tracks.rs`，这里补上"换一个维度看同一批数据"的部分。
//! 所有列表查询都必须分页（`docs/ARCHITECTURE.md`），所以每个方法都收 `offset` / `limit`。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{
    Album, AlbumId, Artist, ArtistId, ArtworkId, GenreCount, LekisError, Result, TrackQuery,
    TrackRow, TrackSort,
};
use rusqlite::{params, OptionalExtension, Row};

/// 字母 / 拼音索引条里一个首字母对应的起始行号（UIX-05）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LetterOffset {
    /// 大写英文字母 `'A'..='Z'` 或非字母归类 `'#'`。
    pub letter: String,
    /// 该字母第一条记录在有序列表里的 0-based 行号。
    pub offset: u32,
}

fn bucket_letter(sort_key: &str) -> char {
    match sort_key.trim().chars().next() {
        Some(c) if c.is_ascii_alphabetic() => c.to_ascii_uppercase(),
        _ => '#',
    }
}

fn collect_letter_offsets(keys: impl Iterator<Item = String>) -> Vec<LetterOffset> {
    let mut out: Vec<LetterOffset> = Vec::with_capacity(27);
    let mut seen: [bool; 27] = [false; 27];
    for (idx, key) in keys.enumerate() {
        let ch = bucket_letter(&key);
        let slot = if ch.is_ascii_uppercase() {
            (ch as u8 - b'A') as usize
        } else {
            26
        };
        if !seen[slot] {
            seen[slot] = true;
            out.push(LetterOffset {
                letter: ch.to_string(),
                offset: idx as u32,
            });
        }
    }
    out
}

/// 分页上限，和 `TrackQuery::MAX_LIMIT` 保持一致。
const MAX_LIMIT: u32 = TrackQuery::MAX_LIMIT;

fn check_limit(limit: u32) -> Result<()> {
    if limit == 0 || limit > MAX_LIMIT {
        return Err(LekisError::invalid(format!(
            "limit must be 1..={MAX_LIMIT}"
        )));
    }
    Ok(())
}

pub(crate) fn map_album_row(r: &Row<'_>) -> rusqlite::Result<Album> {
    Ok(Album {
        id: AlbumId(r.get(0)?),
        title: r.get(1)?,
        artist_line: r.get(2)?,
        year: r.get(3)?,
        track_count: r.get::<_, i64>(4)?.max(0) as u32,
        artwork_id: r.get::<_, Option<i64>>(5)?.map(ArtworkId),
        mbid_release: r.get(6)?,
        artwork_hash: r.get(7)?,
    })
}

pub(crate) fn map_artist_row(r: &Row<'_>) -> rusqlite::Result<Artist> {
    let aliases: Option<String> = r.get(3)?;
    Ok(Artist {
        id: ArtistId(r.get(0)?),
        name: r.get(1)?,
        sort_name: r.get(2)?,
        aliases: aliases
            .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
            .unwrap_or_default(),
        artwork_id: r.get::<_, Option<i64>>(4)?.map(ArtworkId),
        mbid: r.get(5)?,
    })
}

/// 专辑列表的列（`track_count` 是实时统计出来的曲目数）。
const ALBUM_COLUMNS: &str = "a.id, a.title, a.artist_line, a.year,
     (SELECT COUNT(*) FROM catalog_track t WHERE t.album_id = a.id), a.artwork_id, a.mbid_release,
     (SELECT ar.hash FROM artwork ar WHERE ar.id = COALESCE(a.artwork_id,
        (SELECT t2.artwork_id FROM catalog_track t2
          WHERE t2.album_id = a.id AND t2.artwork_id IS NOT NULL
          ORDER BY t2.disc_no, t2.track_no LIMIT 1)))";

impl Library {
    /// 按维度列出专辑。
    ///
    /// 支持 `Title`（专辑名）、`Artist`（专辑艺人）、`RecentlyAdded`（入库时间）、
    /// `MostPlayed`（曲目播放次数之和）。
    pub async fn list_albums(
        &self,
        sort: TrackSort,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<Album>> {
        check_limit(limit)?;
        let order = match sort {
            TrackSort::Title => "a.sort_title, a.id",
            TrackSort::Artist => "a.artist_norm, a.sort_title, a.id",
            TrackSort::RecentlyAdded => "a.created_at DESC, a.id DESC",
            TrackSort::MostPlayed => {
                "(SELECT COALESCE(SUM(u.play_count), 0) FROM catalog_track t
                    LEFT JOIN user_state u ON u.track_uid = t.uid
                   WHERE t.album_id = a.id) DESC, a.sort_title"
            }
            TrackSort::Album => "a.sort_title, a.id",
        };
        let sql = format!(
            "SELECT {ALBUM_COLUMNS} FROM catalog_album a ORDER BY {order} LIMIT ?1 OFFSET ?2"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt.query_map(params![limit, offset], map_album_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 专辑详情。
    pub async fn get_album(&self, id: AlbumId) -> Result<Album> {
        let sql = crate::catalog::query(format!(
            "SELECT {ALBUM_COLUMNS} FROM album a WHERE a.id = ?1"
        ));
        self.read(move |c| {
            c.query_row(&sql, params![id.0], map_album_row)
                .optional()
                .db()?
                .ok_or_else(|| LekisError::not_found(format!("album {id}")))
        })
        .await
    }

    /// 专辑里的曲目（按碟号 + 曲号排序，这是专辑页的正确顺序）。
    pub async fn album_tracks(
        &self,
        id: AlbumId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        check_limit(limit)?;
        let sql = format!(
            "SELECT {}
             FROM catalog_track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE t.album_id = ?1
             ORDER BY t.disc_no, t.track_no, t.title_sort_key
             LIMIT ?2 OFFSET ?3",
            crate::tracks::TRACK_ROW_COLUMNS
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt
                .query_map(params![id.0, limit, offset], crate::tracks::map_track_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 专辑的艺人署名。
    pub async fn album_artists(&self, id: AlbumId) -> Result<Vec<Artist>> {
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT ar.id, ar.name, ar.sort_name, ar.aliases_json, ar.artwork_id, ar.mbid
                     FROM album_artist aa JOIN artist ar ON ar.id = aa.artist_id
                     WHERE aa.album_id = ?1
                     ORDER BY aa.position",
                )
                .db()?;
            let rows = stmt
                .query_map(params![id.0], map_artist_row)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            Ok(rows)
        })
        .await
    }

    /// 按名字顺序列出艺人。
    pub async fn list_artists(&self, offset: u32, limit: u32) -> Result<Vec<Artist>> {
        check_limit(limit)?;
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(&crate::catalog::query(
                    "SELECT id, name, sort_name, aliases_json, artwork_id, mbid
                     FROM catalog_artist
                     ORDER BY COALESCE(sort_name, name), id
                     LIMIT ?1 OFFSET ?2",
                ))
                .db()?;
            let rows = stmt
                .query_map(params![limit, offset], map_artist_row)
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            Ok(rows)
        })
        .await
    }

    /// 按标题排序时，歌曲列表每个首字母（`#` / `A`–`Z`）的起始行号（UIX-05）。
    ///
    /// 走 `idx_track_sort` 覆盖索引，10 万首歌也只需几毫秒。
    pub async fn track_title_index_offsets(&self) -> Result<Vec<LetterOffset>> {
        self.read(|c| {
            let mut stmt = c
                .prepare_cached(&crate::catalog::query(
                    "SELECT title_sort_key FROM catalog_track ORDER BY title_sort_key, id",
                ))
                .db()?;
            let rows = stmt
                .query_map([], |r| r.get::<_, String>(0))
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            Ok(collect_letter_offsets(rows.into_iter()))
        })
        .await
    }

    /// 艺人列表每个首字母（`#` / `A`–`Z`）的起始行号（UIX-05）。
    pub async fn artist_index_offsets(&self) -> Result<Vec<LetterOffset>> {
        self.read(|c| {
            let mut stmt = c
                .prepare_cached(
                    &crate::catalog::query("SELECT COALESCE(sort_name, name) FROM catalog_artist ORDER BY COALESCE(sort_name, name), id"),
                )
                .db()?;
            let rows = stmt
                .query_map([], |r| r.get::<_, String>(0))
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            Ok(collect_letter_offsets(rows.into_iter()))
        })
        .await
    }

    /// 艺人详情。
    pub async fn get_artist(&self, id: ArtistId) -> Result<Artist> {
        self.read(move |c| {
            c.query_row(
                "SELECT id, name, sort_name, aliases_json, artwork_id, mbid FROM artist WHERE id = ?1",
                params![id.0],
                map_artist_row,
            )
            .optional()
            .db()?
            .ok_or_else(|| LekisError::not_found(format!("artist {id}")))
        })
        .await
    }

    /// 艺人参与的曲目（含合作 / feat.）。
    pub async fn artist_tracks(
        &self,
        id: ArtistId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        check_limit(limit)?;
        let sql = format!(
            "SELECT {}
             FROM catalog_track t
             JOIN track_artist ta ON ta.track_id = t.id
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE ta.artist_id = ?1
             GROUP BY t.id
             ORDER BY a.sort_title, t.disc_no, t.track_no
             LIMIT ?2 OFFSET ?3",
            crate::tracks::TRACK_ROW_COLUMNS
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt
                .query_map(params![id.0, limit, offset], crate::tracks::map_track_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 艺人的专辑（去重，按年份倒序）。
    pub async fn artist_albums(&self, id: ArtistId, offset: u32, limit: u32) -> Result<Vec<Album>> {
        check_limit(limit)?;
        let sql = format!(
            "SELECT {ALBUM_COLUMNS}
             FROM catalog_album a
             WHERE EXISTS (SELECT 1 FROM album_artist aa WHERE aa.album_id = a.id AND aa.artist_id = ?1)
                OR EXISTS (SELECT 1 FROM catalog_track t JOIN track_artist ta ON ta.track_id = t.id
                           WHERE t.album_id = a.id AND ta.artist_id = ?1)
             ORDER BY COALESCE(a.year, 0) DESC, a.sort_title
             LIMIT ?2 OFFSET ?3"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt
                .query_map(params![id.0, limit, offset], map_album_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 流派及其曲目数（按曲目数倒序）。
    pub async fn list_genres(&self, limit: u32) -> Result<Vec<GenreCount>> {
        check_limit(limit)?;
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(&crate::catalog::query(
                    "SELECT g.name, COUNT(tg.track_id)
                     FROM genre g JOIN track_genre tg ON tg.genre_id = g.id
                     JOIN catalog_track t ON t.id = tg.track_id
                     GROUP BY g.id
                     ORDER BY COUNT(tg.track_id) DESC, g.name
                     LIMIT ?1",
                ))
                .db()?;
            let rows = stmt
                .query_map(params![limit], |r| {
                    Ok(GenreCount {
                        name: r.get(0)?,
                        track_count: r.get::<_, i64>(1)?.max(0) as u32,
                    })
                })
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;
            Ok(rows)
        })
        .await
    }

    /// 某个流派的曲目。
    pub async fn genre_tracks(&self, name: &str, offset: u32, limit: u32) -> Result<Vec<TrackRow>> {
        check_limit(limit)?;
        let name = name.to_string();
        let sql = format!(
            "SELECT {}
             FROM catalog_track t
             JOIN track_genre tg ON tg.track_id = t.id
             JOIN genre g ON g.id = tg.genre_id
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             WHERE g.name = ?1
             ORDER BY t.title_sort_key, t.id
             LIMIT ?2 OFFSET ?3",
            crate::tracks::TRACK_ROW_COLUMNS
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&crate::catalog::query(&sql)).db()?;
            let rows = stmt
                .query_map(params![name, limit, offset], crate::tracks::map_track_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 最近添加的曲目（`RecentlyAdded` 的便捷封装，首页用）。
    pub async fn recently_added(&self, limit: u32) -> Result<Vec<TrackRow>> {
        self.list_track_rows(TrackQuery {
            sort: TrackSort::RecentlyAdded,
            offset: 0,
            limit,
        })
        .await
    }
}

// ---------------------------------------------------------------------------
// 搜索索引行的写入（LIB-07）
// ---------------------------------------------------------------------------
//
// `search_index` 是 fts5 虚表，`kind` / `ref_id` 两列是 UNINDEXED：按它们 `WHERE` 会全表扫描，
// 逐首入库时就成了 O(n²)。所以每一行都用**确定的 rowid**（`ref_id * 4 + 类型码`）写入，
// 删除 / 判断存在都按 rowid 走 fts5 的主键（迁移 0004 把老数据换成了这种 rowid）。

/// 曲目行的类型码。
pub(crate) const INDEX_TRACK: i64 = 1;
/// 专辑行的类型码。
pub(crate) const INDEX_ALBUM: i64 = 2;
/// 艺人行的类型码。
pub(crate) const INDEX_ARTIST: i64 = 3;

/// 一个实体在 `search_index` 里的 rowid。
pub(crate) fn index_rowid(kind: i64, ref_id: i64) -> i64 {
    ref_id * 4 + kind
}

fn kind_name(kind: i64) -> &'static str {
    match kind {
        INDEX_TRACK => "track",
        INDEX_ALBUM => "album",
        _ => "artist",
    }
}

/// 这个实体在索引里有没有行。
fn index_row_exists(tx: &rusqlite::Transaction<'_>, kind: i64, ref_id: i64) -> Result<bool> {
    let hit: Option<i64> = tx
        .query_row(
            "SELECT rowid FROM search_index WHERE rowid = ?1",
            params![index_rowid(kind, ref_id)],
            |r| r.get(0),
        )
        .optional()
        .db()?;
    Ok(hit.is_some())
}

/// 删掉一个实体的索引行（按 rowid，不扫表）。
pub(crate) fn delete_index_row(
    tx: &rusqlite::Transaction<'_>,
    kind: i64,
    ref_id: i64,
) -> Result<()> {
    tx.execute(
        "DELETE FROM search_index WHERE rowid = ?1",
        params![index_rowid(kind, ref_id)],
    )
    .db()?;
    Ok(())
}

/// 写一个实体的索引行。`replace = false` 表示调用方确定这行还不存在（新建的实体），跳过删除。
pub(crate) fn write_index_row(
    tx: &rusqlite::Transaction<'_>,
    kind: i64,
    ref_id: i64,
    title: &str,
    subtitle: &str,
    keys: &str,
    replace: bool,
) -> Result<()> {
    if replace {
        delete_index_row(tx, kind, ref_id)?;
    }
    tx.execute(
        "INSERT INTO search_index (rowid, kind, ref_id, title, subtitle, keys)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            index_rowid(kind, ref_id),
            kind_name(kind),
            ref_id,
            title,
            subtitle,
            keys
        ],
    )
    .db()?;
    Ok(())
}

/// 搜索索引里需要合并的曲目字段。
type TrackIndexRow = (
    String,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
);

/// 重建曲目的搜索索引行。
///
/// 用户改了覆盖层（标题 / 艺人）之后要调一次，否则搜索结果还是旧标题。
pub(crate) fn refresh_track_index(tx: &rusqlite::Transaction<'_>, track_id: i64) -> Result<()> {
    delete_index_row(tx, INDEX_TRACK, track_id)?;
    let row: Option<TrackIndexRow> = tx
        .query_row(
            "SELECT t.title, t.artist_line, a.title, t.overlay_json, t.tag_overrides_json
             FROM track t LEFT JOIN album a ON a.id = t.album_id WHERE t.id = ?1",
            params![track_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()
        .db()?;
    let Some((title, artist_line, album_title, overlay_json, tag_overrides_json)) = row else {
        return Ok(());
    };
    let overlay = overlay_json
        .as_deref()
        .and_then(|s| serde_json::from_str::<lekis_types::TrackOverlay>(s).ok());
    let tag_overrides = tag_overrides_json
        .as_deref()
        .and_then(|s| serde_json::from_str::<lekis_types::TrackTagOverrides>(s).ok());

    // 覆盖层优先：搜索到的应该是用户看到的标题。
    let (title, artist_line, album_title) = crate::tracks::merged_display_values(
        title,
        artist_line,
        album_title,
        overlay.as_ref(),
        tag_overrides.as_ref(),
    );

    let keys = crate::normalize::search_keys(&[
        &title,
        &artist_line,
        album_title.as_deref().unwrap_or(""),
    ]);
    write_index_row(
        tx,
        INDEX_TRACK,
        track_id,
        &title,
        &artist_line,
        &keys,
        false,
    )
}

/// 重建专辑的搜索索引行（专辑改名 / 合并之后调用）。
#[allow(dead_code)] // 元数据编辑接上 UI 后使用；现在只有扫描路径会重建索引。
pub(crate) fn refresh_album_index(
    tx: &rusqlite::Transaction<'_>,
    album_id: Option<i64>,
) -> Result<()> {
    let Some(album_id) = album_id else {
        return Ok(());
    };
    delete_index_row(tx, INDEX_ALBUM, album_id)?;
    write_album_row(tx, album_id)
}

/// 入库路径用：专辑的索引行只依赖标题和艺人（入库时不会改），已经有了就什么都不做。
pub(crate) fn ensure_album_index(
    tx: &rusqlite::Transaction<'_>,
    album_id: Option<i64>,
) -> Result<()> {
    let Some(album_id) = album_id else {
        return Ok(());
    };
    if index_row_exists(tx, INDEX_ALBUM, album_id)? {
        return Ok(());
    }
    write_album_row(tx, album_id)
}

fn write_album_row(tx: &rusqlite::Transaction<'_>, album_id: i64) -> Result<()> {
    let row: Option<(String, String)> = tx
        .query_row(
            "SELECT title, artist_line FROM album WHERE id = ?1",
            params![album_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .db()?;
    let Some((title, artist_line)) = row else {
        return Ok(());
    };
    let keys = crate::normalize::search_keys(&[&title, &artist_line]);
    write_index_row(
        tx,
        INDEX_ALBUM,
        album_id,
        &title,
        &artist_line,
        &keys,
        false,
    )
}

/// 重建艺人的搜索索引行（改名 / 加别名之后调用）。
#[allow(dead_code)] // 同上：留给艺人改名 / 合并路径。
pub(crate) fn refresh_artist_index(tx: &rusqlite::Transaction<'_>, artist_id: i64) -> Result<()> {
    delete_index_row(tx, INDEX_ARTIST, artist_id)?;
    write_artist_row(tx, artist_id)
}

/// 入库路径用：艺人的索引行只依赖名字和别名（入库时不会改），已经有了就什么都不做。
pub(crate) fn ensure_artist_index(tx: &rusqlite::Transaction<'_>, artist_id: i64) -> Result<()> {
    if index_row_exists(tx, INDEX_ARTIST, artist_id)? {
        return Ok(());
    }
    write_artist_row(tx, artist_id)
}

fn write_artist_row(tx: &rusqlite::Transaction<'_>, artist_id: i64) -> Result<()> {
    let row: Option<(String, Option<String>)> = tx
        .query_row(
            "SELECT name, aliases_json FROM artist WHERE id = ?1",
            params![artist_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .db()?;
    let Some((name, aliases)) = row else {
        return Ok(());
    };
    let mut parts: Vec<&str> = vec![name.as_str()];
    let alias_list: Vec<String> = aliases
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    for alias in &alias_list {
        parts.push(alias.as_str());
    }
    let keys = crate::normalize::search_keys(&parts);
    write_index_row(tx, INDEX_ARTIST, artist_id, &name, "", &keys, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::scanned::{ScannedFile, ScannedTags};
    use lekis_types::{AudioProps, Codec, SourceConfig, SourceKind};
    use std::collections::BTreeMap;

    async fn local_source(lib: &Library) -> Result<lekis_types::SourceId> {
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

    fn file(
        source: lekis_types::SourceId,
        path: &str,
        title: &str,
        album: &str,
        track_no: u32,
    ) -> ScannedFile {
        ScannedFile {
            source_id: source,
            path: path.into(),
            size: 1_000,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec!["周杰伦".into()],
                album: Some(album.into()),
                track_no: Some(track_no),
                year: Some(2003),
                audio: Some(AudioProps {
                    codec: Codec::Flac,
                    sample_rate: 44_100,
                    bit_depth: Some(16),
                    channels: 2,
                    bitrate_kbps: Some(900),
                }),
                ..Default::default()
            },
        }
    }

    #[tokio::test]
    async fn browse_albums_and_artists() -> Result<()> {
        let lib = temp_library("browse")?;
        let src = local_source(&lib).await?;
        lib.upsert_scanned(vec![
            file(src, "a/1.flac", "以父之名", "叶惠美", 2),
            file(src, "a/2.flac", "晴天", "叶惠美", 3),
            file(src, "b/1.flac", "夜曲", "十一月的萧邦", 1),
        ])
        .await?;

        let albums = lib.list_albums(TrackSort::Title, 0, 10).await?;
        assert_eq!(albums.len(), 2, "两首在叶惠美下，应当只有两张专辑");
        let ye = match albums.iter().find(|a| a.title == "叶惠美") {
            Some(a) => a,
            // 用返回错误代替 panic：workspace 的 clippy 把 expect/unwrap 当警告。
            None => return Err(LekisError::not_found("专辑列表里应当有《叶惠美》")),
        };
        assert_eq!(ye.track_count, 2);
        assert_eq!(ye.year, Some(2003));

        let tracks = lib.album_tracks(ye.id, 0, 10).await?;
        assert_eq!(tracks.len(), 2);
        // 专辑页按曲号排序：第 2 首在前。
        assert_eq!(tracks[0].title, "以父之名");
        assert_eq!(tracks[1].title, "晴天");

        let artists = lib.list_artists(0, 10).await?;
        assert_eq!(artists.len(), 1);
        assert_eq!(artists[0].name, "周杰伦");

        let by_artist = lib.artist_tracks(artists[0].id, 0, 10).await?;
        assert_eq!(by_artist.len(), 3);
        let artist_albums = lib.artist_albums(artists[0].id, 0, 10).await?;
        assert_eq!(artist_albums.len(), 2);

        let track_idx = lib.track_title_index_offsets().await?;
        assert!(track_idx.iter().any(|e| e.letter == "Q")); // 晴天 -> qingtian
        assert!(track_idx.iter().any(|e| e.letter == "Y")); // 夜曲/以父之名 -> y...
        let artist_idx = lib.artist_index_offsets().await?;
        assert_eq!(artist_idx.len(), 1);
        assert_eq!(artist_idx[0].letter, "Z"); // 周杰伦 -> zhoujielun
        assert_eq!(artist_idx[0].offset, 0);
        Ok(())
    }

    #[tokio::test]
    async fn albums_and_artists_are_searchable() -> Result<()> {
        let lib = temp_library("browse-search")?;
        let src = local_source(&lib).await?;
        lib.upsert_scanned(vec![file(src, "a/1.flac", "晴天", "叶惠美", 1)])
            .await?;

        // 专辑名能搜到专辑，艺人名能搜到艺人，拼音缩写也能。
        for q in ["叶惠美", "yehuimei", "yhm"] {
            let hits = lib.search(q, 10).await?;
            assert_eq!(hits.albums.len(), 1, "搜 {q} 应当命中 1 张专辑");
        }
        for q in ["周杰伦", "zhoujielun", "zjl"] {
            let hits = lib.search(q, 10).await?;
            assert_eq!(hits.artists.len(), 1, "搜 {q} 应当命中 1 位艺人");
        }
        Ok(())
    }

    #[tokio::test]
    async fn invalid_limit_is_rejected() -> Result<()> {
        let lib = temp_library("browse-limit")?;
        assert!(lib.list_albums(TrackSort::Title, 0, 0).await.is_err());
        assert!(lib
            .list_artists(0, TrackQuery::MAX_LIMIT + 1)
            .await
            .is_err());
        Ok(())
    }
}
