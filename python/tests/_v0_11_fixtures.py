"""v0.11 conformance fixture builder — Python mirror of Java's
``FixtureBuilder`` (commits ``86116c0f`` + ``46c26587`` + ``2d04e035``).

Each builder is deterministic: same input produces a byte-stable
``.tio`` across runs (modulo HDF5's own deterministic-on-write
guarantees). The fixtures here are the per-accessor isolation
fixtures consumed by
:mod:`tests.test_accessor_matrix_conformance` plus the cross-
accessor ``everything.tio`` fixture consumed by
:mod:`tests.test_coverage_gap_watchdog`.

Stage 1 (Task 2.10): REFERENCES, MS_RUNS, GENOMIC_RUNS, IMAGE,
IDENTIFICATIONS, QUANTIFICATIONS, DATASET_PROVENANCE,
ENCRYPTION_ALGORITHM. SUBJECTS + SAMPLES are deferred — the v0.11
spec mentions them, but the data model still surfaces them only as
server-side cohort predicates.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import MSImage
from ttio.enums import AcquisitionMode, Polarity
from ttio.genomic.reference_import import ReferenceImport
from ttio.identification import Identification
from ttio.provenance import ProvenanceRecord
from ttio.quantification import Quantification
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.written_genomic_run import WrittenGenomicRun


# ── reference (3 contigs) — shared by REFERENCES + everything ─────────


def _ref_three_contigs(uri: str) -> ReferenceImport:
    """Build a deterministic 3-contig reference matching Java's
    ``FixtureBuilder.buildReferenceOnly`` shape:

    * ``chr_long``   — 6,000 bytes of ``'A'``
    * ``chr_medium`` — 1,000 bytes of ``'C'``
    * ``chr_short``  — 18 bytes of an ACGT-mix
    """
    return ReferenceImport(
        uri=uri,
        chromosomes=["chr_long", "chr_medium", "chr_short"],
        sequences=[
            b"A" * 6_000,
            b"C" * 1_000,
            b"ACGTACGTACGTACGTAC",
        ],
    )


def build_reference_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildReferenceOnly``."""
    SpectralDataset.write_minimal(
        target,
        title="reference_only",
        isa_investigation_id="",
        runs={},
    )
    ref = _ref_three_contigs("fixture-reference-only-v1")
    with SpectralDataset.open(target, writable=True) as ds:
        ref.write_to_dataset(ds)
    return target


# ── MSImage continuous (3x3x4 for everything; 4x4x5 for IMAGE-only) ──


def _build_image_cube(width: int, height: int, spectral_points: int,
                      title: str) -> MSImage:
    """Build a deterministic continuous-mode MSImage cube with
    ``intensity[y, x, k] = (k + 1) * (x + y * width)`` and m/z axis
    ``100 + 10*k`` for ``k`` in ``[0, spectral_points)``. Mirrors the
    Java ``buildEverything`` / ``buildImageMsContinuous`` formulas
    verbatim."""
    cube = np.empty((height, width, spectral_points), dtype=np.float64)
    for y in range(height):
        for x in range(width):
            pixel_idx = x + y * width
            for k in range(spectral_points):
                cube[y, x, k] = (k + 1.0) * pixel_idx
    mz = np.array(
        [100.0 + i * 10.0 for i in range(spectral_points)],
        dtype=np.float64,
    )
    return MSImage(
        width=width,
        height=height,
        spectral_points=spectral_points,
        intensity=cube,
        mz_axis=mz,
        pixel_size_x=10.0,
        pixel_size_y=10.0,
        scan_pattern="raster",
        title=title,
        isa_investigation_id="",
    )


