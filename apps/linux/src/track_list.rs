//! 可复用的曲目列表（分页加载）。
//!
//! `docs/ARCHITECTURE.md` 要求大列表必须分页：`TrackQuery` 有 `offset`/`limit`，
//! 单页上限 [`MAX_LIMIT`]。这里用 `ListView` + `ListStore`，只把已经加载到内存的
//! 行交给 GTK，剩下的靠"加载更多"按钮再取一页。
//!
//! 列表本身不认识核心：它只保存已经取到的 [`TrackRow`]，点击时把整批 id 交给调用方。

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

use lekis_types::{TrackId, TrackRow};

use crate::i18n;
use crate::widgets;

/// 单页最多取多少行（`lekis-core` 的 `TrackQuery::MAX_LIMIT`）。
pub const PAGE_SIZE: u32 = 200;

/// 一个曲目行在 `ListStore` 里的包装。
///
/// `ListStore` 只能装 GObject，所以用 `glib::BoxedAnyObject` 把纯 Rust 结构塞进去。
type Row = (TrackRow, u32);

/// 分页曲目列表。
#[derive(Clone)]
pub struct TrackList {
    /// 外层容器（列表 + 空状态 + 加载更多）。
    pub widget: gtk4::Box,
    /// 底层数据模型。
    store: gio::ListStore,
    /// 滚动容器。
    scroll: gtk4::ScrolledWindow,
    /// 空状态提示。
    empty: gtk4::Label,
    /// "加载更多"按钮。
    more: gtk4::Button,
    /// 到底之后的页脚（"已加载全部"）。
    footer: gtk4::Label,
    /// 已加载的行（点播放时要把整批 id 交给核心）。
    rows: Rc<RefCell<Vec<TrackRow>>>,
    /// 是否已经加载到底。
    done: Rc<RefCell<bool>>,
    /// 是否正在加载。
    loading: Rc<RefCell<bool>>,
}

impl TrackList {
    /// 创建列表；`on_activate` 在用户点击某一行时被调用（拿到当前全部行和下标）。
    pub fn new<F>(empty_text: &str, on_activate: F) -> Self
    where
        F: Fn(&[TrackRow], u32) + 'static,
    {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let rows: Rc<RefCell<Vec<TrackRow>>> = Rc::new(RefCell::new(Vec::new()));
        let done = Rc::new(RefCell::new(false));
        let loading = Rc::new(RefCell::new(false));

        let factory = gtk4::SignalListItemFactory::new();
        factory.connect_setup(|_, object| {
            let Some(item) = object.downcast_ref::<gtk4::ListItem>() else {
                return;
            };
            item.set_child(Some(&row_widget()));
        });
        {
            factory.connect_bind(|_, object| {
                let Some(item) = object.downcast_ref::<gtk4::ListItem>() else {
                    return;
                };
                let Some(row) = item.item().and_downcast::<glib::BoxedAnyObject>() else {
                    return;
                };
                let borrowed = row.borrow::<Row>();
                let (track, _) = &*borrowed;
                bind_row(&item, track);
            });
        }
        factory.connect_unbind(|_, object| {
            let Some(item) = object.downcast_ref::<gtk4::ListItem>() else {
                return;
            };
            if let Some(child) = item.child() {
                clear_row(&child);
            }
        });

        let selection = gtk4::NoSelection::new(Some(store.clone()));
        let list = gtk4::ListView::new(Some(selection), Some(factory));
        list.add_css_class("track-list");
        list.set_single_click_activate(true);
        {
            let rows = Rc::clone(&rows);
            list.connect_activate(move |_, position| {
                let snapshot = rows.borrow().clone();
                if !snapshot.is_empty() {
                    on_activate(&snapshot, position);
                }
            });
        }

        let scroll = gtk4::ScrolledWindow::new();
        scroll.set_child(Some(&list));
        scroll.set_vexpand(true);
        scroll.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);

        let empty = gtk4::Label::new(Some(empty_text));
        empty.add_css_class("dim");
        empty.set_wrap(true);
        empty.set_margin_top(24);
        empty.set_margin_bottom(24);
        empty.set_visible(false);

        let more = gtk4::Button::with_label(i18n::LIST_LOAD_MORE);
        more.add_css_class("pill");
        more.set_halign(gtk4::Align::Center);
        more.set_margin_top(8);
        more.set_visible(false);

        // 到底之后的页脚。
        let footer = gtk4::Label::new(Some(i18n::LIST_ALL_LOADED));
        footer.add_css_class("footnote");
        footer.set_margin_top(8);
        footer.set_margin_bottom(8);
        footer.set_visible(false);

