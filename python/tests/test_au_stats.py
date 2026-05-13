"""Unit tests for AUStats (per-AU summary stats)."""
from __future__ import annotations

import json

from ttio.transport.packets import AccessUnit, ChannelData
from ttio.transport.stats import AUStats


def _ms_au() -> AccessUnit:
    return AccessUnit(
        spectrum_class=0,
        acquisition_mode=0,
        ms_level=2,
        polarity=1,
        retention_time=12.5,
        precursor_mz=400.5,
        precursor_charge=2,
        ion_mobility=0.0,
        base_peak_intensity=98765.0,
        channels=[
            ChannelData(name="mz", precision=3, compression=0,
                        n_elements=1024, data=b"\x00" * 4096),
            ChannelData(name="intensity", precision=3, compression=0,
                        n_elements=1024, data=b"\x00" * 4096),
        ],
    )


def _genomic_au() -> AccessUnit:
    return AccessUnit(
        spectrum_class=5,
        acquisition_mode=0,
        ms_level=0,
        polarity=2,
        retention_time=0.0,
        precursor_mz=0.0,
        precursor_charge=0,
        ion_mobility=0.0,
        base_peak_intensity=0.0,
        channels=[
            ChannelData(name="seq", precision=0, compression=0,
                        n_elements=150, data=b"A" * 150),
            ChannelData(name="qual", precision=0, compression=0,
                        n_elements=150, data=b"!" * 150),
            ChannelData(name="cigar", precision=0, compression=0,
                        n_elements=10, data=b"\x00" * 12),
        ],
        chromosome="chr3",
        position=12_345_678,
        mapping_quality=60,
        flags=99,
    )


def _image_au() -> AccessUnit:
    return AccessUnit(
        spectrum_class=4,
        acquisition_mode=0,
        ms_level=1,
        polarity=0,
        retention_time=0.0,
        precursor_mz=0.0,
        precursor_charge=0,
        ion_mobility=0.0,
        base_peak_intensity=0.0,
        channels=[
            ChannelData(name="mz", precision=3, compression=0,
                        n_elements=512, data=b"\x00" * 2048),
        ],
        pixel_x=7, pixel_y=11, pixel_z=13,
    )


def test_ms_stats_fields():
    s = AUStats.from_access_unit(_ms_au(), au_sequence=42)
    assert s.au_sequence == 42
    assert s.spectrum_class == 0
    assert s.ms_level == 2
    assert s.polarity == 1
    assert s.retention_time == 12.5
    assert s.precursor_mz == 400.5
    assert s.precursor_charge == 2
    assert s.base_peak_intensity == 98765.0
    assert s.channel_count == 2
    assert s.total_elements == 2048
    assert s.payload_bytes == 8192
    # MS AU: genomic + image fields are zero / None.
    assert s.chromosome is None
    assert s.position == 0
    assert s.mapping_quality == 0
    assert s.flags == 0
    assert s.pixel_x == s.pixel_y == s.pixel_z == 0


def test_genomic_stats_fields():
    s = AUStats.from_access_unit(_genomic_au(), au_sequence=7)
    assert s.spectrum_class == 5
    assert s.chromosome == "chr3"
    assert s.position == 12_345_678
    assert s.mapping_quality == 60
    assert s.flags == 99
    assert s.channel_count == 3
    assert s.total_elements == 310  # 150+150+10
    assert s.payload_bytes == 312   # 150+150+12


def test_image_stats_fields():
    s = AUStats.from_access_unit(_image_au(), au_sequence=3)
    assert s.spectrum_class == 4
    assert s.pixel_x == 7
    assert s.pixel_y == 11
    assert s.pixel_z == 13


def test_json_keys_sorted_and_compact():
    s = AUStats.from_access_unit(_ms_au(), au_sequence=42)
    j = s.json_string()
    # Compact: no spaces.
    assert " " not in j
    # Sorted: au_sequence < base_peak_intensity < channel_count ...
    parsed = json.loads(j)
    # Round-trip yields the same dict.
    assert parsed == s.to_dict()
    # Sorted check via observable string positions.
    assert j.index("au_sequence") < j.index("base_peak_intensity")
    assert j.index("base_peak_intensity") < j.index("channel_count")


def test_json_genomic_only_includes_genomic_keys():
    s = AUStats.from_access_unit(_genomic_au(), au_sequence=7)
    j = s.json_string()
    parsed = json.loads(j)
    assert "chromosome" in parsed
    assert "position" in parsed
    assert "mapping_quality" in parsed
    assert "flags" in parsed
    assert "pixel_x" not in parsed


def test_json_image_only_includes_image_keys():
    s = AUStats.from_access_unit(_image_au(), au_sequence=3)
    j = s.json_string()
    parsed = json.loads(j)
    assert "pixel_x" in parsed
    assert "pixel_y" in parsed
    assert "pixel_z" in parsed
    assert "chromosome" not in parsed


def test_json_ms_excludes_genomic_and_image_keys():
    s = AUStats.from_access_unit(_ms_au(), au_sequence=1)
    parsed = json.loads(s.json_string())
    for k in ("chromosome", "position", "mapping_quality", "flags",
              "pixel_x", "pixel_y", "pixel_z"):
        assert k not in parsed


def test_json_string_for_shortcut():
    au = _ms_au()
    a = AUStats.from_access_unit(au, au_sequence=99).json_string()
    b = AUStats.json_string_for(au, au_sequence=99)
    assert a == b
