//! 同步引擎（SYN-01、SYN-02、SYN-07）。
//!
//! 职责很窄，只有两件事：
//! 1. **推送**：把 `sync_outbox` 里攒下的本机操作追加到自己设备的日志里；
//! 2. **拉取并物化**：读其他设备的日志，按字段级 LWW 合并后写回本地数据库。
//!
//! 通道是"NAS 上的一个目录"（[`lekis_sync::channel::NasFolderChannel`]），所以只需要一个 `Vfs`。
//! 哪台设备写哪一份日志由协议保证（只写自己目录），合并顺序与输入顺序无关（见 `lekis_sync::merge`）。

use crate::events::EventBus;
use lekis_library::Library;
use lekis_sync::channel::NasFolderChannel;
use lekis_sync::{merge, EntityKind, Hlc, SyncChannel, SyncOp};
use lekis_types::{CoreEvent, Result, SyncState};
use std::collections::BTreeMap;
use std::sync::Arc;

/// 一次同步的结果。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SyncReport {
    /// 推送出去的操作数。
    pub pushed: u64,
    /// 从其他设备读到的操作数。
    pub pulled: u64,
    /// 实际改动了本地状态的字段数。
    pub applied: u64,
}

/// 推送本机待发操作。
pub(crate) async fn push(channel: &dyn SyncChannel, library: &Library, limit: u32) -> Result<u64> {
    let entries = library.pending_sync_ops(limit).await?;
    if entries.is_empty() {
        return Ok(0);
    }
    let mut ops = Vec::with_capacity(entries.len());
    for e in &entries {
        match serde_json::from_str::<SyncOp>(&e.op_json) {
            Ok(op) => ops.push(op),
            Err(err) => {
                // 坏行直接丢掉，否则会永远卡在队列头部。
                tracing::warn!(target: "sync", hlc = %e.hlc, error = %err, "dropping corrupt outbox entry");
                library.ack_sync_ops(vec![e.hlc.clone()]).await?;
            }
        }
    }
    if ops.is_empty() {
        return Ok(0);
    }
    channel.push(&ops).await?;
    let hlcs = entries.iter().map(|e| e.hlc.clone()).collect();
    let n = library.ack_sync_ops(hlcs).await?;
    Ok(n)
}

/// 拉取其他设备的操作，合并后物化到本地库。
pub(crate) async fn pull_and_apply(
    channel: &dyn SyncChannel,
    library: &Library,
    device_id: &str,
    clock: &mut lekis_sync::HlcClock,
) -> Result<SyncReport> {
    // 先问通道要"每个远端设备读到哪了"。
    let mut cursors: Vec<(String, Hlc)> = Vec::new();
    for remote in channel.devices().await? {
        if remote == device_id {
            continue;
        }
        if let Some(raw) = library
            .sync_cursor(channel.name(), &remote)
            .await?
            .and_then(|s| parse_hlc(&s))
        {
            cursors.push((remote, raw));
        }
    }

    let ops = channel.pull(&cursors).await?;
    if ops.is_empty() {
        return Ok(SyncReport::default());
    }
    let pulled = ops.len() as u64;

    // 推进本机时钟，保证之后的本机操作一定排在读到的操作之后。
    let now = lekis_types::now_ms();
    for op in &ops {
        clock.observe(&op.hlc, now);
    }

    // 字段级 LWW 合并。
    let merged = merge(ops.iter());
    let applied = apply_merged(library, &merged).await?;

    // 记录每台设备读到的最高 HLC。
    let mut highest: BTreeMap<String, Hlc> = BTreeMap::new();
    for op in &ops {
        highest
            .entry(op.hlc.device.clone())
            .and_modify(|h| {
                if op.hlc > *h {
                    *h = op.hlc.clone();
                }
            })
            .or_insert_with(|| op.hlc.clone());
    }
    for (device, hlc) in highest {
        library
            .set_sync_cursor(channel.name(), &device, &hlc.to_string())
            .await?;
    }

    Ok(SyncReport {
        pushed: 0,
        pulled,
        applied,
    })
}

/// 把合并后的字段写回数据库。目前只处理用户状态和设置（SYN-01 的 P0 部分）。
async fn apply_merged(
    library: &Library,
    merged: &BTreeMap<lekis_sync::merge::FieldKey, lekis_sync::merge::FieldState>,
) -> Result<u64> {
    // 按实体聚合，一个实体只写一次。
    let mut track_states: BTreeMap<String, (Option<bool>, Option<i64>)> = BTreeMap::new();
    let mut settings: BTreeMap<String, Option<serde_json::Value>> = BTreeMap::new();
    for ((entity, entity_id, field), state) in merged {
        match entity {
            EntityKind::TrackState => {
                let slot = track_states.entry(entity_id.clone()).or_default();
                match field.as_str() {
                    "loved" => slot.0 = state.value.as_ref().and_then(|v| v.as_bool()),
                    "rating" => slot.1 = state.value.as_ref().and_then(|v| v.as_i64()),
                    _ => {}
                }
            }
            EntityKind::Setting => {
                settings.insert(entity_id.clone(), state.value.clone());
            }
            // 歌单、播放记录、元数据覆盖层的物化留到后续（PL-01~05 / ENR）。
            _ => {}
        }
    }

    let mut applied = 0u64;
    for (uid, (loved, rating)) in track_states {
        let uid = lekis_types::TrackUid(uid);
        if let Some(loved) = loved {
            library.set_loved(uid.clone(), loved).await?;
            applied += 1;
        }
        if let Some(rating) = rating {
            library.set_rating(uid.clone(), rating).await?;
            applied += 1;
        }
    }
    for (key, value) in settings {
        // 设置项本身是字符串：直接取原文，不要把它再序列化成带引号的 JSON 文本。
        let text = match value {
            Some(serde_json::Value::String(s)) => s,
            Some(v) => serde_json::to_string(&v).unwrap_or_default(),
            None => continue,
        };
        library.set_setting(&key, &text).await?;
        applied += 1;
    }
    Ok(applied)
}

