# Third-party notices

Lekis itself is licensed under the Mozilla Public License 2.0 (see `LICENSE`).
This file lists the third-party components we deliberately depend on. It is a
summary of direct dependencies, not a replacement for the license text shipped
with each package. The Rust dependency graph is checked in CI with
`cargo-deny` against the allow-list in `core/deny.toml`.

## Rust workspace

| Component | License |
|---|---|
| symphonia | MPL-2.0 |
| uniffi | MPL-2.0 |
| cpal, ciborium, russh, russh-sftp | Apache-2.0 |
| tokio, tracing, tracing-subscriber, tower, axum, pinyin, quick-xml, rubato, rusqlite, rquickjs, souvlaki, wasapi | MIT |
| ringbuf | MIT OR Apache-2.0 |
| lofty, mdns-sd, image, serde, serde_json, sha2, thiserror, url, uuid, windows, windows-sys, reqwest, base64, bytes, hex, httpdate, futures-util, async-trait, anyhow, percent-encoding, log, md5, smb2, cpal (dual), android_logger, jni-sys, ndk-context | MIT OR Apache-2.0 |
| zstd | BSD-3-Clause |
| nfs3_client | Unlicense |
| ferrous-opencc | Apache-2.0 |
| flutter_rust_bridge (Rust crate) | MIT |

`zhconv` is deliberately **not** used because it is GPL-2.0-or-later; simplified
/ traditional normalization uses `ferrous-opencc` instead.

## Flutter app

| Component | License |
|---|---|
| Flutter / material_ui / path_provider / flutter_lints / build_runner | BSD-3-Clause (Flutter Authors / Dart project authors) |
| flutter_riverpod, freezed_annotation, freezed | MIT |
| flutter_rust_bridge | MIT |
| file_picker, audio_service, audio_session, permission_handler | MIT |
| cupertino_icons | MIT |

## Vendored code and assets

| Component | License |
|---|---|
| `core/vendor/rquickjs-sys` (vendored crate) | MIT |
| QuickJS (inside rquickjs-sys) | MIT |
| Cargokit (`app/rust_builder/cargokit`) | MIT |
| Lekis rabbit mascot artwork (`app/app_icon.png`, launcher icons) | original project asset, MPL-2.0 |
| Liquid glass lens shader (`app/shaders/liquid_glass_lens.frag`) and tab bar glass parameters — from Kyant's Backdrop / AndroidLiquidGlass (Copyright 2025 Kyant) via CYLTabBarController's Android port (ChenYilong) | Apache-2.0 (Backdrop), MIT (CYLTabBarController) |

## Fonts and icons

- Material Icons: Apache-2.0.
- Cupertino Icons: MIT.

## Updating this file

When adding a direct dependency, add a row here and check that its license is in
the `allow` list in `core/deny.toml`. Run `cargo deny check licenses` (or the CI
`deny` job) before release.
