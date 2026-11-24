月兔音乐（Lekis Music）0.5.4 预览版：新增官方视频页和日语歌词注音。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### 官方视频页（默认开启）

- 在线音源曲目的「更多」菜单可以打开对应 MV / 投稿 / Live 的官方视频页。
- macOS、Android、Windows 和 Linux 都使用受限的内嵌 WebView；WebView2 / WebKitGTK 运行时不完整时自动退回系统浏览器。
- 应用内打开后，菜单和提示条都提供「在浏览器打开视频」入口。
- 打开视频时暂停当前音频；只打开官方页面，不解析、不转存视频流。
- 官方「视频播放」插件随 App 附带并默认启用；音源插件新增 `video` 能力，旧 B 站插件仍走兼容映射。可以在「设置 → 播放 → 视频播放」或插件页关闭。

### 日语歌词注音

- 「设置 → 歌词 → 注音歌词」新增「日文假名」和「日文罗马音」。
- 日文歌词没有自带罗马音时，可以在汉字上方标出振假名，或给汉字和假名整体标上 Hepburn 罗马音。
- 读音由内置的常用汉字表离线计算，不联网、不加词典包。
- 中文拼音只作用于不带假名的行，日文注音只作用于带假名的行，二者不会互相误标。经典歌词视图生效。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.5.4-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.5.4-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.5.4-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.5.4-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.5.4-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.5.4-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.5.4-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.5.4 preview release adds official video pages and Japanese ruby lyrics. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Official video pages (on by default)**: the “More” menu on source tracks opens the official MV / upload / live replay page. macOS, Android, Windows and Linux use a restricted in-app WebView; if the WebView2 / WebKitGTK runtime is unavailable, the page falls back to the system browser. In-app playback also offers “Open video in browser” in both the menu and the snackbar. Audio pauses when the video opens; only the official page is opened, and video streams are never extracted or stored. The official Video Playback plugin ships with the app and is enabled by default; source plugins gain an optional `video` capability. Turn it off in Settings → Playback → Video Playback or on the plugin page.
- **Japanese ruby lyrics**: Settings → Lyrics → Ruby Lyrics adds “Japanese Kana” and “Japanese Romaji”. Japanese lines can show furigana above kanji, or Hepburn romaji over the whole line. Readings are computed offline from a built-in common-kanji table. Chinese pinyin applies only to lines without kana, and Japanese ruby only to lines with kana, so they never mislabel each other. Classic lyrics view only.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
