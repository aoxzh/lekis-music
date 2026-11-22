//! 待确认的补全候选队列（ENR-06）。
//!
//! 补全提供方（`lekis-enrich`）找到候选后不直接改库，而是先塞进 `enrich_candidate` 表，
//! 由用户在"待确认"页面逐条接受 / 拒绝（也可以全部接受）。表结构见
//! `migrations/0001_init.sql`：
//! - `state`：`pending` / `accepted` / `rejected` / `auto_applied`；
//! - `track_id` / `album_id` 是**本机** ID（可空，专辑级候选比如封面可以只挂 `album_id`）；
//! - `payload_json` 是提供方自己的结果（解析方式由 `lekis-enrich` 决定，这一层只当字符串存）。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, AlbumId, LekisError, Result, TrackId, TrackQuery};
use rusqlite::{params, OptionalExtension, Row};

/// 分页上限，和 `TrackQuery::MAX_LIMIT` 保持一致。
const MAX_LIMIT: u32 = TrackQuery::MAX_LIMIT;

const CANDIDATE_COLUMNS: &str = "id, track_id, album_id, kind, payload_json, source, score, state,
     created_at, decided_at";

/// 一条新的补全候选（入队用）。
#[derive(Debug, Clone, PartialEq)]
pub struct NewEnrichCandidate {
    /// 关联的曲目（曲目级候选，例如歌词、标签）。
    pub track_id: Option<TrackId>,
    /// 关联的专辑（专辑级候选，例如封面）。
    pub album_id: Option<AlbumId>,
    /// 候选类型，例如 `artwork` / `lyrics` / `tags`。
    pub kind: String,
    /// 提供方返回的原始结果（JSON）。
    pub payload_json: String,
    /// 提供方标识，例如 `lrclib` / `coverartarchive` / `plugin:com.example.x`。
    pub source: String,
    /// 匹配分（0..=1，或者提供方自己的打分；越大越可信）。
    pub score: f32,
}

/// 一条已经入库的补全候选。
#[derive(Debug, Clone, PartialEq)]
pub struct EnrichCandidateRow {
    /// 本机 ID。
    pub id: i64,
    /// 关联曲目。
    pub track_id: Option<TrackId>,
    /// 关联专辑。
    pub album_id: Option<AlbumId>,
    /// 候选类型。
    pub kind: String,
    /// 提供方返回的原始结果（JSON）。
    pub payload_json: String,
    /// 提供方标识。
    pub source: String,
    /// 匹配分。
    pub score: f32,
    /// 状态：`pending` / `accepted` / `rejected` / `auto_applied`。
    pub state: String,
    /// 入队时间（Unix 毫秒）。
    pub created_at: i64,
    /// 用户做出决定的时间（Unix 毫秒，未决定为 `None`）。
    pub decided_at: Option<i64>,
}

fn map_candidate_row(r: &Row<'_>) -> rusqlite::Result<EnrichCandidateRow> {
    Ok(EnrichCandidateRow {
        id: r.get(0)?,
        track_id: r.get::<_, Option<i64>>(1)?.map(TrackId),
        album_id: r.get::<_, Option<i64>>(2)?.map(AlbumId),
        kind: r.get(3)?,
        payload_json: r.get(4)?,
        source: r.get(5)?,
        score: r.get::<_, f64>(6)? as f32,
        state: r.get(7)?,
        created_at: r.get(8)?,
        decided_at: r.get(9)?,
    })
}

fn check_limit(limit: u32) -> Result<()> {
    if limit == 0 || limit > MAX_LIMIT {
        return Err(LekisError::invalid(format!(
            "limit must be 1..={MAX_LIMIT}"
        )));
    }
    Ok(())
}

