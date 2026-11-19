//! 扫描状态跟踪（NOD-03 的 `getScanStatus` / `startScan` 用）。
//!
//! `LekisCore::start_scan` 是"发起后台扫描后立即返回"，进度通过 [`CoreEvent`] 推送。
//! 这里注册一个监听者，把事件折成两个原子的状态，HTTP 侧随时可以读，不用轮询数据库。
//!
//! 监听回调在核心线程上触发（见 `lekis_core::EventListener` 的说明），所以只做原子写，
//! 不分配、不加锁、不阻塞。

use crate::AppState;
use lekis_core::EventListener;
use lekis_types::{CoreEvent, LekisError, Result};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// 扫描状态。
#[derive(Debug, Default)]
pub(crate) struct ScanTracker {
    /// 是否有扫描在跑。
    scanning: AtomicBool,
    /// 已完成的数量（最近一次 `ScanProgress` 的 `done`）。
    done: AtomicU64,
    /// 总数（`ScanProgress.total` 已知时才有意义；0 表示未知）。
    total: AtomicU64,
}

impl ScanTracker {
    /// 是否有扫描在跑。
    pub(crate) fn scanning(&self) -> bool {
        self.scanning.load(Ordering::Relaxed)
    }

    /// 已完成 / 总数。总数未知时返回 `(done, 0)`。
    pub(crate) fn progress(&self) -> (u64, u64) {
        (
            self.done.load(Ordering::Relaxed),
            self.total.load(Ordering::Relaxed),
        )
    }
}

impl EventListener for ScanTracker {
    fn on_event(&self, event: CoreEvent) {
        match event {
            CoreEvent::ScanProgress { done, total, .. } => {
                self.scanning.store(true, Ordering::Relaxed);
                self.done.store(done, Ordering::Relaxed);
                if let Some(total) = total {
                    self.total.store(total, Ordering::Relaxed);
                }
            }
            CoreEvent::ScanFinished { .. } => {
                self.scanning.store(false, Ordering::Relaxed);
            }
            _ => {}
        }
    }
}

/// 触发所有启用音源的扫描，返回启动了几个。
///
/// Subsonic 的 `startScan` 没有"扫哪个源"的参数（只有一个可选的 `musicFolderId`），
/// 所以这里遍历所有启用的源；某个源失败不影响其他源，但至少要成功一个才算成功。
pub(crate) async fn start_all(state: &AppState) -> Result<u64> {
    let sources = state.core.list_sources().await?;
    let mut started = 0u64;
    let mut last_error: Option<LekisError> = None;
    for source in sources.iter().filter(|source| source.enabled) {
        let Some(id) = source.id else { continue };
        match state.core.start_scan(id).await {
            Ok(()) => started += 1,
            Err(e) => {
                tracing::warn!(target: "node", %id, error = %e, "start scan failed for source");
                last_error = Some(e);
            }
        }
    }
    if started == 0 {
        if let Some(e) = last_error {
            return Err(e);
        }
    }
    Ok(started)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lekis_types::{ScanPhase, SourceId};

    #[test]
    fn tracker_follows_scan_events() {
        let tracker = ScanTracker::default();
        assert!(!tracker.scanning());
        assert_eq!(tracker.progress(), (0, 0));

        tracker.on_event(CoreEvent::ScanProgress {
            source_id: SourceId(1),
            phase: ScanPhase::ReadingTags,
            done: 5,
            total: Some(20),
        });
        assert!(tracker.scanning());
        assert_eq!(tracker.progress(), (5, 20));

        tracker.on_event(CoreEvent::ScanFinished {
            source_id: SourceId(1),
            added: 20,
            updated: 0,
            removed: 0,
        });
        assert!(!tracker.scanning());
    }

    #[test]
    fn unrelated_events_are_ignored() {
        let tracker = ScanTracker::default();
        tracker.on_event(CoreEvent::LibraryChanged {
            scope: lekis_types::LibraryScope::Catalog,
        });
        assert!(!tracker.scanning());
        assert_eq!(tracker.progress(), (0, 0));
    }
}
