#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26", "scipy>=1.11"]
# ///
"""Silicon Mode sound design: every UI sound and panic alarm, synthesised procedurally.

    uv run scripts/make-sounds.py                        # (re)writes apps/mac/App/Resources/Sounds/*.wav
    uv run scripts/make-sounds.py --report               # ...and prints duration / peak / RMS / loudness / loop seam
    uv run scripts/make-sounds.py --only enter,panic-siren --out /tmp/sm
    uv run --with matplotlib scripts/make-sounds.py --spectrograms /tmp/sm-spec

Output: 48 kHz, 16-bit, mono PCM WAV (TPDF-dithered). Deterministic: fixed seeds, no clock input.

How it is built (in the spirit of bencho.dev/sounds, see docs/research/macos-ui.md §2):
  * Everything renders at 96 kHz (2x oversampling) and is decimated with a 255-tap Kaiser FIR.
  * Pitched sources are band-limited by construction: additive oscillators that only emit partials below
    19 kHz (with a taper), spectrally shaped in the partial domain (lowpass curves, vocal/horn formants), so
    sweeps and glides never alias. Bells are 1:1 FM "tines" (bright strike that mellows) plus inharmonic
    free-bar modes (1 : 2.756 : 5.404) for glassiness.
  * Noise layers go through RBJ biquads or a zero-delay-feedback state-variable filter for sweeps.
  * A short synthetic room / hall (two-band decaying noise impulse response) gives UI sounds air.
  * Gentle tanh saturation for warmth and density; everything is high-passed so laptop speakers don't waste
    headroom on sub-bass.
  * UI sounds: normalised by K-weighted (BS.1770) momentary loudness with a true-peak ceiling of -3 dBTP.
    Panic loops: louder, true peak <= -1 dBTP.
  * Panic loops are rendered *circularly* (voices wrap around the loop point, global filters/reverb/decimation
    run on the tiled loop and the steady-state period is kept), so the last sample flows into the first with
    no click. Continuous oscillators are tuned to a whole number of cycles per loop.

The UI sound names match `UISound` raw values in apps/mac/App/Sources/Core/SoundPlayer.swift; panic sounds are
`panic-<id>.wav` for `SoundPlayer.panicSounds`.
"""
from __future__ import annotations

import argparse
import math
import sys
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
from scipy import signal

SR_OUT = 48_000
OS = 2
SR = SR_OUT * OS
TOP = 19_000.0                       # highest partial an oscillator may emit (Hz)
TAU = 2.0 * np.pi
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "apps/mac/App/Resources/Sounds"

_NOTES = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def hz(name: str) -> float:
    """'E5' -> 659.255 Hz (A4 = 440)."""
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2.0 ** ((12 * (octave + 1) + _NOTES[pitch] - 69) / 12.0)


# ---------------------------------------------------------------------------------------------------------------
# Basics

def ns(sec: float, rate: int = SR) -> int:
    return max(0, int(round(sec * rate)))


def tv(n: int) -> np.ndarray:
    return np.arange(n) / SR


def smoothstep(e0: float, e1: float, x):
    u = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return u * u * (3.0 - 2.0 * u)


def rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def noise(n: int, seed: int) -> np.ndarray:
    return rng(seed).uniform(-1.0, 1.0, n)


def freq_array(f, n: int) -> np.ndarray:
    return np.full(n, float(f)) if np.isscalar(f) else np.asarray(f, dtype=float)


# ---------------------------------------------------------------------------------------------------------------
# Envelopes (all end at exactly 0 so voices never click when they stop)

def end_fade(n: int, sec: float = 0.004) -> np.ndarray:
    m = min(n, ns(sec))
    f = np.ones(n)
    if m:
        f[-m:] = 0.5 + 0.5 * np.cos(np.pi * np.arange(1, m + 1) / m)
    return f


def perc(n: int, atk: float, t60: float, hold: float = 0.0) -> np.ndarray:
    """Sine-squared attack, optional hold, exponential decay reaching -60 dB `t60` seconds later."""
    t = tv(n)
    a = np.sin(0.5 * np.pi * np.clip(t / max(atk, 1e-6), 0.0, 1.0)) ** 2
    d = np.clip(t - atk - hold, 0.0, None)
    return a * 10.0 ** (-3.0 * d / t60) * end_fade(n)


def gate(n: int, atk: float, rel: float) -> np.ndarray:
    """Flat-top envelope: sine attack, sustain, cosine release ending at 0."""
    t = tv(n)
    T = n / SR
    a = np.sin(0.5 * np.pi * np.clip(t / atk, 0.0, 1.0)) ** 2
    r = np.cos(0.5 * np.pi * np.clip((t - (T - rel)) / rel, 0.0, 1.0)) ** 2
    return a * r


# ---------------------------------------------------------------------------------------------------------------
# Band-limited oscillators

def phase(f: np.ndarray, ph0: float = 0.0) -> np.ndarray:
    """Phase in cycles for a per-sample frequency; ph[0] == ph0."""
    return ph0 + np.concatenate(([0.0], np.cumsum(f[:-1]))) / SR


Tone = Callable[[np.ndarray], np.ndarray]


def additive(f, n: int, partials, tone: Tone | None = None, ph0: float = 0.0) -> np.ndarray:
    """Sum of sines k*f with amplitudes a_k, shaped per partial by `tone(partial_freq)`. Partials above TOP are
    faded out sample by sample, so glides never alias."""
    f = freq_array(f, n)
    ph = phase(f, ph0)
    out = np.zeros(n)
    for k, a in partials:
        fk = k * f
        if fk.min() >= TOP:
            continue
        g = a * np.clip((TOP - fk) / 3000.0, 0.0, 1.0)
        if tone is not None:
            g = g * tone(fk)
        if np.max(np.abs(g)) < 2e-5:
            continue
        out += g * np.sin(TAU * k * ph)
    return out


