//! 资料库页：排序 + 分页曲目列表 + 播放。
//!
//! 对应 Windows 版的 `LibraryPage`：排序切换后重新从第一页拉取，列表滚到底点
//! "加载更多"继续取；点某一行就把当前已加载的整批曲目交给核心播放（顺序播放）。

use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;

use lekis_types::{TrackQuery, TrackRow, TrackSort};

use crate::app::App;
use crate::i18n;
use crate::track_list::{track_ids, TrackList, PAGE_SIZE};

/// 资料库页。
pub struct LibraryPage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
}

impl LibraryPage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");
        root.set_vexpand(true);

        let title = gtk4::Label::new(Some(i18n::LIBRARY_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);
        root.append(&title);

        // 排序行：标签 + 下拉框。
        let sort_row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
        let sort_label = gtk4::Label::new(Some(i18n::LIBRARY_SORT));
        sort_label.add_css_class("dim");
        let dropdown = gtk4::DropDown::from_strings(&i18n::SORT_OPTIONS);
        // 初始排序跟着 `TrackSort::default()` 走，避免两处各写一个 0。
        dropdown.set_selected(i18n::sort_index(TrackSort::default()));
        dropdown.set_tooltip_text(Some(i18n::sort_text(TrackSort::default())));
        sort_row.append(&sort_label);
        sort_row.append(&dropdown);
        root.append(&sort_row);

        let sort = Rc::new(std::cell::Cell::new(TrackSort::default()));

        let list = TrackList::new(i18n::LIBRARY_EMPTY, {
            let app = app.clone();
            move |rows, index| play(app.clone(), rows, index)
        });
        root.append(&list.widget);

        // 加载一页：先从第一页开始（`reset` 时清空旧数据）。
        let load_page = {
            let app = app.clone();
            let list = list.clone();
            let sort = Rc::clone(&sort);
            Rc::new(move |reset: bool| {
                if reset {
                    list.clear();
                }
                if !list.begin_load() {
                    return;
                }
                let core = app.core().arc();
                let offset = list.len() as u32;
                let query = TrackQuery {
                    sort: sort.get(),
                    offset,
                    limit: PAGE_SIZE.min(TrackQuery::MAX_LIMIT),
                };
                let list = list.clone();
                glib::spawn_future_local(async move {
                    match core.list_tracks(query).await {
                        Ok(page) => {
                            let page_len = page.len();
                            list.append(&page, page_len);
                        }
                        Err(err) => {
                            tracing::warn!(error = %err, "{}", i18n::LOAD_FAILED);
                            list.fail(&format!("{}{}", i18n::LOAD_FAILED, i18n::error_text(&err)));
                        }
                    }
                });
            })
        };

        // 首屏 + 排序切换。
        load_page(true);
        {
            let load_page = Rc::clone(&load_page);
            let sort = Rc::clone(&sort);
            dropdown.connect_selected_notify(move |dropdown| {
                let selected = i18n::sort_from_index(dropdown.selected());
                sort.set(selected);
                dropdown.set_tooltip_text(Some(i18n::sort_text(selected)));
                load_page(true);
            });
        }
        {
            let load_page = Rc::clone(&load_page);
            list.connect_load_more(move || load_page(false));
        }

        // 资料库变了（扫描完成、收藏变化）就重新拉第一页。
        {
            let load_page = Rc::clone(&load_page);
            app.router().on_event(move |event| {
                if matches!(
                    event,
                    lekis_types::CoreEvent::LibraryChanged { .. }
                        | lekis_types::CoreEvent::ScanFinished { .. }
                ) {
                    load_page(true);
                }
            });
        }

        Self {
            widget: root.upcast(),
        }
    }
}

/// 播放当前列表，从点击的那一行开始。
fn play(app: App, rows: &[TrackRow], index: u32) {
    let ids = track_ids(rows);
    if ids.is_empty() {
        return;
    }
    let start = index.min(ids.len() as u32 - 1);
    app.player().play_tracks(ids, start);
}
