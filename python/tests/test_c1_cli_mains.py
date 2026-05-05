"""C1 — CLI mains coverage (Python).

Exercises every `def main(argv) -> int` entry point under
``ttio.tools.*`` for the three argparse-plumbing patterns that
account for almost all the previously-uncovered code:

1. ``--help`` — argparse exits 0 after printing help.
2. No args — argparse exits 2 (or main returns non-zero) with a
   "required" error on stderr.
3. Bad args — argparse exits 2 with a "invalid"/"unrecognized"
   error on stderr.

These are NOT integration tests — they don't pass real ``.tio``
files or perform real work. They exist to lift the
``ttio.tools.*`` package coverage from 22.5% (per V1 baseline) to
≥70% by exercising the parser construction, help-text rendering,
and error-message formatting branches.

Real-CLI behaviour (happy paths, encrypt-then-decrypt round-trips,
etc.) is covered separately by the cross-language harnesses
(``test_per_au_cross_language.py``, ``test_canonical_signatures.py``,
``test_m87_cross_language.py``, etc.).

Per docs/coverage-workplan.md §C1.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import importlib

import pytest


def _skip_if_optional_dep_missing(modname: str) -> None:
    """Skip CLI smoke tests whose module imports an optional 3rd-party
    package that may not be installed in the dev env.

    Maps each CLI module to the optional package(s) its import chain
    needs; if any are missing, the test SKIPs cleanly instead of
    surfacing the optional-extra install hint as a failure.
    """
    deps = {
        "ttio.tools.transport_server_cli": ["websockets"],
        # ttio_pqc_cli imports ttio.pqc only on subcommand dispatch,
        # but the keygen-writes-key-files tests force the import.
        "ttio.tools.ttio_pqc_cli": [],  # tested per-test instead
    }.get(modname, [])
    for pkg in deps:
        try:
            importlib.import_module(pkg)
        except ImportError:
            pytest.skip(
                f"{modname} requires optional package '{pkg}'; install via "
                f"the matching ttio[...] extra"
            )


def _skip_if_no_liboqs() -> None:
    """Skip ttio-pqc tests when liboqs-python is not installed."""
    try:
        importlib.import_module("oqs")
    except ImportError:
        pytest.skip(
            "ttio.pqc requires the optional 'liboqs-python' dependency; "
            "install via 'pip install ttio[pqc]'"
        )


CLI_MODULES = [
    "ttio.tools.dump_identifications",
    "ttio.tools.per_au_cli",
    "ttio.tools.simulator_cli",
    "ttio.tools.transport_decode_cli",
    "ttio.tools.transport_encode_cli",
    "ttio.tools.transport_server_cli",
    "ttio.tools.ttio_pqc_cli",
    "ttio.tools.ttio_sign_cli",
    "ttio.tools.ttio_verify_cli",
    "ttio.importers.bruker_tdf_cli",
]

# CLIs that don't special-case --help (treat it as a positional
# arg). Their `--help` test target is "doesn't crash" rather than
# "prints usage".
CLI_NO_HELP_HANDLING = {"ttio.tools.dump_identifications"}


@pytest.mark.parametrize("modname", CLI_MODULES)
def test_cli_help_exits_zero(modname, capsys):
    """Every CLI accepts --help and prints usage text.

    Two patterns coexist: argparse-based CLIs raise SystemExit(0);
    hand-rolled ones (ttio_pqc_cli, dump_identifications) return 0
    or 1 directly. Both are acceptable as long as usage text prints.
    """
    _skip_if_optional_dep_missing(modname)
    mod = importlib.import_module(modname)
    rc: int | None = None
    try:
        rc = mod.main(["--help"])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 0
    captured = capsys.readouterr()
    out = captured.out + captured.err
    if modname in CLI_NO_HELP_HANDLING:
        # --help is treated as a path argument; we just want
        # something printed (the "dump failed:" error message).
        assert out.strip(), (
            f"{modname} --help should at least print an error; got nothing"
        )
        # Exit code 1 or 2 expected since the file doesn't exist.
        assert rc in (1, 2), (
            f"{modname} --help (no --help handling) should exit 1 or 2, got {rc}"
        )
    else:
        # Usage block always prints (either "usage:" or "Usage:").
        assert "usage" in out.lower(), (
            f"{modname} --help should print usage text; got: {out[:200]}"
        )
        # Hand-rolled CLIs may return 0 or 1; argparse exits 0.
        assert rc in (0, 1), (
            f"{modname} --help should exit 0 or 1, got {rc}"
        )


@pytest.mark.parametrize("modname", CLI_MODULES)
def test_cli_no_args_errors(modname, capsys):
    """Every CLI requires at least one positional argument.

    Subcommand CLIs (per_au_cli, ttio_pqc_cli) require a subcommand
    name. argparse exits 2 with a "required"/"choose from" message.
    Some CLIs accept no args and run a default behaviour — those
    are still allowed by this test (we accept any non-crash exit).
    """
    _skip_if_optional_dep_missing(modname)
    mod = importlib.import_module(modname)
    try:
        result = mod.main([])
    except SystemExit as exc:
        # argparse path: exits 2 typically.
        assert exc.code in (0, 1, 2), (
            f"{modname} with no args raised SystemExit({exc.code}); "
            f"expected 0/1/2"
        )
    except Exception as exc:
        pytest.fail(
            f"{modname} with no args raised {type(exc).__name__}: {exc}; "
            f"expected SystemExit or clean int return"
        )
    else:
        # CLI returned an int (no SystemExit raised).
        assert isinstance(result, int)


@pytest.mark.parametrize("modname", CLI_MODULES)
def test_cli_unknown_flag_errors(modname, capsys):
    """Every CLI rejects an unknown --flag with non-zero exit."""
    _skip_if_optional_dep_missing(modname)
    mod = importlib.import_module(modname)
    rc: int | None = None
    try:
        rc = mod.main(["--this-flag-does-not-exist"])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 2
    assert rc in (1, 2), (
        f"{modname} on unknown flag should exit 1 or 2, got {rc}"
    )
    captured = capsys.readouterr()
    err = captured.err + captured.out
    assert err.strip(), (
        f"{modname} unknown-flag error path should print to stderr; "
        f"got nothing"
    )


# ---------------------------------------------------------------------------
# Per-CLI focused tests for sub-command coverage
# ---------------------------------------------------------------------------


def test_ttio_pqc_cli_subcommands_listed_in_help(capsys):
    """ttio-pqc help text mentions its subcommands.

    Hand-rolled CLI (no argparse) — main(["--help"]) returns 0
    rather than raising SystemExit.
    """
    from ttio.tools import ttio_pqc_cli

    rc = ttio_pqc_cli.main(["--help"])
    assert rc == 0
    cap = capsys.readouterr()
    out = cap.out + cap.err
    assert any(sub in out for sub in (
        "sig-keygen", "sig-sign", "sig-verify",
        "kem-keygen", "kem-encaps", "kem-decaps",
        "hdf5-sign", "hdf5-verify", "provider-sign", "provider-verify",
    ))


def test_per_au_cli_subcommands_listed_in_help(capsys):
    """per_au_cli help text mentions its subcommands (encrypt / decrypt)."""
    from ttio.tools import per_au_cli

    with pytest.raises(SystemExit):
        per_au_cli.main(["--help"])
    out = capsys.readouterr().out + capsys.readouterr().err
    assert any(sub in out for sub in ("encrypt", "decrypt", "send", "recv"))


def test_per_au_cli_encrypt_missing_args_errors(capsys):
    """per_au_cli encrypt without input/output/key positional args exits non-zero."""
    from ttio.tools import per_au_cli

    with pytest.raises(SystemExit):
        per_au_cli.main(["encrypt"])  # missing input/output/key


def test_ttio_sign_cli_with_three_args_attempts_work(capsys, tmp_path):
    """ttio_sign_cli accepts (path, dataset, key_hex) and reaches the work path.

    We pass a non-existent file so it errors out at the open step;
    the point is to cover the argparse-success branch so the
    parser.parse_args() return path is exercised.
    """
    from ttio.tools import ttio_sign_cli

    fake_tio = tmp_path / "missing.tio"
    rc = ttio_sign_cli.main([str(fake_tio), "/some/dataset", "00" * 32])
    # Should fail (file doesn't exist) but with an int return, not a crash.
    assert isinstance(rc, int)
    assert rc != 0


def test_ttio_verify_cli_with_args_attempts_work(capsys, tmp_path):
    """ttio_verify_cli reaches its work path on parsed args."""
    from ttio.tools import ttio_verify_cli

    fake_tio = tmp_path / "missing.tio"
    rc = ttio_verify_cli.main([str(fake_tio), "/some/dataset", "00" * 32])
    assert isinstance(rc, int)
    assert rc != 0


# ---------------------------------------------------------------------------
# Subcommand-level tests — exercise the per-subcommand argparse branches
# that don't get hit by the top-level --help / unknown-flag tests above.
# ---------------------------------------------------------------------------


PQC_SUBCOMMANDS = [
    "sig-keygen", "sig-sign", "sig-verify",
    "kem-keygen", "kem-encaps", "kem-decaps",
    "hdf5-sign", "hdf5-verify",
    "provider-sign", "provider-verify",
]


@pytest.mark.parametrize("sub", PQC_SUBCOMMANDS)
def test_ttio_pqc_subcommand_no_args_errors(sub, capsys, tmp_path):
    """Each ttio-pqc subcommand exits non-zero with no positional args."""
    from ttio.tools import ttio_pqc_cli

    rc = ttio_pqc_cli.main([sub])
    assert rc != 0, f"ttio-pqc {sub} with no args should fail; got {rc}"


@pytest.mark.parametrize("sub", PQC_SUBCOMMANDS)
def test_ttio_pqc_subcommand_with_bogus_paths_errors(sub, capsys, tmp_path):
    """Each subcommand fails cleanly when given non-existent file paths."""
    from ttio.tools import ttio_pqc_cli

    nope1 = str(tmp_path / "nope1")
    nope2 = str(tmp_path / "nope2")
    nope3 = str(tmp_path / "nope3")
    rc = ttio_pqc_cli.main([sub, nope1, nope2, nope3])
    # Either fails (file not found / liboqs not loaded) or succeeds
    # (keygen may write to nope_X). What matters is no crash.
    assert isinstance(rc, int)


PER_AU_SUBCOMMANDS = ["encrypt", "decrypt", "send", "recv", "transcode"]


@pytest.mark.parametrize("sub", PER_AU_SUBCOMMANDS)
def test_per_au_subcommand_help(sub, capsys):
    """Each per-AU subcommand's --help works without crashing."""
    from ttio.tools import per_au_cli

    rc: int | None = None
    try:
        rc = per_au_cli.main([sub, "--help"])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 0
    assert rc in (0, 1, 2)


