"""v0.11 M79 — Modality abstraction + genomic enumerations.

Purely additive groundwork for the genomic milestone series:

* ``Precision.UINT8`` round-trips through every storage provider.
* New :class:`Compression` values 4-8 (rANS / base-pack / quality-binned
  / name-tokenized) persist as HDF5 integer attributes.
* :class:`AcquisitionMode` gains ``GENOMIC_WGS = 7`` and
  ``GENOMIC_WES = 8``.
* Transport :class:`AccessUnit` accepts ``spectrum_class = 5``
  (GenomicRead) without crashing — the wire format is generic.
* Run groups carry an optional ``@modality`` UTF-8 attribute; absent
  attribute → ``"mass_spectrometry"`` for v0.10 backward-compat.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.acquisition_run import AcquisitionRun
from ttio.enums import AcquisitionMode, Compression, Precision
from ttio.providers import open_provider
from ttio.providers.hdf5 import Hdf5Provider
from ttio.providers.memory import MemoryProvider
from ttio.providers.sqlite import SqliteProvider
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport.packets import (
    SPECTRUM_CLASS_GENOMIC_READ,
    AccessUnit,
)


# ── UINT8 provider round-trip ────────────────────────────────────────


def _provider_url(provider: str, tmp_path: Path) -> str:
    if provider == "hdf5":
        return str(tmp_path / "m79.h5")
    if provider == "memory":
        return f"memory://m79-{provider}-{id(tmp_path)}"
    if provider == "sqlite":
        return str(tmp_path / "m79.tio.sqlite")
    if provider == "zarr":
        return f"zarr://{tmp_path / 'm79.zarr'}"
    raise ValueError(provider)


def _discard_memory(provider: str, url: str) -> None:
    if provider == "memory":
        MemoryProvider.discard_store(url)


@pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
def test_uint8_roundtrip(provider: str, tmp_path: Path) -> None:
    """1000-element UINT8 buffer round-trips byte-exactly."""
    if provider == "zarr":
        pytest.importorskip("zarr", minversion="3.0")

    url = _provider_url(provider, tmp_path)
    expected = np.arange(1000, dtype=np.uint8)  # 0..255 repeating

    try:
        with open_provider(url, provider=provider, mode="w") as p:
            ds = p.root_group().create_dataset(
                "bases", Precision.UINT8, length=len(expected))
            ds.write(expected)
            assert ds.precision == Precision.UINT8

        with open_provider(url, provider=provider, mode="r") as p:
            got = p.root_group().open_dataset("bases").read()
            assert got.dtype == np.uint8
            np.testing.assert_array_equal(got, expected)
    finally:
        _discard_memory(provider, url)


@pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
def test_uint8_partial_read(provider: str, tmp_path: Path) -> None:
    """Hyperslab read of UINT8 returns the requested window."""
    if provider == "zarr":
        pytest.importorskip("zarr", minversion="3.0")

    url = _provider_url(provider, tmp_path)
    expected = np.arange(1000, dtype=np.uint8)

    try:
        with open_provider(url, provider=provider, mode="w") as p:
            ds = p.root_group().create_dataset(
                "bases", Precision.UINT8, length=len(expected))
            ds.write(expected)

        with open_provider(url, provider=provider, mode="r") as p:
            got = p.root_group().open_dataset("bases").read(
                offset=500, count=100)
            np.testing.assert_array_equal(got, expected[500:600])
    finally:
        _discard_memory(provider, url)


# ── Compression enum persistence ─────────────────────────────────────


def test_compression_enum_values() -> None:
    """All compression IDs in v1.0. On-disk integers — must not drift.
    Slots 8 (NAME_TOKENIZED v1), 9 (REF_DIFF v1), and 10
    (FQZCOMP_NX16 v1) are intentionally absent — all three legacy v1
    codecs were removed in the v1.0 reset (Phases 2c/2d). Their v2
    successors live at 13/14/15."""
    # M79 (v0.11) — base codec set
    assert Compression.RANS_ORDER0.value == 4
    assert Compression.RANS_ORDER1.value == 5
    assert Compression.BASE_PACK.value == 6
    assert Compression.QUALITY_BINNED.value == 7
    # 8/9/10 reserved (v1 codecs removed in v1.0 reset)
    assert Compression.DELTA_RANS_ORDER0.value == 11
    assert Compression.FQZCOMP_NX16_Z.value == 12
    # v1.7+ #11 channels
    assert Compression.MATE_INLINE_V2.value == 13      # v1.7 ch1
    assert Compression.REF_DIFF_V2.value == 14         # v1.8 ch2
    assert Compression.NAME_TOKENIZED_V2.value == 15   # v1.9 ch3
    # IDs 8, 9, 10 must remain unmapped
    import pytest as _pytest
    for unmapped in (8, 9, 10):
        with _pytest.raises(ValueError):
            Compression(unmapped)


@pytest.mark.parametrize("codec", [
    Compression.RANS_ORDER0,
    Compression.RANS_ORDER1,
    Compression.BASE_PACK,
    Compression.QUALITY_BINNED,
    Compression.DELTA_RANS_ORDER0,
    Compression.FQZCOMP_NX16_Z,
    Compression.MATE_INLINE_V2,
    Compression.REF_DIFF_V2,
    Compression.NAME_TOKENIZED_V2,
])
def test_compression_enum_persists_as_attribute(
        codec: Compression, tmp_path: Path) -> None:
    """Each new codec ID round-trips as an HDF5 integer attribute."""
    path = str(tmp_path / "codec.h5")
    with Hdf5Provider.open(path, mode="w") as p:
        p.root_group().set_attribute("codec_id", int(codec.value))

    with Hdf5Provider.open(path, mode="r") as p:
        raw = p.root_group().get_attribute("codec_id")
        assert int(raw) == codec.value
        assert Compression(int(raw)) is codec


# ── AcquisitionMode genomic values ──────────────────────────────────


def test_acquisition_mode_genomic_values() -> None:
    """Stable wire integers for genomic acquisition modes."""
    assert AcquisitionMode.GENOMIC_WGS.value == 7
    assert AcquisitionMode.GENOMIC_WES.value == 8


# ── Transport spectrum_class = 5 ────────────────────────────────────


def test_access_unit_spectrum_class_genomic_read_roundtrip() -> None:
    """Codec must serialise + deserialise spectrum_class=5 without
    crashing. Genomic AUs reuse the spectral prefix with zeroed
    spectral fields — proper genomic prefix arrives in M82."""
    au = AccessUnit(
        spectrum_class=SPECTRUM_CLASS_GENOMIC_READ,
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        ms_level=0,
        polarity=2,  # unknown
        retention_time=0.0,
        precursor_mz=0.0,
        precursor_charge=0,
        ion_mobility=0.0,
        base_peak_intensity=0.0,
        channels=[],
    )

    blob = au.to_bytes()
    decoded = AccessUnit.from_bytes(blob)

    assert decoded.spectrum_class == SPECTRUM_CLASS_GENOMIC_READ == 5
    assert decoded.acquisition_mode == int(AcquisitionMode.GENOMIC_WGS)
    assert decoded.channels == []
    assert decoded.pixel_x == 0  # MSImagePixel extension MUST NOT activate


# ── Modality attribute (read-side; write-side lands with M74) ───────


def _write_minimal_run(path: Path) -> None:
    """Smallest valid v1.1 .tio with one MS run for modality tests."""
    n_spec, n_pts = 2, 4
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n_spec).astype(np.float64)
    intensity = np.tile(
        np.linspace(1.0, 1000.0, n_pts), n_spec).astype(np.float64)
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, 1.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 1000.0, dtype=np.float64),
    )
    SpectralDataset.write_minimal(
        path,
        title="m79 modality",
        isa_investigation_id="TTIO:m79",
        runs={"run_0001": run},
    )


def test_modality_default_for_v0_10_files(tmp_path: Path) -> None:
    """Files written without a ``@modality`` attribute (= every v0.10
    file) read as ``"mass_spectrometry"`` so existing readers don't
    break on the new field."""
    out = tmp_path / "default.tio"
    _write_minimal_run(out)

    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs["run_0001"]
        assert run.modality == "mass_spectrometry"


def test_modality_explicit_genomic_sequencing(tmp_path: Path) -> None:
    """An explicit ``@modality = "genomic_sequencing"`` set on the run
    group is preserved through a close + reopen cycle. M79 ships only
    the read side; the write here goes through the StorageGroup
    attribute API directly so we don't need GenomicRun.write_to_group
    (M74)."""
    out = tmp_path / "explicit.tio"
    _write_minimal_run(out)

    # Re-open in read-write mode and stamp the attribute. SpectralDataset
    # doesn't surface a writable run group directly, so reach in via the
    # provider.
    with Hdf5Provider.open(str(out), mode="r+") as prov:
        run_group = (prov.root_group()
                         .open_group("study")
                         .open_group("ms_runs")
                         .open_group("run_0001"))
        run_group.set_attribute("modality", "genomic_sequencing")

    with SpectralDataset.open(out) as ds:
        run = ds.ms_runs["run_0001"]
        assert run.modality == "genomic_sequencing"
