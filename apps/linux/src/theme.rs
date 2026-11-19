//! 主题样式：把 `design/tokens.json` 里的色板翻译成 GTK4 CSS。
//!
//! 设计令牌的唯一来源是 `design/tokens.json`（见 `docs/ARCHITECTURE.md` 第 7 节），
//! 这里只做“翻译”，不自己发明颜色。改主题请先改 tokens.json 再同步这里。

use gtk4::CssProvider;

/// 一套配色（对应 tokens.json 的 `colors.dark` / `colors.light`）。
struct Palette {
    /// 页面背景。
    background: &'static str,
    /// 卡片 / 侧栏背景。
    surface: &'static str,
    /// 次级填充（列表悬停、徽章底色）。
    surface_variant: &'static str,
    /// 正文颜色。
    on_background: &'static str,
    /// 次要文字。
    on_surface_variant: &'static str,
    /// 分隔线。
    outline: &'static str,
    /// 强调色。
    accent: &'static str,
    /// 强调色上的文字。
    on_accent: &'static str,
    /// 强调色的浅色底。
    accent_soft: &'static str,
    /// 月亮色（收藏、点缀）。
    moon: &'static str,
    /// 危险色。
    danger: &'static str,
}

/// 深色板。
const DARK: Palette = Palette {
    background: "#0B0A10",
    surface: "#15141C",
    surface_variant: "#201E29",
    on_background: "#F3F1FA",
    on_surface_variant: "#A9A5B8",
    outline: "#2E2C3A",
    accent: "#9C99FF",
    on_accent: "#0B0A10",
    accent_soft: "#2A2850",
    moon: "#F2C46B",
    danger: "#FF6B81",
};

/// 浅色板。
const LIGHT: Palette = Palette {
    background: "#FBFAFF",
    surface: "#FFFFFF",
    surface_variant: "#F1EFF8",
    on_background: "#14131A",
    on_surface_variant: "#5E5B6B",
    outline: "#DDDAE6",
    accent: "#5B57D6",
    on_accent: "#FFFFFF",
    accent_soft: "#E7E5FF",
    moon: "#E8B04B",
    danger: "#D6455B",
};

/// 把当前主题写进 CSS Provider（重复调用即切换主题）。
pub fn install(provider: &CssProvider, dark: bool) {
    // GTK 4.12 之前只有 `load_from_data`；本项目按 GTK 4.10 打底。
    #[allow(deprecated)]
    provider.load_from_data(&stylesheet(dark));
}

/// 系统是否偏好深色（跟随 `gtk-application-prefer-dark-theme`）。
pub fn prefer_dark_from_system() -> bool {
    gtk4::Settings::default().is_some_and(|s| s.is_gtk_application_prefer_dark_theme())
}

