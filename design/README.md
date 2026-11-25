# 设计 Token

[`tokens.json`](tokens.json) 是颜色、圆角、间距、字号、动效参数的**唯一来源**。

| 平台 | 对应文件 |
|---|---|
| Flutter（所有平台） | [`app/lib/src/theme/tokens.dart`](../app/lib/src/theme/tokens.dart) |

现在是手动同步：改 `tokens.json` 的 PR 必须同时改 `tokens.dart`。

视觉方向：月夜靛紫 + 月光金，内容第一。
