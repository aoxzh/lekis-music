"""Tiny original synth used by the demo library.

The tracks are deliberately simple, loop-based instrumentals: warm pads,
a soft bass, a bell/pluck arpeggio and light drums.  They are not excerpts of
any existing recording, and they exist so the player has something real to
decode, seek and scrobble during promo recordings.
"""

from __future__ import annotations

import math

import numpy as np
from scipy.signal import fftconvolve

from catalog import Track

SR = 44100

# Per-album tonal centre and character.  MIDI 60 = C4.
_MOODS = {
    "starlit": dict(root=57, minor=True, wave="sine", arp_div=2, pad=0.115, drums=0.55, swing=0.0),
    "neon": dict(root=54, minor=True, wave="saw", arp_div=4, pad=0.10, drums=0.78, swing=0.02),
    "paper": dict(root=60, minor=False, wave="triangle", arp_div=2, pad=0.12, drums=0.38, swing=0.0),
    "summer": dict(root=62, minor=True, wave="saw", arp_div=2, pad=0.11, drums=0.66, swing=0.01),
    "arcade": dict(root=64, minor=False, wave="square", arp_div=4, pad=0.09, drums=0.72, swing=0.0),
    "dawn": dict(root=67, minor=False, wave="sine", arp_div=2, pad=0.12, drums=0.45, swing=0.0),
}


