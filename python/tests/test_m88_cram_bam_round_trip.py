"""M88 CRAM importer + BAM/CRAM exporter acceptance tests.

The whole file is skipped when ``samtools`` is not on PATH so CI
runners without the binary stay green (HANDOFF.md Gotcha §158).

Each writer test writes a temp BAM/CRAM under ``tmp_path``, then
reads it back through M87's :class:`~ttio.importers.bam.BamReader`
or M88's :class:`~ttio.importers.cram.CramReader` and compares
field-by-field. Per HANDOFF §6.1 the @PG chain is allowed to grow
on each round trip (samtools injects its own @PG entries) so we
never assert on byte-equality of the BAM/CRAM bytes themselves —
only on the parsed-back parallel arrays.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest


def _samtools_on_path() -> bool:
    return shutil.which("samtools") is not None


pytestmark = pytest.mark.skipif(
    not _samtools_on_path(),
    reason="samtools not installed; M88 round-trip tests require it on PATH",
)


FIXTURE_DIR = Path(__file__).parent / "fixtures" / "genomic"
SAM_PATH = FIXTURE_DIR / "m88_test.sam"
BAM_PATH = FIXTURE_DIR / "m88_test.bam"
CRAM_PATH = FIXTURE_DIR / "m88_test.cram"
REFERENCE_PATH = FIXTURE_DIR / "m88_test_reference.fa"


# Expected post-sort coordinate-order from the fixture (chr1 by pos
# ascending, then chr2). The fixture is already sorted in the SAM
# source, so this is just the SAM order.
EXPECTED_READ_NAMES = ["m88r001", "m88r002", "m88r003", "m88r004", "m88r005"]
EXPECTED_POSITIONS = [101, 201, 301, 401, 201]
EXPECTED_CHROMOSOMES = ["chr1", "chr1", "chr1", "chr1", "chr2"]
EXPECTED_FLAGS = [0, 0, 0, 0, 0]
EXPECTED_MAPQ = [60, 60, 60, 60, 60]
EXPECTED_CIGARS = ["100M", "100M", "100M", "100M", "100M"]


def _build_synthetic_run(*, mate_chrom_same: bool = False,
                          mate_pos_neg_one: bool = False):
    """Return a small WrittenGenomicRun for writer tests.

    Keeps the topology dead simple: 3 reads, all aligned to chr1
    against the M88 synthetic reference. Optional flags toggle the
    edge-cases needed by §136 / §138 verification tests.
    """
    from ttio.enums import AcquisitionMode
    from ttio.written_genomic_run import WrittenGenomicRun

    seq_chunk = b"ACGT" * 25  # 100 bases — matches m88_test_reference chr1
    qual_chunk = b"I" * 100

    sequences = np.frombuffer(seq_chunk * 3, dtype=np.uint8).copy()
    qualities = np.frombuffer(qual_chunk * 3, dtype=np.uint8).copy()
    offsets = np.array([0, 100, 200], dtype=np.uint64)
    lengths = np.array([100, 100, 100], dtype=np.uint32)

    if mate_chrom_same:
        mate_chroms = ["chr1", "chr1", "chr1"]
    else:
        mate_chroms = ["*", "*", "*"]

    if mate_pos_neg_one:
        mate_positions = np.array([-1, -1, -1], dtype=np.int64)
    else:
        mate_positions = np.array([0, 0, 0], dtype=np.int64)

    return WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri="chr1",
        platform="ILLUMINA",
        sample_name="M88_SYNTH",
        positions=np.array([101, 201, 301], dtype=np.int64),
        mapping_qualities=np.array([60, 60, 60], dtype=np.uint8),
        flags=np.array([0, 0, 0], dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=["100M", "100M", "100M"],
        read_names=["s001", "s002", "s003"],
        mate_chromosomes=mate_chroms,
        mate_positions=mate_positions,
        template_lengths=np.array([0, 0, 0], dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr1"],
    )


# ----------------------------------------------------------------------
# 1: CRAM read full
# ----------------------------------------------------------------------
def test_cram_read_full():
    """CramReader on the M88 fixture returns 5 reads with expected fields."""
    from ttio.importers.cram import CramReader

    run = CramReader(CRAM_PATH, REFERENCE_PATH).to_genomic_run()
    assert len(run.read_names) == 5
    assert run.read_names == EXPECTED_READ_NAMES
    assert list(run.positions) == EXPECTED_POSITIONS
    assert run.chromosomes == EXPECTED_CHROMOSOMES
    assert list(run.flags) == EXPECTED_FLAGS
    assert list(run.mapping_qualities) == EXPECTED_MAPQ
    assert run.cigars == EXPECTED_CIGARS
    assert run.sample_name == "M88_TEST_SAMPLE"
    assert run.platform == "ILLUMINA"


# ----------------------------------------------------------------------
# 2: CRAM region filter
# ----------------------------------------------------------------------
def test_cram_read_region():
    """Region filter on chr1 returns only the chr1 reads."""
    from ttio.importers.cram import CramReader

    run = CramReader(CRAM_PATH, REFERENCE_PATH).to_genomic_run(
        region="chr1:100-500"
    )
    assert run.read_names == ["m88r001", "m88r002", "m88r003", "m88r004"]
    for chrom in run.chromosomes:
        assert chrom == "chr1"


# ----------------------------------------------------------------------
# 3: BAM write basic round-trip
# ----------------------------------------------------------------------
def test_bam_write_basic(tmp_path):
    from ttio.exporters.bam import BamWriter
    from ttio.importers.bam import BamReader

    src = BamReader(BAM_PATH).to_genomic_run()
    out = tmp_path / "round_trip.bam"
    BamWriter(out).write(src)

    back = BamReader(out).to_genomic_run()
    assert sorted(back.read_names) == sorted(src.read_names)
    assert len(back.read_names) == len(src.read_names)

    # Compare per-read by QNAME (sort-by-coord may permute order).
    src_by_name = dict(zip(src.read_names, src.positions))
    back_by_name = dict(zip(back.read_names, back.positions))
    for name in src.read_names:
        assert back_by_name[name] == src_by_name[name], name


# ----------------------------------------------------------------------
# 4: BAM write unsorted preserves input order
# ----------------------------------------------------------------------
def test_bam_write_unsorted(tmp_path):
    from ttio.exporters.bam import BamWriter
    from ttio.importers.bam import BamReader

    src = _build_synthetic_run()
    out = tmp_path / "unsorted.bam"
    BamWriter(out).write(src, sort=False)

    back = BamReader(out).to_genomic_run()
    # Without sort, output read order matches input order.
    assert back.read_names == src.read_names


# ----------------------------------------------------------------------
# 5: BAM write with explicit provenance
# ----------------------------------------------------------------------
def test_bam_write_with_provenance(tmp_path):
    from ttio.exporters.bam import BamWriter
    from ttio.importers.bam import BamReader
    from ttio.provenance import ProvenanceRecord

    src = _build_synthetic_run()
    pr = ProvenanceRecord(
        timestamp_unix=0,
        software="my_tool",
        parameters={"CL": "my_tool --opt foo input.fq"},
    )
    out = tmp_path / "with_prov.bam"
    BamWriter(out).write(src, provenance_records=[pr])

    back = BamReader(out).to_genomic_run()
    softs = [p.software for p in back.provenance_records]
    assert "my_tool" in softs
    matching = [p for p in back.provenance_records if p.software == "my_tool"]
    assert "my_tool --opt foo input.fq" in matching[0].parameters.get("CL", "")


# ----------------------------------------------------------------------
# 6: CRAM write basic round-trip
# ----------------------------------------------------------------------
def test_cram_write_basic(tmp_path):
    from ttio.exporters.cram import CramWriter
    from ttio.importers.cram import CramReader

    src = _build_synthetic_run()
    out = tmp_path / "round_trip.cram"
    CramWriter(out, REFERENCE_PATH).write(src)

    back = CramReader(out, REFERENCE_PATH).to_genomic_run()
    assert sorted(back.read_names) == sorted(src.read_names)
    assert len(back.read_names) == len(src.read_names)
    # Sequence/quality buffers byte-identical (sort permutes order
    # for the per-read scalars but the buffers contents in
    # coordinate-sort order should be a permutation; here all reads
    # are the same so total bytes match exactly).
    assert bytes(back.sequences) == bytes(src.sequences)
    assert bytes(back.qualities) == bytes(src.qualities)


# ----------------------------------------------------------------------
# 7: CRAM write requires reference to read back
# ----------------------------------------------------------------------
def test_cram_write_with_reference(tmp_path):
    """A CRAM written with a reference cannot be decoded without one.

    samtools embeds a ``UR:`` tag pointing to the absolute path of
    the reference used at write time, and will silently fall back to
    that path when no ``--reference`` is supplied. To exercise the
    "reference is required" semantics deterministically we copy the
    reference into a tmp_path subdirectory, write the CRAM against
    the copy, then delete the copy before attempting to read.
    """
    import shutil as _shutil

    from ttio.exporters.cram import CramWriter
    from ttio.importers.bam import BamReader

    src = _build_synthetic_run()
    ref_dir = tmp_path / "refs"
    ref_dir.mkdir()
    ref_copy = ref_dir / "ref.fa"
    _shutil.copyfile(REFERENCE_PATH, ref_copy)

    out = tmp_path / "needs_ref.cram"
    CramWriter(out, ref_copy).write(src)

    # Yank the reference out from under samtools.
    ref_copy.unlink()
    fai = ref_copy.with_suffix(".fa.fai")
    if fai.exists():
        fai.unlink()

    # Try to read the CRAM via BamReader (which doesn't pass
    # --reference). With the reference deleted samtools fails. We
    # set REF_PATH=: to also disable the EBI MD5 fallback in case
    # samtools tries to resolve via ENA / a local cache.
    import os
    env = os.environ.copy()
    env["REF_PATH"] = ":"
    env["REF_CACHE"] = ":"

    proc = subprocess.run(
        ["samtools", "view", "-h", str(out)],
        capture_output=True, env=env, timeout=30,
    )
    assert proc.returncode != 0, (
        "samtools should have failed to read CRAM without reference; "
        f"stderr={proc.stderr!r}"
    )


# ----------------------------------------------------------------------
# 8: BAM -> GenomicRun -> BAM round trip
# ----------------------------------------------------------------------
def test_round_trip_bam_to_bam(tmp_path):
    from ttio.exporters.bam import BamWriter
    from ttio.importers.bam import BamReader

    src = BamReader(BAM_PATH).to_genomic_run()
    out = tmp_path / "rt.bam"
    BamWriter(out).write(src)

    back = BamReader(out).to_genomic_run()
    assert len(back.read_names) == len(src.read_names)
    assert sorted(back.read_names) == sorted(src.read_names)

    # Per-read field equality, indexed by QNAME so coordinate-sort
    # permutation doesn't matter.
    def _by_name(run, attr):
        return dict(zip(run.read_names, getattr(run, attr)))

    for attr in ("positions", "flags", "mapping_qualities",
                 "mate_positions", "template_lengths",
                 "cigars", "chromosomes", "mate_chromosomes"):
        s = _by_name(src, attr)
        b = _by_name(back, attr)
        for name in src.read_names:
            sv = s[name]
            bv = b[name]
            if hasattr(sv, "item"):
                sv = sv.item()
            if hasattr(bv, "item"):
                bv = bv.item()
            assert sv == bv, f"{attr} mismatch on {name}: src={sv} back={bv}"


# ----------------------------------------------------------------------
# 9: CRAM -> GenomicRun -> CRAM round trip
# ----------------------------------------------------------------------
def test_round_trip_cram_to_cram(tmp_path):
    from ttio.exporters.cram import CramWriter
    from ttio.importers.cram import CramReader

    src = CramReader(CRAM_PATH, REFERENCE_PATH).to_genomic_run()
    out = tmp_path / "rt.cram"
    CramWriter(out, REFERENCE_PATH).write(src)

    back = CramReader(out, REFERENCE_PATH).to_genomic_run()
    assert sorted(back.read_names) == sorted(src.read_names)
    assert len(back.read_names) == len(src.read_names)


# ----------------------------------------------------------------------
# 10: cross-format BAM <-> CRAM round trip
# ----------------------------------------------------------------------
def test_round_trip_cross_format(tmp_path):
    from ttio.exporters.bam import BamWriter
    from ttio.exporters.cram import CramWriter
    from ttio.importers.bam import BamReader
    from ttio.importers.cram import CramReader

    src = BamReader(BAM_PATH).to_genomic_run()
    cram_out = tmp_path / "from_bam.cram"
    CramWriter(cram_out, REFERENCE_PATH).write(src)

    via_cram = CramReader(cram_out, REFERENCE_PATH).to_genomic_run()

    bam_out = tmp_path / "back_to.bam"
    BamWriter(bam_out).write(via_cram)
    final = BamReader(bam_out).to_genomic_run()

    assert sorted(final.read_names) == sorted(src.read_names)
    assert len(final.read_names) == len(src.read_names)


# ----------------------------------------------------------------------
# 11: mate-chromosome collapse to '=' on write
# ----------------------------------------------------------------------
def test_mate_collapse_to_equals(tmp_path):
    """When mate_chromosome == chromosome, the SAM stream uses '='.

    Asserts on the writer's pre-samtools SAM text directly (samtools
    re-expands the ``=`` shorthand back to the chromosome name when
    decoding BAM via ``view -h``, masking the collapse in the
    on-disk file). The collapse is a writer-side normalisation per
    Binding Decision §136; what matters is that the SAM text TTI-O
    hands to samtools uses ``=``.
    """
    from ttio.exporters.bam import BamWriter

    src = _build_synthetic_run(mate_chrom_same=True)
    writer = BamWriter(tmp_path / "unused.bam")
    sam_text = writer._build_sam_text(src, [], sort=False)

    alignment_lines = [
        line for line in sam_text.splitlines()
        if line and not line.startswith("@")
    ]
    assert alignment_lines
    for line in alignment_lines:
        cols = line.split("\t")
        # Column 7 (0-indexed: 6) is RNEXT.
        assert cols[6] == "=", (
            f"Expected RNEXT='=' (collapse), got {cols[6]!r} in {line!r}"
        )


# ----------------------------------------------------------------------
# 12: mate position -1 mapped to 0 on write
# ----------------------------------------------------------------------
def test_mate_position_negative_one_to_zero(tmp_path):
    """mate_positions[i] == -1 in TTI-O is mapped to SAM '0' on write."""
    from ttio.exporters.bam import BamWriter

    src = _build_synthetic_run(mate_pos_neg_one=True)
    out = tmp_path / "pneg1.bam"
    BamWriter(out).write(src, sort=False)

    proc = subprocess.run(
        ["samtools", "view", str(out)],
        capture_output=True, text=True, timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    for line in proc.stdout.splitlines():
        if not line:
            continue
        cols = line.split("\t")
        # Column 8 (0-indexed: 7) is PNEXT.
        assert cols[7] == "0", (
            f"Expected PNEXT='0' (from -1 mapping), got {cols[7]!r}"
        )


# ----------------------------------------------------------------------
# 13: CramReader requires a reference path at construction
# ----------------------------------------------------------------------
def test_cram_reader_missing_reference():
    """CramReader's reference_fasta is a required positional arg."""
    from ttio.importers.cram import CramReader

    with pytest.raises(TypeError):
        CramReader(CRAM_PATH)  # type: ignore[call-arg]


# ----------------------------------------------------------------------
# 14: writer output is valid SAM that samtools can re-parse
# ----------------------------------------------------------------------
def test_writer_produces_valid_sam(tmp_path):
    from ttio.exporters.bam import BamWriter
    from ttio.importers.bam import BamReader

    src = BamReader(BAM_PATH).to_genomic_run()
    out = tmp_path / "valid.bam"
    BamWriter(out).write(src)

    # samtools view -h should succeed, returning header + alignments.
    proc = subprocess.run(
        ["samtools", "view", "-h", str(out)],
        capture_output=True, text=True, timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    header_lines = [line for line in lines if line.startswith("@")]
    align_lines = [line for line in lines if line and not line.startswith("@")]
    assert any(line.startswith("@HD") for line in header_lines)
    assert any(line.startswith("@SQ") for line in header_lines)
    assert len(align_lines) == len(src.read_names)
    # Each alignment line has at least 11 tab-separated columns.
    for line in align_lines:
        assert len(line.split("\t")) >= 11, line
