月兔音乐（Lekis Music）0.5.6 预览版：资料库和搜索里显示艺人头像。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### 艺人头像

- 艺人列表、搜索结果和艺人详情页显示艺人照片，不再只有首字母。
- 没有头像的艺人在首次显示时从网易云音乐 / Deezer 免 Key 查一次：名字须完全一致（简繁、大小写归一），中日韩名字优先查网易云，其余优先查 Deezer；网易云别名只在正名都对不上时才参考，避免误配到同名账号。
- 查到的照片存进本机封面缓存，之后离线也能显示；查不到的保留首字母头像，30 天内不再重复查询。
- 「群星」「Various Artists」「未知艺人」这类占位名不会去查。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.5.6-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.5.6-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.5.6-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.5.6-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.5.6-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.5.6-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.5.6-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.5.6 preview release adds artist photos to the library and search. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Artist photos**: the artist list, search results and artist pages show the artist's photo instead of only an initial. Artists without one are looked up once from NetEase Cloud Music / Deezer (no API key; the name must match exactly after simplified/traditional and case folding; CJK names try NetEase first). Found photos go into the local artwork cache and also show offline; artists with no match keep the initial avatar and are not looked up again for 30 days. Placeholder names such as "Various Artists" or "Unknown Artist" are skipped.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
