"""AssemblyGraph (GFA 1.x) container primitive — M98, format-spec §11a.

Value classes for graph records, the validating write-side
:class:`WrittenAssemblyGraph`, the storage writer
:func:`write_assembly_graph`, and the read-side :class:`AssemblyGraph`
opened from ``/study/assembly_graphs/<name>/``.

Layout (format-spec §11a)
-------------------------
``/study/assembly_graphs/@_graph_names`` (comma list), then per graph:
``@gfa_version`` / ``@producer`` / ``@final_newline`` attributes,
``segments/records`` + ``segments/sequences`` (concatenated bytes,
BASE_PACK when the alphabet is ACGTN upper or lower case, RANS_ORDER1
otherwise, ``@compression`` on the dataset), ``links``, ``paths``,
``extras``, and ``line_index`` (codes 0=S 1=L 2=P 3=X) which replays
the original line order on emission.

Empty tables are ABSENT: 0-row non-extendable compounds do not
round-trip on every provider, and readers in all 3 SDKs treat a
missing table as empty. The ``final_newline`` attribute is the
structural marker :meth:`AssemblyGraph.open` validates.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOWrittenAssemblyGraph`` / ``TTIOAssemblyGraph`` /
``TTIOSpectralDataset (AssemblyWrite)`` · Java:
``global.thalion.ttio.assembly``.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

import numpy as np

from .codecs._context import ChannelPayload, CodecContext, DecodedChannel
from .codecs._registry import CODEC_REGISTRY
from .enums import Compression, Precision
from .providers.base import CompoundField, CompoundFieldKind

if TYPE_CHECKING:
    from .providers.base import StorageDataset, StorageGroup

# line_index codes (format-spec §11a).
GFA_LINE_TYPE_SEGMENT = 0
GFA_LINE_TYPE_LINK = 1
GFA_LINE_TYPE_PATH = 2
GFA_LINE_TYPE_EXTRA = 3


# ------------------------------------------------------------ value classes


@dataclass(frozen=True, slots=True)
class GraphSegment:
    """One GFA ``S`` record. ``sequence`` is ``None`` for ``*``."""

    name: str
    sequence: bytes | None
    tags: str = ""


@dataclass(frozen=True, slots=True)
class GraphLink:
    """One GFA ``L`` record."""

    from_segment: str
    from_orient: str
    to_segment: str
    to_orient: str
    overlap: str
    tags: str = ""


@dataclass(frozen=True, slots=True)
class GraphPath:
    """One GFA ``P`` record."""

    name: str
    segment_list: str
    overlaps: str
    tags: str = ""


@dataclass(slots=True)
class WrittenAssemblyGraph:
    """Write-side container for one assembly graph.

    ``line_types`` / ``line_rows`` replay the original file's line
    order on emission; the constructor validates that the index is a
    complete, in-range cover of the four tables (same checks as the
    ObjC validating init).
    """

    gfa_version: str = "1.0"
    producer: str = ""
    final_newline: bool = True
    segments: list[GraphSegment] = field(default_factory=list)
    links: list[GraphLink] = field(default_factory=list)
    paths: list[GraphPath] = field(default_factory=list)
    extras: list[str] = field(default_factory=list)
    line_types: list[int] = field(default_factory=list)
    line_rows: list[int] = field(default_factory=list)

    def __post_init__(self) -> None:
        n = len(self.line_types)
        if len(self.line_rows) != n:
            raise ValueError(
                f"line_rows must hold one entry per line_types entry "
                f"({n} lines, {len(self.line_rows)} rows)")
        counts = (len(self.segments), len(self.links),
                  len(self.paths), len(self.extras))
        seen = [0, 0, 0, 0]
        for i in range(n):
            t = self.line_types[i]
            r = self.line_rows[i]
            if t < 0 or t > GFA_LINE_TYPE_EXTRA or r < 0 or r >= counts[t]:
                raise ValueError(
                    f"line_index entry {i} (type {t}, row {r}) is "
                    f"out of range")
            seen[t] += 1
        for t in range(4):
            if seen[t] != counts[t]:
                raise ValueError(
                    f"line_index covers {seen[t]} rows of type {t}, "
                    f"table has {counts[t]}")

    @property
    def line_count(self) -> int:
        return len(self.line_types)


# ---------------------------------------------------------- storage writer

_SEGMENT_FIELDS = [
    CompoundField("name", CompoundFieldKind.VL_STRING),
    CompoundField("length", CompoundFieldKind.UINT64),
    CompoundField("seq_offset", CompoundFieldKind.UINT64),
    CompoundField("seq_missing", CompoundFieldKind.UINT32),
    CompoundField("tags", CompoundFieldKind.VL_STRING),
]

_LINK_FIELDS = [
    CompoundField("from", CompoundFieldKind.VL_STRING),
    CompoundField("from_orient", CompoundFieldKind.VL_STRING),
    CompoundField("to", CompoundFieldKind.VL_STRING),
    CompoundField("to_orient", CompoundFieldKind.VL_STRING),
    CompoundField("overlap", CompoundFieldKind.VL_STRING),
    CompoundField("tags", CompoundFieldKind.VL_STRING),
]

_PATH_FIELDS = [
    CompoundField("name", CompoundFieldKind.VL_STRING),
    CompoundField("segment_list", CompoundFieldKind.VL_STRING),
    CompoundField("overlaps", CompoundFieldKind.VL_STRING),
    CompoundField("tags", CompoundFieldKind.VL_STRING),
]

_EXTRA_FIELDS = [
    CompoundField("line", CompoundFieldKind.VL_STRING),
]

_INDEX_FIELDS = [
    CompoundField("line_type", CompoundFieldKind.UINT32),
    CompoundField("row", CompoundFieldKind.UINT64),
]

_SEQ_ALPHABET = frozenset(b"ACGTNacgtn")


def _sequences_codec(data: bytes) -> Compression:
    """Codec for a concatenated segment-sequences buffer: BASE_PACK
    when every byte is ACGTN (upper or lower case), RANS_ORDER1
    otherwise, NONE when empty. The same rule holds in the ObjC and
    Java writers so the 3 SDKs emit identical channels."""
    if not data:
        return Compression.NONE
    if set(data) <= _SEQ_ALPHABET:
        return Compression.BASE_PACK
    return Compression.RANS_ORDER1


def _write_bytes_channel(group: "StorageGroup", name: str,
                         data: bytes) -> None:
    codec = _sequences_codec(data)
    stored = data
    if codec != Compression.NONE:
        enc = CODEC_REGISTRY[codec].encode(
            DecodedChannel.of_bytes(data), CodecContext.empty())
        if enc.dataset_bytes is None:
            raise ValueError("assembly sequences channel encode failed")
        stored = enc.dataset_bytes
    ds = group.create_dataset(name, Precision.UINT8, len(stored),
                              chunk_size=65536)
    if stored:
        ds.write(np.frombuffer(stored, dtype=np.uint8))
    if codec != Compression.NONE:
        ds.set_attribute("compression", int(codec.value))


def _write_compound(group: "StorageGroup", name: str,
                    fields: list[CompoundField],
                    rows: list[dict]) -> None:
    # Empty tables are ABSENT (format-spec §11a).
    if not rows:
        return
    ds = group.create_compound_dataset(name, fields, len(rows))
    ds.write(rows)


def write_assembly_graph(graph: WrittenAssemblyGraph, name: str,
                         study: "StorageGroup") -> None:
    """Write ``graph`` under ``/study/assembly_graphs/<name>/``.

    ``study`` is the dataset's ``study`` :class:`StorageGroup` on any
    provider. Raises :class:`ValueError` when ``name`` already exists.
    """
    if study.has_child("assembly_graphs"):
        ag = study.open_group("assembly_graphs")
    else:
        ag = study.create_group("assembly_graphs")
        ag.set_attribute("_graph_names", "")

    if ag.has_child(name):
        raise ValueError(f"assembly graph {name!r} already exists")
    names_value = ""
    if ag.has_attribute("_graph_names"):
        raw = ag.get_attribute("_graph_names")
        if isinstance(raw, bytes):
            names_value = raw.decode("utf-8")
        elif isinstance(raw, str):
            names_value = raw
    names = [n for n in names_value.split(",") if n] if names_value else []
    names.append(name)
    ag.set_attribute("_graph_names", ",".join(names))

    g = ag.create_group(name)
    g.set_attribute("gfa_version", graph.gfa_version or "1.0")
    g.set_attribute("producer", graph.producer or "")
    g.set_attribute("final_newline", 1 if graph.final_newline else 0)

    # segments/: records compound + concatenated sequences channel.
    seg_g = g.create_group("segments")
    seqs = bytearray()
    seg_rows: list[dict] = []
    for s in graph.segments:
        off = len(seqs)
        length = len(s.sequence) if s.sequence is not None else 0
        if s.sequence is not None:
            seqs += s.sequence
        seg_rows.append({
            "name": s.name,
            "length": length,
            "seq_offset": off,
            "seq_missing": 0 if s.sequence is not None else 1,
            "tags": s.tags,
        })
    _write_compound(seg_g, "records", _SEGMENT_FIELDS, seg_rows)
    if seqs:
        _write_bytes_channel(seg_g, "sequences", bytes(seqs))

    _write_compound(g, "links", _LINK_FIELDS, [
        {"from": l.from_segment, "from_orient": l.from_orient,
         "to": l.to_segment, "to_orient": l.to_orient,
         "overlap": l.overlap, "tags": l.tags}
        for l in graph.links
    ])
    _write_compound(g, "paths", _PATH_FIELDS, [
        {"name": p.name, "segment_list": p.segment_list,
         "overlaps": p.overlaps, "tags": p.tags}
        for p in graph.paths
    ])
    _write_compound(g, "extras", _EXTRA_FIELDS, [
        {"line": line} for line in graph.extras
    ])
    _write_compound(g, "line_index", _INDEX_FIELDS, [
        {"line_type": t, "row": r}
        for t, r in zip(graph.line_types, graph.line_rows)
    ])


# ------------------------------------------------------------- read side


def _row_str(v) -> str:
    """VL-string field value as str. HDF5 reads VL strings back as
    bytes; Memory/SQLite give str."""
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return str(v)


def _attr_str(group: "StorageGroup", name: str) -> str:
    if not group.has_attribute(name):
        return ""
    v = group.get_attribute(name)
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return v if isinstance(v, str) else ""


def _decode_bytes_channel(ds: "StorageDataset") -> bytes:
    """Read a byte channel written with an optional ``@compression``
    codec attribute (0 or absent = raw bytes)."""
    raw = ds.read()
    raw_bytes = raw.tobytes() if hasattr(raw, "tobytes") else bytes(raw)
    codec = 0
    if ds.has_attribute("compression"):
        codec = int(ds.get_attribute("compression"))
    if codec == 0:
        return raw_bytes
    try:
        c = CODEC_REGISTRY[Compression(codec)]
    except (KeyError, ValueError):
        raise ValueError(
            f"sequences channel names unregistered codec {codec}")
    return c.decode(ChannelPayload.of_bytes(raw_bytes),
                    CodecContext.empty()).as_bytes()


def _rows_or_empty(group: "StorageGroup", name: str) -> list[dict]:
    """read_rows on a table that is absent-when-empty."""
    if not group.has_child(name):
        return []
    return group.open_dataset(name).read_rows()


class AssemblyGraph:
    """Read-side handle for one stored assembly graph.

    Table decode is lazy: :meth:`written_graph` reads and caches on
    first call; :meth:`open` only validates the attributes.
    """

    def __init__(self, group: "StorageGroup", name: str,
                 gfa_version: str, producer: str,
                 final_newline: bool) -> None:
        self._group = group
        self._cached: WrittenAssemblyGraph | None = None
        self.name = name
        self.gfa_version = gfa_version
        self.producer = producer
        self.final_newline = final_newline

    @classmethod
    def open(cls, group: "StorageGroup", name: str) -> "AssemblyGraph":
        # Empty tables are absent (format-spec §11a); the attributes
        # are the structural marker of an M98 graph group.
        if not group.has_attribute("final_newline"):
            raise ValueError(
                f"assembly graph {name!r} lacks the final_newline "
                f"attribute")
        final_newline = True
        try:
            final_newline = bool(int(group.get_attribute("final_newline")))
        except (TypeError, ValueError):
            pass
        return cls(group, name,
                   gfa_version=_attr_str(group, "gfa_version"),
                   producer=_attr_str(group, "producer"),
                   final_newline=final_newline)

    def written_graph(self) -> WrittenAssemblyGraph:
        if self._cached is not None:
            return self._cached

        seg_rows: list[dict] = []
        seq_bytes = b""
        if self._group.has_child("segments"):
            seg_g = self._group.open_group("segments")
            seg_rows = _rows_or_empty(seg_g, "records")
            if seg_g.has_child("sequences"):
                seq_bytes = _decode_bytes_channel(
                    seg_g.open_dataset("sequences"))

        segments: list[GraphSegment] = []
        for row in seg_rows:
            seq: bytes | None = None
            if not int(row["seq_missing"]):
                off = int(row["seq_offset"])
                length = int(row["length"])
                if off + length > len(seq_bytes):
                    raise ValueError(
                        "segment record points outside the sequences "
                        "channel")
                seq = seq_bytes[off:off + length]
            segments.append(GraphSegment(
                name=_row_str(row["name"]), sequence=seq,
                tags=_row_str(row["tags"])))

        links = [
            GraphLink(from_segment=_row_str(row["from"]),
                      from_orient=_row_str(row["from_orient"]),
                      to_segment=_row_str(row["to"]),
                      to_orient=_row_str(row["to_orient"]),
                      overlap=_row_str(row["overlap"]),
                      tags=_row_str(row["tags"]))
            for row in _rows_or_empty(self._group, "links")
        ]
        paths = [
            GraphPath(name=_row_str(row["name"]),
                      segment_list=_row_str(row["segment_list"]),
                      overlaps=_row_str(row["overlaps"]),
                      tags=_row_str(row["tags"]))
            for row in _rows_or_empty(self._group, "paths")
        ]
        extras = [
            _row_str(row["line"]) for row in _rows_or_empty(self._group, "extras")
        ]
        idx_rows = _rows_or_empty(self._group, "line_index")
        line_types = [int(row["line_type"]) for row in idx_rows]
        line_rows = [int(row["row"]) for row in idx_rows]

        self._cached = WrittenAssemblyGraph(
            gfa_version=self.gfa_version,
            producer=self.producer,
            final_newline=self.final_newline,
            segments=segments,
            links=links,
            paths=paths,
            extras=extras,
            line_types=line_types,
            line_rows=line_rows,
        )
        return self._cached

    def gfa_bytes(self) -> bytes:
        """Re-emit the stored graph as GFA bytes (byte-exact)."""
        from .exporters.gfa import GfaWriter

        return GfaWriter.data_for_graph(self.written_graph())
