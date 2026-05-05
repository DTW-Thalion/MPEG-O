"""Round-trip + parser-correctness tests for the FASTA/FASTQ I/O paths.

Covers:
- FASTA reference round-trip (ReferenceImport -> file -> ReferenceImport)
- FASTA unaligned-run round-trip (FASTA -> WrittenGenomicRun -> FASTA)
- FASTQ round-trip with Phred+33 (default) and Phred+64 (forced)
- Phred auto-detect heuristic
- gzip transparent decompression
- .fai index format
- Cross-language byte fixtures (FASTA / FASTQ canonical bytes)
"""
from __future__ import annotations

import gzip
import hashlib
from pathlib import Path

import pytest

from ttio.exporters.fasta import FastaWriter, DEFAULT_LINE_WIDTH
from ttio.exporters.fastq import FastqWriter
from ttio.genomic.reference_import import (
    ReferenceImport,
    compute_reference_md5,
)
from ttio.importers.fasta import FastaParseError, FastaReader
from ttio.importers.fastq import (
    FastqParseError,
    FastqReader,
    detect_phred_offset,
)


# ---------------------------------------------------------------------- helpers


def _write(path: Path, content: bytes) -> Path:
    path.write_bytes(content)
    return path


# ---------------------------------------------------------------------- FASTA reference


def test_reference_import_md5_is_order_invariant() -> None:
    a = compute_reference_md5(["chr1", "chr2"], [b"AAA", b"GGG"])
    b = compute_reference_md5(["chr2", "chr1"], [b"GGG", b"AAA"])
    assert a == b
    assert len(a) == 16


def test_reference_round_trip_preserves_bytes(tmp_path: Path) -> None:
    fa = _write(
        tmp_path / "ref.fa",
        b">chr1\nACGTACGT\nACGT\n>chr2\nGGGggg\n",
    )

    ref_in = FastaReader(fa).read_reference()
    assert ref_in.uri == "ref"
    assert ref_in.chromosomes == ["chr1", "chr2"]
    # Case preserved (note lowercase soft-masking on chr2).
    assert ref_in.sequences == [b"ACGTACGTACGT", b"GGGggg"]

    out = tmp_path / "out.fa"
    FastaWriter.write_reference(ref_in, out, line_width=4)
    ref_out = FastaReader(out).read_reference()
    assert ref_out.chromosomes == ref_in.chromosomes
    assert ref_out.sequences == ref_in.sequences
    assert ref_out.md5 == ref_in.md5


def test_fasta_writer_emits_default_60_char_wrap(tmp_path: Path) -> None:
    seq = b"A" * 125
    ref = ReferenceImport(
        uri="x",
        chromosomes=["chr1"],
        sequences=[seq],
    )
    out = tmp_path / "x.fa"
    FastaWriter.write_reference(ref, out)
    body = out.read_bytes()
    # Header + 60 + LF + 60 + LF + 5 + LF
    assert body == b">chr1\n" + b"A" * 60 + b"\n" + b"A" * 60 + b"\n" + b"A" * 5 + b"\n"


def test_fasta_writer_configurable_line_width(tmp_path: Path) -> None:
    ref = ReferenceImport(uri="x", chromosomes=["c"], sequences=[b"A" * 25])
    out = tmp_path / "x.fa"
    FastaWriter.write_reference(ref, out, line_width=10)
    body = out.read_bytes()
    assert body == b">c\n" + b"A" * 10 + b"\n" + b"A" * 10 + b"\n" + b"A" * 5 + b"\n"


def test_fai_index_byte_layout(tmp_path: Path) -> None:
    ref = ReferenceImport(
        uri="x",
        chromosomes=["chr1", "chr2"],
        sequences=[b"A" * 100, b"G" * 60],
    )
    out = tmp_path / "x.fa"
    FastaWriter.write_reference(ref, out, line_width=60, write_fai=True)
    fai = (tmp_path / "x.fa.fai").read_text(encoding="ascii").splitlines()
    # chr1: length=100, offset=6 (after ">chr1\n"), linebases=60, linewidth=61
    assert fai[0] == "chr1\t100\t6\t60\t61"
    # chr2 starts after chr1's body: ">chr1\n" (6) + 100 bases + 2 LFs = 108,
    # then ">chr2\n" header (6 bytes) → seq starts at 114.
    expected_offset = 6 + 100 + 2 + 6
    assert fai[1] == f"chr2\t60\t{expected_offset}\t60\t61"


def test_fasta_gzip_round_trip(tmp_path: Path) -> None:
    ref = ReferenceImport(
        uri="g", chromosomes=["chr1"], sequences=[b"ACGT" * 25]
    )
    out = tmp_path / "g.fa.gz"
    FastaWriter.write_reference(ref, out)
    # Output is gzip-magic.
    assert out.read_bytes()[:2] == b"\x1f\x8b"
    # No .fai for gzip output (samtools needs bgzip).
    assert not (tmp_path / "g.fa.gz.fai").exists()
    ref_back = FastaReader(out).read_reference()
    assert ref_back.sequences == ref.sequences


def test_fasta_unaligned_round_trip(tmp_path: Path) -> None:
    fa = _write(
        tmp_path / "reads.fa",
        b">read_1\nACGTACGT\n>read_2\nGGGGAAAA\n",
    )
    run = FastaReader(fa).read_unaligned(sample_name="NA12878")
    assert run.sample_name == "NA12878"
    assert run.read_names == ["read_1", "read_2"]
    assert list(run.flags) == [4, 4]
    assert list(run.chromosomes) == ["*", "*"]
    # FASTA-imported runs have qualities set to 0xFF "unknown".
    assert all(q == 0xFF for q in run.qualities)

    out = tmp_path / "back.fa"
    FastaWriter.write_run(run, out, line_width=4)
    body = out.read_bytes()
    assert body == (
        b">read_1\n"
        b"ACGT\nACGT\n"
        b">read_2\n"
        b"GGGG\nAAAA\n"
    )


