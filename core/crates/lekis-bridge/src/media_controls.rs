//! 系统媒体控件（Windows SMTC / macOS Now Playing / Linux MPRIS），用 souvlaki 实现。
//!
//! 放在 `api` 之外，frb 不会导出这里的类型。Android / iOS 走 Dart 侧的 audio_service，
//! 这里在那些平台上是空实现。
//!
//! 线程模型：一个专用线程拥有 `MediaControls`，核心事件通过 channel 送过来；
//! 系统按钮回调（WinRT 线程池 / D-Bus 线程 / 主线程）直接调用核心的播放控制函数。
//!
//! `frb_expand`：codegen 解析 `cargo expand` 的输出时解析不了这里展开后的代码，
//! 而这里本来也没有要导出的东西，所以 codegen 时只留下空实现。

#[cfg(all(not(frb_expand), any(target_os = "windows", target_os = "macos", target_os = "linux")))]
mod desktop {
    use std::future::Future;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{Arc, Mutex};
    use std::task::{Context, Poll, Wake, Waker};
    use std::time::{Duration, Instant};

    use lekis_types::{CoreEvent, PlaybackState, TrackId};
    use souvlaki::{
        MediaControlEvent, MediaControls, MediaMetadata, MediaPlayback, MediaPosition,
        PlatformConfig, SeekDirection,
    };

    use crate::internal::core;

    /// 无方向的快进 / 快退（媒体键、SMTC 的 FastForward/Rewind）跳多少。
    const SEEK_STEP_MS: u64 = 10_000;
    /// 播放中位置同步给系统的最小间隔。
    const POSITION_THROTTLE: Duration = Duration::from_secs(1);

    static STARTED: AtomicBool = AtomicBool::new(false);

    enum Msg {
        Playback {
            state: PlaybackState,
            track_id: Option<TrackId>,
            position_ms: u64,
            duration_ms: u64,
        },
        Tick {
            position_ms: u64,
        },
    }

    struct ChannelListener(Mutex<Sender<Msg>>);

    impl lekis_core::EventListener for ChannelListener {
        fn on_event(&self, event: CoreEvent) {
            let msg = match event {
                CoreEvent::PlaybackChanged {
                    state,
                    track_id,
                    position_ms,
                    duration_ms,
                } => Msg::Playback {
                    state,
                    track_id,
                    position_ms,
                    duration_ms,
                },
                CoreEvent::PositionTick { position_ms, .. } => Msg::Tick { position_ms },
                _ => return,
            };
            if let Ok(tx) = self.0.lock() {
                let _ = tx.send(msg);
            }
        }
    }

    /// 启动媒体控件线程。重复调用只启动一次。调用方保证核心已初始化。
    pub(crate) fn enable() -> bool {
        if STARTED.swap(true, Ordering::SeqCst) {
            return true;
        }
        let (tx, rx) = mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("lekis-media-controls".into())
            .spawn(move || {
                if let Err(e) = run(tx, rx) {
                    tracing::warn!(target: "media_controls", "system media controls unavailable: {e}");
                }
            });
        if spawned.is_err() {
            STARTED.store(false, Ordering::SeqCst);
            return false;
        }
        true
    }

    fn run(tx: Sender<Msg>, rx: Receiver<Msg>) -> Result<(), String> {
        #[cfg(target_os = "windows")]
        win::init_winrt();

        #[cfg(target_os = "windows")]
        let hwnd = Some(win::find_flutter_window().ok_or("Flutter window not found")?);
        #[cfg(not(target_os = "windows"))]
        let hwnd = None;

        let config = PlatformConfig {
            display_name: "Lekis",
            dbus_name: "lekis",
            hwnd,
        };
        let mut controls = MediaControls::new(config).map_err(|e| format!("{e:?}"))?;
        controls
            .attach(handle_control_event)
            .map_err(|e| format!("{e:?}"))?;

        // 先按当前快照同步一次，再开始收事件。
        let snap = core().playback_snapshot();
        let mut state = Mirror::default();
        state.apply_playback(
            &mut controls,
            snap.state,
            snap.track_id,
            snap.position_ms,
            snap.duration_ms,
        );
        #[cfg(target_os = "linux")]
        let _ = controls.set_volume(f64::from(snap.volume));

        core().add_listener(Arc::new(ChannelListener(Mutex::new(tx))));

        while let Ok(msg) = rx.recv() {
            match msg {
                Msg::Playback {
                    state: s,
                    track_id,
                    position_ms,
                    duration_ms,
                } => state.apply_playback(&mut controls, s, track_id, position_ms, duration_ms),
                Msg::Tick { position_ms } => state.apply_tick(&mut controls, position_ms),
            }
        }
        Ok(())
    }

