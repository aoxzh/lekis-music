# 设计 Token

[`tokens.json`](tokens.json) 是颜色、圆角、间距、字号、动效参数的**唯一来源**，三个平台必须保持一致：

| 平台 | 对应文件 |
|---|---|
| Android | [`apps/android/core/designsystem/src/main/kotlin/dev/lekis/designsystem/Tokens.kt`](../apps/android/core/designsystem/src/main/kotlin/dev/lekis/designsystem/Tokens.kt) |
| Windows | [`apps/windows/src/Lekis.App/Themes/Tokens.xaml`](../apps/windows/src/Lekis.App/Themes/Tokens.xaml) |
| Linux | 以后（GTK CSS 变量）|

现在是手动同步，改 `tokens.json` 的 PR 必须同时改上面两个文件。以后改成脚本自动生成（`tools/gen-tokens`）。

## 视觉方向（月兔音乐）

- 主色：月夜靛紫（`accent`），点缀色：月光金（`moon`，只用于少量强调，例如"正在播放"的波形、收藏的心形）。
- 内容第一：封面是主角，界面元素尽量退后；正在播放页的背景从封面取色，主色只用在可交互的控件上。
- 不照抄 Apple Music 的布局和图标，只借鉴它的质感：大封面、取色背景、逐字歌词、弹簧动效。
