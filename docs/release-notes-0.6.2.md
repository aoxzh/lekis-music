月兔音乐（Lekis Music）0.6.2 预览版：修复后台补全专辑/封面时资料库列表自动往上回弹的问题，并为资料库专辑页新增多种显示方式切换。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### 资料库专辑多种显示方式

- 资料库专辑页顶栏新增显示方式切换按钮（排序按钮旁），支持自由切换并记住偏好：
  - **标准网格**：经典大封面专辑卡片网格。
  - **紧凑网格**：更密集的多列小封面网格（手机端 3 列起步），一屏展示更多专辑。
  - **高效列表**：固定行高列表（小圆角封面 + 专辑名 + 艺人 · 年份 · 曲目数 + 操作菜单，兼容 2.0× 系统大字号），大曲库快速浏览更高效。

## 修复

### 补全专辑时资料库不再自动回弹

- 后台逐首补全封面或标签时，资料库分页列表改为就地防抖刷新，不再销毁重建滚动控制器或闪回加载骨架屏；往下滑动浏览时滚动位置稳稳停在原处，新补全的封面原地平滑出现。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.6.2-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.6.2-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.6.2-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.6.2-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.6.2-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.6.2-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.6.2-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.6.2 preview release fixes the library scroll jump during background album/cover enrichment and adds switchable display modes for the Albums library view. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Switchable album view modes**: pick between **Standard Grid**, **Compact Grid** (denser multi-column cards), and **Compact List** (fast fixed-height rows with cover, title, artist, year, and track count, adaptive to 2.0× text scaling) from the Library header; your choice is saved automatically.

**Fixed**

- **No more scroll jump during enrichment**: paged library lists now refresh cached pages in place with debouncing instead of recreating the scroll controller on each catalog update, keeping your exact scroll position while newly fetched covers appear smoothly.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
