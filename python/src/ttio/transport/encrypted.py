"""v1.0 encrypted transport paths.

Bypasses the high-level :class:`Spectrum` / :class:`SignalArray`
decode machinery (which requires the key to materialise) and reads
HDF5 segment compounds directly, so encrypted bytes travel through
transport without being decrypted in transit.

Cross-language equivalents: ObjC
``TTIOEncryptedTransport`` · Java
``global.thalion.ttio.transport.EncryptedTransport``.
"""
from __future__ import annotations

import struct
from pathlib import Path
from typing import BinaryIO

from .. import _hdf5_io as io
from ..feature_flags import (
    OPT_ENCRYPTED_AU_HEADERS,
    OPT_PER_AU_ENCRYPTION,
)
from .codec import (
    TransportWriter,
    _SPECTRUM_CLASS_TO_WIRE,
    _instrument_config_json,  # reused via wrapper below
)
from .packets import (
    AccessUnit,
    ChannelData,
    PacketFlag,
    PacketHeader,
    PacketType,
    now_ns,
    pack_string,
)


def is_per_au_encrypted(path: str | Path,
                          *,
                          provider: str | None = None) -> bool:
    """Return True if the file on disk carries ``opt_per_au_encryption``.

    Routes through :func:`ttio.providers.open_provider` so any
    backend works uniformly."""
    from ..providers.registry import open_provider
    sp = open_provider(str(path), provider=provider, mode="r")
    try:
        _, features = io.read_feature_flags(sp.root_group())
    finally:
        sp.close()
    return OPT_PER_AU_ENCRYPTION in features


