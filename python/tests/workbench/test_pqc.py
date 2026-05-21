"""W6.3 -- workbench PQC client surface (ML-KEM-1024).

The blob ``seal_pqc`` / ``open_pqc`` envelope path was removed with the
per-AU encrypted-upload rework (it was never daemon-compatible). What
remains is the preview gate + keypair generator that the per-AU PQC
upload path (``WorkbenchClient.upload_encrypted_pqc``) uses; the gate's
end-to-end behaviour is covered by the live smoke
(``test_per_au_encrypted_pqc_upload_round_trip``).
"""
import pytest

from ttio import pqc as core_pqc
from ttio.workbench.pqc import (
    ML_KEM_1024,
    PQCPreviewDisabledError,
    _require_preview,
    kem_keygen,
)

requires_pqc = pytest.mark.skipif(
    not core_pqc.is_available(),
    reason="liboqs-python not available",
)


def test_require_preview_refuses_without_optin():
    with pytest.raises(PQCPreviewDisabledError):
        _require_preview(False)


def test_require_preview_passes_when_optin():
    _require_preview(True)  # no raise


@requires_pqc
def test_kem_keygen_shapes():
    kp = kem_keygen()
    # ML-KEM-1024: 1568-byte public key, 3168-byte private key.
    assert len(kp.public_key) == 1568
    assert len(kp.private_key) == 3168


def test_ml_kem_1024_constant():
    assert ML_KEM_1024 == "ml-kem-1024"
