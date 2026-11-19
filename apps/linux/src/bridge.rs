//! 核心事件 → GTK 主线程的桥。
//!
//! `lekis_core::EventListener::on_event` 在核心自己的线程池里被调用
//! （`core/crates/lekis-core/src/events.rs` 的注释明确要求实现方自己切回 UI 线程、
//! 并且不能阻塞），所以这里只做一件事：把事件搬进 GTK 主线程再分发。
//!
//! 用 `MainContext::invoke` 而不是自己开 channel：它的唤醒机制就是 GLib 的
//! idle source，天然合并进主循环里，省得再维护一个消费者线程。
//!
//! 处理器表放在 thread-local 里：处理器是界面回调，需要直接碰控件（`Rc`），
//! 所以不能要求 `Send + Sync`——它本来就只会跑在 GTK 主线程上。

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib;
use lekis_core::EventListener;
use lekis_types::CoreEvent;

thread_local! {
    /// 界面的事件处理器。
    static HANDLERS: RefCell<Vec<Rc<dyn Fn(&CoreEvent)>>> = const { RefCell::new(Vec::new()) };
}

/// 把核心事件转发到 GTK 主线程。
struct GtkListener {
    /// GTK 主线程的 MainContext（跨线程安全）。
    context: glib::MainContext,
}

impl EventListener for GtkListener {
    fn on_event(&self, event: CoreEvent) {
        // 闭包本身只需要 `Send + 'static`（持有的是纯数据事件），真正的处理
        // 发生在主线程，因此界面回调不需要 Send/Sync。
        self.context.invoke(move || dispatch(&event));
    }
}

/// 在主线程上把事件交给所有已注册的处理器。
fn dispatch(event: &CoreEvent) {
    // 先复制一份，避免处理器里再注册新处理器时发生借用冲突。
    let handlers: Vec<Rc<dyn Fn(&CoreEvent)>> = HANDLERS.with(|slot| slot.borrow().clone());
    for handler in handlers {
        handler(event);
    }
}

/// 事件路由器：把核心的事件总线接到界面。
///
/// 克隆是廉价的，可以塞进每个页面。
#[derive(Clone, Copy, Default)]
pub struct EventRouter;

impl EventRouter {
    /// 把路由器挂到核心上；必须在 GTK 主线程调用。
    pub fn install(core: &lekis_core::LekisCore) {
        let listener = GtkListener {
            context: glib::MainContext::default(),
        };
        core.add_listener(Arc::new(listener));
    }

    /// 注册一个界面处理器。
    ///
    /// 处理器在主线程执行，可以自由捕获 `Rc` 控件；**不要太重**，
    /// 播放中 `PositionTick` 每 250ms 一次。
    pub fn on_event<F>(&self, handler: F)
    where
        F: Fn(&CoreEvent) + 'static,
    {
        HANDLERS.with(|slot| slot.borrow_mut().push(Rc::new(handler)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lekis_types::{LibraryScope, PlaybackState, SyncState};

    /// 事件应当可以被格式化（会被记进日志），构造覆盖所有分支。
    #[test]
    fn events_are_debuggable() {
        let events = [
            CoreEvent::PlaybackChanged {
                state: PlaybackState::Playing,
                track_id: None,
                position_ms: 0,
                duration_ms: 0,
            },
            CoreEvent::PositionTick {
                position_ms: 1,
                buffered_ms: 0,
            },
            CoreEvent::QueueChanged {
                length: 0,
                current_index: None,
            },
            CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog,
            },
            CoreEvent::EnrichQueueChanged { pending: 0 },
            CoreEvent::SyncStatus {
                state: SyncState::Idle,
            },
        ];
        for event in &events {
            assert!(!format!("{event:?}").is_empty());
        }
    }
}
