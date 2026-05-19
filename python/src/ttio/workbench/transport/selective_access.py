"""
ttio.workbench.transport.selective_access -- typed builder for the
download-handshake filter map.

The underlying handshake already validates filter keys against
`ALLOWED_DOWNLOAD_FILTER_KEYS` -- this builder narrows the API to
typed setters so a GUI consumer (W5.3 in tio-browser) cannot
accidentally produce a key the server will reject.

Cross-language equivalent: Java
`global.thalion.ttio.workbench.transport.SelectiveAccessFilter`.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

ALLOWED_POLARITIES = frozenset({"positive", "negative"})


class SelectiveAccessFilter:
    """Fluent builder for a download-handshake filter dict."""

    def __init__(self) -> None:
        self._filters: Dict[str, Any] = {}

    def ms_level(self, level: int) -> "SelectiveAccessFilter":
        if level < 1:
            raise ValueError(f"ms_level must be >= 1; got {level}")
        self._filters["ms_level"] = int(level)
        return self

    def polarity(self, value: Optional[str]) -> "SelectiveAccessFilter":
        if value is None:
            self._filters.pop("polarity", None)
            return self
        if value not in ALLOWED_POLARITIES:
            raise ValueError(
                f"polarity must be one of {sorted(ALLOWED_POLARITIES)}; "
                f"got {value!r}")
        self._filters["polarity"] = value
        return self

    def retention_time_min(self, seconds: float) -> "SelectiveAccessFilter":
        if seconds < 0:
            raise ValueError(
                f"retention_time_min must be >= 0; got {seconds}")
        self._filters["retention_time_min"] = float(seconds)
        return self

    def retention_time_max(self, seconds: float) -> "SelectiveAccessFilter":
        if seconds < 0:
            raise ValueError(
                f"retention_time_max must be >= 0; got {seconds}")
        self._filters["retention_time_max"] = float(seconds)
        return self

    def precursor_mz_min(self, mz: float) -> "SelectiveAccessFilter":
        if mz < 0:
            raise ValueError(
                f"precursor_mz_min must be >= 0; got {mz}")
        self._filters["precursor_mz_min"] = float(mz)
        return self

    def precursor_mz_max(self, mz: float) -> "SelectiveAccessFilter":
        if mz < 0:
            raise ValueError(
                f"precursor_mz_max must be >= 0; got {mz}")
        self._filters["precursor_mz_max"] = float(mz)
        return self

    def precursor_charge(self, charge: int) -> "SelectiveAccessFilter":
        self._filters["precursor_charge"] = int(charge)
        return self

    def max_au(self, n: int) -> "SelectiveAccessFilter":
        if n < 1:
            raise ValueError(f"max_au must be >= 1; got {n}")
        self._filters["max_au"] = int(n)
        return self

    def validate(self) -> "SelectiveAccessFilter":
        """Validate cross-key constraints (rt_max >= rt_min,
        mz_max >= mz_min). Per-key range checks are already enforced
        by the typed setters."""
        self._validate_range("retention_time_min", "retention_time_max")
        self._validate_range("precursor_mz_min", "precursor_mz_max")
        return self

    def _validate_range(self, min_key: str, max_key: str) -> None:
        if min_key in self._filters and max_key in self._filters:
            mn = self._filters[min_key]
            mx = self._filters[max_key]
            if mx < mn:
                raise RuntimeError(
                    f"{max_key} ({mx}) must be >= {min_key} ({mn})")

    def build(self) -> Dict[str, Any]:
        """Return a shallow copy of the accumulated filter dict."""
        return dict(self._filters)

    def is_empty(self) -> bool:
        return not self._filters

    def __len__(self) -> int:
        return len(self._filters)
