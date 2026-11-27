# Lekis demo library

An **original, fictional** music library for screenshots and the 30-second
promo video.  It exists so the app can show a full album wall, Japanese lyrics
with ruby, cover art, seeking and gapless playback without using anyone else's
recordings or artwork.

> Real anime songs are tempting, but their audio, covers and lyrics are
> copyrighted.  A promo video is commercial use, so this generator creates
> everything from scratch instead.  The names below are fictional.

## What it generates

- 6 albums × 3 tracks = 18 tracks (about 22 minutes of audio)
- Tagged FLAC files (title, artist, album, track number, year, genre, BPM)
- A 1200×1200 original cover per album, embedded and written as `cover.jpg`
- Synced `.lrc` sidecars for every track with lyrics
- A `playlist.m3u8` for importing the whole library at once
- `demo-library.json` with the catalogue and durations
- A per-album `README.txt` and a top-level licence note

The audio is a small original synth (pads, bass, arpeggio, light drums), not a
real song.  It is intentionally gentle and loop-based; it is here so playback,
seeking, lyrics and the player UI have something real to show.

## Requirements

- Python 3.11+
- `numpy`, `Pillow`, `soundfile`, `mutagen`, `scipy`

```powershell
python -m pip install -r tools/demo-library/requirements.txt
```

`soundfile` bundles libsndfile on Windows/macOS; on Linux install
`libsndfile1` if needed.

## Generate

From the repository root:

```powershell
# Default output: private/demo-library (ignored by git)
python tools/demo-library/generate.py

# Replace an existing folder
python tools/demo-library/generate.py --force

# One album only
python tools/demo-library/generate.py --only starlit-reverie --force

# Covers, LRC and manifest only (no audio)
python tools/demo-library/generate.py --covers-only --force

# Print the catalogue
python tools/demo-library/generate.py --list
```

The generator is deterministic: the same `--seed` produces the same audio and
the same covers.  Covers are drawn with Pillow (gradients, moons, neon grids,
fireworks), so no network or image model is needed.

## Use it in the app

### Desktop

Add `private/demo-library` as a local source in **Settings → Sources**.

For a clean profile that does not mix with your real library, seed a small
SQLite database first (this is what the screenshots use):

```powershell
cargo run --manifest-path core/Cargo.toml -p lekis-core `
  --example seed_demo_library -- private/demo-profile private/demo-library

flutter run -d windows `
  --dart-define=LEKIS_DATA_DIR=<repo>\private\demo-profile `
  --dart-define=LEKIS_CACHE_DIR=<repo>\private\demo-profile\cache `
  --dart-define=LEKIS_START_TAB=library
```

The seeder adds the folder as the "Lekis Demo" source and waits for the scan,
so the app opens with all 18 tracks already indexed. Delete
`private/demo-profile` to start over.

If you prefer to use your normal profile, just add the folder as a source.

### Android

```powershell
adb push private/demo-library /sdcard/Music/LekisDemo
```

Add `/sdcard/Music/LekisDemo` as a local folder source.  For a clean device
profile, use a secondary user/profile or clear the app's data first — clearing
data also removes the real library.

## Recording tips

- Prefer FLAC (the generated files are already lossless) so the "Lossless"
  badge is visible.
- Open a Japanese track for the ruby/furigana screenshot; the lyrics include
  kanji and kana on purpose.
- Leave 2–3 albums without a cover for the "cover completion" shot: delete
  their `cover.jpg`, or generate a copy and remove selected covers.
- The storyboard lives in `private/promo/video-30s.md` (not committed).

## Headless promo screenshots

`app/test/promo_shots_test.dart` renders the Now Playing page in a Flutter
widget test and writes PNGs through `RepaintBoundary.toImage` — no desktop
window, no screen capture, no mouse control.  The cover and LRC fixtures are
committed under `app/test/fixtures/demo/`.

```powershell
$env:LEKIS_UI_CAPTURE_DIR = "$PWD\private\demo-shots"
$env:LEKIS_UI_FONT = "C:\Windows\Fonts\simhei.ttf"
$flutter = Split-Path (Split-Path (Get-Command flutter).Source -Parent) -Parent
$env:LEKIS_UI_ICONS = "$flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf"
Push-Location app
flutter test test/promo_shots_test.dart
Pop-Location
```

Leave `LEKIS_UI_CAPTURE_DIR` unset in normal CI; the test still checks the
layout but writes nothing.  The real screenshots in `docs/screenshots/` and
`website/assets/shots/` are produced from these PNGs (desktop 1600×965) and
the demo library; see the commit history for the last replacement.

## Licence

The generated catalogue, lyrics, artwork and audio are released under
**CC0-1.0**.  You can use them in screenshots, videos and store listings
without attribution.  Do not present the fictional artists as real people.
