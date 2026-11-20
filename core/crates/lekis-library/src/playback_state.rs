//! 播放会话持久化（PLY：重启后接着听）。
//!
//! 只保存本机数据库里的 `track.id`：资料库换了设备 / 源之后，旧 ID 会失效，
//! 所以读取时会把库里已经不存在的曲目丢掉，并修正当前下标。
//! 队列、游标、进度、随机 / 循环模式和音量都存在单行 `playback_state` 里。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{ErrorCode, LekisError, RepeatMode, Result, ShuffleMode, TrackId};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashSet;

/// 一次可恢复的播放会话。
#[derive(Debug, Clone, PartialEq)]
pub struct PlaybackStateRow {
    /// 按播放顺序排列的队列（只含本机 `track.id`）。
    pub queue: Vec<TrackId>,
    /// 当前曲目在 [`Self::queue`] 里的下标。
    pub current_index: u32,
    /// 当前曲目进度（毫秒）。
    pub position_ms: u64,
    /// 随机模式。
    pub shuffle: ShuffleMode,
    /// 循环模式。
    pub repeat: RepeatMode,
    /// 音量（0..=1）。
    pub volume: f32,
    /// 最后一次保存时间（Unix 毫秒）。
    pub updated_at: i64,
}

impl Library {
    /// 保存播放会话。空队列等于「没有可恢复的会话」，会清掉旧记录。
    pub async fn save_playback_state(&self, state: PlaybackStateRow) -> Result<()> {
        if state.queue.is_empty() {
            return self.clear_playback_state().await;
        }
        let ids: Vec<i64> = state.queue.iter().map(|id| id.0).collect();
        let queue_json = serde_json::to_string(&ids)
            .map_err(|e| LekisError::internal(format!("serialize playback queue: {e}")))?;
        let index = (state.current_index as usize).min(ids.len() - 1) as i64;
        let position = state.position_ms.min(i64::MAX as u64) as i64;
        let volume = if state.volume.is_finite() {
            f64::from(state.volume.clamp(0.0, 1.0))
        } else {
            1.0
        };
        let shuffle = shuffle_str(state.shuffle);
        let repeat = repeat_str(state.repeat);
        let updated_at = state.updated_at;

        self.write(move |c| {
            c.execute(
                "INSERT INTO playback_state
                   (id, queue_json, queue_index, position_ms, shuffle, repeat_mode, volume, updated_at)
                 VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT (id) DO UPDATE SET
                   queue_json = excluded.queue_json,
                   queue_index = excluded.queue_index,
                   position_ms = excluded.position_ms,
                   shuffle = excluded.shuffle,
                   repeat_mode = excluded.repeat_mode,
                   volume = excluded.volume,
                   updated_at = excluded.updated_at",
                params![queue_json, index, position, shuffle, repeat, volume, updated_at],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 读取上次保存的播放会话。
    ///
    /// 库里已经不存在的曲目会被丢掉；当前曲目被删时游标落到它后面第一首可播放的，
    /// 没有就从队尾退。过滤后队列为空则返回 `None`。
    pub async fn load_playback_state(&self) -> Result<Option<PlaybackStateRow>> {
        self.read(load_from).await
    }

    /// 清掉保存的播放会话（用户清空队列 / 退出登录 / 资料库重置时用）。
    pub async fn clear_playback_state(&self) -> Result<()> {
        self.write(|c| {
            c.execute("DELETE FROM playback_state WHERE id = 1", [])
                .db()?;
            Ok(())
        })
        .await
    }
}

fn load_from(c: &Connection) -> Result<Option<PlaybackStateRow>> {
    let row: Option<(String, i64, i64, String, String, f64, i64)> = c
        .query_row(
            "SELECT queue_json, queue_index, position_ms, shuffle, repeat_mode, volume, updated_at
             FROM playback_state WHERE id = 1",
            [],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            },
        )
        .optional()
        .db()?;
    let Some((queue_json, raw_index, raw_position, shuffle, repeat, volume, updated_at)) = row
    else {
        return Ok(None);
    };

    let ids: Vec<i64> = serde_json::from_str(&queue_json).map_err(|e| {
        LekisError::new(
            ErrorCode::Database,
            format!("playback_state.queue_json is not a JSON array: {e}"),
        )
    })?;
    let valid = existing_track_ids(c, &ids)?;
    let requested = raw_index.max(0) as usize;
    let cursor_existed = ids.get(requested).is_some_and(|id| valid.contains(id));

    let mut queue = Vec::with_capacity(ids.len());
    let mut current_index = None;
    let mut next_after_cursor = None;
    for (i, id) in ids.into_iter().enumerate() {
        if !valid.contains(&id) {
            continue;
        }
        if i == requested {
            current_index = Some(queue.len());
        } else if i > requested && next_after_cursor.is_none() {
            next_after_cursor = Some(queue.len());
        }
        queue.push(TrackId(id));
    }
    if queue.is_empty() {
        return Ok(None);
    }
    let index = current_index
        .or(next_after_cursor)
        .unwrap_or(queue.len() - 1) as u32;

    Ok(Some(PlaybackStateRow {
        queue,
        current_index: index,
        // 当前曲目被删时不能把旧进度套到别的歌上。
        position_ms: if cursor_existed {
            raw_position.max(0) as u64
        } else {
            0
        },
        shuffle: parse_shuffle(&shuffle),
        repeat: parse_repeat(&repeat),
        volume: (volume as f32).clamp(0.0, 1.0),
        updated_at,
    }))
}

/// 一次查询一批存在的曲目 ID（SQLite 参数通常限制在 999）。
fn existing_track_ids(c: &Connection, ids: &[i64]) -> Result<HashSet<i64>> {
    const CHUNK: usize = 400;
    let mut valid = HashSet::with_capacity(ids.len());
    let mut seen = HashSet::with_capacity(ids.len());
    let unique: Vec<i64> = ids.iter().copied().filter(|id| seen.insert(*id)).collect();
    for chunk in unique.chunks(CHUNK) {
        let placeholders = std::iter::repeat_n("?", chunk.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!("SELECT id FROM track WHERE id IN ({placeholders})");
        let mut stmt = c.prepare_cached(&sql).db()?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(chunk.iter()), |r| {
                r.get::<_, i64>(0)
            })
            .db()?;
        for id in rows {
            valid.insert(id.db()?);
        }

        // 网络电台用负数合成 TrackId（SRC-11）；只要 radio_station 里还有这一行，
        // 重启后也允许恢复这条队列。
        let radio_ids: Vec<i64> = chunk
            .iter()
            .copied()
            .filter(|id| *id < 0)
            .map(|id| -id)
            .collect();
        if !radio_ids.is_empty() {
            let placeholders = std::iter::repeat_n("?", radio_ids.len())
                .collect::<Vec<_>>()
                .join(",");
            let sql = format!("SELECT -id FROM radio_station WHERE id IN ({placeholders})");
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(radio_ids.iter()), |r| {
                    r.get::<_, i64>(0)
                })
                .db()?;
            for id in rows {
                valid.insert(id.db()?);
            }
        }
    }
    Ok(valid)
}

fn shuffle_str(mode: ShuffleMode) -> &'static str {
    match mode {
        ShuffleMode::Off => "off",
        ShuffleMode::Random => "random",
        ShuffleMode::Smart => "smart",
    }
}

fn parse_shuffle(value: &str) -> ShuffleMode {
    match value {
        "random" => ShuffleMode::Random,
        "smart" => ShuffleMode::Smart,
        // 未知值（旧版本 / 手工改库）按顺序播放，不要因为一条记录拒绝启动。
        _ => ShuffleMode::Off,
    }
}

fn repeat_str(mode: RepeatMode) -> &'static str {
    match mode {
        RepeatMode::Off => "off",
        RepeatMode::All => "all",
        RepeatMode::One => "one",
    }
}

