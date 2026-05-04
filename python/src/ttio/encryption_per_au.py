"""v1.0 per-Access-Unit encryption primitives.

Implements ``opt_per_au_encryption`` (channel data) and
``opt_encrypted_au_headers`` (AU semantic header) as specified in
``docs/transport-encryption-design.md`` and
``docs/format-spec.md`` §9.1.

Unlike the v0.x :mod:`ttio.encryption` module — which encrypts an
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
``TTIOPerAUEncryption`` · Java
``global.thalion.ttio.protection.PerAUEncryption``.
"""
from __future__ import annotations

import os
import struct
from dataclasses import dataclass

import numpy as np

from .encryption import AES_IV_LEN, AES_KEY_LEN, AES_TAG_LEN
from .enums import Precision  # M90.11 — used by _encrypt_genomic_index


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
    dtype: np.dtype | str = "<f8",
) -> list[ChannelSegment]:
    """Slice ``plaintext_flat`` into per-AU rows and encrypt each
    independently.

    ``plaintext_flat`` is typically a float64 array of decoded signal
    values (MS path) or a uint8 array of bytes (genomic path, M90.1).
    ``offsets[i]`` / ``lengths[i]`` are the i-th AU's position. Each
    row is a separate AES-GCM operation with a fresh IV.

    ``dtype`` controls the per-element byte width and the cast applied
    to ``plaintext_flat`` if it doesn't already match. Default
    ``"<f8"`` (float64, 8 bytes) preserves pre-M90.1 behaviour.
    Genomic callers pass ``"<u1"`` (uint8, 1 byte).
    """
    target = np.dtype(dtype)
    if plaintext_flat.dtype != target:
        plaintext_flat = plaintext_flat.astype(target, copy=False)
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
    dtype: np.dtype | str = "<f8",
) -> np.ndarray:
    """Decrypt every row and concatenate plaintext values.

    ``dtype`` controls the per-element byte width used to validate
    the decrypted length and the dtype of the returned array.
    Default ``"<f8"`` (MS path); genomic callers pass ``"<u1"``.
    """
    target = np.dtype(dtype)
    bpe = target.itemsize
    chunks: list[bytes] = []
    for au_seq, seg in enumerate(segments):
        aad = aad_for_channel(dataset_id, au_seq, channel_name)
        plaintext = decrypt_with_aad(seg.iv, seg.tag, seg.ciphertext, key, aad)
        if len(plaintext) != seg.length * bpe:
            raise ValueError(
                f"channel {channel_name!r} segment {au_seq}: "
                f"decrypted {len(plaintext)} bytes, "
                f"expected {seg.length * bpe} (dtype={target})"
            )
        chunks.append(plaintext)
    total_bytes = b"".join(chunks)
    return np.frombuffer(total_bytes, dtype=target).copy()


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
# File-level encrypt / decrypt via the StorageProvider abstraction
# ---------------------------------------------------------------------
#
# Every access below goes through StorageGroup / StorageDataset so
# the path is provider-agnostic: HDF5 + Memory are wired today,
# SQLite + Zarr raise NotImplementedError at the VL_BYTES boundary
# until their compound paths grow base64 transport.


def _split_channel_names(raw) -> list[str]:
    if isinstance(raw, (bytes, bytearray)):
        raw = bytes(raw).decode("utf-8")
    if raw is None:
        return []
    return [c for c in str(raw).split(",") if c]


def _get_str_attr(group, name: str) -> str:
    if not group.has_attribute(name):
        return ""
    v = group.get_attribute(name)
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode("utf-8")
    return str(v) if v is not None else ""


def _get_int_attr(group, name: str, default: int = 0) -> int:
    if not group.has_attribute(name):
        return default
    v = group.get_attribute(name)
    try:
        return int(v)
    except Exception:
        return default


