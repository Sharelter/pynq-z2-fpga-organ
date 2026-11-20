import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import mido

from midi_player_m4 import (
    MidiEvent,
    OrganMidiPlayer,
    PreparedMidi,
    prepare_midi_file,
)


class FakeOrgan:
    clip_flag_available = False

    def __init__(self):
        self.notes = {}
        self.stolen_voice_count = 0
        self.all_off_calls = 0
        self.note_off_calls = 0
        self.note_on_calls = 0

    @property
    def allocated_voice_count(self):
        return len(self.notes)

    def reset_performance_counters(self):
        self.stolen_voice_count = 0

    def note_on(self, note, *, channel, stop, gain, velocity):
        self.note_on_calls += 1
        self.notes[(channel, note)] = (stop, gain, velocity)
        return len(self.notes) - 1

    def note_off(self, note, *, channel):
        self.note_off_calls += 1
        return self.notes.pop((channel, note), None) is not None

    def all_notes_off(self):
        self.notes.clear()
        self.all_off_calls += 1

    def clip_detected(self):
        return None


class MidiPlayerTests(unittest.TestCase):
    def test_preparse_tempo_and_velocity_zero(self):
        midi = mido.MidiFile(type=0, ticks_per_beat=480)
        track = mido.MidiTrack([
            mido.Message("note_on", note=60, velocity=90),
            mido.MetaMessage("set_tempo", tempo=1_000_000, time=480),
            mido.Message("control_change", control=64, value=127, time=240),
            mido.Message("note_on", note=60, velocity=0, time=240),
        ])
        midi.tracks.append(track)
        with TemporaryDirectory() as directory:
            path = Path(directory) / "tempo.mid"
            midi.save(path)
            prepared = prepare_midi_file(path)

        self.assertEqual(prepared.events, (
            MidiEvent(0.0, "note_on", 0, note=60, velocity=90),
            MidiEvent(1.0, "control_change", 0, control=64, value=127),
            MidiEvent(1.5, "note_off", 0, note=60),
        ))
        self.assertEqual(prepared.duration, 1.5)
        self.assertEqual(prepared.tempo_changes, 1)

    def test_bwv565_preparse(self):
        path = Path(__file__).resolve().parents[1] / "ToccataFugue.mid"
        if not path.is_file():
            self.skipTest("optional Mutopia BWV 565 fixture is absent")
        prepared = prepare_midi_file(path)
        self.assertEqual(prepared.tracks, 4)
        self.assertEqual(prepared.ticks_per_beat, 384)
        self.assertEqual(len(prepared.events), 7302)
        self.assertAlmostEqual(prepared.duration, 572.0, places=6)
        self.assertEqual(prepared.tempo_changes, 1)
        self.assertEqual(prepared.score_peak_polyphony, 9)
        self.assertEqual(prepared.ignored_messages, {"program_change": 6})

    def test_sustain_and_cleanup(self):
        events = (
            MidiEvent(0.000, "note_on", 0, note=60, velocity=100),
            MidiEvent(0.001, "control_change", 0, control=64, value=127),
            MidiEvent(0.002, "note_off", 0, note=60),
            MidiEvent(0.003, "control_change", 0, control=64, value=0),
        )
        prepared = PreparedMidi(Path("test.mid"), events, 0.003, 1, 480, 0, 1, {})
        organ = FakeOrgan()
        player = OrganMidiPlayer(organ, prepared, stats_interval=1.0)
        player.play(speed=100.0)
        self.assertEqual(organ.notes, {})
        self.assertEqual(organ.all_off_calls, 1)
        self.assertEqual(player.statistics.event_errors, 0)
        self.assertEqual(player.statistics.peak_polyphony, 1)

    def test_stop_interrupts_wait(self):
        events = (
            MidiEvent(0.000, "note_on", 0, note=60, velocity=100),
            MidiEvent(10.000, "note_off", 0, note=60),
        )
        prepared = PreparedMidi(Path("long.mid"), events, 10.0, 1, 480, 0, 1, {})
        organ = FakeOrgan()
        player = OrganMidiPlayer(organ, prepared, stats_interval=10.0)
        thread = player.play_async()
        time.sleep(0.020)
        player.stop()
        thread.join(1.0)
        self.assertFalse(thread.is_alive())
        self.assertEqual(organ.notes, {})
        self.assertEqual(organ.all_off_calls, 1)

    def test_overlapping_identical_notes_are_reference_counted(self):
        events = (
            MidiEvent(0.000, "note_on", 0, note=60, velocity=100),
            MidiEvent(0.001, "note_on", 0, note=60, velocity=100),
            MidiEvent(0.002, "note_off", 0, note=60),
            MidiEvent(0.003, "note_off", 0, note=60),
        )
        prepared = PreparedMidi(Path("overlap.mid"), events, 0.003,
                                1, 480, 0, 2, {})
        organ = FakeOrgan()
        player = OrganMidiPlayer(organ, prepared, stats_interval=1.0)
        player.play(speed=100.0)
        self.assertEqual(organ.note_off_calls, 1)
        self.assertEqual(organ.note_on_calls, 1)
        self.assertEqual(player.statistics.note_off_errors, 0)
        self.assertEqual(player.statistics.peak_polyphony, 1)

    def test_seek_primes_notes_already_sounding(self):
        events = (
            MidiEvent(0.000, "note_on", 0, note=60, velocity=100),
            MidiEvent(0.700, "note_off", 0, note=60),
            MidiEvent(0.800, "note_on", 0, note=64, velocity=90),
            MidiEvent(1.000, "note_off", 0, note=64),
        )
        prepared = PreparedMidi(Path("seek.mid"), events, 1.0,
                                1, 480, 0, 1, {})
        organ = FakeOrgan()
        player = OrganMidiPlayer(organ, prepared, stats_interval=1.0)
        player.play(start_seconds=0.5, speed=100.0)
        self.assertEqual(organ.note_on_calls, 2)
        self.assertEqual(organ.note_off_calls, 2)
        self.assertEqual(player.statistics.event_errors, 0)
        self.assertEqual(player.statistics.peak_polyphony, 1)


if __name__ == "__main__":
    unittest.main()
