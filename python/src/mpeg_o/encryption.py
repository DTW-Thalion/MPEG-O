"""AES-256-GCM encryption / decryption matching the ObjC reference layout.

The Objective-C implementation uses OpenSSL ``EVP_aes_256_gcm`` with a
12-byte IV and a 16-byte auth tag. Ciphertext is stored separately from the
tag (via ``EVP_CTRL_GCM_GET_TAG``). Python mirrors this using
``cryptography.hazmat.primitives.ciphers.aead.AESGCM`` — note that
``AESGCM.encrypt`` returns ``ciphertext || tag``; we split the last 16 bytes
off to match the OpenSSL layout.

Per-channel encrypted-signal-channel layout (see §5 of ``docs/format-spec.md``)::

    <channel>_values_encrypted    int32 raw byte container, zero-padded to /4
    <channel>_iv                  3 × int32 raw bytes (12-byte IV)
    <channel>_tag                 4 × int32 raw bytes (16-byte GCM tag)
    @<channel>_ciphertext_bytes   int64  exact ciphertext length
    @<channel>_original_count     int64  original element count
    @<channel>_algorithm          string "AES-256-GCM"

Cross-language equivalents
--------------------------
Objective-C: ``MPGOEncryptionManager`` · Java:
``com.dtwthalion.mpgo.protection.EncryptionManager``.

API status: Stable.
"""
from __future__ import annotations

from dataclasses import dataclass

import h5py
import numpy as np

from . import _hdf5_io as io

AES_KEY_LEN = 32
AES_IV_LEN = 12
AES_TAG_LEN = 16
ALGORITHM_NAME = "AES-256-GCM"

# v0.7 M48: default algorithm identifier used by the cipher_suite
# catalog. Pre-v0.7 code hardcoded the constants above; new code paths
# go through :mod:`mpeg_o.cipher_suite` so the algorithm is a
# parameter, not an invariant.
DEFAULT_ENCRYPTION_ALGORITHM = "aes-256-gcm"


def _aesgcm():  # type: ignore[no-untyped-def]
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "mpeg_o.encryption requires the 'cryptography' optional dependency; "
            "install with 'pip install mpeg-o[crypto]'"
        ) from exc
    return AESGCM


@dataclass(frozen=True, slots=True)
class SealedBlob:
    """Result of an AES-256-GCM encrypt: separate ciphertext, IV, and tag."""

    ciphertext: bytes
    iv: bytes
    tag: bytes


def encrypt_bytes(
    plaintext: bytes,
    key: bytes,
    iv: bytes | None = None,
    *,
    algorithm: str = DEFAULT_ENCRYPTION_ALGORITHM,
) -> SealedBlob:
    """Encrypt ``plaintext`` with the named AEAD cipher.
    Returns ciphertext/iv/tag tuple.

    v0.7 M48: the algorithm is a parameter, not an invariant. Key and
    nonce lengths come from :mod:`mpeg_o.cipher_suite`. Passing an
    unsupported algorithm raises
    :class:`~mpeg_o.cipher_suite.UnsupportedAlgorithmError`.

    Default ``algorithm="aes-256-gcm"`` preserves pre-v0.7 behaviour
    exactly. If ``iv`` is ``None`` a random nonce of the cipher's
    required length is generated. Tests that need cross-implementation
    parity should pass a fixed ``iv``.
    """
    from . import cipher_suite
    cipher_suite.validate_key(algorithm, key)
    nonce_len = cipher_suite.nonce_length(algorithm)
    tag_len = cipher_suite.tag_length(algorithm)
    if iv is None:
        import os
        iv = os.urandom(nonce_len)
    if len(iv) != nonce_len:
        raise ValueError(
            f"{algorithm}: IV must be {nonce_len} bytes, got {len(iv)}"
        )
    # v0.7: only AES-256-GCM is a live AEAD; other AEADs land in M49.
    if algorithm != "aes-256-gcm":  # pragma: no cover - caught by validate_key
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm}: AEAD path not yet implemented"
        )
    AESGCM = _aesgcm()
    ct_with_tag = AESGCM(key).encrypt(iv, plaintext, associated_data=None)
    ciphertext, tag = ct_with_tag[:-tag_len], ct_with_tag[-tag_len:]
    return SealedBlob(ciphertext=ciphertext, iv=iv, tag=tag)


