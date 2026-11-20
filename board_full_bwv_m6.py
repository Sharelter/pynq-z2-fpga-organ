#!/usr/bin/env python3
"""Run and validate the complete 572-second BWV 565 M6 playback."""

import json
from pathlib import Path

from midi_player_m4 import OrganMidiPlayer, prepare_midi_file
from pynq_organ_m6 import OrganM6Overlay


def main() -> None:
    root = Path(__file__).resolve().parent
    prepared = prepare_midi_file(root / "ToccataFugue.mid")
    if len(prepared.events) != 7302 or abs(prepared.duration - 572.0) > 1e-6:
        raise RuntimeError("unexpected BWV 565 MIDI input")

    with OrganM6Overlay(
        root / "build/organ_m6.bit",
        codec_volume=39,
        feedback=0.88,
        wet=0.22,
        damping_alpha=(0.52, 0.50, 0.48, 0.46),
        early_reflection_gains=(0.60, 0.40, 0.30, 0.20),
    ) as organ:
        player = OrganMidiPlayer(
            organ, prepared, stop="principal", voice_gain=0.025,
            stats_interval=60.0,
        )
        player.play(speed=1.0)
        clipped = organ.clip_detected()
        result = {
            "events": len(prepared.events),
            "score_seconds": prepared.duration,
            "peak_polyphony": player.statistics.peak_polyphony,
            "voice_steals": organ.stolen_voice_count,
            "maximum_lateness_ms": round(
                player.statistics.maximum_lateness * 1000.0, 6),
            "late_events_over_10ms": player.statistics.late_events,
            "clipping_events": player.statistics.clip_reports,
            "clip": clipped,
            "note_on_errors": player.statistics.note_on_errors,
            "note_off_errors": player.statistics.note_off_errors,
            "control_errors": player.statistics.control_errors,
        }
        print("BWV565_M6_RESULT " + json.dumps(result, sort_keys=True), flush=True)
        if clipped or result["clipping_events"]:
            raise RuntimeError("PL clipping flag asserted during playback")
        if (result["voice_steals"] or player.statistics.event_errors):
            raise RuntimeError("voice steals or MIDI dispatch errors detected")


if __name__ == "__main__":
    main()
