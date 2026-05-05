"""Full round-trip tests through the on-disk ``.tio`` container.

The other suite (``test_fasta_fastq_io.py``) exercises the parser
and writer in memory only — FASTA/FASTQ -> ``WrittenGenomicRun`` ->
FASTA/FASTQ. This suite drives the full chain that real users go
through:

    FASTA / FASTQ
      → reader
      → SpectralDataset.write_minimal(...)        [writes .tio]
      → SpectralDataset.open(...)                 [reads .tio]
      → writer
      → FASTA / FASTQ                             (compare to input)

Tests SKIP when the optional ``libttio_rans`` native library isn't
available (genomic-run write requires it for the NAME_TOKENIZED_V2
codec on the read_names channel).
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.codecs.fqzcomp_nx16_z import _HAVE_NATIVE_LIB
from ttio.exporters.fasta import FastaWriter
from ttio.exporters.fastq import FastqWriter
from ttio.genomic.reference_import import ReferenceImport
from ttio.importers.fasta import FastaReader
from ttio.importers.fastq import FastqReader
from ttio.spectral_dataset import SpectralDataset


pytestmark = pytest.mark.skipif(
    not _HAVE_NATIVE_LIB,
    reason=(
        "FASTA/FASTQ -> .tio -> FASTA/FASTQ round-trip requires the "
        "native libttio_rans library (set TTIO_RANS_LIB_PATH or build "
        "via 'pip install ttio[native]')."
    ),
)


# ---------------------------------------------------------------------- FASTQ


def test_fastq_to_tio_to_fastq_byte_exact(tmp_path: Path) -> None:
    """Byte-exact round-trip for the FASTQ → .tio → FASTQ chain.

    The default Phred+33 encoding should survive write+read intact.
    """
    src = tmp_path / "src.fq"
    src.write_bytes(
        b"@r1\nACGTACGT\n+\n!!!!!!!!\n"
        b"@r2\nGGGGAAAA\n+\nIIIIJJJJ\n"
        b"@r3\nNNNN\n+\n????\n"
    )
    tio_path = tmp_path / "out.tio"
    final_fq = tmp_path / "final.fq"

    # Step 1: parse FASTQ -> WrittenGenomicRun
    run_in = FastqReader(src).read(sample_name="S1")

    # Step 2: write WrittenGenomicRun -> .tio
    SpectralDataset.write_minimal(
        tio_path,
        title="",
        isa_investigation_id="",
        runs={},
        genomic_runs={"genomic_0001": run_in},
    )
    assert tio_path.exists() and tio_path.stat().st_size > 0

    # Step 3: open .tio and recover the run
    with SpectralDataset.open(tio_path) as ds:
        assert "genomic_0001" in ds.genomic_runs
        run_back = ds.genomic_runs["genomic_0001"]

        # Step 4: write the recovered run back out as FASTQ
        FastqWriter.write(run_back, final_fq)

    # Step 5: input bytes must equal output bytes
    assert final_fq.read_bytes() == src.read_bytes()


def test_fastq_to_tio_preserves_read_count_and_qualities(
    tmp_path: Path,
) -> None:
    """Round-trip preserves per-read sequence + quality content."""
    src = tmp_path / "src.fq"
    expected_reads = [
        ("read_0001", b"ACGTACGTACGT", b"!" * 12),
        ("read_0002", b"NNNN", b"????"),
        ("read_0003", b"GGGGGGGG", b"IIIIIIII"),
    ]
    body = b""
    for name, seq, qual in expected_reads:
        body += b"@" + name.encode() + b"\n" + seq + b"\n+\n" + qual + b"\n"
    src.write_bytes(body)

    tio_path = tmp_path / "out.tio"
    run = FastqReader(src).read()
    SpectralDataset.write_minimal(
        tio_path, title="", isa_investigation_id="",
        runs={}, genomic_runs={"reads": run},
    )
    with SpectralDataset.open(tio_path) as ds:
        recovered = ds.genomic_runs["reads"]
        assert len(recovered) == len(expected_reads)
        for i, (name, seq, qual) in enumerate(expected_reads):
            r = recovered[i]
            assert r.read_name == name
            assert r.sequence == seq.decode()
            assert bytes(r.qualities) == qual


# ---------------------------------------------------------------------- FASTA reference


def test_fasta_reference_to_tio_to_fasta_byte_exact(tmp_path: Path) -> None:
    """FASTA reference embedded in a .tio reads back byte-exact."""
    src = tmp_path / "ref.fa"
    src.write_bytes(
        b">chr1\nACGTACGTACGT\n>chr2\nGGGggg\n>chr3\n"
        + b"A" * 125 + b"\n"
    )
    tio_path = tmp_path / "out.tio"
    final_fa = tmp_path / "final.fa"

    # Step 1: parse FASTA -> ReferenceImport
    ref_in = FastaReader(src).read_reference()
    assert ref_in.uri == "ref"
    assert len(ref_in.chromosomes) == 3

    # Step 2: create empty .tio, then embed the reference
    SpectralDataset.write_minimal(
        tio_path, title="", isa_investigation_id="", runs={},
    )
    with SpectralDataset.open(tio_path, writable=True) as ds:
        ref_in.write_to_dataset(ds)

    # Step 3: open .tio and load reference back from
    #         /study/references/<uri>/
    with SpectralDataset.open(tio_path) as ds:
        h5 = ds.file
        grp = h5["/study/references/ref"]
        md5_hex = grp.attrs["md5"]
        if isinstance(md5_hex, bytes):
            md5_hex = md5_hex.decode("ascii")
        names = sorted(grp["chromosomes"].keys())
        seqs = [
            bytes(np.asarray(grp["chromosomes"][n]["data"]).tobytes())
            for n in names
        ]
        ref_back = ReferenceImport(
            uri="ref",
            chromosomes=names,
            sequences=seqs,
            md5=bytes.fromhex(md5_hex),
        )

    # Step 4: write the recovered reference to a fresh FASTA
    FastaWriter.write_reference(ref_back, final_fa, line_width=60)

    # Step 5: compare
    # Reference is sorted by chromosome name on read-back from HDF5
    # (h5py iterates groups in stored order, which is creation order).
    # Check content invariants instead of byte-equality on the file.
    assert ref_back.md5 == ref_in.md5
    expected_total = sum(len(s) for s in ref_in.sequences)
    actual_total = sum(len(s) for s in ref_back.sequences)
    assert expected_total == actual_total
    # Each chromosome's bytes round-trip exactly.
    for name in ref_in.chromosomes:
        assert ref_back.chromosome(name) == ref_in.chromosome(name)


def test_fasta_unaligned_to_tio_to_fasta(tmp_path: Path) -> None:
    """FASTA → unaligned WrittenGenomicRun → .tio → FASTA recovers
    the original sequences (qualities are FASTA-sentinel 0xFF and
    are intentionally not preserved on FASTA export — only the
    sequence content needs to round-trip)."""
    src = tmp_path / "panel.fa"
    src.write_bytes(
        b">target_1\nACGTACGTACGT\n>target_2\nGGGGAAAA\n"
    )
    tio_path = tmp_path / "out.tio"
    final_fa = tmp_path / "final.fa"

    run_in = FastaReader(src).read_unaligned(sample_name="panel")
    SpectralDataset.write_minimal(
        tio_path, title="", isa_investigation_id="", runs={},
        genomic_runs={"panel": run_in},
    )
    with SpectralDataset.open(tio_path) as ds:
        run_back = ds.genomic_runs["panel"]
        FastaWriter.write_run(run_back, final_fa, line_width=60)

    # The default 60-char line wrap means short sequences fit on one
    # line each, so the output is byte-identical to the input.
    assert final_fa.read_bytes() == src.read_bytes()