    /// 系统那边当前显示的状态（避免重复推送）。
    #[derive(Default)]
    struct Mirror {
        track_id: Option<TrackId>,
        duration_ms: u64,
        playing: bool,
        position_ms: u64,
        last_position_push: Option<Instant>,
    }

    impl Mirror {
        fn apply_playback(
            &mut self,
            controls: &mut MediaControls,
            state: PlaybackState,
            track_id: Option<TrackId>,
            position_ms: u64,
            duration_ms: u64,
        ) {
            if track_id != self.track_id || (duration_ms != self.duration_ms && duration_ms > 0) {
                self.track_id = track_id;
                self.duration_ms = duration_ms;
                push_metadata(controls, track_id, duration_ms);
            }
            self.playing = matches!(
                state,
                PlaybackState::Playing | PlaybackState::Buffering | PlaybackState::Loading
            );
            self.position_ms = position_ms;
            self.last_position_push = Some(Instant::now());
            let progress = Some(MediaPosition(Duration::from_millis(position_ms)));
            let playback = match state {
                PlaybackState::Idle | PlaybackState::Ended if track_id.is_none() => {
                    MediaPlayback::Stopped
                }
                PlaybackState::Idle | PlaybackState::Ended | PlaybackState::Paused => {
                    MediaPlayback::Paused { progress }
                }
                PlaybackState::Playing | PlaybackState::Buffering | PlaybackState::Loading => {
                    MediaPlayback::Playing { progress }
                }
            };
            if let Err(e) = controls.set_playback(playback) {
                tracing::debug!(target: "media_controls", "set_playback failed: {e:?}");
            }
        }

        fn apply_tick(&mut self, controls: &mut MediaControls, position_ms: u64) {
            self.position_ms = position_ms;
            if !self.playing {
                return;
            }
            let due = self
                .last_position_push
                .is_none_or(|t| t.elapsed() >= POSITION_THROTTLE);
            if !due {
                return;
            }
            self.last_position_push = Some(Instant::now());
            let progress = Some(MediaPosition(Duration::from_millis(position_ms)));
            let _ = controls.set_playback(MediaPlayback::Playing { progress });
        }
    }

    fn push_metadata(controls: &mut MediaControls, track_id: Option<TrackId>, duration_ms: u64) {
        let Some(id) = track_id else {
            let _ = controls.set_metadata(MediaMetadata::default());
            return;
        };
        let track = block_on(core().get_track(id)).ok();
        let cover = block_on(core().artwork(id))
            .ok()
            .flatten()
            .map(|row| core().artwork_path(row.hash, 512))
            .filter(|p| std::path::Path::new(p).exists())
            .map(|p| file_url(&p));

        let (title, artist, album, track_ms) = match &track {
            Some(t) => {
                let overlay = t.overlay.as_ref();
                let title = overlay
                    .and_then(|o| o.title.clone())
                    .unwrap_or_else(|| t.title.clone());
                let artist = overlay
                    .and_then(|o| o.artists.clone())
                    .unwrap_or_else(|| t.artists.iter().map(|a| a.name.clone()).collect())
                    .join(", ");
                let album = overlay
                    .and_then(|o| o.album_title.clone())
                    .or_else(|| t.album_title.clone());
                (Some(title), Some(artist), album, t.duration_ms)
            }
            None => (None, None, None, 0),
        };
        let ms = if duration_ms > 0 { duration_ms } else { track_ms };
        let metadata = MediaMetadata {
            title: title.as_deref(),
            artist: artist.as_deref().filter(|s| !s.is_empty()),
            album: album.as_deref(),
            cover_url: cover.as_deref(),
            duration: (ms > 0).then(|| Duration::from_millis(ms)),
        };
        if let Err(e) = controls.set_metadata(metadata) {
            tracing::debug!(target: "media_controls", "set_metadata failed: {e:?}");
        }
    }

    /// souvlaki 在 Windows 上把 `file://` 后面的部分原样当路径用，所以不要转义；
    /// MPRIS / macOS 用标准的 `file:///abs/path`。
    fn file_url(path: &str) -> String {
        #[cfg(target_os = "windows")]
        {
            format!("file://{path}")
        }
        #[cfg(not(target_os = "windows"))]
        {
            url_escape(path)
        }
    }

