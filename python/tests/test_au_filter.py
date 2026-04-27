"""Unit tests for AUFilter (M68 spectral predicates + M89.3 genomic predicates)."""
from __future__ import annotations

import pytest

from ttio.transport.filters import AUFilter
from ttio.transport.packets import AccessUnit


def _make_ms_au(
    *, rt: float = 0.0, ms_level: int = 1, polarity: int = 0,
    precursor_mz: float = 0.0,
) -> AccessUnit:
    return AccessUnit(
        spectrum_class=0,
        acquisition_mode=0,
        ms_level=ms_level,
        polarity=polarity,
        retention_time=rt,
        precursor_mz=precursor_mz,
        precursor_charge=0,
        ion_mobility=0.0,
        base_peak_intensity=0.0,
        channels=[],
    )


def _make_genomic_au(
    *, chromosome: str = "chr1", position: int = 0,
    mapping_quality: int = 60, flags: int = 0,
) -> AccessUnit:
    return AccessUnit(
        spectrum_class=5,
        acquisition_mode=0, ms_level=0, polarity=2,
        retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
        ion_mobility=0.0, base_peak_intensity=0.0,
        channels=[],
        chromosome=chromosome,
        position=position,
        mapping_quality=mapping_quality,
        flags=flags,
    )


class TestSpectralPredicates:
    """Sanity-check the existing M68 spectral filter behaviour."""

    def test_empty_filter_accepts_all(self):
        f = AUFilter()
        assert f.matches(_make_ms_au(rt=1.5), dataset_id=1)
        assert f.matches(_make_genomic_au(), dataset_id=1)

    def test_rt_range(self):
        f = AUFilter(rt_min=1.0, rt_max=5.0)
        assert not f.matches(_make_ms_au(rt=0.5), dataset_id=1)
        assert f.matches(_make_ms_au(rt=3.0), dataset_id=1)
        assert not f.matches(_make_ms_au(rt=10.0), dataset_id=1)

    def test_ms_level(self):
        f = AUFilter(ms_level=2)
        assert not f.matches(_make_ms_au(ms_level=1), dataset_id=1)
        assert f.matches(_make_ms_au(ms_level=2), dataset_id=1)


class TestGenomicPredicates:
    """M89.3: chromosome + position_min/position_max predicates."""

    def test_chromosome_match(self):
        f = AUFilter(chromosome="chr1")
        assert f.matches(_make_genomic_au(chromosome="chr1"), dataset_id=1)
        assert not f.matches(
            _make_genomic_au(chromosome="chr2"), dataset_id=1
        )

    def test_position_range(self):
        f = AUFilter(position_min=100, position_max=200)
        assert not f.matches(_make_genomic_au(position=50), dataset_id=1)
        assert f.matches(_make_genomic_au(position=100), dataset_id=1)
        assert f.matches(_make_genomic_au(position=150), dataset_id=1)
        assert f.matches(_make_genomic_au(position=200), dataset_id=1)
        assert not f.matches(_make_genomic_au(position=201), dataset_id=1)

    def test_chromosome_and_position_combined(self):
        # Region query: chr3:1000-2000.
        f = AUFilter(chromosome="chr3", position_min=1000, position_max=2000)
        assert f.matches(
            _make_genomic_au(chromosome="chr3", position=1500), dataset_id=1
        )
        assert not f.matches(
            _make_genomic_au(chromosome="chr1", position=1500), dataset_id=1
        )
        assert not f.matches(
            _make_genomic_au(chromosome="chr3", position=500), dataset_id=1
        )

    def test_unmapped_reads_match_chromosome_star(self):
        # BAM convention: unmapped reads carry chromosome="*", position=-1.
        f = AUFilter(chromosome="*")
        assert f.matches(
            _make_genomic_au(chromosome="*", position=-1), dataset_id=1
        )

    def test_genomic_filter_excludes_ms_aus(self):
        # An MS AU (spectrum_class==0, chromosome="") should NOT match a
        # filter that requires chromosome="chr1". Different semantic
        # types should be cleanly separable in a multiplexed stream.
        f = AUFilter(chromosome="chr1")
        assert not f.matches(_make_ms_au(rt=1.0), dataset_id=1)

    def test_position_filter_excludes_ms_aus(self):
        # An MS AU has no notion of position; a position filter MUST
        # filter it out (semantic separation in multiplexed streams).
        f = AUFilter(position_min=100)
        assert not f.matches(_make_ms_au(rt=1.0), dataset_id=1)

    def test_empty_genomic_filter_accepts_all_genomic(self):
        # No genomic predicates set = match every genomic AU.
        f = AUFilter()
        assert f.matches(
            _make_genomic_au(chromosome="chrZ", position=999), dataset_id=1
        )

    def test_from_dict_parses_genomic_keys(self):
        f = AUFilter.from_dict({
            "chromosome": "chrX",
            "position_min": 10,
            "position_max": 20,
        })
        assert f.chromosome == "chrX"
        assert f.position_min == 10
        assert f.position_max == 20

    def test_from_dict_rejects_invalid_position_types(self):
        # AUFilter coerces ints; a bad string should raise.
        with pytest.raises((TypeError, ValueError)):
            AUFilter.from_dict({"position_min": "not-a-number"})
