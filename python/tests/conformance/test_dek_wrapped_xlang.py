"""Cross-language ``dek_wrapped`` envelope-encryption conformance.

Proves that the dataset-level wrapped-DEK blob at
``/protection/key_info/dek_wrapped`` written by ANY language
(Python / Java / ObjC) is correctly read **and unwrapped** by Python.
Combined with the Java (``DekWrappedXLangTest``) and ObjC
(``TestDekWrappedXLang``) peers — each of which reads the same
committed fixtures — this gives the full NxN writer×reader matrix.

This is the conformance test whose ABSENCE let the
``fix/dek-wrapped-xlang`` bug ship: Java/ObjC used to store
``dek_wrapped`` as an ``int32``-packed, 4-byte-padded dataset while
Python stored the spec-compliant ``uint8[N]`` exact-length blob, so a
file written by one language crashed (``ClassCastException``) or
corrupted (1639→60 truncation) when read by another. All three now
write ``uint8[N]``.

The fixtures + committed KEK + expected DEK hex live under
``conformance/key_rotation/`` and are produced by
``conformance/key_rotation/gen_fixtures.py``.

Coverage:
* **aes-256-gcm (71-byte blob)** — Python reads py/java/objc writers.
* **ml-kem-1024 (1639-byte blob)** — Python reads py/objc writers
  (skipped without liboqs; Java exposes no dataset-level PQC path).
"""
from __future__ import annotations

import json
from pathlib import Path

import h5py
import pytest

from ttio.key_rotation import unwrap_dek

_REPO_ROOT = Path(__file__).resolve().parents[3]
_KR = _REPO_ROOT / "conformance" / "key_rotation"
_MANIFEST = _KR / "expected.json"


def _pqc_available() -> bool:
    try:
        from ttio import pqc
        return pqc.is_available()
    except Exception:
        return False


def _load_manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def _fixture_cases() -> list[tuple[str, str, str]]:
    """(fixture_name, algorithm, expected_dek_hex) for every committed
    fixture, or an empty list when the manifest is missing."""
    if not _MANIFEST.exists():
        return []
    manifest = _load_manifest()
    return [
        (f["fixture"], f["algorithm"], f["expected_dek_hex"])
        for f in manifest["fixtures"]
    ]


_CASES = _fixture_cases()


@pytest.mark.skipif(not _MANIFEST.exists(),
                     reason="conformance/key_rotation fixtures not generated")
@pytest.mark.parametrize("fixture,algorithm,expected_hex", _CASES,
                          ids=[c[0] for c in _CASES])
def test_python_reads_xlang_dek_wrapped(fixture, algorithm, expected_hex):
    """Python unwraps each language's committed ``dek_wrapped`` fixture
    with the shared KEK and recovers the exact expected DEK."""
    if algorithm == "ml-kem-1024" and not _pqc_available():
        pytest.skip("liboqs/ML-KEM not available in this Python build")

    manifest = _load_manifest()
    if algorithm == "aes-256-gcm":
        kek = (_KR / manifest["kek_aes_file"]).read_bytes()
    else:
        kek = (_KR / manifest["kek_mlkem_priv_file"]).read_bytes()

    path = _KR / "fixtures" / fixture
    with h5py.File(path, "r") as f:
        # Guard the on-disk layout: the bug was a non-uint8 dataset.
        ds = f["/protection/key_info/dek_wrapped"]
        assert ds.dtype.itemsize == 1, (
            f"{fixture}: dek_wrapped must be uint8 (got {ds.dtype}); "
            "int32-padded layout corrupts cross-language reads"
        )
        expected_len = manifest["blob_lengths"][algorithm]
        assert len(ds) == expected_len, (
            f"{fixture}: dek_wrapped must be exactly {expected_len} bytes "
            f"(got {len(ds)}); padding corrupts cross-language reads"
        )
        recovered = unwrap_dek(f, kek, algorithm=algorithm)

    assert recovered.hex() == expected_hex, (
        f"{fixture}: Python recovered the wrong DEK from a {algorithm} "
        "blob written by another language"
    )


@pytest.mark.skipif(not _MANIFEST.exists(),
                     reason="conformance/key_rotation fixtures not generated")
def test_matrix_covers_all_writers():
    """Sanity: the committed corpus exercises every writer language for
    AES-GCM (the universal NxN case) so a regression in any writer is
    caught here."""
    manifest = _load_manifest()
    aes_writers = {
        f["writer"] for f in manifest["fixtures"]
        if f["algorithm"] == "aes-256-gcm"
    }
    assert {"py", "java", "objc"}.issubset(aes_writers), (
        f"AES-GCM corpus missing writers: {aes_writers}. Regenerate "
        "with all three toolchains built."
    )
