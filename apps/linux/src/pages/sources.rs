//! 音源页：本地文件夹音源的添加、列出与重新扫描。
//!
//! 对应 Windows 版的 `SourcesPage`：选文件夹用 `FileDialog`（GTK 4.10 的异步文件
//! 对话框），扫描进度完全由核心的 `ScanProgress` / `ScanFinished` 事件推送。
//!
//! TODO(SRC-04~06)：SMB / WebDAV / NFS / SFTP 与服务器音源（OpenSubsonic、
//! Jellyfin、Emby、Plex）的添加表单还没做，核心侧已经支持这些类型。

use std::collections::BTreeMap;
use std::path::Path;
use std::rc::Rc;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

use lekis_types::{SourceConfig, SourceKind};

use crate::app::App;
use crate::i18n;

/// 音源页。
pub struct SourcesPage {
    /// 页面根控件。
    pub widget: gtk4::Widget,
}

impl SourcesPage {
    /// 构建页面。
    pub fn new(app: &App) -> Self {
        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
        root.add_css_class("page");
        root.set_vexpand(true);

        let title = gtk4::Label::new(Some(i18n::SOURCES_TITLE));
        title.add_css_class("page-title");
        title.set_xalign(0.0);
        root.append(&title);

        // 操作行：添加按钮 + 状态文字。
        let actions = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
        let add = gtk4::Button::with_label(i18n::SOURCES_ADD_LOCAL);
        add.add_css_class("suggested-action");
        {
            let app = app.clone();
            add.connect_clicked(move |_| add_local_folder(&app));
        }
        actions.append(&add);

        let status = gtk4::Label::new(None);
        status.add_css_class("dim");
        status.set_xalign(0.0);
        status.set_hexpand(true);
        status.set_ellipsize(gtk4::pango::EllipsizeMode::End);
        actions.append(&status);
        root.append(&actions);

        // 音源列表。
        let list = gtk4::ListBox::new();
        list.add_css_class("source-list");
        list.set_selection_mode(gtk4::SelectionMode::None);
        list.set_show_separators(false);

        let scroll = gtk4::ScrolledWindow::new();
        scroll.set_child(Some(&list));
        scroll.set_vexpand(true);
        scroll.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
        root.append(&scroll);

        let empty = gtk4::Label::new(Some(i18n::SOURCES_EMPTY));
        empty.add_css_class("dim");
        empty.set_wrap(true);
        empty.set_xalign(0.0);
        empty.set_margin_top(16);
        root.append(&empty);

        let footnote = gtk4::Label::new(Some(i18n::SOURCES_FOOTNOTE));
        footnote.add_css_class("footnote");
        footnote.set_wrap(true);
        footnote.set_xalign(0.0);
        root.append(&footnote);

        // 用 `Rc<RefCell<Vec<..>>>` 保存每行的可刷新控件，重新加载时整体重建。
        let reload: Rc<dyn Fn()> = {
            let app = app.clone();
            let list = list.clone();
            let empty = empty.clone();
            Rc::new(move || load_sources(app.clone(), list.clone(), empty.clone()))
        };
        reload();

        // 扫描进度：核心会持续推 `ScanProgress`，结束后推 `ScanFinished`。
        {
            let app = app.clone();
            let status = status.clone();
            let reload = Rc::clone(&reload);
            app.router().on_event(move |event| match event {
                lekis_types::CoreEvent::ScanProgress {
                    phase, done, total, ..
                } => {
                    let phase = i18n::scan_phase_text(*phase);
                    match total {
                        Some(total) => status.set_label(&format!(
                            "{}{} {done}/{total}",
                            i18n::SOURCES_SCANNING,
                            phase
                        )),
                        None => {
                            status.set_label(&format!("{}{} {done}", i18n::SOURCES_SCANNING, phase))
                        }
                    }
                }
                lekis_types::CoreEvent::ScanFinished {
                    added,
                    updated,
                    removed,
                    ..
                } => {
                    status.set_label(&format_scan_finished(*added, *updated, *removed));
                    // 扫描可能新增了音源记录（ID 是核心分配的），刷新一下列表。
                    reload();
                }
                _ => {}
            });
        }

        Self {
            widget: root.upcast(),
        }
    }
}

/// 打开文件夹选择框，把选中的目录加成本地音源并开始扫描。
///
/// 主窗口的"添加本地文件夹"按钮和 Ctrl+O 快捷键都走这里。
pub fn add_local_folder(app: &App) {
    let dialog = gtk4::FileDialog::builder()
        .title(i18n::SOURCES_PICK_FOLDER)
        .modal(true)
        .build();

    let app = app.clone();
    dialog.select_folder(
        Some(&app.window()),
        None::<&gio::Cancellable>,
        move |result| {
            let file = match result {
                Ok(file) => file,
                Err(err) => {
                    // 用户点"取消"不是错误，不要弹提示。
                    if err.matches(gtk4::DialogError::Cancelled)
                        || err.matches(gtk4::DialogError::Dismissed)
                    {
                        app.status(i18n::SOURCES_CANCELLED);
                    } else {
                        tracing::warn!(error = %err, "{}", i18n::OP_FAILED);
                        app.status(&format!("{}{}", i18n::OP_FAILED, err.message()));
                    }
                    return;
                }
            };
            let Some(path) = file.path() else {
                app.status(&format!("{}{}", i18n::OP_FAILED, i18n::SOURCES_EMPTY));
                return;
            };
            create_local_source(app, path);
        },
    );
}