def _count(f, n) -> int:
    return int(TOP / max(20.0, float(np.min(freq_array(f, n))))) + 1


def saw(f, n, tone=None, ph0=0.0):
    return additive(f, n, [(k, (2 / np.pi) / k) for k in range(1, _count(f, n) + 1)], tone, ph0)


def square(f, n, tone=None, ph0=0.0):
    return additive(f, n, [(k, (4 / np.pi) / k) for k in range(1, _count(f, n) + 1, 2)], tone, ph0)


def triangle(f, n, tone=None, ph0=0.0):
    return additive(f, n, [(k, (8 / np.pi ** 2) * (-1) ** ((k - 1) // 2) / k ** 2)
                           for k in range(1, _count(f, n) + 1, 2)], tone, ph0)


def lowpass_tone(fc, order: int = 2) -> Tone:
    return lambda fk: 1.0 / np.sqrt(1.0 + (fk / fc) ** (2 * order))


def highpass_tone(fc, order: int = 1) -> Tone:
    return lambda fk: 1.0 / np.sqrt(1.0 + (fc / np.maximum(fk, 1.0)) ** (2 * order))


def formant_tone(formants, floor: float = 0.06) -> Tone:
    """Sum of resonance bumps [(centre Hz (may vary per sample), bandwidth Hz, gain)] over a floor."""
    def tone(fk):
        g = np.full_like(fk, floor)
        for F, bw, gain in formants:
            g = g + gain / (1.0 + ((fk - F) / (0.5 * bw)) ** 2)
        return g
    return tone


def tones(*ts: Tone) -> Tone:
    def tone(fk):
        g = np.ones_like(fk)
        for t in ts:
            g = g * t(fk)
        return g
    return tone


# ---------------------------------------------------------------------------------------------------------------
# Filters

def rbj(kind: str, f: float, q: float = 0.7071) -> np.ndarray:
    w = TAU * min(f, 0.45 * SR) / SR
    cw, sw = math.cos(w), math.sin(w)
    a = sw / (2 * q)
    b = {"lp": [(1 - cw) / 2, 1 - cw, (1 - cw) / 2],
         "hp": [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2],
         "bp": [a, 0.0, -a]}[kind]
    den = [1 + a, -2 * cw, 1 - a]
    return np.array([[*(x / den[0] for x in b), 1.0, den[1] / den[0], den[2] / den[0]]])


def biquad(x, kind: str, f: float, q: float = 0.7071):
    return signal.sosfilt(rbj(kind, f, q), x)


def butter(x, kind: str, f, order: int = 2, rate: int = SR):
    return signal.sosfilt(signal.butter(order, f, btype=kind, fs=rate, output="sos"), x)


def sweep_bp(x: np.ndarray, fc, q) -> np.ndarray:
    """Unity-peak band-pass with per-sample centre and Q (topology-preserving SVF, modulation-safe)."""
    n = len(x)
    fc = np.clip(freq_array(fc, n), 20.0, 0.45 * SR)
    q = freq_array(q, n)
    g = np.tan(np.pi * fc / SR)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    xs, A1, A2, A3, K = x.tolist(), a1.tolist(), a2.tolist(), a3.tolist(), k.tolist()
    ic1 = ic2 = 0.0
    y = [0.0] * n
    for i in range(n):
        v3 = xs[i] - ic2
        v1 = A1[i] * ic1 + A2[i] * v3
        v2 = ic2 + A2[i] * ic1 + A3[i] * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        y[i] = K[i] * v1
    return np.asarray(y)


def sat(x, drive: float = 1.5):
    """Normalised tanh saturation: unity gain for small signals' peaks at 1, warm compression above."""
    return np.tanh(drive * x) / np.tanh(drive)


def limit(x: np.ndarray, ceiling: float = 0.95, window: float = 0.005) -> np.ndarray:
    """Look-ahead peak limiter with a smooth gain curve: the per-sample required gain is min-filtered over
    +-window, then smoothed with a Hann kernel half as wide, so the result never exceeds the ceiling."""
    from scipy.ndimage import minimum_filter1d
    w = max(4, ns(window))
    g = np.minimum(1.0, ceiling / np.maximum(np.abs(x), 1e-12))
    g = minimum_filter1d(g, size=2 * w + 1, mode="nearest")
    h = np.hanning(w + 2)[1:-1]
    return x * np.convolve(g, h / h.sum(), mode="same")


# ---------------------------------------------------------------------------------------------------------------
# Space: synthetic two-band decaying-noise impulse responses

def make_ir(t60_lo: float, t60_hi: float, *, seed: int, predelay: float, xover: float = 2500.0,
            damp: float = 9000.0, er_level: float = 0.25) -> np.ndarray:
    n = ns(max(t60_lo, t60_hi) * 1.05)
    t = tv(n)
    nz = rng(seed).standard_normal(n)
    lo = butter(nz, "lowpass", xover, 2)
    hi = nz - lo
    ir = lo * 10.0 ** (-3.0 * t / t60_lo) + hi * 10.0 ** (-3.0 * t / t60_hi)
    ir *= smoothstep(0.0, 0.010, t) * end_fade(n, 0.05)
    ir = butter(ir, "lowpass", damp, 2)
    ir /= np.sqrt(np.sum(ir ** 2))
    er = np.zeros(n)                       # a few sparse early reflections for a sense of size
    r = rng(seed + 1)
    for i, d in enumerate((0.0043, 0.0071, 0.0109, 0.0157, 0.0213)):
        er[ns(d)] = er_level * (0.82 ** i) * (1 if r.random() > 0.5 else -1)
    ir = ir + er
    ir /= np.sqrt(np.sum(ir ** 2))
    return np.concatenate([np.zeros(ns(predelay)), ir])


ROOM = make_ir(0.42, 0.26, seed=11, predelay=0.004)
HALL = make_ir(1.45, 0.85, seed=12, predelay=0.012, er_level=0.15)


def reverb(x: np.ndarray, ir: np.ndarray, send: float, hp: float = 280.0, lp: float = 9500.0) -> np.ndarray:
    w = signal.fftconvolve(butter(butter(x, "highpass", hp, 2), "lowpass", lp, 2), ir)[: len(x)]
    return x + send * w


# ---------------------------------------------------------------------------------------------------------------
# A mixing track (one-shot or circular loop)

class Track:
    def __init__(self, dur: float, loop: bool = False):
        n = ns(dur)
        if loop:
            n -= n % OS
        self.x = np.zeros(n)
        self.loop = loop

    @property
    def n(self) -> int:
        return len(self.x)

    def add(self, sig: np.ndarray, at: float = 0.0, gain: float = 1.0) -> "Track":
        i = ns(at)
        if self.loop:                       # wrap tails around the loop point
            idx = (i + np.arange(len(sig))) % self.n
            np.add.at(self.x, idx, gain * sig)
        else:
            j = min(self.n, i + len(sig))
            if j > i:
                self.x[i:j] += gain * sig[: j - i]
        return self

    def process(self, fn: Callable[[np.ndarray], np.ndarray]) -> "Track":
        self.x = circular(fn, self.x) if self.loop else fn(self.x)
        return self

    def reverb(self, ir: np.ndarray, send: float, **kw) -> "Track":
        return self.process(lambda z: reverb(z, ir, send, **kw))


def circular(fn: Callable[[np.ndarray], np.ndarray], x: np.ndarray, down: int = 1, reps: int = 4) -> np.ndarray:
    """Apply a (causal, time-invariant) process to a periodic signal and return its steady-state period."""
    n = len(x)
    y = fn(np.tile(x, reps))
    m = n // down
    return y[(reps - 2) * m:(reps - 1) * m]


# ---------------------------------------------------------------------------------------------------------------
# Instruments

def burst(fc: float, q: float, tau: float, dur: float, seed: int, atk: float = 0.0002) -> np.ndarray:
    """A noise click: band-passed white noise with an exponential decay (time constant `tau`)."""
    n = ns(dur)
    t = tv(n)
    e = np.clip(t / atk, 0, 1) * np.exp(-t / tau) * end_fade(n, 0.001)
    return biquad(noise(n, seed) * e, "bp", fc, q) * math.sqrt(q)


def blip(f: float, t60: float, *, drop: float = 0.0, drop_t: float = 0.005, atk: float = 0.0008,
         dur: float | None = None) -> np.ndarray:
    """A sine ping whose pitch starts `drop` sharp (or flat if negative) and settles in ~`drop_t`."""
    n = ns(dur or t60 * 1.1)
    t = tv(n)
    fr = f * (1.0 + drop * np.exp(-t / drop_t))
    return np.sin(TAU * phase(fr)) * perc(n, atk, t60)


def glass(f: float, t60: float, *, bright: float = 0.8, drop: float = 0.03, drop_t: float = 0.015,
          strike: float = 0.10, seed: int = 0, dur: float | None = None, atk: float = 0.0015) -> np.ndarray:
    """Warm glass/mallet: 1:1 FM tine (bright strike, mellow body) + free-bar modes + strike noise."""
    n = ns(dur or t60 * 1.08)
    t = tv(n)
    fr = f * (1.0 + drop * np.exp(-t / drop_t))
    ph = phase(fr)
    index = bright * (0.18 + 1.25 * np.exp(-t / 0.040))
    # keep the FM sidebands (~index+2 harmonics) below the band edge
    index = np.minimum(index, max(0.0, TOP / f - 2.0))
    out = np.sin(TAU * ph + index * np.sin(TAU * ph)) * perc(n, atk, t60)
    for r, g, tf in ((2.756, 0.20, 0.30), (5.404, 0.07, 0.14)):
        if f * r < TOP - 1500:
            out += bright * g * np.sin(TAU * phase(fr * r)) * perc(n, atk * 0.7, t60 * tf)
    if strike:
        s = burst(min(f * 3.1, 7200.0), 1.3, 0.0012, 0.008, seed)
        out[: len(s)] += strike * bright * s
    return out


def thump(f0: float, f1: float, t60: float, *, drive: float = 2.2, glide: float = 0.035) -> np.ndarray:
    """A soft, punchy body hit: falling sine, lightly saturated so laptop speakers reproduce its harmonics."""
    n = ns(t60 * 1.05)
    t = tv(n)
    fr = f1 + (f0 - f1) * np.exp(-t / glide)
    return sat(np.sin(TAU * phase(fr)) * perc(n, 0.0012, t60), drive)


def knock(f: float, t60: float) -> np.ndarray:
    """Woody knock: band-limited triangle with a fast pitch drop through a lowpass."""
    n = ns(t60 * 1.1)
    t = tv(n)
    fr = f * (1.0 + 0.12 * np.exp(-t / 0.004))
    return triangle(fr, n, lowpass_tone(1700.0, 2)) * perc(n, 0.0006, t60)


# ---------------------------------------------------------------------------------------------------------------
# Sound registry

@dataclass
class Spec:
    name: str
    render: Callable[[], Track]
    loop: bool = False
    loudness: float = -20.0          # target K-weighted loudness (LUFS): momentary max (UI) / loop mean (panic)
    peak: float = -3.0               # true-peak ceiling (dBTP)
    hp: float = 50.0                 # final high-pass (Hz)


SPECS: list[Spec] = []


def sound(name: str, **kw):
    def deco(fn):
        SPECS.append(Spec(name, fn, **kw))
        return fn
    return deco


# ---- UI sounds ------------------------------------------------------------------------------------------------

def _keypress(pitch: float, seed: int) -> Track:
    T = Track(0.16)
    T.add(burst(4300 * pitch, 1.7, 0.0006, 0.006, seed), 0.0, 0.50)        # the tactile "tk"
    T.add(blip(1560 * pitch, 0.030, drop=0.09, drop_t=0.003), 0.0003, 0.26)  # a glassy point
    T.add(blip(540 * pitch, 0.024, drop=0.06, drop_t=0.003), 0.0, 0.20)      # tiny body
    return T.reverb(ROOM, 0.06)


@sound("keypress", loudness=-30.0, peak=-12.0)
def keypress():
    return _keypress(1.0, 101)


@sound("keypress-2", loudness=-30.0, peak=-12.0)
def keypress2():
    return _keypress(1.055, 102)


@sound("keypress-3", loudness=-30.0, peak=-12.0)
def keypress3():
    return _keypress(0.955, 103)


def _tick(note: str, seed: int, accent: float = 0.0) -> Track:
    f = hz(note)
    T = Track(0.32)
    T.add(burst(min(2.3 * f, 6200.0), 1.8, 0.0008, 0.008, seed), 0.0, 0.42 + 0.1 * accent)
    T.add(glass(f, 0.075 + 0.04 * accent, bright=0.5 + 0.2 * accent, drop=0.05, drop_t=0.005,
                strike=0.0, atk=0.0006), 0.0003, 0.42)
    T.add(knock(f / 4.0, 0.055), 0.0, 0.32)
    return T.reverb(ROOM, 0.10 + 0.04 * accent)


# Countdown: 5, 4 -> "tick" (E6); then 3, 2, 1 climb the E pentatonic (F#6, G#6, B6) into the enter chord (E).
@sound("tick", loudness=-25.0, peak=-8.0)
def tick():
    return _tick("E6", 201)


@sound("tick-3", loudness=-25.0, peak=-8.0)
def tick3():
    return _tick("F#6", 203, 0.25)


@sound("tick-2", loudness=-24.5, peak=-7.5)
def tick2():
    return _tick("G#6", 202, 0.5)


@sound("tick-1", loudness=-24.0, peak=-7.0)
def tick1():
    return _tick("B6", 201, 1.0)


@sound("countdown-start", loudness=-22.0)
def countdown_start():
    """The blur slides in from the top: an airy swell, then two soft notes a fourth apart (B4 -> E5)."""
    T = Track(1.5)
    n = ns(0.62)
    t = tv(n)
    fc = 480.0 * (1900.0 / 480.0) ** smoothstep(0.0, 0.42, t)
    env = smoothstep(0.0, 0.30, t) ** 1.5 * 10.0 ** (-3.0 * np.clip(t - 0.30, 0, None) / 0.30) * end_fade(n)
    air = butter(sweep_bp(noise(n, 301), fc, 0.8 + 0.9 * smoothstep(0, 0.4, t)), "lowpass", 5000.0, 2)
    T.add(air * env, 0.0, 0.32)
    T.add(glass(hz("B4"), 0.55, bright=0.45, drop=0.012, seed=302), 0.15, 0.48)
    T.add(glass(hz("E5"), 0.80, bright=0.55, drop=0.012, seed=303), 0.26, 0.58)
    m = ns(0.7)
    T.add(np.sin(TAU * phase(freq_array(hz("E4"), m))) * perc(m, 0.03, 0.55), 0.26, 0.10)  # warmth underneath
    return T.reverb(ROOM, 0.24)


@sound("enter", loudness=-18.0)
def enter():
    """Suction whoosh into a bump at 320 ms (= the shader's tBang), then an E-major strum that blooms with the
    expanding ring, prismatic glitter on the ring's rim and a soft echo ping 120 ms later."""
    B = 0.32
    T = Track(2.3)
    # 1) suction whoosh: a noise band accelerating upwards, getting more focused, into the bang
    n = ns(B + 0.10)
    t = tv(n)
    u = np.clip(t / B, 0, 1)
    fc = 280.0 * (4200.0 / 280.0) ** (u ** 1.5)
    env = u ** 2.4 * np.where(t > B, 10.0 ** (-3.0 * (t - B) / 0.07), 1.0) * end_fade(n)
    T.add(sweep_bp(noise(n, 401), fc, 0.7 + 1.9 * u) * env, 0.0, 0.55)
    # 2) tonal riser: E3 -> E5 octave pair gliding into the chord root
    fr = hz("E3") * 4.0 ** (u ** 1.35)
    ph = phase(fr)
    riser = (np.sin(TAU * ph) + 0.3 * np.sin(TAU * 2 * ph)) * u ** 1.8
    riser *= np.where(t > B, np.exp(-(t - B) / 0.012), 1.0) * end_fade(n)
    T.add(riser, 0.0, 0.13)
    # 3) the glow: a faint airy shimmer swelling into the bang
    hiss = butter(noise(n, 402), "highpass", 6500, 2) * u ** 3 * np.where(t > B, np.exp(-(t - B) / 0.03), 1.0)
    T.add(hiss * end_fade(n), 0.0, 0.07)
    # 4) the bump: soft punchy body + contact snap
    T.add(thump(170.0, 70.0, 0.20, glide=0.03), B, 0.62)
    T.add(burst(2500, 0.9, 0.0025, 0.03, 403), B, 0.34)
    # 5) bloom: an upward strum E5 B5 E6 G#6 B6
    for i, (note, g, t60) in enumerate([("E5", 0.52, 1.55), ("B5", 0.40, 1.35), ("E6", 0.34, 1.2),
                                        ("G#6", 0.25, 1.0), ("B6", 0.19, 0.9)]):
        T.add(glass(hz(note), t60, bright=0.95, drop=0.04, drop_t=0.018, seed=410 + i), B + 0.003 + 0.021 * i, g)
    # 6) ripple glitter: tiny high pings scattered along the expanding rim (E major pentatonic, 2.6-6.3 kHz)
    r = rng(420)
    pool = [hz(x) for x in ("E7", "F#7", "G#7", "B7", "C#8", "E8")]
    for j in range(10):
        at = B + 0.045 + 0.042 * j + r.uniform(-0.008, 0.008)
        T.add(blip(pool[r.integers(len(pool))], 0.16, drop=0.01, atk=0.002), at, 0.07 * 0.86 ** j)
    # 7) echo ring
    T.add(glass(hz("E7"), 0.45, bright=0.35, drop=0.02, strike=0.0), B + 0.12, 0.09)
    return T.reverb(HALL, 0.22)


@sound("dismiss", loudness=-23.0)
def dismiss():
    """Backing off: a falling breath and two soft notes stepping down (E5 -> B4). Gentle, not negative."""
    T = Track(1.2)
    n = ns(0.30)
    t = tv(n)
    fc = 2000.0 * (420.0 / 2000.0) ** smoothstep(0.0, 0.27, t)
    env = smoothstep(0, 0.025, t) * 10.0 ** (-3.0 * t / 0.30) * end_fade(n)
    T.add(butter(sweep_bp(noise(n, 501), fc, 1.1), "lowpass", 5000.0, 2) * env, 0.0, 0.32)
    T.add(glass(hz("E5"), 0.36, bright=0.5, drop=0.015, seed=502), 0.0, 0.46)
    T.add(glass(hz("B4"), 0.60, bright=0.42, drop=0.015, seed=503), 0.075, 0.55)
    return T.reverb(ROOM, 0.2)


@sound("unlock", loudness=-19.0)
def unlock():
    """A two-stage latch ("ka-chunk") then a quick rising E-major arpeggio that resolves on the octave."""
    T = Track(1.8)
    T.add(burst(3400, 2.6, 0.0011, 0.010, 601), 0.000, 0.55)               # bolt release
    T.add(blip(2950, 0.025, drop=0.05, drop_t=0.003), 0.000, 0.10)
    T.add(burst(1500, 1.6, 0.0020, 0.016, 602), 0.034, 0.55)               # bolt seats
    T.add(thump(240.0, 135.0, 0.075, glide=0.012), 0.034, 0.34)
    for i, (note, g, t60) in enumerate([("E5", 0.38, 0.34), ("G#5", 0.38, 0.38), ("B5", 0.42, 0.5),
                                        ("E6", 0.55, 1.05)]):
        T.add(glass(hz(note), t60, bright=0.85, drop=0.03, seed=610 + i), 0.075 + 0.055 * i, g)
    T.add(glass(hz("B6"), 0.65, bright=0.35, drop=0.01, strike=0.0), 0.075 + 0.165 + 0.012, 0.10)
    return T.reverb(ROOM, 0.18)


@sound("wrong-pin", loudness=-20.0)
def wrong_pin():
    """Two low, rough "nope" pulses: beating squares (155/164 Hz) sagging down, through a warm lowpass."""
    T = Track(0.55)
    for at, g in ((0.0, 1.0), (0.118, 0.82)):
        n = ns(0.096)
        t = tv(n)
        f1 = 155.0 * (1.0 - 0.10 * smoothstep(0.0, 0.09, t))
        tone = tones(lowpass_tone(1150.0, 2), formant_tone([(620.0, 500.0, 0.8)], floor=0.5))
        x = square(f1, n, tone) + 0.8 * square(f1 * 164.0 / 155.0, n, tone, ph0=0.25)
        T.add(sat(0.55 * x * gate(n, 0.003, 0.035), 1.7), at, 0.5 * g)
        T.add(thump(140.0, 85.0, 0.085, glide=0.02), at, 0.40 * g)
    return T.reverb(ROOM, 0.08)


@sound("question", loudness=-21.0)
def question():
    """A friendly two-note glass ping (B5 -> E6); the second note scoops up into place like a "?"."""
    T = Track(1.4)
    T.add(burst(3000, 0.8, 0.0009, 0.006, 701), 0.0, 0.10)
    T.add(glass(hz("B5"), 0.34, bright=0.5, drop=0.02, seed=702), 0.0, 0.46)
    T.add(glass(hz("E6"), 0.80, bright=0.58, drop=-0.03, drop_t=0.028, seed=703), 0.105, 0.56)
    return T.reverb(ROOM, 0.24)


# ---- Panic alarms (seamless loops) ----------------------------------------------------------------------------

def _honk(f: float, dur: float) -> np.ndarray:
    """A horn blast: scoop up into the note, slight wobble, sag at the end ("bwaaa-ah")."""
    n = ns(dur)
    t = tv(n)
    scoop = 1.0 - 0.17 * np.exp(-t / 0.026)
    sag = 1.0 - 0.09 * smoothstep(dur - 0.12, dur - 0.005, t)
    vib = 1.0 + 0.005 * np.sin(TAU * 6.3 * t)
    fr = f * scoop * sag * vib
    tone = tones(formant_tone([(1150.0, 420.0, 1.0), (2450.0, 650.0, 0.75), (3600.0, 900.0, 0.35)], floor=0.22),
                 lowpass_tone(4600.0, 3))
    x = saw(fr, n, tone) + 0.45 * np.sin(TAU * phase(fr))
    growl = 1.0 - 0.14 * (0.5 + 0.5 * np.sin(TAU * 31.0 * t))
    return sat(0.9 * x * growl * gate(n, 0.010, 0.045), 2.0)


@sound("panic-klaxon", loop=True, loudness=-10.5, peak=-1.0, hp=90.0)
def panic_klaxon():
    """Classic alarm horn, two blasts per 1.2 s loop (one every 600 ms)."""
    T = Track(1.2, loop=True)
    for at in (0.0, 0.6):
        T.add(_honk(hz("G#4"), 0.46), at, 0.8)
        T.add(burst(1800, 0.9, 0.003, 0.02, 801), at, 0.25)
    T.reverb(ROOM, 0.12)
    return T.process(lambda z: sat(1.15 * z, 1.6))


def _syllable(f: float, dur: float, vowels, *, sag: float = 0.0, vib: float = 0.0) -> np.ndarray:
    """A cartoon voice syllable: band-limited saw through formants morphing from vowels[0] to vowels[1]."""
    n = ns(dur)
    t = tv(n)
    u = smoothstep(0.0, dur, t)
    fr = f * (1.0 - sag * smoothstep(0.25 * dur, dur, t)) * (1.0 + vib * np.sin(TAU * 5.8 * t) * u)
    fr *= 1.0 + 0.04 * np.exp(-t / 0.012)              # slight scoop on the onset
    (a1, a2, a3), (b1, b2, b3) = vowels
    F = [a1 + (b1 - a1) * u, a2 + (b2 - a2) * u, a3 + (b3 - a3) * u]
    tone = tones(formant_tone([(F[0], 160.0, 1.0), (F[1], 220.0, 0.7), (F[2], 380.0, 0.3)], floor=0.04),
                 lowpass_tone(4500.0, 2))
    x = saw(fr, n, tone)
    # formants sliding over the harmonics change the level a lot; flatten it (20 ms RMS) and shape it ourselves
    k = np.hanning(ns(0.02))
    rms = np.sqrt(np.convolve(x * x, k, "same") / np.convolve(np.ones(n), k, "same"))
    return x / rms * 0.5 * gate(n, 0.008, min(0.07, 0.4 * dur)) * (1.0 - 0.4 * u ** 1.3)


@sound("panic-mistake", loop=True, loudness=-10.5, peak=-1.0, hp=90.0)
def panic_mistake():
    """An urgent cartoon "uh-oh!": G5 -> E5 sagging to D#5, a voice an octave below doubled by a bright mallet,
    twice per 1.2 s loop."""
    T = Track(1.2, loop=True)
    uh, oh, oo = (700.0, 1220.0, 2600.0), (520.0, 900.0, 2500.0), (380.0, 760.0, 2400.0)
    for k, at in enumerate((0.0, 0.6)):
        T.add(_syllable(hz("G4"), 0.135, (uh, uh)), at, 0.55)
        T.add(_syllable(hz("E4"), 0.33, (oh, oo), sag=0.06, vib=0.012), at + 0.165, 0.60)
        T.add(glass(hz("G5"), 0.22, bright=1.0, drop=0.05, seed=900 + k), at, 0.50)
        T.add(glass(hz("E5"), 0.42, bright=1.0, drop=0.05, seed=910 + k), at + 0.165, 0.55)
        # the sag, doubled on the mallet: a sliding sine from E5 to D#5
        m = ns(0.32)
        tt = tv(m)
        fr = hz("E5") * (1.0 - 0.06 * smoothstep(0.08, 0.32, tt))
        T.add(np.sin(TAU * phase(fr)) * gate(m, 0.02, 0.08), at + 0.165, 0.22)
        T.add(burst(2200, 1.2, 0.002, 0.012, 920 + k), at, 0.35)
        T.add(burst(1800, 1.2, 0.002, 0.012, 930 + k), at + 0.165, 0.30)
    T.reverb(ROOM, 0.14)
    return T.process(lambda z: sat(1.1 * z, 1.5))


@sound("panic-siren", loop=True, loudness=-10.5, peak=-1.0, hp=120.0)
def panic_siren():
    """A mechanical wail: rises 650 -> 1300 Hz in 0.95 s, falls back in 0.65 s; detuned twin for urgency.
    Tuned to a whole number of cycles so the 1.6 s loop is phase-continuous."""
    L = 1.6
    T = Track(L, loop=True)
    n = T.n
    t = tv(n)
    u = t / L
    c = np.where(u < 0.6, 0.5 - 0.5 * np.cos(np.pi * u / 0.6), 0.5 + 0.5 * np.cos(np.pi * (u - 0.6) / 0.4))
    f = 650.0 * 2.0 ** c
    cycles = f.sum() / SR
    f *= round(cycles) / cycles
    twin_cycles = round(cycles * 1.0075)
    f2 = f * twin_cycles / round(cycles)
    partials = [(1, 1.0), (2, 0.30), (3, 0.24), (4, 0.07), (5, 0.08), (7, 0.03)]
    tone = lowpass_tone(4200.0, 2)
    x = additive(f, n, partials, tone) + 0.55 * additive(f2, n, partials, tone, ph0=0.3)
    x *= 0.78 + 0.22 * c
    T.add(x, 0.0, 0.7)
    return T.process(lambda z: sat(z, 1.5))


def _crush(x: np.ndarray, rate: float, bits: int) -> np.ndarray:
    """Sample-rate + bit-depth reduction (the digital crunch), then smoothed so it isn't shrill."""
    step = SR / rate
    idx = (np.floor(np.arange(len(x)) / step) * step).astype(int)
    q = 2.0 ** (bits - 1)
    y = np.round(x[idx] * q) / q
    return butter(y, "lowpass", 8000.0, 4)


def _stutter(f: float, count: int, on: float, off: float, *, drop: float = 0.0, crush: float = 7000.0,
             bits: int = 5, wave_fn=square) -> np.ndarray:
    grain_n = ns(on)
    period = ns(on + off)
    out = np.zeros(period * count)
    for i in range(count):
        g = wave_fn(f * (1.0 - drop * i), grain_n, lowpass_tone(5000.0, 1)) * gate(grain_n, 0.0008, 0.002)
        out[i * period:i * period + grain_n] += g
    return _crush(0.8 * out, crush, bits)


def _dive(f0: float, f1: float, dur: float, crush: float = 9000.0) -> np.ndarray:
    n = ns(dur)
    t = tv(n)
    fr = f0 * (f1 / f0) ** (t / dur) ** 0.7
    return _crush(0.8 * square(fr, n, lowpass_tone(4000.0, 1)) * gate(n, 0.002, 0.02), crush, 6)


def _crunch(dur: float, seed: int) -> np.ndarray:
    n = ns(dur)
    return _crush(biquad(noise(n, seed), "bp", 1400, 0.7) * gate(n, 0.001, 0.01), 4000.0, 4)


@sound("panic-glitch", loop=True, loudness=-11.0, peak=-1.0, hp=90.0)
def panic_glitch():
    """A digital error stutter on a 100 ms grid (1.6 s loop): retriggered blips, crushed buzzes, a tape-stop
    dive and a reverse rise, then the motif answers itself lower."""
    T = Track(1.6, loop=True)
    T.add(_stutter(hz("C6"), 5, 0.018, 0.010), 0.00, 0.75)
    T.add(_crunch(0.045, 1001), 0.16, 0.6)
    T.add(_stutter(hz("E6"), 1, 0.035, 0.0, crush=12000, bits=6), 0.205, 0.55)
    T.add(_stutter(hz("D#6"), 1, 0.035, 0.0, crush=12000, bits=6), 0.25, 0.55)
    T.add(_dive(hz("G6"), 170.0, 0.17), 0.30, 0.7)
    T.add(_stutter(110.0, 3, 0.035, 0.012, crush=3000, bits=4, wave_fn=saw), 0.50, 0.8)
    T.add(_stutter(hz("G5"), 4, 0.012, 0.006, drop=0.03), 0.70, 0.75)
    T.add(_stutter(hz("C6"), 5, 0.018, 0.010), 0.80, 0.75)
    T.add(_crunch(0.045, 1002), 0.96, 0.6)
    for i, nm in enumerate(("C7", "B6", "C7")):
        T.add(_stutter(hz(nm), 1, 0.026, 0.0, crush=14000, bits=6, wave_fn=triangle), 1.0 + 0.032 * i, 0.5)
    T.add(_dive(180.0, hz("E6"), 0.12), 1.11, 0.6)
    T.add(_stutter(98.0, 3, 0.04, 0.012, crush=2500, bits=4, wave_fn=saw), 1.28, 0.8)
    T.reverb(ROOM, 0.10)
    return T.process(lambda z: sat(1.2 * z, 1.5))


# ---------------------------------------------------------------------------------------------------------------
# Mastering, metering, output

DECIM = signal.firwin(255, 21_500.0, fs=SR, window=("kaiser", 10.0))
K_SOS = np.array([[1.53512485958697, -2.69169618940638, 1.19839281085285, 1.0, -1.69065929318241, 0.73248077421585],
                  [1.0, -2.0, 1.0, 1.0, -1.99004745483398, 0.99007225036621]])   # BS.1770 K-weighting @ 48 kHz


def decimate(x: np.ndarray) -> np.ndarray:
    return signal.resample_poly(x, 1, OS, window=DECIM)


def true_peak(y: np.ndarray, loop: bool) -> float:
    z = np.tile(y, 3) if loop else np.concatenate([y, np.zeros(64)])
    up = signal.resample_poly(z, 4, 1)
    if loop:
        up = up[len(up) // 3: 2 * len(up) // 3]
    return float(np.max(np.abs(up)))


def loudness(y: np.ndarray, loop: bool) -> tuple[float, float]:
    """(momentary-max LUFS over 400 ms windows, mean LUFS over the sound / loop)."""
    w = ns(0.4, SR_OUT)
    if loop:
        z = signal.sosfilt(K_SOS, np.tile(y, 4))[2 * len(y):3 * len(y)]
        ms_mean = float(np.mean(z ** 2))
        zz = np.concatenate([z, z[:w]])
    else:
        zz = signal.sosfilt(K_SOS, np.concatenate([np.zeros(w), y, np.zeros(w)]))
        ms_mean = float(np.mean(signal.sosfilt(K_SOS, y) ** 2))
    c = np.cumsum(np.concatenate([[0.0], zz ** 2]))
    mom = (c[w:] - c[:-w]) / w
    db = lambda v: -0.691 + 10.0 * math.log10(max(v, 1e-12))
    return db(float(mom.max())), db(ms_mean)


def master(spec: Spec, track: Track) -> tuple[np.ndarray, float]:
    """High-pass, decimate and level a rendered track. Loops are pushed into a look-ahead limiter until they
    reach their loudness target (returns the limiter's peak gain reduction in dB); one-shots are only scaled."""
    hp = lambda z: butter(z, "highpass", spec.hp, 2)
    if spec.loop:
        x = circular(hp, track.x)
        ceiling = 10 ** ((spec.peak - 0.4) / 20)
        drive = ceiling / np.max(np.abs(x))
        for _ in range(4):
            y = circular(lambda z: decimate(limit(drive * z, ceiling)), x, OS)
            delta = spec.loudness - loudness(y, True)[1]
            if abs(delta) < 0.15:
                break
            drive *= 10 ** (delta / 20)
        reduction = 20 * math.log10(max(1.0, drive * np.max(np.abs(x)) / ceiling))
        mean = loudness(y, True)[1]
        gain_db = min(spec.loudness - mean, spec.peak - 20 * math.log10(true_peak(y, True)))
        return y * 10 ** (gain_db / 20), reduction
    else:
        y = decimate(hp(track.x))
        # trim the tail once it is 72 dB below the peak, then fade the last 25 ms to zero
        env = np.abs(y)
        thresh = env.max() * 10 ** (-72 / 20)
        last = int(np.nonzero(env > thresh)[0][-1]) if np.any(env > thresh) else len(y) - 1
        y = y[: min(len(y), last + ns(0.012, SR_OUT))]
        m = min(len(y), ns(0.025, SR_OUT))
        y[-m:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(1, m + 1) / m)
        k = min(len(y), 24)
        y[:k] *= np.sin(0.5 * np.pi * np.arange(k) / k) ** 2
    mom = loudness(y, False)[0]
    gain_db = min(spec.loudness - mom, spec.peak - 20 * math.log10(true_peak(y, False)))
    return y * 10 ** (gain_db / 20), 0.0


def to_pcm16(y: np.ndarray, seed: int, loop: bool) -> np.ndarray:
    r = rng(seed)
    dither = r.uniform(-0.5, 0.5, len(y)) + r.uniform(-0.5, 0.5, len(y))       # TPDF, +-1 LSB
    if not loop:                                   # true digital silence at both ends of one-shots
        e = np.ones(len(y))
        e[:24] = 0.0
        e[-48:] = 0.0
        dither *= e
    q = np.round(y * 32767.0 + dither)
    if not loop:
        q[0] = 0
        q[-1] = 0
    return np.clip(q, -32768, 32767).astype("<i2")


def write_wav(path: Path, pcm: np.ndarray) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR_OUT)
        w.writeframes(pcm.tobytes())


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == SR_OUT, path
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float) / 32768.0


def stats(name: str, y: np.ndarray, loop: bool) -> str:
    dbfs = lambda v: 20 * math.log10(max(v, 1e-9))
    mom, mean = loudness(y, loop)
    active = y[np.abs(y) > 10 ** (-50 / 20)]
    rms = math.sqrt(float(np.mean(active ** 2))) if len(active) else 0.0
    line = (f"{name:18s} {len(y) / SR_OUT * 1000:7.0f} ms  peak {dbfs(np.max(np.abs(y))):6.1f} dBFS  "
            f"TP {dbfs(true_peak(y, loop)):6.1f} dBTP  RMS {dbfs(rms):6.1f}  M-max {mom:6.1f} LUFS")
    if loop:
        # seam check: the 2nd difference across the loop point vs. the largest 2nd differences inside the loop
        d2 = np.abs(np.diff(np.concatenate([y[-2:], y[:2]]), 2))
        inner = np.abs(np.diff(y, 2))
        line += (f"  mean {mean:6.1f} LUFS  seam d2 {d2.max() * 32768:5.0f} LSB"
                 f" (inner p99.9 {np.quantile(inner, .999) * 32768:5.0f})")
    else:
        line += f"  ends {int(round(y[0] * 32768))},{int(round(y[-1] * 32768))}"
    return line


def spectrogram(path: Path, y: np.ndarray, title: str) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, (a0, a1) = plt.subplots(2, 1, figsize=(10, 5.2), height_ratios=[1, 2.4], sharex=True)
    t = np.arange(len(y)) / SR_OUT
    a0.plot(t, y, lw=0.4, color="#3460F0")
    a0.set_ylim(-1, 1)
    a0.set_title(title, fontsize=10)
    f, tt, S = signal.spectrogram(y, fs=SR_OUT, nperseg=1024, noverlap=896, window="hann")
    a1.pcolormesh(tt, f[1:], 10 * np.log10(S[1:] + 1e-14), shading="auto", vmin=-120, vmax=-40, cmap="magma")
    a1.set_yscale("log")
    a1.set_ylim(50, 24000)
    a1.set_ylabel("Hz")
    a1.set_xlabel("s")
    fig.tight_layout()
    fig.savefig(path, dpi=90)
    plt.close(fig)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--only", default="", help="comma-separated sound names")
    ap.add_argument("--report", action="store_true", help="print stats for the written files")
    ap.add_argument("--spectrograms", type=Path, help="write a waveform + spectrogram PNG per sound here")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    args.out.mkdir(parents=True, exist_ok=True)
    if args.spectrograms:
        args.spectrograms.mkdir(parents=True, exist_ok=True)
    for i, spec in enumerate(SPECS):
        if only and spec.name not in only:
            continue
        y, reduction = master(spec, spec.render())
        pcm = to_pcm16(y, 5000 + i, spec.loop)
        path = args.out / f"{spec.name}.wav"
        write_wav(path, pcm)
        back = read_wav(path)
        if args.report or args.spectrograms:
            print(stats(spec.name, back, spec.loop) + (f"  limiter GR {reduction:4.1f} dB" if spec.loop else ""))
        else:
            print(f"wrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")
        if args.spectrograms:
            spectrogram(args.spectrograms / f"{spec.name}.png", np.tile(back, 2) if spec.loop else back,
                        spec.name + (" (2 loops)" if spec.loop else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
