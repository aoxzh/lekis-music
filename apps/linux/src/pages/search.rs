//! 搜索页：输入框（防抖 250ms）+ 分页结果列表。
//!
//! 对应 Windows 版的 `SearchPage`。拼音、简繁、首字母匹配都由 `lekis-core` 完成，
//! 界面只负责延迟发请求、展示结果。

use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::glib;
use gtk4::prelude::*;

use lekis_types::TrackRow;

use crate::app::App;
use crate::i18n;
use crate::track_list::TrackList;

/// 输入停止多久后发请求（和 Windows 版一致）。
const DEBOUNCE: Duration = Duration::from_millis(250);

/// 搜索页。
pub struct SearchPage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
    /// 搜索框（Ctrl+F 聚焦用）。
    pub entry: gtk4::SearchEntry,
}

impl SearchPage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");
        root.set_vexpand(true);

        let title = gtk4::Label::new(Some(i18n::SEARCH_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);
        root.append(&title);

        let entry = gtk4::SearchEntry::new();
        entry.set_placeholder_text(Some(i18n::SEARCH_PLACEHOLDER));
        entry.set_hexpand(true);
        root.append(&entry);

        let hint = gtk4::Label::new(Some(i18n::SEARCH_EMPTY));
        hint.add_css_class("dim");
        hint.set_xalign(0.0);
        hint.set_wrap(true);
        root.append(&hint);

        let list = TrackList::new(i18n::SEARCH_NO_RESULT, {
            let app = app.clone();
            move |rows: &[TrackRow], index| {
                let ids: Vec<lekis_types::TrackId> = rows.iter().map(|row| row.id).collect();
                if !ids.is_empty() {
                    app.player()
                        .play_tracks(ids, index.min(rows.len() as u32 - 1));
                }
            }
        });
        list.widget.set_visible(false);
        root.append(&list.widget);

        // 每次输入都取消上一个待发的定时器，实现防抖。
        let pending: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
        {
            let app = app.clone();
            let list = list.clone();
            let hint = hint.clone();
            let pending = Rc::clone(&pending);
            entry.connect_search_changed(move |entry| {
                if let Some(source) = pending.borrow_mut().take() {
                    source.remove();
                }
                let text = entry.text().trim().to_string();
                if text.is_empty() {
                    list.clear();
                    list.widget.set_visible(false);
                    hint.set_visible(true);
                    return;
                }
                let app = app.clone();
                let list = list.clone();
                let hint = hint.clone();
                let source = glib::timeout_add_local_once(DEBOUNCE, move || {
                    run_search(app, list, hint, text);
                });
                *pending.borrow_mut() = Some(source);
            });
        }

        // 回车立即搜索，不等防抖。
        {
            let app = app.clone();
            let list = list.clone();
            let hint = hint.clone();
            let pending = Rc::clone(&pending);
            entry.connect_activate(move |entry| {
                if let Some(source) = pending.borrow_mut().take() {
                    source.remove();
                }
                let text = entry.text().trim().to_string();
                if text.is_empty() {
                    list.clear();
                    list.widget.set_visible(false);
                    hint.set_visible(true);
                    return;
                }
                run_search(app.clone(), list.clone(), hint.clone(), text);
            });
        }

        Self {
            widget: root.upcast(),
            entry,
        }
    }
}

/// 发一次搜索请求并填充结果。
fn run_search(app: App, list: TrackList, hint: gtk4::Label, text: String) {
    list.clear();
    let core = app.core().arc();
    glib::spawn_future_local(async move {
        match core.search(text, 50).await {
            Ok(results) => {
                let page = results.tracks;
                let count = page.len();
                list.append(&page, count);
                hint.set_visible(count == 0);
                list.widget.set_visible(count > 0);
            }
            Err(err) => {
                tracing::warn!(error = %err, "{}", i18n::LOAD_FAILED);
                list.fail(&format!("{}{}", i18n::LOAD_FAILED, i18n::error_text(&err)));
                list.widget.set_visible(true);
                hint.set_visible(false);
            }
        }
    });
}
