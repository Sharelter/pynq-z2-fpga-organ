#!/usr/bin/env python3
"""Conservative two-second PYNQ-Z2 Milestone-1 board test."""

from pathlib import Path
import time

from pynq_organ import OrganOverlay


def main() -> None:
    here = Path(__file__).resolve().parent
    with OrganOverlay(here / "build" / "organ_dds.bit", codec_volume=39) as organ:
        ftw = organ.set_frequency(440.0)
        print(f"FTW: 0x{ftw:08x}")
        print("Before enable:", organ.diagnostics())
        organ.enable()
        time.sleep(0.050)
        print("Enabled:", organ.diagnostics())
        print("Playing 440 Hz for two seconds through HP OUT...")
        time.sleep(2.0)
        organ.disable()
        print("Test complete; oscillator disabled and codec will be muted.")


if __name__ == "__main__":
    main()
