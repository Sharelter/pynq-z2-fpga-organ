#!/usr/bin/env python3
"""Audition four additive stops and an eight-voice chord."""

from pathlib import Path
import time

from pynq_organ_m2 import OrganM2Overlay, STOP_IDS


def main() -> None:
    root = Path(__file__).resolve().parent
    with OrganM2Overlay(root / "build/organ_m2.bit", codec_volume=39) as organ:
        for stop in STOP_IDS:
            print(f"Audition: {stop}", flush=True)
            organ.note_on(0, 440.0, stop=stop, gain=0.10)
            time.sleep(0.55)
            organ.note_off(0)
            time.sleep(0.10)

        # C-major/add-6 voicing spread over eight voices. Conservative
        # per-voice gain prevents clipping when all waves align.
        frequencies = [130.813, 164.814, 195.998, 261.626,
                       329.628, 391.995, 523.251, 659.255]
        stops = ["principal", "principal", "flute", "principal",
                 "flute", "principal", "sine", "flute"]
        for voice, (frequency, stop) in enumerate(zip(frequencies, stops)):
            organ.note_on(voice, frequency, stop=stop, gain=0.055)
        time.sleep(0.050)
        print(f"Eight-voice active mask: 0x{organ.active_mask():02x}", flush=True)
        if organ.active_mask() != 0xFF:
            raise RuntimeError("not all eight PL voices became active")
        print("Playing eight-voice organ chord for two seconds...", flush=True)
        time.sleep(2.0)
        organ.all_notes_off()
        time.sleep(0.050)
        print(f"Final active mask: 0x{organ.active_mask():02x}")
        if organ.active_mask() != 0:
            raise RuntimeError("voices did not turn off")


if __name__ == "__main__":
    main()
