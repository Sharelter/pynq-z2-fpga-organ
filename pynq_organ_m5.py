"""PYNQ driver for the 128-voice organ with four-line FDN reverb."""

from __future__ import annotations

import math
import time

from pynq_organ_m3 import OrganM3Overlay, STOP_IDS


class OrganM5Overlay(OrganM3Overlay):
    IP_NAME = "organ_m5_i2s_0"
    EXPECTED_ID = 0x4F524735
    REVERB_CONTROL = 0x34
    REVERB_FEEDBACK = 0x38
    REVERB_WET = 0x3C
    REVERB_COMMIT = 0x40
    REVERB_STATUS = 0x44

    def __init__(self, bitfile, *, codec_volume: int = 39,
                 reverb_enabled: bool = True, feedback: float = 0.90,
                 wet: float = 0.25) -> None:
        super().__init__(bitfile, codec_volume=codec_volume)
        self.configure_reverb(enabled=reverb_enabled, feedback=feedback,
                              wet=wet, clear_clip=True)

    def _wait_reverb(self, timeout: float = 0.1) -> None:
        deadline = time.monotonic() + timeout
        while self.mmio.read(self.REVERB_STATUS) & 0x80000000:
            if time.monotonic() >= deadline:
                raise TimeoutError("PL reverb-config mailbox did not acknowledge")
            time.sleep(0.0001)

    def configure_reverb(self, *, enabled: bool, feedback: float,
                         wet: float, clear_clip: bool = False) -> None:
        feedback_value = float(feedback)
        wet_value = float(wet)
        if not math.isfinite(feedback_value) or not 0.0 <= feedback_value <= 0.99:
            raise ValueError("feedback must be finite and in [0, 0.99]")
        if not math.isfinite(wet_value) or not 0.0 <= wet_value <= 1.0:
            raise ValueError("wet must be finite and in [0, 1]")
        self._wait_reverb()
        self.mmio.write(self.REVERB_CONTROL,
                        int(bool(enabled)) | (int(bool(clear_clip)) << 1))
        self.mmio.write(self.REVERB_FEEDBACK, round(feedback_value * 32767.0))
        self.mmio.write(self.REVERB_WET, round(wet_value * 32767.0))
        self.mmio.write(self.REVERB_COMMIT, 1)
        self._wait_reverb()

    @property
    def clip_flag_available(self) -> bool:
        return True

    def clip_detected(self) -> bool:
        return bool(self.mmio.read(self.REVERB_STATUS) & 1)

    def clear_clip(self) -> None:
        enabled = bool(self.mmio.read(self.REVERB_CONTROL) & 1)
        feedback = (self.mmio.read(self.REVERB_FEEDBACK) & 0xFFFF) / 32767.0
        wet = (self.mmio.read(self.REVERB_WET) & 0xFFFF) / 32767.0
        self.configure_reverb(enabled=enabled, feedback=feedback, wet=wet,
                              clear_clip=True)


__all__ = ["OrganM5Overlay", "STOP_IDS"]
