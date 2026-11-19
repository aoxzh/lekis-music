//! 补全审核页：显示核心推送的待确认数量。
//!
//! 对应 Windows 版的 `EnrichReviewPage`。ENR-06 要求置信度 0.5~0.85 的补全结果
//! 交给用户确认，但核心目前只推队列长度（`CoreEvent::EnrichQueueChanged`），
//! 列出候选 / 接受 / 拒绝的接口还没接通。
//!
//! TODO(ENR-06)：等 `lekis-core` 提供 `list_enrich_candidates` /
//! `accept_enrich_candidate` / `reject_enrich_candidate` 之后，把这一页换成
//! 真正的审核列表（候选 + 原值 + 置信度 + 接受/拒绝按钮）。

use std::cell::Cell;
use std::rc::Rc;

use gtk4::prelude::*;

use crate::app::App;
use crate::i18n;

/// 补全审核页。
pub struct EnrichReviewPage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
}

impl EnrichReviewPage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");
        root.set_vexpand(true);

        let title = gtk4::Label::new(Some(i18n::ENRICH_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);
        root.append(&title);

        // "待确认：N"。
        let pending_row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
        let pending_label = gtk4::Label::new(Some(i18n::ENRICH_PENDING));
        pending_label.add_css_class("dim");
        let pending_count = gtk4::Label::new(Some("0"));
        pending_count.add_css_class("card-value");
        pending_row.append(&pending_label);
        pending_row.append(&pending_count);
        root.append(&pending_row);

        // 两种空/未接通状态。
        let nothing = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
        nothing.set_margin_top(24);
        let nothing_title = gtk4::Label::new(Some(i18n::ENRICH_EMPTY_TITLE));
        nothing_title.add_css_class("empty-title");
        nothing_title.set_xalign(0.0);
        let nothing_body = gtk4::Label::new(Some(i18n::ENRICH_EMPTY_BODY));
        nothing_body.add_css_class("dim");
        nothing_body.set_wrap(true);
        nothing_body.set_xalign(0.0);
        nothing.append(&nothing_title);
        nothing.append(&nothing_body);
        root.append(&nothing);

        let unavailable = gtk4::Label::new(Some(i18n::ENRICH_UNAVAILABLE));
        unavailable.add_css_class("dim");
        unavailable.set_wrap(true);
        unavailable.set_xalign(0.0);
        unavailable.set_margin_top(24);
        unavailable.set_visible(false);
        root.append(&unavailable);

        let footnote = gtk4::Label::new(Some(i18n::ENRICH_FOOTNOTE));
        footnote.add_css_class("footnote");
        footnote.set_wrap(true);
        footnote.set_xalign(0.0);
        footnote.set_valign(gtk4::Align::End);
        footnote.set_vexpand(true);
        root.append(&footnote);

        // 首次进入时读一次核心状态，之后靠事件更新。
        let last_pending = Rc::new(Cell::new(u32::MAX));
        let apply: Rc<dyn Fn(u32)> = {
            let pending_count = pending_count.clone();
            let nothing = nothing.clone();
            let unavailable = unavailable.clone();
            Rc::new(move |pending: u32| {
                pending_count.set_label(&pending.to_string());
                nothing.set_visible(pending == 0);
                unavailable.set_visible(pending > 0);
            })
        };
        apply(0);
        {
            let apply = Rc::clone(&apply);
            let last_pending = Rc::clone(&last_pending);
            app.router().on_event(move |event| {
                if let lekis_types::CoreEvent::EnrichQueueChanged { pending } = event {
                    if last_pending.get() != *pending {
                        last_pending.set(*pending);
                        apply(*pending);
                    }
                }
            });
        }

        Self {
            widget: root.upcast(),
        }
    }
}