def encrypt_per_au(
    path: str,
    key: bytes,
    *,
    encrypt_headers: bool = False,
    provider: str | None = None,
) -> None:
    """Encrypt an existing plaintext .tio at ``path`` in place with
    per-AU AES-256-GCM.

    Routes through :func:`ttio.providers.open_provider` so any
    backend that implements ``VL_BYTES`` compound fields works
    uniformly. Today HDF5 + Memory are wired; SQLite + Zarr raise a
    clear ``NotImplementedError`` at the compound-write boundary
    until their JSON-backed compound paths grow base64 transport for
    bytes.

    Feature flags ``opt_per_au_encryption`` (and
    ``opt_encrypted_au_headers`` when applicable) are set on the
    root group via the same provider attribute API the rest of the
    writer uses.

    For each run the writer:

    - Reads plaintext ``<channel>_values`` (float64), slices it per
      spectrum using ``spectrum_index/{offsets,lengths}``, encrypts
      each row with a fresh IV and AAD =
      ``dataset_id || au_sequence || channel_name``.
    - Writes a ``<channel>_segments`` compound via the provider.
    - Deletes the plaintext ``<channel>_values`` child.

    When ``encrypt_headers=True`` it additionally encrypts the six
    semantic index arrays (retention_times, ms_levels, polarities,
    precursor_mzs, precursor_charges, base_peak_intensities) into
    ``spectrum_index/au_header_segments`` and deletes the plaintext
    children. ``offsets`` and ``lengths`` remain plaintext — they
    are structural framing, not semantic PHI.
    """
    from . import _hdf5_io as io
    from .providers.registry import open_provider

    if len(key) != 32:
        raise ValueError(f"AES-256-GCM key must be 32 bytes, got {len(key)}")

    sp = open_provider(path, provider=provider, mode="a")
    try:
        root = sp.root_group()
        version, features = io.read_feature_flags(root)
        features_set = set(features)

        study = root.open_group("study")
        ms_runs = study.open_group("ms_runs")
        run_names = [n for n in ms_runs.child_names()
                      if not n.startswith("_") and ms_runs.has_child(n)]

        dataset_id_counter = 1
        for run_name in run_names:
            try:
                run_group = ms_runs.open_group(run_name)
            except KeyError:
                continue
            sig = run_group.open_group("signal_channels")
            idx = run_group.open_group("spectrum_index")

            from .genomic_index import _read_offsets_or_cumsum
            offsets = _read_offsets_or_cumsum(idx)
            lengths = np.asarray(idx.open_dataset("lengths").read(),
                                    dtype="<u4")

            channel_names = _split_channel_names(
                _get_str_attr(sig, "channel_names")
            )
            for cname in channel_names:
                values_name = f"{cname}_values"
                if not sig.has_child(values_name):
                    continue
                plaintext = np.asarray(
                    sig.open_dataset(values_name).read()
                ).astype("<f8", copy=False)
                segments = encrypt_channel_to_segments(
                    plaintext, offsets, lengths,
                    dataset_id=dataset_id_counter,
                    channel_name=cname,
                    key=key,
                )
                io.write_channel_segments(sig, f"{cname}_segments", segments)
                sig.delete_child(values_name)
                sig.set_attribute(f"{cname}_algorithm", "aes-256-gcm")

            if encrypt_headers:
                acquisition_mode = _get_int_attr(run_group,
                                                    "acquisition_mode", 0)
                count = _get_int_attr(idx, "count", len(offsets))
                rows = []
                ms_levels = np.asarray(idx.open_dataset("ms_levels").read())
                polarities = np.asarray(idx.open_dataset("polarities").read())
                rts = np.asarray(idx.open_dataset("retention_times").read())
                pmzs = np.asarray(idx.open_dataset("precursor_mzs").read())
                pcs = np.asarray(idx.open_dataset("precursor_charges").read())
                bpis = np.asarray(
                    idx.open_dataset("base_peak_intensities").read()
                )
                for i in range(count):
                    rows.append({
                        "acquisition_mode": acquisition_mode,
                        "ms_level": int(ms_levels[i]),
                        "polarity": int(polarities[i]),
                        "retention_time": float(rts[i]),
                        "precursor_mz": float(pmzs[i]),
                        "precursor_charge": int(pcs[i]),
                        "ion_mobility": 0.0,
                        "base_peak_intensity": float(bpis[i]),
                    })
                header_segs = encrypt_header_segments(
                    rows, dataset_id=dataset_id_counter, key=key,
                )
                io.write_au_header_segments(idx, "au_header_segments",
                                              header_segs)
                for name in ("retention_times", "ms_levels", "polarities",
                              "precursor_mzs", "precursor_charges",
                              "base_peak_intensities"):
                    if idx.has_child(name):
                        idx.delete_child(name)

            dataset_id_counter += 1

        # M90.1: extend encryption to genomic runs. Genomic signal
        # channels (sequences, qualities) are stored as plain uint8
        # datasets named without a "_values" suffix (different from
        # the MS layout). dataset_id_counter continues from where the
        # MS loop left off so genomic runs occupy IDs N+1..N+M
        # (matches the M89.2 transport convention).
        if study.has_child("genomic_runs"):
            g_runs = study.open_group("genomic_runs")
            g_run_names = [n for n in g_runs.child_names()
                            if not n.startswith("_") and g_runs.has_child(n)]
            for g_run_name in g_run_names:
                try:
                    g_group = g_runs.open_group(g_run_name)
                except KeyError:
                    continue
                g_sig = g_group.open_group("signal_channels")
                g_idx = g_group.open_group("genomic_index")
                from .genomic_index import _read_offsets_or_cumsum
                g_offsets = _read_offsets_or_cumsum(g_idx)
                g_lengths = np.asarray(
                    g_idx.open_dataset("lengths").read(), dtype="<u4",
                )
                # Genomic signal channels: sequences + qualities, both
                # uint8, both stored under their bare names (no
                # _values suffix per _write_genomic_run).
                for cname in ("sequences", "qualities"):
                    if not g_sig.has_child(cname):
                        continue
                    plaintext = np.asarray(
                        g_sig.open_dataset(cname).read(),
                    ).astype("<u1", copy=False)
                    segments = encrypt_channel_to_segments(
                        plaintext, g_offsets, g_lengths,
                        dataset_id=dataset_id_counter,
                        channel_name=cname,
                        key=key,
                        dtype="<u1",
                    )
                    io.write_channel_segments(
                        g_sig, f"{cname}_segments", segments,
                    )
                    g_sig.delete_child(cname)
                    g_sig.set_attribute(
                        f"{cname}_algorithm", "aes-256-gcm",
                    )
                dataset_id_counter += 1

        features_set.add("opt_per_au_encryption")
        if encrypt_headers:
            features_set.add("opt_encrypted_au_headers")
        io.write_feature_flags(root, version, sorted(features_set))
    finally:
        sp.close()


