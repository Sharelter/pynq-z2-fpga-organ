#!/usr/bin/env python3
"""Objective M6.1 envelope, release-aware allocation, and clipping test."""

from pathlib import Path
import time

from pynq_organ_m61 import OrganM61Overlay


def wait_for_active(organ: OrganM61Overlay, expected: int,
                    timeout: float) -> float:
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if organ.active_count() == expected:
            return time.monotonic() - start
        time.sleep(0.001)
    raise TimeoutError(f"active voice count did not reach {expected}")


def main() -> None:
    root = Path(__file__).resolve().parent
    with OrganM61Overlay(
        root / "build/organ_m61.bit", codec_volume=45,
        feedback=0.955, wet=0.38,
    ) as organ:
        first = organ.note_on(60, stop="principal", gain=0.045, velocity=1.0)
        wait_for_active(organ, 1, 0.1)
        time.sleep(0.050)
        assert organ.note_off(60)
        # Software ownership ends immediately, while the PL voice must remain
        # active during its release ramp.
        assert organ.allocated_voice_count == 0
        assert organ.active_count() == 1
        release_seconds = wait_for_active(organ, 0, 0.2)

        # A new note during another voice's release must use a different slot.
        first = organ.note_on(60, stop="principal", gain=0.045, velocity=1.0)
        time.sleep(0.020)
        assert organ.note_off(60)
        second = organ.note_on(64, stop="principal", gain=0.045, velocity=1.0)
        assert second != first
        assert organ.note_off(64)
        wait_for_active(organ, 0, 0.2)
        assert not organ.clip_detected()
        print(f"M61_ENVELOPE PASS release_ms={release_seconds*1000.0:.3f} "
              f"release_voice={first} new_voice={second} clip=False")


if __name__ == "__main__":
    main()
