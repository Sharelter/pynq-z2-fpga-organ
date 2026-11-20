#!/usr/bin/env python3
"""Objective register, mailbox, voice, and clipping checks for M6."""

from pathlib import Path
import time

from pynq_organ_m6 import OrganM6Overlay


def close_enough(actual: float, expected: float) -> bool:
    return abs(actual - expected) <= (1.5 / 32767.0)


def main() -> None:
    root = Path(__file__).resolve().parent
    expected_alpha = (0.52, 0.50, 0.48, 0.46)
    expected_gains = (0.60, 0.40, 0.30, 0.20)
    with OrganM6Overlay(
        root / "build/organ_m6.bit",
        codec_volume=39,
        feedback=0.88,
        wet=0.22,
        damping_alpha=expected_alpha,
        early_reflection_gains=expected_gains,
    ) as organ:
        assert organ.get_reverb_enabled()
        assert organ.get_early_reflections_enabled()
        assert close_enough(organ.get_feedback(), 0.88)
        assert close_enough(organ.get_wet_mix(), 0.22)
        assert all(close_enough(a, b) for a, b in
                   zip(organ.get_damping_alpha(), expected_alpha))
        assert all(close_enough(a, b) for a, b in
                   zip(organ.get_early_reflection_gains(), expected_gains))

        organ.set_early_reflections_enabled(False)
        assert not organ.get_early_reflections_enabled()
        organ.set_early_reflections_enabled(True)
        organ.set_damping_alpha(0.40)
        assert all(close_enough(item, 0.40)
                   for item in organ.get_damping_alpha())
        organ.set_damping_alpha(expected_alpha)

        notes = (48, 55, 60, 64, 67, 72)
        for note in notes:
            organ.note_on(note, stop="principal", gain=0.015, velocity=0.8)
        assert organ.allocated_voice_count == len(notes)
        assert organ.active_count() == len(notes)
        time.sleep(0.25)
        for note in notes:
            assert organ.note_off(note)
        assert organ.allocated_voice_count == 0
        time.sleep(2.0)
        assert not organ.clip_detected(), "sticky PL clipping flag was asserted"

        print("M6_OBJECTIVE_SMOKE PASS")
        print(f"feedback={organ.get_feedback():.6f}")
        print(f"wet={organ.get_wet_mix():.6f}")
        print("alpha=" + ",".join(f"{item:.6f}"
                                  for item in organ.get_damping_alpha()))
        print("early_gains=" + ",".join(f"{item:.6f}"
                                        for item in organ.get_early_reflection_gains()))
        print("clip=False")


if __name__ == "__main__":
    main()
