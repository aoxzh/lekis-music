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
| cpal, ciborium, russh, russh-sftp | Apache-2.0 |
| tokio, tracing, tracing-subscriber, tower, axum, pinyin, wana_kana, quick-xml, rubato, rusqlite, rquickjs, souvlaki, wasapi | MIT |
| ringbuf | MIT OR Apache-2.0 |
| regex, tempfile | MIT OR Apache-2.0 |
| encoding_rs | (Apache-2.0 OR MIT) AND BSD-3-Clause |
| miniz_oxide | MIT OR Zlib OR Apache-2.0 |
| lofty, mdns-sd, image, serde, serde_json, sha2, md-5, thiserror, url, uuid, windows, windows-sys, reqwest, base64, bytes, hex, httpdate, futures-util, async-trait, anyhow, percent-encoding, log, md5, smb2, cpal (dual), android_logger, jni-sys, ndk-context | MIT OR Apache-2.0 |
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
| desktop_webview_window | Apache-2.0 |
| Microsoft Edge WebView2 (Windows runtime) | Microsoft proprietary runtime, redistributed by Microsoft |
| WebKitGTK (Linux runtime, dynamically linked) | LGPL-2.1-or-later |
| file_picker, audio_service, audio_session, permission_handler, tray_manager, window_manager | MIT |
| cupertino_icons | MIT |

## Vendored code and assets

| Component | License |
|---|---|
| `core/vendor/rquickjs-sys` (vendored crate) | MIT |
| QuickJS (inside rquickjs-sys) | MIT |
| Cargokit (`app/rust_builder/cargokit`) | MIT |
| Unihan database readings, generated into `core/crates/lekis-enrich/src/ruby_ja_data.rs` (Copyright © Unicode, Inc.) | Unicode License v3 |
| Lekis rabbit mascot artwork (`app/app_icon.png`, launcher icons) | original project asset, MPL-2.0 |
| Liquid glass lens shader (`app/shaders/liquid_glass_lens.frag`) and tab bar glass parameters — from Kyant's Backdrop / AndroidLiquidGlass (Copyright 2025 Kyant) via CYLTabBarController's Android port (ChenYilong) | Apache-2.0 (Backdrop), MIT (CYLTabBarController) |

### Unicode data license

The generated `core/crates/lekis-enrich/src/ruby_ja_data.rs` contains readings
derived from the Unicode Unihan database. Copyright © 1991-2026 Unicode, Inc.
Distributed under the [Unicode License v3](https://www.unicode.org/license.txt):

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of data files and any associated documentation (the "Data Files") or software
> and any associated documentation (the "Software") to deal in the Data Files
> or Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish, distribute, and/or sell copies of the Data
> Files or Software, and to permit persons to whom the Data Files or Software
> are furnished to do so, provided that either (a) this copyright and permission
> notice appear with all copies of the Data Files or Software, or (b) this
> copyright and permission notice appear in associated Documentation.
>
> THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
> KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
> MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
> THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED
> IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR
> CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
> DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
> TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
> OF THE DATA FILES OR SOFTWARE.
>
> Except as contained in this notice, the name of a copyright holder shall not
> be used in advertising or otherwise to promote the sale, use or other
> dealings in these Data Files or Software without prior written authorization
> of the copyright holder.

## Fonts and icons

- Material Icons: Apache-2.0.
- Cupertino Icons: MIT.

## Updating this file

When adding a direct dependency, add a row here and check that its license is in
the `allow` list in `core/deny.toml`. Run `cargo deny check licenses` (or the CI
`deny` job) before release.
