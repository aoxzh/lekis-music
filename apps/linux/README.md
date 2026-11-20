# Lekis 音乐 · Linux 桌面版

> **已冻结**（[ADR-0006](../../docs/adr/0006-flutter-ui.md)）：UI 已改用 Flutter（[`app/`](../../app/)）。这里不再加功能、不作为日常构建目标，Alpha 退出后连同 `core/crates/lekis-ffi`、`tools/gen-bindings.*`、`tools/build-*-core.*` 和对应 CI 一起删除。下面的内容只作历史参考。

Lekis Music 的 Linux 前端：**Rust + GTK4**。

界面结构和 [`apps/windows`](../windows)（C#/WinUI3）、[`apps/android`](../android)
（Kotlin/Compose）保持一致——同样的 7 个页面、同样的底部播放条，方便三个平台一起改。

```
apps/linux/
├── Cargo.toml            # 独立 workspace（见下文"为什么不并入 core"）
└── src/
    ├── main.rs           # GTK Application 入口 + 核心启动失败的兜底窗口
    ├── window.rs         # 主窗口：侧栏导航 + 页面堆栈 + 播放条 + 快捷键
    ├── app.rs            # 界面上下文（核心句柄 / 播放器 / 事件路由 / 状态提示）
    ├── bridge.rs         # 核心线程事件 → GTK 主线程的桥
    ├── core_service.rs   # 启动 lekis-core：XDG 目录、CoreConfig、PlatformServices
    ├── player.rs         # 播放快照（进度靠 PositionTick，不轮询）
    ├── player_bar.rs     # 底部播放条（UIX-02）
    ├── track_list.rs     # 可复用分页曲目列表（ListView + ListStore）
    ├── widgets.rs        # 播放条 / 正在播放页共用的小控件
    ├── mini_player.rs    # 桌面迷你播放器（UIX-08 骨架）
    ├── lyrics.rs         # LRC 解析与当前行判定（有单测）
    ├── lyrics_window.rs  # 桌面歌词窗口（UIX-07 骨架）
    ├── theme.rs          # design/tokens.json → GTK4 CSS
    ├── i18n.rs           # 界面中文文案集中处
    └── pages/            # home / library / search / now_playing / sources / enrich_review / settings
```

## 构建环境

### Linux（Debian / Ubuntu）

```bash
sudo apt install build-essential pkg-config libgtk-4-dev libasound2-dev
cargo build --release
```

其它发行版：

| 发行版 | 包 |
| --- | --- |
| Fedora | `gtk4-devel alsa-lib-devel pkgconf-pkg-config` |
| Arch | `gtk4 alsa-lib pkgconf` |
| openSUSE | `gtk4-devel alsa-devel pkg-config` |

需要 **GTK ≥ 4.10**（用到 `FileDialog`）。用 `pkg-config --modversion gtk4` 确认。

### 运行

```bash
cargo run --release
# 或者
./target/release/lekis-linux
```

数据与缓存目录遵循 XDG：

| 内容 | 默认位置 |
| --- | --- |
| 数据库、`device_id` | `$XDG_DATA_HOME/lekis-music`（默认 `~/.local/share/lekis-music`）|
| 缩略图、缓存 | `$XDG_CACHE_HOME/lekis-music`（默认 `~/.cache/lekis-music`）|

日志默认只打 `warn` 及以上；`LEKIS_LOG=info` / `debug` / `trace` 可以放宽：

```bash
LEKIS_LOG=debug cargo run
```

## 在 Windows 上交叉验证编译

本仓库在 Windows 上用 msys2 的 GTK4 做**编译验证**（不是发布目标——发布目标是 Linux）：

```powershell
cd <仓库根目录>
. .\tools\env-windows-gnu.ps1
$env:PATH="C:\msys64\ucrt64\bin;C:\msys64\usr\bin;$env:PATH"
$env:PKG_CONFIG_PATH="C:\msys64\ucrt64\lib\pkgconfig"
$env:PKG_CONFIG="C:\msys64\ucrt64\bin\pkg-config.exe"   # 必须在 ucrt64\bin，不是 usr\bin
cd apps\linux
cargo check
```

依赖（`pacman -S --needed`）：`mingw-w64-ucrt-x86_64-gtk4`、`mingw-w64-ucrt-x86_64-pkgconf`。