# Back-compat alias. Existing tests and external callers use this
# name; the provider-routed implementation is the new canonical
# entry point.
encrypt_per_au_file = encrypt_per_au


def decrypt_per_au(
    path: str,
    key: bytes,
    *,
    provider: str | None = None,
) -> dict[str, dict[str, np.ndarray]]:
    """Read-only: materialise the plaintext values of a per-AU
    encrypted file. Returns ``{run_name: {channel_name: float64
    ndarray}}``; when ``opt_encrypted_au_headers`` is set the result
    also carries ``"__au_headers__"`` as a list of dicts.

    Routes through :func:`ttio.providers.open_provider` so the
    file can live in any backend that supports ``VL_BYTES`` compound
    reads.
    """
    from . import _hdf5_io as io
    from .providers.registry import open_provider

    if len(key) != 32:
        raise ValueError(f"AES-256-GCM key must be 32 bytes, got {len(key)}")

    sp = open_provider(path, provider=provider, mode="r")
    try:
        root = sp.root_group()
        _, features = io.read_feature_flags(root)
        headers_encrypted = "opt_encrypted_au_headers" in features
        if "opt_per_au_encryption" not in features:
            raise ValueError(
                f"file at {path!r} does not carry opt_per_au_encryption"
            )

        study = root.open_group("study")
        ms_runs = study.open_group("ms_runs")
        run_names = [n for n in ms_runs.child_names()
                      if not n.startswith("_") and ms_runs.has_child(n)]

        out: dict[str, dict] = {}
        dataset_id_counter = 1
        for run_name in run_names:
            try:
                run_group = ms_runs.open_group(run_name)
            except KeyError:
                continue
            sig = run_group.open_group("signal_channels")
            idx = run_group.open_group("spectrum_index")
            run_out: dict[str, Any] = {}
            channel_names = _split_channel_names(
                _get_str_attr(sig, "channel_names")
            )
            for cname in channel_names:
                seg_name = f"{cname}_segments"
                if not sig.has_child(seg_name):
                    continue
                segments = io.read_channel_segments(sig, seg_name)
                run_out[cname] = decrypt_channel_from_segments(
                    segments,
                    dataset_id=dataset_id_counter,
                    channel_name=cname,
                    key=key,
                )

            if headers_encrypted and idx.has_child("au_header_segments"):
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

        # M90.1: also materialise genomic_runs. dataset_id continues
        # from where the MS loop left off so AAD reconstruction
        # matches the encrypt path exactly.
        if study.has_child("genomic_runs"):
            g_runs = study.open_group("genomic_runs")
            g_run_names = [n for n in g_runs.child_names()
                            if not n.startswith("_") and g_runs.has_child(n)]
            for g_run_name in g_run_names:
                try:
                    g_group = g_runs.open_group(g_run_name)
                except KeyError:
                    continue
                g_sig = g_group.open_group("signal_channels")
                g_run_out: dict[str, Any] = {}
                for cname in ("sequences", "qualities"):
                    seg_name = f"{cname}_segments"
                    if not g_sig.has_child(seg_name):
                        continue
                    segments = io.read_channel_segments(g_sig, seg_name)
                    g_run_out[cname] = decrypt_channel_from_segments(
                        segments,
                        dataset_id=dataset_id_counter,
                        channel_name=cname,
                        key=key,
                        dtype="<u1",
                    )
                out[g_run_name] = g_run_out
                dataset_id_counter += 1

        return out
    finally:
        sp.close()