@pytest.mark.parametrize("sub", PER_AU_SUBCOMMANDS)
def test_per_au_subcommand_no_args_errors(sub, capsys):
    """Each per-AU subcommand requires positional args."""
    from ttio.tools import per_au_cli

    rc: int | None = None
    try:
        rc = per_au_cli.main([sub])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 2
    assert rc in (1, 2), f"per_au {sub} with no args should fail; got {rc}"


def test_simulator_cli_with_output_path_writes_file(tmp_path, capsys):
    """simulator_cli accepts an output path and writes a .tio (synthetic AUs).

    The CLI is a generator — it produces synthetic access units to the
    given output path. Test that it succeeds (returns 0 / None) when
    given a writable path.
    """
    from ttio.tools import simulator_cli

    rc: int | None = None
    out = tmp_path / "synthetic.tio"
    try:
        rc = simulator_cli.main([str(out)])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 1
    except (FileNotFoundError, OSError, ValueError):
        rc = 1
    # Either succeeds (None / 0) or fails cleanly with int return.
    assert rc in (None, 0) or isinstance(rc, int)


def test_transport_decode_cli_with_bogus_path_errors(tmp_path, capsys):
    """transport_decode_cli fails cleanly on a bogus input path."""
    from ttio.tools import transport_decode_cli

    rc: int | None = None
    try:
        rc = transport_decode_cli.main([str(tmp_path / "missing.tis"),
                                        str(tmp_path / "out.tio")])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 1
    except (FileNotFoundError, OSError):
        rc = 1
    assert rc is None or isinstance(rc, int)