def write_encrypted_dataset(
    writer: TransportWriter,
    ttio_path: str | Path,
    *,
    provider: str | None = None,
) -> None:
    """Emit a full transport stream from a per-AU-encrypted .tio
    file. Bypasses :class:`SpectralDataset.open` (which would refuse
    the file because the plaintext ``<channel>_values`` are absent)
    and walks the source via the StorageProvider abstraction so every
    backend that supports VL_BYTES compound reads works.

    ProtectionMetadata is emitted after ``StreamHeader``; encrypted
    AUs carry the flag bits defined in ``docs/transport-spec.md``
    §3.1.1.
    """
    from ..providers.registry import open_provider

    sp = open_provider(str(ttio_path), provider=provider, mode="r")
    try:
        root = sp.root_group()
        _, features = io.read_feature_flags(root)
        if OPT_PER_AU_ENCRYPTION not in features:
            raise ValueError(
                f"{ttio_path!r} does not carry opt_per_au_encryption"
            )
        headers_encrypted = OPT_ENCRYPTED_AU_HEADERS in features

        study = root.open_group("study")
        title = io.read_string_attr(study, "title") or ""
        isa = io.read_string_attr(study, "isa_investigation_id") or ""
        ms_runs = study.open_group("ms_runs")
        run_items = [(n, ms_runs.open_group(n))
                      for n in ms_runs.child_names()
                      if not n.startswith("_") and ms_runs.has_child(n)]

        writer.write_stream_header(
            format_version="1.2",
            title=title,
            isa_investigation=isa,
            features=list(features),
            n_datasets=len(run_items),
        )

        # One ProtectionMetadata per dataset (per run). The wrapped
        # DEK is read from the channel's @<channel>_wrapped_dek attr
        # if present; otherwise an empty byte string is emitted. The
        # receiver is responsible for KEK unwrap via out-of-band
        # key management.
        for dataset_id, (run_name, run_group) in enumerate(run_items, start=1):
            sig = run_group.open_group("signal_channels")
            # Probe the first channel for the algorithm / wrapped DEK
            # metadata. All channels in a run share the same DEK in
            # the v1.0 design.
            channel_names = [
                c for c in (io.read_string_attr(sig, "channel_names") or "").split(",")
                if c
            ]
            first_channel = channel_names[0] if channel_names else "intensity"
            cipher_suite = (io.read_string_attr(sig, f"{first_channel}_algorithm")
                              or "aes-256-gcm")
            kek_algorithm = (io.read_string_attr(sig, f"{first_channel}_kek_algorithm")
                               or "")
            wrapped_dek_attr = f"{first_channel}_wrapped_dek"
            if sig.has_attribute(wrapped_dek_attr):
                wrapped_dek = bytes(sig.get_attribute(wrapped_dek_attr))
            else:
                wrapped_dek = b""
            _emit_protection_metadata(
                writer,
                dataset_id=dataset_id,
                cipher_suite=cipher_suite,
                kek_algorithm=kek_algorithm,
                wrapped_dek=wrapped_dek,
                signature_algorithm="",
                public_key=b"",
            )

            spectrum_class = (io.read_string_attr(run_group, "spectrum_class")
                              or "TTIOMassSpectrum")
            acquisition_mode = io.read_int_attr(run_group, "acquisition_mode",
                                                  default=0) or 0
            # count discovered from any channel's segment dataset length
            first_segs = io.read_channel_segments(sig, f"{first_channel}_segments")
            n_spectra = len(first_segs)

            writer.write_dataset_header(
                dataset_id=dataset_id,
                name=run_name,
                acquisition_mode=int(acquisition_mode),
                spectrum_class=spectrum_class,
                channel_names=list(channel_names),
                instrument_json="{}",   # skipped for brevity; non-PHI
                expected_au_count=n_spectra,
            )

        # Emit AUs for each run
        for dataset_id, (run_name, run_group) in enumerate(run_items, start=1):
            sig = run_group.open_group("signal_channels")
            idx = run_group.open_group("spectrum_index")
            channel_names = [
                c for c in (io.read_string_attr(sig, "channel_names") or "").split(",")
                if c
            ]
            # Pre-load all segments for each channel + header segments.
            channel_segments_by_name = {
                c: io.read_channel_segments(sig, f"{c}_segments")
                for c in channel_names
            }
            if headers_encrypted:
                header_segs = io.read_au_header_segments(idx, "au_header_segments")
            else:
                header_segs = None
                # Read plaintext index arrays via the provider.
                def _read_or_none(name):
                    return (idx.open_dataset(name).read()
                             if idx.has_child(name) else None)
                rts = _read_or_none("retention_times")
                ms_levels = _read_or_none("ms_levels")
                polarities = _read_or_none("polarities")
                precursor_mzs = _read_or_none("precursor_mzs")
                precursor_charges = _read_or_none("precursor_charges")
                base_peak = _read_or_none("base_peak_intensities")

            n = len(next(iter(channel_segments_by_name.values())))
            wire_class = _SPECTRUM_CLASS_TO_WIRE.get(spectrum_class, 0)

            for i in range(n):
                # Build encrypted ChannelData list.
                channels = []
                for cname in channel_names:
                    seg = channel_segments_by_name[cname][i]
                    data = seg.iv + seg.tag + seg.ciphertext
                    channels.append(ChannelData(
                        name=cname,
                        precision=1,     # float64
                        compression=0,   # NONE (inner plaintext would be f64 raw)
                        n_elements=seg.length,
                        data=data,
                    ))

                if headers_encrypted:
                    # Wire: spectrum_class(u8) n_channels(u8) IV(12) TAG(16)
                    # ct(36) [channels] [pixel optional].
                    hdr_seg = header_segs[i]
                    payload = (
                        struct.pack("<BB", int(wire_class) & 0xFF, len(channels) & 0xFF)
                        + hdr_seg.iv + hdr_seg.tag + hdr_seg.ciphertext
                    )
                    for ch in channels:
                        payload += ch.to_bytes()
                    _emit_raw_au(
                        writer,
                        dataset_id=dataset_id,
                        au_sequence=i,
                        payload=payload,
                        flags=int(PacketFlag.ENCRYPTED) | int(PacketFlag.ENCRYPTED_HEADER),
                    )
                else:
                    # Plaintext filter header, encrypted channels.
                    au = AccessUnit(
                        spectrum_class=wire_class,
                        acquisition_mode=int(acquisition_mode),
                        ms_level=int(ms_levels[i]) if ms_levels is not None else 0,
                        polarity=_wire_polarity(int(polarities[i])) if polarities is not None else 2,
                        retention_time=float(rts[i]) if rts is not None else 0.0,
                        precursor_mz=float(precursor_mzs[i]) if precursor_mzs is not None else 0.0,
                        precursor_charge=int(precursor_charges[i]) if precursor_charges is not None else 0,
                        ion_mobility=0.0,
                        base_peak_intensity=float(base_peak[i]) if base_peak is not None else 0.0,
                        channels=channels,
                    )
                    _emit_raw_au(
                        writer,
                        dataset_id=dataset_id,
                        au_sequence=i,
                        payload=au.to_bytes(),
                        flags=int(PacketFlag.ENCRYPTED),
                    )

            writer.write_end_of_dataset(
                dataset_id=dataset_id,
                final_au_sequence=n,
            )
        writer.write_end_of_stream()
    finally:
        sp.close()


