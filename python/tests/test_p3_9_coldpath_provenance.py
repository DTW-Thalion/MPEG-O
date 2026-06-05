"""P3.9 (OO-assessment): characterize the per-run provenance cold path.

These tests pin the behaviour of ``AcquisitionRun.provenance()`` and
``GenomicRun.provenance()`` independent of the internal ``_native_h5py``
shim, so the PR-3 refactor (route the compound ``provenance/steps`` read
through the ``StorageGroup`` protocol instead of casting to a raw h5py
handle) is byte-for-byte behaviour-preserving.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import ProvenanceRecord, SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode


def _ms_records() -> list[ProvenanceRecord]:
    return [
        ProvenanceRecord(
            timestamp_unix=1710000000,
            software="thermo-raw-parser/1.4",
            parameters={"denoise": "yes"},
            input_refs=["raw:run_0001"],
            output_refs=["ttio:run_0001"],
        ),
        ProvenanceRecord(
            timestamp_unix=1710000100,
            software="ttio-py/0.3.0",
            parameters={"mode": "serialize"},
            input_refs=["ttio:run_0001"],
            output_refs=["ttio:run_0001"],
        ),
    ]


def _ms_run(records: list[ProvenanceRecord]) -> WrittenRun:
    n_spec, n_pts = 3, 4
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    mz = np.tile(np.linspace(100.0, 200.0, n_pts), n_spec).astype(np.float64)
    intensity = np.tile(
        np.linspace(1.0, 100.0, n_pts), n_spec
    ).astype(np.float64)
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, 2.0, n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 100.0, dtype=np.float64),
        provenance_records=records,
    )


def _genomic_run(records: list[ProvenanceRecord]):
    from ttio.written_genomic_run import WrittenGenomicRun

    n_reads, read_length = 4, 10
    positions = np.array([10_000 + i * 100 for i in range(n_reads)],
                         dtype=np.int64)
    flags = np.zeros(n_reads, dtype=np.uint32)
    mapqs = np.full(n_reads, 60, dtype=np.uint8)
    seq = np.frombuffer(b"ACGT" * (n_reads * read_length // 4), dtype=np.uint8)
    qual = np.frombuffer(bytes([30] * (n_reads * read_length)), dtype=np.uint8)
    offsets = np.arange(n_reads, dtype=np.uint64) * read_length
    lengths = np.full(n_reads, read_length, dtype=np.uint32)
    return WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=seq,
        qualities=qual,
        offsets=offsets,
        lengths=lengths,
        cigars=[f"{read_length}M" for _ in range(n_reads)],
        read_names=[f"read_{i:06d}" for i in range(n_reads)],
        mate_chromosomes=["*" for _ in range(n_reads)],
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1"] * n_reads,
        provenance_records=records,
    )


def test_ms_provenance_coldpath_via_protocol(tmp_path: Path) -> None:
    out = tmp_path / "p39_ms.tio"
    records = _ms_records()
    SpectralDataset.write_minimal(
        out,
        title="p39 ms",
        isa_investigation_id="TTIO:p39ms",
        runs={"run_0001": _ms_run(records)},
    )
    with SpectralDataset.open(out) as ds:
        prov = ds.ms_runs["run_0001"].provenance()
    assert [p.software for p in prov] == [
        "thermo-raw-parser/1.4",
        "ttio-py/0.3.0",
    ]
    assert prov[0].timestamp_unix == 1710000000
    assert prov[0].parameters == {"denoise": "yes"}
    assert prov[0].input_refs == ["raw:run_0001"]


def test_ms_provenance_coldpath_empty(tmp_path: Path) -> None:
    out = tmp_path / "p39_ms_empty.tio"
    SpectralDataset.write_minimal(
        out,
        title="p39 ms empty",
        isa_investigation_id="TTIO:p39mse",
        runs={"run_0001": _ms_run([])},
    )
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs["run_0001"].provenance() == []


def test_genomic_provenance_coldpath_via_protocol(tmp_path: Path) -> None:
    out = tmp_path / "p39_gen.tio"
    records = _ms_records()
    SpectralDataset.write_minimal(
        out,
        title="p39 gen",
        isa_investigation_id="TTIO:p39gen",
        runs={},
        genomic_runs={"genomic_0001": _genomic_run(records)},
    )
    with SpectralDataset.open(out) as ds:
        prov = ds.genomic_runs["genomic_0001"].provenance_chain()
    assert [p.software for p in prov] == [
        "thermo-raw-parser/1.4",
        "ttio-py/0.3.0",
    ]
    assert prov[1].timestamp_unix == 1710000100


def test_genomic_provenance_coldpath_empty(tmp_path: Path) -> None:
    out = tmp_path / "p39_gen_empty.tio"
    SpectralDataset.write_minimal(
        out,
        title="p39 gen empty",
        isa_investigation_id="TTIO:p39gene",
        runs={},
        genomic_runs={"genomic_0001": _genomic_run([])},
    )
    with SpectralDataset.open(out) as ds:
        assert ds.genomic_runs["genomic_0001"].provenance_chain() == []