# Back-compat alias.
decrypt_per_au_file = decrypt_per_au


# ────────────────────────────────────────────────────────────────────
# M90.4 — region-based per-AU encryption.
#
# Per-AU dispatch keyed on the genomic_index `chromosomes` column:
# reads on chromosomes whose name appears in `key_map` are AES-256-GCM
# encrypted with that key; reads on chromosomes NOT in `key_map`
# are stored as "clear segments" — the same `<channel>_segments`
# compound is reused, but with a length-0 IV / length-0 tag and the
# raw plaintext bytes stored in the `ciphertext` field. The decode
# path branches on `len(iv)`, so old M90.1 files (every IV is exactly
# 12 bytes) still decode unchanged.
#
# This is intentionally non-invasive: no schema changes, no extra
# field, no migration. The empty-IV sentinel is unambiguous because
# AES-GCM IVs are always exactly 12 bytes.
# ────────────────────────────────────────────────────────────────────


_HEADERS_KEY_NAME = "_headers"


def encrypt_per_au_by_region(
    path: str,
    key_map: dict[str, bytes],
    *,
    provider: str | None = None,
) -> None:
    """Encrypt genomic signal channels with a per-chromosome key map.

    Reads whose chromosome appears in ``key_map`` are AES-256-GCM
    encrypted with the corresponding 32-byte key. Reads on
    chromosomes NOT in ``key_map`` are stored as "clear segments"
    (length-0 IV + plaintext bytes in the ciphertext slot).

    M90.11: when ``key_map`` contains the reserved key ``"_headers"``,
    the genomic_index columns (chromosomes, positions, mapping_qualities,
    flags) are ALSO encrypted with that key — closing the gap where
    a reader without any signal-channel key could still see read
    locations + counts. ``offsets`` and ``lengths`` always stay
    plaintext (structural framing, not semantic PHI).

    MS runs are NOT touched — chromosome is a genomic concept.
    Use the existing :func:`encrypt_per_au` for MS encryption.

    The on-disk schema for signal channels is identical to M90.1
    (same ``<channel>_segments`` compound). The reader distinguishes
    encrypted vs clear segments by ``len(seg.iv)``.
    """
    from . import _hdf5_io as io
    from .providers.registry import open_provider

    for chrom, key in key_map.items():
        if len(key) != 32:
            raise ValueError(
                f"AES-256-GCM key for chromosome {chrom!r} must be "
                f"32 bytes, got {len(key)}"
            )

    chromosome_keys = {
        k: v for k, v in key_map.items() if k != _HEADERS_KEY_NAME
    }
    headers_key = key_map.get(_HEADERS_KEY_NAME)

    sp = open_provider(path, provider=provider, mode="a")
    try:
        root = sp.root_group()
        version, features = io.read_feature_flags(root)
        features_set = set(features)

        study = root.open_group("study")
        if not study.has_child("genomic_runs"):
            return  # no genomic data — nothing to encrypt

        # Match the dataset_id_counter convention from the MS path:
        # MS runs occupy 1..N, genomic N+1..N+M. For region-only
        # encryption we still walk MS first to get the count even
        # though we don't touch it.
        if study.has_child("ms_runs"):
            ms_runs = study.open_group("ms_runs")
            n_ms = sum(
                1 for n in ms_runs.child_names()
                if not n.startswith("_") and ms_runs.has_child(n)
            )
        else:
            n_ms = 0
        dataset_id_counter = n_ms + 1

        g_runs = study.open_group("genomic_runs")
        g_run_names = [n for n in g_runs.child_names()
                        if not n.startswith("_") and g_runs.has_child(n)]
        for g_run_name in g_run_names:
            try:
                g_group = g_runs.open_group(g_run_name)
            except KeyError:
                continue
            g_sig = g_group.open_group("signal_channels")
            g_idx = g_group.open_group("genomic_index")
            from .genomic_index import _read_offsets_or_cumsum
            g_offsets = _read_offsets_or_cumsum(g_idx)
            g_lengths = np.asarray(
                g_idx.open_dataset("lengths").read(), dtype="<u4",
            )
            chromosomes = _read_chromosomes(g_idx)

            # Signal-channel encryption runs in two cases:
            #   (a) caller supplied chromosome keys (M90.4 path)
            #   (b) caller supplied an empty key_map (M90.4 no-op
            #       behaviour: file gets opt_per_au_encryption with
            #       all-clear segments)
            # The only path that SKIPS signal-channel encryption is
            # the M90.11 headers-only case (key_map == {"_headers": K}).
            run_signal_encrypt = bool(chromosome_keys) or headers_key is None
            if run_signal_encrypt:
                for cname in ("sequences", "qualities"):
                    if not g_sig.has_child(cname):
                        continue
                    plaintext = np.asarray(
                        g_sig.open_dataset(cname).read(),
                    ).astype("<u1", copy=False)
                    segments = _encrypt_channel_with_dispatch(
                        plaintext, g_offsets, g_lengths, chromosomes,
                        dataset_id=dataset_id_counter,
                        channel_name=cname,
                        key_map=chromosome_keys,
                    )
                    io.write_channel_segments(
                        g_sig, f"{cname}_segments", segments,
                    )
                    g_sig.delete_child(cname)
                    g_sig.set_attribute(
                        f"{cname}_algorithm", "aes-256-gcm-by-region",
                    )

            # M90.11: encrypt genomic_index columns under the
            # reserved _headers key.
            if headers_key is not None:
                _encrypt_genomic_index(
                    g_idx,
                    dataset_id=dataset_id_counter,
                    key=headers_key,
                    chromosomes=chromosomes,
                )

            dataset_id_counter += 1

        # Feature-flag set rules:
        #  * opt_per_au_encryption — set whenever signal-channel
        #    encryption ran (chromosome keys present OR empty key_map
        #    no-op path) OR when headers_key is provided.
        #  * opt_region_keyed_encryption — only when at least one
        #    chromosome key was provided. Empty key_map leaves the
        #    file with all-clear segments — that's M90.4's no-op
        #    semantics, not a region-keyed file.
        #  * opt_encrypted_au_headers — set when _headers key was
        #    used (M90.11).
        if chromosome_keys or headers_key is None:
            features_set.add("opt_per_au_encryption")
        if chromosome_keys:
            features_set.add("opt_region_keyed_encryption")
        if headers_key is not None:
            features_set.add("opt_per_au_encryption")
            features_set.add("opt_encrypted_au_headers")
        io.write_feature_flags(root, version, sorted(features_set))
    finally:
        sp.close()


