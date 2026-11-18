#!/usr/bin/env bash
# 为 Android 编译 Rust 核心，输出到 apps/android/core/bridge/src/main/jniLibs/<abi>/liblekis_ffi.so
# 依赖：Android NDK（ANDROID_NDK_HOME）、cargo install cargo-ndk、
#       rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-release-android}"   # 调试时可以传 dev

cd "$ROOT/core"
cargo ndk \
  -t arm64-v8a -t armeabi-v7a -t x86_64 \
  --platform 26 \
  -o "$ROOT/apps/android/core/bridge/src/main/jniLibs" \
  build --profile "$PROFILE" -p lekis-ffi
