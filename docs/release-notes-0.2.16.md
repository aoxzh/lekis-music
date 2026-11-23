月兔音乐（Lekis Music）0.2.16 预览版，扫描进度会估算剩余时间，大库和 NAS 扫描更容易判断还要等多久。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **扫描剩余时间**：音源详情和列表的扫描进度会按当前阶段的平均速度估算「剩余约 X 分钟 / 秒」；总数未知时仍显示已处理数量，不会给出不可靠的估计。
- 包含 0.2.15 的搜索结果分类筛选、0.2.14 的最近搜索和 0.2.13 的歌词偏移快捷调整。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.16-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.16-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.16-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.16-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.16-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.16-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.16-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.16 preview release, estimating the remaining scan time so large libraries and NAS scans are easier to wait for. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Remaining scan time**: source details and source rows now estimate "About Xm/Xs left" from the current phase's average speed. When the total is unknown, only the processed count is shown, so the estimate never becomes misleading.
- Includes the 0.2.15 search result filters, 0.2.14 recent searches, and 0.2.13 quick lyric-offset actions.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
