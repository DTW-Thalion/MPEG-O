"""v1.0 per-Access-Unit encryption primitives.

Implements ``opt_per_au_encryption`` (channel data) and
``opt_encrypted_au_headers`` (AU semantic header) as specified in
``docs/transport-encryption-design.md`` and
``docs/format-spec.md`` §9.1.

Unlike the v0.x :mod:`mpeg_o.encryption` module — which encrypts an
entire channel as one AES-GCM operation — this module generates one
AES-GCM operation per spectrum, producing:

- ``ChannelSegment`` rows for :class:`SpectralDataset` writers to
  store in the ``<channel>_segments`` compound dataset.
- ``HeaderSegment`` rows for the optional
  ``spectrum_index/au_header_segments`` compound.

Each AES-GCM op binds its ciphertext to its context via authenticated
data (AAD): ``dataset_id (u16 LE) || au_sequence (u32 LE) ||
purpose_tag`` where ``purpose_tag`` is either the UTF-8 channel name,
the literal bytes ``b"header"``, or ``b"pixel"``. Ciphertext cannot
be replayed against a different AU or envelope.

Cross-language equivalents: ObjC
``MPGOPerAUEncryption`` · Java
``com.dtwthalion.mpgo.protection.PerAUEncryption``.
"""
from __future__ import annotations

import os
import struct
from dataclasses import dataclass

import numpy as np

from .encryption import AES_IV_LEN, AES_KEY_LEN, AES_TAG_LEN


# ---------------------------------------------------------- AAD


def aad_for_channel(dataset_id: int, au_sequence: int, channel_name: str) -> bytes:
    """AAD bound into AES-GCM for an encrypted channel payload.

    Per ``docs/transport-spec.md`` §4.3.4:
    ``dataset_id (u16 LE) || au_sequence (u32 LE) || channel_name_utf8``.
    """
    return (
        struct.pack("<HI", dataset_id & 0xFFFF, au_sequence & 0xFFFFFFFF)
        + channel_name.encode("utf-8")
    )


def aad_for_header(dataset_id: int, au_sequence: int) -> bytes:
    """AAD for the encrypted AU semantic header. Uses the literal
    6-byte tag ``b"header"``."""
    return struct.pack("<HI", dataset_id & 0xFFFF, au_sequence & 0xFFFFFFFF) + b"header"


def aad_for_pixel(dataset_id: int, au_sequence: int) -> bytes:
    """AAD for the encrypted MSImagePixel pixel_x/y/z envelope. Uses
    the literal 5-byte tag ``b"pixel"``."""
    return struct.pack("<HI", dataset_id & 0xFFFF, au_sequence & 0xFFFFFFFF) + b"pixel"


# ---------------------------------------------------------- primitives


def _aesgcm(key: bytes):
    if len(key) != AES_KEY_LEN:
        raise ValueError(
            f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}"
        )
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:  # pragma: no cover
        raise ImportError(
            "per-AU encryption requires the `cryptography` package"
        ) from exc
    return AESGCM(key)


def encrypt_with_aad(plaintext: bytes, key: bytes, aad: bytes,
                      *, iv: bytes | None = None) -> tuple[bytes, bytes, bytes]:
    """Encrypt ``plaintext`` with AES-256-GCM, binding ``aad`` as
    authenticated data. Returns ``(iv, tag, ciphertext)`` with
    ``len(iv) == 12`` and ``len(tag) == 16``.

    If ``iv`` is ``None``, a fresh random nonce is generated.
    Callers doing deterministic testing MUST supply a fixed IV."""
    if iv is None:
        iv = os.urandom(AES_IV_LEN)
    elif len(iv) != AES_IV_LEN:
        raise ValueError(f"IV must be {AES_IV_LEN} bytes, got {len(iv)}")
    ct_with_tag = _aesgcm(key).encrypt(iv, plaintext, associated_data=aad)
    ciphertext, tag = ct_with_tag[:-AES_TAG_LEN], ct_with_tag[-AES_TAG_LEN:]
    return iv, tag, ciphertext


