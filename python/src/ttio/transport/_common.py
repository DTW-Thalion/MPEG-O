"""Shared transport-codec helpers used by both writer and reader.

Pure code-movement split of ``codec.py`` (OO-assessment P3.10).
Holds the wire-mapping constants and the genomic/codec helpers that
:mod:`ttio.transport._writer` and :mod:`ttio.transport._reader` both
depend on. Importing this module must not pull in either of those
(one-way dependency: writer/reader -> _common).
"""
from __future__ import annotations

import logging
import struct
from typing import Iterator

from ..enums import Compression, Polarity, Precision
from .._hdf5_io import read_int_attr as io_attr_int  # M90.10 wire codec probe
from .packets import (
    AccessUnit,
    ChannelData,
)

_CHECKSUM_STRUCT = struct.Struct("<I")

_LOG = logging.getLogger("ttio.transport.codec")

# ---------------------------------------------------------- wire mappings

# Wire polarity (0=positive, 1=negative, 2=unknown) vs Polarity enum
# (UNKNOWN=0, POSITIVE=1, NEGATIVE=-1). The transport spec uses a
# nonneg-only layout for portability across languages that can't
# round-trip negative uint8 values.
_POLARITY_TO_WIRE = {
    Polarity.POSITIVE: 0,
    Polarity.NEGATIVE: 1,
    Polarity.UNKNOWN: 2,
}
_WIRE_TO_POLARITY = {v: k for k, v in _POLARITY_TO_WIRE.items()}

_SPECTRUM_CLASS_TO_WIRE = {
    "TTIOMassSpectrum": 0,
    "TTIONMRSpectrum": 1,
    "TTIONMR2DSpectrum": 2,
    "TTIOFreeInductionDecay": 3,
    "TTIOMSImagePixel": 4,
    "TTIOGenomicRead": 5,  # M89.2
}
_WIRE_TO_SPECTRUM_CLASS = {v: k for k, v in _SPECTRUM_CLASS_TO_WIRE.items()}


# M86 codec dispatch for genomic UINT8 channels on the wire.

_RANS_ORDER0_WIRE = int(Compression.RANS_ORDER0)
_RANS_ORDER1_WIRE = int(Compression.RANS_ORDER1)
_BASE_PACK_WIRE = int(Compression.BASE_PACK)


def _read_mate_chrom_names_table(mate_grp) -> list[str]:
    """Read the ``mate_info/chrom_names`` compound dataset into a list
    of names ordered by row index (matches the chrom_id encoding used
    by MATE_INLINE_V2). Returns ``[]`` when the table is missing
    (mate_info/inline_v2 is allowed without a name table on empty
    runs)."""
    from .. import _hdf5_io as _io
    try:
        records = _io.read_compound_dataset(mate_grp, "chrom_names")
    except (KeyError, ValueError):
        return []
    return [str(r.get("name", "")) for r in records]


def _apply_wire_codec(plaintext: bytes, codec: int) -> bytes:
    """Encode ``plaintext`` with the wire codec id (NONE → identity)."""
    if codec == 0:  # NONE
        return plaintext
    if codec == _RANS_ORDER0_WIRE:
        from ..codecs import rans
        return rans.encode(plaintext, order=0)
    if codec == _RANS_ORDER1_WIRE:
        from ..codecs import rans
        return rans.encode(plaintext, order=1)
    if codec == _BASE_PACK_WIRE:
        from ..codecs import base_pack
        return base_pack.encode(plaintext)
    # Other compression ids (zlib for MS, etc.) take the existing
    # paths in this module; this helper is genomic-channel-only.
    raise NotImplementedError(
        f"_apply_wire_codec: codec id {codec} not supported for genomic UINT8"
    )


