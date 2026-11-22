月兔音乐（Lekis Music）0.2.0 预览版。从这一版起版本号改为普通的语义化版本：1.0 之前的 0.x 都是预览版，在 GitHub 上标为 Pre-release。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

*English summary below.*

## 亮点

- **USB DAC 比特完美直出**（Android 14+）：「设置 → 高级 → 音频输出」里打开后，插上支持比特完美的 USB DAC，音频按原始采样率 / 位深直送解码器，状态行实时显示设备和格式，不满足条件时会说明原因并自动回到普通输出。开启时音量、ReplayGain、均衡器和交叉淡入淡出不生效，也不支持无缝播放。
- **动画全面升级**：专辑卡片点开时封面直接飞到详情页、内容依次浮现；队列和歌单里移动、删除、添加歌曲都有过渡；加载时显示骨架屏，内容淡入替换；Android 14+ 支持预测性返回手势。系统开启「移除动画」时全部改为瞬时或短淡入。
- **窄屏排版**：手机上曲目行的音质标签缩成小标签放在艺人名后面，歌名不再被挤成几个字；歌单、播放队列和电台列表同样修复。
- **悬浮导航栏**：选中态改为与胶囊同心、居中在图标下的色块，去掉了发灰的大阴影。
- **英文界面补全**：之前在 English 模式下仍显示中文的菜单、提示、错误信息和无障碍标签都已翻译。
- **修复**：桌面迷你播放器在 Windows 上可能误操作其他应用窗口的问题。

完整变化见 [CHANGELOG.md](https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md)。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.0-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.0-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS | `lekis-0.2.0-macos-universal.zip` | 未签名公证：首次打开请右键 → 打开，或执行 `xattr -dr com.apple.quarantine lekis.app` |
| Linux x64 | `lekis-0.2.0-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 里是所有文件的 SHA-256 校验和。从 0.1.0-alpha.2 可以直接覆盖安装升级。

## 已知限制

- USB DAC 直出尚未在大量 DAC 型号上验证，遇到问题请附上状态行的提示提 issue。
- 媒体服务器源（Jellyfin / Emby / Plex / OpenSubsonic）还在完善中。
- macOS 包没有签名和公证。

---

## English

From this release on, versions are plain semantic versions: every 0.x release before 1.0 is a preview and is marked Pre-release on GitHub.

**Highlights**

- **USB DAC bit-perfect output** (Android 14+): turn it on under Settings → Advanced → Audio Output and plug in a DAC that supports bit-perfect mode; audio goes straight to it at the source sample rate and bit depth. A status line shows the device and format, or why it fell back to normal output. While active, volume, ReplayGain, EQ and crossfade are bypassed and gapless playback is unavailable.
- **Motion**: album covers fly from the card into the album page with the content settling in after; queue and playlist rows slide, collapse and fade in; skeleton loading states cross-fade to content; Android 14+ predictive back. Everything honours the system's remove-animations setting.
- **Narrow screens**: track rows put a compact codec tag after the artist so titles are no longer cut to a few letters; playlist, queue and radio rows fixed the same way.
- **Floating tab bar**: the selection is a tint concentric with the capsule and centred on its icon; the grey halo is gone.
- **English UI**: menus, messages, errors and accessibility labels that still showed Chinese in English mode are translated.
- **Fix**: the desktop mini player could act on another app's window on Windows.

**Downloads:** Android arm64 APK, Windows x64 zip (portable, run `lekis.exe`), macOS Universal zip (unsigned: right-click → Open the first time), Linux x64 tar.gz. Checksums are in `SHA256SUMS.txt`. Installs over 0.1.0-alpha.2.