def _encrypt_genomic_index(
    g_idx,
    *,
    dataset_id: int,
    key: bytes,
    chromosomes: list[str],
) -> None:
    """M90.11: encrypt the four genomic_index columns
    (chromosomes, positions, mapping_qualities, flags) and replace
    the plaintext datasets with ``<column>_encrypted`` blobs
    containing iv || tag || ciphertext. offsets/lengths stay
    plaintext (structural framing).

    Per-column AES-GCM with AAD = "genomic_headers:" + dataset_id +
    ":" + column_name. Chromosomes (a VL compound) is JSON-serialised
    before encryption; positions/mapping_qualities/flags are
    serialised as little-endian byte buffers.
    """
    import json
    # Serialise each column to bytes.
    columns: dict[str, bytes] = {
        "chromosomes": json.dumps(chromosomes).encode("utf-8"),
        "positions": np.asarray(
            g_idx.open_dataset("positions").read(), dtype="<i8",
        ).tobytes(),
        "mapping_qualities": np.asarray(
            g_idx.open_dataset("mapping_qualities").read(), dtype="<u1",
        ).tobytes(),
        "flags": np.asarray(
            g_idx.open_dataset("flags").read(), dtype="<u4",
        ).tobytes(),
    }
    for col_name, plaintext in columns.items():
        aad = f"genomic_headers:{dataset_id}:{col_name}".encode("ascii")
        iv, tag, ciphertext = encrypt_with_aad(plaintext, key, aad)
        blob = bytes(iv) + bytes(tag) + bytes(ciphertext)
        # Delete plaintext dataset (or compound) and write the
        # encrypted blob as a uint8 1-D dataset.
        if g_idx.has_child(col_name):
            g_idx.delete_child(col_name)
        # L1 (Task #82 Phase B.1): the on-disk chromosomes column is
        # decomposed into chromosome_ids + chromosome_names. When
        # encrypting the logical "chromosomes" column we also delete
        # those L1 datasets so plaintext doesn't linger alongside the
        # encrypted blob.
        if col_name == "chromosomes":
            for sub in ("chromosome_ids", "chromosome_names"):
                if g_idx.has_child(sub):
                    g_idx.delete_child(sub)
        ds = g_idx.create_dataset(
            f"{col_name}_encrypted", Precision.UINT8, len(blob),
        )
        ds.write(np.frombuffer(blob, dtype=np.uint8))


