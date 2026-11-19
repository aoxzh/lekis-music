//! 底部播放条（UIX-02）。
//!
//! 布局照 `apps/windows/src/Lekis.App/Controls/PlayerBar.xaml`：封面 + 曲目信息 +
//! 传输按钮 + 进度 + 音量。所有显示都由 [`crate::player`] 的快照驱动，
//! 进度来自 `PositionTick` 事件（**不轮询**）。

use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::App;
use crate::i18n;
use crate::widgets;

/// 播放条。
pub struct PlayerBar {
    /// 根控件。
    pub widget: gtk4::Box,
}

impl PlayerBar {
    /// 构建播放条并接上播放器状态。
    pub fn new(app: &App) -> Self {
        let bar = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
        bar.add_css_class("player-bar");
        bar.set_height_request(88);

        let top = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
        bar.append(&top);

        // 封面 + 曲目信息。
        top.append(&widgets::cover(48));
        let info = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
        info.set_valign(gtk4::Align::Center);
        info.set_width_request(200);
        info.set_hexpand(true);
        let title = gtk4::Label::new(Some(i18n::PLAYER_NO_TRACK));
        title.add_css_class("player-title");
        title.set_xalign(0.0);
        title.set_ellipsize(gtk4::pango::EllipsizeMode::End);
        let subtitle = gtk4::Label::new(Some(i18n::PLAYER_NO_TRACK_SUBTITLE));
        subtitle.add_css_class("player-subtitle");
        subtitle.set_xalign(0.0);
        subtitle.set_ellipsize(gtk4::pango::EllipsizeMode::End);
        info.append(&title);
        info.append(&subtitle);
        top.append(&info);

        // 传输按钮（上一首 / 播放暂停 / 下一首）。
        let transport = widgets::transport(app, 40, 36);
        top.append(&transport.widget);

        // 循环 / 随机。
        let repeat = gtk4::Button::from_icon_name("media-playlist-repeat-symbolic");
        repeat.add_css_class("transport");
        repeat.set_tooltip_text(Some(i18n::PLAYER_REPEAT_OFF));
        repeat.set_width_request(32);
        repeat.set_height_request(32);
        {
            let app = app.clone();
            repeat.connect_clicked(move |_| app.player().cycle_repeat());
        }
        top.append(&repeat);

        let shuffle = gtk4::Button::from_icon_name("media-playlist-shuffle-symbolic");
        shuffle.add_css_class("transport");
        shuffle.set_tooltip_text(Some(i18n::PLAYER_SHUFFLE_OFF));
        shuffle.set_width_request(32);
        shuffle.set_height_request(32);
        {
            let app = app.clone();
            shuffle.connect_clicked(move |_| app.player().cycle_shuffle());
        }
        top.append(&shuffle);

        // 音量：0.0 ~ 1.0，和核心的 `set_volume` 一致。
        let volume_label = gtk4::Image::from_icon_name("audio-volume-high-symbolic");
        volume_label.set_tooltip_text(Some(i18n::PLAYER_VOLUME));
        top.append(&volume_label);
        let volume = gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 1.0, 0.01);
        volume.set_draw_value(false);
        volume.set_width_request(110);
        volume.set_valign(gtk4::Align::Center);
        volume.set_value(app.player().volume() as f64);
        {
            let app = app.clone();
            volume.connect_change_value(move |_, _, value| {
                if value.is_finite() {
                    app.player().set_volume(value as f32);
                }
                gtk4::glib::Propagation::Proceed
            });
        }
        top.append(&volume);

        // 进度条。
        let progress = widgets::progress(app);
        bar.append(&progress.widget);

        // 每帧（事件驱动）刷新一次显示。
        let sync = {
            let app = app.clone();
            Rc::new(move || {
                let (title_text, subtitle_text) = widgets::track_texts(app.player());
                title.set_label(&title_text);
                subtitle.set_label(&subtitle_text);
                transport.update(app.player().is_playing());
                progress.update(app.player().position_ms(), app.player().duration_ms());
                volume.set_value(app.player().volume() as f64);

                let repeat_mode = app.player().repeat();
                repeat.set_icon_name(i18n::repeat_icon(repeat_mode));
                repeat.set_tooltip_text(Some(i18n::repeat_text(repeat_mode)));
                if repeat_mode == lekis_types::RepeatMode::Off {
                    repeat.remove_css_class("toggle-active");
                } else {
                    repeat.add_css_class("toggle-active");
                }

                let shuffle_mode = app.player().shuffle();
                shuffle.set_icon_name(i18n::shuffle_icon(shuffle_mode));
                shuffle.set_tooltip_text(Some(i18n::shuffle_text(shuffle_mode)));
                if shuffle_mode == lekis_types::ShuffleMode::Off {
                    shuffle.remove_css_class("toggle-active");
                } else {
                    shuffle.add_css_class("toggle-active");
                }
            })
        };
        sync();
        crate::player::subscribe(sync);

        Self { widget: bar }
    }
}