/// 解析数据库里存的 HLC 字符串（`0000001732000000000-00000001-device`）。
pub(crate) fn parse_hlc(raw: &str) -> Option<Hlc> {
    let mut parts = raw.splitn(3, '-');
    let wall = parts.next()?.parse::<i64>().ok()?;
    let counter = u32::from_str_radix(parts.next()?, 16).ok()?;
    let device = parts.next()?.to_string();
    Some(Hlc {
        wall_ms: wall,
        counter,
        device,
    })
}

/// 完整同步一轮。
pub(crate) async fn sync_once(
    channel: &dyn SyncChannel,
    library: &Library,
    device_id: &str,
    clock: &mut lekis_sync::HlcClock,
    events: &EventBus,
) -> Result<SyncReport> {
    events.emit(CoreEvent::SyncStatus {
        state: SyncState::Syncing,
    });
    let pushed = push(channel, library, 1000).await?;
    let mut report = pull_and_apply(channel, library, device_id, clock).await?;
    report.pushed = pushed;
    events.emit(CoreEvent::SyncStatus {
        state: SyncState::Idle,
    });
    if report.applied > 0 {
        events.emit(CoreEvent::LibraryChanged {
            scope: lekis_types::LibraryScope::UserState,
        });
    }
    Ok(report)
}

/// 从"共享目录的 Vfs"造一个同步通道。
pub(crate) fn channel_for(root: Arc<dyn lekis_vfs::Vfs>, device_id: &str) -> Arc<dyn SyncChannel> {
    Arc::new(NasFolderChannel::new(root, device_id))
}

/// 造一条"曲目用户状态"的同步操作（SYN-01）。
///
/// 时钟被别的线程占着时退化成"用当前时间戳"，宁可丢一次因果顺序也不要阻塞 UI。
pub(crate) fn track_state_op(
    clock: &std::sync::Mutex<lekis_sync::HlcClock>,
    uid: &lekis_types::TrackUid,
    field: &str,
    value: Option<serde_json::Value>,
) -> SyncOp {
    SyncOp {
        hlc: next_hlc(clock),
        entity: EntityKind::TrackState,
        entity_id: uid.0.clone(),
        field: field.to_string(),
        value,
    }
}

/// 造一条"设置项"的同步操作。
pub(crate) fn setting_op(
    clock: &std::sync::Mutex<lekis_sync::HlcClock>,
    key: &str,
    value: &str,
) -> SyncOp {
    SyncOp {
        hlc: next_hlc(clock),
        entity: EntityKind::Setting,
        entity_id: key.to_string(),
        field: "value".to_string(),
        value: Some(serde_json::json!(value)),
    }
}