/// 生成完整样式表。
pub fn stylesheet(dark: bool) -> String {
    let p = if dark { &DARK } else { &LIGHT };
    format!(
        r#"
/* ---------- 基础 ---------- */
window.lekis-window {{
  background-color: {background};
  color: {on_background};
}}

/* ---------- 侧栏 ---------- */
.sidebar {{
  background-color: {surface};
  border-right: 1px solid {outline};
  padding: 12px 8px;
  min-width: 216px;
}}
.sidebar-title {{
  font-size: 15pt;
  font-weight: 700;
  padding: 6px 12px 14px 12px;
  color: {on_background};
}}
.sidebar-row {{
  border-radius: 8px;
  padding: 9px 12px;
  color: {on_surface_variant};
  font-size: 11pt;
}}
.sidebar-row:hover {{
  background-color: {surface_variant};
  color: {on_background};
}}
.sidebar-row:selected {{
  background-color: {accent_soft};
  color: {accent};
  font-weight: 600;
}}
.sidebar-foot {{
  color: {on_surface_variant};
  font-size: 9pt;
  padding: 8px 12px;
}}

/* ---------- 页面 ---------- */
.page {{
  padding: 24px 32px;
}}
.page-title {{
  font-size: 22pt;
  font-weight: 700;
  color: {on_background};
}}
.page-subtitle {{
  font-size: 11pt;
  color: {on_surface_variant};
}}
.section-title {{
  font-size: 13pt;
  font-weight: 600;
  color: {on_background};
}}
.dim {{
  color: {on_surface_variant};
}}
.empty-title {{
  font-size: 15pt;
  font-weight: 600;
  color: {on_background};
}}
.footnote {{
  font-size: 9pt;
  color: {on_surface_variant};
}}
.card {{
  background-color: {surface};
  border: 1px solid {outline};
  border-radius: 16px;
  padding: 16px 20px;
}}
.card-title {{
  font-size: 10pt;
  font-weight: 600;
  color: {on_surface_variant};
}}
.card-value {{
  font-size: 12pt;
  color: {on_background};
}}

/* ---------- 列表行 ---------- */
.track-row {{
  padding: 6px 10px;
  border-radius: 8px;
}}
.track-row:hover {{
  background-color: {surface_variant};
}}
.track-title {{
  font-size: 11pt;
  color: {on_background};
}}
.track-subtitle {{
  font-size: 9pt;
  color: {on_surface_variant};
}}
.badge {{
  background-color: {accent_soft};
  color: {accent};
  border-radius: 6px;
  padding: 1px 7px;
  font-size: 8pt;
  font-weight: 600;
}}
.badge-moon {{
  color: {moon};
  font-size: 11pt;
}}
.cover {{
  background-color: {surface_variant};
  color: {on_surface_variant};
  border-radius: 6px;
  font-size: 16pt;
}}
.cover-large {{
  background-color: {surface_variant};
  color: {on_surface_variant};
  border-radius: 14px;
  font-size: 40pt;
}}

/* ---------- 播放器 ---------- */
.player-bar {{
  background-color: {surface};
  border-top: 1px solid {outline};
  padding: 10px 16px;
}}
.player-title {{
  font-size: 11pt;
  font-weight: 600;
  color: {on_background};
}}
.player-subtitle {{
  font-size: 9pt;
  color: {on_surface_variant};
}}
.play-button {{
  border-radius: 999px;
  min-width: 40px;
  min-height: 40px;
  background-color: {accent};
  color: {on_accent};
  font-weight: 700;
  border: none;
}}
.play-button:hover {{
  background-color: {accent};
}}
.transport {{
  border-radius: 999px;
  min-width: 36px;
  min-height: 36px;
  background-color: transparent;
  color: {on_background};
  border: none;
}}
.transport:hover {{
  background-color: {surface_variant};
}}
.toggle-active {{
  color: {accent};
  font-weight: 700;
}}
.now-playing-title {{
  font-size: 30pt;
  font-weight: 700;
  color: {on_background};
}}
.now-playing-subtitle {{
  font-size: 15pt;
  color: {on_surface_variant};
}}
.time-label {{
  font-size: 9pt;
  color: {on_surface_variant};
}}

/* ---------- 迷你播放器 / 桌面歌词 ---------- */
.mini-title {{
  font-size: 11pt;
  font-weight: 600;
  color: {on_background};
}}
.lyrics-line {{
  font-size: 22pt;
  font-weight: 700;
  color: {on_background};
}}
.lyrics-active {{
  font-size: 22pt;
  font-weight: 700;
  color: {accent};
}}

/* ---------- 错误提示（核心返回 PermissionDenied / Io 之类时用） ---------- */
.danger {{
  color: {danger};
}}
"#,
        background = p.background,
        surface = p.surface,
        surface_variant = p.surface_variant,
        on_background = p.on_background,
        on_surface_variant = p.on_surface_variant,
        outline = p.outline,
        accent = p.accent,
        on_accent = p.on_accent,
        accent_soft = p.accent_soft,
        moon = p.moon,
        danger = p.danger,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两种色板都能生成非空样式表，并且包含关键 class。
    #[test]
    fn stylesheet_contains_core_classes() {
        for dark in [true, false] {
            let css = stylesheet(dark);
            assert!(css.contains(".player-bar"));
            assert!(css.contains(".sidebar-row"));
            assert!(css.contains(".now-playing-title"));
        }
    }
}
