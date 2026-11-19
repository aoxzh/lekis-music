//! 主窗口：左侧导航 + 页面堆栈 + 底部播放条 + 快捷键。
//!
//! 结构照 `apps/windows/src/Lekis.App/MainWindow.xaml`：导航项对应 7 个页面
//! （home / library / search / nowplaying / sources / enrich / settings），
//! 底部是共用的播放条（UIX-02）。

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::gdk;
use gtk4::glib;
use gtk4::prelude::*;

use crate::app::App;
use crate::bridge::EventRouter;
use crate::core_service::CoreHandle;
use crate::i18n;
use crate::pages;
use crate::player_bar;
use crate::theme;

/// 导航项：标签、标题、页面名。顺序和侧栏一致。
const NAV_ITEMS: [(&str, &str); 7] = [
    ("home", i18n::NAV_HOME),
    ("library", i18n::NAV_LIBRARY),
    ("search", i18n::NAV_SEARCH),
    ("nowplaying", i18n::NAV_NOW_PLAYING),
    ("sources", i18n::NAV_SOURCES),
    ("enrich", i18n::NAV_ENRICH),
    ("settings", i18n::NAV_SETTINGS),
];

thread_local! {
    /// 页面切换回调（由主窗口注册，供页面之间互相跳转）。
    static NAVIGATOR: RefCell<Option<Rc<dyn Fn(&str)>>> = const { RefCell::new(None) };
    /// 搜索框聚焦回调（Ctrl+F 用）。
    static SEARCH_FOCUS: RefCell<Option<Rc<dyn Fn()>>> = const { RefCell::new(None) };
}

/// 切换到指定页面（`tag` 取自 [`NAV_ITEMS`]）。
///
/// 页面之间互相跳转（例如首页空状态的"添加音源"按钮）都走这个函数。
pub fn navigate(app: &App, tag: &str) {
    let _ = app;
    NAVIGATOR.with(|slot| {
        if let Some(navigator) = slot.borrow().as_ref() {
            navigator(tag);
        }
    });
}

/// 切到搜索页并把焦点放进搜索框（Ctrl+F）。
fn focus_search(app: &App) {
    navigate(app, "search");
    SEARCH_FOCUS.with(|slot| {
        if let Some(focus) = slot.borrow().as_ref() {
            focus();
        }
    });
}

/// 主窗口。
pub struct MainWindow {
    /// GTK 窗口。
    pub window: gtk4::ApplicationWindow,
}

