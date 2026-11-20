"""PYNQ driver for the Milestone-1 DDS/I2S pipe-organ overlay."""

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


class OrganOverlay:
    """Load the overlay and control its one PL sine oscillator.

    The codec is configured with PYNQ's installed AudioADAU1761.configure()
    implementation. Four additional I2C writes enable the playback mixers and
    headphone outputs because configure() intentionally leaves them muted until
    the stock software-driven play() method is called.
    """

    CONTROL = 0x00
    FTW = 0x04
    STATUS = 0x08
    ID = 0x0C
    EXPECTED_ID = 0x4F524731
    PHASE_WIDTH = 32
    # Vivado 2026.1 realizes 49.154929 MHz; i2s_tx divides it by 1024.
    SAMPLE_RATE = 49_154_929.0 / 1024.0

    def __init__(
        self,
        bitfile: str | os.PathLike[str],
        *,
        ip_name: str = "organ_dds_i2s_0",
        codec_volume: int = 39,
        i2c_device: str = "/dev/i2c-1",
    ) -> None:
        self.bitfile = str(Path(bitfile).expanduser().resolve())
        self.ip_name = ip_name
        self.i2c_device = i2c_device
        self.codec_volume = self._validate_codec_volume(codec_volume)

        self.overlay = Overlay(self.bitfile)
        try:
            self.ip = getattr(self.overlay, self.ip_name)
            description = self.overlay.ip_dict[self.ip_name]
        except (AttributeError, KeyError) as error:
            raise RuntimeError(
                f"Overlay does not expose AXI IP {self.ip_name!r}; "
                f"available IP: {sorted(self.overlay.ip_dict)}"
            ) from error
        self.mmio = self.ip.mmio

        design_id = self.mmio.read(self.ID)
        if design_id != self.EXPECTED_ID:
            raise RuntimeError(
                f"Unexpected design ID 0x{design_id:08x}; "
                f"expected 0x{self.EXPECTED_ID:08x}"
            )

        # The overlay must be loaded first so its 10 MHz codec MCLK is active.
        self.disable()
        time.sleep(0.050)
        self.codec = AudioADAU1761(description)
        self.codec.configure(
            sample_rate=int(self.SAMPLE_RATE),
            iic_index=1,
            uio_name="audio-codec-ctrl",
        )
        self.codec.deselect_inputs()
        self._enable_codec_playback(self.codec_volume)

    @staticmethod
    def _validate_codec_volume(volume: int) -> int:
        if not isinstance(volume, int) or not 0 <= volume <= 62:
            raise ValueError("codec_volume must be an integer in [0, 62]")
        return volume

    def _write_codec_registers(self, writes: tuple[tuple[int, int], ...]) -> None:
        descriptor = os.open(self.i2c_device, os.O_RDWR)
        try:
            fcntl.ioctl(descriptor, I2C_SLAVE, ADAU1761_ADDRESS)
            for register, value in writes:
                payload = bytes((register >> 8, register & 0xFF, value & 0xFF))
                written = os.write(descriptor, payload)
                if written != len(payload):
                    raise OSError(
                        f"short I2C write to ADAU1761 register 0x{register:04x}"
                    )
        finally:
            os.close(descriptor)

    def _enable_codec_playback(self, volume: int) -> None:
        volume_register = (volume << 2) | 0x03
        self._write_codec_registers(
            (
                (0x401C, 0x21),  # DAC left to playback mixer 3
                (0x401E, 0x41),  # DAC right to playback mixer 4
                (0x4023, volume_register),
                (0x4024, volume_register),
            )
        )

    def set_codec_volume(self, volume: int) -> None:
        """Set HP output level; 39=-18 dB, 43=-14 dB, and 57=0 dB."""
        self.codec_volume = self._validate_codec_volume(volume)
        self._enable_codec_playback(self.codec_volume)

    def mute_codec(self) -> None:
        """Mute both playback mixers at the codec."""
        self._write_codec_registers(((0x401C, 0x01), (0x401E, 0x01)))

    def unmute_codec(self) -> None:
        self._enable_codec_playback(self.codec_volume)

    def set_frequency(self, frequency_hz: float) -> int:
        """Set oscillator frequency and return the written 32-bit FTW."""
        frequency = float(frequency_hz)
        if not math.isfinite(frequency) or not 0.0 < frequency < self.SAMPLE_RATE / 2:
            raise ValueError(
                f"frequency_hz must be finite and in (0, {self.SAMPLE_RATE / 2})"
            )
        ftw = round(frequency * (1 << self.PHASE_WIDTH) / self.SAMPLE_RATE)
        ftw &= 0xFFFFFFFF
        self.mmio.write(self.FTW, ftw)
        if self.mmio.read(self.FTW) != ftw:
            raise RuntimeError("FTW AXI readback mismatch")
        return ftw

    def frequency(self) -> float:
        ftw = self.mmio.read(self.FTW)
        return ftw * self.SAMPLE_RATE / (1 << self.PHASE_WIDTH)

    def enable(self) -> None:
        self.mmio.write(self.CONTROL, 1)

    def disable(self) -> None:
        self.mmio.write(self.CONTROL, 0)

    def enabled(self) -> bool:
        return bool(self.mmio.read(self.STATUS) & 1)

    def diagnostics(self) -> dict[str, int | float | bool | str]:
        return {
            "bitfile": self.bitfile,
            "design_id": self.mmio.read(self.ID),
            "ftw": self.mmio.read(self.FTW),
            "frequency_hz": self.frequency(),
            "enabled": self.enabled(),
            "codec_volume": self.codec_volume,
            "sample_rate_hz": self.SAMPLE_RATE,
        }

    def close(self) -> None:
        self.disable()
        self.mute_codec()

    def __enter__(self) -> "OrganOverlay":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


__all__ = ["OrganOverlay"]