def decrypt_bytes(
    blob: SealedBlob,
    key: bytes,
    *,
    algorithm: str = DEFAULT_ENCRYPTION_ALGORITHM,
) -> bytes:
    """Decrypt a sealed blob with the named AEAD cipher. Raises on
    authentication failure. Key / IV / tag lengths dispatched via
    :mod:`mpeg_o.cipher_suite` (v0.7 M48)."""
    from . import cipher_suite
    cipher_suite.validate_key(algorithm, key)
    nonce_len = cipher_suite.nonce_length(algorithm)
    tag_len = cipher_suite.tag_length(algorithm)
    if len(blob.iv) != nonce_len or len(blob.tag) != tag_len:
        raise ValueError(
            f"{algorithm}: IV/tag length mismatch "
            f"(iv {len(blob.iv)}≠{nonce_len}, tag {len(blob.tag)}≠{tag_len})"
        )
    if algorithm != "aes-256-gcm":  # pragma: no cover
        raise cipher_suite.UnsupportedAlgorithmError(
            f"{algorithm}: AEAD path not yet implemented"
        )
    AESGCM = _aesgcm()
    return AESGCM(key).decrypt(blob.iv, blob.ciphertext + blob.tag,
                                 associated_data=None)


# ---------------------------------------------- channel-level helpers ---


def read_encrypted_channel(
    channels_group, channel: str, key: bytes, dtype: str = "<f8"
) -> np.ndarray:
    """Decrypt one encrypted signal channel from a ``signal_channels`` group.

    The plaintext is interpreted as an array of ``dtype`` (default
    little-endian float64, matching the ObjC writer). Raises ``KeyError`` if
    the channel is not encrypted in this group.

    v0.9 M64.5 phase B: ``channels_group`` may be an ``h5py.Group``
    (legacy fast path) or a :class:`StorageGroup`. The HDF5-backed
    StorageGroup unwraps to the native h5py path; non-HDF5 providers
    route through the protocol's ``open_dataset().read()`` and
    ``get_attribute`` primitives.
    """
    from .providers.base import StorageGroup
    enc_name = f"{channel}_values_encrypted"

    if isinstance(channels_group, StorageGroup) and getattr(channels_group, "_grp", None) is None:
        # Non-HDF5 provider path.
        if not channels_group.has_child(enc_name):
            raise KeyError(f"channel {channel!r} is not encrypted under this group")
        padded = np.asarray(channels_group.open_dataset(enc_name).read())
        padded_bytes = padded.tobytes()
        attr_name = f"{channel}_ciphertext_bytes"
        if channels_group.has_attribute(attr_name):
            ciphertext_bytes = int(channels_group.get_attribute(attr_name))
        else:
            ciphertext_bytes = len(padded_bytes)
        ciphertext = padded_bytes[:ciphertext_bytes]
        iv_arr  = np.asarray(channels_group.open_dataset(f"{channel}_iv").read())
        tag_arr = np.asarray(channels_group.open_dataset(f"{channel}_tag").read())
        iv = iv_arr.tobytes()[:AES_IV_LEN]
        tag = tag_arr.tobytes()[:AES_TAG_LEN]
        plaintext = decrypt_bytes(SealedBlob(ciphertext, iv, tag), key)
        return np.frombuffer(plaintext, dtype=dtype).copy()

    # HDF5 fast path (legacy byte parity).
    native = getattr(channels_group, "_grp", channels_group)
    if enc_name not in native:
        raise KeyError(f"channel {channel!r} is not encrypted under this group")
    padded = native[enc_name][()]
    padded_bytes = padded.tobytes()
    ciphertext_bytes = int(io.read_int_attr(
        native, f"{channel}_ciphertext_bytes", default=len(padded_bytes)
    ) or len(padded_bytes))
    ciphertext = padded_bytes[:ciphertext_bytes]
    iv_arr = native[f"{channel}_iv"][()]
    tag_arr = native[f"{channel}_tag"][()]
    iv = iv_arr.tobytes()[:AES_IV_LEN]
    tag = tag_arr.tobytes()[:AES_TAG_LEN]
    plaintext = decrypt_bytes(SealedBlob(ciphertext, iv, tag), key)
    return np.frombuffer(plaintext, dtype=dtype).copy()