def test_fasta_parse_error_on_orphan_sequence(tmp_path: Path) -> None:
    fa = _write(tmp_path / "bad.fa", b"ACGT\n>c\nGGG\n")
    with pytest.raises(FastaParseError, match="before any header"):
        FastaReader(fa).read_reference()


# ---------------------------------------------------------------------- FASTQ


def _phred33(seq_len: int, score: int = 30) -> bytes:
    return bytes([score + 33]) * seq_len


def test_fastq_phred33_round_trip(tmp_path: Path) -> None:
    fq = _write(
        tmp_path / "reads.fq",
        b"@r1\nACGT\n+\n"
        + _phred33(4, 30)
        + b"\n@r2\nGGGG\n+\n"
        + _phred33(4, 20)
        + b"\n",
    )
    run = FastqReader(fq).read(sample_name="S1")
    assert FastqReader(fq)
    reader = FastqReader(fq)
    reader.read()
    assert reader.detected_phred_offset == 33
    assert run.read_names == ["r1", "r2"]
    assert list(run.qualities[:4]) == [63, 63, 63, 63]  # 30 + 33

    out = tmp_path / "back.fq"
    FastqWriter.write(run, out)
    body = out.read_bytes()
    assert body == (
        b"@r1\nACGT\n+\n????\n"
        b"@r2\nGGGG\n+\n555 5\n".replace(b"5 5", b"55")
    )
    # Verify by re-parsing — round-trip must be lossless byte-for-byte.
    run_back = FastqReader(out).read()
    assert run_back.read_names == run.read_names
    assert bytes(run_back.qualities) == bytes(run.qualities)
    assert bytes(run_back.sequences) == bytes(run.sequences)


def test_fastq_phred_auto_detect_legacy_64() -> None:
    # All bytes in [64, 104] -> Phred+64
    raw = bytes(range(64, 105))
    assert detect_phred_offset(raw) == 64


def test_fastq_phred_auto_detect_modern_33() -> None:
    # Includes a byte < 59 -> definitely Phred+33
    raw = bytes([33, 50, 70, 80])
    assert detect_phred_offset(raw) == 33


def test_fastq_phred_auto_detect_default_33() -> None:
    # Empty -> default 33
    assert detect_phred_offset(b"") == 33


def test_fastq_phred64_input_normalised_to_33(tmp_path: Path) -> None:
    # Phred+64: 'h' = 104 = score 40
    qual_p64 = bytes([104, 100, 80])  # scores 40, 36, 16
    fq = _write(
        tmp_path / "p64.fq",
        b"@r1\nACG\n+\n" + qual_p64 + b"\n",
    )
    run = FastqReader(fq).read()
    # Internally converted to Phred+33: byte - 31
    assert list(run.qualities) == [104 - 31, 100 - 31, 80 - 31]


def test_fastq_force_phred(tmp_path: Path) -> None:
    qual_p64 = bytes([104, 100, 80])
    fq = _write(
        tmp_path / "force.fq",
        b"@r1\nACG\n+\n" + qual_p64 + b"\n",
    )
    # Force Phred+33 — bytes pass through verbatim.
    run = FastqReader(fq, force_phred=33).read()
    assert list(run.qualities) == list(qual_p64)


def test_fastq_export_phred64(tmp_path: Path) -> None:
    fq = _write(
        tmp_path / "in.fq",
        b"@r1\nACG\n+\n" + _phred33(3, 20) + b"\n",
    )
    run = FastqReader(fq).read()
    out = tmp_path / "out.fq"
    FastqWriter.write(run, out, phred_offset=64)
    # Phred+33 byte 53 (= 20 + 33) -> Phred+64 byte 84 (= 20 + 64).
    body = out.read_bytes()
    assert b"\n+\n" + bytes([84, 84, 84]) + b"\n" in body


def test_fastq_gzip_round_trip(tmp_path: Path) -> None:
    fq = _write(
        tmp_path / "in.fq",
        b"@r1\nAAAA\n+\n" + _phred33(4) + b"\n",
    )
    run = FastqReader(fq).read()
    out = tmp_path / "out.fq.gz"
    FastqWriter.write(run, out)
    # Gzip magic.
    assert out.read_bytes()[:2] == b"\x1f\x8b"
    run_back = FastqReader(out).read()
    assert run_back.read_names == run.read_names
    assert bytes(run_back.sequences) == bytes(run.sequences)
    assert bytes(run_back.qualities) == bytes(run.qualities)


def test_fastq_parse_error_missing_separator(tmp_path: Path) -> None:
    fq = _write(
        tmp_path / "bad.fq",
        b"@r1\nACGT\nNOT_A_PLUS\n!!!!\n",
    )
    with pytest.raises(FastqParseError, match="separator"):
        FastqReader(fq).read()


def test_fastq_parse_error_seq_qual_mismatch(tmp_path: Path) -> None:
    fq = _write(
        tmp_path / "bad.fq",
        b"@r1\nACGT\n+\n!!!\n",
    )
    with pytest.raises(FastqParseError, match="length mismatch"):
        FastqReader(fq).read()
