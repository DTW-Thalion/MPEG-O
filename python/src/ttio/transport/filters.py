"""Query filters for selective-access streaming (v0.10 M68)."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .packets import AccessUnit


@dataclass(frozen=True, slots=True)
class AUFilter:
    """Filter predicate evaluated against an :class:`AccessUnit`.

    All fields are optional; an empty filter accepts every AU. See
    ``docs/transport-spec.md`` §7.

    The filter is applied BEFORE an AU is serialized to the wire, so
    filtered streams consume no bandwidth for non-matching spectra.
    """

    rt_min: float | None = None
    rt_max: float | None = None
    ms_level: int | None = None
    precursor_mz_min: float | None = None
    precursor_mz_max: float | None = None
    polarity: int | None = None  # wire polarity: 0=pos, 1=neg, 2=unknown
    dataset_id: int | None = None
    max_au: int | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> "AUFilter":
        if not data:
            return cls()
        return cls(
            rt_min=_f(data.get("rt_min")),
            rt_max=_f(data.get("rt_max")),
            ms_level=_i(data.get("ms_level")),
            precursor_mz_min=_f(data.get("precursor_mz_min")),
            precursor_mz_max=_f(data.get("precursor_mz_max")),
            polarity=_i(data.get("polarity")),
            dataset_id=_i(data.get("dataset_id")),
            max_au=_i(data.get("max_au")),
        )

    def matches(self, au: AccessUnit, dataset_id: int) -> bool:
        if self.dataset_id is not None and dataset_id != self.dataset_id:
            return False
        if self.rt_min is not None and au.retention_time < self.rt_min:
            return False
        if self.rt_max is not None and au.retention_time > self.rt_max:
            return False
        if self.ms_level is not None and au.ms_level != self.ms_level:
            return False
        if self.precursor_mz_min is not None and au.precursor_mz < self.precursor_mz_min:
            return False
        if self.precursor_mz_max is not None and au.precursor_mz > self.precursor_mz_max:
            return False
        if self.polarity is not None and au.polarity != self.polarity:
            return False
        return True


def _f(v: Any) -> float | None:
    return None if v is None else float(v)


def _i(v: Any) -> int | None:
    return None if v is None else int(v)