def decrypt_with_aad(iv: bytes, tag: bytes, ciphertext: bytes,
                      key: bytes, aad: bytes) -> bytes:
    """Decrypt + authenticate. Raises on tag mismatch."""
    if len(iv) != AES_IV_LEN:
        raise ValueError(f"IV must be {AES_IV_LEN} bytes, got {len(iv)}")
    if len(tag) != AES_TAG_LEN:
        raise ValueError(f"tag must be {AES_TAG_LEN} bytes, got {len(tag)}")
    return _aesgcm(key).decrypt(iv, ciphertext + tag, associated_data=aad)


# ---------------------------------------------------------- segment types


@dataclass(slots=True)
class ChannelSegment:
    """One encrypted row of a ``<channel>_segments`` compound dataset.

    ``offset`` and ``length`` describe the spectrum's slice into the
    *plaintext* element stream; they're load-bearing for the
    :class:`SpectrumIndex` reader path.
    """

    offset: int
    length: int
    iv: bytes      # 12 bytes
    tag: bytes     # 16 bytes
    ciphertext: bytes


@dataclass(slots=True)
class HeaderSegment:
    """One encrypted row of ``spectrum_index/au_header_segments``."""

    iv: bytes      # 12 bytes
    tag: bytes     # 16 bytes
    ciphertext: bytes   # exactly 36 bytes per spec (1+1+1+8+8+1+8+8)


# ---------------------------------------------------------- channel segments


def encrypt_channel_to_segments(
    plaintext_flat: np.ndarray,
    offsets: np.ndarray,
    lengths: np.ndarray,
    *,
    dataset_id: int,
    channel_name: str,
    key: bytes,
) -> list[ChannelSegment]:
    """Slice ``plaintext_flat`` into per-spectrum rows and encrypt
    each independently.

    ``plaintext_flat`` is typically a float64 array of decoded signal
    values for an entire channel; ``offsets[i]`` / ``lengths[i]`` are
    the i-th spectrum's position. Each row is a separate AES-GCM
    operation with a fresh IV.
    """
    if plaintext_flat.dtype != np.dtype("<f8"):
        plaintext_flat = plaintext_flat.astype("<f8", copy=False)
    segments: list[ChannelSegment] = []
    for au_seq, (off, length) in enumerate(zip(offsets, lengths)):
        off_i = int(off)
        length_i = int(length)
        chunk = plaintext_flat[off_i:off_i + length_i].tobytes()
        aad = aad_for_channel(dataset_id, au_seq, channel_name)
        iv, tag, ciphertext = encrypt_with_aad(chunk, key, aad)
        segments.append(
            ChannelSegment(
                offset=off_i,
                length=length_i,
                iv=iv,
                tag=tag,
                ciphertext=ciphertext,
            )
        )
    return segments


def decrypt_channel_from_segments(
    segments: list[ChannelSegment],
    *,
    dataset_id: int,
    channel_name: str,
    key: bytes,
) -> np.ndarray:
    """Decrypt every row and concatenate plaintext float64 values."""
    chunks: list[bytes] = []
    for au_seq, seg in enumerate(segments):
        aad = aad_for_channel(dataset_id, au_seq, channel_name)
        plaintext = decrypt_with_aad(seg.iv, seg.tag, seg.ciphertext, key, aad)
        if len(plaintext) != seg.length * 8:
            raise ValueError(
                f"channel {channel_name!r} segment {au_seq}: "
                f"decrypted {len(plaintext)} bytes, expected {seg.length * 8}"
            )
        chunks.append(plaintext)
    total_bytes = b"".join(chunks)
    return np.frombuffer(total_bytes, dtype="<f8").copy()


# ---------------------------------------------------------- header segments


# 36-byte AU semantic header plaintext: acquisition_mode(u8) ms_level(u8)
# polarity(u8) retention_time(f64) precursor_mz(f64) precursor_charge(u8)
# ion_mobility(f64) base_peak_intensity(f64). 1+1+1+8+8+1+8+8 = 36.
# Explicit byte concatenation avoids struct natural-alignment padding.
def pack_au_header_plaintext(
    *,
    acquisition_mode: int,
    ms_level: int,
    polarity: int,
    retention_time: float,
    precursor_mz: float,
    precursor_charge: int,
    ion_mobility: float,
    base_peak_intensity: float,
) -> bytes:
    return (
        struct.pack("<BBB", acquisition_mode & 0xFF, ms_level & 0xFF, polarity & 0xFF)
        + struct.pack("<dd", float(retention_time), float(precursor_mz))
        + struct.pack("<B", precursor_charge & 0xFF)
        + struct.pack("<dd", float(ion_mobility), float(base_peak_intensity))
    )


