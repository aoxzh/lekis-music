//! 桌面悬浮歌词（UIX-07）。
//!
//! 一个 Rust 自己持有的原生窗口，不经过 Flutter：第二个 Flutter 引擎要多 40–80 MB，
//! 官方多窗口 API 仍是实验性的（见 docs/adr/0008-desktop-lyrics-native-window.md）。
//!
//! - 宿主（桥接层）在换曲时推一次整首歌词（[`DesktopLyrics::set_lyrics`]），
//!   并把核心的播放时钟（约 200ms 一次）转给 [`DesktopLyrics::set_clock`]；
//!   窗口线程自己插值出每帧的位置，**每帧不经过 Dart**。
//! - 只有在播放且有逐字填充时才按显示器刷新率重绘；逐行歌词只在换行时重绘，
//!   暂停 / 隐藏时线程阻塞在消息循环里。
//! - 平台相关部分在 [`Platform`] 后面：Windows 用 Win32 分层窗口 + Direct2D/DirectWrite；
//!   macOS（NSPanel）/ Linux 以后各自实现，目前 [`DesktopLyrics::is_supported`] 返回 `false`。

pub mod model;
pub mod placement;
pub mod timeline;

#[cfg(target_os = "windows")]
mod win;

use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Instant;

pub use model::{Control, Event, Line, LyricsDoc, Style, Word};
use placement::Placements;
pub use timeline::Clock;

/// 窗口事件回调。在窗口线程上调用，不能阻塞。
pub type EventHandler = Arc<dyn Fn(Event) + Send + Sync>;

/// 窗口线程读取的共享状态。
pub(crate) struct State {
    pub(crate) visible: bool,
    pub(crate) locked: bool,
    pub(crate) style: Style,
    pub(crate) doc: Option<Arc<LyricsDoc>>,
    pub(crate) clock: Clock,
    pub(crate) clock_at: Instant,
    pub(crate) placements: Placements,
}

pub(crate) struct Shared {
    state: Mutex<State>,
    handler: Mutex<Option<EventHandler>>,
}

impl Shared {
    pub(crate) fn state(&self) -> MutexGuard<'_, State> {
        // 锁里只有赋值，不会 panic；就算中毒也继续用里面的数据。
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(crate) fn emit(&self, event: Event) {
        let handler = self.handler.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(h) = handler {
            h(event);
        }
    }
}

/// 发给平台窗口的“有东西变了”通知；窗口自己去 [`Shared`] 里读最新值。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Change {
    Visibility,
    Lock,
    Style,
    Lyrics,
    Clock,
}

/// 平台窗口（每个平台一个实现）。
pub(crate) trait Platform: Send + Sync {
    fn notify(&self, change: Change);
}

/// 悬浮歌词控制器（进程内单例）。
pub struct DesktopLyrics {
    shared: Arc<Shared>,
    platform: Mutex<Option<Box<dyn Platform>>>,
}

/// 播放中，新采样与插值结果差多少才算 seek（需要叫醒窗口重新算下一次换行时间）。
const SEEK_WAKE_MS: u64 = 400;