# ---------------------------------------------- run-level helpers ---


def _encrypt_intensity_in_signal_group(
    sig, key: bytes
) -> None:
    """Encrypt the ``intensity_values`` dataset inside an open signal_channels group.

    This is the shared implementation used by both
    :func:`encrypt_intensity_channel_in_run` (file-path API) and
    :meth:`~mpeg_o.acquisition_run.AcquisitionRun.encrypt_with_key`
    (group API, which avoids re-opening the file).

    v0.9 M64.5 phase B: ``sig`` may be an ``h5py.Group`` or a
    :class:`StorageGroup`; non-HDF5 providers route through
    StorageGroup primitives.

    Idempotent: returns silently if ``intensity_values_encrypted`` already
    exists. Callers are responsible for key-length validation.
    """
    from .enums import Precision
    from .providers.base import StorageGroup

    if isinstance(sig, StorageGroup) and getattr(sig, "_grp", None) is None:
        # Non-HDF5 provider path.
        if sig.has_child("intensity_values_encrypted"):
            return
        if not sig.has_child("intensity_values"):
            raise KeyError("intensity_values not found in signal_channels group")
        plain_arr = np.asarray(sig.open_dataset("intensity_values").read()).astype("<f8", copy=False)
        original_count = int(plain_arr.shape[0])
        plaintext = plain_arr.tobytes()
        blob = encrypt_bytes(plaintext, key)
        ct = blob.ciphertext
        remainder = len(ct) % 4
        if remainder:
            ct = ct + b"\x00" * (4 - remainder)
        ct_arr = np.frombuffer(ct, dtype="<i4").copy()
        iv_arr = np.frombuffer(blob.iv, dtype="<i4").copy()
        tag_arr = np.frombuffer(blob.tag, dtype="<i4").copy()
        sig.create_dataset("intensity_values_encrypted", Precision.INT32, ct_arr.size).write(ct_arr)
        sig.create_dataset("intensity_iv", Precision.INT32, iv_arr.size).write(iv_arr)
        sig.create_dataset("intensity_tag", Precision.INT32, tag_arr.size).write(tag_arr)
        sig.set_attribute("intensity_ciphertext_bytes", int(len(blob.ciphertext)))
        sig.set_attribute("intensity_original_count", int(original_count))
        sig.set_attribute("intensity_algorithm", ALGORITHM_NAME)
        sig.delete_child("intensity_values")
        return

    # HDF5 fast path (legacy byte parity).
    native = getattr(sig, "_grp", sig)
    if "intensity_values_encrypted" in native:
        return
    if "intensity_values" not in native:
        raise KeyError("intensity_values not found in signal_channels group")
    plain_arr = native["intensity_values"][()].astype("<f8", copy=False)
    original_count = int(plain_arr.shape[0])
    plaintext = plain_arr.tobytes()
    blob = encrypt_bytes(plaintext, key)
    ct = blob.ciphertext
    remainder = len(ct) % 4
    if remainder:
        ct = ct + b"\x00" * (4 - remainder)
    ct_arr = np.frombuffer(ct, dtype="<i4").copy()
    iv_arr = np.frombuffer(blob.iv, dtype="<i4").copy()
    tag_arr = np.frombuffer(blob.tag, dtype="<i4").copy()
    native.create_dataset("intensity_values_encrypted", data=ct_arr)
    native.create_dataset("intensity_iv", data=iv_arr)
    native.create_dataset("intensity_tag", data=tag_arr)
    native.attrs["intensity_ciphertext_bytes"] = np.int64(len(blob.ciphertext))
    native.attrs["intensity_original_count"] = np.int64(original_count)
    native.attrs["intensity_algorithm"] = ALGORITHM_NAME
    del native["intensity_values"]


