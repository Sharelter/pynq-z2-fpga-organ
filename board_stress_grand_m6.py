#!/usr/bin/env python3
"""Stress the M6 grand-space settings with nine sustained full-velocity voices."""

from pathlib import Path
import time

from pynq_organ_m6 import OrganM6Overlay


def main() -> None:
    root = Path(__file__).resolve().parent
    notes = (36, 43, 48, 52, 55, 60, 64, 67, 72)
    with OrganM6Overlay(
        root / "build/organ_m6.bit",
        codec_volume=50,
        feedback=0.955,
        wet=0.38,
        damping_alpha=(0.52, 0.50, 0.48, 0.46),
        early_reflection_gains=(0.60, 0.40, 0.30, 0.20),
    ) as organ:
        for note in notes:
            organ.note_on(note, stop="principal", gain=0.045, velocity=1.0)
        assert organ.allocated_voice_count == 9
        assert organ.active_count() == 9
        time.sleep(5.0)
        for note in notes:
            assert organ.note_off(note)
        time.sleep(6.0)
        clipped = organ.clip_detected()
        print(f"GRAND_STRESS voices=9 hold_s=5 tail_s=6 clip={clipped}")
        if clipped:
            raise RuntimeError("grand-space preset asserted the sticky clip flag")


if __name__ == "__main__":
    main()
