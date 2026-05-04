"""Native round-trip tests for NAME_TOKENIZED v2 (codec id 15)."""
from __future__ import annotations

import pytest

from ttio.codecs import name_tokenizer_v2 as nt2

if not nt2.HAVE_NATIVE_LIB:
    pytest.skip("requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
                allow_module_level=True)


def test_empty():
    assert nt2.decode(nt2.encode([])) == []


@pytest.mark.parametrize("names", [
    ["EAS220_R1:8:1:0:1234"],
    ["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1234"],          # DUP
    ["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1235"],          # MATCH-K
    [f"EAS:1:{i}" for i in range(50)],                          # COL
    ["weird1", "weird2"],                                        # may use COL or VERB
    ["mixed", "X:1:2", "another", "X:1:3"],                      # mixed shapes
])
def test_round_trip(names):
    assert nt2.decode(nt2.encode(names)) == names


def test_two_blocks():
    names = [f"R:1:{i}" for i in range(4097)]
    assert nt2.decode(nt2.encode(names)) == names


def test_paired_alternating():
    """Each name appears twice — DUP-heavy."""
    names: list[str] = []
    for i in range(100):
        n = f"INSTR:1:101:{i*100}:{i*200}"
        names.append(n); names.append(n)
    assert nt2.decode(nt2.encode(names)) == names


def test_pacbio_style():
    names = [
        "m54006_180123_120000/zmw1/0_15000",
        "m54006_180123_120000/zmw1/15001_30000",
        "m54006_180123_120000/zmw2/0_18000",
    ]
    assert nt2.decode(nt2.encode(names)) == names


def test_bad_magic_raises():
    with pytest.raises(RuntimeError, match="magic|name_tok_v2"):
        nt2.decode(b"XXXX" + b"\x01\x00" + b"\x00" * 6)


def test_bad_version_raises():
    with pytest.raises(RuntimeError, match="version|name_tok_v2"):
        nt2.decode(b"NTK2" + b"\x99\x00" + b"\x00" * 6)


def test_too_short_raises():
    with pytest.raises(RuntimeError):
        nt2.decode(b"NTK2\x01")


def test_backend():
    assert nt2.get_backend_name() == "native"


def test_magic_in_blob():
    blob = nt2.encode(["X:1"])
    assert blob[:4] == b"NTK2"
    assert blob[4] == 0x01  # version
