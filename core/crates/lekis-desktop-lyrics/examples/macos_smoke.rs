//! Real AppKit smoke app: `cargo run -p lekis-desktop-lyrics --example macos_smoke`.
//! Pass `--verify /absolute/report.json` for automated native window assertions and exit.
#![allow(clippy::expect_used, clippy::panic)]

#[cfg(target_os = "macos")]
fn main() {
    use lekis_desktop_lyrics::{
        Clock, Control, DesktopLyrics, Event, Line, LyricsDoc, Style, Word,
    };
    use serde_json::Value;
    use std::ffi::{c_char, CStr};
    use std::sync::{mpsc, Arc};
    use std::time::{Duration, Instant};

    unsafe extern "C" {
        fn lekis_lyrics_macos_run_application();
        fn lekis_lyrics_macos_diagnostics() -> *mut c_char;
        fn lekis_lyrics_macos_free_diagnostics(text: *mut c_char);
        fn lekis_lyrics_macos_smoke_hover(hovering: bool);
        fn lekis_lyrics_macos_smoke_menu_action(index: usize);
    }
    fn snapshot() -> Value {
        // The Swift diagnostic routine safely hops onto the AppKit main thread.
        unsafe {
            let text = lekis_lyrics_macos_diagnostics();
            assert!(!text.is_null(), "native diagnostics unavailable");
            let value =
                serde_json::from_slice(CStr::from_ptr(text).to_bytes()).expect("native JSON");
            lekis_lyrics_macos_free_diagnostics(text);
            value
        }
    }
    let verify_path = std::env::args().skip_while(|arg| arg != "--verify").nth(1);
    let controller = DesktopLyrics::global();
    let (commands, receiver) = mpsc::channel();
    controller.set_event_handler(Arc::new(move |event| {
        if event == Event::Closed && verify_path.is_none() {
            std::process::exit(0);
        }
        if let Event::Control(control) = event {
            let _ = commands.send(control);
        }
    }));
    let verify_path = std::env::args().skip_while(|arg| arg != "--verify").nth(1);
    let make_doc = || LyricsDoc {
        track_id: Some(1),
        title: "月光电台".into(),
        artist: "Lekis 演示".into(),
        synced: true,
        lines: [
            (
                0,
                "晚风轻轻吹过窗前",
                "The evening breeze slips past the window",
            ),
            (
                4500,
                "远处的灯还为你亮着",
                "A distant light is still waiting for you",
            ),
            (
                9000,
                "把今天的心事慢慢放下",
                "Let the weight of today drift away",
            ),
            (
                13500,
                "让一首歌陪你走回家",
                "Let a song keep you company on your way home",
            ),
        ]
        .into_iter()
        .map(|(start, text, translation)| {
            let chars: Vec<_> = text.chars().collect();
            let count = chars.len().max(1) as u32;
            Line {
                start_ms: start,
                text: text.into(),
                translation: Some(translation.into()),
                words: chars
                    .into_iter()
                    .enumerate()
                    .map(|(index, ch)| Word {
                        start_ms: start + index as u32 * 4000 / count,
                        end_ms: start + (index as u32 + 1) * 4000 / count,
                        text: ch.to_string(),
                    })
                    .collect(),
            }
        })
        .collect(),
    };
    controller.set_style(Style {
        sung_color: 0xFFFFFFFF,
        unsung_color: 0xA6FFFFFF,
        font_size: 26.0,
        bold: false,
        ..Style::default()
    });
    controller.set_lyrics(make_doc());
    controller.set_clock(Clock {
        track_id: Some(1),
        playing: true,
        position_ms: 0,
    });
    // Updating the state must stay safe without an AppKit run loop until the user shows lyrics.
    let before_show = snapshot();
    assert_eq!(before_show["created"], false);
    assert!(controller.set_menu_bar_visible(true));
    assert!(controller.show());

    std::thread::spawn(move || {
        if let Some(path) = verify_path {
            let result = std::panic::catch_unwind(|| {
                std::thread::sleep(Duration::from_millis(350));
                let visible = snapshot();
                assert_eq!(visible["visible"], true);
                assert_eq!(visible["bodyBackgroundAlpha"], 1);
                assert_eq!(visible["bodyBackgroundColor"], "#202022");
                assert_eq!(visible["windowAlpha"], 1);
                assert_eq!(visible["level"], visible["floatingLevel"]);
                assert_eq!(visible["canBecomeKey"], false);
                assert_eq!(visible["allSpaces"], true);
                assert_eq!(visible["fullScreenAuxiliary"], true);
                assert_eq!(visible["primary"], "晚风轻轻吹过窗前");
                assert_eq!(visible["menuBarVisible"], true);
                assert_eq!(visible["menuBarText"], visible["primary"]);
                assert!(visible["menuBarWidth"].as_f64().expect("menu width") <= 240.0);

                controller.set_locked(true);
                std::thread::sleep(Duration::from_millis(160));
                let locked = snapshot();
                assert_eq!(locked["locked"], true);
                assert_eq!(
                    locked["ignoresMouseEvents"],
                    !locked["unlockHovered"].as_bool().expect("unlock hover")
                );
                controller.set_locked(false);
                std::thread::sleep(Duration::from_millis(100));
                let unlocked = snapshot();
                assert_eq!(unlocked["ignoresMouseEvents"], false);

                controller.set_clock(Clock {
                    track_id: Some(1),
                    playing: false,
                    position_ms: 5000,
                });
                std::thread::sleep(Duration::from_millis(100));
                let seek = snapshot();
                assert_eq!(seek["primary"], "远处的灯还为你亮着");
                unsafe {
                    lekis_lyrics_macos_smoke_hover(false);
                }
                std::thread::sleep(Duration::from_millis(100));
                let paused = snapshot();
                std::thread::sleep(Duration::from_millis(150));
                assert_eq!(snapshot()["drawCount"], paused["drawCount"]);
                unsafe {
                    lekis_lyrics_macos_smoke_hover(true);
                }
                std::thread::sleep(Duration::from_millis(100));
                let hovered = snapshot();
                assert_eq!(hovered["toolbarVisible"], true);
                assert!(
                    hovered["height"].as_f64().expect("height")
                        > paused["height"].as_f64().expect("height")
                );
                assert!(
                    (hovered["lyricsTopScreenY"].as_f64().expect("position")
                        - paused["lyricsTopScreenY"].as_f64().expect("position"))
                    .abs()
                        < 0.5
                );
                unsafe {
                    lekis_lyrics_macos_smoke_hover(false);
                }
                std::thread::sleep(Duration::from_millis(100));
                assert_eq!(snapshot()["height"], paused["height"]);
                let style = Style {
                    two_line: false,
                    font_size: 48.0,
                    opacity: 0.4,
                    ..Style::default()
                };
                controller.set_style(style);
                std::thread::sleep(Duration::from_millis(100));
                let styled = snapshot();
                assert_eq!(styled["secondary"], Value::Null);
                assert!(
                    (styled["windowAlpha"].as_f64().expect("window alpha") - 0.4).abs() < 0.001
                );
                controller.hide();
                std::thread::sleep(Duration::from_millis(100));
                let hidden = snapshot();
                assert_eq!(hidden["visible"], false);
                assert_eq!(hidden["menuBarVisible"], true);
                controller.set_clock(Clock {
                    track_id: Some(1),
                    playing: false,
                    position_ms: 10_000,
                });
                std::thread::sleep(Duration::from_millis(100));
                assert_eq!(snapshot()["menuBarText"], "把今天的心事慢慢放下");
                assert!(!controller.set_menu_bar_visible(false));
                std::thread::sleep(Duration::from_millis(100));
                assert_eq!(snapshot()["menuBarVisible"], false);
                assert!(controller.show());
                std::thread::sleep(Duration::from_millis(100));
                let reopened = snapshot();
                assert_eq!(reopened["visible"], true);
                assert_eq!(reopened["menuBarVisible"], false);
                assert_eq!(reopened["windowNumber"], visible["windowNumber"]);
                controller.set_clock(Clock {
                    track_id: Some(2),
                    playing: false,
                    position_ms: 0,
                });
                std::thread::sleep(Duration::from_millis(100));
                let stale = snapshot();
                assert_eq!(stale["primary"], "Lekis 桌面歌词");
                controller.set_lyrics(LyricsDoc {
                    track_id: Some(2),
                    title: "Moonlight Radio".into(),
                    artist: "Lekis".into(),
                    synced: false,
                    lines: vec![],
                });
                controller.set_menu_bar_visible(true);
                std::thread::sleep(Duration::from_millis(100));
                let fallback = snapshot();
                assert_eq!(fallback["menuBarText"], "Moonlight Radio");
                let menu_action = |index| {
                    unsafe {
                        lekis_lyrics_macos_smoke_menu_action(index);
                    }
                    std::thread::sleep(Duration::from_millis(100));
                };
                menu_action(0);
                assert_eq!(
                    receiver.try_recv().expect("native play/pause"),
                    Control::PlayPause
                );
                menu_action(1);
                assert_eq!(
                    receiver.try_recv().expect("native previous"),
                    Control::Previous
                );
                menu_action(2);
                assert_eq!(receiver.try_recv().expect("native next"), Control::Next);
                menu_action(4);
                assert!(!controller.is_visible());
                assert!(controller.is_menu_bar_visible());
                menu_action(4);
                assert!(controller.is_visible());
                menu_action(5);
                assert!(controller.is_locked());
                menu_action(5);
                assert!(!controller.is_locked());
                menu_action(7);
                assert!(!controller.is_menu_bar_visible());
                assert!(controller.is_visible());
                controller.set_menu_bar_visible(true);
                std::thread::sleep(Duration::from_millis(100));
                menu_action(8);
                assert!(!controller.is_visible());
                assert!(!controller.is_menu_bar_visible());
                serde_json::json!({"status":"passed","assertions":49,"nativeMenuActions":"NSMenu.performActionForItem -> actual Swift targets -> Rust callbacks/state", "pausedHover":hovered,"fallbackTitle":fallback,"beforeShow":before_show,"visible":visible,"locked":locked,
                    "unlocked":unlocked,"seek":seek,"styled":styled,"staleTrack":stale,
                    "scope":"actual Rust timeline/state -> Swift/AppKit NSPanel; full Flutter mac.app not built"})
            });
            let (report, code) = match result {
                Ok(report) => (report, 0),
                Err(_) => (serde_json::json!({"status":"failed"}), 1),
            };
            std::fs::write(
                path,
                serde_json::to_vec_pretty(&report).expect("serialize report"),
            )
            .expect("write report");
            std::process::exit(code);
        }
        let mut sampled_at = Instant::now();
        let mut sampled_position = 0_u64;
        let mut playing = true;
        loop {
            let elapsed = if playing {
                sampled_at.elapsed().as_millis() as u64
            } else {
                0
            };
            let position = (sampled_position + elapsed) % 18_000;
            if let Ok(command) = receiver.try_recv() {
                sampled_position = match command {
                    Control::Previous => (position / 4500).saturating_sub(1) * 4500,
                    Control::Next => ((position / 4500 + 1) * 4500) % 18_000,
                    Control::PlayPause => {
                        playing = !playing;
                        position
                    }
                };
                sampled_at = Instant::now();
                continue;
            }
            controller.set_clock(Clock {
                track_id: Some(1),
                playing,
                position_ms: position,
            });
            std::thread::sleep(Duration::from_millis(200));
        }
    });
    // AppKit owns the actual main thread; the Rust timing worker never creates NSWindow objects.
    unsafe {
        lekis_lyrics_macos_run_application();
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("The AppKit lyrics smoke app requires macOS.");
}