def build_image_ms_continuous(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildImageMsContinuous`` — a
    4x4x5 continuous-mode MSImage and nothing else."""
    img = _build_image_cube(4, 4, 5, "image_ms_continuous")
    SpectralDataset.write_minimal(
        target,
        title="image_ms_continuous",
        isa_investigation_id="",
        runs={},
        image=img,
    )
    return target


# ── identifications / quantifications ────────────────────────────────


def _ids_two_rows(run_name: str = "run1") -> list[Identification]:
    return [
        Identification(
            run_name=run_name,
            spectrum_index=42 if run_name == "run1" else 0,
            chemical_entity="CompoundA",
            confidence_score=0.91,
            evidence_chain=["evidence1", "evidence2"],
        ),
        Identification(
            run_name=run_name,
            spectrum_index=43 if run_name == "run1" else 1,
            chemical_entity="CompoundB",
            confidence_score=0.85,
            evidence_chain=["evidence3"],
        ),
    ]


def _quants_two_rows() -> list[Quantification]:
    return [
        Quantification(
            chemical_entity="CompoundA",
            sample_ref="sample-1",
            abundance=12.5,
            normalization_method="intensity-sum",
            unit="counts",
        ),
        Quantification(
            chemical_entity="CompoundB",
            sample_ref="sample-1",
            abundance=7.3,
            normalization_method="intensity-sum",
            unit="counts",
        ),
    ]


def build_identifications_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildIdentificationsOnly``."""
    SpectralDataset.write_minimal(
        target,
        title="ids_only",
        isa_investigation_id="",
        runs={},
        identifications=_ids_two_rows("run1"),
    )
    return target


def build_quantifications_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildQuantificationsOnly``."""
    SpectralDataset.write_minimal(
        target,
        title="quants_only",
        isa_investigation_id="",
        runs={},
        quantifications=_quants_two_rows(),
    )
    return target


# ── provenance ───────────────────────────────────────────────────────


def _provenance_two_records() -> list[ProvenanceRecord]:
    """Mirror Java's ``FixtureBuilder.buildDatasetProvenanceOnly`` two-
    record fixture (one rich, one minimal). ``parameters`` is a Python
    dict; the on-disk JSON serialisation is order-sensitive at the
    string level but the dict-equality comparator used by
    :func:`AccessorSpec.assertContentEquals` ignores key order."""
    return [
        ProvenanceRecord(
            timestamp_unix=1700000000,
            software="TTI-O Python 1.0.0",
            parameters={"mode": "strict", "threshold": "0.5"},
            input_refs=["file:///in.raw", "file:///in2.raw"],
            output_refs=["file:///out.tio"],
        ),
        ProvenanceRecord(
            timestamp_unix=1700000100,
            software="downstream step",
            parameters={},
            input_refs=[],
            output_refs=["file:///final.tio"],
        ),
    ]


def build_dataset_provenance_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildDatasetProvenanceOnly``."""
    SpectralDataset.write_minimal(
        target,
        title="provenance_only",
        isa_investigation_id="",
        runs={},
        provenance=_provenance_two_records(),
    )
    return target


# ── encryption algorithm ─────────────────────────────────────────────


def build_encryption_algorithm_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildEncryptionAlgorithmOnly``.

    Stamps the root ``@encrypted`` attribute via the provider-level
    setter — same path the existing
    ``test_transport_encryption_algorithm`` fixture uses."""
    SpectralDataset.write_minimal(
        target,
        title="encryption_only",
        isa_investigation_id="",
        runs={},
    )
    with SpectralDataset.open(target, writable=True) as ds:
        ds.provider.root_group().set_attribute("encrypted", "aes-256-gcm")
    return target


# ── MS run (5 spectra x 4 m/z points) ────────────────────────────────


def _synth_ms_run(run_offset: int = 0, n_spectra: int = 5,
                  points_per_spectrum: int = 4) -> WrittenRun:
    """Mirror Java's ``FixtureBuilder.synthMsRun`` — deterministic MS
    run with ``intensity = 100 * (run_offset + 1) * (i + 1)`` and
    ``mz = 100 * (run_offset + 1) + i`` for global flat index ``i``.
    Used by both the standalone MS_RUNS fixture and the all-in-one
    everything fixture."""
    total = n_spectra * points_per_spectrum
    mz = np.array(
        [100.0 * (run_offset + 1) + i for i in range(total)],
        dtype="<f8",
    )
    intensity = np.array(
        [100.0 * (run_offset + 1) * (i + 1) for i in range(total)],
        dtype="<f8",
    )
    offsets = np.array(
        [i * points_per_spectrum for i in range(n_spectra)],
        dtype="<u8",
    )
    lengths = np.full(n_spectra, points_per_spectrum, dtype="<u4")
    retention_times = np.array(
        [1.0 + i for i in range(n_spectra)], dtype="<f8",
    )
    ms_levels = np.array(
        [1 if i % 2 == 0 else 2 for i in range(n_spectra)], dtype="<i4",
    )
    polarities = np.array(
        [int(Polarity.POSITIVE)] * n_spectra, dtype="<i4",
    )
    precursor_mzs = np.array(
        [0.0 if ms_levels[i] == 1 else 500.0 + i for i in range(n_spectra)],
        dtype="<f8",
    )
    precursor_charges = np.array(
        [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)],
        dtype="<i4",
    )
    base_peak_intensities = np.array(
        [
            float(
                intensity[i * points_per_spectrum:(i + 1) * points_per_spectrum].max()
            )
            for i in range(n_spectra)
        ],
        dtype="<f8",
    )
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=retention_times,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peak_intensities,
    )


def build_ms_runs_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildMsRunsOnly`` — one MS run
    named ``run_0001`` with 5 spectra of 4 m/z points each, no
    references / no image / no ids / no quants / no provenance."""
    SpectralDataset.write_minimal(
        target,
        title="ms_runs_only",
        isa_investigation_id="",
        runs={"run_0001": _synth_ms_run()},
    )
    return target


# ── genomic run (4 short aligned reads) ──────────────────────────────


def _synth_genomic_run() -> WrittenGenomicRun:
    """Mirror Java's ``FixtureBuilder.synthGenomicRun`` — 4 short
    aligned reads (``read_000`` … ``read_003``) on
    ``chr1``/``chr1``/``chr2``/``*`` with deterministic
    ``ACGTACGTACGT`` sequence and uniform quality 30. Mirrors the
    fixture shape used by ``test_transport_codec.TestGenomicRoundTrip``
    so the existing reader/writer paths are exercised."""
    n = 4
    template = b"ACGTACGTACGT"
    read_len = len(template)
    sequences = np.frombuffer(template * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * read_len)), dtype=np.uint8)
    offsets = np.arange(n, dtype=np.uint64) * read_len
    lengths = np.full(n, read_len, dtype=np.uint32)
    return WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 50, -1], dtype=np.int64),
        mapping_qualities=np.array([60, 55, 40, 0], dtype=np.uint8),
        flags=np.array([0x0003, 0x0003, 0x0003, 0x0004], dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=[f"{read_len}M"] * n,
        read_names=[f"read_{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "*"],
    )


def build_genomic_runs_only(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildGenomicRunsOnly``."""
    SpectralDataset.write_minimal(
        target,
        title="genomic_runs_only",
        isa_investigation_id="",
        runs={},
        genomic_runs={"genomic_0001": _synth_genomic_run()},
    )
    return target


# ── everything (8 accessors populated) ───────────────────────────────


def build_everything(target: Path) -> Path:
    """Mirror Java's ``FixtureBuilder.buildEverything``.

    Populates every first-class v0.11 accessor at once (except
    SUBJECTS + SAMPLES, deferred):

    * 1 reference (3 contigs)
    * 1 MSImage (3x3x4 continuous)
    * 2 identifications
    * 2 quantifications
    * 2 provenance records (1 rich, 1 minimal)
    * @encrypted = "aes-256-gcm"
    * 1 MS run (5 spectra x 4 m/z points)
    * 1 genomic run (4 reads)
    """
    # Image at 3x3x4 (smaller than the IMAGE-only fixture which uses
    # 4x4x5 — both mirror their Java counterparts).
    img = _build_image_cube(3, 3, 4, "everything")
    # MS + genomic + ids + quants + provenance in a single write_minimal.
    SpectralDataset.write_minimal(
        target,
        title="everything",
        isa_investigation_id="",
        runs={"run_0001": _synth_ms_run()},
        genomic_runs={"genomic_0001": _synth_genomic_run()},
        identifications=_ids_two_rows("run_0001"),
        quantifications=_quants_two_rows(),
        provenance=_provenance_two_records(),
        image=img,
    )
    # Layer the reference + the @encrypted root attribute through
    # writable re-open (mirrors the Java path which uses
    # writeToDataset + provider.rootGroup.setAttribute on an open
    # dataset).
    ref = _ref_three_contigs("fixture-everything-v1")
    with SpectralDataset.open(target, writable=True) as ds:
        ref.write_to_dataset(ds)
        ds.provider.root_group().set_attribute("encrypted", "aes-256-gcm")
    return target
