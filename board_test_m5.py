#!/usr/bin/env python3
"""Audition a dry chord followed by the same chord through the FDN."""

from pathlib import Path
import time

from pynq_organ_m5 import OrganM5Overlay


def chord(organ: OrganM5Overlay) -> None:
    notes = (48, 55, 60, 64, 67, 72)
    for note in notes:
        organ.note_on(note, stop="principal", gain=0.025, velocity=0.8)
    time.sleep(0.55)
    for note in notes:
        organ.note_off(note)


def main() -> None:
    root = Path(__file__).resolve().parent
    with OrganM5Overlay(root / "build/organ_m5.bit", codec_volume=39,
                        reverb_enabled=False) as organ:
        print("Dry chord...", flush=True)
        chord(organ)
        time.sleep(0.5)
        print("FDN chord (feedback=0.90, wet=0.30)...", flush=True)
        organ.configure_reverb(enabled=True, feedback=0.90, wet=0.30,
                               clear_clip=True)
        chord(organ)
        print("Listening to the three-second decay...", flush=True)
        time.sleep(3.0)
        print(f"Clip flag: {organ.clip_detected()}")
        if organ.clip_detected():
            raise RuntimeError("FDN or output mixer clipped; reduce gain/wet/feedback")


if __name__ == "__main__":
    main()
