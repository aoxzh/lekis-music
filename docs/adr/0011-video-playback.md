# ADR-0011：在线音源的官方视频页

- 状态：已接受
- 日期：2026-11-24

## 背景

Lekis Music 是音乐播放器，音频链路已经能通过音源插件解析流媒体。用户希望在不离开听歌流程的情况下，看到当前歌曲对应的官方视频（MV、B 站投稿、多 P 视频等）。早期需求把“视频、电影、电视剧”整体列为非目标，是为了避免把产品做成视频客户端；现在把范围收窄为“在线音源曲目的官方视频页”，不再整体禁止视频。

## 决策

1. **只打开官方页面，不解析视频流。** 音源插件返回一个 HTTPS 页面地址，App 用受限的 WebView（macOS / Android）或系统浏览器（Windows / Linux）打开。不抓取 DASH / FLV / 视频直链，不做 DRM 绕过、转存或下载。
2. **视频地址优先由音源插件提供。** 插件新增可选 `video` 能力：
   ```ts
   video({ id }): Promise<{ url: string; title?: string }>
   ```
   插件清单的 `kinds` 增加 `video`，表示该音源支持视频页。外部 ID 仍是不透明标识，由拥有它的插件解释。
3. **可选“视频播放”插件只做兼容层。** 对于还没有导出 `video` 的老音源，可以由一个 `kinds: ["video"]` 的独立插件接收 `{sourcePluginId, externalId, title, artists}` 并返回页面地址。它只覆盖已知的源 ID，源插件接入 `video` 后自动走音源自己的结果。参考实现对 B 站和常见 YouTube 音源可用，见 `plugin-sdk/examples/video-playback/`。
4. **播放器在核心 App，不在插件里。** JS 插件无法渲染原生窗口。核心只负责校验 URL、打开窗口、暂停音频、恢复焦点。macOS 用现有 WKWebView 窗口，Android 用 WebView Activity，Windows / Linux 用 WebView2 / WebKitGTK 窗口；运行时不完整时退回系统浏览器。应用内打开后会提供一个“在浏览器打开”的小按钮。
5. **官方“视频播放”插件随 App 附带，默认开启。** 插件本身有启用开关；关闭后 B 站的内置兜底也不再显示，用户可以在「设置 → 播放 → 视频播放」关闭整个入口。
6. **兼容旧 B 站插件。** 现有 B 站插件没有 `video` 导出时，由随 App 附带的官方插件补上；如果官方插件被禁用或安装失败，App 仍保留一个内置映射（`BV...|cid` → 官方播放页）作为最后兜底。插件作者接入 `video` 后自动走通用路径。

## 影响

- 不引入 `media_kit` 等第二套原生视频解码/输出栈，保持 Rust 音频链路不变。
- Windows / Linux 新增 `desktop_webview_window` 依赖（WebView2 / WebKitGTK），Linux 构建需要 WebKitGTK / libsoup 开发包。
- 未来 YouTube Music 等音源插件只要实现 `video`，即可复用同一入口。
- 插件必须把视频页域名写进 `permissions.network`；核心在调用后再次校验 HTTPS、URL 凭据和域名权限。
- 视频页仍受上游服务的地域限制、登录要求和风控影响；App 不尝试绕过。
