"""GFA 1.x importer.

Parses a GFA assembly-graph file (hifiasm, miniasm, ...) into a
:class:`ttio.assembly.WrittenAssemblyGraph` that re-emits the input
byte-exactly (format-spec §11a).

Structural rules (identical in the 3 SDKs): split on LF after
final-newline detection, fields split on TAB. ``S`` needs >= 3
fields, ``L`` >= 6, ``P`` >= 4; every other line (H, C, comments,
hifiasm ``A`` lines, short S/L/P) goes verbatim into the extras
table. Tags are the tab-joined verbatim remainder, ``""`` when none.
A ``*`` sequence parses as ``None``. ``gfa_version`` is the
``VN:Z:`` value of the first header line routed to extras, else
``"1.0"``. An empty file has 0 lines; ``"\\n"`` is one empty extras
line.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOGfaReader`` ·
Java: ``global.thalion.ttio.importers.GfaReader``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

from ..assembly import (
    GFA_LINE_TYPE_EXTRA,
    GFA_LINE_TYPE_LINK,
    GFA_LINE_TYPE_PATH,
    GFA_LINE_TYPE_SEGMENT,
    GraphLink,
    GraphPath,
    GraphSegment,
    WrittenAssemblyGraph,
)


def _version_from_header_fields(fields: list[str]) -> str | None:
    """The ``VN:Z:`` value of a header line's fields, or None."""
    for f in fields[1:]:
        if f.startswith("VN:Z:"):
            return f[5:]
    return None


class GfaReader:
    """Reads GFA 1.x bytes or files into :class:`WrittenAssemblyGraph`."""

    @staticmethod
    def graph_from_bytes(data: bytes) -> WrittenAssemblyGraph:
        text = data.decode("utf-8")
        final_newline = len(data) > 0 and data[-1:] == b"\n"
        lines = text.split("\n")
        if final_newline:
            lines = lines[:-1]  # drop the empty tail element
        if len(data) == 0:
            lines = []

        segments: list[GraphSegment] = []
        links: list[GraphLink] = []
        paths: list[GraphPath] = []
        extras: list[str] = []
        line_types: list[int] = []
        line_rows: list[int] = []
        gfa_version: str | None = None

        for line in lines:
            f = line.split("\t")
            t = f[0]
            if t == "S" and len(f) >= 3:
                seq_col = f[2]
                seq = None if seq_col == "*" else seq_col.encode("utf-8")
                segments.append(GraphSegment(
                    name=f[1], sequence=seq, tags="\t".join(f[3:])))
                line_types.append(GFA_LINE_TYPE_SEGMENT)
                line_rows.append(len(segments) - 1)
            elif t == "L" and len(f) >= 6:
                links.append(GraphLink(
                    from_segment=f[1], from_orient=f[2],
                    to_segment=f[3], to_orient=f[4],
                    overlap=f[5], tags="\t".join(f[6:])))
                line_types.append(GFA_LINE_TYPE_LINK)
                line_rows.append(len(links) - 1)
            elif t == "P" and len(f) >= 4:
                paths.append(GraphPath(
                    name=f[1], segment_list=f[2], overlaps=f[3],
                    tags="\t".join(f[4:])))
                line_types.append(GFA_LINE_TYPE_PATH)
                line_rows.append(len(paths) - 1)
            else:
                if gfa_version is None and t == "H":
                    gfa_version = _version_from_header_fields(f)
                extras.append(line)
                line_types.append(GFA_LINE_TYPE_EXTRA)
                line_rows.append(len(extras) - 1)

        return WrittenAssemblyGraph(
            gfa_version=gfa_version or "1.0",
            producer="",
            final_newline=final_newline,
            segments=segments,
            links=links,
            paths=paths,
            extras=extras,
            line_types=line_types,
            line_rows=line_rows,
        )

    @staticmethod
    def graph_from_path(path: str | Path) -> WrittenAssemblyGraph:
        return GfaReader.graph_from_bytes(Path(path).read_bytes())
