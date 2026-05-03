"""V4 cross-corpus byte-exact integration tests.

Phase 5 gate of the M94.Z Stage 2 plan: end-to-end through the Python
wrapper, V4 encoding produces a stream whose inner CRAM body is
byte-equal to the htscodecs reference encoder's output across all 4
corpora (chr22, WES, HG002 Illumina, HG002 PacBio HiFi).

This complements the C-level Phase 3 byte-equality test
(`native/tests/test_fqzcomp_qual_byte_equality.c`): Phase 3 confirmed
``ttio_fqzcomp_qual_compress`` byte-matches htscodecs's
``fqz_compress``; this test confirms the same property holds end-to-end
through the Python wrapper + V4 outer wire format.

Skipped automatically if either:
  * libttio_rans.so is not loadable (no V4 path), or
  * the htscodecs reference auto-tune driver is not built at
    ``tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune``.

Per-corpus runtime (-m integration): ~10-30s each (chr22 ~15s).
Marked ``integration`` so the default ``pytest`` run does not invoke
this; opt in with ``pytest -m integration``.
"""
from __future__ import annotations

import struct
import subprocess
from pathlib import Path

import numpy as np
import pytest

from ttio.codecs.fqzcomp_nx16_z import _HAVE_NATIVE_LIB, encode
from ttio.importers.bam import BamReader

REPO = Path("/home/toddw/TTI-O")
HTS_BIN = REPO / "tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune"

CORPORA = [
    ("chr22",          "data/genomic/na12878/na12878.chr22.lean.mapped.bam"),
    ("wes",            "data/genomic/na12878_wes/na12878_wes.chr22.bam"),
    ("hg002_illumina", "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"),
    ("hg002_pacbio",   "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"),
]

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not _HAVE_NATIVE_LIB, reason="V4 needs libttio_rans"),
    pytest.mark.skipif(
        not HTS_BIN.exists(),
        reason=f"htscodecs ref autotune driver not built at {HTS_BIN}",
    ),
]


def _strip_m94z_v4_header(blob: bytes) -> bytes:
    """Return the inner CRAM body from an M94.Z V4 stream.

    Wire format (matches ``native/src/m94z_v4_wire.c::ttio_m94z_v4_pack``):
      offset 0   magic              4 bytes  ``b"M94Z"``
      offset 4   version            1 byte   ``4``
      offset 5   flags              1 byte
      offset 6   num_qualities      8 bytes  uint64 LE
      offset 14  num_reads          8 bytes  uint64 LE
      offset 22  rlt_len            4 bytes  uint32 LE
      offset 26  rlt                rlt_len bytes
      offset 26+rlt_len   cram_len  4 bytes  uint32 LE
      offset 30+rlt_len   cram_body cram_len bytes
    """
    assert len(blob) >= 30, f"blob too short: {len(blob)} bytes"
    assert blob[:4] == b"M94Z", f"bad magic: {blob[:4]!r}"
    assert blob[4] == 4, f"expected V4, got version byte {blob[4]}"
    rlt_len = struct.unpack_from("<I", blob, 22)[0]
    body_len_off = 26 + rlt_len
    body_len = struct.unpack_from("<I", blob, body_len_off)[0]
    body_off = body_len_off + 4
    assert len(blob) == body_off + body_len, (
        f"V4 size mismatch: blob={len(blob)} expected="
        f"{body_off + body_len} (rlt_len={rlt_len}, body_len={body_len})"
    )
    return blob[body_off:body_off + body_len]


@pytest.mark.parametrize("name,bam_rel", CORPORA, ids=[c[0] for c in CORPORA])
def test_v4_byte_exact_vs_htscodecs(tmp_path, name, bam_rel):
    """Encode each corpus via the Python V4 path, strip the M94.Z V4
    outer header, and assert byte equality against htscodecs's
    auto-tune reference encoder run on the same raw inputs.
    """
    bam = REPO / bam_rel
    if not bam.exists():
        pytest.skip(f"corpus not present: {bam}")

    # Extract qualities + lengths + flags via the same BamReader path
    # used by both our codec and the C-level extraction script.
    run = BamReader(str(bam)).to_genomic_run(name="run")
    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp = [int(f) for f in run.flags]

    # ── Our encoder (Python → ctypes → V4 → fqzcomp_qual_compress) ──
    v4_blob = encode(qualities, read_lengths, revcomp, prefer_v4=True)
    our_body = _strip_m94z_v4_header(v4_blob)

    # ── htscodecs reference encoder (auto-tune mode) ────────────────
    # The driver expects:
    #   qual.bin   raw uint8 quality bytes
    #   lens.bin   uint32 LE per-read lengths
    #   flags.bin  uint32 LE per-read SAM flags
    qual_path = tmp_path / f"{name}_qual.bin"
    lens_path = tmp_path / f"{name}_lens.bin"
    flags_path = tmp_path / f"{name}_flags.bin"
    out_path = tmp_path / f"{name}_htscodecs.fqz"

    qual_path.write_bytes(qualities)
    np.asarray(read_lengths, dtype=np.uint32).tofile(str(lens_path))
    np.asarray(revcomp, dtype=np.uint32).tofile(str(flags_path))

    proc = subprocess.run(
        [str(HTS_BIN), str(qual_path), str(lens_path),
         str(flags_path), str(out_path)],
        capture_output=True,
    )
    assert proc.returncode == 0, (
        f"htscodecs ref autotune failed (rc={proc.returncode}):\n"
        f"stderr: {proc.stderr.decode(errors='replace')}"
    )
    hts_body = out_path.read_bytes()

    if our_body != hts_body:
        first_diff = next(
            (i for i in range(min(len(our_body), len(hts_body)))
             if our_body[i] != hts_body[i]),
            min(len(our_body), len(hts_body)),
        )
        pytest.fail(
            f"{name}: V4 inner CRAM body differs from htscodecs.\n"
            f"  our_body:       {len(our_body):,} bytes\n"
            f"  htscodecs_body: {len(hts_body):,} bytes\n"
            f"  qualities:      {len(qualities):,} bytes "
            f"({len(read_lengths):,} reads)\n"
            f"  first diff at offset {first_diff}"
        )