def _wire_polarity(raw: int) -> int:
    if raw == 1: return 0      # POSITIVE
    if raw == -1: return 1     # NEGATIVE
    return 2                   # UNKNOWN


def _emit_protection_metadata(
    writer: TransportWriter,
    *,
    dataset_id: int,
    cipher_suite: str,
    kek_algorithm: str,
    wrapped_dek: bytes,
    signature_algorithm: str,
    public_key: bytes,
) -> None:
    payload = (
        pack_string(cipher_suite, width=2)
        + pack_string(kek_algorithm, width=2)
        + struct.pack("<I", len(wrapped_dek))
        + wrapped_dek
        + pack_string(signature_algorithm, width=2)
        + struct.pack("<I", len(public_key))
        + public_key
    )
    writer._emit(PacketType.PROTECTION_METADATA, payload,
                  dataset_id=dataset_id)


def _emit_raw_au(
    writer: TransportWriter,
    *,
    dataset_id: int,
    au_sequence: int,
    payload: bytes,
    flags: int,
) -> None:
    """Bypass the public write_access_unit so custom flag bits (including
    ENCRYPTED_HEADER) make it onto the packet header."""
    header = PacketHeader(
        packet_type=int(PacketType.ACCESS_UNIT),
        flags=flags,
        dataset_id=dataset_id,
        au_sequence=au_sequence,
        payload_length=len(payload),
        timestamp_ns=now_ns(),
    )
    writer._stream.write(header.to_bytes())
    writer._stream.write(payload)
    if writer._use_checksum:
        from .packets import crc32c
        writer._stream.write(struct.pack("<I", crc32c(payload)))


# ---------------------------------------------------------------------
# Reader side: encrypted stream → new .tio file
# ---------------------------------------------------------------------


