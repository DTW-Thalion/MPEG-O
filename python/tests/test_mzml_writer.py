"""M19 mzML writer tests — round trip and byte offsets."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.exporters import mzml as mzml_writer
from ttio.importers import mzml as mzml_reader


def _build_dataset(n_spec: int = 3, n_pts: int = 6) -> Path:
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={
            "mz": np.tile(np.linspace(100.0, 102.5, n_pts), n_spec).astype(np.float64),
            "intensity": np.tile(np.linspace(1.0, 100.0, n_pts), n_spec).astype(np.float64),
        },
        offsets=np.arange(n_spec, dtype=np.uint64) * n_pts,
        lengths=np.full(n_spec, n_pts, dtype=np.uint32),
        retention_times=np.linspace(0.0, 2.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 100.0, dtype=np.float64),
    )


def _write_ttio(tmp_path: Path, n_spec: int = 3, n_pts: int = 6) -> Path:
    out = tmp_path / "m19_src.tio"
    SpectralDataset.write_minimal(
        out, title="m19", isa_investigation_id="TTIO:m19",
        runs={"run_0001": _build_dataset(n_spec=n_spec, n_pts=n_pts)},
    )
    return out


def test_writer_produces_parseable_mzml_uncompressed(tmp_path: Path) -> None:
    src = _write_ttio(tmp_path, n_spec=3, n_pts=6)
    mzml_path = tmp_path / "out.mzML"
    with SpectralDataset.open(src) as ds:
        mzml_writer.write_dataset(ds, mzml_path, zlib_compression=False)
    assert mzml_path.stat().st_size > 0

    # Round trip via the ttio mzML importer.
    result = mzml_reader.read(mzml_path)
    assert len(result.ms_spectra) == 3
    first = result.ms_spectra[0]
    np.testing.assert_allclose(
        first.mz_or_chemical_shift, np.linspace(100.0, 102.5, 6),
    )
    np.testing.assert_allclose(
        first.intensity, np.linspace(1.0, 100.0, 6),
    )


def test_writer_produces_parseable_mzml_zlib(tmp_path: Path) -> None:
    src = _write_ttio(tmp_path, n_spec=4, n_pts=8)
    mzml_path = tmp_path / "out.mzML"
    with SpectralDataset.open(src) as ds:
        mzml_writer.write_dataset(ds, mzml_path, zlib_compression=True)

    result = mzml_reader.read(mzml_path)
    assert len(result.ms_spectra) == 4
    # Exact float64 equality after zlib round trip.
    last = result.ms_spectra[3]
    np.testing.assert_array_equal(
        last.mz_or_chemical_shift.astype(np.float64),
        np.linspace(100.0, 102.5, 8).astype(np.float64),
    )


def test_indexed_mzml_offsets_point_at_spectrum_tag(tmp_path: Path) -> None:
    """``<indexList>`` offsets must be byte-correct — the byte at each
    offset should be the literal ``<`` of ``<spectrum``."""
    src = _write_ttio(tmp_path, n_spec=2, n_pts=4)
    with SpectralDataset.open(src) as ds:
        blob = mzml_writer.dataset_to_bytes(ds, zlib_compression=False)

    text = blob.decode("utf-8")
    # Parse the first <offset> entry under the spectrum index.
    start = text.index('<index name="spectrum">')
    offset_line = text.index('<offset idRef="scan=1">', start)
    num_start = offset_line + len('<offset idRef="scan=1">')
    num_end = text.index("</offset>", num_start)
    byte_offset = int(text[num_start:num_end])

    assert 0 < byte_offset < len(blob)
    snippet = blob[byte_offset:byte_offset + len("<spectrum")]
    assert snippet == b"<spectrum"


def test_writer_emits_activation_block_for_ms2_spectra(tmp_path: Path) -> None:
    """PSI mzML 1.1 XSD requires <activation> inside every <precursor>.
    When the source dataset carries no M74 detail (legacy file or the
    ``opt_ms2_activation_detail`` flag unset), the element is emitted
    empty rather than with a fabricated cvParam — downstream tooling
    can tell the difference."""
    out = tmp_path / "ms2.tio"
    # Build a dataset with one MS1 + one MS2 spectrum.
    SpectralDataset.write_minimal(
        out, title="ms2 test", isa_investigation_id="TTIO:ms2",
        runs={"run1": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={
                "mz": np.array([100.0, 200.0, 300.0, 150.0, 250.0], dtype=np.float64),
                "intensity": np.array([1.0, 2.0, 3.0, 4.0, 5.0], dtype=np.float64),
            },
            offsets=np.array([0, 3], dtype=np.uint64),
            lengths=np.array([3, 2], dtype=np.uint32),
            retention_times=np.array([0.5, 1.0]),
            ms_levels=np.array([1, 2], dtype=np.int32),
            polarities=np.array([1, 1], dtype=np.int32),
            precursor_mzs=np.array([0.0, 250.0]),
            precursor_charges=np.array([0, 2], dtype=np.int32),
            base_peak_intensities=np.array([3.0, 5.0]),
        )},
    )
    with SpectralDataset.open(out) as ds:
        blob = mzml_writer.dataset_to_bytes(ds)
    text = blob.decode("utf-8")
    # MS2 spectrum must carry a precursor block with <activation> (XSD
    # requires the child). Without M74 detail, no activation cvParam
    # is fabricated: the element is empty.
    assert "<precursor>" in text, "MS2 spectrum must emit <precursor>"
    assert "<activation>" in text, (
        "<precursor> must include <activation> child per mzML 1.1 XSD"
    )
    assert "MS:1000133" not in text, (
        "writer must not fabricate a CID cvParam when activation is unknown"
    )
    assert "MS:1000827" not in text, (
        "writer must not emit an isolation-window cvParam when none is stored"
    )


def test_writer_emits_m74_activation_and_isolation(tmp_path: Path) -> None:
    """(M74 Slice D) When the WrittenRun supplies activation_methods
    and isolation window columns, the mzML writer emits the matching
    PSI-MS cvParams and the round-trip through the reader restores the
    original ActivationMethod / IsolationWindow values."""
    from ttio.enums import ActivationMethod

    out = tmp_path / "m74.tio"
    SpectralDataset.write_minimal(
        out, title="m74 test", isa_investigation_id="TTIO:m74",
        runs={"run1": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS2_DDA),
            channel_data={
                "mz": np.array([100.0, 200.0, 300.0, 150.0, 250.0], dtype=np.float64),
                "intensity": np.array([1.0, 2.0, 3.0, 4.0, 5.0], dtype=np.float64),
            },
            offsets=np.array([0, 3], dtype=np.uint64),
            lengths=np.array([3, 2], dtype=np.uint32),
            retention_times=np.array([0.5, 1.0]),
            ms_levels=np.array([1, 2], dtype=np.int32),
            polarities=np.array([1, 1], dtype=np.int32),
            precursor_mzs=np.array([0.0, 445.3]),
            precursor_charges=np.array([0, 2], dtype=np.int32),
            base_peak_intensities=np.array([3.0, 5.0]),
            # M74 detail: MS1 keeps the NONE/zero sentinel; MS2 carries
            # HCD activation and a symmetric ±0.5 Th isolation window.
            activation_methods=np.array(
                [int(ActivationMethod.NONE), int(ActivationMethod.HCD)],
                dtype=np.int32,
            ),
            isolation_target_mzs=np.array([0.0, 445.3], dtype=np.float64),
            isolation_lower_offsets=np.array([0.0, 0.5], dtype=np.float64),
            isolation_upper_offsets=np.array([0.0, 0.5], dtype=np.float64),
        )},
    )
    with SpectralDataset.open(out) as ds:
        blob = mzml_writer.dataset_to_bytes(ds)
    text = blob.decode("utf-8")

    # Activation: HCD accession appears, CID does not (proves the
    # writer consults the data-model rather than emitting a placeholder).
    assert 'accession="MS:1000422"' in text, "HCD accession must appear"
    assert "beam-type collision-induced dissociation" in text
    assert 'accession="MS:1000133"' not in text, "CID must not leak in"

    # Isolation window: all three cvParams present with the correct values.
    assert 'accession="MS:1000827"' in text
    assert 'accession="MS:1000828"' in text
    assert 'accession="MS:1000829"' in text
    assert 'value="445.3"' in text  # target m/z
    assert 'value="0.5"' in text    # shared lower/upper offset

    # Round-trip: write mzML to disk, read with ttio.importers.mzml,
    # confirm the reader recovers the same enum + offsets.
    mzml_path = tmp_path / "m74.mzML"
    mzml_path.write_bytes(blob)
    result = mzml_reader.read(mzml_path)
    ms2 = result.ms_spectra[1]
    assert ms2.activation_method == int(ActivationMethod.HCD)
    assert ms2.isolation_target_mz == pytest.approx(445.3)
    assert ms2.isolation_lower_offset == pytest.approx(0.5)
    assert ms2.isolation_upper_offset == pytest.approx(0.5)
    # MS1 must stay at the NONE/zero sentinel — no leakage from MS2.
    ms1 = result.ms_spectra[0]
    assert ms1.activation_method == int(ActivationMethod.NONE)
    assert ms1.isolation_target_mz == 0.0


def test_writer_populates_instrument_configuration_from_dataset(
    tmp_path: Path,
) -> None:
    """v0.9 M64: <instrumentConfiguration> cvParam and userParams reflect
    the dataset's InstrumentConfig rather than emitting an empty block.
    write_minimal callers that don't set instrument metadata get an
    empty cvParam value — the block is still XSD-valid."""
    out = tmp_path / "ic.tio"
    SpectralDataset.write_minimal(
        out, title="ic test", isa_investigation_id="TTIO:ic",
        runs={"run1": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={
                "mz": np.array([100.0, 200.0], dtype=np.float64),
                "intensity": np.array([1.0, 2.0], dtype=np.float64),
            },
            offsets=np.array([0], dtype=np.uint64),
            lengths=np.array([2], dtype=np.uint32),
            retention_times=np.array([0.5]),
            ms_levels=np.array([1], dtype=np.int32),
            polarities=np.array([1], dtype=np.int32),
            precursor_mzs=np.array([0.0]),
            precursor_charges=np.array([0], dtype=np.int32),
            base_peak_intensities=np.array([2.0]),
        )},
    )
    with SpectralDataset.open(out) as ds:
        blob = mzml_writer.dataset_to_bytes(ds)
    text = blob.decode("utf-8")
    # The instrument-model cvParam is always emitted (XSD-required); the
    # value may be empty when the dataset doesn't carry instrument data.
    assert '<cvParam cvRef="MS" accession="MS:1000031" name="instrument model"' in text
    # Required per-file sections must all be present.
    assert "<softwareList" in text
    assert "<instrumentConfigurationList" in text
    assert "<dataProcessingList" in text


def test_writer_refuses_dataset_without_ms_run(tmp_path: Path) -> None:
    out = tmp_path / "empty.tio"
    # Build a valid .tio with a single NMR-class run so there is no
    # TTIOMassSpectrum to export.
    SpectralDataset.write_minimal(
        out, title="nmr only", isa_investigation_id="TTIO:nmr",
        runs={"nmr_run": WrittenRun(
            spectrum_class="TTIONMRSpectrum",
            acquisition_mode=int(AcquisitionMode.NMR_1D),
            channel_data={
                "chemical_shift": np.linspace(0.0, 10.0, 8),
                "intensity": np.linspace(1.0, 8.0, 8),
            },
            offsets=np.array([0], dtype=np.uint64),
            lengths=np.array([8], dtype=np.uint32),
            retention_times=np.array([0.0]),
            ms_levels=np.zeros(1, dtype=np.int32),
            polarities=np.zeros(1, dtype=np.int32),
            precursor_mzs=np.zeros(1),
            precursor_charges=np.zeros(1, dtype=np.int32),
            base_peak_intensities=np.array([10.0]),
            nucleus_type="1H",
        )},
    )
    with SpectralDataset.open(out) as ds:
        with pytest.raises(ValueError, match="no TTIOMassSpectrum"):
            mzml_writer.dataset_to_bytes(ds)
