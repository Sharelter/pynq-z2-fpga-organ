#!/usr/bin/env python3
"""Real-time Standard MIDI File player for the M3/M5/M6 PYNQ organ."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import threading
import time
from typing import TYPE_CHECKING

import mido

if TYPE_CHECKING:
    from pynq_organ_m3 import OrganM3Overlay


@dataclass(frozen=True, slots=True)
class MidiEvent:
    timestamp: float
    kind: str
    channel: int
    note: int = 0
    velocity: int = 0
    control: int = 0
    value: int = 0


@dataclass(frozen=True, slots=True)
class PreparedMidi:
    path: Path
    events: tuple[MidiEvent, ...]
    duration: float
    tracks: int
    ticks_per_beat: int
    tempo_changes: int
    score_peak_polyphony: int
    ignored_messages: dict[str, int]


@dataclass(slots=True)
class PlaybackStatistics:
    note_on_errors: int = 0
    note_off_errors: int = 0
    control_errors: int = 0
    ignored_controls: int = 0
    late_events: int = 0
    maximum_lateness: float = 0.0
    peak_polyphony: int = 0
    clip_reports: int = 0

    @property
    def event_errors(self) -> int:
        return self.note_on_errors + self.note_off_errors + self.control_errors


def prepare_midi_file(path: str | Path) -> PreparedMidi:
    """Parse all tracks and convert delta ticks to absolute wall-clock times."""
    midi_path = Path(path).expanduser().resolve()
    midi = mido.MidiFile(midi_path)
    tempo = 500_000  # MIDI default: 120 beats/minute.
    absolute_seconds = 0.0
    events: list[MidiEvent] = []
    ignored: Counter[str] = Counter()
    tempo_changes = 0
    active_notes: Counter[tuple[int, int]] = Counter()
    score_polyphony = 0

    for message in mido.merge_tracks(midi.tracks):
        absolute_seconds += mido.tick2second(
            message.time, midi.ticks_per_beat, tempo
        )
        if message.is_meta:
            if message.type == "set_tempo":
                tempo = message.tempo
                tempo_changes += 1
            continue

        if message.type == "note_on":
            kind = "note_off" if message.velocity == 0 else "note_on"
            events.append(MidiEvent(absolute_seconds, kind, message.channel,
                                    note=message.note, velocity=message.velocity))
            key = (message.channel, message.note)
            if kind == "note_on":
                active_notes[key] += 1
            elif active_notes[key]:
                active_notes[key] -= 1
            score_polyphony = max(score_polyphony, sum(active_notes.values()))
        elif message.type == "note_off":
            events.append(MidiEvent(absolute_seconds, "note_off", message.channel,
                                    note=message.note, velocity=message.velocity))
            key = (message.channel, message.note)
            if active_notes[key]:
                active_notes[key] -= 1
        elif message.type == "control_change":
            events.append(MidiEvent(absolute_seconds, "control_change",
                                    message.channel, control=message.control,
                                    value=message.value))
        else:
            ignored[message.type] += 1

    return PreparedMidi(
        path=midi_path,
        events=tuple(events),
        duration=absolute_seconds,
        tracks=len(midi.tracks),
        ticks_per_beat=midi.ticks_per_beat,
        tempo_changes=tempo_changes,
        score_peak_polyphony=score_polyphony,
        ignored_messages=dict(sorted(ignored.items())),
    )


class OrganMidiPlayer:
    """Absolute-time MIDI scheduler with sustain and clean interruption."""

    def __init__(self, organ: "OrganM3Overlay", prepared: PreparedMidi, *,
                 stop: str = "principal", voice_gain: float = 0.03,
                 stats_interval: float = 1.0) -> None:
        if not 0.0 <= float(voice_gain) <= 1.0:
            raise ValueError("voice_gain must be in [0, 1]")
        if float(stats_interval) <= 0.0:
            raise ValueError("stats_interval must be positive")
        self.organ = organ
        self.prepared = prepared
        self.stop_name = stop
        self.voice_gain = float(voice_gain)
        self.stats_interval = float(stats_interval)
        self.statistics = PlaybackStatistics()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._sustain = [False] * 16
        self._pressed = [Counter() for _ in range(16)]
        self._deferred = [set() for _ in range(16)]
        self._channel_volume = [127] * 16
        self._expression = [127] * 16
        self._clip_seen = False

    def stop(self) -> None:
        """Request prompt termination; safe to call from another thread."""
        self._stop_event.set()

    def play_async(self, *, max_seconds: float | None = None,
                   speed: float = 1.0,
                   start_seconds: float = 0.0) -> threading.Thread:
        if self._thread is not None and self._thread.is_alive():
            raise RuntimeError("playback is already running")
        self._thread = threading.Thread(
            target=self.play,
            kwargs={"max_seconds": max_seconds, "speed": speed,
                    "start_seconds": start_seconds},
            name="organ-midi-player",
            daemon=True,
        )
        self._thread.start()
        return self._thread

    def join(self, timeout: float | None = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    def _note_gain(self, channel: int) -> float:
        return (self.voice_gain * self._channel_volume[channel] / 127.0
                * self._expression[channel] / 127.0)

    def _note_on(self, event: MidiEvent) -> None:
        already_sounding = (self._pressed[event.channel][event.note] > 0
                            or event.note in self._deferred[event.channel])
        self._deferred[event.channel].discard(event.note)
        self._pressed[event.channel][event.note] += 1
        if already_sounding:
            return
        try:
            self.organ.note_on(
                event.note,
                channel=event.channel,
                stop=self.stop_name,
                gain=self._note_gain(event.channel),
                velocity=event.velocity / 127.0,
            )
        except Exception as error:
            self.statistics.note_on_errors += 1
            print(f"NOTE-ON ERROR ch={event.channel} note={event.note}: {error}",
                  flush=True)

    def _release_note(self, channel: int, note: int, *, control: bool = False) -> None:
        try:
            released = self.organ.note_off(note, channel=channel)
            if not released:
                if control:
                    self.statistics.control_errors += 1
                else:
                    self.statistics.note_off_errors += 1
        except Exception as error:
            if control:
                self.statistics.control_errors += 1
            else:
                self.statistics.note_off_errors += 1
            print(f"NOTE-OFF ERROR ch={channel} note={note}: {error}", flush=True)

    def _note_off(self, event: MidiEvent) -> None:
        pressed = self._pressed[event.channel]
        if pressed[event.note] > 1:
            pressed[event.note] -= 1
            return
        if pressed[event.note] == 1:
            del pressed[event.note]
        if self._sustain[event.channel]:
            self._deferred[event.channel].add(event.note)
        else:
            self._release_note(event.channel, event.note)

    def _flush_sustain(self, channel: int) -> None:
        for note in tuple(self._deferred[channel]):
            if self._pressed[channel][note] == 0:
                self._release_note(channel, note, control=True)
                self._deferred[channel].discard(note)

    def _all_notes_off_channel(self, channel: int) -> None:
        notes = set(self._pressed[channel]) | self._deferred[channel]
        for note in tuple(notes):
            self._release_note(channel, note, control=True)
        self._pressed[channel].clear()
        self._deferred[channel].clear()

    def _control_change(self, event: MidiEvent) -> None:
        channel, control, value = event.channel, event.control, event.value
        if control == 64:  # Damper/sustain pedal.
            was_down = self._sustain[channel]
            self._sustain[channel] = value >= 64
            if was_down and not self._sustain[channel]:
                self._flush_sustain(channel)
        elif control == 7:
            self._channel_volume[channel] = value
        elif control == 11:
            self._expression[channel] = value
        elif control in (120, 123):  # All sound off / all notes off.
            self._all_notes_off_channel(channel)
        elif control == 121:  # Reset all controllers.
            self._channel_volume[channel] = 127
            self._expression[channel] = 127
            self._sustain[channel] = False
            self._flush_sustain(channel)
        else:
            self.statistics.ignored_controls += 1

    def _dispatch(self, event: MidiEvent) -> None:
        if event.kind == "note_on":
            self._note_on(event)
        elif event.kind == "note_off":
            self._note_off(event)
        elif event.kind == "control_change":
            self._control_change(event)

    def _clip_status(self) -> str:
        clipped = self.organ.clip_detected()
        if clipped is None:
            return "n/a"
        if clipped:
            if not self._clip_seen:
                self.statistics.clip_reports += 1
                self._clip_seen = True
            return "YES"
        return "no"

    def _print_statistics(self, elapsed: float) -> None:
        current = self.organ.allocated_voice_count
        self.statistics.peak_polyphony = max(self.statistics.peak_polyphony, current)
        print(
            f"t={elapsed:8.2f}s polyphony={current:3d} "
            f"peak={self.statistics.peak_polyphony:3d} "
            f"stolen={self.organ.stolen_voice_count:4d} "
            f"on_err={self.statistics.note_on_errors:3d} "
            f"off_err={self.statistics.note_off_errors:3d} "
            f"ctl_err={self.statistics.control_errors:3d} "
            f"clip={self._clip_status()}",
            flush=True,
        )

    def _prime_seek(self, score_start: float) -> int:
        """Reconstruct MIDI state immediately before a non-zero start time."""
        if score_start <= 0.0:
            return 0

        velocities: dict[tuple[int, int], int] = {}
        for event in self.prepared.events:
            if event.timestamp >= score_start:
                break
            channel = event.channel
            if event.kind == "note_on":
                self._deferred[channel].discard(event.note)
                self._pressed[channel][event.note] += 1
                velocities[(channel, event.note)] = event.velocity
            elif event.kind == "note_off":
                pressed = self._pressed[channel]
                if pressed[event.note] > 1:
                    pressed[event.note] -= 1
                elif pressed[event.note] == 1:
                    del pressed[event.note]
                    if self._sustain[channel]:
                        self._deferred[channel].add(event.note)
                    else:
                        velocities.pop((channel, event.note), None)
            elif event.kind == "control_change":
                control, value = event.control, event.value
                if control == 64:
                    was_down = self._sustain[channel]
                    self._sustain[channel] = value >= 64
                    if was_down and not self._sustain[channel]:
                        for note in tuple(self._deferred[channel]):
                            if self._pressed[channel][note] == 0:
                                self._deferred[channel].discard(note)
                                velocities.pop((channel, note), None)
                elif control == 7:
                    self._channel_volume[channel] = value
                elif control == 11:
                    self._expression[channel] = value
                elif control in (120, 123):
                    self._pressed[channel].clear()
                    self._deferred[channel].clear()
                    for key in tuple(velocities):
                        if key[0] == channel:
                            del velocities[key]
                elif control == 121:
                    self._channel_volume[channel] = 127
                    self._expression[channel] = 127
                    self._sustain[channel] = False
                    for note in tuple(self._deferred[channel]):
                        self._deferred[channel].discard(note)
                        velocities.pop((channel, note), None)

        sounding: list[tuple[int, int, int]] = []
        for channel in range(16):
            notes = set(self._pressed[channel]) | self._deferred[channel]
            for note in notes:
                sounding.append(
                    (channel, note, velocities.get((channel, note), 127))
                )

        for channel, note, velocity in sounding:
            try:
                self.organ.note_on(
                    note,
                    channel=channel,
                    stop=self.stop_name,
                    gain=self._note_gain(channel),
                    velocity=velocity / 127.0,
                )
            except Exception as error:
                self.statistics.note_on_errors += 1
                print(f"SEEK NOTE-ON ERROR ch={channel} note={note}: {error}",
                      flush=True)
        return len(sounding)

    def play(self, *, max_seconds: float | None = None, speed: float = 1.0,
             start_seconds: float = 0.0) -> None:
        """Play synchronously; speed=1.0 preserves the MIDI file's real time."""
        if float(speed) <= 0.0:
            raise ValueError("speed must be positive")
        if max_seconds is not None and float(max_seconds) <= 0.0:
            raise ValueError("max_seconds must be positive")
        score_start = float(start_seconds)
        if not 0.0 <= score_start < self.prepared.duration:
            raise ValueError("start_seconds must be within the MIDI duration")

        self._stop_event.clear()
        self.statistics = PlaybackStatistics()
        self._clip_seen = False
        self._sustain = [False] * 16
        self._pressed = [Counter() for _ in range(16)]
        self._deferred = [set() for _ in range(16)]
        self._channel_volume = [127] * 16
        self._expression = [127] * 16
        self.organ.reset_performance_counters()
        primed_notes = self._prime_seek(score_start)
        start = time.monotonic()
        next_stats = start
        end_time = self.prepared.duration
        if max_seconds is not None:
            end_time = min(end_time, score_start + float(max_seconds))

        print(
            f"Playing {self.prepared.path.name}: {len(self.prepared.events)} events, "
            f"duration={self.prepared.duration:.2f}s, speed={speed:g}x, "
            f"start={score_start:.2f}s, score_peak={self.prepared.score_peak_polyphony}",
            flush=True,
        )
        if score_start > 0.0:
            print(f"Seek state: primed_notes={primed_notes}", flush=True)
        if not self.organ.clip_flag_available:
            print("Clip flag: unavailable in the immutable M3 register map", flush=True)

        try:
            for event in self.prepared.events:
                if event.timestamp < score_start:
                    continue
                if event.timestamp > end_time or self._stop_event.is_set():
                    break
                target = start + (event.timestamp - score_start) / speed
                while not self._stop_event.is_set():
                    now = time.monotonic()
                    if now >= next_stats:
                        self._print_statistics(score_start + (now - start) * speed)
                        next_stats += self.stats_interval
                    remaining = target - now
                    if remaining <= 0.0:
                        break
                    self._stop_event.wait(min(remaining, 0.020))
                if self._stop_event.is_set():
                    break
                lateness = max(0.0, time.monotonic() - target)
                if lateness > 0.010:
                    self.statistics.late_events += 1
                self.statistics.maximum_lateness = max(
                    self.statistics.maximum_lateness, lateness
                )
                self._dispatch(event)
                self.statistics.peak_polyphony = max(
                    self.statistics.peak_polyphony,
                    self.organ.allocated_voice_count,
                )

            cutoff_target = start + (end_time - score_start) / speed
            while (not self._stop_event.is_set()
                   and time.monotonic() < cutoff_target
                   and end_time < self.prepared.duration):
                now = time.monotonic()
                if now >= next_stats:
                    self._print_statistics(score_start + (now - start) * speed)
                    next_stats += self.stats_interval
                self._stop_event.wait(min(cutoff_target - now, 0.020))
        finally:
            self.organ.all_notes_off()
            elapsed = min((time.monotonic() - start) * speed,
                          end_time - score_start)
            self._print_statistics(score_start + elapsed)
            print(
                f"Playback stopped: steals={self.organ.stolen_voice_count}, "
                f"note_on_errors={self.statistics.note_on_errors}, "
                f"note_off_errors={self.statistics.note_off_errors}, "
                f"control_errors={self.statistics.control_errors}, "
                f"late_events={self.statistics.late_events}, "
                f"max_lateness_ms={self.statistics.maximum_lateness * 1000.0:.3f}",
                flush=True,
            )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("midi_file", type=Path)
    parser.add_argument("--bitfile", type=Path, default=Path("build/organ_m3.bit"))
    parser.add_argument("--overlay", choices=("m3", "m5", "m6", "m61"),
                        default="m3",
                        help="select M3, M5, M6, or click-free M6.1")
    parser.add_argument("--stop", choices=("sine", "principal", "flute", "reed"),
                        default="principal")
    parser.add_argument("--gain", type=float, default=0.03,
                        help="full-velocity gain per note (default: 0.03)")
    parser.add_argument("--codec-volume", type=int, default=39)
    parser.add_argument("--feedback", type=float, default=0.90,
                        help="M5 FDN feedback in [0, 0.99]")
    parser.add_argument("--wet", type=float, default=0.25,
                        help="M5/M6 FDN wet mix in [0, 1]")
    parser.add_argument("--damping-alpha", default="0.52,0.50,0.48,0.46",
                        help="four comma-separated M6 damping coefficients")
    parser.add_argument("--early-gains", default="0.60,0.40,0.30,0.20",
                        help="four comma-separated M6 early-reflection gains")
    parser.add_argument("--no-early-reflections", action="store_true",
                        help="bypass the M6 early-reflection branch")
    parser.add_argument("--stats-interval", type=float, default=1.0)
    parser.add_argument("--max-seconds", type=float,
                        help="play at most this many score seconds")
    parser.add_argument("--start-seconds", type=float, default=0.0,
                        help="begin playback at this score timestamp")
    parser.add_argument("--speed", type=float, default=1.0,
                        help="playback speed; 1.0 is real time")
    parser.add_argument("--dry-run", action="store_true",
                        help="parse and report the file without loading the FPGA")
    return parser


