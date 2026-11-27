#!/usr/bin/env python3
"""Generate the original Lekis demo music library.

The output is a normal folder of tagged FLAC files with cover art and LRC
sidecars.  Add it to Lekis like any other local folder, or push it to a phone
for promo recordings.  Nothing here is a real release: the catalogue, lyrics,
cover art and audio are generated from this repository.

Examples:
    python tools/demo-library/generate.py
    python tools/demo-library/generate.py --out private/demo-library
    python tools/demo-library/generate.py --only starlit-reverie
    python tools/demo-library/generate.py --list
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from mutagen.flac import FLAC, Picture

from catalog import ALBUMS, Album, Track, catalog_stats
from covers import cover_for
from synth import SR, lrc_for, render_track

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO_ROOT / "private" / "demo-library"
LICENSE = "CC0-1.0"
YEAR = 2026


def _safe(name: str) -> str:
    return re.sub(r'[\\/:*?"<>|]', "-", name).strip().rstrip(".")


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def _tag_track(
    path: Path,
    album: Album,
    track: Track,
    index: int,
    cover_bytes: bytes,
    lyrics: str,
) -> None:
    audio = FLAC(path)
    audio["title"] = track.title
    audio["artist"] = album.artist
    audio["albumartist"] = album.artist
    audio["album"] = album.title
    audio["tracknumber"] = str(index)
    audio["tracktotal"] = str(len(album.tracks))
    audio["discnumber"] = "1"
    audio["disctotal"] = "1"
    audio["date"] = str(album.year)
    audio["genre"] = album.genre
    audio["bpm"] = str(track.bpm)
    audio["comment"] = (
        "Original demo track generated for Lekis Music. "
        "Fictional artist, lyrics and cover. CC0-1.0."
    )
    audio["license"] = LICENSE
    if track.lyrics:
        audio["lyrics"] = "\n".join(track.lyrics)
    picture = Picture()
    picture.type = 3
    picture.mime = "image/jpeg"
    picture.desc = "Cover"
    picture.data = cover_bytes
    audio.add_picture(picture)
    audio.save()


def _album_readme(album: Album) -> str:
    lines = [
        f"{album.title} — {album.artist} ({album.year})",
        f"{album.genre} · demo album",
        "",
        "All titles, lyrics, artwork and audio in this folder are original",
        "generated material for the Lekis Music demo library.",
        f"License: {LICENSE} (public-domain dedication).",
        "",
        "Tracks:",
    ]
    for i, track in enumerate(album.tracks, start=1):
        minutes, seconds = divmod(int(track.duration), 60)
        lines.append(f"  {i:02d}. {track.title}  ({minutes}:{seconds:02d})")
    lines.append("")
    lines.append("Not a real release. Do not treat these names as real artists.")
    return "\n".join(lines) + "\n"


def _playlist(albums: list[Album]) -> str:
    lines = ["#EXTM3U"]
    for album in albums:
        folder = _safe(f"{album.title} ({album.year})")
        for i, track in enumerate(album.tracks, start=1):
            rel = f"{folder}/{i:02d} - {_safe(track.title)}.flac".replace("\\", "/")
            lines.append(f"#EXTINF:{int(track.duration)},{album.artist} - {track.title}")
            lines.append(rel)
    return "\n".join(lines) + "\n"


def _manifest(albums: list[Album]) -> str:
    data = {
        "generatedBy": "tools/demo-library/generate.py",
        "license": LICENSE,
        "fictional": True,
        "sampleRate": SR,
        "albums": [
            {
                "slug": album.slug,
                "title": album.title,
                "artist": album.artist,
                "year": album.year,
                "genre": album.genre,
                "cover": f"{_safe(f'{album.title} ({album.year})')}/cover.jpg",
                "tracks": [
                    {
                        "title": track.title,
                        "duration": track.duration,
                        "bpm": track.bpm,
                        "file": f"{_safe(f'{album.title} ({album.year})')}/"
                        f"{i:02d} - {_safe(track.title)}.flac",
                        "lyrics": bool(track.lyrics),
                    }
                    for i, track in enumerate(album.tracks, start=1)
                ],
            }
            for album in albums
        ],
    }
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate the Lekis demo library.")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"output folder (default: {DEFAULT_OUT})")
    parser.add_argument("--seed", type=int, default=20261128, help="audio seed")
    parser.add_argument("--only", action="append", default=[], help="album slug (repeatable)")
    parser.add_argument("--force", action="store_true", help="overwrite an existing output folder")
    parser.add_argument("--list", action="store_true", help="print the catalogue and exit")
    parser.add_argument(
        "--covers-only",
        action="store_true",
        help="write covers, LRC files and the manifest without audio",
    )
    args = parser.parse_args(argv)

    if args.list:
        albums, tracks, seconds = catalog_stats()
        print(f"{albums} albums, {tracks} tracks, {seconds / 60:.1f} minutes")
        for album in ALBUMS:
            print(f"  {album.slug:20} {album.artist:24} {album.title}")
            for i, track in enumerate(album.tracks, 1):
                print(f"    {i}. {track.title} ({int(track.duration)}s, {track.bpm} BPM)")
        return 0

    selected = [a for a in ALBUMS if not args.only or a.slug in args.only]
    if args.only:
        missing = set(args.only) - {a.slug for a in ALBUMS}
        if missing:
            parser.error(f"unknown album slug(s): {', '.join(sorted(missing))}")
    if not selected:
        parser.error("no albums selected")

    out: Path = args.out.resolve()
    if out.exists():
        if not args.force:
            parser.error(f"{out} already exists; pass --force to replace it")
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    started = time.perf_counter()
    total_bytes = 0
    for album_index, album in enumerate(selected):
        seed_index = ALBUMS.index(album)
        folder = out / _safe(f"{album.title} ({album.year})")
        folder.mkdir(parents=True, exist_ok=True)
        cover_path = folder / "cover.jpg"
        cover_for(album, cover_path)
        cover_bytes = cover_path.read_bytes()
        _write_text(folder / "README.txt", _album_readme(album))
        print(f"[{album_index + 1}/{len(selected)}] {album.artist} — {album.title}")
        for track_index, track in enumerate(album.tracks, start=1):
            stem = f"{track_index:02d} - {_safe(track.title)}"
            path = folder / f"{stem}.flac"
            lyrics = lrc_for(track)
            if lyrics:
                _write_text(folder / f"{stem}.lrc", lyrics)
            if not args.covers_only:
                seed = args.seed + seed_index * 100 + track_index
                audio = render_track(track, seed)
                sf.write(path, audio, SR, format="FLAC", subtype="PCM_16")
                _tag_track(path, album, track, track_index, cover_bytes, lyrics)
                total_bytes += path.stat().st_size
                print(
                    f"    {track_index}. {track.title:24} "
                    f"{track.duration:5.0f}s  {path.stat().st_size / 1_000_000:5.1f} MB"
                )
            else:
                print(f"    {track_index}. {track.title:24} {track.duration:5.0f}s  (no audio)")

    _write_text(out / "playlist.m3u8", _playlist(selected))
    _write_text(out / "demo-library.json", _manifest(selected))
    _write_text(
        out / "README.txt",
        "Lekis Music demo library\n"
        "=======================\n\n"
        "Fictional artists, original lyrics, original generated artwork and\n"
        "original synthesized audio.  Nothing here is a real commercial release.\n"
        f"License: {LICENSE}.\n\n"
        "Add this folder as a local source in Lekis, or push it to a phone:\n"
        "  adb push private/demo-library /sdcard/Music/LekisDemo\n\n"
        "For a clean desktop profile:\n"
        "  flutter run -d windows --dart-define=LEKIS_DATA_DIR=<a temp folder>\n\n"
        "Regenerate with:\n"
        "  python tools/demo-library/generate.py --force\n",
    )
    elapsed = time.perf_counter() - started
    print(
        f"\nDone: {len(selected)} albums, "
        f"{sum(len(a.tracks) for a in selected)} tracks, "
        f"{total_bytes / 1_000_000:.1f} MB audio in {elapsed:.1f}s\n{out}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