def encrypt_intensity_channel_in_run(
    file_path: str, run_name: str, key: bytes
) -> None:
    """Encrypt the intensity_values dataset of the named MS run in place.

    Matches ObjC
    ``+[MPGOEncryptionManager encryptIntensityChannelInRun:atFilePath:withKey:error:]``.

    Opens the .mpgo file read-write, locates
    ``/study/ms_runs/<run_name>/signal_channels/``, encrypts the
    ``intensity_values`` dataset bytes with AES-256-GCM, writes an
    ``intensity_values_encrypted`` dataset (bytes padded to 4-byte boundary,
    stored as int32 array for ObjC wire compat) plus sibling scalar
    datasets ``intensity_iv`` and ``intensity_tag``, plus attributes
    ``intensity_ciphertext_bytes`` (int64), ``intensity_original_count``
    (int64), and ``intensity_algorithm`` ("AES-256-GCM"), and deletes the
    original ``intensity_values`` dataset.

    Idempotent: if ``intensity_values_encrypted`` already exists, returns
    silently without re-encrypting.

    Raises ``FileNotFoundError`` if the file or run does not exist,
    ``ValueError`` if key is not 32 bytes.
    """
    if len(key) != AES_KEY_LEN:
        raise ValueError(f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}")

    import os
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"File not found: {file_path}")

    with h5py.File(file_path, "r+") as f:
        run_path = f"study/ms_runs/{run_name}"
        if run_path not in f:
            raise FileNotFoundError(
                f"Run {run_name!r} not found in {file_path!r}"
            )
        sig = f[f"{run_path}/signal_channels"]
        _encrypt_intensity_in_signal_group(sig, key)


def encrypt_intensity_channel_in_group(
    signal_channels_group, key: bytes
) -> None:
    """Encrypt the intensity_values dataset inside an already-open signal_channels group.

    Use this variant when the caller already holds an open file handle
    (e.g. via :class:`~mpeg_o.spectral_dataset.SpectralDataset`) and
    cannot open the file a second time. v0.9 M64.5 phase B: accepts
    either an ``h5py.Group`` or a :class:`StorageGroup` so non-HDF5
    providers also encrypt in place.

    Raises ``ValueError`` if ``key`` is not 32 bytes, ``KeyError`` if
    ``intensity_values`` is absent.
    """
    if len(key) != AES_KEY_LEN:
        raise ValueError(f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}")
    _encrypt_intensity_in_signal_group(signal_channels_group, key)


def decrypt_intensity_channel_in_run(
    file_path: str, run_name: str, key: bytes
) -> np.ndarray:
    """Decrypt the intensity_values channel of the named MS run.

    Matches ObjC
    ``+[MPGOEncryptionManager decryptIntensityChannelInRun:atFilePath:withKey:error:]``.

    Returns a float64 numpy array with the original element count. The
    on-disk file is NOT modified — decryption is read-only.

    Raises ``FileNotFoundError``, ``KeyError`` (run not found), or
    ``ValueError`` (channel not encrypted / key wrong) as appropriate.
    """
    if len(key) != AES_KEY_LEN:
        raise ValueError(f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}")

    import os
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"File not found: {file_path}")

    with h5py.File(file_path, "r") as f:
        run_path = f"study/ms_runs/{run_name}"
        if run_path not in f:
            raise KeyError(f"Run {run_name!r} not found in {file_path!r}")
        sig = f[f"{run_path}/signal_channels"]
        return read_encrypted_channel(sig, "intensity", key, dtype="<f8")
