//! 应用上下文：把核心、播放器、事件路由、主窗口和状态提示打包在一起。
//!
//! 页面只通过 [`App`] 调核心与播放器，不自己启动运行时、也不自己开线程
//! （`docs/ARCHITECTURE.md` 第 7 节：平台 UI 层没有业务逻辑，只调 `lekis-core`
//! 的公开 API）。

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::glib;
use gtk4::prelude::*;

use crate::bridge::EventRouter;
use crate::core_service::CoreHandle;
use crate::player::Player;

/// 状态提示在界面上停留多久。
const STATUS_TIMEOUT: Duration = Duration::from_secs(6);

/// 界面上下文。
///
/// 克隆只是给内部的 GObject 加引用计数，可以放心往闭包里搬。
#[derive(Clone)]
pub struct App {
    /// 核心句柄。
    core: CoreHandle,
    /// 播放器状态。
    player: Player,
    /// 事件路由。
    router: EventRouter,
    /// 主窗口（文件对话框、模态提示都需要它）。
    window: gtk4::ApplicationWindow,
    /// 底部状态提示。
    status: gtk4::Label,
    /// 状态提示的序号，用来让过期的定时器不要再改文字。
    status_seq: Rc<Cell<u64>>,
}

impl App {
    /// 组装上下文，并把播放器挂到核心事件总线上。
    ///
    /// 必须在 GTK 主线程调用，且要在 [`EventRouter::install`] 之后。
    pub fn new(core: CoreHandle, window: gtk4::ApplicationWindow, status: gtk4::Label) -> Self {
        let player = Player::new(core.clone());
        let router = EventRouter::default();
        {
            // 核心事件先合并进播放器状态，再统一通知界面（进度靠 PositionTick，不轮询）。
            let player = player.clone();
            router.on_event(move |event| player.apply_event(event));
        }
        Self {
            core,
            player,
            router,
            window,
            status,
            status_seq: Rc::new(Cell::new(0)),
        }
    }

    /// 核心句柄。
    pub fn core(&self) -> &CoreHandle {
        &self.core
    }

    /// 播放器状态。
    pub fn player(&self) -> &Player {
        &self.player
    }

    /// 事件路由。
    pub fn router(&self) -> &EventRouter {
        &self.router
    }

    /// 主窗口。
    pub fn window(&self) -> gtk4::ApplicationWindow {
        self.window.clone()
    }

    /// 显示一条状态提示，几秒后自动消失。
    pub fn status(&self, text: &str) {
        let seq = self.status_seq.get().wrapping_add(1);
        self.status_seq.set(seq);
        self.status.set_label(text);
        self.status.set_visible(true);

        let status = self.status.clone();
        let status_seq = Rc::clone(&self.status_seq);
        let _ = glib::timeout_add_local_once(STATUS_TIMEOUT, move || {
            // 期间又来了新提示就不要再把新的盖掉。
            if status_seq.get() == seq {
                status.set_visible(false);
            }
        });
    }
}