    #[cfg(not(target_os = "windows"))]
    fn url_escape(path: &str) -> String {
        let mut out = String::from("file://");
        for b in path.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char)
                }
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    }

    fn handle_control_event(event: MediaControlEvent) {
        let c = core();
        let result = match event {
            MediaControlEvent::Play => c.play(),
            MediaControlEvent::Pause | MediaControlEvent::Stop => c.pause(),
            MediaControlEvent::Toggle => match c.playback_snapshot().state {
                PlaybackState::Playing | PlaybackState::Buffering | PlaybackState::Loading => {
                    c.pause()
                }
                _ => c.play(),
            },
            MediaControlEvent::Next => c.next(),
            MediaControlEvent::Previous => c.previous(),
            MediaControlEvent::Seek(dir) => seek_by(dir, SEEK_STEP_MS),
            MediaControlEvent::SeekBy(dir, d) => {
                seek_by(dir, u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
            }
            MediaControlEvent::SetPosition(MediaPosition(d)) => {
                c.seek(u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
            }
            MediaControlEvent::SetVolume(v) => c.set_volume(v.clamp(0.0, 1.0) as f32),
            _ => Ok(()),
        };
        if let Err(e) = result {
            tracing::debug!(target: "media_controls", "control event failed: {e}");
        }
    }

    fn seek_by(dir: SeekDirection, step_ms: u64) -> lekis_types::Result<()> {
        let snap = core().playback_snapshot();
        let target = match dir {
            SeekDirection::Forward => {
                let t = snap.position_ms.saturating_add(step_ms);
                if snap.duration_ms > 0 {
                    t.min(snap.duration_ms)
                } else {
                    t
                }
            }
            SeekDirection::Backward => snap.position_ms.saturating_sub(step_ms),
        };
        core().seek(target)
    }

    /// 最小的 block_on：核心的 async 方法内部已经把工作丢到核心运行时上，
    /// 这里只需要等结果，不需要再起一个运行时。
    fn block_on<F: Future>(fut: F) -> F::Output {
        struct ThreadWaker(std::thread::Thread);
        impl Wake for ThreadWaker {
            fn wake(self: Arc<Self>) {
                self.0.unpark();
            }
        }
        let waker = Waker::from(Arc::new(ThreadWaker(std::thread::current())));
        let mut cx = Context::from_waker(&waker);
        let mut fut = std::pin::pin!(fut);
        loop {
            if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
                return v;
            }
            std::thread::park();
        }
    }

    #[cfg(target_os = "windows")]
    mod win {
        use std::ffi::c_void;

        use windows::core::BOOL;
        use windows::Win32::Foundation::{HWND, LPARAM};
        use windows::Win32::System::Threading::GetCurrentProcessId;
        use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};
        use windows::Win32::UI::WindowsAndMessaging::{
            EnumWindows, GetClassNameW, GetWindowThreadProcessId,
        };

        const FLUTTER_CLASS: &str = "FLUTTER_RUNNER_WIN32_WINDOW";

        /// SMTC 是 WinRT API，这个线程要先加入 MTA。已初始化（S_FALSE / RPC_E_CHANGED_MODE）都无妨。
        pub(super) fn init_winrt() {
            let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
        }

        /// 找本进程的 Flutter 顶层窗口。Dart 启动时窗口通常已经建好，保险起见重试几秒。
        pub(super) fn find_flutter_window() -> Option<*mut c_void> {
            for _ in 0..50 {
                if let Some(h) = enumerate() {
                    return Some(h);
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            None
        }

        fn enumerate() -> Option<*mut c_void> {
            let mut found: HWND = HWND::default();
            unsafe {
                let _ = EnumWindows(
                    Some(enum_proc),
                    LPARAM(&mut found as *mut HWND as isize),
                );
            }
            (!found.0.is_null()).then_some(found.0)
        }

        unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
            let mut pid = 0u32;
            unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
            if pid != unsafe { GetCurrentProcessId() } {
                return BOOL(1);
            }
            let mut buf = [0u16; 64];
            let len = unsafe { GetClassNameW(hwnd, &mut buf) };
            let len = usize::try_from(len).unwrap_or(0);
            if String::from_utf16_lossy(&buf[..len]) == FLUTTER_CLASS {
                unsafe { *(lparam.0 as *mut HWND) = hwnd };
                return BOOL(0);
            }
            BOOL(1)
        }
    }
}

#[cfg(all(not(frb_expand), any(target_os = "windows", target_os = "macos", target_os = "linux")))]
pub(crate) use desktop::enable;

/// 移动端由 Dart 侧（audio_service）负责，这里什么都不做。
#[cfg(any(frb_expand, not(any(target_os = "windows", target_os = "macos", target_os = "linux"))))]
pub(crate) fn enable() -> bool {
    false
}
