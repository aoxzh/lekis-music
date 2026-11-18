# 编码规范

## 通用

- 代码、标识符、提交信息的 scope 用英文；注释和文档可以用中文。
- 日志不能包含：完整文件路径里的用户名、IP、Token、密码。使用 `lekis_types::redact` 里的辅助函数（以后补充）。
- 所有用户可见的文字都要走本地化资源，不能写死在代码里。
- 新功能必须带测试；修 bug 必须带一个能复现这个 bug 的测试。

## Rust（`core/`、`apps/linux/`）

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
- 依赖：新增依赖要过 `cargo deny`；核心层不能引入 GPL / AGPL 依赖。版本统一写在 workspace 根目录的 `[workspace.dependencies]` 里。

## Kotlin（`apps/android/`）

- Kotlin 官方代码风格；用 ktlint / detekt（以后接入 CI）。
- 架构：单 Activity + Compose Navigation；每个 feature 一个 `Screen` + `ViewModel`；依赖注入用 Hilt。
- ViewModel 暴露 `StateFlow<UiState>`，UI 只读状态、只发事件（单向数据流）。不能在 Composable 里调用核心。
- **只有 `core/bridge` 模块能引用 UniFFI 生成的 `uniffi.lekis_ffi.*` 包**，其他模块只能用 `CoreBridge` 接口。
- 核心的回调在非主线程上触发：`CoreBridge` 负责把它转成 `Flow`，ViewModel 里用 `viewModelScope` 收集。
- 播放必须通过 `LekisPlaybackService`（Media3 `MediaSessionService`），这样锁屏、通知、蓝牙按键、Android Auto 才能正常工作。UI 通过 `MediaController` 控制播放，不直接调用核心的播放方法。
- 颜色、圆角、间距只能用 `core/designsystem` 里的 Token，不能写死数值。

## C#（`apps/windows/`）

- .NET 10，`<Nullable>enable</Nullable>`，`<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`。
- MVVM 用 CommunityToolkit.Mvvm 的源生成器（`[ObservableProperty]`、`[RelayCommand]`）；页面的 code-behind 里只能有和视图相关的代码。
- **只有 `Lekis.Core.Interop` 项目能引用 UniFFI 生成的代码**，App 项目通过 `ICoreService` 接口调用核心。
- 核心的回调在非 UI 线程上触发：用 `DispatcherQueue.TryEnqueue` 切回 UI 线程再修改绑定属性。
- 系统媒体控制（SMTC）统一放在 `MediaControlsService` 里。
- 样式只能引用 `Themes/Tokens.xaml` 里的资源，不能写死颜色和尺寸。

## 数据库

- 表结构只能通过新增迁移文件修改：`core/crates/lekis-library/migrations/NNNN_描述.sql`。
- 列名用 `snake_case`；时间统一存 Unix 毫秒（`INTEGER`）；布尔存 `0/1`。
- 涉及大量行的查询必须有索引，并且在 PR 里附上 `EXPLAIN QUERY PLAN` 的结果。