def read_encrypted_to_file(
    stream_source,
    output_path: str | Path,
    *,
    provider: str | None = None,
) -> dict:
    """Materialise an encrypted transport stream into a new .tio
    file preserving the encrypted ChannelData bytes verbatim. Routes
    through :func:`ttio.providers.open_provider` so the output
    can live in any backend that supports VL_BYTES compound writes.

    ``stream_source`` may be a ``BinaryIO`` or a path to a ``.tis``
    file. The output file is written with ``opt_per_au_encryption``
    (and ``opt_encrypted_au_headers`` when the source stream used
    encrypted headers). The receiver does NOT decrypt in transit —
    the emitted file carries the same ciphertext the sender stored.

    Returns a metadata dict summarising the stream
    (``{"title", "runs": {run_name: {"n_spectra", "channels"}}}``)
    mainly for testing / introspection.
    """
    from .codec import TransportReader
    from ..encryption_per_au import ChannelSegment, HeaderSegment
    from ..providers.registry import open_provider

    # Accumulate stream → in-memory structure, then emit .tio at the end.
    stream_meta: dict = {}
    datasets: dict[int, dict] = {}  # dataset_id -> {name, channel_names, ...}
    protection: dict[int, dict] = {}

    reader = TransportReader(stream_source)
    for header, payload in reader.iter_packets():
        ptype = header.packet_type
        if ptype == int(PacketType.STREAM_HEADER):
            from .codec import _decode_stream_header
            stream_meta = _decode_stream_header(payload)
        elif ptype == int(PacketType.DATASET_HEADER):
            from .codec import _decode_dataset_header
            meta = _decode_dataset_header(payload)
            did = meta["dataset_id"]
            datasets[did] = {
                "meta": meta,
                "channel_segments": {c: [] for c in meta["channel_names"]},
                "header_segments": [],
                "used_encrypted_headers": False,
            }
        elif ptype == int(PacketType.PROTECTION_METADATA):
            pm = _decode_protection_metadata(payload)
            protection[header.dataset_id] = pm
        elif ptype == int(PacketType.ACCESS_UNIT):
            did = header.dataset_id
            if did not in datasets:
                raise ValueError(f"AU for unknown dataset_id {did}")
            _ingest_encrypted_au(
                datasets[did],
                header=header,
                payload=payload,
                dataset_id=did,
                au_sequence=header.au_sequence,
            )
        elif ptype == int(PacketType.END_OF_STREAM):
            break
        # EndOfDataset / Annotation / Provenance / Chromatogram: skip for now.

    # Emit the .tio with encrypted compounds.
    features = set(stream_meta.get("features", []))
    features.add(OPT_PER_AU_ENCRYPTION)
    any_encrypted_headers = any(d["used_encrypted_headers"] for d in datasets.values())
    if any_encrypted_headers:
        features.add(OPT_ENCRYPTED_AU_HEADERS)

    sp_out = open_provider(str(output_path), provider=provider, mode="w")
    try:
        root = sp_out.root_group()
        io.write_feature_flags(root, "1.1", sorted(features))
        study = root.create_group("study")
        io.write_fixed_string_attr(study, "title", stream_meta.get("title", ""))
        io.write_fixed_string_attr(study, "isa_investigation_id",
                                     stream_meta.get("isa_investigation", ""))
        ms_runs = study.create_group("ms_runs")
        names = ",".join(d["meta"]["name"] for _, d in sorted(datasets.items()))
        io.write_fixed_string_attr(ms_runs, "_run_names", names)

        import numpy as np
        from ..enums import Precision
        for did, d in sorted(datasets.items()):
            meta = d["meta"]
            run_group = ms_runs.create_group(meta["name"])
            io.write_int_attr(run_group, "acquisition_mode",
                                meta["acquisition_mode"])
            io.write_int_attr(run_group, "spectrum_count",
                                len(d["header_segments"])
                                if d["used_encrypted_headers"]
                                else len(next(iter(d["channel_segments"].values()))))
            io.write_fixed_string_attr(run_group, "spectrum_class",
                                         meta["spectrum_class"])
            cfg = run_group.create_group("instrument_config")
            for fname in ("manufacturer", "model", "serial_number",
                            "source_type", "analyzer_type", "detector_type"):
                io.write_fixed_string_attr(cfg, fname, "")

            sig = run_group.create_group("signal_channels")
            io.write_fixed_string_attr(sig, "channel_names",
                                         ",".join(meta["channel_names"]))
            for cname in meta["channel_names"]:
                segs = d["channel_segments"][cname]
                io.write_channel_segments(sig, f"{cname}_segments", segs)
                sig.set_attribute(f"{cname}_algorithm", "aes-256-gcm")
                pm = protection.get(did)
                if pm:
                    sig.set_attribute(f"{cname}_wrapped_dek",
                                         pm["wrapped_dek"])
                    sig.set_attribute(f"{cname}_kek_algorithm",
                                         pm["kek_algorithm"])

            idx = run_group.create_group("spectrum_index")
            first_segs = next(iter(d["channel_segments"].values()))
            io.write_int_attr(idx, "count", len(first_segs))
            offsets_arr = np.array([s.offset for s in first_segs], dtype="<u8")
            lengths_arr = np.array([s.length for s in first_segs], dtype="<u4")
            ds_off = idx.create_dataset("offsets", Precision.INT64,
                                           len(first_segs))
            ds_off.write(offsets_arr)
            ds_len = idx.create_dataset("lengths", Precision.UINT32,
                                           len(first_segs))
            ds_len.write(lengths_arr)
            if d["used_encrypted_headers"]:
                io.write_au_header_segments(idx, "au_header_segments",
                                              d["header_segments"])
    finally:
        sp_out.close()

    return {
        "title": stream_meta.get("title", ""),
        "runs": {d["meta"]["name"]: {
            "n_spectra": len(d["header_segments"])
                           if d["used_encrypted_headers"]
                           else len(next(iter(d["channel_segments"].values()))),
            "channels": list(d["meta"]["channel_names"]),
            "encrypted_headers": d["used_encrypted_headers"],
        } for d in datasets.values()},
    }