impl MainWindow {
    /// 构建并显示主窗口。
    pub fn build(app: &gtk4::Application, core: CoreHandle) -> Self {
        let window = gtk4::ApplicationWindow::new(app);
        window.set_title(Some(i18n::APP_NAME));
        window.set_default_size(1180, 760);
        window.add_css_class("lekis-window");

        // 样式：按 tokens.json 的深色 / 浅色板选一套。
        let provider = gtk4::CssProvider::new();
        theme::install(&provider, theme::prefer_dark_from_system());
        if let Some(display) = gdk::Display::default() {
            gtk4::style_context_add_provider_for_display(
                &display,
                &provider,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }

        // 标题栏：左边应用名，右边迷你播放器 / 桌面歌词入口（UIX-08 / UIX-07）。
        let header = gtk4::HeaderBar::new();
        let header_title = gtk4::Label::new(Some(i18n::APP_NAME));
        header_title.add_css_class("title");
        header.set_title_widget(Some(&header_title));
        let mini_button = gtk4::Button::from_icon_name("view-restore-symbolic");
        mini_button.set_tooltip_text(Some(i18n::OPEN_MINI_PLAYER));
        header.pack_end(&mini_button);
        let lyrics_button = gtk4::Button::from_icon_name("format-text-symbolic");
        lyrics_button.set_tooltip_text(Some(i18n::OPEN_LYRICS));
        header.pack_end(&lyrics_button);
        window.set_titlebar(Some(&header));

        // 底部状态提示（扫描进度、错误信息都走这里）。
        let status = gtk4::Label::new(None);
        status.add_css_class("footnote");
        status.set_xalign(0.0);
        status.set_margin_start(16);
        status.set_margin_end(16);
        status.set_margin_top(4);
        status.set_margin_bottom(4);
        status.set_visible(false);

        // 先装事件路由，再建 App——页面创建时就能注册处理器。
        EventRouter::install(&core.arc());
        let app = App::new(core.clone(), window.clone(), status.clone());
        // 核心可能已经恢复过上次的队列，先把快照同步一次再建界面。
        app.player().refresh();

        // 侧栏。
        let (sidebar, nav_list) = build_sidebar();

        // 页面堆栈。
        let stack = gtk4::Stack::new();
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        stack.set_transition_type(gtk4::StackTransitionType::Crossfade);
        stack.set_transition_duration(120);
        stack.add_named(&pages::home::HomePage::new(&app).widget, Some("home"));
        stack.add_named(
            &pages::library::LibraryPage::new(&app).widget,
            Some("library"),
        );
        let search = pages::search::SearchPage::new(&app);
        stack.add_named(&search.widget, Some("search"));
        stack.add_named(
            &pages::now_playing::NowPlayingPage::new(&app).widget,
            Some("nowplaying"),
        );
        stack.add_named(
            &pages::sources::SourcesPage::new(&app).widget,
            Some("sources"),
        );
        stack.add_named(
            &pages::enrich_review::EnrichReviewPage::new(&app).widget,
            Some("enrich"),
        );
        stack.add_named(
            &pages::settings::SettingsPage::new(&app).widget,
            Some("settings"),
        );
        stack.set_visible_child_name("home");

        // 播放条（UIX-02）。
        let player_bar = player_bar::PlayerBar::new(&app);

        let body = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
        body.set_vexpand(true);
        body.append(&sidebar);
        body.append(&stack);

        let root = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        root.append(&body);
        root.append(&status);
        root.append(&player_bar.widget);
        window.set_child(Some(&root));

        // 导航接线。
        register_navigator(&stack, &nav_list);
        SEARCH_FOCUS.with(|slot| {
            *slot.borrow_mut() = Some(Rc::new({
                let entry = search.entry.clone();
                move || {
                    let _ = entry.grab_focus();
                }
            }));
        });

        // 迷你播放器 / 桌面歌词窗口。
        {
            let app = app.clone();
            mini_button.connect_clicked(move |_| crate::mini_player::show(&app));
        }
        {
            let app = app.clone();
            lyrics_button.connect_clicked(move |_| crate::lyrics_window::show(&app));
        }

        install_shortcuts(&app, &window);

        Self { window }
    }
}

/// 侧栏：应用名 + 导航列表 + 脚注。返回侧栏和导航列表本身。
fn build_sidebar() -> (gtk4::Box, gtk4::ListBox) {
    let sidebar = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
    sidebar.add_css_class("sidebar");
    sidebar.set_width_request(240);

    let title = gtk4::Label::new(Some(i18n::APP_NAME));
    title.add_css_class("sidebar-title");
    title.set_xalign(0.0);
    sidebar.append(&title);

    let list = gtk4::ListBox::new();
    list.add_css_class("nav-list");
    list.set_selection_mode(gtk4::SelectionMode::Single);
    for (tag, label) in NAV_ITEMS {
        let row = gtk4::ListBoxRow::new();
        row.set_widget_name(tag);
        let text = gtk4::Label::new(Some(label));
        text.set_xalign(0.0);
        text.add_css_class("sidebar-row");
        row.set_child(Some(&text));
        list.append(&row);
    }
    if let Some(first) = list.row_at_index(0) {
        list.select_row(Some(&first));
    }
    sidebar.append(&list);

    let spacer = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    spacer.set_vexpand(true);
    sidebar.append(&spacer);

    let foot = gtk4::Label::new(Some(&format!(
        "{} {}",
        i18n::APP_NAME,
        env!("CARGO_PKG_VERSION")
    )));
    foot.add_css_class("sidebar-foot");
    foot.set_xalign(0.0);
    sidebar.append(&foot);

    (sidebar, list)
}

/// 把侧栏选项和页面堆栈接起来。
fn register_navigator(stack: &gtk4::Stack, list: &gtk4::ListBox) {
    {
        let stack = stack.clone();
        list.connect_row_selected(move |_, row| {
            if let Some(row) = row {
                let tag = row.widget_name();
                if !tag.is_empty() {
                    stack.set_visible_child_name(&tag);
                }
            }
        });
    }

    // 页面 → 导航：让 `navigate()` 能切页并同步高亮。
    let list_weak = glib::WeakRef::new();
    list_weak.set(Some(list));
    NAVIGATOR.with(|slot| {
        *slot.borrow_mut() = Some(Rc::new(move |tag: &str| {
            let Some(list) = list_weak.upgrade() else {
                return;
            };
            for index in 0..NAV_ITEMS.len() as i32 {
                let Some(row) = list.row_at_index(index) else {
                    continue;
                };
                if row.widget_name() == tag {
                    list.select_row(Some(&row));
                    return;
                }
            }
        }));
    });
}

/// 安装桌面快捷键（UIX-09）。
///
/// 用 `Capture` 阶段拦截，但输入框获得焦点时让路——否则搜索框里打不了空格。
fn install_shortcuts(app: &App, window: &gtk4::ApplicationWindow) {
    let controller = gtk4::EventControllerKey::new();
    controller.set_propagation_phase(gtk4::PropagationPhase::Capture);
    {
        let app = app.clone();
        controller.connect_key_pressed(move |_, key, _, state| shortcut(&app, key, state));
    }
    window.add_controller(controller);
}

/// 单个按键的处理；返回 `Stop` 表示已经消费掉。
fn shortcut(app: &App, key: gdk::Key, state: gdk::ModifierType) -> glib::Propagation {
    let ctrl = state.contains(gdk::ModifierType::CONTROL_MASK);

    // Ctrl 组合键在任何控件上都生效。
    if ctrl {
        match key {
            gdk::Key::f | gdk::Key::F => {
                focus_search(app);
                return glib::Propagation::Stop;
            }
            gdk::Key::o | gdk::Key::O => {
                navigate(app, "sources");
                pages::sources::add_local_folder(app);
                return glib::Propagation::Stop;
            }
            _ => {}
        }
    }

    // 文本输入时不抢空格和方向键。
    if is_text_input(app) {
        return glib::Propagation::Proceed;
    }

    match key {
        gdk::Key::space => {
            app.player().toggle_play_pause();
            glib::Propagation::Stop
        }
        gdk::Key::Left => {
            app.player().seek_by(-5_000);
            glib::Propagation::Stop
        }
        gdk::Key::Right => {
            app.player().seek_by(5_000);
            glib::Propagation::Stop
        }
        _ => glib::Propagation::Proceed,
    }
}

/// 当前焦点是不是文本输入控件。
fn is_text_input(app: &App) -> bool {
    // `focus()` 同时出现在 `GtkWindowExt` 和 `RootExt` 上，这里明确要窗口级焦点。
    let Some(focus) = gtk4::prelude::GtkWindowExt::focus(&app.window()) else {
        return false;
    };
    focus.is::<gtk4::Entry>()
        || focus.is::<gtk4::SearchEntry>()
        || focus.is::<gtk4::PasswordEntry>()
        || focus.is::<gtk4::Text>()
        || focus.is::<gtk4::SpinButton>()
        || focus.is::<gtk4::EditableLabel>()
}
