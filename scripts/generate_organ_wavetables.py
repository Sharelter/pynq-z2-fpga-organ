#!/usr/bin/env python3
"""Generate four normalized additive organ wavetables for Milestone 2."""

from pathlib import Path
import math


DEPTH = 1024
WIDTH = 24
OUTPUT = Path(__file__).resolve().parents[1] / "rtl" / "organ_wavetables_4x1024x24.mem"

# Harmonic number: linear amplitude. Each table is normalized independently.
STOPS = {
    "sine": {1: 1.0},
    "principal": {1: 1.0, 2: 0.50, 3: 0.30, 4: 0.20, 5: 0.12, 6: 0.08, 8: 0.05},
    "flute": {1: 1.0, 2: 0.12, 3: 0.04, 4: 0.02},
    "reed": {1: 1.0, 2: 0.65, 3: 0.50, 4: 0.40, 5: 0.30, 6: 0.25, 7: 0.20, 8: 0.15},
}


def make_table(partials: dict[int, float]) -> list[int]:
    floating = []
    for index in range(DEPTH):
        phase = 2.0 * math.pi * index / DEPTH
        floating.append(sum(level * math.sin(harmonic * phase)
                            for harmonic, level in partials.items()))
    peak = max(abs(value) for value in floating)
    maximum = (1 << (WIDTH - 1)) - 1
    return [round(value * maximum / peak) for value in floating]


def main() -> None:
    mask = (1 << WIDTH) - 1
    lines = []
    for name, partials in STOPS.items():
        table = make_table(partials)
        lines.extend(f"{sample & mask:06x}" for sample in table)
        print(f"table {len(lines) // DEPTH - 1}: {name}, {len(partials)} partials")
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"Wrote {len(lines)} samples to {OUTPUT}")


if __name__ == "__main__":
    main()