fn parse_repeat(value: &str) -> RepeatMode {
    match value {
        "all" => RepeatMode::All,
        "one" => RepeatMode::One,
        _ => RepeatMode::Off,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;

    async fn seed_tracks(lib: &Library, ids: &[i64]) -> Result<()> {
        let ids = ids.to_vec();
        lib.write(move |c| {
            for id in ids {
                c.execute(
                    "INSERT INTO track (id, uid, title, created_at, updated_at)
                     VALUES (?1, ?2, ?3, 0, 0)",
                    params![id, format!("test:track:{id}"), format!("Track {id}")],
                )
                .db()?;
            }
            Ok(())
        })
        .await
    }

    fn state(queue: &[i64], index: u32, position_ms: u64) -> PlaybackStateRow {
        PlaybackStateRow {
            queue: queue.iter().copied().map(TrackId).collect(),
            current_index: index,
            position_ms,
            shuffle: ShuffleMode::Random,
            repeat: RepeatMode::One,
            volume: 0.37,
            updated_at: 1_700_000_000_123,
        }
    }

    #[tokio::test]
    async fn empty_state_is_none_and_clear_is_idempotent() -> Result<()> {
        let lib = temp_library("playback-state-empty")?;
        assert_eq!(lib.load_playback_state().await?, None);
        lib.clear_playback_state().await?;
        assert_eq!(lib.load_playback_state().await?, None);

        // 空队列不写记录：等于没有可恢复的会话。
        seed_tracks(&lib, &[1]).await?;
        lib.save_playback_state(state(&[], 0, 0)).await?;
        assert_eq!(lib.load_playback_state().await?, None);
        Ok(())
    }

    #[tokio::test]
    async fn roundtrip_restores_every_field() -> Result<()> {
        let lib = temp_library("playback-state-roundtrip")?;
        seed_tracks(&lib, &[10, 20, 30]).await?;
        let saved = state(&[10, 20, 30], 1, 42_000);
        lib.save_playback_state(saved.clone()).await?;
        assert_eq!(lib.load_playback_state().await?, Some(saved));

        // 再保存是覆盖，不是新增。
        let mut updated = state(&[30, 10], 0, 7_500);
        updated.shuffle = ShuffleMode::Smart;
        updated.repeat = RepeatMode::All;
        updated.volume = 0.8;
        lib.save_playback_state(updated.clone()).await?;
        assert_eq!(lib.load_playback_state().await?, Some(updated));

        lib.clear_playback_state().await?;
        assert_eq!(lib.load_playback_state().await?, None);
        Ok(())
    }

    #[tokio::test]
    async fn missing_tracks_are_dropped_and_cursor_is_fixed() -> Result<()> {
        let lib = temp_library("playback-state-invalid")?;
        seed_tracks(&lib, &[10, 20, 30]).await?;
        // 999 是已被删掉的曲目；游标仍指向存活的 20。
        lib.save_playback_state(state(&[10, 999, 20, 30], 2, 12_000))
            .await?;
        let loaded = lib.load_playback_state().await?.expect("state");
        assert_eq!(loaded.queue, vec![TrackId(10), TrackId(20), TrackId(30)]);
        assert_eq!(loaded.current_index, 1);
        assert_eq!(loaded.position_ms, 12_000);

        // 游标本身指向已删除的曲目：落到它后面第一首，进度归零。
        lib.save_playback_state(state(&[10, 999, 30], 1, 12_000))
            .await?;
        let loaded = lib.load_playback_state().await?.expect("state");
        assert_eq!(loaded.queue, vec![TrackId(10), TrackId(30)]);
        assert_eq!(loaded.current_index, 1);
        assert_eq!(loaded.position_ms, 0);

        // 最后一条也坏了：退到队列里最后一首存活的。
        lib.save_playback_state(state(&[10, 20, 999], 2, 9_000))
            .await?;
        let loaded = lib.load_playback_state().await?.expect("state");
        assert_eq!(loaded.queue, vec![TrackId(10), TrackId(20)]);
        assert_eq!(loaded.current_index, 1);
        assert_eq!(loaded.position_ms, 0);

        // 全部失效：没有可恢复的会话。
        lib.save_playback_state(state(&[999, 998], 0, 0)).await?;
        assert_eq!(lib.load_playback_state().await?, None);
        Ok(())
    }
}