def _decrypt_genomic_index(
    g_idx,
    *,
    dataset_id: int,
    key: bytes,
) -> dict:
    """Inverse of :func:`_encrypt_genomic_index`. Returns
    ``{"chromosomes": list[str], "positions": np.ndarray,
    "mapping_qualities": np.ndarray, "flags": np.ndarray}``.
    """
    import json
    out: dict = {}
    column_dtypes = {
        "chromosomes": None,  # JSON-deserialised
        "positions": np.dtype("<i8"),
        "mapping_qualities": np.dtype("<u1"),
        "flags": np.dtype("<u4"),
    }
    for col_name, dtype in column_dtypes.items():
        enc_name = f"{col_name}_encrypted"
        if not g_idx.has_child(enc_name):
            raise ValueError(
                f"genomic_index/{enc_name} missing — file does not "
                f"appear to carry M90.11 encrypted headers"
            )
        blob = bytes(np.asarray(g_idx.open_dataset(enc_name).read()).tobytes())
        if len(blob) < 12 + 16:
            raise ValueError(
                f"genomic_index/{enc_name} too short for IV+TAG"
            )
        iv = blob[:12]
        tag = blob[12:28]
        ciphertext = blob[28:]
        aad = f"genomic_headers:{dataset_id}:{col_name}".encode("ascii")
        plaintext = decrypt_with_aad(iv, tag, ciphertext, key, aad)
        if dtype is None:
            out[col_name] = json.loads(plaintext.decode("utf-8"))
        else:
            out[col_name] = np.frombuffer(plaintext, dtype=dtype).copy()
    return out


