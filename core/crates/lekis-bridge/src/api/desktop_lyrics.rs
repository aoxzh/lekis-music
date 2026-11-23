//! 桌面悬浮歌词桥接（UIX-07）。
//!
//! 直接转发到 [`lekis_desktop_lyrics::DesktopLyrics`] 单例；Windows 原生窗口由
//! Rust 线程持有，macOS NSPanel 在主线程；Android / iOS 等平台安全降级为 no-op。

use std::sync::Arc;

use flutter_rust_bridge::frb;
use lekis_desktop_lyrics::{Clock, Control, DesktopLyrics, Event, Line, LyricsDoc, Style, Word};

use crate::frb_generated::StreamSink;

/// 一行歌词里的一个字 / 词（增强 LRC）。
#[derive(Debug, Clone)]
pub struct DesktopLyricsWordDto {
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
}

/// 一行同步歌词。
#[derive(Debug, Clone)]
pub struct DesktopLyricsLineDto {
    pub start_ms: u32,
    pub text: String,
    pub translation: Option<String>,
    pub words: Vec<DesktopLyricsWordDto>,
}

/// 推送给悬浮窗的整首歌词文档。
#[derive(Debug, Clone)]
pub struct DesktopLyricsDocDto {
    pub track_id: Option<i64>,
    pub title: String,
    pub artist: String,
    pub synced: bool,
    pub lines: Vec<DesktopLyricsLineDto>,
}

/// 悬浮窗外观设置（颜色为 `0xAARRGGBB`）。
#[derive(Debug, Clone)]
pub struct DesktopLyricsStyleDto {
    pub font_size: f32,
    pub font_family: String,
    pub bold: bool,
    pub sung_color: u32,
    pub unsung_color: u32,
    pub outline_color: u32,
    pub opacity: f32,
    pub two_line: bool,
}

/// 悬浮窗播放时钟采样。
#[derive(Debug, Clone)]
pub struct DesktopLyricsClockDto {
    pub track_id: Option<i64>,
    pub playing: bool,
    pub position_ms: u64,
}

/// 悬浮窗工具栏上的播放控制动作。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesktopLyricsControlDto {
    Previous,
    PlayPause,
    Next,
}

/// 悬浮窗发回 Flutter 的事件。
#[derive(Debug, Clone)]
pub enum DesktopLyricsEventDto {
    Closed,
    VisibilityChanged { visible: bool },
    MenuBarClosed,
    LockChanged { locked: bool },
    Control { action: DesktopLyricsControlDto },
    PlacementChanged { json: String },
}

/// 当前平台是否支持桌面悬浮歌词。
#[frb(sync)]
pub fn desktop_lyrics_is_supported() -> bool {
    DesktopLyrics::is_supported()
}

/// 当前平台是否支持菜单栏歌词（macOS）。
#[frb(sync)]
pub fn desktop_lyrics_is_menu_bar_supported() -> bool {
    DesktopLyrics::is_menu_bar_supported()
}

/// 独立设置菜单栏歌词，返回实际启用状态。
#[frb(sync)]
pub fn desktop_lyrics_set_menu_bar_visible(visible: bool) -> bool {
    DesktopLyrics::global().set_menu_bar_visible(visible)
}

/// 显示桌面悬浮歌词窗口。
#[frb(sync)]
pub fn desktop_lyrics_show() -> bool {
    DesktopLyrics::global().show()
}

/// 隐藏桌面悬浮歌词窗口。
#[frb(sync)]
pub fn desktop_lyrics_hide() {
    DesktopLyrics::global().hide();
}

/// 窗口当前是否可见。
#[frb(sync)]
pub fn desktop_lyrics_is_visible() -> bool {
    DesktopLyrics::global().is_visible()
}

/// 锁定（鼠标穿透）/ 解锁悬浮窗。
#[frb(sync)]
pub fn desktop_lyrics_set_locked(locked: bool) {
    DesktopLyrics::global().set_locked(locked);
}

/// 窗口当前是否锁定。
#[frb(sync)]
pub fn desktop_lyrics_is_locked() -> bool {
    DesktopLyrics::global().is_locked()
}

/// 更新外观样式。
#[frb(sync)]
pub fn desktop_lyrics_set_style(style: DesktopLyricsStyleDto) {
    DesktopLyrics::global().set_style(Style {
        font_size: style.font_size,
        font_family: style.font_family,
        bold: style.bold,
        sung_color: style.sung_color,
        unsung_color: style.unsung_color,
        outline_color: style.outline_color,
        opacity: style.opacity,
        two_line: style.two_line,
    });
}

/// 换曲或歌词变更时推送整首歌词。
#[frb(sync)]
pub fn desktop_lyrics_set_lyrics(doc: DesktopLyricsDocDto) {
    DesktopLyrics::global().set_lyrics(LyricsDoc {
        track_id: doc.track_id,
        title: doc.title,
        artist: doc.artist,
        synced: doc.synced,
        lines: doc
            .lines
            .into_iter()
            .map(|l| Line {
                start_ms: l.start_ms,
                text: l.text,
                translation: l.translation,
                words: l
                    .words
                    .into_iter()
                    .map(|w| Word {
                        start_ms: w.start_ms,
                        end_ms: w.end_ms,
                        text: w.text,
                    })
                    .collect(),
            })
            .collect(),
    });
}

/// 推送播放时钟采样。
#[frb(sync)]
pub fn desktop_lyrics_set_clock(clock: DesktopLyricsClockDto) {
    DesktopLyrics::global().set_clock(Clock {
        track_id: clock.track_id,
        playing: clock.playing,
        position_ms: clock.position_ms,
    });
}

/// 恢复上次保存的各显示器位置 JSON。
#[frb(sync)]
pub fn desktop_lyrics_set_placements(json: String) {
    DesktopLyrics::global().set_placements_json(&json);
}

/// 订阅悬浮窗事件流（关闭、锁定切换、悬停工具栏切歌/播停、拖动位置变更）。
pub fn desktop_lyrics_events(sink: StreamSink<DesktopLyricsEventDto>) {
    DesktopLyrics::global().set_event_handler(Arc::new(move |ev| {
        let dto = match ev {
            Event::Closed => DesktopLyricsEventDto::Closed,
            Event::VisibilityChanged(visible) => {
                DesktopLyricsEventDto::VisibilityChanged { visible }
            }
            Event::MenuBarClosed => DesktopLyricsEventDto::MenuBarClosed,
            Event::LockChanged(locked) => DesktopLyricsEventDto::LockChanged { locked },
            Event::Control(c) => DesktopLyricsEventDto::Control {
                action: match c {
                    Control::Previous => DesktopLyricsControlDto::Previous,
                    Control::PlayPause => DesktopLyricsControlDto::PlayPause,
                    Control::Next => DesktopLyricsControlDto::Next,
                },
            },
            Event::PlacementChanged(json) => DesktopLyricsEventDto::PlacementChanged { json },
        };
        let _ = sink.add(dto);
    }));
}