        let widget = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
        widget.set_vexpand(true);
        widget.append(&scroll);
        widget.append(&empty);
        widget.append(&more);
        widget.append(&footer);

        let list = Self {
            widget,
            store,
            scroll,
            empty,
            more,
            footer,
            rows,
            done,
            loading,
        };
        list.sync_visibility();
        list
    }

    /// 由调用方把列表和"加载更多"按钮接到自己的加载逻辑上。
    pub fn connect_load_more<F>(&self, callback: F)
    where
        F: Fn() + 'static,
    {
        self.more.connect_clicked(move |_| callback());
    }

    /// 清空列表（切换排序、重新搜索时用）。
    pub fn clear(&self) {
        let count = self.store.n_items();
        // `splice` 的 additions 是泛型切片，空数组要显式标注元素类型。
        self.store.splice(0, count, &[] as &[glib::BoxedAnyObject]);
        self.rows.borrow_mut().clear();
        *self.done.borrow_mut() = false;
        *self.loading.borrow_mut() = false;
        self.sync_visibility();
    }

    /// 追加一页。
    ///
    /// `page_len` 是核心实际返回的行数：小于 [`PAGE_SIZE`] 说明已经到底了。
    pub fn append(&self, page: &[TrackRow], page_len: usize) {
        if page.is_empty() {
            *self.done.borrow_mut() = true;
            *self.loading.borrow_mut() = false;
            self.sync_visibility();
            return;
        }
        let offset = self.rows.borrow().len() as u32;
        let objects: Vec<glib::BoxedAnyObject> = page
            .iter()
            .enumerate()
            .map(|(index, track)| glib::BoxedAnyObject::new((track.clone(), offset + index as u32)))
            .collect();
        self.store.extend_from_slice(&objects);
        self.rows.borrow_mut().extend_from_slice(page);
        *self.done.borrow_mut() = page_len < PAGE_SIZE as usize;
        *self.loading.borrow_mut() = false;
        self.sync_visibility();
    }

    /// 标记"这一页开始加载了"（防止用户连点重复请求）。
    pub fn begin_load(&self) -> bool {
        let mut loading = self.loading.borrow_mut();
        if *loading || *self.done.borrow() {
            return false;
        }
        *loading = true;
        true
    }

    /// 加载失败：停止继续请求，并把错误显示在空状态里。
    pub fn fail(&self, message: &str) {
        *self.loading.borrow_mut() = false;
        *self.done.borrow_mut() = true;
        if self.rows.borrow().is_empty() {
            self.empty.set_label(message);
        }
        self.sync_visibility();
    }

    /// 已加载的行数。
    pub fn len(&self) -> usize {
        self.rows.borrow().len()
    }

    /// 是否已经加载到底。
    pub fn is_done(&self) -> bool {
        *self.done.borrow()
    }

    /// 同步空状态 / 加载更多按钮 / 页脚的可见性。
    fn sync_visibility(&self) {
        let empty = self.rows.borrow().is_empty();
        let done = self.is_done();
        let loading = *self.loading.borrow();
        self.empty.set_visible(empty);
        self.scroll.set_visible(!empty);
        self.more.set_visible(!empty && !done);
        self.more.set_sensitive(!loading);
        self.more.set_label(if loading {
            i18n::LIST_LOADING
        } else {
            i18n::LIST_LOAD_MORE
        });
        // 有内容又已经到底：显示"已加载全部"，让用户知道不用再等。
        self.footer.set_visible(!empty && done);
    }
}

/// 一行的控件骨架（只在 setup 时创建一次，bind 时填内容）。
fn row_widget() -> gtk4::Box {
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
    row.add_css_class("track-row");
    row.set_height_request(56);

    let cover = widgets::cover(40);
    row.append(&cover);

    let text = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
    text.set_valign(gtk4::Align::Center);
    text.set_hexpand(true);
    let title = gtk4::Label::new(None);
    title.add_css_class("track-title");
    title.set_xalign(0.0);
    title.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    let subtitle = gtk4::Label::new(None);
    subtitle.add_css_class("track-subtitle");
    subtitle.set_xalign(0.0);
    subtitle.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    text.append(&title);
    text.append(&subtitle);
    row.append(&text);

    let badge = gtk4::Label::new(None);
    badge.add_css_class("badge");
    badge.set_valign(gtk4::Align::Center);
    badge.set_visible(false);
    row.append(&badge);

    let loved = gtk4::Image::from_icon_name("emblem-favorite-symbolic");
    loved.add_css_class("badge-moon");
    loved.set_valign(gtk4::Align::Center);
    loved.set_tooltip_text(Some(i18n::TRACK_LOVE));
    loved.set_visible(false);
    row.append(&loved);

    let duration = gtk4::Label::new(None);
    duration.add_css_class("time-label");
    duration.set_valign(gtk4::Align::Center);
    duration.set_width_request(48);
    duration.set_xalign(1.0);
    row.append(&duration);

    row
}

