//! 正在播放页：大封面 + 标题 + 传输按钮 + 进度 + 音量。
//!
//! 对应 Windows 版的 `NowPlayingPage`：曲目信息来自 [`crate::player`] 的快照，
//! 进度由 `PositionTick` 事件驱动（不轮询）。

use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::App;
use crate::i18n;
use crate::widgets;

/// 正在播放页。
pub struct NowPlayingPage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
}

impl NowPlayingPage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");
        root.set_vexpand(true);

        let title = gtk4::Label::new(Some(i18n::NOW_PLAYING_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);
        root.append(&title);

        let body = gtk4::Box::new(gtk4::Orientation::Horizontal, 32);
        body.set_valign(gtk4::Align::Center);
        body.set_halign(gtk4::Align::Center);
        body.set_vexpand(true);
        root.append(&body);

        // 左侧：大封面占位。
        body.append(&widgets::cover_large(280));

        // 右侧：文字 + 按钮 + 进度。
        let side = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        side.set_valign(gtk4::Align::Center);
        side.set_width_request(420);

        let nothing = gtk4::Label::new(Some(i18n::NOW_PLAYING_NOTHING));
        nothing.add_css_class("dim");
        nothing.set_xalign(0.0);
        nothing.set_wrap(true);
        side.append(&nothing);

        let track_title = gtk4::Label::new(None);
        track_title.add_css_class("now-playing-title");
        track_title.set_xalign(0.0);
        track_title.set_wrap(true);
        track_title.set_ellipsize(gtk4::pango::EllipsizeMode::End);
        track_title.set_lines(2);
        side.append(&track_title);

        let subtitle = gtk4::Label::new(None);
        subtitle.add_css_class("now-playing-subtitle");
        subtitle.set_xalign(0.0);
        subtitle.set_ellipsize(gtk4::pango::EllipsizeMode::End);
        side.append(&subtitle);

        let badge = gtk4::Label::new(None);
        badge.add_css_class("badge");
        badge.set_halign(gtk4::Align::Start);
        badge.set_visible(false);
        side.append(&badge);

        // 播放状态提示（缓冲中 / 已暂停 / 播放结束）；播放中不显示。
        let state_text = gtk4::Label::new(None);
        state_text.add_css_class("dim");
        state_text.set_xalign(0.0);
        state_text.set_visible(false);
        side.append(&state_text);

        let transport = widgets::transport(app, 56, 44);
        transport.widget.set_margin_top(8);
        side.append(&transport.widget);

        let progress = widgets::progress(app);
        progress.widget.set_margin_top(8);
        side.append(&progress.widget);

        body.append(&side);

        // 事件驱动的刷新。
        let sync = {
            let app = app.clone();
            Rc::new(move || {
                let has_track = app.player().has_track();
                nothing.set_visible(!has_track);

                let (title_text, subtitle_text) = widgets::track_texts(app.player());
                track_title.set_label(&title_text);
                subtitle.set_label(&subtitle_text);
                track_title.set_visible(has_track);
                subtitle.set_visible(has_track);

                let quality = app
                    .player()
                    .now_playing()
                    .and_then(|now| now.quality)
                    .filter(|text| !text.is_empty());
                match quality {
                    Some(text) => {
                        badge.set_label(&text);
                        badge.set_visible(has_track);
                    }
                    None => badge.set_visible(false),
                }

                transport.update(app.player().is_playing());
                progress.update(app.player().position_ms(), app.player().duration_ms());

                // "缓冲中 / 已暂停 / 播放结束"这类状态文字由快照驱动。
                match i18n::playback_state_text(app.player().snapshot().state) {
                    Some(text) if has_track => {
                        state_text.set_label(text);
                        state_text.set_visible(true);
                    }
                    _ => state_text.set_visible(false),
                }
            })
        };
        sync();
        crate::player::subscribe(sync);

        Self {
            widget: root.upcast(),
        }
    }
}
