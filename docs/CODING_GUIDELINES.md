# 编码规范

## 通用

- 代码、标识符、提交信息的 scope 用英文；注释和文档可以用中文。
- 日志不能包含：完整文件路径里的用户名、IP、Token、密码。使用 `lekis_types::redact` 里的辅助函数（以后补充）。
- 所有用户可见的文字都要走本地化资源，不能写死在代码里。
- 新功能必须带测试；修 bug 必须带一个能复现这个 bug 的测试。

## Rust（`core/`）

- 版本以 `core/rust-toolchain.toml` 为准；edition 2021。
- `cargo fmt` + `cargo clippy -- -D warnings` 必须通过。
- **库代码禁止** `unwrap()` / `expect()` / `panic!()`，只有测试和"不可能发生"的情况（必须写注释说明原因）可以用。用 `?` 和 `LekisError`。
- 每个 crate 的公开 API 都要有文档注释（`#![warn(missing_docs)]`）。
- 错误：领域 crate 用 `lekis_types::LekisError`（或者自己的错误类型，再 `impl From` 转换过去），不要用 `anyhow`；`anyhow` 只能用在二进制（`lekis-node`）和测试里。
- 异步：
  - 只在 `lekis-core` 里创建 tokio 运行时；领域 crate 只写 `async fn`，不创建运行时，也不调用 `block_on`。
  - 阻塞操作（SQLite、CPU 密集的解码、图片缩放）用 `spawn_blocking` 或者专用线程，不能直接在 async 任务里跑。
  - 需要 `dyn` 的 async trait 用 `async-trait`。
- 日志：使用 `tracing`，每个模块带 `target`；热路径（解码循环、音频回调）里不能写日志。
- **音频实时线程**：不分配内存、不加锁、不做 IO、不写日志。代码评审重点检查。
- `unsafe`：只允许出现在 FFI 绑定（libsmb2、libnfs、平台音频 API）里，每一处都要写 `// SAFETY:` 注释。
- 依赖：先查 [REUSE.md](REUSE.md)，能复用就复用；新增依赖要过 `cargo deny`，许可证规则见 [ADR-0007](adr/0007-license-and-reuse-first.md)。版本统一写在 workspace 根目录的 `[workspace.dependencies]` 里。

## Flutter / Dart（`app/`）

> UI 改用 Flutter，见 [ADR-0006](adr/0006-flutter-ui.md)。下面是初版规范，Phase 0 结束时补全。

- `flutter analyze` 零警告；`dart format` 必须通过。
- 状态管理用 Riverpod；页面只读状态、只发事件（单向数据流），不在 Widget 里直接调用核心。
- **只有 `app/lib/bridge/` 能引用 flutter_rust_bridge 生成的代码**，其他代码通过 `CoreBridge` 接口调用核心，这样重新生成绑定时只改桥接层。
- 核心事件以 `Stream` 的形式进入 Dart，在 Provider 里转换成 UI 状态；高频事件（播放进度）要节流，不能每个事件都触发重建。
- 长列表一律用按需构建的列表（`ListView.builder` / `SliverList`），分页从核心取数据；图片只加载核心生成好的缩略图路径。
- 颜色、圆角、间距、动效参数只能用从 `design/tokens.json` 生成的主题，不能写死数值。
- 平台原生代码（悬浮歌词窗口、SMTC、CarPlay 等）放在 `app/<平台>/` 下，保持最小。

## 旧的原生 UI（已冻结）

`apps/android`（Kotlin）、`apps/windows`（C#）、`apps/linux`（GTK）已冻结，不再加功能，Flutter 端达到同等功能后删除。旧规范见 git 历史。

## 数据库

- 表结构只能通过新增迁移文件修改：`core/crates/lekis-library/migrations/NNNN_描述.sql`。
- 列名用 `snake_case`；时间统一存 Unix 毫秒（`INTEGER`）；布尔存 `0/1`。
- 涉及大量行的查询必须有索引，并且在 PR 里附上 `EXPLAIN QUERY PLAN` 的结果。
