"""``Query`` — compressed-domain query builder over ``SpectrumIndex``."""
from __future__ import annotations

from dataclasses import dataclass, field

from .acquisition_run import SpectrumIndex
from .enums import Polarity
from .value_range import ValueRange


@dataclass(slots=True)
class Query:
    """Compressed-domain query against a :class:`SpectrumIndex`.

    Predicates are combined with AND (intersection). The query
    operates entirely on the in-memory index arrays — signal-channel
    datasets are never opened, so a 10k-spectrum scan completes in
    under a millisecond and never touches the encrypted intensity
    stream.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOQuery`` · Java:
    ``com.dtwthalion.ttio.Query``.
    """

    index: SpectrumIndex
    _rt_range: ValueRange | None = field(default=None, repr=False)
    _ms_level: int | None = field(default=None, repr=False)
    _polarity: Polarity | None = field(default=None, repr=False)
    _precursor_mz_range: ValueRange | None = field(default=None, repr=False)
    _base_peak_threshold: float | None = field(default=None, repr=False)

    @classmethod
    def on_index(cls, index: SpectrumIndex) -> "Query":
        """Start a query on the given index."""
        return cls(index=index)

    def with_retention_time_range(self, value_range: ValueRange) -> "Query":
        self._rt_range = value_range
        return self

    def with_ms_level(self, level: int) -> "Query":
        self._ms_level = level
        return self

    def with_polarity(self, polarity: Polarity) -> "Query":
        self._polarity = polarity
        return self

    def with_precursor_mz_range(self, value_range: ValueRange) -> "Query":
        self._precursor_mz_range = value_range
        return self

    def with_base_peak_intensity_at_least(self, threshold: float) -> "Query":
        self._base_peak_threshold = threshold
        return self

    def matching_indices(self) -> list[int]:
        """Return the indices that match all predicates (AND)."""
        import numpy as np

        n = self.index.count
        mask = np.ones(n, dtype=bool)

        if self._rt_range is not None:
            rt = self.index.retention_times
            mask &= (rt >= self._rt_range.minimum) & (rt <= self._rt_range.maximum)

        if self._ms_level is not None:
            mask &= self.index.ms_levels == self._ms_level

        if self._polarity is not None:
            mask &= self.index.polarities == int(self._polarity)

        if self._precursor_mz_range is not None:
            pmz = self.index.precursor_mzs
            mask &= ((pmz >= self._precursor_mz_range.minimum) &
                     (pmz <= self._precursor_mz_range.maximum))

        if self._base_peak_threshold is not None:
            mask &= self.index.base_peak_intensities >= self._base_peak_threshold

        return np.where(mask)[0].tolist()