def decrypt_per_au_by_region(
    path: str,
    key_map: dict[str, bytes],
    *,
    provider: str | None = None,
) -> dict[str, dict[str, np.ndarray]]:
    """Decrypt a region-encrypted file using a per-chromosome key map.

    Caller may supply only a subset of the keys used at encryption
    time. Clear segments (length-0 IV) decode without any key.
    Encrypted segments whose chromosome key isn't in ``key_map``
    raise the underlying AES-GCM authentication error.

    Returns ``{run_name: {channel_name: uint8 ndarray}}`` like
    :func:`decrypt_per_au`. MS runs are decrypted via the standard
    path inside this function as a convenience — but only if all
    MS runs were encrypted (mixed MS-encrypted / region-genomic-
    encrypted is unusual and supported here only because the
    counter convention guarantees correct AAD reconstruction).
    """
    from . import _hdf5_io as io
    from .providers.registry import open_provider

    sp = open_provider(path, provider=provider, mode="r")
    try:
        root = sp.root_group()
        _, features = io.read_feature_flags(root)
        if "opt_per_au_encryption" not in features:
            raise ValueError(
                f"file at {path!r} does not carry opt_per_au_encryption"
            )

        study = root.open_group("study")
        out: dict[str, dict] = {}

        # Walk MS runs first to keep the dataset_id counter aligned.
        # MS reads use the legacy single-key path — region encryption
        # only touches genomic. If MS is encrypted under a different
        # key, callers should use the standard decrypt_per_au.
        if study.has_child("ms_runs"):
            ms_runs = study.open_group("ms_runs")
            ms_run_names = [n for n in ms_runs.child_names()
                             if not n.startswith("_") and ms_runs.has_child(n)]
        else:
            ms_run_names = []
        dataset_id_counter = len(ms_run_names) + 1

        # M90.11: when the file carries opt_encrypted_au_headers,
        # decrypt requires the reserved "_headers" key. Without it,
        # we can't even reconstruct the chromosomes column needed
        # for per-AU dispatch on signal channels.
        headers_encrypted = "opt_encrypted_au_headers" in features
        headers_key = key_map.get(_HEADERS_KEY_NAME)
        if headers_encrypted and headers_key is None:
            raise ValueError(
                f"file at {path!r} carries opt_encrypted_au_headers; "
                f"caller must provide a '_headers' entry in key_map "
                f"to decrypt the genomic_index columns"
            )
        chromosome_keys = {
            k: v for k, v in key_map.items() if k != _HEADERS_KEY_NAME
        }

        if not study.has_child("genomic_runs"):
            return out
        g_runs = study.open_group("genomic_runs")
        g_run_names = [n for n in g_runs.child_names()
                        if not n.startswith("_") and g_runs.has_child(n)]
        for g_run_name in g_run_names:
            try:
                g_group = g_runs.open_group(g_run_name)
            except KeyError:
                continue
            g_sig = g_group.open_group("signal_channels")
            g_idx = g_group.open_group("genomic_index")
            g_run_out: dict[str, Any] = {}

            # M90.11: decrypt the genomic_index columns first so the
            # per-AU signal-channel dispatch (which needs chromosomes)
            # can proceed even when the source columns were encrypted.
            if headers_encrypted:
                index_plain = _decrypt_genomic_index(
                    g_idx,
                    dataset_id=dataset_id_counter,
                    key=headers_key,
                )
                chromosomes = list(index_plain["chromosomes"])
                g_run_out["__index__"] = index_plain
            else:
                chromosomes = _read_chromosomes(g_idx)

            for cname in ("sequences", "qualities"):
                seg_name = f"{cname}_segments"
                if not g_sig.has_child(seg_name):
                    continue
                segments = io.read_channel_segments(g_sig, seg_name)
                g_run_out[cname] = _decrypt_channel_with_dispatch(
                    segments, chromosomes,
                    dataset_id=dataset_id_counter,
                    channel_name=cname,
                    key_map=chromosome_keys,
                )
            out[g_run_name] = g_run_out
            dataset_id_counter += 1

        return out
    finally:
        sp.close()


