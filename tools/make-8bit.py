#!/usr/bin/env python3
"""Generate the bundled `8bit` sound set: original chiptune effects.

Every melody here was written for feedme. Nothing is sampled or transcribed
from an existing game. Pure standard library, so anyone can regenerate the set:

    python3 tools/make-8bit.py sounds/8bit
"""

import math
import struct
import sys
import wave
from pathlib import Path

RATE = 22050
VOLUME = 0.125  # about -20 LUFS, like the other bundled sounds
NOTE_GAP = 0.012  # short silence between notes, like a sequencer re-triggering


def note_hz(name):
    """Frequency of a note such as 'A4', 'C#5' or 'Bb3' (A4 = 440 Hz)."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semitone = names[name[0]]
    rest = name[1:]
    if rest.startswith("#"):
        semitone, rest = semitone + 1, rest[1:]
    elif rest.startswith("b"):
        semitone, rest = semitone - 1, rest[1:]
    octave = int(rest)
    return 440.0 * 2 ** ((semitone + 12 * (octave - 4)) / 12)


class Pulse:
    """NES-style pulse channel with a continuous phase across segments."""

    def __init__(self, duty=0.5):
        self.duty = duty
        self.phase = 0.0
        self.samples = []

    def tone(self, seconds, start_hz, end_hz=None, vibrato_hz=0.0, vibrato_depth=0.0, decay=0.0):
        end_hz = start_hz if end_hz is None else end_hz
        count = int(seconds * RATE)
        for i in range(count):
            progress = i / max(count - 1, 1)
            hz = start_hz + (end_hz - start_hz) * progress
            if vibrato_hz:
                hz *= 1 + vibrato_depth * math.sin(2 * math.pi * vibrato_hz * i / RATE)
            self.phase = (self.phase + hz / RATE) % 1.0
            level = VOLUME * (1 - decay * progress)
            # 3 ms fade at both ends avoids clicks between notes.
            edge = min(i, count - 1 - i) / (0.003 * RATE)
            level *= min(edge, 1.0)
            self.samples.append(level if self.phase < self.duty else -level)
        return self

    def rest(self, seconds):
        self.samples.extend([0.0] * int(seconds * RATE))
        return self

    def notes(self, names, seconds_each, **kwargs):
        for name in names:
            self.tone(seconds_each - NOTE_GAP, note_hz(name), **kwargs)
            self.rest(NOTE_GAP)
        return self


def pipe_down():
    """Three falling 'vwoop' pulses: sliding down into somewhere."""
    p = Pulse(duty=0.25)
    for start in (880, 740, 620):
        p.tone(0.16, start, start / 3.2)
        p.rest(0.05)
    return p


def game_over():
    """A sad chromatic slide down, ending on a wobbling low note."""
    p = Pulse(duty=0.5)
    p.notes(["G5", "F#5", "F5"], 0.22)
    p.tone(0.75, note_hz("E5"), vibrato_hz=7, vibrato_depth=0.03, decay=0.85)
    return p


def power_up():
    """A fast major arpeggio climbing three octaves."""
    p = Pulse(duty=0.125)
    p.notes(["C5", "E5", "G5", "C6", "E6", "G6", "C7"], 0.065)
    p.tone(0.25, note_hz("E7"), decay=0.9)
    return p


def jump():
    """A quick upward chirp."""
    p = Pulse(duty=0.25)
    p.tone(0.14, 260, 900, decay=0.4)
    return p


SOUNDS = {
    "pipe-down.wav": pipe_down,
    "game-over.wav": game_over,
    "power-up.wav": power_up,
    "jump.wav": jump,
}


def write_wav(path, samples):
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-8bit.py <output-dir>")
    outdir = Path(sys.argv[1])
    outdir.mkdir(parents=True, exist_ok=True)
    for filename, build in SOUNDS.items():
        write_wav(outdir / filename, build().samples)
        print(outdir / filename)


if __name__ == "__main__":
    main()