def main() -> None:
    args = _build_parser().parse_args()
    prepared = prepare_midi_file(args.midi_file)
    print(
        f"Prepared MIDI: tracks={prepared.tracks}, "
        f"ticks_per_beat={prepared.ticks_per_beat}, events={len(prepared.events)}, "
        f"duration={prepared.duration:.3f}s, tempo_changes={prepared.tempo_changes}, "
        f"score_peak_polyphony={prepared.score_peak_polyphony}, "
        f"ignored={prepared.ignored_messages}",
        flush=True,
    )
    if args.dry_run:
        return

    bitfile = args.bitfile.expanduser().resolve()
    if args.overlay in ("m6", "m61"):
        if args.overlay == "m61":
            from pynq_organ_m61 import OrganM61Overlay as OrganClass
        else:
            from pynq_organ_m6 import OrganM6Overlay as OrganClass
        try:
            alpha = tuple(float(item) for item in args.damping_alpha.split(","))
            early_gains = tuple(float(item) for item in args.early_gains.split(","))
        except ValueError as error:
            raise SystemExit(f"invalid M6 coefficient list: {error}") from error
        organ_context = OrganClass(
            bitfile, codec_volume=args.codec_volume, reverb_enabled=True,
            feedback=args.feedback, wet=args.wet, damping_alpha=alpha,
            early_reflections_enabled=not args.no_early_reflections,
            early_reflection_gains=early_gains,
        )
    elif args.overlay == "m5":
        from pynq_organ_m5 import OrganM5Overlay
        organ_context = OrganM5Overlay(
            bitfile, codec_volume=args.codec_volume, reverb_enabled=True,
            feedback=args.feedback, wet=args.wet,
        )
    else:
        from pynq_organ_m3 import OrganM3Overlay
        organ_context = OrganM3Overlay(bitfile, codec_volume=args.codec_volume)

    with organ_context as organ:
        player = OrganMidiPlayer(
            organ,
            prepared,
            stop=args.stop,
            voice_gain=args.gain,
            stats_interval=args.stats_interval,
        )
        try:
            player.play(max_seconds=args.max_seconds, speed=args.speed,
                        start_seconds=args.start_seconds)
        except KeyboardInterrupt:
            print("Keyboard interrupt: stopping playback", flush=True)
            player.stop()


if __name__ == "__main__":
    main()
