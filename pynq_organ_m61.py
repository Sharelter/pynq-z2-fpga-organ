"""PYNQ driver for the M6.1 click-free envelope organ overlay."""

from __future__ import annotations

from pynq_organ_m6 import OrganM6Overlay, STOP_IDS


class OrganM61Overlay(OrganM6Overlay):
    IP_NAME = "organ_m61_i2s_0"
    EXPECTED_ID = 0x4F523631  # "OR61"

    def _find_free_voice(self) -> int | None:
        """Do not reuse a hardware voice while its release envelope is active."""
        masks = self.active_masks()
        for voice, key in enumerate(self._voice_keys):
            if key is None and not (masks[voice >> 5] & (1 << (voice & 31))):
                return voice
        # All software-free voices are releasing. Prefer the oldest release
        # rather than stealing a currently held software note.
        for voice, key in enumerate(self._voice_keys):
            if key is None:
                return voice
        return None


__all__ = ["OrganM61Overlay", "STOP_IDS"]
