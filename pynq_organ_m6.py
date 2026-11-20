"""PYNQ driver for the M6 128-voice organ and acoustically tuned FDN."""

from __future__ import annotations

from collections.abc import Iterable
import math
import os
import time

from pynq_organ_m3 import OrganM3Overlay, STOP_IDS


class OrganM6Overlay(OrganM3Overlay):
    """M3-compatible voice allocator with M6 reverb parameter control."""

    IP_NAME = "organ_m6_i2s_0"
    EXPECTED_ID = 0x4F524736

    REVERB_CONTROL = 0x34
    REVERB_FEEDBACK = 0x38
    REVERB_WET = 0x3C
    REVERB_COMMIT = 0x40
    REVERB_STATUS = 0x44
    DAMPING_ALPHA_01 = 0x48
    DAMPING_ALPHA_23 = 0x4C
    EARLY_GAIN_01 = 0x50
    EARLY_GAIN_23 = 0x54

    DEFAULT_ALPHA = (0.52, 0.50, 0.48, 0.46)
    DEFAULT_EARLY_GAINS = (0.60, 0.40, 0.30, 0.20)

    def __init__(
        self,
        bitfile: str | os.PathLike[str],
        *,
        codec_volume: int = 39,
        reverb_enabled: bool = True,
        feedback: float = 0.90,
        wet: float = 0.25,
        damping_alpha: float | Iterable[float] = DEFAULT_ALPHA,
        early_reflections_enabled: bool = True,
        early_reflection_gains: Iterable[float] = DEFAULT_EARLY_GAINS,
    ) -> None:
        super().__init__(bitfile, codec_volume=codec_volume)
        self.configure_acoustics(
            enabled=reverb_enabled,
            feedback=feedback,
            wet=wet,
            damping_alpha=damping_alpha,
            early_enabled=early_reflections_enabled,
            early_gains=early_reflection_gains,
            clear_clip=True,
        )

    @staticmethod
    def _validate_unit(value: float, name: str, upper: float = 1.0) -> float:
        result = float(value)
        if not math.isfinite(result) or not 0.0 <= result <= upper:
            raise ValueError(f"{name} must be finite and in [0, {upper:g}]")
        return result

    @classmethod
    def _validate_alpha(cls, value: float | Iterable[float]) -> tuple[float, ...]:
        if isinstance(value, (int, float)):
            values = (float(value),) * 4
        else:
            values = tuple(float(item) for item in value)
        if len(values) != 4:
            raise ValueError("damping_alpha must be one value or four values")
        if any(not math.isfinite(item) or not 0.1 <= item <= 0.9 for item in values):
            raise ValueError("each damping alpha must be finite and in [0.1, 0.9]")
        return values

    @classmethod
    def _validate_gains(cls, values: Iterable[float]) -> tuple[float, ...]:
        result = tuple(float(item) for item in values)
        if len(result) != 4:
            raise ValueError("early_reflection_gains must contain four values")
        for index, item in enumerate(result):
            cls._validate_unit(item, f"early_reflection_gains[{index}]")
        return result

    @staticmethod
    def _to_q15(value: float) -> int:
        return round(value * 32767.0)

    @staticmethod
    def _from_q15(value: int) -> float:
        return (value & 0xFFFF) / 32767.0

    @classmethod
    def _pack_pair(cls, first: float, second: float) -> int:
        return cls._to_q15(first) | (cls._to_q15(second) << 16)

    @classmethod
    def _unpack_pair(cls, word: int) -> tuple[float, float]:
        return cls._from_q15(word), cls._from_q15(word >> 16)

    def _wait_reverb(self, timeout: float = 0.1) -> None:
        deadline = time.monotonic() + timeout
        while self.mmio.read(self.REVERB_STATUS) & 0x80000000:
            if time.monotonic() >= deadline:
                raise TimeoutError("PL reverb-config mailbox did not acknowledge")
            time.sleep(0.0001)

    def configure_acoustics(
        self,
        *,
        enabled: bool,
        feedback: float,
        wet: float,
        damping_alpha: float | Iterable[float],
        early_enabled: bool,
        early_gains: Iterable[float],
        clear_clip: bool = False,
    ) -> None:
        """Validate, stage, and atomically transfer all reverb parameters."""
        feedback_value = self._validate_unit(feedback, "feedback", 0.99)
        wet_value = self._validate_unit(wet, "wet")
        alpha_values = self._validate_alpha(damping_alpha)
        gain_values = self._validate_gains(early_gains)
        control = (int(bool(enabled)) | (int(bool(clear_clip)) << 1)
                   | (int(bool(early_enabled)) << 2))

        self._wait_reverb()
        self.mmio.write(self.REVERB_CONTROL, control)
        self.mmio.write(self.REVERB_FEEDBACK, self._to_q15(feedback_value))
        self.mmio.write(self.REVERB_WET, self._to_q15(wet_value))
        self.mmio.write(self.DAMPING_ALPHA_01,
                        self._pack_pair(alpha_values[0], alpha_values[1]))
        self.mmio.write(self.DAMPING_ALPHA_23,
                        self._pack_pair(alpha_values[2], alpha_values[3]))
        self.mmio.write(self.EARLY_GAIN_01,
                        self._pack_pair(gain_values[0], gain_values[1]))
        self.mmio.write(self.EARLY_GAIN_23,
                        self._pack_pair(gain_values[2], gain_values[3]))
        self.mmio.write(self.REVERB_COMMIT, 1)
        self._wait_reverb()
        if clear_clip:
            # Clear is a mailbox pulse; leave staging low for the next update.
            self.mmio.write(self.REVERB_CONTROL, control & ~0x2)

    def _current_parameters(self) -> dict[str, object]:
        control = self.mmio.read(self.REVERB_CONTROL)
        return {
            "enabled": bool(control & 0x1),
            "feedback": self.get_feedback(),
            "wet": self.get_wet_mix(),
            "damping_alpha": self.get_damping_alpha(),
            "early_enabled": bool(control & 0x4),
            "early_gains": self.get_early_reflection_gains(),
        }

    def _update(self, **changes: object) -> None:
        parameters = self._current_parameters()
        parameters.update(changes)
        self.configure_acoustics(**parameters)

    def set_reverb_enabled(self, enabled: bool) -> None:
        self._update(enabled=bool(enabled))

    def get_reverb_enabled(self) -> bool:
        return bool(self.mmio.read(self.REVERB_CONTROL) & 0x1)

    def set_feedback(self, feedback: float) -> None:
        self._update(feedback=self._validate_unit(feedback, "feedback", 0.99))

    def get_feedback(self) -> float:
        return self._from_q15(self.mmio.read(self.REVERB_FEEDBACK))

    def set_wet_mix(self, wet: float) -> None:
        self._update(wet=self._validate_unit(wet, "wet"))

    def get_wet_mix(self) -> float:
        return self._from_q15(self.mmio.read(self.REVERB_WET))

    def set_damping_alpha(self, value: float | Iterable[float]) -> None:
        self._update(damping_alpha=self._validate_alpha(value))

    def get_damping_alpha(self) -> tuple[float, float, float, float]:
        return (*self._unpack_pair(self.mmio.read(self.DAMPING_ALPHA_01)),
                *self._unpack_pair(self.mmio.read(self.DAMPING_ALPHA_23)))

    def set_early_reflections_enabled(self, enabled: bool) -> None:
        self._update(early_enabled=bool(enabled))

    def get_early_reflections_enabled(self) -> bool:
        return bool(self.mmio.read(self.REVERB_CONTROL) & 0x4)

    def set_early_reflection_gains(self, gains: Iterable[float]) -> None:
        self._update(early_gains=self._validate_gains(gains))

    def get_early_reflection_gains(self) -> tuple[float, float, float, float]:
        return (*self._unpack_pair(self.mmio.read(self.EARLY_GAIN_01)),
                *self._unpack_pair(self.mmio.read(self.EARLY_GAIN_23)))

    # M5-compatible combined setter retained for existing control code.
    def configure_reverb(self, *, enabled: bool, feedback: float, wet: float,
                         clear_clip: bool = False) -> None:
        parameters = self._current_parameters()
        parameters.update(enabled=enabled, feedback=feedback, wet=wet)
        self.configure_acoustics(**parameters, clear_clip=clear_clip)

    @property
    def clip_flag_available(self) -> bool:
        return True

    def clip_detected(self) -> bool:
        return bool(self.mmio.read(self.REVERB_STATUS) & 0x1)

    def clear_clip(self) -> None:
        self.configure_acoustics(**self._current_parameters(), clear_clip=True)


__all__ = ["OrganM6Overlay", "STOP_IDS"]
