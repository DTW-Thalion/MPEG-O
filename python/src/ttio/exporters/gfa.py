"""GFA 1.x exporter.

Re-emits a :class:`ttio.assembly.WrittenAssemblyGraph` as GFA bytes.
Emission replays ``line_index`` so the output is byte-exact against
the parsed input: extras verbatim, ``*`` for a missing sequence, tags
appended with a TAB only when non-empty, and the final newline
restored from the graph's ``final_newline`` flag.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOGfaWriter`` ·
Java: ``global.thalion.ttio.exporters.GfaWriter``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

from ..assembly import (
    GFA_LINE_TYPE_LINK,
    GFA_LINE_TYPE_PATH,
    GFA_LINE_TYPE_SEGMENT,
    WrittenAssemblyGraph,
)


class GfaWriter:
    """Writes a :class:`WrittenAssemblyGraph` back to GFA 1.x."""

    @staticmethod
    def data_for_graph(graph: WrittenAssemblyGraph) -> bytes:
        parts: list[bytes] = []
        for i in range(graph.line_count):
            if i > 0:
                parts.append(b"\n")
            t = graph.line_types[i]
            row = graph.line_rows[i]
            if t == GFA_LINE_TYPE_SEGMENT:
                s = graph.segments[row]
                parts.append(b"S\t" + s.name.encode("utf-8") + b"\t")
                parts.append(b"*" if s.sequence is None else s.sequence)
                if s.tags:
                    parts.append(b"\t" + s.tags.encode("utf-8"))
            elif t == GFA_LINE_TYPE_LINK:
                l = graph.links[row]
                parts.append(
                    f"L\t{l.from_segment}\t{l.from_orient}"
                    f"\t{l.to_segment}\t{l.to_orient}"
                    f"\t{l.overlap}".encode("utf-8"))
                if l.tags:
                    parts.append(b"\t" + l.tags.encode("utf-8"))
            elif t == GFA_LINE_TYPE_PATH:
                p = graph.paths[row]
                parts.append(
                    f"P\t{p.name}\t{p.segment_list}"
                    f"\t{p.overlaps}".encode("utf-8"))
                if p.tags:
                    parts.append(b"\t" + p.tags.encode("utf-8"))
            else:
                parts.append(graph.extras[row].encode("utf-8"))
        if graph.final_newline:
            parts.append(b"\n")
        return b"".join(parts)

    @staticmethod
    def write_graph(graph: WrittenAssemblyGraph,
                    path: str | Path) -> None:
        Path(path).write_bytes(GfaWriter.data_for_graph(graph))
