//! macOS: Rust owns timing/state; AppKit objects live exclusively on the main queue.

use crate::{
    timeline::{self, Fill, Interpolator},
    Change, Control, Event, Platform, Shared,
};
use serde_json::{json, Value};
use std::ffi::{c_char, c_void, CStr};
use std::sync::{mpsc, Arc};
use std::time::Duration;

unsafe extern "C" {
    fn lekis_lyrics_macos_frame(
        bytes: *const u8,
        length: usize,
        context: *const c_void,
        callback: extern "C" fn(*const c_void, *const c_char),
    );
}

struct Context {
    shared: Arc<Shared>,
    sender: mpsc::Sender<Change>,
}

pub(crate) struct MacPlatform {
    sender: mpsc::Sender<Change>,
}

impl Platform for MacPlatform {
    fn notify(&self, change: Change) {
        let _ = self.sender.send(change);
    }
}

pub(crate) fn start(shared: Arc<Shared>) -> Result<MacPlatform, String> {
    let (sender, receiver) = mpsc::channel();
    let context = Arc::new(Context {
        shared,
        sender: sender.clone(),
    });
    std::thread::Builder::new()
        .name("lekis-macos-lyrics".into())
        .spawn(move || run(context, receiver))
        .map_err(|error| error.to_string())?;
    Ok(MacPlatform { sender })
}

fn run(context: Arc<Context>, receiver: mpsc::Receiver<Change>) {
    let mut interpolator = Interpolator::default();
    loop {
        let (frame, wait) = {
            let state = context.shared.state();
            let elapsed = u64::try_from(state.clock_at.elapsed().as_millis()).unwrap_or(u64::MAX);
            let position = interpolator.position(state.clock, elapsed);
            let view = timeline::view(
                state.doc.as_deref(),
                state.clock.track_id,
                position,
                state.style.two_line,
            );
            let fill = match view.fill {
                Fill::Nothing => json!({"kind":"nothing"}),
                Fill::All => json!({"kind":"all"}),
                Fill::Partial { word, fraction } => {
                    json!({"kind":"partial","word":word,"fraction":fraction})
                }
            };
            let style = &state.style;
            let frame = json!({
                "visible":state.visible, "menuBarVisible":state.menu_bar_visible,
                "locked":state.locked, "playing":state.clock.playing,
                "primary":view.primary, "secondary":view.secondary,
                "menuBarText": if view.kind == timeline::PrimaryKind::Idle { "Lekis" } else { view.primary },
                "words":view.words.iter().map(|word| &word.text).collect::<Vec<_>>(), "fill":fill,
                "style":{"fontSize":style.font_size,"fontFamily":style.font_family,"bold":style.bold,
                    "sungColor":style.sung_color,"unsungColor":style.unsung_color,"outlineColor":style.outline_color,
                    "opacity":style.opacity,"twoLine":style.two_line},
                "placements":state.placements,
            });
            let wait = if (!state.visible && !state.menu_bar_visible) || !state.clock.playing {
                None
            } else if state.visible && view.animating {
                Some(Duration::from_millis(16))
            } else {
                view.next_change_in_ms
                    .map(|ms| Duration::from_millis(ms.saturating_add(1).max(1)))
            };
            (frame.to_string(), wait)
        };
        // Swift copies the UTF-8 bytes before scheduling its main-queue block. The context stays
        // owned by this process-lifetime singleton worker; no AppKit object crosses threads.
        unsafe {
            lekis_lyrics_macos_frame(
                frame.as_ptr(),
                frame.len(),
                Arc::as_ptr(&context).cast(),
                on_event,
            );
        }
        let message = match wait {
            Some(duration) => match receiver.recv_timeout(duration) {
                Ok(change) => Some(change),
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => receiver.recv().ok(),
        };
        if message.is_none() {
            break;
        }
        // Coalesce fast lyric/clock/style updates instead of queuing obsolete UI frames.
        while receiver.try_recv().is_ok() {}
    }
}

extern "C" fn on_event(context: *const c_void, text: *const c_char) {
    if context.is_null() || text.is_null() {
        return;
    }
    // SAFETY: Swift calls with our retained context and a temporary NUL-terminated UTF-8 string.
    let context = unsafe { &*context.cast::<Context>() };
    let Ok(value) = serde_json::from_slice::<Value>(unsafe { CStr::from_ptr(text) }.to_bytes())
    else {
        return;
    };
    let event = match value["event"].as_str() {
        Some("visibility") => value["visible"].as_bool().map(|visible| {
            context.shared.state().visible = visible;
            Event::VisibilityChanged(visible)
        }),
        Some("menuBarClosed") => {
            context.shared.state().menu_bar_visible = false;
            Some(Event::MenuBarClosed)
        }
        Some("closed") => {
            context.shared.state().visible = false;
            Some(Event::Closed)
        }
        Some("lock") => value["locked"].as_bool().map(|locked| {
            context.shared.state().locked = locked;
            Event::LockChanged(locked)
        }),
        Some("control") => match value["action"].as_str() {
            Some("previous") => Some(Event::Control(Control::Previous)),
            Some("playPause") => Some(Event::Control(Control::PlayPause)),
            Some("next") => Some(Event::Control(Control::Next)),
            _ => None,
        },
        Some("placement") => serde_json::from_value(value["placements"].clone())
            .ok()
            .map(|placements| {
                context.shared.state().placements = placements;
                Event::PlacementChanged(context.shared.state().placements.to_json())
            }),
        _ => None,
    };
    if let Some(event) = event {
        context.shared.emit(event);
    }
    let _ = context.sender.send(Change::Visibility);
}
