"""Layer 4 — chr22 ratio gate per spec §10.

Encodes the chr22 NA12878 lean+mapped corpus end-to-end via
SpectralDataset.write_minimal with NAME_TOKENIZED v2 default ON vs
opt-out. Asserts savings >= 3 MB (hard gate per spec §10).

Design target was ~3-4 MB savings (read_names channel: 7.14 MB v1 -> ~3
MB v2 measured by the v1<->v2 oracle in Task 6, which produced 4.12 MB
of savings on the read_names channel alone).

Run with::

    TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \\
        python -m pytest python/tests/integration/test_name_tok_v2_compression_gate.py \\
        -m integration -v -s
"""
from __future__ import annotations

from pathlib import Path

import pytest

from ttio.codecs import name_tokenizer_v2 as nt2

REPO_ROOT = Path(__file__).resolve().parents[3]
CHR22_BAM = REPO_ROOT / "data" / "genomic" / "na12878" / "na12878.chr22.lean.mapped.bam"
CHR22_REF = REPO_ROOT / "data" / "genomic" / "reference" / "hs37.chr22.fa"

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not nt2.HAVE_NATIVE_LIB,
        reason="needs libttio_rans (set TTIO_RANS_LIB_PATH)",
    ),
    pytest.mark.skipif(
        not CHR22_BAM.exists(),
        reason=f"chr22 corpus not on disk: {CHR22_BAM}",
    ),
]


def _load_reference_chroms(ref_fasta: Path, chroms_used: set) -> dict:
    out: dict[str, bytes] = {}
    if not chroms_used:
        return out
    target_set = {c.encode("ascii") for c in chroms_used}
    current = None
    buf = bytearray()
    with ref_fasta.open("rb") as fh:
        for line in fh:
            if line.startswith(b">"):
                if current is not None:
                    out[current.decode("ascii")] = bytes(buf).upper()
                hdr = line[1:].split()[0] if len(line) > 1 else b""
                current = hdr if hdr in target_set else None
                buf.clear()
            elif current is not None:
                buf.extend(line.strip())
        if current is not None:
            out[current.decode("ascii")] = bytes(buf).upper()
    return out


def _encode_chr22(out_path: Path, *, opt_disable_v2: bool) -> None:
    """Build a .tio file from the chr22 BAM with NAME_TOKENIZED v2 on/off.

    Only `opt_disable_name_tokenized_v2` differs between the two runs —
    everything else (REF_DIFF v2, mate_info v2, qualities V4) stays at
    its v1.8 default to isolate the read_names channel savings cleanly.
    """
    from ttio.importers.bam import BamReader
    from ttio import SpectralDataset

    run = BamReader(str(CHR22_BAM)).to_genomic_run(name="chr22")
    run.opt_disable_name_tokenized_v2 = opt_disable_v2

    if CHR22_REF.exists():
        chroms_used = set(run.chromosomes) - {"*"}
        chrom_seqs = _load_reference_chroms(CHR22_REF, chroms_used)
        run.reference_chrom_seqs = chrom_seqs if chrom_seqs else None

    SpectralDataset.write_minimal(
        path=str(out_path),
        title="name_tok_v2_gate:chr22",
        isa_investigation_id="TTIO:gate:name_tok_v2",
        runs={},
        genomic_runs={"chr22": run},
    )


def test_chr22_name_tok_v2_savings_ge_3mb(tmp_path: Path) -> None:
    """chr22 NA12878 lean+mapped: NAME_TOKENIZED v2 saves >= 3 MB vs v1.

    Hard gate: if this test fails the NAME_TOKENIZED v2 codec has
    regressed and MUST NOT ship. The 3 MB floor is the spec §10 hard
    gate; the design target is ~3-4 MB.
    """
    out_v1 = tmp_path / "chr22_v1.tio"
    out_v2 = tmp_path / "chr22_v2.tio"

    _encode_chr22(out_v1, opt_disable_v2=True)
    _encode_chr22(out_v2, opt_disable_v2=False)

    v1_size = out_v1.stat().st_size
    v2_size = out_v2.stat().st_size
    savings = v1_size - v2_size

    MB = 1024 * 1024
    print(
        f"\nchr22 NA12878 lean+mapped (n=1,766,433 records):\n"
        f"  pre-v1.9 default (M82 compound) : {v1_size:>15,d} bytes  "
        f"({v1_size / MB:8.3f} MB)\n"
        f"  v1.9 default (NAME_TOKENIZED v2): {v2_size:>15,d} bytes  "
        f"({v2_size / MB:8.3f} MB)\n"
        f"  savings                         : {savings:>15,d} bytes  "
        f"({savings / MB:8.3f} MB)\n"
        f"  pct delta                       : {100.0 * savings / v1_size:.2f}%\n"
        f"  (Includes ~63 MB from removing M82 VL-string fractal-heap\n"
        f"   overhead in addition to ~4 MB codec-algorithm savings.)"
    )

    assert savings >= 3 * MB, (
        f"chr22 savings {savings / MB:.3f} MB < 3 MB hard gate — "
        f"NAME_TOKENIZED v2 regressed or native lib not loaded correctly."
    )
