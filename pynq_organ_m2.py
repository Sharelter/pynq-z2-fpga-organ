"""PYNQ driver for the eight-voice Milestone-2 wavetable organ overlay."""

from __future__ import annotations

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


class OrganM2Overlay:
    GLOBAL_CONTROL = 0x00
    VOICE_SELECT = 0x04
    VOICE_CONTROL = 0x08
    VOICE_FTW = 0x0C
    VOICE_GAIN = 0x10
    COMMIT = 0x14
    STATUS = 0x18
    ID = 0x1C
    EXPECTED_ID = 0x4F524732
    SAMPLE_RATE = 49_154_929.0 / 1024.0
    VOICES = 8

    def __init__(self, bitfile: str | os.PathLike[str], *, codec_volume: int = 39) -> None:
        if not isinstance(codec_volume, int) or not 0 <= codec_volume <= 62:
            raise ValueError("codec_volume must be an integer in [0, 62]")
        self.bitfile = str(Path(bitfile).expanduser().resolve())
        self.codec_volume = codec_volume
        self.overlay = Overlay(self.bitfile)
        self.ip = getattr(self.overlay, "organ_m2_i2s_0")
        self.mmio = self.ip.mmio
        if self.mmio.read(self.ID) != self.EXPECTED_ID:
            raise RuntimeError("Milestone-2 design ID mismatch")
        self._state = [dict(frequency=440.0, stop=0, gain=0.0, gate=False)
                       for _ in range(self.VOICES)]
        self.mmio.write(self.GLOBAL_CONTROL, 0)
        time.sleep(0.050)
        self.codec = AudioADAU1761(self.overlay.ip_dict["organ_m2_i2s_0"])
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

    def set_voice(self, voice: int, frequency_hz: float, *, stop: str | int,
                  gain: float, gate: bool, retrigger: bool = False) -> None:
        if not isinstance(voice, int) or not 0 <= voice < self.VOICES:
            raise IndexError("voice must be in [0, 7]")
        if not 0.0 <= float(gain) <= 1.0:
            raise ValueError("gain must be in [0, 1]")
        table = self._stop_id(stop)
        gain_q15 = round(float(gain) * 32767.0)
        self._wait_mailbox()
        self.mmio.write(self.VOICE_SELECT, voice)
        self.mmio.write(self.VOICE_CONTROL,
                        (table << 8) | (int(retrigger) << 1) | int(bool(gate)))
        self.mmio.write(self.VOICE_FTW, self._ftw(frequency_hz))
        self.mmio.write(self.VOICE_GAIN, gain_q15)
        self.mmio.write(self.COMMIT, 1)
        self._wait_mailbox()
        self._state[voice] = dict(frequency=float(frequency_hz), stop=table,
                                  gain=float(gain), gate=bool(gate))

    def note_on(self, voice: int, frequency_hz: float, *,
                stop: str | int = "principal", gain: float = 0.10) -> None:
        self.set_voice(voice, frequency_hz, stop=stop, gain=gain,
                       gate=True, retrigger=True)

    def note_off(self, voice: int) -> None:
        if not isinstance(voice, int) or not 0 <= voice < self.VOICES:
            raise IndexError("voice must be in [0, 7]")
        state = self._state[voice]
        self.set_voice(voice, state["frequency"], stop=state["stop"],
                       gain=state["gain"], gate=False)

    def all_notes_off(self) -> None:
        for voice in range(self.VOICES):
            self.note_off(voice)

    def active_mask(self) -> int:
        return self.mmio.read(self.STATUS) & 0xFF

    def close(self) -> None:
        self.mmio.write(self.GLOBAL_CONTROL, 0)
        self.mute_codec()

    def __enter__(self) -> "OrganM2Overlay":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


__all__ = ["OrganM2Overlay", "STOP_IDS"]
