//! 播放条与"正在播放"页共用的小控件。
//!
//! 抽出来是为了让两处显示完全一致：播放/暂停按钮、进度条、时间标签都由
//! [`Player`] 的快照驱动，控件本身不记状态。

use gtk4::glib;
use gtk4::prelude::*;

use crate::app::App;
use crate::i18n;
use crate::player::Player;

/// 上一首 / 播放暂停 / 下一首。
#[derive(Clone)]
pub struct Transport {
    /// 外层容器。
    pub widget: gtk4::Box,
    /// 播放暂停按钮。
    play: gtk4::Button,
    /// 按钮里的图标。
    play_icon: gtk4::Image,
}

impl Transport {
    /// 按播放状态刷新图标和提示。
    pub fn update(&self, is_playing: bool) {
        let (icon, tooltip) = if is_playing {
            ("media-playback-pause-symbolic", i18n::PLAYER_PAUSE)
        } else {
            ("media-playback-start-symbolic", i18n::PLAYER_PLAY)
        };
        self.play_icon.set_icon_name(Some(icon));
        self.play.set_tooltip_text(Some(tooltip));
    }
}

/// 构建一组播放控制按钮。
///
/// `play_size` 是中央圆钮的边长（播放条 40，正在播放页 56），`side_size` 是两侧按钮的边长。
pub fn transport(app: &App, play_size: i32, side_size: i32) -> Transport {
    let widget = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
    widget.set_halign(gtk4::Align::Center);
    widget.set_valign(gtk4::Align::Center);

    let previous = gtk4::Button::from_icon_name("media-skip-backward-symbolic");
    previous.add_css_class("transport");
    previous.set_tooltip_text(Some(i18n::PLAYER_PREVIOUS));
    previous.set_width_request(side_size);
    previous.set_height_request(side_size);
    {
        let app = app.clone();
        previous.connect_clicked(move |_| app.player().previous());
    }

    let play_icon = gtk4::Image::from_icon_name("media-playback-start-symbolic");
    play_icon.set_pixel_size((play_size / 2).max(14));
    let play = gtk4::Button::new();
    play.set_child(Some(&play_icon));
    play.add_css_class("play-button");
    play.set_tooltip_text(Some(i18n::PLAYER_PLAY));
    play.set_width_request(play_size);
    play.set_height_request(play_size);
    {
        let app = app.clone();
        play.connect_clicked(move |_| app.player().toggle_play_pause());
    }

    let next = gtk4::Button::from_icon_name("media-skip-forward-symbolic");
    next.add_css_class("transport");
    next.set_tooltip_text(Some(i18n::PLAYER_NEXT));
    next.set_width_request(side_size);
    next.set_height_request(side_size);
    {
        let app = app.clone();
        next.connect_clicked(move |_| app.player().next());
    }

    widget.append(&previous);
    widget.append(&play);
    widget.append(&next);

    Transport {
        widget,
        play,
        play_icon,
    }
}

/// 进度条 + 左右时间标签。
#[derive(Clone)]
pub struct Progress {
    /// 外层容器。
    pub widget: gtk4::Box,
    /// 进度条本体。
    scale: gtk4::Scale,
    /// 已播放时间。
    elapsed: gtk4::Label,
    /// 总时长。
    total: gtk4::Label,
}

impl Progress {
    /// 用快照里的位置和时长刷新。
    pub fn update(&self, position_ms: u64, duration_ms: u64) {
        // 时长未知（流媒体 / 还没解析出来）时给 1ms，避免滑块范围退化成 0。
        let duration = duration_ms.max(1) as f64;
        self.scale.set_range(0.0, duration);
        self.scale.set_value(position_ms as f64);
        self.elapsed.set_label(&i18n::format_duration(position_ms));
        self.total.set_label(&i18n::format_duration(duration_ms));
    }
}

/// 构建进度条控件。
pub fn progress(app: &App) -> Progress {
    let widget = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
    widget.set_valign(gtk4::Align::Center);
    widget.set_hexpand(true);

    let elapsed = gtk4::Label::new(Some(&i18n::format_duration(0)));
    elapsed.add_css_class("time-label");
    elapsed.set_width_request(44);
    elapsed.set_xalign(1.0);

    let scale = gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 1.0, 1.0);
    scale.set_draw_value(false);
    scale.set_hexpand(true);
    scale.set_valign(gtk4::Align::Center);
    scale.add_css_class("progress");
    {
        let app = app.clone();
        // 只有用户拖动才会触发 change_value，所以事件更新 value 不会造成回环。
        scale.connect_change_value(move |_, _, value| {
            if value.is_finite() && value >= 0.0 {
                app.player().seek(value as u64);
            }
            glib::Propagation::Proceed
        });
    }

    let total = gtk4::Label::new(Some(&i18n::format_duration(0)));
    total.add_css_class("time-label");
    total.set_width_request(44);

    widget.append(&elapsed);
    widget.append(&scale);
    widget.append(&total);

    Progress {
        widget,
        scale,
        elapsed,
        total,
    }
}

/// 一个纯色方形占位（核心还没有封面解码通路，`TODO(ART-01)`）。
pub fn cover(size: i32) -> gtk4::Label {
    let label = gtk4::Label::new(Some("♪"));
    label.add_css_class("cover");
    label.set_width_request(size);
    label.set_height_request(size);
    label.set_halign(gtk4::Align::Center);
    label.set_valign(gtk4::Align::Center);
    label
}

/// 大号封面占位（正在播放页）。
pub fn cover_large(size: i32) -> gtk4::Label {
    let label = gtk4::Label::new(Some("♪"));
    label.add_css_class("cover-large");
    label.set_width_request(size);
    label.set_height_request(size);
    label.set_halign(gtk4::Align::Center);
    label.set_valign(gtk4::Align::Center);
    label
}

/// 曲目行的标题与副标题文字（和 Windows 版 `PlayerViewModel` 的拼法一致）。
pub fn track_texts(player: &Player) -> (String, String) {
    match player.now_playing() {
        Some(now) => {
            let subtitle = if now.subtitle.is_empty() {
                i18n::PLAYER_NO_TRACK_SUBTITLE.to_string()
            } else {
                now.subtitle.clone()
            };
            let title = if now.title.is_empty() {
                i18n::PLAYER_NO_TRACK.to_string()
            } else {
                now.title
            };
            (title, subtitle)
        }
        None if player.has_track() => (
            i18n::LIST_LOADING.to_string(),
            i18n::PLAYER_NO_TRACK_SUBTITLE.to_string(),
        ),
        None => (
            i18n::PLAYER_NO_TRACK.to_string(),
            i18n::PLAYER_NO_TRACK_SUBTITLE.to_string(),
        ),
    }
}
