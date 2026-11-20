#!/usr/bin/env python3
"""Generate the signed 24-bit, 1024-sample DDS sine ROM."""

from pathlib import Path
import math


DEPTH = 1024
WIDTH = 24
OUTPUT = Path(__file__).resolve().parents[1] / "rtl" / "sine_1024x24.mem"


def main() -> None:
    maximum = (1 << (WIDTH - 1)) - 1
    mask = (1 << WIDTH) - 1
    values = []
    for index in range(DEPTH):
        sample = round(maximum * math.sin(2.0 * math.pi * index / DEPTH))
        values.append(f"{sample & mask:06x}")
    OUTPUT.write_text("\n".join(values) + "\n", encoding="ascii")
    print(f"Wrote {DEPTH} samples to {OUTPUT}")


if __name__ == "__main__":
    main()
