#!/usr/bin/env python3
"""Exercise 128 voices, oldest-note stealing, and audible summed output."""

from pathlib import Path
import time

from pynq_organ_m3 import OrganM3Overlay


def main() -> None:
    root = Path(__file__).resolve().parent
    chord = (130.813, 164.814, 195.998, 261.626,
             329.628, 391.995, 523.251, 659.255)
    stops = ("principal", "flute", "principal", "sine",
             "flute", "principal", "sine", "flute")

    with OrganM3Overlay(root / "build/organ_m3.bit", codec_volume=39) as organ:
        print("Allocating 128 low-gain voices...", flush=True)
        for note_id in range(organ.VOICES):
            group = note_id // len(chord)
            cents = (group - 7.5) * 0.35
            frequency = chord[note_id % len(chord)] * 2.0 ** (cents / 1200.0)
            voice = organ.note_on_hz(note_id, frequency,
                                     stop=stops[note_id % len(stops)],
                                     gain=0.0025)
            if voice != note_id:
                raise RuntimeError(f"allocator returned voice {voice}, expected {note_id}")

        time.sleep(0.100)
        masks = organ.active_masks()
        print("Active masks:", " ".join(f"0x{word:08x}" for word in masks),
              flush=True)
        print(f"Active voice count: {organ.active_count()}", flush=True)
        if masks != (0xFFFFFFFF,) * 4 or organ.active_count() != 128:
            raise RuntimeError("not all 128 PL voices became active")

        print("Playing the 128-voice organ chord for two seconds...", flush=True)
        time.sleep(2.0)

        stolen_voice = organ.note_on_hz("steal-test", 440.0,
                                        stop="principal", gain=0.0025)
        print(f"129th note stole oldest voice: {stolen_voice}", flush=True)
        if stolen_voice != 0 or organ.active_count() != 128:
            raise RuntimeError("oldest-note stealing failed")
        time.sleep(0.250)

        organ.all_notes_off()
        time.sleep(0.100)
        final_masks = organ.active_masks()
        print("Final masks:", " ".join(f"0x{word:08x}" for word in final_masks))
        if final_masks != (0, 0, 0, 0):
            raise RuntimeError("voices did not turn off")


if __name__ == "__main__":
    main()
