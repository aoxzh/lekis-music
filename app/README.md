# Lekis Flutter 客户端

Lekis Music 的 UI，一套 Flutter 代码覆盖 Windows 和 Android（Beta 起加 macOS / iOS / Linux）。所有业务逻辑在 Rust 核心里（[`../core`](../core)），这里只负责显示和交互。

- 代码结构和分层规则：[docs/ARCHITECTURE.md 第 7 节](../docs/ARCHITECTURE.md)
- 编码规范：[docs/CODING_GUIDELINES.md](../docs/CODING_GUIDELINES.md)
- 环境和构建命令：[根目录 README](../README.md#常用命令)

要点：

- `lib/src/rust/` 是 flutter_rust_bridge 生成的代码，不要手改；改了 `core/crates/lekis-bridge/src/api/` 后在本目录跑 `flutter_rust_bridge_codegen generate`（配置见 `flutter_rust_bridge.yaml`）。
- `rust_builder/` 是 Cargokit 插件，`flutter build` / `flutter run` 时会自动编译 Rust 核心，不需要单独的构建脚本。
- 调试用的 `--dart-define`：`LEKIS_START_TAB=library|search|sources|settings`（直接打开某个页面）、`LEKIS_DATA_DIR=<目录>`（换数据目录，例如 10 万首性能库）。
