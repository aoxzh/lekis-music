//! 桌面迷你播放器（UIX-08）。
//!
//! 骨架：一个无边框小组件窗口，复用播放条那套传输按钮 + 曲目信息，显示完全由
//! [`crate::player`] 的状态驱动（和主窗口同一个 `Player`，切歌/暂停会同步）。
//!
//! TODO(UIX-08)：
//! - 置顶（"总在最前"）：GTK4 没有 `set_keep_above`，需要走
//!   `gdk_surface_set_keep_above`（X11/Wayland 特化）或等 GTK 暴露 API；
//! - 无边框拖动：现在用普通标题栏，正式版应该用 `WindowHandle` + 自绘拖拽区；
//! - 关闭后保留状态（现在是 `hide_on_close`，已满足）；
//! - 记住上次的位置和尺寸。

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;

use crate::app::App;
use crate::i18n;
use crate::widgets;

thread_local! {
    /// 已经打开的迷你播放器（再次点击按钮就把它提到前面，而不是开第二个）。
    static WINDOW: RefCell<Option<gtk4::Window>> = const { RefCell::new(None) };
}

/// 打开（或聚焦）迷你播放器。
pub fn show(app: &App) {
    if let Some(window) = WINDOW.with(|slot| slot.borrow().clone()) {
        window.present();
        return;
    }

    let window = gtk4::Window::builder()
        .title(i18n::MINI_PLAYER_TITLE)
        .default_width(360)
        .default_height(96)
        .resizable(false)
        .decorated(true)
        .build();
    window.set_application(app.window().application().as_ref());
    // 关掉窗口只是隐藏，播放器状态还在主窗口里。
    window.set_hide_on_close(true);

    let root = gtk4::Box::new(gtk4::Orientation::Vertical, 6);
    root.add_css_class("player-bar");
    root.set_margin_top(6);
    root.set_margin_bottom(6);
    root.set_margin_start(8);
    root.set_margin_end(8);

    let line = gtk4::Box::new(gtk4::Orientation::Horizontal, 10);
    line.append(&widgets::cover(48));

    let info = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
    info.set_valign(gtk4::Align::Center);
    info.set_hexpand(true);
    let title = gtk4::Label::new(Some(i18n::PLAYER_NO_TRACK));
    title.add_css_class("mini-title");
    title.set_xalign(0.0);
    title.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    let subtitle = gtk4::Label::new(Some(i18n::PLAYER_NO_TRACK_SUBTITLE));
    subtitle.add_css_class("player-subtitle");
    subtitle.set_xalign(0.0);
    subtitle.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    info.append(&title);
    info.append(&subtitle);
    line.append(&info);
    let transport = widgets::transport(app, 40, 32);
    line.append(&transport.widget);
    root.append(&line);

    let progress = widgets::progress(app);
    root.append(&progress.widget);
    window.set_child(Some(&root));

    // 事件驱动刷新。
    let sync = {
        let app = app.clone();
        Rc::new(move || {
            let (title_text, subtitle_text) = widgets::track_texts(app.player());
            title.set_label(&title_text);
            subtitle.set_label(&subtitle_text);
            transport.update(app.player().is_playing());
            progress.update(app.player().position_ms(), app.player().duration_ms());
        })
    };
    sync();
    crate::player::subscribe(sync);

    // 主窗口关闭时迷你播放器一起走。
    let main_window = app.window();
    let weak = glib::WeakRef::new();
    weak.set(Some(&window));
    main_window.connect_close_request(move |_| {
        if let Some(window) = weak.upgrade() {
            window.close();
        }
        glib::Propagation::Proceed
    });

    WINDOW.with(|slot| *slot.borrow_mut() = Some(window.clone()));
    window.present();
}
