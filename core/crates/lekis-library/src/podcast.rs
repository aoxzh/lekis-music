//! 播客的持久化（SRC-12）。
//!
//! - `podcast`：打开过的节目（RSS 源）。`subscribed = 1` 才出现在订阅列表里。
//! - `podcast_episode`：单集，按 `(podcast_id, guid)` 去重；刷新只更新元数据，
//!   保留播放进度和已播放标记。
//!
//! 播放队列用 [`PodcastEpisodeId::track_id`] 的合成 `TrackId` 引用单集，不写 `track` 表。

use crate::db::{DbResultExt, Library};
use lekis_types::{
    now_ms, LekisError, Podcast, PodcastEpisode, PodcastEpisodeId, PodcastId, Result,
};
use rusqlite::{params, Connection, OptionalExtension, Row};

/// 一次列表查询最多返回多少条。
const MAX_PODCAST_LIMIT: u32 = 1000;

const PODCAST_COLUMNS: &str = "p.id, p.feed_url, p.itunes_id, p.title, p.author, p.description,
     p.artwork_url, p.link, p.language, p.categories_json, p.subscribed, p.subscribed_at,
     p.last_refreshed_at, p.last_error,
     (SELECT COUNT(*) FROM podcast_episode e WHERE e.podcast_id = p.id),
     (SELECT COUNT(*) FROM podcast_episode e WHERE e.podcast_id = p.id AND e.played = 0),
     (SELECT MAX(e.published_at) FROM podcast_episode e WHERE e.podcast_id = p.id)";

const EPISODE_COLUMNS: &str = "e.id, e.podcast_id, p.title, e.guid, e.title, e.description,
     e.audio_url, e.mime_type, e.size_bytes, e.duration_ms, e.published_at,
     COALESCE(e.artwork_url, p.artwork_url), e.episode_no, e.season_no, e.link,
     e.position_ms, e.played, e.last_played_at";

fn map_podcast(r: &Row<'_>) -> rusqlite::Result<Podcast> {
    let categories_json: String = r.get(9)?;
    Ok(Podcast {
        id: PodcastId(r.get(0)?),
        feed_url: r.get(1)?,
        itunes_id: r.get(2)?,
        title: r.get(3)?,
        author: r.get(4)?,
        description: r.get(5)?,
        artwork_url: r.get(6)?,
        link: r.get(7)?,
        language: r.get(8)?,
        categories: serde_json::from_str(&categories_json).unwrap_or_default(),
        subscribed: r.get::<_, i64>(10)? != 0,
        subscribed_at: r.get(11)?,
        last_refreshed_at: r.get(12)?,
        last_error: r.get(13)?,
        episode_count: r.get::<_, i64>(14)?.max(0) as u32,
        unplayed_count: r.get::<_, i64>(15)?.max(0) as u32,
        latest_published_at: r.get(16)?,
    })
}

fn map_episode(r: &Row<'_>) -> rusqlite::Result<PodcastEpisode> {
    Ok(PodcastEpisode {
        id: PodcastEpisodeId(r.get(0)?),
        podcast_id: PodcastId(r.get(1)?),
        podcast_title: r.get(2)?,
        guid: r.get(3)?,
        title: r.get(4)?,
        description: r.get(5)?,
        audio_url: r.get(6)?,
        mime_type: r.get(7)?,
        size_bytes: r
            .get::<_, Option<i64>>(8)?
            .filter(|v| *v > 0)
            .map(|v| v as u64),
        duration_ms: r.get::<_, i64>(9)?.max(0) as u64,
        published_at: r.get(10)?,
        artwork_url: r.get(11)?,
        episode_no: r.get::<_, Option<i64>>(12)?.map(|v| v.max(0) as u32),
        season_no: r.get::<_, Option<i64>>(13)?.map(|v| v.max(0) as u32),
        link: r.get(14)?,
        position_ms: r.get::<_, i64>(15)?.max(0) as u64,
        played: r.get::<_, i64>(16)? != 0,
        last_played_at: r.get(17)?,
    })
}

fn read_podcast(c: &Connection, id: i64) -> Result<Podcast> {
    let sql = format!("SELECT {PODCAST_COLUMNS} FROM podcast p WHERE p.id = ?1");
    c.query_row(&sql, params![id], map_podcast)
        .optional()
        .db()?
        .ok_or_else(|| LekisError::not_found(format!("podcast {id}")))
}