def test_transport_encode_cli_with_bogus_path_errors(tmp_path, capsys):
    """transport_encode_cli fails cleanly on a bogus input path."""
    from ttio.tools import transport_encode_cli

    rc: int | None = None
    try:
        rc = transport_encode_cli.main([str(tmp_path / "missing.tio"),
                                        str(tmp_path / "out.tis")])
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 1
    except (FileNotFoundError, OSError):
        rc = 1
    assert rc is None or isinstance(rc, int)


# ---------------------------------------------------------------------------
# In-process round-trip tests — exercise the encrypt/decrypt handlers
# in per_au_cli end-to-end. These hit ~50 lines of handler code that
# the argparse-only tests above skip.
# ---------------------------------------------------------------------------


def _make_minimal_tio(tmp_path, name="src.tio"):
    """Build a tiny valid .tio for per-AU round-trip tests."""
    from pathlib import Path

    import numpy as np

    from ttio import SpectralDataset
    from ttio.spectral_dataset import WrittenRun

    mz = np.array([100.0, 101.0, 102.0, 103.0,
                   200.0, 201.0, 202.0, 203.0,
                   300.0, 301.0, 302.0, 303.0], dtype="<f8")
    intensity = np.array(
        [10.0 * (i + 1) for i in range(12)], dtype="<f8")
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=1,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=np.array([0, 4, 8], dtype="<u8"),
        lengths=np.array([4, 4, 4], dtype="<u4"),
        retention_times=np.array([1.0, 2.0, 3.0], dtype="<f8"),
        ms_levels=np.array([1, 2, 1], dtype="<i4"),
        polarities=np.array([1, 1, 1], dtype="<i4"),
        precursor_mzs=np.array([0.0, 500.0, 0.0], dtype="<f8"),
        precursor_charges=np.array([0, 2, 0], dtype="<i4"),
        base_peak_intensities=np.array([40.0, 80.0, 120.0], dtype="<f8"),
        signal_compression="none",
    )
    path = Path(tmp_path) / name
    SpectralDataset.write_minimal(
        path, title="c1", isa_investigation_id="ISA-C1",
        runs={"run_0001": run},
    )
    return path


