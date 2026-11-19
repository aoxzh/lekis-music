//! 桌面歌词窗口（UIX-07）。
//!
//! 骨架：独立窗口 + 大字歌词 + 当前行高亮。播放位置来自
//! [`crate::player::Player`]（由 `PositionTick` 事件驱动），行解析和高亮判定在
//! [`crate::lyrics`] 里，已有单测覆盖。
//!
//! 目前核心还没有歌词接口（`TODO(ENR-04)`：`lekis-core` 需要提供
//! `lyrics(track_id) -> Result<Lyrics>`，`lekis-types::Lyrics` 已经是现成的模型），
//! 所以这里只显示占位文案；一旦拿到 LRC 文本，把 [`crate::lyrics::parse_lrc`] 的
//! 结果塞进 `apply_position` 就能工作。
//!
//! TODO(UIX-07)：
//! - 锁定 / 穿透点击（`gdk_surface_input_region` 设为空 + `set_keep_above`）；
//! - 字体大小、颜色、透明度的用户设置（存核心 kv 表）；
//! - 多显示器定位与位置记忆；
//! - 平滑滚动（tokens.json 的 `motion.spring.lyricsScroll`）。

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;

use crate::app::App;
use crate::i18n;
use crate::lyrics::{current_line, parse_lrc, LyricLine};

thread_local! {
    /// 已打开的歌词窗口。
    static WINDOW: RefCell<Option<gtk4::Window>> = const { RefCell::new(None) };
}

/// 打开（或聚焦）桌面歌词窗口。
pub fn show(app: &App) {
    if let Some(window) = WINDOW.with(|slot| slot.borrow().clone()) {
        window.present();
        return;
    }

    let window = gtk4::Window::builder()
        .title(i18n::LYRICS_TITLE)
        .default_width(720)
        .default_height(240)
        .decorated(true)
        .build();
    window.set_application(app.window().application().as_ref());
    window.set_hide_on_close(true);

    let root = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
    root.set_valign(gtk4::Align::Center);
    root.set_halign(gtk4::Align::Center);
    root.set_margin_top(16);
    root.set_margin_bottom(16);
    root.set_margin_start(24);
    root.set_margin_end(24);

    // 上一行 / 当前行 / 下一行。
    let prev = gtk4::Label::new(None);
    prev.add_css_class("lyrics-line");
    prev.set_opacity(0.35);
    prev.set_ellipsize(gtk4::pango::EllipsizeMode::End);

    let active = gtk4::Label::new(Some(i18n::LYRICS_PLACEHOLDER));
    active.add_css_class("lyrics-active");
    active.set_wrap(true);
    active.set_justify(gtk4::Justification::Center);

    let next = gtk4::Label::new(None);
    next.add_css_class("lyrics-line");
    next.set_opacity(0.35);
    next.set_ellipsize(gtk4::pango::EllipsizeMode::End);

    root.append(&prev);
    root.append(&active);
    root.append(&next);

    let footnote = gtk4::Label::new(Some(i18n::LYRICS_FOOTNOTE));
    footnote.add_css_class("footnote");
    footnote.set_halign(gtk4::Align::Center);
    footnote.set_margin_top(12);
    root.append(&footnote);

    window.set_child(Some(&root));

    // 歌词缓存：拿到文本后只解析一次。
    let lines: Rc<RefCell<Vec<LyricLine>>> = Rc::new(RefCell::new(parse_lrc("")));
    let last_index: Rc<RefCell<Option<usize>>> = Rc::new(RefCell::new(None));

    let sync = {
        let app = app.clone();
        let lines = Rc::clone(&lines);
        let last_index = Rc::clone(&last_index);
        let prev = prev.clone();
        let active = active.clone();
        let next = next.clone();
        Rc::new(move || {
            // TODO(ENR-04)：核心提供歌词后，这里换成 `core.lyrics(track_id)`，
            // 并把结果塞进 `lines`；下面的高亮逻辑不用改。
            let position = app.player().position_ms();
            let parsed = lines.borrow();
            let index = current_line(&parsed, position);
            if *last_index.borrow() == index {
                return;
            }
            *last_index.borrow_mut() = index;
            match index {
                Some(index) => {
                    let line_text = |offset: usize| {
                        parsed
                            .get(offset)
                            .map(|line| line.text.as_str())
                            .unwrap_or("")
                    };
                    prev.set_label(if index == 0 { "" } else { line_text(index - 1) });
                    active.set_label(&parsed[index].text);
                    next.set_label(line_text(index + 1));
                }
                None => {
                    prev.set_label("");
                    active.set_label(i18n::LYRICS_PLACEHOLDER);
                    next.set_label("");
                }
            }
        })
    };
    sync();
    crate::player::subscribe(sync);

    // 主窗口关闭时一起收掉。
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
