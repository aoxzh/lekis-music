月兔音乐（Lekis Music）0.2.6 预览版，修复 NAS / 文件系统音源「曲库能看见但播放不了」的问题，并把手动修改和旧版本补全结果也写回音源目录。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 修复

- **NAS 音源能看不能播**：播放前会先确认目标文件可访问；如果内存里的 VFS 连接不存在或已经失效，就按音源配置重新打开并重新登记，再开始解码。之前只依赖进程启动时的登记，重启、凭据晚到或 NAS 断开连接后会报 `no vfs resolver installed`，但曲库仍然能看到。错误提示也改成「音源连接未就绪，请重新扫描或编辑音源」。
- **手动修改写回侧车**：手动换封面、撤销封面、保存或切换歌词版本时，会同步更新 `cover.jpg` / `<歌曲名>.jpg` / 同名 `.lrc`。补全任务仍不覆盖已有的用户侧车文件。
- **旧结果自动迁移**：从 0.2.5 升级后第一次启动，会延迟 20 秒在后台把旧版本只存在缓存里的封面 / 歌词写回源目录，完成后只跑一次；只读共享和媒体服务器自动跳过。
- **侧车性能**：没有来自在线来源的封面 / 歌词时不再枚举源目录，减少 NAS 请求。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.6-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.6-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.6-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.6-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.6-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.6-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.6-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.6 preview release, fixing NAS / filesystem sources that list tracks but cannot play them, and persisting manual edits and pre-0.2.5 enrichment results into source folders.

**Fixes**

- **NAS sources visible but unplayable**: before decoding, the app verifies the target file and reopens/re-registers the VFS from the source config when the in-memory connection is missing or stale. Previously it relied only on the process-startup registry; after a restart, late credentials or a dropped NAS connection, playback failed with `no vfs resolver installed` while the library still listed the tracks. The error is now a readable "source connection not ready; rescan or edit the source".
- **Manual edits write sidecars**: changing/undoing a cover, saving lyrics or switching lyric versions updates `cover.jpg` / `<track>.jpg` / the matching `.lrc`. Enrichment still avoids overwriting existing user sidecar files.
- **One-time migration**: the first launch after upgrading from 0.2.5 waits 20 seconds, then writes covers/lyrics that only exist in the old cache back into source folders in the background. It runs once; read-only shares and media servers are skipped.
- **Sidecar performance**: tracks with no online artwork/lyrics skip directory listing, reducing NAS requests.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
