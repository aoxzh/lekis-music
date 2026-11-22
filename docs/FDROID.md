# F-Droid & IzzyOnDroid Packaging Guide · F-Droid 上架指南

Lekis Music (`dev.lekis.music`) is 100% FOSS (`MPL-2.0`), with zero proprietary blobs, zero Google Play Services, and `dependenciesInfo` disabled in `app/android/app/build.gradle.kts`.

## FOSS Compliance Checklist

- [x] **OSI-Approved License**: Mozilla Public License 2.0 (`MPL-2.0`)
- [x] **No Proprietary Blobs / GMS**: Zero Google Play Services, Firebase, Crashlytics, AdMob, or analytics SDKs
- [x] **No Encrypted Google Dependency Block**: `dependenciesInfo { includeInApk = false; includeInBundle = false }` enabled
- [x] **Fastlane Metadata + Screenshots Included**: `fastlane/metadata/android/en-US/` and `zh-CN/` (title, descriptions, changelogs, icon, phoneScreenshots)
- [x] **Tag & Release Pipeline Ready**: `v0.1.0-alpha.2` (remember to click **Publish release** on the GitHub Release draft before submitting!)

---

## 通道 1：IzzyOnDroid（最快，已迁至 Codeberg）

> **注意**：IzzyOnDroid 已从 GitLab 迁移至 **Codeberg**，原 GitLab 仓库已失效（404）。

- **提交地址**：<https://codeberg.org/IzzyOnDroid/repodata/issues>
- **收录政策**：<https://izzyondroid.org/docs/general/AppInclusionPolicy/>
- **说明**：IzzyOnDroid 直接分发你 GitHub Release 中的签名 APK，并自动抓取本仓库 `fastlane/metadata/android/` 的图标、介绍与截图。通常 1–3 天过审（Flutter + Rust 应用 APK 若略超 30 MB 软限制，说明仅提供 `arm64-v8a` 单 ABI 即可）。

### 可直接复制的 IzzyOnDroid Issue 模板

```markdown
### Application Information
- **App Name:** Lekis Music
- **Package ID:** `dev.lekis.music`
- **License:** MPL-2.0
- **Source Code:** https://github.com/aoxzh/lekis-music
- **Issue Tracker:** https://github.com/aoxzh/lekis-music/issues
- **Release Tag:** `v0.1.0-alpha.1`
- **APK Asset:** https://github.com/aoxzh/lekis-music/releases/download/v0.1.0-alpha.1/lekis-0.1.0-alpha.1-android-arm64-v8a.apk
- **Categories:** Multimedia
- **Fastlane Metadata:** Included in repo (`fastlane/metadata/android/en-US` and `zh-CN`, with icon & screenshots)

### Summary
Open-source local & NAS lossless music player (Rust + Flutter) — direct SMB/WebDAV/NFS/SFTP playback without a server, plus OpenSubsonic/Navidrome, Jellyfin, Emby, and Plex support.

### FOSS & Privacy Notes
- 100% MPL-2.0 open source, zero trackers/ads, zero Google Play Services.
- `dependenciesInfo` block disabled in Gradle (`includeInApk = false`).
- Single-ABI `arm64-v8a` release APK (Flutter UI + Rust audio/VFS core).
```

---

## 通道 2：官方 F-Droid 主库（省事版 RFP + 加速版 MR）

官方 F-Droid 必须在隔离的**离线** Debian 构建服务器上从源码编译。提交后一旦收录，后续只要你在 GitHub 推送 `v*` 标签，F-Droid 会自动检测并构建新版本。

### 省事版：提 RFP 收录请求
1. 打开 <https://gitlab.com/fdroid/rfp> → **Issues** → **New issue**（选择 RFP 模板）。
2. 复制下方模板提交，等待社区维护者接手审核：

```markdown
* [x] The app complies with the inclusion criteria
* [x] The original app author has been notified (I am the author)
* [x] All related fdroiddata/rfp issues have been checked

### Link to the source code:
https://github.com/aoxzh/lekis-music

### Link to app in another app store:
(None / GitHub Releases: https://github.com/aoxzh/lekis-music/releases)

### License used:
MPL-2.0

### Category:
Multimedia

### Summary:
Local & NAS lossless music player (SMB/WebDAV/NFS/SFTP/Subsonic/Jellyfin)

### Description:
Lekis Music is an open-source, privacy-first local and NAS lossless music player powered by a Rust audio core and Flutter UI. Stream directly from Local folders, SMB, WebDAV, NFSv3, and SFTP without any server setup, or connect OpenSubsonic (Navidrome), Jellyfin, Emby, and Plex. Features sample-accurate gapless playback, 10-band EQ, ReplayGain, zero-API-key artwork & synced lyrics enrichment, LAN Connect remote control, and serverless multi-device sync.

Fastlane metadata (en-US & zh-CN, icon, screenshots) and `dependenciesInfo { includeInApk = false }` are already in the repository.
```

### 加速版：直接向 `fdroid/fdroiddata` 提 Merge Request（推荐）
1. 在 GitLab Fork <https://gitlab.com/fdroid/fdroiddata>。
2. 新建分支 `dev.lekis.music`，新增文件 `metadata/dev.lekis.music.yml`，粘贴下方配方（已按 F-Droid 离线构建规范，在 `prebuild` 阶段预拉取 Rust crates 和 Flutter 依赖）：

```yaml
Categories:
  - Multimedia
License: MPL-2.0
AuthorName: aoxzh
SourceCode: https://github.com/aoxzh/lekis-music
IssueTracker: https://github.com/aoxzh/lekis-music/issues
Changelog: https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md

AutoName: Lekis Music

RepoType: git
Repo: https://github.com/aoxzh/lekis-music.git

Builds:
  - versionName: 0.1.0-alpha.1
    versionCode: 1
    commit: v0.1.0-alpha.1
    subdir: app
    output: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
    srclibs:
      - flutter@3.50.1
      - rustup@1.27.1
    rm:
      - app/windows
      - app/macos
      - app/linux
      - app/ios
    prebuild:
      - $$rustup$$/rustup-init.sh -y --default-toolchain stable --target aarch64-linux-android
      - export PATH="$HOME/.cargo/bin:$$flutter$$/bin:$PATH"
      - export PUB_CACHE="$(pwd)/.pub-cache"
      - cargo fetch --manifest-path ../core/Cargo.toml
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get --enforce-lockfile
    build:
      - export PATH="$HOME/.cargo/bin:$$flutter$$/bin:$PATH"
      - export PUB_CACHE="$(pwd)/.pub-cache"
      - export ANDROID_NDK_HOME="$ANDROID_NDK"
      - export CARGO_NET_OFFLINE=true
      - $$flutter$$/bin/flutter build apk --release --target-platform android-arm64 --split-per-abi
    ndk: 28.2.13676358

scandelete:
  - app/.pub-cache

AutoUpdateMode: Version v%v
UpdateCheckMode: Tags
CurrentVersion: 0.1.0-alpha.1
CurrentVersionCode: 1
```

3. 提交 MR 到 `fdroid/fdroiddata:master`，标题写 `New app: Lekis Music`，观察 GitLab CI 的 YAML Linter 与构建检查即可。
