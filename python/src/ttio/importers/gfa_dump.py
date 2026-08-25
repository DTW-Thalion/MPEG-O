"""gfa_dump — canonical-JSON dump of a GFA 1.x file or a stored
assembly graph, plus the M98 conformance write/emit modes.

Usage::

    # canonical JSON on stdout (input may be .gfa text or a .tio
    # container; --graph picks the stored graph, default graph_0001):
    python -m ttio.importers.gfa_dump <input.gfa|input.tio>

    # parse a GFA and write a .tio holding it as <--graph>:
    python -m ttio.importers.gfa_dump <input.gfa> --write-tio <out.tio>

    # re-emit a stored graph as GFA bytes:
    python -m ttio.importers.gfa_dump <input.tio> --emit-gfa <out.gfa>

The JSON document matches ``json.dumps(payload, sort_keys=True,
indent=2)`` plus a trailing newline; the same shape is produced by
the ObjC ``TtioGfaDump`` and Java ``GfaDump`` CLIs, and the M98
conformance harness (``tests/validation/test_m98_gfa_matrix.py``)
diffs the three outputs and drives the 3x3 container matrix through
the write/emit modes.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from typing import Any

from ..assembly import WrittenAssemblyGraph

__all__ = ["dump", "main"]


def _load(path: str, graph_name: str) -> WrittenAssemblyGraph:
    """Parse a GFA file, or open a ``.tio`` and materialise the
    stored graph named ``graph_name``."""
    if path.lower().endswith(".tio"):
        from ..spectral_dataset import SpectralDataset

        ds = SpectralDataset.open(path)
        try:
            g = ds.assembly_graphs.get(graph_name)
            if g is None:
                raise ValueError(
                    f"no assembly graph {graph_name!r} in {path}")
            return g.written_graph()
        finally:
            ds.close()
    from .gfa import GfaReader

    return GfaReader.graph_from_path(path)


def dump(path: str, graph: str = "graph_0001") -> dict[str, Any]:
    """Return the canonical-JSON-shaped dict for ``path``."""
    g = _load(path, graph)
    seqs = b"".join(
        s.sequence for s in g.segments if s.sequence is not None)
    return {
        "extra_count": len(g.extras),
        "extras": list(g.extras),
        "final_newline": 1 if g.final_newline else 0,
        "gfa_version": g.gfa_version,
        "line_rows": [int(x) for x in g.line_rows],
        "line_types": [int(x) for x in g.line_types],
        "link_count": len(g.links),
        "links": [
            {"from": l.from_segment, "from_orient": l.from_orient,
             "overlap": l.overlap, "tags": l.tags,
             "to": l.to_segment, "to_orient": l.to_orient}
            for l in g.links],
        "path_count": len(g.paths),
        "paths": [
            {"name": p.name, "overlaps": p.overlaps,
             "segment_list": p.segment_list, "tags": p.tags}
            for p in g.paths],
        "producer": g.producer,
        "segment_count": len(g.segments),
        "segments": [
            {"length": len(s.sequence) if s.sequence is not None else 0,
             "name": s.name,
             "seq_missing": 0 if s.sequence is not None else 1,
             "tags": s.tags}
            for s in g.segments],
        "sequences_md5": hashlib.md5(seqs).hexdigest(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m ttio.importers.gfa_dump",
        description=(
            "Emit canonical M98 JSON for a GFA file or a stored "
            "assembly graph, or run the conformance write/emit modes."
        ),
    )
    parser.add_argument(
        "path",
        help="Path to a GFA file, or a .tio container holding a graph.")
    parser.add_argument(
        "--graph", default="graph_0001",
        help="Stored graph name (default: graph_0001).")
    parser.add_argument(
        "--write-tio", default=None, metavar="OUT",
        help="Parse the GFA input and write a .tio holding it.")
    parser.add_argument(
        "--emit-gfa", default=None, metavar="OUT",
        help="Re-emit the graph as GFA bytes to OUT.")
    args = parser.parse_args(argv)

    if args.write_tio is not None:
        from ..spectral_dataset import SpectralDataset
        from .gfa import GfaReader

        g = GfaReader.graph_from_path(args.path)
        SpectralDataset.write_minimal(
            args.write_tio, title="M98", isa_investigation_id="M98",
            runs={}, assembly_graphs={args.graph: g})
        return 0

    if args.emit_gfa is not None:
        from ..exporters.gfa import GfaWriter

        GfaWriter.write_graph(_load(args.path, args.graph), args.emit_gfa)
        return 0

    payload = dump(args.path, graph=args.graph)
    sys.stdout.write(json.dumps(payload, sort_keys=True, indent=2))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