/// 取 `row` 的第 `index` 个子控件（0 开始）。
fn child_at(row: &gtk4::Box, index: usize) -> Option<gtk4::Widget> {
    let mut child = row.first_child();
    for _ in 0..index {
        child = child.and_then(|widget| widget.next_sibling());
    }
    child
}

/// 把一行数据填进骨架；`row_widget` 里 append 的顺序决定了下标。
fn bind_row(item: &gtk4::ListItem, track: &TrackRow) {
    let Some(root) = item.child() else { return };
    let Some(row) = root.downcast_ref::<gtk4::Box>() else {
        return;
    };

    // 1：标题 / 副标题所在的竖向容器。
    if let Some(text) = child_at(row, 1).and_then(|widget| widget.downcast::<gtk4::Box>().ok()) {
        if let Some(title) = child_at(&text, 0).and_then(|w| w.downcast::<gtk4::Label>().ok()) {
            title.set_label(&track.title);
        }
        if let Some(subtitle) = child_at(&text, 1).and_then(|w| w.downcast::<gtk4::Label>().ok()) {
            subtitle.set_label(&subtitle_text(track));
        }
    }

    // 2：音质徽章（没有就隐藏）。
    if let Some(badge) = child_at(row, 2).and_then(|w| w.downcast::<gtk4::Label>().ok()) {
        match track.quality_badge.as_deref() {
            Some(text) if !text.is_empty() => {
                badge.set_label(text);
                badge.set_visible(true);
            }
            _ => badge.set_visible(false),
        }
    }

    // 3：收藏心。
    if let Some(loved) = child_at(row, 3).and_then(|w| w.downcast::<gtk4::Image>().ok()) {
        loved.set_visible(track.loved);
    }

    // 4：时长。
    if let Some(duration) = child_at(row, 4).and_then(|w| w.downcast::<gtk4::Label>().ok()) {
        duration.set_label(&i18n::format_duration(track.duration_ms));
    }
}

/// 回收行（GTK 复用控件时清掉上一行的内容）。
fn clear_row(root: &gtk4::Widget) {
    let Some(row) = root.downcast_ref::<gtk4::Box>() else {
        return;
    };
    if let Some(text) = child_at(row, 1).and_then(|widget| widget.downcast::<gtk4::Box>().ok()) {
        if let Some(title) = child_at(&text, 0).and_then(|w| w.downcast::<gtk4::Label>().ok()) {
            title.set_label("");
        }
        if let Some(subtitle) = child_at(&text, 1).and_then(|w| w.downcast::<gtk4::Label>().ok()) {
            subtitle.set_label("");
        }
    }
}

/// 副标题：`艺人 · 专辑`，和 Windows 版一致。
fn subtitle_text(track: &TrackRow) -> String {
    match track.album_title.as_deref() {
        Some(album) if !album.is_empty() && !track.artist_line.is_empty() => {
            format!("{} · {album}", track.artist_line)
        }
        Some(album) if !album.is_empty() => album.to_string(),
        _ => track.artist_line.clone(),
    }
}

/// 把一批行转成 id 列表（播放整张列表用）。
pub fn track_ids(rows: &[TrackRow]) -> Vec<TrackId> {
    rows.iter().map(|row| row.id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 副标题拼接规则和 Windows 版保持一致。
    #[test]
    fn subtitle_joins_artist_and_album() {
        let base = TrackRow {
            id: TrackId(1),
            title: "标题".into(),
            artist_line: "艺人".into(),
            album_title: Some("专辑".into()),
            duration_ms: 1_000,
            artwork_id: None,
            quality_badge: None,
            loved: false,
        };
        assert_eq!(subtitle_text(&base), "艺人 · 专辑");

        let no_album = TrackRow {
            album_title: None,
            ..base.clone()
        };
        assert_eq!(subtitle_text(&no_album), "艺人");

        let only_album = TrackRow {
            artist_line: String::new(),
            ..base
        };
        assert_eq!(subtitle_text(&only_album), "专辑");
    }
}