fn read_episode(c: &Connection, id: i64) -> Result<PodcastEpisode> {
    let sql = format!(
        "SELECT {EPISODE_COLUMNS} FROM podcast_episode e JOIN podcast p ON p.id = e.podcast_id
         WHERE e.id = ?1"
    );
    c.query_row(&sql, params![id], map_episode)
        .optional()
        .db()?
        .ok_or_else(|| LekisError::not_found(format!("podcast episode {id}")))
}

fn clean(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

fn check_limit(limit: u32) -> Result<i64> {
    if limit == 0 || limit > MAX_PODCAST_LIMIT {
        return Err(LekisError::invalid(format!(
            "limit must be 1..={MAX_PODCAST_LIMIT}"
        )));
    }
    Ok(limit as i64)
}

fn query_episodes(
    c: &Connection,
    where_and_order: &str,
    params: impl rusqlite::Params,
) -> Result<Vec<PodcastEpisode>> {
    let sql = format!(
        "SELECT {EPISODE_COLUMNS} FROM podcast_episode e JOIN podcast p ON p.id = e.podcast_id
         {where_and_order}"
    );
    let mut stmt = c.prepare_cached(&sql).db()?;
    let rows = stmt.query_map(params, map_episode).db()?;
    rows.collect::<rusqlite::Result<Vec<_>>>().db()
}

/// 一个节目最多保留多少集（超大的历史源只存最新的这些）。
pub const MAX_EPISODES_PER_FEED: usize = 3000;

impl Library {
    /// 按本机 ID 取节目。
    pub async fn podcast(&self, id: PodcastId) -> Result<Podcast> {
        self.read(move |c| read_podcast(c, id.0)).await
    }

    /// 按 RSS 地址找节目。
    pub async fn podcast_by_feed_url(&self, feed_url: &str) -> Result<Option<Podcast>> {
        let feed_url = feed_url.trim().to_string();
        self.read(move |c| {
            let id: Option<i64> = c
                .query_row(
                    "SELECT id FROM podcast WHERE feed_url = ?1",
                    params![feed_url],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            id.map(|id| read_podcast(c, id)).transpose()
        })
        .await
    }

    /// 按 Apple Podcasts 目录 ID 找节目。
    pub async fn podcast_by_itunes_id(&self, itunes_id: i64) -> Result<Option<Podcast>> {
        self.read(move |c| {
            let id: Option<i64> = c
                .query_row(
                    "SELECT id FROM podcast WHERE itunes_id = ?1 ORDER BY subscribed DESC, id LIMIT 1",
                    params![itunes_id],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            id.map(|id| read_podcast(c, id)).transpose()
        })
        .await
    }

    /// 写入一次 RSS 抓取结果：按 `feed_url` upsert 节目，按 `guid` upsert 单集。
    ///
    /// `podcast.id` / `episode.id` 会被忽略。已存在的节目保留订阅状态；
    /// 已存在的单集保留播放进度和已播放标记。返回更新后的节目。
    pub async fn podcast_store_feed(
        &self,
        podcast: Podcast,
        episodes: Vec<PodcastEpisode>,
    ) -> Result<Podcast> {
        let feed_url = podcast.feed_url.trim().to_string();
        if feed_url.is_empty() {
            return Err(LekisError::invalid("podcast feed url must not be empty"));
        }
        let now = now_ms();
        let categories = serde_json::to_string(&podcast.categories)
            .map_err(|e| LekisError::internal(format!("serialize podcast categories: {e}")))?;
        self.write(move |c| {
            let tx = c.transaction().db()?;
            let existing: Option<i64> = tx
                .query_row(
                    "SELECT id FROM podcast WHERE feed_url = ?1",
                    params![feed_url],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            let title = podcast.title.trim();
            let id = if let Some(id) = existing {
                tx.execute(
                    "UPDATE podcast SET
                       itunes_id = COALESCE(?1, itunes_id),
                       title = CASE WHEN ?2 = '' THEN title ELSE ?2 END,
                       author = COALESCE(?3, author),
                       description = COALESCE(?4, description),
                       artwork_url = COALESCE(?5, artwork_url),
                       link = COALESCE(?6, link),
                       language = COALESCE(?7, language),
                       categories_json = CASE WHEN ?8 = '[]' THEN categories_json ELSE ?8 END,
                       last_refreshed_at = ?9,
                       last_error = NULL,
                       updated_at = ?9
                     WHERE id = ?10",
                    params![
                        podcast.itunes_id,
                        title,
                        clean(podcast.author.as_deref()),
                        clean(podcast.description.as_deref()),
                        clean(podcast.artwork_url.as_deref()),
                        clean(podcast.link.as_deref()),
                        clean(podcast.language.as_deref()),
                        categories,
                        now,
                        id,
                    ],
                )
                .db()?;
                id
            } else {
                tx.execute(
                    "INSERT INTO podcast
                       (feed_url, itunes_id, title, author, description, artwork_url, link,
                        language, categories_json, subscribed, subscribed_at,
                        last_refreshed_at, last_error, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, NULL, ?10, NULL, ?10, ?10)",
                    params![
                        feed_url,
                        podcast.itunes_id,
                        if title.is_empty() {
                            feed_url.as_str()
                        } else {
                            title
                        },
                        clean(podcast.author.as_deref()),
                        clean(podcast.description.as_deref()),
                        clean(podcast.artwork_url.as_deref()),
                        clean(podcast.link.as_deref()),
                        clean(podcast.language.as_deref()),
                        categories,
                        now,
                    ],
                )
                .db()?;
                tx.last_insert_rowid()
            };

            {
                let mut upsert = tx
                    .prepare_cached(
                        "INSERT INTO podcast_episode
                           (podcast_id, guid, title, description, audio_url, mime_type,
                            size_bytes, duration_ms, published_at, artwork_url, episode_no,
                            season_no, link, position_ms, played, last_played_at,
                            created_at, updated_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                                 0, 0, NULL, ?14, ?14)
                         ON CONFLICT (podcast_id, guid) DO UPDATE SET
                           title = excluded.title,
                           description = excluded.description,
                           audio_url = excluded.audio_url,
                           mime_type = excluded.mime_type,
                           size_bytes = excluded.size_bytes,
                           duration_ms = CASE WHEN excluded.duration_ms > 0
                                              THEN excluded.duration_ms ELSE duration_ms END,
                           published_at = COALESCE(excluded.published_at, published_at),
                           artwork_url = excluded.artwork_url,
                           episode_no = excluded.episode_no,
                           season_no = excluded.season_no,
                           link = excluded.link,
                           updated_at = excluded.updated_at",
                    )
                    .db()?;
                for episode in episodes.iter().take(MAX_EPISODES_PER_FEED) {
                    let guid = episode.guid.trim();
                    let audio_url = episode.audio_url.trim();
                    if guid.is_empty() || audio_url.is_empty() {
                        continue;
                    }
                    upsert
                        .execute(params![
                            id,
                            guid,
                            episode.title.trim(),
                            clean(episode.description.as_deref()),
                            audio_url,
                            clean(episode.mime_type.as_deref()),
                            episode.size_bytes.map(|v| v.min(i64::MAX as u64) as i64),
                            episode.duration_ms.min(i64::MAX as u64) as i64,
                            episode.published_at,
                            clean(episode.artwork_url.as_deref()),
                            episode.episode_no,
                            episode.season_no,
                            clean(episode.link.as_deref()),
                            now,
                        ])
                        .db()?;
                }
            }
            let out = read_podcast(&tx, id)?;
            tx.commit().db()?;
            Ok(out)
        })
        .await
    }

    /// 确保有一条节目记录（OPML 导入 / 先订阅后抓取）。已存在时原样返回。
    pub async fn podcast_ensure(
        &self,
        feed_url: &str,
        title: &str,
        itunes_id: Option<i64>,
    ) -> Result<Podcast> {
        let feed_url = feed_url.trim().to_string();
        let title = title.trim().to_string();
        if feed_url.is_empty() {
            return Err(LekisError::invalid("podcast feed url must not be empty"));
        }
        let now = now_ms();
        self.write(move |c| {
            c.execute(
                "INSERT INTO podcast (feed_url, itunes_id, title, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?4)
                 ON CONFLICT (feed_url) DO UPDATE SET
                   itunes_id = COALESCE(podcast.itunes_id, excluded.itunes_id)",
                params![
                    feed_url,
                    itunes_id,
                    if title.is_empty() { &feed_url } else { &title },
                    now
                ],
            )
            .db()?;
            let id: i64 = c
                .query_row(
                    "SELECT id FROM podcast WHERE feed_url = ?1",
                    params![feed_url],
                    |r| r.get(0),
                )
                .db()?;
            read_podcast(c, id)
        })
        .await
    }

    /// 记录一次刷新失败（`None` 清除）。
    pub async fn podcast_set_error(&self, id: PodcastId, error: Option<String>) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE podcast SET last_error = ?1, updated_at = ?2 WHERE id = ?3",
                params![error, now_ms(), id.0],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 订阅 / 取消订阅。取消订阅保留缓存和播放进度，重新订阅时还在。
    pub async fn podcast_set_subscribed(&self, id: PodcastId, subscribed: bool) -> Result<()> {
        let now = now_ms();
        self.write(move |c| {
            let changed = c
                .execute(
                    "UPDATE podcast SET
                       subscribed = ?1,
                       subscribed_at = CASE WHEN ?1 = 1 THEN COALESCE(subscribed_at, ?2) ELSE NULL END,
                       updated_at = ?2
                     WHERE id = ?3",
                    params![subscribed as i64, now, id.0],
                )
                .db()?;
            if changed == 0 {
                return Err(LekisError::not_found(format!("podcast {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 已订阅的节目，最新一集发布时间倒序。
    pub async fn podcast_subscriptions(&self) -> Result<Vec<Podcast>> {
        self.read(move |c| {
            let sql = format!(
                "SELECT {PODCAST_COLUMNS} FROM podcast p WHERE p.subscribed = 1
                 ORDER BY COALESCE((SELECT MAX(e.published_at) FROM podcast_episode e
                                    WHERE e.podcast_id = p.id), p.subscribed_at, 0) DESC,
                          p.title COLLATE NOCASE"
            );
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map([], map_podcast).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 某个节目的单集，新的在前。
    pub async fn podcast_episodes(
        &self,
        podcast_id: PodcastId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<PodcastEpisode>> {
        let limit = check_limit(limit)?;
        self.read(move |c| {
            query_episodes(
                c,
                "WHERE e.podcast_id = ?1
                 ORDER BY COALESCE(e.published_at, 0) DESC, e.id DESC LIMIT ?2 OFFSET ?3",
                params![podcast_id.0, limit, offset as i64],
            )
        })
        .await
    }

    /// 订阅节目里最新的单集（「最新」收件箱）。
    pub async fn podcast_latest_episodes(&self, limit: u32) -> Result<Vec<PodcastEpisode>> {
        let limit = check_limit(limit)?;
        self.read(move |c| {
            query_episodes(
                c,
                "WHERE p.subscribed = 1
                 ORDER BY COALESCE(e.published_at, 0) DESC, e.id DESC LIMIT ?1",
                params![limit],
            )
        })
        .await
    }

    /// 听到一半的单集（「继续收听」），最近播放优先。
    pub async fn podcast_in_progress(&self, limit: u32) -> Result<Vec<PodcastEpisode>> {
        let limit = check_limit(limit)?;
        self.read(move |c| {
            query_episodes(
                c,
                "WHERE e.played = 0 AND e.position_ms > 0
                 ORDER BY COALESCE(e.last_played_at, 0) DESC LIMIT ?1",
                params![limit],
            )
        })
        .await
    }

    /// 按本机 ID 取单集。
    pub async fn podcast_episode(&self, id: PodcastEpisodeId) -> Result<PodcastEpisode> {
        self.read(move |c| read_episode(c, id.0)).await
    }

    /// 记录播放进度；`played` 为 `Some` 时同时改已播放标记（播完时位置归零）。
    pub async fn podcast_update_progress(
        &self,
        id: PodcastEpisodeId,
        position_ms: u64,
        played: Option<bool>,
        at: i64,
    ) -> Result<()> {
        let position = position_ms.min(i64::MAX as u64) as i64;
        self.write(move |c| {
            let changed = match played {
                Some(true) => c.execute(
                    "UPDATE podcast_episode SET position_ms = 0, played = 1,
                       last_played_at = ?1, updated_at = ?1 WHERE id = ?2",
                    params![at, id.0],
                ),
                Some(false) => c.execute(
                    "UPDATE podcast_episode SET position_ms = ?1, played = 0,
                       last_played_at = ?2, updated_at = ?2 WHERE id = ?3",
                    params![position, at, id.0],
                ),
                None => c.execute(
                    "UPDATE podcast_episode SET position_ms = ?1,
                       last_played_at = ?2, updated_at = ?2 WHERE id = ?3",
                    params![position, at, id.0],
                ),
            }
            .db()?;
            if changed == 0 {
                return Err(LekisError::not_found(format!("podcast episode {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 标记已播放 / 未播放（不改最近播放时间）。两种情况都把进度归零。
    pub async fn podcast_set_played(&self, id: PodcastEpisodeId, played: bool) -> Result<()> {
        self.write(move |c| {
            let changed = c
                .execute(
                    "UPDATE podcast_episode SET played = ?1, position_ms = 0, updated_at = ?2
                     WHERE id = ?3",
                    params![played as i64, now_ms(), id.0],
                )
                .db()?;
            if changed == 0 {
                return Err(LekisError::not_found(format!("podcast episode {id}")));
            }
            Ok(())
        })
        .await
    }

    /// 把一个节目的所有单集标记为已播放。
    pub async fn podcast_mark_all_played(&self, id: PodcastId) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE podcast_episode SET played = 1, position_ms = 0, updated_at = ?1
                 WHERE podcast_id = ?2 AND played = 0",
                params![now_ms(), id.0],
            )
            .db()?;
            Ok(())
        })
        .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;

    fn podcast(feed: &str, title: &str) -> Podcast {
        Podcast {
            id: PodcastId(0),
            feed_url: feed.into(),
            itunes_id: Some(42),
            title: title.into(),
            author: Some("作者".into()),
            description: None,
            artwork_url: Some("https://example.test/a.jpg".into()),
            link: None,
            language: Some("zh-cn".into()),
            categories: vec!["Technology".into()],
            subscribed: false,
            subscribed_at: None,
            last_refreshed_at: None,
            last_error: None,
            episode_count: 0,
            unplayed_count: 0,
            latest_published_at: None,
        }
    }

    fn episode(guid: &str, title: &str, published: i64) -> PodcastEpisode {
        PodcastEpisode {
            id: PodcastEpisodeId(0),
            podcast_id: PodcastId(0),
            podcast_title: String::new(),
            guid: guid.into(),
            title: title.into(),
            description: None,
            audio_url: format!("https://example.test/{guid}.mp3"),
            mime_type: Some("audio/mpeg".into()),
            size_bytes: Some(1234),
            duration_ms: 60_000,
            published_at: Some(published),
            artwork_url: None,
            episode_no: Some(1),
            season_no: None,
            link: None,
            position_ms: 0,
            played: false,
            last_played_at: None,
        }
    }

    #[tokio::test]
    async fn store_feed_keeps_progress_and_subscription() -> Result<()> {
        let lib = temp_library("podcast-store").unwrap();
        let feed = "https://example.test/feed.xml";
        let stored = lib
            .podcast_store_feed(
                podcast(feed, "节目"),
                vec![episode("a", "第一集", 1), episode("b", "第二集", 2)],
            )
            .await?;
        assert_eq!(stored.episode_count, 2);
        assert_eq!(stored.unplayed_count, 2);
        assert!(!stored.subscribed);
        lib.podcast_set_subscribed(stored.id, true).await?;

        let eps = lib.podcast_episodes(stored.id, 0, 10).await?;
        assert_eq!(eps[0].title, "第二集");
        assert_eq!(
            eps[0].artwork_url.as_deref(),
            Some("https://example.test/a.jpg")
        );
        lib.podcast_update_progress(eps[0].id, 30_000, None, 100)
            .await?;
        lib.podcast_set_played(eps[1].id, true).await?;

        let again = lib
            .podcast_store_feed(
                podcast(feed, "节目（改名）"),
                vec![
                    episode("a", "第一集", 1),
                    episode("b", "第二集 改", 2),
                    episode("c", "第三集", 3),
                ],
            )
            .await?;
        assert_eq!(again.id, stored.id);
        assert!(again.subscribed);
        assert_eq!(again.title, "节目（改名）");
        assert_eq!(again.episode_count, 3);
        assert_eq!(again.unplayed_count, 2);

        let b = lib.podcast_episode(eps[0].id).await?;
        assert_eq!(b.title, "第二集 改");
        assert_eq!(b.position_ms, 30_000);
        assert_eq!(lib.podcast_in_progress(10).await?.len(), 1);
        assert_eq!(lib.podcast_latest_episodes(10).await?[0].guid, "c");
        assert_eq!(lib.podcast_subscriptions().await?.len(), 1);

        lib.podcast_update_progress(b.id, 59_000, Some(true), 200)
            .await?;
        let b = lib.podcast_episode(b.id).await?;
        assert!(b.played);
        assert_eq!(b.position_ms, 0);
        assert!(lib.podcast_in_progress(10).await?.is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn ensure_is_idempotent() -> Result<()> {
        let lib = temp_library("podcast-ensure").unwrap();
        let a = lib
            .podcast_ensure("https://example.test/f.xml", "OPML 标题", None)
            .await?;
        let b = lib
            .podcast_ensure("https://example.test/f.xml", "别的", Some(7))
            .await?;
        assert_eq!(a.id, b.id);
        assert_eq!(b.title, "OPML 标题");
        assert_eq!(b.itunes_id, Some(7));
        assert!(lib
            .podcast_by_feed_url("https://example.test/f.xml")
            .await?
            .is_some());
        assert_eq!(lib.podcast_by_itunes_id(7).await?.unwrap().id, a.id);
        Ok(())
    }
}
