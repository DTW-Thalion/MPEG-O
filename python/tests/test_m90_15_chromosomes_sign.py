"""M90.15: sign the chromosomes VL compound.

Closes gap #9 from the post-M90 analysis. M90.2 explicitly skipped
the genomic_index/chromosomes compound on the rationale that the
canonical-bytes path didn't yet handle VL row compounds — but the
existing read_canonical_bytes via canonicalise_compound_rows /
canonicalise_compound_structured DOES handle VL_BYTES fields
(emitted as ``u32_le(length) || utf-8_bytes``). This milestone
just adds chromosomes to the signed-dataset list.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

import h5py

from ttio import SpectralDataset
from ttio.signatures import sign_genomic_run, verify_genomic_run
from ttio.written_genomic_run import WrittenGenomicRun


KEY = b"\x42" * 32


def _make_genomic_dataset(path: Path) -> Path:
    n = 4
    L = 8
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8),
        qualities=np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8),
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"r{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.15 chromosomes-sign fixture",
        isa_investigation_id="ISA-M90-15",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestChromosomesSigning:

    def test_sign_genomic_run_includes_chromosomes(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "src.tio")
        with h5py.File(path, "r+") as f:
            sigs = sign_genomic_run(f["/study/genomic_runs/genomic_0001"], KEY)
        assert "genomic_index/chromosomes" in sigs, (
            "M90.15: chromosomes compound must be signed"
        )
        # Signature is HMAC-SHA256 v2-prefixed.
        assert sigs["genomic_index/chromosomes"].startswith("v2:")

    def test_verify_passes_on_clean_run(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "v.tio")
        with h5py.File(path, "r+") as f:
            run = f["/study/genomic_runs/genomic_0001"]
            sign_genomic_run(run, KEY)
            assert verify_genomic_run(run, KEY) is True

    def test_verify_detects_tampered_chromosomes(self, tmp_path):
        path = _make_genomic_dataset(tmp_path / "t.tio")
        with h5py.File(path, "r+") as f:
            run = f["/study/genomic_runs/genomic_0001"]
            sign_genomic_run(run, KEY)
            # Tamper with the chromosomes compound by deleting a row's
            # value and rewriting (changes the canonical bytes).
            chrom_ds = run["genomic_index/chromosomes"]
            current = chrom_ds[()]
            # Mutate index 0's value field. Compound row read returns
            # a numpy structured array.
            new_rows = current.copy()
            # Field name is "value" per genomic_index._write helper.
            new_rows[0]["value"] = b"chrTAMPERED"
            chrom_ds[...] = new_rows
            assert verify_genomic_run(run, KEY) is False, (
                "M90.15: tampered chromosomes compound must verify=False"
            )
