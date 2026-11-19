//! 事件总线：把核心事件分发给所有监听者。

use lekis_playback::PlaybackSnapshot;
use lekis_types::CoreEvent;
use std::sync::{Arc, RwLock};
use tokio::sync::watch;

/// 事件监听者。**回调在核心线程上触发**，实现方要自己切回 UI 线程，并且不能阻塞。
pub trait EventListener: Send + Sync {
    /// 收到事件。
    fn on_event(&self, event: CoreEvent);
}

/// 事件总线。
#[derive(Clone, Default)]
pub(crate) struct EventBus {
    listeners: Arc<RwLock<Vec<Arc<dyn EventListener>>>>,
}

impl EventBus {
    pub(crate) fn add(&self, listener: Arc<dyn EventListener>) {
        if let Ok(mut l) = self.listeners.write() {
            l.push(listener);
        }
    }

    pub(crate) fn emit(&self, event: CoreEvent) {
        let listeners = match self.listeners.read() {
            Ok(l) => l.clone(),
            Err(_) => return,
        };
        for l in listeners {
            l.on_event(event.clone());
        }
    }
}

/// 把播放引擎的快照变化转成事件。
pub(crate) async fn forward_playback(mut rx: watch::Receiver<PlaybackSnapshot>, bus: EventBus) {
    let mut last = rx.borrow().clone();
    while rx.changed().await.is_ok() {
        let snap = rx.borrow_and_update().clone();
        if snap.state != last.state || snap.track_id != last.track_id {
            bus.emit(CoreEvent::PlaybackChanged {
                state: snap.state,
                track_id: snap.track_id,
                position_ms: snap.position_ms,
                duration_ms: snap.duration_ms,
            });
        } else if snap.position_ms != last.position_ms {
            bus.emit(CoreEvent::PositionTick {
                position_ms: snap.position_ms,
                buffered_ms: 0,
            });
        }
        if snap.repeat != last.repeat
            || snap.shuffle != last.shuffle
            || snap.volume != last.volume
            || snap.gapless != last.gapless
        {
            bus.emit(CoreEvent::PlaybackOptionsChanged {
                repeat: snap.repeat,
                shuffle: snap.shuffle,
                volume: snap.volume,
                gapless: snap.gapless,
            });
        }
        if snap.queue_len != last.queue_len
            || snap.queue_index != last.queue_index
            || snap.queue_version != last.queue_version
        {
            bus.emit(CoreEvent::QueueChanged {
                length: snap.queue_len,
                current_index: snap.queue_index,
            });
        }
        last = snap;
    }
}