def _decode_protection_metadata(payload: bytes) -> dict:
    from .codec import unpack_string
    off = 0
    cipher_suite, off = unpack_string(payload, off, width=2)
    kek_algorithm, off = unpack_string(payload, off, width=2)
    (wrapped_len,) = struct.unpack_from("<I", payload, off); off += 4
    wrapped_dek = bytes(payload[off:off + wrapped_len]); off += wrapped_len
    signature_algorithm, off = unpack_string(payload, off, width=2)
    (pk_len,) = struct.unpack_from("<I", payload, off); off += 4
    public_key = bytes(payload[off:off + pk_len])
    return {
        "cipher_suite": cipher_suite,
        "kek_algorithm": kek_algorithm,
        "wrapped_dek": wrapped_dek,
        "signature_algorithm": signature_algorithm,
        "public_key": public_key,
    }


def _ingest_encrypted_au(d: dict, *, header, payload: bytes,
                           dataset_id: int, au_sequence: int) -> None:
    from ..encryption_per_au import ChannelSegment, HeaderSegment

    flags = header.flags
    encrypted_header = bool(flags & int(PacketFlag.ENCRYPTED_HEADER))
    encrypted_channel = bool(flags & int(PacketFlag.ENCRYPTED))
    if not encrypted_channel:
        raise ValueError("encrypted-transport reader saw plaintext AU")

    d["used_encrypted_headers"] = encrypted_header

    if encrypted_header:
        # Wire: spectrum_class(u8) n_channels(u8) IV(12) TAG(16)
        # ciphertext(36) [channels].
        off = 0
        spectrum_class = payload[off]; off += 1
        n_channels = payload[off]; off += 1
        hdr_iv = bytes(payload[off:off + 12]); off += 12
        hdr_tag = bytes(payload[off:off + 16]); off += 16
        hdr_ct = bytes(payload[off:off + 36]); off += 36
        d["header_segments"].append(HeaderSegment(
            iv=hdr_iv, tag=hdr_tag, ciphertext=hdr_ct,
        ))
        remaining = payload[off:]
    else:
        # Plaintext filter header: the encrypted-channel-only AU
        # variant. We don't decode the filter header; we do need to
        # skip it to reach the channels. Delegate to AccessUnit.
        au = AccessUnit.from_bytes(payload)
        # AccessUnit.from_bytes already parsed channels; retrieve
        # them directly.
        for cname in list(d["channel_segments"].keys()):
            ch = next((c for c in au.channels if c.name == cname), None)
            if ch is None:
                continue
            if len(ch.data) < 28:
                raise ValueError(
                    f"encrypted channel {cname!r} data shorter than IV+TAG"
                )
            iv = ch.data[:12]
            tag = ch.data[12:28]
            ciphertext = ch.data[28:]
            # Offset is derived from the sum of previous lengths. We
            # don't have it in the payload, so reconstruct.
            prior = sum(s.length for s in d["channel_segments"][cname])
            d["channel_segments"][cname].append(ChannelSegment(
                offset=prior,
                length=ch.n_elements,
                iv=iv, tag=tag, ciphertext=ciphertext,
            ))
        return

    # After reading the encrypted header (encrypted_header branch),
    # walk the channel entries from ``remaining``.
    buf = remaining
    off = 0
    for cname in list(d["channel_segments"].keys())[:n_channels]:
        (name_len,) = struct.unpack_from("<H", buf, off); off += 2
        name = bytes(buf[off:off + name_len]).decode("utf-8"); off += name_len
        precision = buf[off]; off += 1
        compression = buf[off]; off += 1
        (n_elements,) = struct.unpack_from("<I", buf, off); off += 4
        (data_len,) = struct.unpack_from("<I", buf, off); off += 4
        data = bytes(buf[off:off + data_len]); off += data_len
        if len(data) < 28:
            raise ValueError(
                f"encrypted channel {name!r} data shorter than IV+TAG"
            )
        iv = data[:12]
        tag = data[12:28]
        ciphertext = data[28:]
        prior = sum(s.length for s in d["channel_segments"][name])
        d["channel_segments"][name].append(ChannelSegment(
            offset=prior,
            length=n_elements,
            iv=iv, tag=tag, ciphertext=ciphertext,
        ))