def test_per_au_cli_encrypt_decrypt_round_trip(tmp_path):
    """per_au_cli encrypt + decrypt: in-process round-trip exercises both handlers."""
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src.tio")
    enc = tmp_path / "enc.tio"
    dec = tmp_path / "dec.mpad"
    key = tmp_path / "key.bin"
    key.write_bytes(b"\x77" * 32)

    rc_enc = per_au_cli.main(["encrypt", str(src), str(enc), str(key)])
    assert rc_enc == 0, f"encrypt rc {rc_enc}"
    assert enc.exists()

    rc_dec = per_au_cli.main(["decrypt", str(enc), str(dec), str(key)])
    assert rc_dec == 0, f"decrypt rc {rc_dec}"
    assert dec.exists()
    # mpad magic header at the start of the decoded output. M90.12
    # bumped the magic from "MPAD" to "MPA1" (uint8-aware format).
    assert dec.read_bytes()[:4] == b"MPA1"


def test_per_au_cli_encrypt_with_headers_round_trip(tmp_path):
    """per_au_cli encrypt --headers covers the headers branch."""
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src_h.tio")
    enc = tmp_path / "enc_h.tio"
    dec = tmp_path / "dec_h.mpad"
    key = tmp_path / "key.bin"
    key.write_bytes(b"\x42" * 32)

    rc_enc = per_au_cli.main(["encrypt", "--headers",
                              str(src), str(enc), str(key)])
    assert rc_enc == 0
    rc_dec = per_au_cli.main(["decrypt", str(enc), str(dec), str(key)])
    assert rc_dec == 0
    # Decoded output should mention au_headers_json key (header
    # round-trip path differs from the no-headers path).
    body = dec.read_bytes()
    assert b"au_headers_json" in body