impl Library {
    /// 批量插入补全候选，返回**新增**的行数（更新已有 pending 行不算新增）。
    ///
    /// 去重键是 `(track_id, kind, source)`，并且只在 `state = 'pending'` 的行上生效：
    /// 已经有同样的 pending 候选时，用它更新 `payload_json` / `score` / `album_id`；
    /// 已经接受或拒绝过的候选不影响，会再插一条新的 pending（用户可能想重新看看）。
    pub async fn insert_enrich_candidates(&self, batch: Vec<NewEnrichCandidate>) -> Result<u64> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            let mut inserted = 0u64;
            {
                // `track_id IS ?3` 而不是 `=`：SQLite 里 NULL = NULL 是 NULL，`IS` 才能匹配空值。
                let mut find = tx
                    .prepare(
                        "SELECT id FROM enrich_candidate
                         WHERE state = 'pending' AND kind = ?1 AND source = ?2 AND track_id IS ?3",
                    )
                    .db()?;
                let mut update = tx
                    .prepare(
                        "UPDATE enrich_candidate
                         SET payload_json = ?2, score = ?3, album_id = ?4
                         WHERE id = ?1",
                    )
                    .db()?;
                let mut insert = tx
                    .prepare(
                        "INSERT INTO enrich_candidate
                           (track_id, album_id, kind, payload_json, source, score, state, created_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7)",
                    )
                    .db()?;
                for c in &batch {
                    let existing: Option<i64> = find
                        .query_row(
                            params![c.kind, c.source, c.track_id.map(|t| t.0)],
                            |r| r.get(0),
                        )
                        .optional()
                        .db()?;
                    match existing {
                        Some(id) => {
                            update
                                .execute(params![
                                    id,
                                    c.payload_json,
                                    f64::from(c.score),
                                    c.album_id.map(|a| a.0)
                                ])
                                .db()?;
                        }
                        None => {
                            insert
                                .execute(params![
                                    c.track_id.map(|t| t.0),
                                    c.album_id.map(|a| a.0),
                                    c.kind,
                                    c.payload_json,
                                    c.source,
                                    f64::from(c.score),
                                    now
                                ])
                                .db()?;
                            inserted += 1;
                        }
                    }
                }
            }
            tx.commit().db()?;
            Ok(inserted)
        })
        .await
    }

    /// 按入队时间取一批待确认候选（最老的在前，方便"从头过一遍"）。
    ///
    /// `limit` 必须在 `1..=TrackQuery::MAX_LIMIT`，否则返回 [`LekisError::invalid`]。
    pub async fn list_pending_candidates(&self, limit: u32) -> Result<Vec<EnrichCandidateRow>> {
        check_limit(limit)?;
        let sql = format!(
            "SELECT {CANDIDATE_COLUMNS} FROM enrich_candidate
             WHERE state = 'pending'
             ORDER BY created_at, id
             LIMIT ?1"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map(params![limit], map_candidate_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 待确认候选的总数（"待确认 (N)" 角标用）。
    pub async fn pending_candidate_count(&self) -> Result<u64> {
        self.read(|c| {
            c.query_row(
                "SELECT COUNT(*) FROM enrich_candidate WHERE state = 'pending'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .db()
            .map(|n| n.max(0) as u64)
        })
        .await
    }

    /// 自动清理已经过期的待确认封面候选：曲目（或其所属专辑）已经有生效封面时，
    /// 不再向用户提示重复的封面替换建议。返回被清理的条数。
    pub async fn dismiss_stale_artwork_candidates(&self) -> Result<u64> {
        self.write(move |conn| {
            let now = now_ms();
            let n = conn
                .execute(
                    "UPDATE enrich_candidate
                     SET state = 'rejected', decided_at = ?1
                     WHERE state = 'pending'
                       AND kind = 'artwork'
                       AND (
                         (track_id IS NOT NULL AND EXISTS (
                           SELECT 1
                           FROM track t
                           LEFT JOIN album a ON a.id = t.album_id
                           WHERE t.id = enrich_candidate.track_id
                             AND COALESCE(t.artwork_id, a.artwork_id) IS NOT NULL
                         ))
                         OR (album_id IS NOT NULL AND EXISTS (
                           SELECT 1
                           FROM album a
                           WHERE a.id = enrich_candidate.album_id
                             AND a.artwork_id IS NOT NULL
                         ))
                       )",
                    params![now],
                )
                .db()?;
            Ok(n as u64)
        })
        .await
    }

    /// 接受一条候选（`state = 'accepted'`，`decided_at` 记成现在）。
    ///
    /// 候选不存在、或者已经不是 `pending`，返回 [`LekisError::not_found`]。
    /// 把候选内容真正写进曲目是 `lekis-enrich` 的事，这一层只改状态。
    pub async fn accept_candidate(&self, id: i64) -> Result<()> {
        self.decide_candidate(id, "accepted").await
    }

    /// 拒绝一条候选（`state = 'rejected'`，`decided_at` 记成现在）。
    ///
    /// 语义同 [`Self::accept_candidate`]。
    pub async fn reject_candidate(&self, id: i64) -> Result<()> {
        self.decide_candidate(id, "rejected").await
    }

    /// 全部接受，返回被接受的条数（没有待确认候选时返回 0）。
    pub async fn accept_all_pending(&self) -> Result<u64> {
        self.write(move |conn| {
            let now = now_ms();
            let n = conn
                .execute(
                    "UPDATE enrich_candidate SET state = 'accepted', decided_at = ?1
                     WHERE state = 'pending'",
                    params![now],
                )
                .db()?;
            Ok(n as u64)
        })
        .await
    }

    /// 把一条 pending 候选改成 `state`，同时记 `decided_at`。
    async fn decide_candidate(&self, id: i64, state: &'static str) -> Result<()> {
        self.write(move |conn| {
            let now = now_ms();
            let n = conn
                .execute(
                    "UPDATE enrich_candidate SET state = ?2, decided_at = ?3
                     WHERE id = ?1 AND state = 'pending'",
                    params![id, state, now],
                )
                .db()?;
            if n == 0 {
                return Err(LekisError::not_found(format!("enrich candidate {id}")));
            }
            Ok(())
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::ErrorCode;

    fn candidate(
        track: Option<i64>,
        kind: &str,
        source: &str,
        payload: &str,
    ) -> NewEnrichCandidate {
        NewEnrichCandidate {
            track_id: track.map(TrackId),
            album_id: None,
            kind: kind.into(),
            payload_json: payload.into(),
            source: source.into(),
            score: 0.5,
        }
    }

    /// 直接写一行 `track`（`enrich_candidate.track_id` 有外键）。
    async fn add_track(lib: &Library, uid: &str) -> Result<TrackId> {
        let uid = uid.to_string();
        lib.write(move |c| {
            let now = now_ms();
            c.execute(
                "INSERT INTO track (uid, title, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)",
                params![uid, now],
            )
            .db()?;
            Ok(TrackId(c.last_insert_rowid()))
        })
        .await
    }

    fn err_code<T>(result: Result<T>) -> Option<ErrorCode> {
        result.err().map(|e| e.code)
    }

    #[tokio::test]
    async fn dedup_accept_reject_and_count() -> Result<()> {
        let lib = temp_library("enrich-queue")?;
        let t1 = add_track(&lib, "enrich-t1").await?;
        let t2 = add_track(&lib, "enrich-t2").await?;

        // 同一批里同一个 (track, kind, source) 只插一条。
        let added = lib
            .insert_enrich_candidates(vec![
                candidate(Some(t1.0), "lyrics", "lrclib", "{\"v\":1}"),
                candidate(Some(t1.0), "lyrics", "lrclib", "{\"v\":1}"),
                candidate(Some(t1.0), "lyrics", "plugin:com.example", "{\"v\":2}"),
                candidate(Some(t2.0), "artwork", "coverartarchive", "{\"v\":3}"),
            ])
            .await?;
        assert_eq!(added, 3, "重复的 (track, kind, source) 应当被去重");
        assert_eq!(lib.pending_candidate_count().await?, 3);

        // 再入同一条：不是新增，而是更新 payload / score。
        let again = lib
            .insert_enrich_candidates(vec![NewEnrichCandidate {
                track_id: Some(t1),
                album_id: None,
                kind: "lyrics".into(),
                payload_json: "{\"v\":9}".into(),
                source: "lrclib".into(),
                score: 0.9,
            }])
            .await?;
        assert_eq!(again, 0, "已存在的 pending 候选只更新，不新增");
        assert_eq!(lib.pending_candidate_count().await?, 3);
        let pending = lib.list_pending_candidates(10).await?;
        assert_eq!(pending.len(), 3);
        let lyrics = pending
            .iter()
            .find(|c| c.source == "lrclib")
            .map(|c| (c.payload_json.clone(), c.score));
        assert_eq!(lyrics, Some(("{\"v\":9}".to_string(), 0.9)));

        // 接受一条 → 不再出现在 pending 列表里，但总数减 1。
        let target = pending
            .iter()
            .find(|c| c.source == "coverartarchive")
            .map(|c| c.id)
            .unwrap_or_default();
        assert_ne!(target, 0, "应当能找到 coverartarchive 的候选");
        lib.accept_candidate(target).await?;
        assert_eq!(lib.pending_candidate_count().await?, 2);
        let pending = lib.list_pending_candidates(10).await?;
        assert!(pending.iter().all(|c| c.id != target));
        assert!(pending.iter().all(|c| c.state == "pending"));
        // 重复接受已经不存在的 pending → not_found。
        assert_eq!(
            err_code(lib.accept_candidate(target).await),
            Some(ErrorCode::NotFound)
        );

        // 已 accepted 的候选可以在同一 (track, kind, source) 上再插一条 pending。
        let re_added = lib
            .insert_enrich_candidates(vec![candidate(
                Some(t2.0),
                "artwork",
                "coverartarchive",
                "{\"v\":4}",
            )])
            .await?;
        assert_eq!(re_added, 1, "accepted 的行不参与去重");

        // 拒绝一条。
        let to_reject = lib
            .list_pending_candidates(10)
            .await?
            .iter()
            .find(|c| c.kind == "lyrics")
            .map(|c| c.id)
            .unwrap_or_default();
        assert_ne!(to_reject, 0, "应当能找到一条 lyrics 候选");
        lib.reject_candidate(to_reject).await?;
        assert_eq!(
            err_code(lib.reject_candidate(to_reject).await),
            Some(ErrorCode::NotFound)
        );

        // 全部接受：剩下的 pending 都变成 accepted。
        let n = lib.accept_all_pending().await?;
        let remaining = lib.pending_candidate_count().await?;
        assert_eq!(remaining, 0);
        assert_eq!(n, 2, "剩下 2 条 pending");
        // 再调一次是 0，不报错。
        assert_eq!(lib.accept_all_pending().await?, 0);

        let decided: i64 = lib
            .read(|c| {
                c.query_row(
                    "SELECT COUNT(*) FROM enrich_candidate WHERE decided_at IS NOT NULL",
                    [],
                    |r| r.get(0),
                )
                .db()
            })
            .await?;
        assert_eq!(decided, 4, "每条做过决定的候选都要有 decided_at");
        Ok(())
    }

    #[tokio::test]
    async fn album_level_candidates_and_limits() -> Result<()> {
        let lib = temp_library("enrich-album")?;
        // 专辑级候选：只挂 album_id，track_id 为空。同一个 (NULL, kind, source) 也要去重。
        let album = lib
            .write(|c| {
                let now = now_ms();
                c.execute(
                    "INSERT INTO album (title, title_norm, created_at) VALUES ('叶惠美', '叶惠美', ?1)",
                    params![now],
                )
                .db()?;
                Ok(AlbumId(c.last_insert_rowid()))
            })
            .await?;
        let mut c1 = candidate(None, "artwork", "coverartarchive", "{\"a\":1}");
        c1.album_id = Some(album);
        let mut c2 = candidate(None, "artwork", "coverartarchive", "{\"a\":2}");
        c2.album_id = Some(album);
        assert_eq!(lib.insert_enrich_candidates(vec![c1, c2]).await?, 1);
        let pending = lib.list_pending_candidates(10).await?;
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].track_id, None);
        assert_eq!(pending[0].album_id, Some(album));
        // 后一条覆盖了前一条的 payload。
        assert_eq!(pending[0].payload_json, "{\"a\":2}");

        // limit 越界是 invalid。
        assert_eq!(
            err_code(lib.list_pending_candidates(0).await),
            Some(ErrorCode::InvalidArgument)
        );
        assert_eq!(
            err_code(lib.list_pending_candidates(TrackQuery::MAX_LIMIT + 1).await),
            Some(ErrorCode::InvalidArgument)
        );
        Ok(())
    }
}
