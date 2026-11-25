# Lekis Music 0.1.0-alpha.1

> 这段是 GitHub pre-release 的正文，会随 `v0.1.0-alpha.1` 标签由 [.github/workflows/release.yml](../.github/workflows/release.yml) 发布。完整变更见 [CHANGELOG.md](../CHANGELOG.md)，安装和构建细节见 [README.md](../README.md)。

## 这是什么

第一个公开预览版，给愿意早点用、也愿意报 bug 的人。**这是预览软件，不是正式版**：会崩，有没做完的地方，数据和设置格式也可能在后续版本里变。

- 只有 Android APK（arm64-v8a）和 Windows x64 免安装 zip。
- macOS、iOS、Linux 不在这个版本里，Beta 跟进。

## 能用的部分

- 播放：本地和 NAS 上的歌能播；样本级无缝、Windows WASAPI 独占、ReplayGain、10 段均衡器、睡眠定时、会话恢复。
- 资料库：专辑 / 艺人 / 歌曲 / 流派 / 文件夹 / 喜欢，歌单和智能歌单，10 万首级别的库（冷启动约 0.3 s）。
- 音源：本地文件夹、SMB、WebDAV，局域网自动发现 NAS；密码按引用保存，数据库里不存明文。
- 歌词和封面：逐行 / 逐字歌词、经典样式默认、手动编辑和偏移；封面和歌词自动补全。
- 另外：播客、本地插件管理、离线下载、Windows 托盘、系统媒体控件（SMTC / 锁屏 / 通知）。

## 还很糙 / 已知坏掉

- **Windows 可能崩溃（阻塞）**：以前保存过播放会话时，启动约 3.8 s 后可能崩在 `flutter_windows.dll+0x3cf16`（`0xC0000005`），交互中也会偶发；崩溃时 stderr 只有 Flutter accessibility bridge 的 `Failed to update ui::AXTree`。
- Windows 验收没做完：均衡器只验了开关和预设列表，库健康、标签编辑、托盘、正在播放页还没逐项过。
- 在 "Lekis Stage Preview" 这首暂停时歌词面板空白，是已知 bug。
- 播客、设置页改版和桌面播放条还没做完整真机复验。
- Jellyfin / Emby / Plex / OpenSubsonic 源只有表单和核心客户端，Beta 前才完整验收。

## 安装

### Android

- 下载 APK：`lekis-0.1.0-alpha.1-android-arm64-v8a.apk`（只提供 64 位 ARM 版，绝大多数手机和折叠屏都适用）。
- 没有上架任何商店，需要侧载：允许「安装未知应用」，用文件管理器点开 APK 安装。需要 Android 8.0（API 26）及以上。
- 官方包用 release key 签名；自己本地构建又没配 keystore 时会退回 debug 签名，那种包装不上正式版，也不能覆盖升级。

### Windows

- 下载 `lekis-0.1.0-alpha.1-windows-x64.zip`，解压到任意目录，运行里面的 `lekis.exe`，不需要安装。
- 需要 Windows 10/11 x64 和一块可用的音频输出设备（WASAPI）；VC++ 运行库已经打进 zip，不用另外装。
- GitHub Release 里附了 `SHA256SUMS.txt`，下载后可以自己核对（Windows 用 `certutil -hashfile <文件> SHA256`，macOS / Linux 用 `shasum -a 256`）。

## 数据放在哪

- Windows：`%APPDATA%\dev.lekis\lekis\`，里面有 `library.sqlite`、`credentials.json`、`offline/`、`plugins/`。
- Android：应用私有目录（包名 `dev.lekis.music`），卸载会一起删掉；升级或换安装方式前先备份。
- 播放和设置数据只存在本机，不会上传；联网只用于你自己配置的音源、封面和歌词补全、播客目录搜索，以及（开了才有的）听歌上报。

## 怎么报 bug

- 用 GitHub Issues，写清版本号、平台、机型或系统版本、复现步骤。
- 附上诊断日志：设置 → 高级 → 诊断日志，复制后贴进 issue（目前是复制文本，不是导出文件；用户名、IP、Token 等敏感字段会自动打码）。
- 启动崩溃的话，把能看到的报错一起贴上，例如 stderr 里的 `flutter_windows.dll+...` 地址或 `Failed to update ui::AXTree`。
