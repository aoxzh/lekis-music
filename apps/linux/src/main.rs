//! Lekis 音乐的 Linux 桌面前端（Rust + GTK4）。
//!
//! 分层和 `docs/ARCHITECTURE.md` 第 7 节一致：
//!
//! ```text
//! main      → 建 GTK Application、启动核心、出错时给一个错误窗口
//! window    → 主窗口：侧栏 + 页面堆栈 + 播放条 + 快捷键
//! pages/*   → 7 个页面，只摆控件 + 调核心
//! app       → 界面上下文（核心句柄 / 播放器 / 事件路由 / 状态提示）
//! bridge    → 核心线程的事件搬到 GTK 主线程
//! player    → 播放快照（进度靠 PositionTick，不轮询）
//! ```
//!
//! UI 层没有业务逻辑：扫描、索引、搜索、播放都交给 `lekis-core`。

mod app;
mod bridge;
mod core_service;
mod i18n;
mod lyrics;
mod lyrics_window;
mod mini_player;
mod pages;
mod player;
mod player_bar;
mod theme;
mod track_list;
mod widgets;
mod window;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

use crate::core_service::CoreHandle;

/// GTK 应用 ID（和 `.desktop` 文件、MPRIS 的 `dev.lekis.music` 保持一致）。
const APP_ID: &str = "dev.lekis.music";

fn main() -> glib::ExitCode {
    // TODO(PTF-02)：需要 `RUST_LOG` 精细过滤时给 tracing-subscriber 打开
    // `env-filter` feature；现在只按固定级别打日志，保持依赖精简。
    tracing_subscriber::fmt().with_max_level(log_level()).init();

    // `FLAGS_NONE` 在 glib 2.74 之后被标成 deprecated，用 `empty()` 表达"没有额外标志"。
    let application = gtk4::Application::new(Some(APP_ID), gio::ApplicationFlags::empty());
    application.connect_activate(|application| {
        // 只有一个主窗口：再次激活就把它提到前面。
        if let Some(window) = application.active_window() {
            window.present();
            return;
        }
        match CoreHandle::start() {
            Ok(core) => {
                // 主窗口要活到应用退出：留一个引用在 `connect_activate` 里就够了，
                // GTK 自己会持有它（`ApplicationWindow::new` 带 application 引用）。
                let main = window::MainWindow::build(application, core);
                main.window.present();
            }
            Err(err) => {
                // 核心起不来时不能 panic：给用户一个能读的错误窗口。
                tracing::error!(error = %err, "核心启动失败");
                show_error_window(application, &i18n::error_text(&err));
            }
        }
    });
    application.run()
}

/// 日志级别：默认只打 `warn` 及以上，`LEKIS_LOG=info|debug|trace` 可以放宽。
fn log_level() -> tracing::Level {
    match std::env::var("LEKIS_LOG")
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "trace" => tracing::Level::TRACE,
        "debug" => tracing::Level::DEBUG,
        "info" => tracing::Level::INFO,
        _ => tracing::Level::WARN,
    }
}

/// 核心启动失败时的错误窗口。
///
/// 这里不用 `AlertDialog`：窗口还没建出来，需要一个能独立显示的顶层窗口。
fn show_error_window(application: &gtk4::Application, message: &str) {
    let window = gtk4::ApplicationWindow::new(application);
    window.set_title(Some(i18n::APP_NAME));
    window.set_default_size(520, 180);

    let body = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
    body.set_margin_top(24);
    body.set_margin_bottom(24);
    body.set_margin_start(24);
    body.set_margin_end(24);

    let title = gtk4::Label::new(Some(i18n::APP_NAME));
    title.add_css_class("page-title");
    title.set_xalign(0.0);

    let detail = gtk4::Label::new(Some(&format!("{}{}", i18n::OP_FAILED, message)));
    detail.add_css_class("dim");
    detail.set_wrap(true);
    detail.set_xalign(0.0);

    let hint = gtk4::Label::new(Some(
        "请确认 $XDG_DATA_HOME / $HOME 可写后重试。详细原因已经写进日志。",
    ));
    hint.add_css_class("footnote");
    hint.set_wrap(true);
    hint.set_xalign(0.0);

    body.append(&title);
    body.append(&detail);
    body.append(&hint);
    window.set_child(Some(&body));
    window.present();
}
