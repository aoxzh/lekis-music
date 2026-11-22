# F-Droid & IzzyOnDroid Packaging Guide · F-Droid 上架指南

Lekis Music (`dev.lekis.music`) is designed to be 100% FOSS and F-Droid friendly.

## FOSS Compliance Checklist

- [x] **OSI-Approved License**: Mozilla Public License 2.0 (`MPL-2.0`)
- [x] **No Proprietary Blobs / GMS**: Zero Google Play Services, Firebase, Crashlytics, AdMob, or analytics SDKs
- [x] **No Encrypted Google Dependency Block**: `dependenciesInfo { includeInApk = false; includeInBundle = false }` enabled in `app/android/app/build.gradle.kts`
- [x] **Fastlane Metadata Included**: `fastlane/metadata/android/en-US/` and `fastlane/metadata/android/zh-CN/` (title, short/full descriptions, changelogs, icon)
- [ ] **First Public GitHub Release**: Tag `v0.1.0-alpha.1` (with release-signed arm64-v8a APK attached) — required before opening the F-Droid / IzzyOnDroid submission.

---

## Fast Track 1: IzzyOnDroid (Recommended First Listing)

IzzyOnDroid is the largest community F-Droid repository and indexes signed APKs directly from GitHub Releases (typically approved within 1–3 days), while official F-Droid reviews the source-build MR.

1. Publish your first non-draft GitHub Release (`v0.1.0-alpha.1`) with the signed `lekis-0.1.0-alpha.1-android-arm64-v8a.apk` asset.
2. Open an issue at <https://gitlab.com/IzzyOnDroid/repo/-/issues/new?issuable_template=New_App> with:
   - **App ID**: `dev.lekis.music`
   - **Source Repo**: `https://github.com/aoxzh/lekis-music`
   - **License**: `MPL-2.0`
   - **Fastlane Metadata**: Already in repo under `fastlane/metadata/android/`
   - **Categories**: `Multimedia`
   - **Anti-Features**: None (all network enrichment / scrobbling is optional and uses public APIs)

---

## Track 2: Official F-Droid (`fdroiddata`)

Official F-Droid builds APKs from source on its build servers. Because Lekis Music combines **Flutter** + **Rust (`flutter_rust_bridge` + Cargokit)**, submit an RFP at <https://gitlab.com/fdroid/rfp/-/issues> or a Merge Request to <https://gitlab.com/fdroid/fdroiddata> with the following starter recipe:

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
      - flutter@3.50.0
    rm:
      - app/windows
      - app/macos
      - app/linux
      - app/ios
    prebuild:
      - export PATH="$HOME/.cargo/bin:$$flutter$$/bin:$PATH"
      - curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --target aarch64-linux-android
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get
    build:
      - export PATH="$HOME/.cargo/bin:$$flutter$$/bin:$PATH"
      - export ANDROID_NDK_HOME="$ANDROID_NDK"
      - $$flutter$$/bin/flutter build apk --release --target-platform android-arm64 --split-per-abi
    ndk: 28.2.13676358

AutoUpdateMode: Version v%v
UpdateCheckMode: Tags
CurrentVersion: 0.1.0-alpha.1
CurrentVersionCode: 1
```

> **Note**: When submitting to `fdroiddata`, pin the exact Flutter tag in `srclibs` matching `app/.metadata` / CI and verify with `fdroid build --verify-diff dev.lekis.music` if pursuing Reproducible Builds.