> `PKG_CONFIG` 必须指向 `C:\msys64\ucrt64\bin\pkg-config.exe`。指到 `usr\bin`
> 的那个会找不到 GTK4 的 `.pc` 文件，报 `The pkg-config command could not be found`。

格式化与单元测试：

```bash
cargo fmt --check
cargo test
```

## 为什么不并入 `core/` 的 workspace

`core/` 是**跨平台**的领域层工作区（Android 也要编译它）。GTK4 只有 Linux 前端需要，
并且它在 Windows/Android 上没有可用依赖，混进同一个 workspace 会让
`cargo build -p lekis-core` 在那些环境下直接失败。

所以 `apps/linux/Cargo.toml` 里有一个空的 `[workspace]` 表把它独立出来；
代价是不能用 `workspace = true` 继承版本号，依赖要写全。

## 架构约束

来自 [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) 第 7 节：

- **UI 层没有业务逻辑**：扫描、索引、搜索、播放决策全在 `lekis-core`。页面只摆控件、
  调公开 API、订阅事件。
- **不自己建 tokio 运行时**：`LekisCore` 自带（`core/crates/lekis-core/src/lib.rs`）；
  界面通过 `glib::spawn_future_local` 等它的 `async` API。
- **大列表必须分页**：`TrackQuery` 的 `offset`/`limit`，单页上限 `MAX_LIMIT = 500`，
  这里用 200（`track_list::PAGE_SIZE`）。
- **进度不轮询**：靠 `CoreEvent::PositionTick`（播放中 250 ms 一次）驱动进度条。
- **实时线程不分配不加锁**：这条约束在 `lekis-playback` 里，界面不碰音频线程。

事件路径：

```
lekis-core 线程
   └─ EventListener::on_event(CoreEvent)
        └─ glib::MainContext::invoke(...)      // bridge.rs：搬回主线程
             └─ Player::apply_event           // player.rs：合并进快照
                  └─ HUD 回调（播放条 / 正在播放 / 迷你播放器 / 歌词）
```

## 功能与快捷键

底部播放条与"正在播放"页共用一份状态：播放 / 暂停、上一首 / 下一首、进度拖动、
音量、循环模式（关闭 → 列表 → 单曲）、随机模式（关闭 → 随机 → 智能）。

| 快捷键 | 作用 |
| --- | --- |
| `空格` | 播放 / 暂停 |
| `←` / `→` | 后退 / 前进 5 秒 |
| `Ctrl+O` | 添加本地文件夹音源 |
| `Ctrl+F` | 聚焦搜索框 |

焦点在文本输入框里时，空格和方向键交给输入框（不抢按键）。

## 还没做的部分

这些是有意留下的占位，代码里都标了对应的需求编号：

| 位置 | 说明 |
| --- | --- |
| `mini_player.rs` | **UIX-08**：置顶（GTK4 未暴露 `set_keep_above`）、无边框拖拽、位置记忆 |
| `lyrics_window.rs` | **UIX-07**：核心还没有歌词接口（ENR-04），现在只显示占位；锁定/穿透、字体颜色设置、平滑滚动未做 |
| `pages/enrich_review.rs` | **ENR-06**：核心只推队列长度，`list_enrich_candidates` / accept / reject 未接通 |
| `pages/settings.rs` | **SET-01~04**：主题跟随系统、语言、音频输出（独占/比特完美）、ReplayGain、缓存上限、插件、同步、隐私 |
| `pages/sources.rs` | **SRC-04~06**：SMB / WebDAV / NFS / SFTP 与服务器音源（OpenSubsonic / Jellyfin / Emby / Plex）的添加表单 |
| `pages/home.rs` | **HOME-\***：继续播放、每日混音、"好久没听"、按时段推荐 |
| `track_list.rs` / `widgets.rs` | **ART-01**：封面解码通路还没接，目前用纯色方块 + ♪ 占位 |
| `core_service.rs` | **PTF-02**：凭据改用 libsecret 存（现在是内存实现，重启要重新输密码）；MPRIS / 媒体键未接 |

## 后续打包（PTF-02）

Flatpak（`org.gnome.Platform` runtime）、AppImage、`.deb` / `.rpm` 都还没做。
`.desktop` 文件和图标资源也还没加；应用 ID 已经定成 `dev.lekis.music`，
和 MPRIS、`.desktop` 的命名保持一致。