/// 把目录登记成音源并触发扫描。
fn create_local_source(app: App, path: std::path::PathBuf) {
    let display_path = path.to_string_lossy().to_string();
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| display_path.clone());

    let config = SourceConfig {
        id: None,
        kind: SourceKind::Local,
        name,
        addresses: vec![display_path.clone()],
        root_path: display_path,
        credential_ref: None,
        options: BTreeMap::new(),
        enabled: true,
    };

    let core = app.core().arc();
    glib::spawn_future_local(async move {
        let id = match core.add_source(config).await {
            Ok(id) => id,
            Err(err) => {
                tracing::warn!(error = %err, "{}", i18n::OP_FAILED);
                app.status(&format!("{}{}", i18n::OP_FAILED, i18n::error_text(&err)));
                return;
            }
        };
        // 扫描在核心里后台跑，进度靠事件推送。
        match core.start_scan(id).await {
            Ok(()) => app.status(i18n::SOURCES_ADDED),
            Err(err) => {
                tracing::warn!(error = %err, "{}", i18n::OP_FAILED);
                app.status(&format!("{}{}", i18n::OP_FAILED, i18n::error_text(&err)));
            }
        }
        // 列表由 `ScanFinished` 事件驱动刷新，这里不用额外做什么。
    });
}

/// 重新读一遍音源列表。
fn load_sources(app: App, list: gtk4::ListBox, empty: gtk4::Label) {
    let core = app.core().arc();
    glib::spawn_future_local(async move {
        match core.list_sources().await {
            Ok(sources) => {
                while let Some(row) = list.row_at_index(0) {
                    list.remove(&row);
                }
                empty.set_visible(sources.is_empty());
                for source in sources {
                    list.append(&source_row(app.clone(), source));
                }
            }
            Err(err) => {
                tracing::warn!(error = %err, "{}", i18n::LOAD_FAILED);
                empty.set_label(&format!("{}{}", i18n::LOAD_FAILED, i18n::error_text(&err)));
                empty.set_visible(true);
            }
        }
    });
}

/// 单行音源：图标 + 名称 + 类型 + 路径 + 重新扫描按钮。
fn source_row(app: App, source: SourceConfig) -> gtk4::ListBoxRow {
    let row = gtk4::ListBoxRow::new();
    row.set_activatable(false);
    row.set_selectable(false);

    let line = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
    line.add_css_class("track-row");

    let icon = gtk4::Image::from_icon_name(match source.kind {
        SourceKind::Local => "drive-harddisk-symbolic",
        _ => "network-server-symbolic",
    });
    icon.set_valign(gtk4::Align::Center);
    line.append(&icon);

    let text = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
    text.set_valign(gtk4::Align::Center);
    text.set_hexpand(true);
    let name = gtk4::Label::new(Some(&source.name));
    name.add_css_class("track-title");
    name.set_xalign(0.0);
    name.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    let detail = gtk4::Label::new(Some(&format!(
        "{} · {}",
        i18n::source_kind_text(source.kind),
        source.root_path
    )));
    detail.add_css_class("track-subtitle");
    detail.set_xalign(0.0);
    detail.set_ellipsize(gtk4::pango::EllipsizeMode::Middle);
    text.append(&name);
    text.append(&detail);
    line.append(&text);

    if let Some(id) = source.id {
        let rescan = gtk4::Button::with_label(i18n::SOURCES_RESCAN);
        rescan.add_css_class("pill");
        rescan.set_valign(gtk4::Align::Center);
        let app = app.clone();
        rescan.connect_clicked(move |_| {
            let core = app.core().arc();
            let app = app.clone();
            glib::spawn_future_local(async move {
                match core.start_scan(id).await {
                    Ok(()) => app.status(i18n::SOURCES_RESCAN_STARTED),
                    Err(err) => {
                        tracing::warn!(error = %err, "{}", i18n::OP_FAILED);
                        app.status(&format!("{}{}", i18n::OP_FAILED, i18n::error_text(&err)));
                    }
                }
            });
        });
        line.append(&rescan);
    }

    row.set_child(Some(&line));
    row
}

/// 把 "扫描完成：新增 {added} · 更新 {updated} · 移除 {removed}" 填上数字。
fn format_scan_finished(added: u64, updated: u64, removed: u64) -> String {
    i18n::SOURCES_SCAN_FINISHED
        .replace("{added}", &added.to_string())
        .replace("{updated}", &updated.to_string())
        .replace("{removed}", &removed.to_string())
}

/// 目录名（给音源取名字用；单独提出来方便测试）。
#[allow(dead_code)]
fn folder_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 扫描完成的文案要把三个计数都填进去。
    #[test]
    fn scan_finished_fills_counts() {
        let text = format_scan_finished(3, 1, 0);
        assert!(text.contains('3'));
        assert!(text.contains('1'));
        assert!(!text.contains("{added}"));
    }

    /// 目录名取最后一段。
    #[test]
    fn folder_name_takes_last_segment() {
        assert_eq!(folder_name(Path::new("/home/user/Music")), "Music");
    }
}