def _read_chromosomes(idx_group) -> list[str]:
    """Read the genomic_index chromosome columns. Returns a list[str],
    one entry per read.

    L1 (Task #82 Phase B.1): chromosomes are stored as
    ``chromosome_ids`` (uint16) + ``chromosome_names`` (compound
    lookup); materialize back to ``list[str]`` for callers that still
    want the per-read view.
    """
    from . import _hdf5_io as io
    import numpy as np
    ids_ds = idx_group.open_dataset("chromosome_ids")
    ids = np.asarray(ids_ds.read(), dtype=np.uint16)
    name_rows = io.read_compound_dataset(idx_group, "chromosome_names")
    name_table: list[str] = []
    for row in name_rows:
        v = row["name"]
        name_table.append(v.decode("utf-8") if isinstance(v, bytes) else v)
    return [name_table[i] for i in ids.tolist()]


def _encrypt_channel_with_dispatch(
    plaintext_flat: np.ndarray,
    offsets: np.ndarray,
    lengths: np.ndarray,
    chromosomes: list[str],
    *,
    dataset_id: int,
    channel_name: str,
    key_map: dict[str, bytes],
) -> list[ChannelSegment]:
    """Per-AU dispatch: encrypt with key_map[chrom] if present, else
    emit a clear segment. ``plaintext_flat`` is uint8 bytes
    (genomic-only path)."""
    if plaintext_flat.dtype != np.dtype("<u1"):
        plaintext_flat = plaintext_flat.astype("<u1", copy=False)
    segments: list[ChannelSegment] = []
    for au_seq, (off, length, chrom) in enumerate(
        zip(offsets, lengths, chromosomes)
    ):
        off_i = int(off)
        length_i = int(length)
        chunk = plaintext_flat[off_i:off_i + length_i].tobytes()
        key = key_map.get(chrom)
        if key is None:
            # Clear segment: empty IV + tag, plaintext bytes ride in
            # the ciphertext slot.
            segments.append(ChannelSegment(
                offset=off_i, length=length_i,
                iv=b"", tag=b"", ciphertext=chunk,
            ))
        else:
            aad = aad_for_channel(dataset_id, au_seq, channel_name)
            iv, tag, ciphertext = encrypt_with_aad(chunk, key, aad)
            segments.append(ChannelSegment(
                offset=off_i, length=length_i,
                iv=iv, tag=tag, ciphertext=ciphertext,
            ))
    return segments


def _decrypt_channel_with_dispatch(
    segments,
    chromosomes: list[str],
    *,
    dataset_id: int,
    channel_name: str,
    key_map: dict[str, bytes],
) -> np.ndarray:
    """Inverse of :func:`_encrypt_channel_with_dispatch`. Branches on
    ``len(seg.iv)``: 0 = clear segment, 12 = AES-GCM."""
    chunks: list[bytes] = []
    for au_seq, seg in enumerate(segments):
        if len(seg.iv) == 0:
            # Clear segment: ciphertext is the plaintext.
            chunks.append(bytes(seg.ciphertext))
            continue
        chrom = chromosomes[au_seq] if au_seq < len(chromosomes) else ""
        key = key_map.get(chrom)
        if key is None:
            raise ValueError(
                f"chromosome {chrom!r} segment {au_seq} is encrypted "
                f"but key_map has no entry for {chrom!r}"
            )
        aad = aad_for_channel(dataset_id, au_seq, channel_name)
        plaintext = decrypt_with_aad(seg.iv, seg.tag, seg.ciphertext, key, aad)
        if len(plaintext) != seg.length:
            raise ValueError(
                f"channel {channel_name!r} segment {au_seq}: "
                f"decrypted {len(plaintext)} bytes, expected {seg.length}"
            )
        chunks.append(plaintext)
    return np.frombuffer(b"".join(chunks), dtype="<u1").copy()