def unpack_au_header_plaintext(plain: bytes) -> dict:
    if len(plain) != 36:
        raise ValueError(f"AU header plaintext must be 36 bytes, got {len(plain)}")
    acquisition_mode, ms_level, polarity = struct.unpack_from("<BBB", plain, 0)
    retention_time, precursor_mz = struct.unpack_from("<dd", plain, 3)
    (precursor_charge,) = struct.unpack_from("<B", plain, 19)
    ion_mobility, base_peak_intensity = struct.unpack_from("<dd", plain, 20)
    return {
        "acquisition_mode": acquisition_mode,
        "ms_level": ms_level,
        "polarity": polarity,
        "retention_time": retention_time,
        "precursor_mz": precursor_mz,
        "precursor_charge": precursor_charge,
        "ion_mobility": ion_mobility,
        "base_peak_intensity": base_peak_intensity,
    }


def encrypt_header_segments(
    rows: list[dict],
    *,
    dataset_id: int,
    key: bytes,
) -> list[HeaderSegment]:
    """One HeaderSegment per row. Each row is a dict with the fields
    :func:`pack_au_header_plaintext` consumes."""
    segments: list[HeaderSegment] = []
    for au_seq, row in enumerate(rows):
        plain = pack_au_header_plaintext(**row)
        aad = aad_for_header(dataset_id, au_seq)
        iv, tag, ciphertext = encrypt_with_aad(plain, key, aad)
        segments.append(HeaderSegment(iv=iv, tag=tag, ciphertext=ciphertext))
    return segments


def decrypt_header_segments(
    segments: list[HeaderSegment],
    *,
    dataset_id: int,
    key: bytes,
) -> list[dict]:
    out: list[dict] = []
    for au_seq, seg in enumerate(segments):
        aad = aad_for_header(dataset_id, au_seq)
        plain = decrypt_with_aad(seg.iv, seg.tag, seg.ciphertext, key, aad)
        out.append(unpack_au_header_plaintext(plain))
    return out


# ---------------------------------------------------------------------
# File-level encrypt / decrypt for .mpgo HDF5 files
# ---------------------------------------------------------------------


def _channel_names_of(sig_group) -> list[str]:
    raw = sig_group.attrs.get("channel_names", "")
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    return [c for c in raw.split(",") if c]


