"""PYNQ driver and note allocator for the 128-voice Milestone-3 organ."""

from __future__ import annotations

from collections.abc import Hashable
import fcntl
import math
import os
from pathlib import Path
import time

from pynq import Overlay
from pynq.lib.audio import AudioADAU1761


I2C_SLAVE = 0x0703
ADAU1761_ADDRESS = 0x3B
STOP_IDS = {"sine": 0, "principal": 1, "flute": 2, "reed": 3}


class OrganM3Overlay:
    IP_NAME = "organ_m3_i2s_0"
    GLOBAL_CONTROL = 0x00
    VOICE_SELECT = 0x04
    VOICE_CONTROL = 0x08
    VOICE_FTW = 0x0C
    VOICE_GAIN = 0x10
    COMMIT = 0x14
    STATUS = 0x18
    ID = 0x1C
    ACTIVE_MASKS = (0x20, 0x24, 0x28, 0x2C)
    VOICE_CAPACITY = 0x30
    EXPECTED_ID = 0x4F524733
    SAMPLE_RATE = 49_154_929.0 / 1024.0
    VOICES = 128

    def __init__(self, bitfile: str | os.PathLike[str], *, codec_volume: int = 39) -> None:
        if not isinstance(codec_volume, int) or not 0 <= codec_volume <= 62:
            raise ValueError("codec_volume must be an integer in [0, 62]")
        self.bitfile = str(Path(bitfile).expanduser().resolve())
        self.codec_volume = codec_volume
        self.overlay = Overlay(self.bitfile)
        self.ip = getattr(self.overlay, self.IP_NAME)
        self.mmio = self.ip.mmio
        if self.mmio.read(self.ID) != self.EXPECTED_ID:
            raise RuntimeError("Milestone-3 design ID mismatch")
        if self.mmio.read(self.VOICE_CAPACITY) != self.VOICES:
            raise RuntimeError("Milestone-3 voice-capacity mismatch")

        self._state = [dict(frequency=440.0, stop=0, gain=0.0, gate=False)
                       for _ in range(self.VOICES)]
        self._key_to_voice: dict[Hashable, int] = {}
        self._voice_keys: list[Hashable | None] = [None] * self.VOICES
        self._voice_age = [-1] * self.VOICES
        self._sequence = 0
        self._stolen_voice_count = 0

        self.mmio.write(self.GLOBAL_CONTROL, 0)
        time.sleep(0.050)
        self.codec = AudioADAU1761(self.overlay.ip_dict[self.IP_NAME])
        self.codec.configure(sample_rate=48_000, iic_index=1,
                             uio_name="audio-codec-ctrl")
        self.codec.deselect_inputs()
        self._enable_codec_playback(codec_volume)
        self.mmio.write(self.GLOBAL_CONTROL, 1)

    def _codec_writes(self, writes: tuple[tuple[int, int], ...]) -> None:
        fd = os.open("/dev/i2c-1", os.O_RDWR)
        try:
            fcntl.ioctl(fd, I2C_SLAVE, ADAU1761_ADDRESS)
            for register, value in writes:
                if os.write(fd, bytes((register >> 8, register & 0xFF, value))) != 3:
                    raise OSError(f"short codec write at 0x{register:04x}")
        finally:
            os.close(fd)

    def _enable_codec_playback(self, volume: int) -> None:
        value = (volume << 2) | 3
        self._codec_writes(((0x401C, 0x21), (0x401E, 0x41),
                            (0x4023, value), (0x4024, value)))

    def mute_codec(self) -> None:
        self._codec_writes(((0x401C, 0x01), (0x401E, 0x01)))

    def _wait_mailbox(self, timeout: float = 0.1) -> None:
        deadline = time.monotonic() + timeout
        while self.mmio.read(self.STATUS) & 0x80000000:
            if time.monotonic() >= deadline:
                raise TimeoutError("PL voice-command mailbox did not acknowledge")
            time.sleep(0.0001)

    @classmethod
    def _ftw(cls, frequency_hz: float) -> int:
        frequency = float(frequency_hz)
        if not math.isfinite(frequency) or not 0.0 < frequency < cls.SAMPLE_RATE / 2:
            raise ValueError("frequency must be finite and below Nyquist")
        return round(frequency * (1 << 32) / cls.SAMPLE_RATE) & 0xFFFFFFFF

    @staticmethod
    def _stop_id(stop: str | int) -> int:
        if isinstance(stop, str):
            try:
                return STOP_IDS[stop.lower()]
            except KeyError as error:
                raise ValueError(f"stop must be one of {tuple(STOP_IDS)}") from error
        if isinstance(stop, int) and 0 <= stop < 4:
            return stop
        raise ValueError("stop ID must be in [0, 3]")

    @staticmethod
    def midi_frequency(note: int, *, a4_hz: float = 440.0) -> float:
        if not isinstance(note, int) or not 0 <= note <= 127:
            raise ValueError("MIDI note must be an integer in [0, 127]")
        if not math.isfinite(float(a4_hz)) or float(a4_hz) <= 0.0:
            raise ValueError("a4_hz must be finite and positive")
        return float(a4_hz) * 2.0 ** ((note - 69) / 12.0)

    def _program_voice(self, voice: int, frequency_hz: float, *, stop: str | int,
                       gain: float, gate: bool, retrigger: bool = False) -> None:
        if not isinstance(voice, int) or not 0 <= voice < self.VOICES:
            raise IndexError("voice must be in [0, 127]")
        level = float(gain)
        if not math.isfinite(level) or not 0.0 <= level <= 1.0:
            raise ValueError("gain must be finite and in [0, 1]")
        table = self._stop_id(stop)
        gain_q15 = round(level * 32767.0)
        self._wait_mailbox()
        self.mmio.write(self.VOICE_SELECT, voice)
        self.mmio.write(self.VOICE_CONTROL,
                        (table << 8) | (int(retrigger) << 1) | int(bool(gate)))
        self.mmio.write(self.VOICE_FTW, self._ftw(frequency_hz))
        self.mmio.write(self.VOICE_GAIN, gain_q15)
        self.mmio.write(self.COMMIT, 1)
        self._wait_mailbox()
        self._state[voice] = dict(frequency=float(frequency_hz), stop=table,
                                  gain=level, gate=bool(gate))

    def set_voice(self, voice: int, frequency_hz: float, *, stop: str | int,
                  gain: float, gate: bool, retrigger: bool = False) -> None:
        """Program a numbered PL voice directly, outside the note allocator."""
        if not isinstance(voice, int) or not 0 <= voice < self.VOICES:
            raise IndexError("voice must be in [0, 127]")
        old_key = self._voice_keys[voice]
        self._program_voice(voice, frequency_hz, stop=stop, gain=gain,
                            gate=gate, retrigger=retrigger)
        if old_key is not None:
            self._key_to_voice.pop(old_key, None)
            self._voice_keys[voice] = None
            self._voice_age[voice] = -1

    def _note_on_key(self, key: Hashable, frequency_hz: float, *,
                     stop: str | int, gain: float) -> int:
        try:
            hash(key)
        except TypeError as error:
            raise TypeError("note key must be hashable") from error

        existing = self._key_to_voice.get(key)
        stole_voice = False
        if existing is not None:
            voice = existing
        else:
            voice = self._find_free_voice()
            if voice is None:
                voice = min(range(self.VOICES), key=self._voice_age.__getitem__)
                stole_voice = True

        old_key = self._voice_keys[voice]
        self._program_voice(voice, frequency_hz, stop=stop, gain=gain,
                            gate=True, retrigger=True)
        if old_key is not None and old_key != key:
            self._key_to_voice.pop(old_key, None)
        self._key_to_voice[key] = voice
        self._voice_keys[voice] = key
        self._voice_age[voice] = self._sequence
        self._sequence += 1
        if stole_voice:
            self._stolen_voice_count += 1
        return voice

    def _find_free_voice(self) -> int | None:
        """Return a software-free voice; subclasses may exclude release tails."""
        try:
            return self._voice_keys.index(None)
        except ValueError:
            return None

    def note_on(self, note: int, *, channel: int = 0, stop: str | int = "principal",
                gain: float = 0.004, velocity: float = 1.0) -> int:
        """Start a MIDI note and return its allocated voice number."""
        if not isinstance(channel, int) or not 0 <= channel <= 15:
            raise ValueError("MIDI channel must be an integer in [0, 15]")
        velocity_value = float(velocity)
        if not math.isfinite(velocity_value) or not 0.0 <= velocity_value <= 1.0:
            raise ValueError("velocity must be finite and in [0, 1]")
        if velocity_value == 0.0:
            self.note_off(note, channel=channel)
            return -1
        frequency = self.midi_frequency(note)
        return self._note_on_key(("midi", channel, note), frequency,
                                 stop=stop, gain=float(gain) * velocity_value)

    def note_off(self, note: int, *, channel: int = 0) -> bool:
        """Release a MIDI note. Return False when it is no longer allocated."""
        self.midi_frequency(note)  # Validate the note consistently.
        if not isinstance(channel, int) or not 0 <= channel <= 15:
            raise ValueError("MIDI channel must be an integer in [0, 15]")
        key = ("midi", channel, note)
        return self._note_off_key(key)

    def note_on_hz(self, note_id: Hashable, frequency_hz: float, *,
                   stop: str | int = "principal", gain: float = 0.004) -> int:
        """Allocate a voice using an application key and explicit frequency."""
        return self._note_on_key(("hz", note_id), frequency_hz,
                                 stop=stop, gain=gain)

    def note_off_hz(self, note_id: Hashable) -> bool:
        return self._note_off_key(("hz", note_id))

    def _note_off_key(self, key: Hashable) -> bool:
        voice = self._key_to_voice.get(key)
        if voice is None:
            return False
        state = self._state[voice]
        self._program_voice(voice, state["frequency"], stop=state["stop"],
                            gain=state["gain"], gate=False)
        self._key_to_voice.pop(key, None)
        self._voice_keys[voice] = None
        self._voice_age[voice] = -1
        return True

    def all_notes_off(self) -> None:
        for voice, state in enumerate(self._state):
            if state["gate"]:
                self._program_voice(voice, state["frequency"], stop=state["stop"],
                                    gain=state["gain"], gate=False)
        self._key_to_voice.clear()
        self._voice_keys = [None] * self.VOICES
        self._voice_age = [-1] * self.VOICES

    def active_masks(self) -> tuple[int, int, int, int]:
        return tuple(self.mmio.read(offset) for offset in self.ACTIVE_MASKS)

    def active_count(self) -> int:
        return sum(word.bit_count() for word in self.active_masks())

    @property
    def allocated_voice_count(self) -> int:
        """Number of voices currently owned by the software allocator."""
        return len(self._key_to_voice)

    @property
    def stolen_voice_count(self) -> int:
        """Cumulative allocator steals since construction or counter reset."""
        return self._stolen_voice_count

    def reset_performance_counters(self) -> None:
        self._stolen_voice_count = 0

    @property
    def clip_flag_available(self) -> bool:
        """M3 has no clip-status register; retained for player feature checks."""
        return False

    def clip_detected(self) -> None:
        """Return None because the immutable M3 bitstream exposes no clip flag."""
        return None

    def close(self) -> None:
        self.mmio.write(self.GLOBAL_CONTROL, 0)
        self.mute_codec()

    def __enter__(self) -> "OrganM3Overlay":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


__all__ = ["OrganM3Overlay", "STOP_IDS"]