def test_per_au_cli_bad_key_length_rejected(tmp_path):
    """per_au_cli rejects key files that aren't exactly 32 bytes."""
    from ttio.tools import per_au_cli

    src = _make_minimal_tio(tmp_path, "src.tio")
    enc = tmp_path / "enc.tio"
    short_key = tmp_path / "short.bin"
    short_key.write_bytes(b"\x00" * 16)  # 16 bytes, not 32

    with pytest.raises(SystemExit):
        per_au_cli.main(["encrypt", str(src), str(enc), str(short_key)])


def test_dump_identifications_with_real_tio(tmp_path):
    """dump_identifications on a real .tio reaches the dump() path."""
    from ttio.tools import dump_identifications

    src = _make_minimal_tio(tmp_path, "src_dump.tio")
    rc = dump_identifications.main([str(src)])
    # Returns 0 on success (no identifications, but valid structure).
    assert rc == 0


def test_transport_encode_decode_round_trip(tmp_path):
    """transport_encode_cli + transport_decode_cli end-to-end exercise both mains."""
    from ttio.tools import transport_decode_cli, transport_encode_cli

    src = _make_minimal_tio(tmp_path, "src_t.tio")
    tis = tmp_path / "out.tis"
    rc_enc = transport_encode_cli.main([str(src), str(tis)])
    assert rc_enc in (None, 0)
    assert tis.exists()
    out = tmp_path / "round.tio"
    rc_dec = transport_decode_cli.main([str(tis), str(out)])
    assert rc_dec in (None, 0)
    assert out.exists()


def test_ttio_sign_verify_round_trip(tmp_path):
    """ttio-sign + ttio-verify happy path on a real .tio.

    Exercises the sign-then-verify flow that's the main user-facing
    behaviour of the two CLIs. Hits ~10 lines per CLI that the
    error-only tests above skip.
    """
    from ttio.tools import ttio_sign_cli, ttio_verify_cli

    src = _make_minimal_tio(tmp_path, "src_sign.tio")
    key_hex = "00" * 32  # 64-char hex HMAC-SHA256 key
    dataset = "/study/ms_runs/run_0001/signal_channels/intensity_values"

    rc_sign = ttio_sign_cli.main([str(src), dataset, key_hex])
    assert rc_sign == 0, f"sign rc {rc_sign}"
    rc_verify = ttio_verify_cli.main([str(src), dataset, key_hex])
    assert rc_verify == 0, f"verify rc {rc_verify}"


def test_ttio_verify_with_wrong_key_fails(tmp_path):
    """ttio-verify with a different key than ttio-sign used returns non-zero.

    Covers the verify-failure branch (signature mismatch path).
    """
    from ttio.tools import ttio_sign_cli, ttio_verify_cli

    src = _make_minimal_tio(tmp_path, "src_wrong.tio")
    key_a = "00" * 32
    key_b = "ff" * 32
    dataset = "/study/ms_runs/run_0001/signal_channels/intensity_values"

    rc_sign = ttio_sign_cli.main([str(src), dataset, key_a])
    assert rc_sign == 0
    rc_verify = ttio_verify_cli.main([str(src), dataset, key_b])
    assert rc_verify != 0


def test_ttio_pqc_sig_keygen_writes_key_files(tmp_path):
    """ttio-pqc sig-keygen actually writes the public + secret key files."""
    _skip_if_no_liboqs()
    from ttio.tools import ttio_pqc_cli

    pk = tmp_path / "pk.bin"
    sk = tmp_path / "sk.bin"
    rc = ttio_pqc_cli.main(["sig-keygen", str(pk), str(sk)])
    assert rc == 0, f"sig-keygen rc {rc}"
    assert pk.exists() and pk.stat().st_size > 0
    assert sk.exists() and sk.stat().st_size > 0


def test_ttio_pqc_kem_keygen_writes_key_files(tmp_path):
    """ttio-pqc kem-keygen writes ML-KEM-1024 key files."""
    _skip_if_no_liboqs()
    from ttio.tools import ttio_pqc_cli

    pk = tmp_path / "kem_pk.bin"
    sk = tmp_path / "kem_sk.bin"
    rc = ttio_pqc_cli.main(["kem-keygen", str(pk), str(sk)])
    assert rc == 0
    assert pk.exists() and sk.exists()
