"""In-process coverage for the dek_envelope cross-language CLI.

The CLI is also exercised end-to-end (as a subprocess) by the conformance
harness in tests/conformance/test_dek_wrapped_xlang.py, but coverage
instrumentation can't see subprocesses — so this drives ``main()`` in
process (mirrors how the other tool CLIs are unit-tested).
"""
from __future__ import annotations

import secrets

import pytest

from ttio.tools import dek_envelope_cli as cli


def test_wrap_then_unwrap_round_trip(tmp_path, capsys):
    kek = tmp_path / "kek.bin"
    kek.write_bytes(secrets.token_bytes(32))
    out = tmp_path / "out.tio"
    dek_out = tmp_path / "dek.hex"

    rc = cli.main(["wrap", str(out), str(kek), "--dek-out", str(dek_out)])
    assert rc == 0
    wrapped_dek = capsys.readouterr().out.strip()
    assert wrapped_dek == dek_out.read_text().strip()
    assert len(wrapped_dek) == 64  # 32-byte DEK as hex
    assert out.exists()

    rc = cli.main(["unwrap", str(out), str(kek)])
    assert rc == 0
    recovered = capsys.readouterr().out.strip()
    assert recovered == wrapped_dek


def test_aes_kek_wrong_length_rejected(tmp_path):
    kek = tmp_path / "kek.bin"
    kek.write_bytes(b"\x00" * 31)  # not 32 bytes
    with pytest.raises(SystemExit):
        cli.main(["wrap", str(tmp_path / "out.tio"), str(kek)])