def encrypt_per_au_file(
    path: str,
    key: bytes,
    *,
    encrypt_headers: bool = False,
) -> None:
    """Encrypt an existing plaintext .mpgo file in place with per-AU
    AES-256-GCM.

    For each MS run:
    - Reads the plaintext ``<channel>_values`` datasets.
    - Slices each spectrum from the run's
      ``spectrum_index/{offsets,lengths}``.
    - Encrypts each spectrum with a fresh IV, AAD =
      ``dataset_id || au_sequence || channel_name``.
    - Writes a compound ``<channel>_segments`` dataset (§9.1 layout).
    - Deletes the plaintext ``<channel>_values`` dataset.

    If ``encrypt_headers=True``, also encrypts the per-spectrum
    ``retention_time / ms_level / polarity / precursor_mz /
    precursor_charge / ion_mobility / base_peak_intensity`` into
    ``spectrum_index/au_header_segments`` and deletes the plaintext
    index arrays. ``offsets`` and ``lengths`` remain plaintext (they
    are structural, not semantic PHI).

    Sets the ``opt_per_au_encryption`` feature flag on the root group
    and ``opt_encrypted_au_headers`` when header encryption is
    requested.

    Raises ``FileNotFoundError``, ``ValueError`` (key length or bad
    source layout).
    """
    from . import _hdf5_io as io
    import h5py

    if len(key) != 32:
        raise ValueError(f"AES-256-GCM key must be 32 bytes, got {len(key)}")

    with h5py.File(path, "r+") as f:
        version, features = io.read_feature_flags(f)
        features_set = set(features)

        dataset_id_counter = 1
        for run_name, run_group in f["study/ms_runs"].items():
            sig = run_group["signal_channels"]
            idx = run_group["spectrum_index"]
            offsets = idx["offsets"][...]
            lengths = idx["lengths"][...]
            for cname in _channel_names_of(sig):
                values_ds = f"{cname}_values"
                if values_ds not in sig:
                    continue
                plaintext = sig[values_ds][...].astype("<f8", copy=False)
                segments = encrypt_channel_to_segments(
                    plaintext, offsets, lengths,
                    dataset_id=dataset_id_counter,
                    channel_name=cname,
                    key=key,
                )
                io.write_channel_segments(sig, f"{cname}_segments", segments)
                del sig[values_ds]
                sig.attrs[f"{cname}_algorithm"] = "aes-256-gcm"

            if encrypt_headers:
                acquisition_mode = int(run_group.attrs.get(
                    "acquisition_mode", 0
                ))
                rows = []
                for i in range(int(idx.attrs.get("count", len(offsets)))):
                    rows.append({
                        "acquisition_mode": acquisition_mode,
                        "ms_level": int(idx["ms_levels"][i]),
                        "polarity": int(idx["polarities"][i]),
                        "retention_time": float(idx["retention_times"][i]),
                        "precursor_mz": float(idx["precursor_mzs"][i]),
                        "precursor_charge": int(idx["precursor_charges"][i]),
                        "ion_mobility": 0.0,
                        "base_peak_intensity": float(
                            idx["base_peak_intensities"][i]
                        ),
                    })
                header_segs = encrypt_header_segments(
                    rows, dataset_id=dataset_id_counter, key=key,
                )
                io.write_au_header_segments(
                    idx, "au_header_segments", header_segs
                )
                for name in ("retention_times", "ms_levels", "polarities",
                              "precursor_mzs", "precursor_charges",
                              "base_peak_intensities"):
                    if name in idx:
                        del idx[name]

            dataset_id_counter += 1

        features_set.add("opt_per_au_encryption")
        if encrypt_headers:
            features_set.add("opt_encrypted_au_headers")
        io.write_feature_flags(f, version, sorted(features_set))


def decrypt_per_au_file(path: str, key: bytes) -> dict[str, dict[str, np.ndarray]]:
    """Read a per-AU-encrypted .mpgo and return the plaintext values.

    Returns ``{run_name: {channel_name: float64_ndarray}}``. When
    ``opt_encrypted_au_headers`` is set, also writes the decrypted
    header fields into an ``"__au_headers__"`` subkey as a list of
    dicts (one per spectrum).

    The on-disk file is NOT modified — this is a read-only op.
    """
    from . import _hdf5_io as io
    import h5py

    if len(key) != 32:
        raise ValueError(f"AES-256-GCM key must be 32 bytes, got {len(key)}")

    out: dict[str, dict] = {}
    with h5py.File(path, "r") as f:
        version, features = io.read_feature_flags(f)
        headers_encrypted = "opt_encrypted_au_headers" in features
        if "opt_per_au_encryption" not in features:
            raise ValueError(
                f"file at {path!r} does not carry opt_per_au_encryption"
            )

        dataset_id_counter = 1
        for run_name, run_group in f["study/ms_runs"].items():
            sig = run_group["signal_channels"]
            idx = run_group["spectrum_index"]
            run_out: dict[str, Any] = {}
            for cname in _channel_names_of(sig):
                seg_name = f"{cname}_segments"
                if seg_name not in sig:
                    continue
                segments = io.read_channel_segments(sig, seg_name)
                run_out[cname] = decrypt_channel_from_segments(
                    segments,
                    dataset_id=dataset_id_counter,
                    channel_name=cname,
                    key=key,
                )

            if headers_encrypted and "au_header_segments" in idx:
                header_segs = io.read_au_header_segments(
                    idx, "au_header_segments"
                )
                run_out["__au_headers__"] = decrypt_header_segments(
                    header_segs,
                    dataset_id=dataset_id_counter,
                    key=key,
                )

            out[run_name] = run_out
            dataset_id_counter += 1

    return out
