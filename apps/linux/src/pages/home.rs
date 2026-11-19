//! 首页：最近添加 + 空状态引导。
//!
//! 对应 Windows 版的 `HomePage`。注释里的 `TODO(HOME-*)` 是从 Windows/Android
//! 版继承下来的：继续播放、每日混音、"好久没听"、按时段推荐都还没做。

use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;

use lekis_types::TrackRow;

use crate::app::App;
use crate::i18n;
use crate::track_list::TrackList;

/// 首页"最近添加"取多少首。
///
/// 和分页大小一致，并且不超过核心的 `TrackQuery::MAX_LIMIT`（500）。
const RECENT_LIMIT: u32 = 200;

/// 首页。
pub struct HomePage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
}

impl HomePage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");
        root.set_vexpand(true);

        let title = gtk4::Label::new(Some(i18n::HOME_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);
        root.append(&title);

        let section = gtk4::Label::new(Some(i18n::HOME_RECENT));
        section.add_css_class("section-title");
        section.set_xalign(0.0);
        root.append(&section);

        // 空状态：只在资料库为空时出现。
        let empty = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        empty.set_halign(gtk4::Align::Center);
        empty.set_valign(gtk4::Align::Center);
        empty.set_width_request(420);
        empty.set_vexpand(true);
        let empty_title = gtk4::Label::new(Some(i18n::HOME_EMPTY_TITLE));
        empty_title.add_css_class("empty-title");
        let empty_body = gtk4::Label::new(Some(i18n::HOME_EMPTY_BODY));
        empty_body.add_css_class("dim");
        empty_body.set_wrap(true);
        empty_body.set_justify(gtk4::Justification::Center);
        let add_source = gtk4::Button::with_label(i18n::HOME_EMPTY_ACTION);
        add_source.add_css_class("suggested-action");
        add_source.set_halign(gtk4::Align::Center);
        {
            let app = app.clone();
            add_source.connect_clicked(move |_| crate::window::navigate(&app, "sources"));
        }
        empty.append(&empty_title);
        empty.append(&empty_body);
        empty.append(&add_source);

        let list = TrackList::new(i18n::LIBRARY_EMPTY, {
            let app = app.clone();
            move |rows: &[TrackRow], index| {
                let ids = crate::track_list::track_ids(rows);
                if !ids.is_empty() {
                    app.player()
                        .play_tracks(ids, index.min(rows.len() as u32 - 1));
                }
            }
        });
        root.append(&list.widget);
        root.append(&empty);

        // 最近添加只有一页，不再有"加载更多"。
        let reload = {
            let app = app.clone();
            let list = list.clone();
            let empty = empty.clone();
            Rc::new(move || {
                // 每次刷新都从干净的列表开始，避免事件重复触发时行数翻倍。
                list.clear();
                let core = app.core().arc();
                let list = list.clone();
                let empty = empty.clone();
                glib::spawn_future_local(async move {
                    match core.recently_added(RECENT_LIMIT).await {
                        Ok(tracks) => {
                            let count = tracks.len();
                            list.append(&tracks, count);
                            // 列表自己会把"加载更多"藏起来（没到上限就算到底）。
                            let is_empty = tracks.is_empty();
                            empty.set_visible(is_empty);
                            list.widget.set_visible(!is_empty);
                        }
                        Err(err) => {
                            tracing::warn!(error = %err, "{}", i18n::LOAD_FAILED);
                            list.fail(&format!("{}{}", i18n::LOAD_FAILED, i18n::error_text(&err)));
                        }
                    }
                });
            })
        };
        reload();
        {
            let reload = Rc::clone(&reload);
            app.router().on_event(move |event| {
                if matches!(
                    event,
                    lekis_types::CoreEvent::LibraryChanged { .. }
                        | lekis_types::CoreEvent::ScanFinished { .. }
                ) {
                    reload();
                }
            });
        }

        Self {
            widget: root.upcast(),
        }
    }
}