def _decode_wire_codec(payload: bytes, codec: int) -> bytes:
    """Decode a payload encoded by :func:`_apply_wire_codec`."""
    if codec == 0:
        return payload
    if codec == _RANS_ORDER0_WIRE or codec == _RANS_ORDER1_WIRE:
        from ..codecs import rans
        return rans.decode(payload)
    if codec == _BASE_PACK_WIRE:
        from ..codecs import base_pack
        return base_pack.decode(payload)
    raise NotImplementedError(
        f"_decode_wire_codec: codec id {codec} not supported for genomic UINT8"
    )


def _iter_genomic_run_access_units(run) -> Iterator[tuple[int, "AccessUnit"]]:
    """Yield ``(au_sequence, AccessUnit)`` tuples for every AlignedRead
    in ``run``.

    Body extracted from :meth:`TransportWriter._emit_genomic_run_access_units`
    in #141 so :func:`ttio.transport.walker.walk_dataset` can emit
    genomic AUs without duplicating the per-read construction. Both
    callers see byte-identical AUs.
    """
    index = run.index
    n_reads = index.count
    # Bulk-read sequences and qualities once; slice per AU.
    if n_reads > 0:
        total_bases = int(index.offsets[-1]) + int(index.lengths[-1])
        seq_full = run._byte_channel_slice("sequences", 0, total_bases)
        qual_full = run._byte_channel_slice("qualities", 0, total_bases)
    else:
        seq_full = b""
        qual_full = b""
    chromosomes = index.chromosomes
    positions = index.positions
    mqs = index.mapping_qualities
    flags_arr = index.flags
    offsets = index.offsets
    lengths = index.lengths
    precision_uint8 = int(Precision.UINT8) & 0xFF
    compression_none = int(Compression.NONE) & 0xFF
    acq_mode = int(run.acquisition_mode) & 0xFF
    seq_codec = qual_codec = compression_none
    try:
        sig_group = run.group.open_group("signal_channels")
        if sig_group.has_child("sequences"):
            seq_ds = sig_group.open_dataset("sequences")
            seq_codec = (io_attr_int(seq_ds, "compression",
                                        default=0) or 0) & 0xFF
        if sig_group.has_child("qualities"):
            qual_ds = sig_group.open_dataset("qualities")
            qual_codec = (io_attr_int(qual_ds, "compression",
                                         default=0) or 0) & 0xFF
    except Exception:
        seq_codec = qual_codec = compression_none

    for i in range(n_reads):
        start = int(offsets[i])
        length = int(lengths[i])
        stop = start + length
        seq_bytes = seq_full[start:stop]
        qual_bytes = qual_full[start:stop]
        seq_payload = _apply_wire_codec(bytes(seq_bytes), seq_codec)
        qual_payload = _apply_wire_codec(bytes(qual_bytes), qual_codec)
        r = run[i]
        cigar_bytes = (r.cigar or "").encode("utf-8")
        name_bytes = (r.read_name or "").encode("utf-8")
        mate_chr_bytes = (r.mate_chromosome or "").encode("utf-8")
        channels = [
            ChannelData("sequences", precision_uint8,
                        seq_codec, length, seq_payload),
            ChannelData("qualities", precision_uint8,
                        qual_codec, length, qual_payload),
            ChannelData("cigar", precision_uint8,
                        compression_none, len(cigar_bytes), cigar_bytes),
            ChannelData("read_name", precision_uint8,
                        compression_none, len(name_bytes), name_bytes),
            ChannelData("mate_chromosome", precision_uint8,
                        compression_none, len(mate_chr_bytes),
                        mate_chr_bytes),
        ]
        au = AccessUnit(
            spectrum_class=5,
            acquisition_mode=acq_mode,
            ms_level=0,
            polarity=2,
            retention_time=0.0,
            precursor_mz=0.0,
            precursor_charge=0,
            ion_mobility=0.0,
            base_peak_intensity=0.0,
            channels=channels,
            chromosome=chromosomes[i],
            position=int(positions[i]),
            mapping_quality=int(mqs[i]),
            flags=int(flags_arr[i]) & 0xFFFF,
            mate_position=int(r.mate_position),
            template_length=int(r.template_length),
        )
        yield i, au