fn next_hlc(clock: &std::sync::Mutex<lekis_sync::HlcClock>) -> Hlc {
    let now = lekis_types::now_ms();
    match clock.lock() {
        Ok(mut c) => c.tick(now),
        Err(poisoned) => poisoned.into_inner().tick(now),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lekis_library::Library;
    use std::sync::Arc;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("lekis-core-sync-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        dir
    }

    fn lib(dir: &std::path::Path) -> Library {
        Library::open(&dir.join("library.sqlite")).expect("open")
    }

    fn vfs(dir: &std::path::Path) -> Arc<dyn lekis_vfs::Vfs> {
        let config = lekis_types::SourceConfig {
            id: Some(lekis_types::SourceId(1)),
            kind: lekis_types::SourceKind::Local,
            name: "share".into(),
            addresses: vec![dir.to_string_lossy().into_owned()],
            root_path: String::new(),
            credential_ref: None,
            options: Default::default(),
            enabled: true,
        };
        lekis_vfs::open(&config, None).expect("open vfs")
    }

    #[test]
    fn hlc_string_roundtrips() {
        let hlc = Hlc {
            wall_ms: 1_732_000_000_123,
            counter: 42,
            device: "device-a".into(),
        };
        let parsed = parse_hlc(&hlc.to_string()).expect("parse");
        assert_eq!(parsed, hlc);
        assert!(parse_hlc("garbage").is_none());
    }

    #[tokio::test]
    async fn two_devices_converge_on_loved() -> Result<()> {
        let share = temp_dir("share");
        let dir_a = temp_dir("a");
        let dir_b = temp_dir("b");
        let lib_a = lib(&dir_a);
        let lib_b = lib(&dir_b);
        let share_vfs = vfs(&share);
        let ch_a = channel_for(share_vfs.clone(), "dev-a");
        let ch_b = channel_for(share_vfs.clone(), "dev-b");
        let mut clock_a = lekis_sync::HlcClock::new("dev-a");
        let mut clock_b = lekis_sync::HlcClock::new("dev-b");
        let bus = EventBus::default();

        // A 收藏了一首歌，写进 outbox。
        let op = SyncOp {
            hlc: clock_a.tick(1_000),
            entity: EntityKind::TrackState,
            entity_id: "mb:track-1".into(),
            field: "loved".into(),
            value: Some(serde_json::json!(true)),
        };
        lib_a
            .enqueue_sync_op(op.hlc.to_string(), serde_json::to_string(&op).expect("ser"))
            .await?;

        let r1 = sync_once(ch_a.as_ref(), &lib_a, "dev-a", &mut clock_a, &bus).await?;
        assert_eq!(r1.pushed, 1);

        // B 同步：读到 A 的操作并物化。
        let r2 = sync_once(ch_b.as_ref(), &lib_b, "dev-b", &mut clock_b, &bus).await?;
        assert_eq!(r2.pulled, 1);
        assert_eq!(r2.applied, 1);

        // dev-b 的设备 A 游标已经推进，再同步一次不该重复应用。
        let r3 = sync_once(ch_b.as_ref(), &lib_b, "dev-b", &mut clock_b, &bus).await?;
        assert_eq!(r3.pulled, 0);

        // A 自己不会读到自己的操作。
        let r4 = sync_once(ch_a.as_ref(), &lib_a, "dev-a", &mut clock_a, &bus).await?;
        assert_eq!(r4.pulled, 0);
        Ok(())
    }

    #[tokio::test]
    async fn later_op_wins_regardless_of_arrival_order() -> Result<()> {
        let share = temp_dir("share-order");
        let dir_b = temp_dir("b-order");
        let lib_b = lib(&dir_b);
        let share_vfs = vfs(&share);
        let ch_a = channel_for(share_vfs.clone(), "dev-a");
        // 读方要用自己的通道：pull 会跳过"本机目录"，用 ch_a 读就看不到 dev-a 自己的日志。
        let ch_b = channel_for(share_vfs.clone(), "dev-b");
        let mk = |wall: i64, value: bool| SyncOp {
            hlc: Hlc {
                wall_ms: wall,
                counter: 0,
                device: "dev-a".into(),
            },
            entity: EntityKind::TrackState,
            entity_id: "mb:x".into(),
            field: "loved".into(),
            value: Some(serde_json::json!(value)),
        };
        ch_a.push(&[mk(1_000, true), mk(2_000, false)]).await?;

        let mut clock_b = lekis_sync::HlcClock::new("dev-b");
        let bus = EventBus::default();
        let report = sync_once(ch_b.as_ref(), &lib_b, "dev-b", &mut clock_b, &bus).await?;
        assert_eq!(report.pulled, 2);
        // 两条操作合并成一个字段状态 → 只应用 1 次。
        assert_eq!(report.applied, 1);

        // 合并后的值应该是更晚的 false。
        let state = lib_b
            .user_state(lekis_types::TrackUid("mb:x".into()))
            .await?;
        assert!(!state.loved);
        Ok(())
    }

    #[tokio::test]
    async fn settings_sync_across_devices() -> Result<()> {
        let share = temp_dir("share-settings");
        let dir_a = temp_dir("a-settings");
        let dir_b = temp_dir("b-settings");
        let lib_a = lib(&dir_a);
        let lib_b = lib(&dir_b);
        let share_vfs = vfs(&share);
        let ch_a = channel_for(share_vfs.clone(), "dev-a");
        let ch_b = channel_for(share_vfs.clone(), "dev-b");
        let mut clock_a = lekis_sync::HlcClock::new("dev-a");
        let mut clock_b = lekis_sync::HlcClock::new("dev-b");
        let bus = EventBus::default();

        let op = SyncOp {
            hlc: clock_a.tick(1_500),
            entity: EntityKind::Setting,
            entity_id: "ui.theme".into(),
            field: "value".into(),
            value: Some(serde_json::json!("dark")),
        };
        lib_a
            .enqueue_sync_op(op.hlc.to_string(), serde_json::to_string(&op).expect("ser"))
            .await?;
        sync_once(ch_a.as_ref(), &lib_a, "dev-a", &mut clock_a, &bus).await?;
        let r = sync_once(ch_b.as_ref(), &lib_b, "dev-b", &mut clock_b, &bus).await?;
        assert_eq!(r.applied, 1);
        assert_eq!(lib_b.get_setting("ui.theme").await?, Some("dark".into()));
        Ok(())
    }
}
