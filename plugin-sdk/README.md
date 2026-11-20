# Lekis 插件 SDK

对外开放的插件协议。设计见 [REQUIREMENTS 3.11](../docs/REQUIREMENTS.md#311-开放插件平台plugins--developer-ecosystem) 和 [ADR-0003](../docs/adr/0003-plugins-js-first.md)。

| 目录 | 内容 | 状态 |
|---|---|---|
| [`schema/plugin.schema.json`](schema/plugin.schema.json) | `plugin.json` 清单的**唯一定义**（Rust 端 `PluginManifest` 必须和它一致）| 1.0 草案 |
| [`js/`](js/) | `@lekis/plugin-sdk`：TypeScript 类型定义 | 1.0 草案 |
| [`wit/lekis-plugin.wit`](wit/lekis-plugin.wit) | WASM 插件接口 | 1.x 草案 |
| [`examples/lrclib-lyrics/`](examples/lrclib-lyrics/) | 最小示例：LRCLIB 歌词 | 可读 |

宿主现状：JS 运行时（`lekis-plugin-host`，rquickjs）和 App 内本地插件管理（文件夹 / zip 安装、启用、权限、设置、删除）已经可用；WASM 运行时、GitHub topic 索引、脚手架 CLI 还没做（1.0 / 1.x）。

## 一个插件长什么样

```
my-plugin/
├── plugin.json      清单（必须）
├── index.ts         入口：每个能力导出一个函数
└── locales/         多语言（可选）
    ├── zh-CN.json
    └── en.json
```

- **不需要构建**：宿主内置 TS 转译，同一个插件在所有平台上都能运行。
- **每个能力导出一个函数**，参数是一个对象，返回一个对象（或 `null`）。没导出的能力就是不支持。
- **默认零权限**：网络只能访问 `permissions.network` 里列出的域名，而且只能用 HTTPS。
- 出错时抛 `PluginError`（`signIn` / `setup` / `unavailable` / `unsupported` / `rateLimited`），App 会据此提示用户。

## 发布

把插件放在公开的 GitHub 仓库里（`plugin.json` 在仓库根目录），给仓库加上 topic `lekis-plugin`，插件目录会自动收录。

## 版本规则

- `apiVersion` 是插件 API 版本。宿主只加载**主版本号相同**的插件；次版本号增加只会新增可选能力和字段。
- 破坏性变更需要新的 ADR，并且至少提前一个大版本标记废弃。

## 红线

官方仓库不接受任何第三方流媒体音源插件（YouTube、网易云、QQ 音乐等）。见 [CONTRIBUTING.md](../CONTRIBUTING.md) 第 7 节。
