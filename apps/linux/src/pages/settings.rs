//! 设置页：版本、目录、设备信息与快捷键说明。
//!
//! 对应 Windows 版的 `SettingsPage`。按 `docs/CODING_GUIDELINES.md`，设置值存在
//! `lekis-core` 的 kv 表里、由核心读写，界面只做展示；真正的偏好项（主题、语言、
//! 音频输出、ReplayGain……）还没接，见文件末尾的 TODO。

use gtk4::prelude::*;

use crate::app::App;
use crate::core_service::CORE_VERSION;
use crate::i18n;

/// 设置页。
pub struct SettingsPage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
}

impl SettingsPage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");

        let title = gtk4::Label::new(Some(i18n::SETTINGS_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);

        // 卡片列（限宽 720，和 Windows 版一致）。
        let column = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        column.set_width_request(720);
        column.set_halign(gtk4::Align::Start);
        column.append(&card(i18n::SETTINGS_APP_VERSION, env!("CARGO_PKG_VERSION")));
        column.append(&card(i18n::SETTINGS_CORE_VERSION, CORE_VERSION));
        column.append(&card(
            i18n::SETTINGS_PLATFORM,
            &format!("Linux（{}）", std::env::consts::ARCH),
        ));
        column.append(&card(
            i18n::SETTINGS_DATA_DIR,
            &app.core().data_dir().to_string_lossy(),
        ));
        column.append(&card(
            i18n::SETTINGS_CACHE_DIR,
            &app.core().cache_dir().to_string_lossy(),
        ));
        column.append(&card(i18n::SETTINGS_DEVICE_ID, &app.core().device_id()));
        column.append(&card_with_note(
            i18n::SETTINGS_DARK_THEME,
            if crate::theme::prefer_dark_from_system() {
                "深色（跟随系统）"
            } else {
                "浅色（跟随系统）"
            },
            i18n::SETTINGS_DARK_THEME_BODY,
        ));

        let shortcuts = gtk4::Label::new(Some(i18n::SHORTCUTS_HINT));
        shortcuts.add_css_class("dim");
        shortcuts.set_wrap(true);
        shortcuts.set_xalign(0.0);
        shortcuts.set_margin_top(8);
        column.append(&shortcuts);

        // TODO(SET-01~04)：主题跟随系统（现在按 gtk-application-prefer-dark-theme
        // 选一次色板）、界面语言、音频输出（独占 / 比特完美，PLY-07）、
        // ReplayGain、缓存上限、补全来源、插件、同步与隐私开关。
        // 这些值都要走 `lekis-core` 的 `get_setting` / `set_setting`，不存 UI。
        let footnote = gtk4::Label::new(Some(i18n::SETTINGS_FOOTNOTE));
        footnote.add_css_class("footnote");
        footnote.set_wrap(true);
        footnote.set_xalign(0.0);
        footnote.set_margin_top(8);
        column.append(&footnote);

        let scroll = gtk4::ScrolledWindow::new();
        scroll.set_child(Some(&column));
        scroll.set_vexpand(true);
        scroll.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);

        root.append(&title);
        root.append(&scroll);

        Self {
            widget: root.upcast(),
        }
    }
}

/// 一张小卡片：标题 + 值。
fn card(title: &str, value: &str) -> gtk4::Box {
    card_with_note(title, value, "")
}

/// 一张小卡片：标题 + 值 +（可选）说明。
fn card_with_note(title: &str, value: &str, note: &str) -> gtk4::Box {
    let card = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
    card.add_css_class("card");

    let label = gtk4::Label::new(Some(title));
    label.add_css_class("card-title");
    label.set_xalign(0.0);

    let text = gtk4::Label::new(Some(value));
    text.add_css_class("card-value");
    text.set_xalign(0.0);
    text.set_selectable(true);
    text.set_ellipsize(gtk4::pango::EllipsizeMode::Middle);
    text.set_tooltip_text(Some(value));

    card.append(&label);
    card.append(&text);

    if !note.is_empty() {
        let note_label = gtk4::Label::new(Some(note));
        note_label.add_css_class("footnote");
        note_label.set_xalign(0.0);
        note_label.set_wrap(true);
        card.append(&note_label);
    }

    card
}