impl DesktopLyrics {
    /// 全局实例。窗口线程在第一次 [`show`](Self::show) 时才创建。
    pub fn global() -> &'static DesktopLyrics {
        static INSTANCE: OnceLock<DesktopLyrics> = OnceLock::new();
        INSTANCE.get_or_init(|| DesktopLyrics {
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    visible: false,
                    locked: false,
                    style: Style::default(),
                    doc: None,
                    clock: Clock::default(),
                    clock_at: Instant::now(),
                    placements: Placements::default(),
                }),
                handler: Mutex::new(None),
            }),
            platform: Mutex::new(None),
        })
    }

    /// 当前平台是否有实现。
    pub fn is_supported() -> bool {
        cfg!(target_os = "windows")
    }

    /// 设置事件回调（替换之前的）。
    pub fn set_event_handler(&self, handler: EventHandler) {
        *self.shared.handler.lock().unwrap_or_else(|e| e.into_inner()) = Some(handler);
    }

    /// 恢复保存过的位置记录（[`Event::PlacementChanged`] 给出的 JSON）。在第一次显示前调用。
    pub fn set_placements_json(&self, json: &str) {
        self.shared.state().placements = Placements::from_json(json);
    }

    /// 显示窗口。平台不支持或窗口创建失败时返回 `false`。
    pub fn show(&self) -> bool {
        if !Self::is_supported() {
            return false;
        }
        self.shared.state().visible = true;
        if !self.ensure_platform() {
            self.shared.state().visible = false;
            return false;
        }
        self.notify(Change::Visibility);
        true
    }

    /// 隐藏窗口（线程和资源保留，下次显示立即出现）。
    pub fn hide(&self) {
        let was = std::mem::replace(&mut self.shared.state().visible, false);
        if was {
            self.notify(Change::Visibility);
        }
    }

    /// 窗口是否显示中。
    pub fn is_visible(&self) -> bool {
        self.shared.state().visible
    }

    /// 锁定（鼠标穿透）/ 解锁（可拖动、悬停显示工具栏）。
    pub fn set_locked(&self, locked: bool) {
        let was = std::mem::replace(&mut self.shared.state().locked, locked);
        if was != locked {
            self.notify(Change::Lock);
        }
    }

    /// 是否锁定。
    pub fn is_locked(&self) -> bool {
        self.shared.state().locked
    }

    /// 更新外观。
    pub fn set_style(&self, style: Style) {
        let style = style.sanitized();
        let changed = {
            let mut s = self.shared.state();
            let changed = s.style != style;
            s.style = style;
            changed
        };
        if changed {
            self.notify(Change::Style);
        }
    }

    /// 换曲时推送整首歌词（含曲名，用于没有同步歌词时显示）。
    pub fn set_lyrics(&self, doc: LyricsDoc) {
        self.shared.state().doc = Some(Arc::new(doc));
        self.notify(Change::Lyrics);
    }

    /// 播放时钟采样（核心的播放事件）。只在状态真的变化时叫醒窗口。
    pub fn set_clock(&self, clock: Clock) {
        let now = Instant::now();
        let wake = {
            let mut s = self.shared.state();
            let prev = s.clock;
            let elapsed = u64::try_from(now.duration_since(s.clock_at).as_millis()).unwrap_or(u64::MAX);
            let expected = if prev.playing {
                prev.position_ms.saturating_add(elapsed)
            } else {
                prev.position_ms
            };
            s.clock = clock;
            s.clock_at = now;
            s.visible
                && (prev.playing != clock.playing
                    || prev.track_id != clock.track_id
                    || expected.abs_diff(clock.position_ms) > SEEK_WAKE_MS
                    || (!clock.playing && prev.position_ms != clock.position_ms))
        };
        if wake {
            self.notify(Change::Clock);
        }
    }

    fn ensure_platform(&self) -> bool {
        let mut p = self.platform.lock().unwrap_or_else(|e| e.into_inner());
        if p.is_some() {
            return true;
        }
        match start_platform(self.shared.clone()) {
            Ok(platform) => {
                *p = Some(platform);
                true
            }
            Err(e) => {
                tracing::warn!(target: "desktop_lyrics", "cannot create the desktop lyrics window: {e}");
                false
            }
        }
    }

    fn notify(&self, change: Change) {
        if let Some(p) = self.platform.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            p.notify(change);
        }
    }
}

#[cfg(target_os = "windows")]
fn start_platform(shared: Arc<Shared>) -> Result<Box<dyn Platform>, String> {
    win::start(shared).map(|p| Box::new(p) as Box<dyn Platform>)
}

#[cfg(not(target_os = "windows"))]
fn start_platform(_shared: Arc<Shared>) -> Result<Box<dyn Platform>, String> {
    Err("desktop lyrics are not implemented on this platform yet".into())
}
