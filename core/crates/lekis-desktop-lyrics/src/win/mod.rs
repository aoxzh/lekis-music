//! Windows 后端：Win32 分层窗口（`WS_EX_LAYERED | TOPMOST | TOOLWINDOW | NOACTIVATE`），
//! Direct2D（软件渲染目标）+ DirectWrite 画进 32 位预乘 DIB，再用 `UpdateLayeredWindow`
//! 按像素 alpha 合成。
//!
//! 线程模型：一个专用线程拥有窗口和所有 D2D 资源。其他线程只往 [`Shared`] 里写数据，
//! 然后 `PostMessage` 叫醒它（[`WM_LYRICS_CHANGE`]）。
//!
//! 节奏：
//! - 卡拉 OK 填充推进中：每帧 `DwmFlush` 等合成器 vblank（= 显示器刷新率）。
//! - 逐行歌词：只在换行时刻醒来（`MsgWaitForMultipleObjectsEx` 带超时）。
//! - 暂停 / 隐藏：阻塞在消息队列上，不耗 CPU。悬停检测用 100ms 的定时器（只在显示时）。

mod render;

use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use windows::core::{w, BOOL, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, MonitorFromWindow, HDC, HMONITOR, MONITORINFO,
    MONITORINFOEXW, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{
    GetDpiForMonitor, GetDpiForWindow, SetThreadDpiAwarenessContext,
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::model::{Control, Event};
use crate::placement::{self, Monitor, Rect};
use crate::timeline::{self, Interpolator};
use crate::{Change, Platform, Shared};

use render::{Button, Gfx, Layout};

const WM_LYRICS_CHANGE: u32 = WM_APP + 0x31;
const TIMER_HOVER: usize = 1;
const TIMER_MOVE: usize = 2;
const CLASS_NAME: PCWSTR = w!("LekisDesktopLyrics");
/// 左右边缘多宽可以拖动改宽度（DIP）。
const RESIZE_EDGE_DIP: f32 = 8.0;

/// 窗口线程的句柄：只存 HWND 的整数值，跨线程 PostMessage 用。
pub(crate) struct WinPlatform {
    hwnd: AtomicIsize,
}

impl Platform for WinPlatform {
    fn notify(&self, change: Change) {
        let hwnd = HWND(self.hwnd.load(Ordering::Acquire) as *mut _);
        let code = change as usize;
        // 窗口线程退出后 PostMessage 会失败，忽略即可。
        let _ = unsafe { PostMessageW(Some(hwnd), WM_LYRICS_CHANGE, WPARAM(code), LPARAM(0)) };
    }
}

/// 启动窗口线程，等窗口建好后返回。
pub(crate) fn start(shared: Arc<Shared>) -> Result<WinPlatform, String> {
    let (tx, rx) = mpsc::channel::<Result<isize, String>>();
    std::thread::Builder::new()
        .name("lekis-desktop-lyrics".into())
        .spawn(move || thread_main(shared, tx))
        .map_err(|e| e.to_string())?;
    let hwnd = rx
        .recv_timeout(Duration::from_secs(5))
        .map_err(|_| "window thread did not start".to_string())??;
    Ok(WinPlatform {
        hwnd: AtomicIsize::new(hwnd),
    })
}

fn thread_main(shared: Arc<Shared>, tx: mpsc::Sender<Result<isize, String>>) {
    // 每显示器 DPI v2：只影响本线程创建的窗口，不动 Flutter 主窗口。
    unsafe {
        let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let win = match Win::create(shared) {
        Ok(w) => w,
        Err(e) => {
            let _ = tx.send(Err(e));
            return;
        }
    };
    let _ = tx.send(Ok(win.hwnd.0 as isize));
    let ptr = Box::into_raw(win);
    unsafe {
        SetWindowLongPtrW((*ptr).hwnd, GWLP_USERDATA, ptr as isize);
        // 创建时可能已经在等显示（Change::Visibility 发在 hwnd 可用之前）。
        (*ptr).on_change(Change::Visibility);
        run_loop(ptr);
        SetWindowLongPtrW((*ptr).hwnd, GWLP_USERDATA, 0);
        drop(Box::from_raw(ptr));
    }
}

unsafe fn run_loop(win: *mut Win) {
    let mut msg = MSG::default();
    let mut last_frame = Instant::now();
    loop {
        while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
            if msg.message == WM_QUIT {
                return;
            }
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        let w = unsafe { &mut *win };
        if w.visible {
            w.render(false);
        }
        if w.visible && w.animating {
            // 等合成器下一帧。DwmFlush 偶尔立即返回（没有可合成的变化），兜底限速。
            let start = Instant::now();
            if unsafe { DwmFlush() }.is_err() {
                std::thread::sleep(Duration::from_millis(16));
            }
            let since = last_frame.elapsed();
            if start.elapsed() < Duration::from_millis(2) && since < Duration::from_millis(7) {
                std::thread::sleep(Duration::from_millis(7) - since);
            }
            last_frame = Instant::now();
            continue;
        }
        let timeout = match (w.visible, w.next_wake) {
            (true, Some(at)) => {
                let ms = at.saturating_duration_since(Instant::now()).as_millis();
                u32::try_from(ms).unwrap_or(INFINITE_MS).max(1)
            }
            _ => INFINITE_MS,
        };
        unsafe {
            MsgWaitForMultipleObjectsEx(None, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        }
    }
}

const INFINITE_MS: u32 = u32::MAX;

struct Win {
    shared: Arc<Shared>,
    hwnd: HWND,
    dpi: u32,
    /// 当前窗口大小（物理像素）。
    size: (i32, i32),
    positioned: bool,
    placing: bool,
    visible: bool,
    locked: bool,
    hovered: bool,
    hover_button: Option<Button>,
    pressed: Option<Button>,
    /// 锁定时光标停在解锁按钮上：暂时去掉 WS_EX_TRANSPARENT 让它能点。
    lifted: bool,
    interp: Interpolator,
    gfx: Gfx,
    last_frame_key: u64,
    animating: bool,
    next_wake: Option<Instant>,
}

impl Win {
    fn create(shared: Arc<Shared>) -> Result<Box<Win>, String> {
        unsafe {
            let hinstance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
            let class = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(wndproc),
                hInstance: hinstance.into(),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                lpszClassName: CLASS_NAME,
                ..Default::default()
            };
            // 重复注册（比如线程重启）返回 0，忽略：类已经在。
            RegisterClassExW(&class);
            let ex = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            let hwnd = CreateWindowExW(
                ex,
                CLASS_NAME,
                w!("Lekis 桌面歌词"),
                WS_POPUP,
                0,
                0,
                640,
                120,
                None,
                None,
                Some(hinstance.into()),
                None,
            )
            .map_err(|e| e.to_string())?;
            let gfx = Gfx::new().map_err(|e| e.to_string())?;
            let dpi = GetDpiForWindow(hwnd).max(96);
            Ok(Box::new(Win {
                shared,
                hwnd,
                dpi,
                size: (640, 120),
                positioned: false,
                placing: false,
                visible: false,
                locked: false,
                hovered: false,
                hover_button: None,
                pressed: None,
                lifted: false,
                interp: Interpolator::default(),
                gfx,
                last_frame_key: 0,
                animating: false,
                next_wake: None,
            }))
        }
    }

    fn scale(&self) -> f32 {
        self.dpi as f32 / 96.0
    }

    fn layout(&self) -> Layout {
        let style = self.shared.state().style.clone();
        Layout::new(self.scale(), self.size.0, &style)
    }

    fn height_for(&self, scale: f32) -> i32 {
        let style = self.shared.state().style.clone();
        Layout::new(scale, 0, &style).height
    }

    fn on_change(&mut self, change: Change) {
        match change {
            Change::Visibility => {
                let want = self.shared.state().visible;
                if want && !self.visible {
                    if !self.positioned {
                        self.place();
                    }
                    self.visible = true;
                    self.locked = self.shared.state().locked;
                    self.apply_ex_style();
                    unsafe {
                        let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                        let _ = SetWindowPos(
                            self.hwnd,
                            Some(HWND_TOPMOST),
                            0,
                            0,
                            0,
                            0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                        );
                        SetTimer(Some(self.hwnd), TIMER_HOVER, 100, None);
                    }
                    self.render(true);
                } else if !want && self.visible {
                    self.visible = false;
                    self.animating = false;
                    self.hovered = false;
                    unsafe {
                        let _ = KillTimer(Some(self.hwnd), TIMER_HOVER);
                        let _ = ShowWindow(self.hwnd, SW_HIDE);
                    }
                    self.gfx.trim();
                }
            }
            Change::Lock => {
                self.locked = self.shared.state().locked;
                self.lifted = false;
                self.hover_button = None;
                self.apply_ex_style();
                self.render(true);
            }
            Change::Style => {
                self.gfx.clear_cache();
                self.fit_height();
                self.render(true);
            }
            Change::Lyrics | Change::Clock => self.render(true),
        }
    }

    /// 首次显示：按记住的位置（或主显示器底部居中）摆放。
    fn place(&mut self) {
        let monitors = enum_monitors();
        let placements = self.shared.state().placements.clone();
        let Some((i, rect)) = placements.resolve(&monitors, |s| self.height_for(s)) else {
            return;
        };
        self.placing = true;
        self.dpi = (monitors[i].scale * 96.0).round() as u32;
        self.move_to(rect);
        // 移到别的 DPI 的显示器后以窗口实际 DPI 为准再算一次高度。
        let real = unsafe { GetDpiForWindow(self.hwnd) };
        if real != 0 && real != self.dpi {
            self.dpi = real;
            self.fit_height();
        }
        self.placing = false;
        self.positioned = true;
    }

    fn move_to(&mut self, r: Rect) {
        self.size = (r.width(), r.height());
        unsafe {
            let _ = SetWindowPos(
                self.hwnd,
                Some(HWND_TOPMOST),
                r.left,
                r.top,
                r.width(),
                r.height(),
                SWP_NOACTIVATE,
            );
        }
    }

    /// 字号 / 两行开关 / DPI 变了：保持左上角和宽度，只改高度。
    fn fit_height(&mut self) {
        let h = self.layout().height;
        if h == self.size.1 {
            return;
        }
        self.size.1 = h;
        unsafe {
            let _ = SetWindowPos(
                self.hwnd,
                None,
                0,
                0,
                self.size.0,
                h,
                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
        self.clamp_to_work_area();
    }

    fn window_rect(&self) -> Rect {
        let mut r = RECT::default();
        unsafe {
            let _ = GetWindowRect(self.hwnd, &mut r);
        }
        Rect {
            left: r.left,
            top: r.top,
            right: r.right,
            bottom: r.bottom,
        }
    }

    fn current_monitor(&self) -> Option<Monitor> {
        let hmon = unsafe { MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONEAREST) };
        monitor_info(hmon)
    }

    fn clamp_to_work_area(&mut self) {
        let Some(m) = self.current_monitor() else {
            return;
        };
        let r = self.window_rect();
        let min_w = (placement::MIN_WIDTH_DIP * self.scale()).round() as i32;
        let c = placement::clamp(r, m.work, min_w);
        if c != r {
            self.move_to(c);
        }
    }

    fn save_placement(&mut self) {
        let Some(m) = self.current_monitor() else {
            return;
        };
        let rect = self.window_rect();
        let json = {
            let mut s = self.shared.state();
            s.placements.record(&m, rect);
            s.placements.to_json()
        };
        self.shared.emit(Event::PlacementChanged(json));
    }

    fn apply_ex_style(&self) {
        unsafe {
            let ex = GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE);
            let transparent = WS_EX_TRANSPARENT.0 as isize;
            let want = if self.locked && !self.lifted {
                ex | transparent
            } else {
                ex & !transparent
            };
            if want != ex {
                SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, want);
            }
        }
    }

    /// 窗口坐标（物理像素）。
    fn local_cursor(&self) -> Option<(i32, i32)> {
        let mut pt = POINT::default();
        unsafe { GetCursorPos(&mut pt) }.ok()?;
        let r = self.window_rect();
        r.contains(pt.x, pt.y)
            .then_some((pt.x - r.left, pt.y - r.top))
    }

    fn poll_hover(&mut self) {
        if !self.visible {
            return;
        }
        let cursor = self.local_cursor();
        let hovered = cursor.is_some();
        let layout = self.layout();
        let button = cursor.and_then(|(x, y)| layout.button_at(x as f32, y as f32, self.locked));
        if self.locked {
            let over_lock = button == Some(Button::Lock);
            if over_lock != self.lifted {
                self.lifted = over_lock;
                self.apply_ex_style();
            }
        }
        if hovered != self.hovered || button != self.hover_button {
            self.hovered = hovered;
            self.hover_button = button;
            if !hovered {
                self.pressed = None;
            }
            self.render(true);
        }
    }

    fn click(&mut self, button: Button) {
        match button {
            Button::Previous => self.shared.emit(Event::Control(Control::Previous)),
            Button::PlayPause => self.shared.emit(Event::Control(Control::PlayPause)),
            Button::Next => self.shared.emit(Event::Control(Control::Next)),
            Button::Lock => {
                let locked = !self.locked;
                self.shared.state().locked = locked;
                self.locked = locked;
                self.lifted = false;
                self.hover_button = None;
                self.apply_ex_style();
                self.render(true);
                self.shared.emit(Event::LockChanged(locked));
            }
            Button::Close => {
                self.shared.state().visible = false;
                self.on_change(Change::Visibility);
                self.shared.emit(Event::Closed);
            }
        }
    }

    /// 画一帧（内容没变时跳过）并安排下一次醒来。
    fn render(&mut self, force: bool) {
        if !self.visible {
            return;
        }
        let (style, doc, clock, elapsed) = {
            let s = self.shared.state();
            let elapsed = u64::try_from(s.clock_at.elapsed().as_millis()).unwrap_or(u64::MAX);
            (s.style.clone(), s.doc.clone(), s.clock, elapsed)
        };
        let position = self.interp.position(clock, elapsed);
        let view = timeline::view(doc.as_deref(), clock.track_id, position, style.two_line);
        self.animating = clock.playing && view.animating;
        self.next_wake = if clock.playing {
            view.next_change_in_ms
                .map(|ms| Instant::now() + Duration::from_millis(ms.saturating_add(5)))
        } else {
            None
        };

        let layout = Layout::new(self.scale(), self.size.0, &style);
        let ui = render::Ui {
            hovered: self.hovered,
            hover_button: self.hover_button,
            pressed: self.pressed,
            locked: self.locked,
            playing: clock.playing,
        };
        let key = render::frame_key(&view, &ui, &style, self.size, self.dpi);
        if !force && key == self.last_frame_key {
            return;
        }
        self.last_frame_key = key;
        let size = (self.size.0, layout.height.max(1));
        match self.gfx.draw(self.hwnd, size, &layout, &style, &view, &ui) {
            Ok(()) => {}
            Err(e) => tracing::debug!(target: "desktop_lyrics", "render failed: {e}"),
        }
    }

    fn handle(&mut self, msg: u32, wparam: WPARAM, lparam: LPARAM) -> Option<LRESULT> {
        match msg {
            WM_LYRICS_CHANGE => {
                let change = match wparam.0 {
                    x if x == Change::Visibility as usize => Change::Visibility,
                    x if x == Change::Lock as usize => Change::Lock,
                    x if x == Change::Style as usize => Change::Style,
                    x if x == Change::Lyrics as usize => Change::Lyrics,
                    _ => Change::Clock,
                };
                self.on_change(change);
                Some(LRESULT(0))
            }
            WM_MOUSEACTIVATE => Some(LRESULT(MA_NOACTIVATE as isize)),
            WM_NCHITTEST => {
                let x = (lparam.0 & 0xFFFF) as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
                let r = self.window_rect();
                let (lx, ly) = ((x - r.left) as f32, (y - r.top) as f32);
                let layout = self.layout();
                let hit = if self.locked {
                    match layout.button_at(lx, ly, true) {
                        Some(Button::Lock) if self.lifted => HTCLIENT,
                        _ => HTTRANSPARENT as u32,
                    }
                } else if layout.button_at(lx, ly, false).is_some() {
                    HTCLIENT
                } else {
                    let edge = RESIZE_EDGE_DIP * self.scale();
                    if lx < edge {
                        HTLEFT
                    } else if lx >= r.width() as f32 - edge {
                        HTRIGHT
                    } else {
                        HTCAPTION
                    }
                };
                Some(LRESULT(hit as i32 as isize))
            }
            WM_MOUSEMOVE | WM_NCMOUSEMOVE => {
                self.poll_hover();
                None
            }
            WM_LBUTTONDOWN => {
                let layout = self.layout();
                let (x, y) = client_point(lparam);
                self.pressed = layout.button_at(x, y, self.locked);
                self.render(true);
                Some(LRESULT(0))
            }
            WM_LBUTTONUP => {
                let layout = self.layout();
                let (x, y) = client_point(lparam);
                let up = layout.button_at(x, y, self.locked);
                let pressed = self.pressed.take();
                if let (Some(b), Some(p)) = (up, pressed) {
                    if b == p {
                        self.click(b);
                        return Some(LRESULT(0));
                    }
                }
                self.render(true);
                Some(LRESULT(0))
            }
            // 不要系统菜单、不要双击最大化。
            WM_NCRBUTTONDOWN | WM_NCRBUTTONUP | WM_NCLBUTTONDBLCLK | WM_CONTEXTMENU => {
                Some(LRESULT(0))
            }
            WM_TIMER => {
                match wparam.0 {
                    TIMER_HOVER => self.poll_hover(),
                    TIMER_MOVE => self.render(false),
                    _ => {}
                }
                Some(LRESULT(0))
            }
            WM_ENTERSIZEMOVE => {
                unsafe { SetTimer(Some(self.hwnd), TIMER_MOVE, 15, None) };
                None
            }
            WM_EXITSIZEMOVE => {
                unsafe {
                    let _ = KillTimer(Some(self.hwnd), TIMER_MOVE);
                }
                self.clamp_to_work_area();
                self.save_placement();
                None
            }
            WM_GETMINMAXINFO => {
                let info = lparam.0 as *mut MINMAXINFO;
                if !info.is_null() {
                    let h = self.layout().height;
                    let min_w = (placement::MIN_WIDTH_DIP * self.scale()).round() as i32;
                    unsafe {
                        (*info).ptMinTrackSize = POINT { x: min_w, y: h };
                        (*info).ptMaxTrackSize = POINT { x: 16_384, y: h };
                    }
                }
                Some(LRESULT(0))
            }
            WM_SIZING => {
                let r = lparam.0 as *mut RECT;
                if !r.is_null() {
                    let h = self.layout().height;
                    unsafe { (*r).bottom = (*r).top + h };
                }
                Some(LRESULT(1))
            }
            WM_WINDOWPOSCHANGED => {
                let wp = lparam.0 as *const WINDOWPOS;
                if !wp.is_null() {
                    let (cx, cy) = unsafe { ((*wp).cx, (*wp).cy) };
                    let flags = unsafe { (*wp).flags };
                    if !flags.contains(SWP_NOSIZE) && (cx, cy) != self.size && cx > 0 && cy > 0 {
                        self.size = (cx, cy);
                        self.render(true);
                    }
                }
                Some(LRESULT(0))
            }
            WM_DPICHANGED => {
                let new_dpi = (wparam.0 & 0xFFFF) as u32;
                if self.placing || new_dpi == 0 {
                    return Some(LRESULT(0));
                }
                let suggested = lparam.0 as *const RECT;
                let ratio = new_dpi as f32 / self.dpi.max(1) as f32;
                self.dpi = new_dpi;
                let width = (self.size.0 as f32 * ratio).round() as i32;
                let height = self.layout().height;
                let (left, top) = if suggested.is_null() {
                    let r = self.window_rect();
                    (r.left, r.top)
                } else {
                    unsafe { ((*suggested).left, (*suggested).top) }
                };
                self.gfx.clear_cache();
                self.move_to(Rect {
                    left,
                    top,
                    right: left + width,
                    bottom: top + height,
                });
                self.render(true);
                Some(LRESULT(0))
            }
            WM_DISPLAYCHANGE | WM_SETTINGCHANGE => {
                if self.visible {
                    self.clamp_to_work_area();
                }
                None
            }
            WM_CLOSE => {
                // Alt+F4 等：当作点了关闭按钮，不销毁窗口。
                self.click(Button::Close);
                Some(LRESULT(0))
            }
            _ => None,
        }
    }
}

fn client_point(lparam: LPARAM) -> (f32, f32) {
    let x = (lparam.0 & 0xFFFF) as i16 as f32;
    let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f32;
    (x, y)
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut Win;
    if !ptr.is_null() {
        // 只有窗口线程会进来；重入（SetWindowPos 里同步发 WM_WINDOWPOSCHANGED 等）
        // 时各处理分支都只做短小的状态更新。
        if let Some(r) = unsafe { (*ptr).handle(msg, wparam, lparam) } {
            return r;
        }
    }
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

fn monitor_info(hmon: HMONITOR) -> Option<Monitor> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    let ok = unsafe { GetMonitorInfoW(hmon, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) };
    if !ok.as_bool() {
        return None;
    }
    let mi = info.monitorInfo;
    let len = info
        .szDevice
        .iter()
        .position(|&c| c == 0)
        .unwrap_or(info.szDevice.len());
    let device = String::from_utf16_lossy(&info.szDevice[..len]);
    let key = format!(
        "{device}@{}x{}",
        mi.rcMonitor.right - mi.rcMonitor.left,
        mi.rcMonitor.bottom - mi.rcMonitor.top
    );
    let (mut dx, mut dy) = (96u32, 96u32);
    let _ = unsafe { GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy) };
    Some(Monitor {
        key,
        work: Rect {
            left: mi.rcWork.left,
            top: mi.rcWork.top,
            right: mi.rcWork.right,
            bottom: mi.rcWork.bottom,
        },
        scale: dx.max(48) as f32 / 96.0,
        primary: mi.dwFlags & MONITORINFOF_PRIMARY != 0,
    })
}

fn enum_monitors() -> Vec<Monitor> {
    unsafe extern "system" fn cb(hmon: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let out = unsafe { &mut *(data.0 as *mut Vec<Monitor>) };
        if let Some(m) = monitor_info(hmon) {
            out.push(m);
        }
        BOOL(1)
    }
    let mut out: Vec<Monitor> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(
            None,
            None,
            Some(cb),
            LPARAM(&mut out as *mut Vec<Monitor> as isize),
        );
    }
    out
}

/// 调试 / 测试：窗口句柄（截图验证用）。
#[allow(dead_code)]
pub(crate) fn find_window() -> Option<isize> {
    unsafe { FindWindowW(CLASS_NAME, None) }
        .ok()
        .map(|h| h.0 as isize)
}