def midi_to_freq(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


def _osc(kind: str, freq: float, t: np.ndarray, detune: float = 0.0) -> np.ndarray:
    phase = 2.0 * math.pi * (freq * (2.0 ** (detune / 1200.0))) * t
    if kind == "sine":
        return np.sin(phase)
    if kind == "triangle":
        return 2.0 * np.abs(2.0 * ((phase / (2.0 * math.pi)) % 1.0) - 1.0) - 1.0
    if kind == "square":
        return np.sign(np.sin(phase))
    # saw
    return 2.0 * ((phase / (2.0 * math.pi)) % 1.0) - 1.0


def _env(n: int, attack: float, release: float, sr: int = SR) -> np.ndarray:
    a = max(1, int(attack * sr))
    r = max(1, int(release * sr))
    e = np.ones(n, dtype=np.float32)
    a = min(a, n)
    r = min(r, n)
    e[:a] = np.linspace(0.0, 1.0, a, dtype=np.float32)
    e[-r:] *= np.linspace(1.0, 0.0, r, dtype=np.float32)
    return e


def _add(buf: np.ndarray, seg: np.ndarray, at: int, gain: float = 1.0, pan: float = 0.0):
    if at >= len(buf) or len(seg) == 0:
        return
    seg = seg[: len(buf) - at]
    left = math.sqrt(max(0.0, 0.5 * (1.0 - pan)))
    right = math.sqrt(max(0.0, 0.5 * (1.0 + pan)))
    buf[at : at + len(seg), 0] += seg * (gain * left)
    buf[at : at + len(seg), 1] += seg * (gain * right)


def _kick(rng: np.random.Generator) -> np.ndarray:
    n = int(0.45 * SR)
    t = np.arange(n, dtype=np.float32) / SR
    freq = 45.0 + 110.0 * np.exp(-t * 26.0)
    phase = 2.0 * math.pi * np.cumsum(freq) / SR
    return (np.sin(phase) * np.exp(-t * 8.0)).astype(np.float32)


def _snare(rng: np.random.Generator) -> np.ndarray:
    n = int(0.24 * SR)
    t = np.arange(n, dtype=np.float32) / SR
    noise = rng.standard_normal(n).astype(np.float32)
    body = 0.25 * np.sin(2.0 * math.pi * 185.0 * t).astype(np.float32)
    return ((noise * 0.8 + body) * np.exp(-t * 17.0)).astype(np.float32)


def _hat(rng: np.random.Generator) -> np.ndarray:
    n = int(0.075 * SR)
    t = np.arange(n, dtype=np.float32) / SR
    noise = rng.standard_normal(n).astype(np.float32)
    # Crude high-pass: remove slow component.
    smooth = np.convolve(noise, np.ones(10, dtype=np.float32) / 10.0, mode="same")
    return ((noise - smooth) * np.exp(-t * 55.0)).astype(np.float32)


def _reverb(x: np.ndarray, rng: np.random.Generator, wet: float = 0.18) -> np.ndarray:
    n = int(1.7 * SR)
    t = np.arange(n, dtype=np.float32) / SR
    left = rng.standard_normal(n).astype(np.float32) * np.exp(-t / 0.38)
    right = rng.standard_normal(n).astype(np.float32) * np.exp(-t / 0.44)
    left[0] = 1.0
    right[0] = 0.9
    left /= np.sqrt(np.sum(left**2))
    right /= np.sqrt(np.sum(right**2))
    wet_l = fftconvolve(x[:, 0], left)[: len(x)].astype(np.float32)
    wet_r = fftconvolve(x[:, 1], right)[: len(x)].astype(np.float32)
    return x * (1.0 - wet) + np.stack((wet_l, wet_r), axis=1) * wet


def _chord(root: int, minor: bool, degree: int) -> list[int]:
    # Natural minor: i, VI, III, VII.  Major: I, V, vi, IV.
    if minor:
        offsets = [0, 8, 3, 10]
        intervals = [0, 3, 7]
    else:
        offsets = [0, 7, 9, 5]
        intervals = [0, 4, 7]
    base = root + offsets[degree % len(offsets)]
    return [base + i for i in intervals]


def render_track(track: Track, seed: int) -> np.ndarray:
    cfg = _MOODS[track.mood]
    rng = np.random.default_rng(seed)
    duration = track.duration
    n = int(duration * SR)
    out = np.zeros((n, 2), dtype=np.float32)
    beat = 60.0 / track.bpm
    bar = beat * 4.0
    chord_len = bar * 2.0
    root = cfg["root"]
    minor = cfg["minor"]
    pad_wave = "sine" if cfg["wave"] in {"sine", "triangle"} else "saw"

    # ---- pads -------------------------------------------------------------
    pos = 0.0
    degree = 0
    while pos < duration:
        notes = _chord(root, minor, degree)
        seg_len = chord_len + 1.6
        cnt = int(min(seg_len, duration - pos + 1.2) * SR)
        if cnt <= 0:
            break
        t = np.arange(cnt, dtype=np.float32) / SR
        env = _env(cnt, 0.9, 1.5)
        pad = np.zeros(cnt, dtype=np.float32)
        for i, note in enumerate(notes):
            freq = midi_to_freq(note)
            det = -4.0 if i % 2 == 0 else 4.0
            pad += _osc(pad_wave, freq, t, det).astype(np.float32) * (0.55 if i else 0.75)
            pad += 0.35 * _osc("sine", freq / 2.0, t).astype(np.float32)
        pad *= env * cfg["pad"]
        _add(out, pad, int(pos * SR), 1.0, -0.35)
        _add(out, pad, int(pos * SR), 0.9, 0.35)
        pos += chord_len
        degree += 1

    # ---- bass -------------------------------------------------------------
    pos = 0.0
    degree = 0
    while pos < duration:
        notes = _chord(root, minor, degree)
        bass_note = notes[0] - 12
        step = beat * 0.85
        local = 0.0
        while local < chord_len and pos + local < duration:
            cnt = int(min(step, duration - (pos + local)) * SR)
            if cnt <= 0:
                break
            t = np.arange(cnt, dtype=np.float32) / SR
            env = np.exp(-t * 3.2).astype(np.float32)
            tone = _osc("sine", midi_to_freq(bass_note), t).astype(np.float32)
            tone += 0.18 * _osc("saw", midi_to_freq(bass_note), t).astype(np.float32)
            _add(out, tone * env, int((pos + local) * SR), 0.13)
            local += beat
        pos += chord_len
        degree += 1

    # ---- arpeggio ---------------------------------------------------------
    pos = 0.0
    degree = 0
    pattern = [0, 1, 2, 1, 2, 0, 1, 2]
    step = beat / cfg["arp_div"]
    idx = 0
    while pos < duration:
        notes = _chord(root, minor, degree)
        local = 0.0
        while local < chord_len and pos + local < duration:
            note = notes[pattern[idx % len(pattern)]] + (12 if idx % 6 in (4, 5) else 0)
            cnt = int(min(step * 1.8, duration - (pos + local)) * SR)
            if cnt <= 0:
                break
            t = np.arange(cnt, dtype=np.float32) / SR
            env = np.exp(-t * (10.0 if cfg["wave"] != "square" else 14.0)).astype(np.float32)
            tone = _osc(cfg["wave"], midi_to_freq(note), t).astype(np.float32)
            tone += 0.25 * _osc("sine", midi_to_freq(note + 12), t).astype(np.float32)
            pan = 0.55 if idx % 2 else -0.55
            _add(out, tone * env, int((pos + local) * SR), 0.055, pan)
            local += step
            idx += 1
        pos += chord_len
        degree += 1

    # ---- drums ------------------------------------------------------------
    kick = _kick(rng)
    snare = _snare(rng)
    hat = _hat(rng)
    total_beats = int(duration / beat)
    for b in range(total_beats):
        at = int(b * beat * SR)
        if b % 4 in (0, 2):
            _add(out, kick, at, 0.42 * cfg["drums"])
            if track.mood in {"neon", "arcade"} and b % 8 == 6:
                _add(out, kick, at + int(beat * 0.5 * SR), 0.22 * cfg["drums"])
        if b % 4 in (1, 3):
            _add(out, snare, at, 0.24 * cfg["drums"], 0.1)
        _add(out, hat, at, 0.08 * cfg["drums"], -0.25)
        _add(out, hat, at + int(beat * 0.5 * SR), 0.055 * cfg["drums"], 0.25)

    # ---- space ------------------------------------------------------------
    out = _reverb(out, rng, wet=0.22 if track.mood in {"starlit", "paper", "dawn"} else 0.14)

    # ---- master -----------------------------------------------------------
    fade = int(min(2.2, duration * 0.08) * SR)
    if fade > 0:
        out[:fade] *= np.linspace(0.0, 1.0, fade, dtype=np.float32)[:, None]
        out[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)[:, None]
    out = np.tanh(out * 1.15).astype(np.float32)
    peak = float(np.max(np.abs(out))) or 1.0
    out *= 0.88 / peak
    return out


def lrc_for(track: Track) -> str:
    """Evenly spaced LRC lines, original text only."""
    if not track.lyrics:
        return ""
    start = min(10.0, track.duration * 0.08)
    end = max(start + 1.0, track.duration - 8.0)
    step = (end - start) / max(1, len(track.lyrics) - 1)
    lines = []
    for i, text in enumerate(track.lyrics):
        t = start + step * i
        minutes = int(t // 60)
        seconds = t - minutes * 60
        lines.append(f"[{minutes:02d}:{seconds:05.2f}]{text}")
    return "\n".join(lines) + "\n"
