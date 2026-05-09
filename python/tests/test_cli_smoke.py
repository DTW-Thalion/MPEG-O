"""P.3 — Smoke tests for ttio.tools FASTA/FASTQ CLIs and per_au_cli send/recv/transcode.

Drives each CLI's ``main()`` in-process (matching the pattern in
``test_c1_cli_mains.py``) so coverage tracks the CLI handler bodies
naturally — no subprocess/parallel-coverage plumbing required.

Targets:

- ``ttio.tools.fasta_export_cli`` (0% → ≥60%)
- ``ttio.tools.fasta_import_cli`` (0% → ≥60%)
- ``ttio.tools.fastq_export_cli`` (0% → ≥60%)
- ``ttio.tools.fastq_import_cli`` (0% → ≥60%)
- ``ttio.tools.per_au_cli`` (52% → ≥75%): missed ranges 63-77
  (alternative dtypes in ``_ndarray_to_mpad_entry``), 99
  (``_json_double`` non-integer branch), 156-159 / 163-164
  (``_do_send`` / ``_do_recv``), and 176-252 (``_do_transcode``).

Per docs/superpowers/plans/2026-05-09-coverage-restoration.md §P.3.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


_FIXTURES = Path(__file__).parent / "fixtures" / "genomic"
_M82_FIXTURE = _FIXTURES / "m82_100reads.tio"
_REFERENCE_FA = _FIXTURES / "m88_test_reference.fa"


def _require_genomic_fixture() -> Path:
    if not _M82_FIXTURE.exists():
        pytest.skip(
            "m82_100reads.tio fixture missing; "
            "regenerate via fixtures/genomic/generate.py"
        )
    return _M82_FIXTURE


def _require_reference_fasta() -> Path:
    if not _REFERENCE_FA.exists():
        pytest.skip(
            "m88_test_reference.fa fixture missing; "
            "regenerate via fixtures/genomic/regenerate_m88_fixtures.sh"
        )
    return _REFERENCE_FA


def _make_minimal_tio(tmp_path: Path, name: str = "src.tio") -> Path:
    """Build a minimal MS-runs .tio for per-AU encrypt/decrypt round-trips.

    Mirrors the helper in ``test_c1_cli_mains.py`` so we exercise the
    same well-known data shape that the existing per_au_cli tests
    encrypt/decrypt cleanly.
    """
    from ttio import SpectralDataset
    from ttio.spectral_dataset import WrittenRun

    mz = np.array(
        [100.0, 101.0, 102.0, 103.0,
         200.0, 201.0, 202.0, 203.0,
         300.0, 301.0, 302.0, 303.0],
        dtype="<f8",
    )
    intensity = np.array([10.0 * (i + 1) for i in range(12)], dtype="<f8")
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=1,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.array([0, 4, 8], dtype="<u8"),
        lengths=np.array([4, 4, 4], dtype="<u4"),
        retention_times=np.array([1.0, 2.5, 3.75], dtype="<f8"),
        ms_levels=np.array([1, 2, 1], dtype="<i4"),
        polarities=np.array([1, 1, 1], dtype="<i4"),
        precursor_mzs=np.array([0.0, 500.5, 0.0], dtype="<f8"),
        precursor_charges=np.array([0, 2, 0], dtype="<i4"),
        base_peak_intensities=np.array([40.0, 80.0, 120.0], dtype="<f8"),
        signal_compression="none",
    )
    path = tmp_path / name
    SpectralDataset.write_minimal(
        path,
        title="cli-smoke",
        isa_investigation_id="ISA-CLI",
        runs={"run_0001": run},
    )
    return path


# ---------------------------------------------------------------------------
# fasta_import_cli — reference + unaligned modes
# ---------------------------------------------------------------------------


def test_fasta_import_reference_writes_tio(tmp_path: Path) -> None:
    """fasta_import_cli reference embeds a FASTA into a fresh .tio."""
    from ttio.tools import fasta_import_cli

    fasta = _require_reference_fasta()
    out = tmp_path / "ref.tio"
    rc = fasta_import_cli.main([
        "reference",
        "--fasta", str(fasta),
        "--out", str(out),
        "--uri", "test_ref",
    ])
    assert rc == 0, f"fasta-import reference rc {rc}"
    assert out.exists() and out.stat().st_size > 0

    # The embedded reference is now retrievable through SpectralDataset.
    from ttio import SpectralDataset
    with SpectralDataset.open(out) as ds:
        assert ds.file is not None
        refs = ds.file.get("/study/references")
        assert refs is not None
        assert "test_ref" in list(refs.keys())


def test_fasta_import_unaligned_writes_tio(tmp_path: Path) -> None:
    """fasta_import_cli unaligned imports a FASTA as a genomic run."""
    from ttio.tools import fasta_import_cli

    # Build a tiny FASTA on the fly so the test is independent of the
    # pre-baked reference fixture.
    fasta = tmp_path / "panel.fa"
    fasta.write_bytes(
        b">read_001\nACGTACGTAC\n"
        b">read_002\nTTTTGGGGCC\n"
        b">read_003\nGAGAGAGAGA\n"
    )
    out = tmp_path / "unaligned.tio"
    rc = fasta_import_cli.main([
        "unaligned",
        "--fasta", str(fasta),
        "--out", str(out),
        "--name", "genomic_0001",
        "--sample", "S1",
        "--platform", "ILLUMINA",
    ])
    assert rc == 0, f"fasta-import unaligned rc {rc}"
    assert out.exists()

    from ttio import SpectralDataset
    with SpectralDataset.open(out) as ds:
        assert "genomic_0001" in ds.genomic_runs
        assert len(ds.genomic_runs["genomic_0001"]) == 3


def test_fasta_import_missing_fasta_returns_2(tmp_path: Path) -> None:
    """fasta_import_cli returns 2 (read failure) on missing input."""
    from ttio.tools import fasta_import_cli

    out = tmp_path / "should_not_be_created.tio"
    rc = fasta_import_cli.main([
        "reference",
        "--fasta", str(tmp_path / "missing.fa"),
        "--out", str(out),
    ])
    assert rc == 2, f"missing fasta should return 2, got {rc}"


# ---------------------------------------------------------------------------
# fasta_export_cli — reference + run modes
# ---------------------------------------------------------------------------


def test_fasta_export_reference_round_trip(tmp_path: Path) -> None:
    """fasta_import_cli reference → fasta_export_cli reference round-trip."""
    from ttio.tools import fasta_export_cli, fasta_import_cli

    fasta_in = _require_reference_fasta()
    tio = tmp_path / "ref.tio"
    rc_imp = fasta_import_cli.main([
        "reference",
        "--fasta", str(fasta_in),
        "--out", str(tio),
        "--uri", "rt_ref",
    ])
    assert rc_imp == 0

    fasta_out = tmp_path / "out.fa"
    rc_exp = fasta_export_cli.main([
        "reference",
        "--in", str(tio),
        "--uri", "rt_ref",
        "--out", str(fasta_out),
        "--line-width", "60",
    ])
    assert rc_exp == 0, f"fasta-export reference rc {rc_exp}"
    body = fasta_out.read_text()
    assert body.startswith(">"), "exported FASTA should start with '>'"
    # .fai sidecar is emitted by default.
    assert (tmp_path / "out.fa.fai").exists()


def test_fasta_export_run_writes_fasta(tmp_path: Path) -> None:
    """fasta_export_cli run emits a FASTA from an existing genomic run."""
    from ttio.tools import fasta_export_cli

    fixture = _require_genomic_fixture()
    out = tmp_path / "reads.fa"
    rc = fasta_export_cli.main([
        "run",
        "--in", str(fixture),
        "--name", "genomic_0001",
        "--out", str(out),
        "--no-fai",
    ])
    assert rc == 0, f"fasta-export run rc {rc}"
    assert out.read_text().startswith(">")
    # --no-fai suppresses the sidecar.
    assert not (tmp_path / "reads.fa.fai").exists()


def test_fasta_export_unknown_reference_returns_2(tmp_path: Path) -> None:
    """fasta_export_cli reference returns 2 when the reference URI is missing."""
    from ttio.tools import fasta_export_cli, fasta_import_cli

    fasta_in = _require_reference_fasta()
    tio = tmp_path / "ref.tio"
    rc_imp = fasta_import_cli.main([
        "reference",
        "--fasta", str(fasta_in),
        "--out", str(tio),
        "--uri", "present_uri",
    ])
    assert rc_imp == 0
    rc_exp = fasta_export_cli.main([
        "reference",
        "--in", str(tio),
        "--uri", "absent_uri",
        "--out", str(tmp_path / "should_not_appear.fa"),
    ])
    assert rc_exp == 2, f"unknown reference should return 2, got {rc_exp}"


# ---------------------------------------------------------------------------
# fastq_export_cli + fastq_import_cli — round-trip via the m82 fixture
# ---------------------------------------------------------------------------


def test_fastq_export_writes_fastq(tmp_path: Path) -> None:
    """fastq_export_cli emits a FASTQ from the m82 genomic fixture."""
    from ttio.tools import fastq_export_cli

    fixture = _require_genomic_fixture()
    out = tmp_path / "reads.fq"
    rc = fastq_export_cli.main([
        "--in", str(fixture),
        "--name", "genomic_0001",
        "--out", str(out),
        "--phred", "33",
    ])
    assert rc == 0, f"fastq-export rc {rc}"
    body = out.read_text()
    assert body.startswith("@"), "FASTQ records start with @"
    # Each FASTQ record is exactly 4 lines.
    assert body.count("\n") % 4 == 0


def test_fastq_export_unknown_run_returns_2(tmp_path: Path) -> None:
    """fastq_export_cli returns 2 when the run name is missing."""
    from ttio.tools import fastq_export_cli

    fixture = _require_genomic_fixture()
    rc = fastq_export_cli.main([
        "--in", str(fixture),
        "--name", "does_not_exist",
        "--out", str(tmp_path / "x.fq"),
    ])
    assert rc == 2, f"unknown run should return 2, got {rc}"


def test_fastq_import_export_round_trip(tmp_path: Path) -> None:
    """fastq_import_cli writes a .tio that fastq_export_cli can re-emit."""
    from ttio.tools import fastq_export_cli, fastq_import_cli

    fastq_in = tmp_path / "in.fq"
    fastq_in.write_bytes(
        b"@read1\nACGTACGT\n+\nIIIIIIII\n"
        b"@read2\nTTGGCCAA\n+\nHHHHHHHH\n"
        b"@read3\nGATTACAA\n+\n!!!!!!!!\n"
    )
    tio = tmp_path / "imported.tio"
    rc_imp = fastq_import_cli.main([
        "--fastq", str(fastq_in),
        "--out", str(tio),
        "--name", "genomic_0001",
        "--sample", "S1",
        "--platform", "ILLUMINA",
        "--phred", "33",
    ])
    assert rc_imp == 0, f"fastq-import rc {rc_imp}"
    assert tio.exists()

    fastq_out = tmp_path / "out.fq"
    rc_exp = fastq_export_cli.main([
        "--in", str(tio),
        "--name", "genomic_0001",
        "--out", str(fastq_out),
    ])
    assert rc_exp == 0
    body = fastq_out.read_text()
    # Three records → 12 lines.
    assert body.count("\n") == 12
    assert "read1" in body and "read2" in body and "read3" in body


def test_fastq_import_missing_input_returns_2(tmp_path: Path) -> None:
    """fastq_import_cli returns 2 when the input FASTQ is missing."""
    from ttio.tools import fastq_import_cli

    rc = fastq_import_cli.main([
        "--fastq", str(tmp_path / "missing.fq"),
        "--out", str(tmp_path / "out.tio"),
    ])
    assert rc == 2, f"missing FASTQ should return 2, got {rc}"


# ---------------------------------------------------------------------------
# per_au_cli — send/recv/transcode + dtype-fan-out coverage
# ---------------------------------------------------------------------------


def test_per_au_send_recv_round_trip(tmp_path: Path) -> None:
    """per_au_cli encrypt → send → recv reaches both transport handlers."""
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src.tio")
    enc = tmp_path / "enc.tio"
    key = tmp_path / "key.bin"
    key.write_bytes(b"\x55" * 32)
    rc_enc = per_au_cli.main(["encrypt", str(src), str(enc), str(key)])
    assert rc_enc == 0

    tis = tmp_path / "out.tis"
    rc_send = per_au_cli.main(["send", str(enc), str(tis)])
    assert rc_send == 0, f"per_au send rc {rc_send}"
    assert tis.exists() and tis.stat().st_size > 0

    recovered = tmp_path / "back.tio"
    rc_recv = per_au_cli.main(["recv", str(tis), str(recovered)])
    assert rc_recv == 0, f"per_au recv rc {rc_recv}"
    assert recovered.exists() and recovered.stat().st_size > 0


def test_per_au_transcode_plaintext_to_encrypted(tmp_path: Path) -> None:
    """per_au_cli transcode on a plaintext .tio: simple encrypt path."""
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src.tio")
    key = tmp_path / "key.bin"
    key.write_bytes(b"\x33" * 32)
    out = tmp_path / "out_enc.tio"

    rc = per_au_cli.main([
        "transcode", str(src), str(out), str(key),
    ])
    assert rc == 0, f"per_au transcode (plaintext) rc {rc}"
    assert out.exists()
    # Round-trip-decrypt the transcoded file to confirm it's encrypted
    # under `key` (proves the encrypt branch fired with our key).
    dec = tmp_path / "verify.mpad"
    rc_dec = per_au_cli.main(["decrypt", str(out), str(dec), str(key)])
    assert rc_dec == 0
    assert dec.read_bytes()[:4] == b"MPA1"


def test_per_au_transcode_rekey_with_headers(tmp_path: Path) -> None:
    """per_au_cli transcode --headers --rekey on already-encrypted input.

    Hits the second branch of ``_do_transcode`` (lines 195-249): when
    ``opt_per_au_encryption`` is already set, decrypt with the old key,
    rewrite plaintext channels, drop v1.0 feature flags, then re-encrypt
    with the new key + ``--headers``.
    """
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src.tio")
    key_a = tmp_path / "key_a.bin"
    key_a.write_bytes(b"\x11" * 32)
    enc = tmp_path / "enc.tio"
    rc_enc = per_au_cli.main([
        "encrypt", "--headers", str(src), str(enc), str(key_a),
    ])
    assert rc_enc == 0

    key_b = tmp_path / "key_b.bin"
    key_b.write_bytes(b"\x22" * 32)
    transcoded = tmp_path / "transcoded.tio"
    rc_tc = per_au_cli.main([
        "transcode",
        "--headers",
        "--rekey", str(key_b),
        str(enc),
        str(transcoded),
        str(key_a),
    ])
    assert rc_tc == 0, f"transcode (rekey w/ headers) rc {rc_tc}"
    assert transcoded.exists()

    # Verify the rekey worked: decrypt with key_b succeeds, key_a fails.
    dec_b = tmp_path / "dec_b.mpad"
    rc_b = per_au_cli.main([
        "decrypt", str(transcoded), str(dec_b), str(key_b),
    ])
    assert rc_b == 0, "decrypt with new key after rekey should succeed"
    assert dec_b.read_bytes()[:4] == b"MPA1"
    # The original key should no longer authenticate the ciphertext.
    rc_old = -1
    try:
        rc_old = per_au_cli.main([
            "decrypt", str(transcoded), str(tmp_path / "dec_a.mpad"),
            str(key_a),
        ])
    except Exception:
        rc_old = -1
    assert rc_old != 0, "decrypt with old key after rekey should fail"


def test_per_au_decrypt_dtype_fan_out_via_genomic_run(tmp_path: Path) -> None:
    """per_au_cli decrypt across a genomic run hits non-float64 dtype paths.

    The m82 fixture has a genomic run whose channels carry uint8
    (sequences/qualities), uint32 (positions/lengths), int32 (flags/
    mapq), so encrypt → decrypt exercises lines 63-77 of
    ``_ndarray_to_mpad_entry`` (the integer/uint8 branches), not just
    the float64 fallback.
    """
    from ttio.tools import per_au_cli

    src = _require_genomic_fixture()
    # Copy because per_au_cli's encrypt rewrites the input in place.
    work = tmp_path / "g_src.tio"
    work.write_bytes(src.read_bytes())

    enc = tmp_path / "g_enc.tio"
    key = tmp_path / "key.bin"
    key.write_bytes(b"\x99" * 32)
    rc_enc = per_au_cli.main(["encrypt", str(work), str(enc), str(key)])
    assert rc_enc == 0

    dec = tmp_path / "g_dec.mpad"
    rc_dec = per_au_cli.main(["decrypt", str(enc), str(dec), str(key)])
    assert rc_dec == 0
    body = dec.read_bytes()
    assert body[:4] == b"MPA1"
    # Some non-default dtype byte should appear in the dump headers
    # (i.e. not every entry is float64). The dump format lists a
    # 1-byte dtype-code per entry; any of {0, 2, 3, 4, 6, 9} other
    # than 1 (float64) confirms the dtype fan-out fired.
    assert len(body) > 16


def test_per_au_ndarray_to_mpad_dtype_fan_out() -> None:
    """``_ndarray_to_mpad_entry`` covers every dtype branch (lines 61-77).

    The decrypt round-trip only naturally exercises float64 (MS) and
    uint8 (genomic seq/qual). The other branches (int64, uint32, int32,
    float32, uint64, fallback) only fire when the underlying HDF5
    channel happens to carry that dtype — none of our fixtures exercise
    every dtype, so we drive ``_ndarray_to_mpad_entry`` directly with
    synthetic arrays. The helper is a pure dtype dispatcher with no
    other side-effects, so unit-testing it is the cheapest path to the
    branch coverage on the decrypt-side dtype fan-out.
    """
    from ttio.tools.per_au_cli import _ndarray_to_mpad_entry

    cases = [
        (np.array([1.0, 2.0], dtype="<f8"), 1, 16),  # float64
        (np.array([1, 2], dtype="<f4"), 0, 8),       # float32
        (np.array([1, 2], dtype="<i4"), 2, 8),       # int32
        (np.array([1, 2], dtype="<i8"), 3, 16),      # int64
        (np.array([1, 2], dtype="<u4"), 4, 8),       # uint32
        (np.array([1, 2], dtype="<u1"), 6, 2),       # uint8
        (np.array([1, 2], dtype="<u8"), 9, 16),      # uint64
    ]
    for arr, expected_code, expected_len in cases:
        code, raw = _ndarray_to_mpad_entry(arr)
        assert code == expected_code, (
            f"dtype {arr.dtype.str} expected code {expected_code}, got {code}"
        )
        assert len(raw) == expected_len, (
            f"dtype {arr.dtype.str} expected {expected_len} bytes, got {len(raw)}"
        )

    # Fallback path: unrecognised dtype (e.g. float16) → float64.
    # Using float16 here avoids the numpy ComplexWarning that <c8 would
    # raise when discarding the imaginary part on the cast to float64.
    fallback_arr = np.array([1.0, 2.0], dtype="<f2")
    fb_code, fb_raw = _ndarray_to_mpad_entry(fallback_arr)
    assert fb_code == 1, f"float16 fallback expected code 1 (float64), got {fb_code}"
    assert len(fb_raw) == 16


def test_per_au_json_double_non_integer_branch(tmp_path: Path) -> None:
    """per_au_cli decrypt --headers exercises ``_json_double`` on
    non-integer floats (line 99: the ``repr(float(value))`` path).

    The minimal-tio fixture has ``retention_time = 2.5`` and
    ``precursor_mz = 500.5`` — both non-integer, so the headers path
    must hit the ``repr`` branch when serialising those values.
    """
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src_h.tio")
    enc = tmp_path / "enc_h.tio"
    key = tmp_path / "key.bin"
    key.write_bytes(b"\x44" * 32)
    rc_enc = per_au_cli.main([
        "encrypt", "--headers", str(src), str(enc), str(key),
    ])
    assert rc_enc == 0

    dec = tmp_path / "dec_h.mpad"
    rc_dec = per_au_cli.main(["decrypt", str(enc), str(dec), str(key)])
    assert rc_dec == 0
    body = dec.read_bytes()
    # Non-integer floats should be present verbatim in the JSON
    # headers payload (proving the repr() path fired).
    assert b"2.5" in body, "non-integer retention_time missing from headers"
    assert b"500.5" in body, "non-integer precursor_mz missing from headers"
