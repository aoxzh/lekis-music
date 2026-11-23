# Desktop lyrics

Windows 使用 Win32 / DirectWrite，macOS 12+ 使用 AppKit `NSPanel`。两者复用同一份
Rust 歌词时间线、播放时钟、样式、位置记录和事件 API。其他平台暂不支持。

macOS 的 Rust 工作线程计算当前行和逐字高亮，只向主队列传递当前帧；Swift 负责主线程上
的所有 AppKit 对象。主队列忙碌时合并旧帧。仅首次 `show()` 才启动平台线程并创建窗口，
未显示时更新播放状态不需要 `NSApplication` 或 GUI run loop。

macOS 桌面歌词默认使用紧凑深灰实色面板（560pt 宽，可调整），不抢焦点，加入所有 Spaces，
并允许显示在全屏应用上。保留设置中的不透明度百分比滑块，默认 100%，可调到 40%；
`NSPanel.alphaValue` 对整个面板应用一次不透明度，文字不会重复衰减。悬停显示上一首、
播放/暂停、下一首、锁定和关闭；拖动歌词调整位置，拖动右侧边缘调整宽度。锁定后鼠标穿透，
将鼠标移到工具栏锁图标原位置可重新解锁。位置按显示器保存在原有 JSON 结构里。

菜单栏歌词是独立开关，使用系统 13pt 字体和固定 220pt 宽度，长句省略、tooltip 保留全文，
无歌词时回退到曲名。点击菜单可控制播放、切换桌面歌词、锁定/解锁和关闭歌词显示。菜单栏
不受桌面不透明度设置影响。只启用菜单栏时仍同步歌词；只有桌面逐字高亮才进行逐帧渲染。

构建需要 Swift 编译器及 macOS SDK（Xcode 或 Command Line Tools）。`build.rs` 自动
查询工具链，编译并静态链接 Swift 后端及兼容库。核心工作区的 `.cargo/config.toml` 和
Flutter Runner 的 runpath 包含 `/usr/lib/swift`，用于加载系统 Swift concurrency 库。
在其他 Rust 工作区中直接使用此 crate 时，也需为最终可执行文件配置这个系统 runpath。

```sh
cd core
cargo test -p lekis-desktop-lyrics --locked
cargo run -p lekis-desktop-lyrics --example macos_smoke --locked
cargo run -p lekis-desktop-lyrics --example macos_smoke --locked -- --verify /absolute/report.json
```

示例是真实 Rust → Swift → AppKit 窗口，使用生成歌词，不播放网络音频。`--verify` 检查
49 个原生窗口/状态/菜单动作条件后退出。它能在只有 Command Line Tools 的 macOS 上运行；它不等于
完整 Flutter 客户端的构建或 GUI 验收。完整客户端仍需完整 Xcode 与 CocoaPods。
