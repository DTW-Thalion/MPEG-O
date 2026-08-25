"""M98 Phase 0 — GFA 1.x <-> HDF5 mapping, byte-exact round-trip proof.

Proves, before any ObjC or Java work, that the proposed
``/study/assembly_graphs/<name>/`` layout can reconstruct a producer's
GFA file byte for byte:

* ``segments/``   — records compound (name, length, seq_offset,
  seq_len, tags) + a concatenated ``sequences`` uint8 dataset (the
  implementation routes it through the existing sequences codec
  stack; the mapping proof stores raw bytes — codec byte-exactness
  is already pinned by the codec conformance suites).
* ``links/``      — compound (from, from_orient, to, to_orient,
  overlap, tags).
* ``paths/``      — compound (name, segment_list, overlaps, tags).
* ``extras/``     — verbatim non-S/L/P lines (headers, containments,
  hifiasm ``A`` lines, comments), so producer extensions survive.
* ``line_index/`` — (line_type, table_row) in file order, so
  re-emission preserves the producer's interleaving exactly.
* ``@gfa_version``, ``@producer``, ``@final_newline``.

Optional GFA tags are kept verbatim per record (tab-joined string):
GFA tags are strictly ``TAG:TYPE:VALUE``, so a parsed key/type/value
view is an accessor question, not a storage question — verbatim
storage is what makes byte-exactness provable.

Usage:
    python gfa_roundtrip_proof.py <graph.gfa> [more.gfa ...]

Exit 0 and ``PHASE0: BYTE-EXACT`` when every input round-trips.
"""
from __future__ import annotations

import sys
from pathlib import Path

import h5py
import numpy as np

STR = h5py.string_dtype(encoding="utf-8")


# ---------------------------------------------------------------------------
# parse
# ---------------------------------------------------------------------------

def parse_gfa(data: bytes):
    """Split a GFA byte stream into the five tables + the line order.

    Returns a dict with lists: segments, links, paths, extras,
    line_index (type char + row), and final_newline.
    """
    segments, links, paths, extras, order = [], [], [], [], []
    final_newline = data.endswith(b"\n")
    text = data.decode("utf-8")
    lines = text.split("\n")
    if final_newline:
        lines = lines[:-1]
    for line in lines:
        fields = line.split("\t")
        t = fields[0]
        if t == "S" and len(fields) >= 3:
            name, seq = fields[1], fields[2]
            tags = "\t".join(fields[3:])
            segments.append((name, seq, tags))
            order.append(("S", len(segments) - 1))
        elif t == "L" and len(fields) >= 6:
            tags = "\t".join(fields[6:])
            links.append((fields[1], fields[2], fields[3], fields[4],
                          fields[5], tags))
            order.append(("L", len(links) - 1))
        elif t == "P" and len(fields) >= 4:
            tags = "\t".join(fields[4:])
            paths.append((fields[1], fields[2], fields[3], tags))
            order.append(("P", len(paths) - 1))
        else:
            # H, C, comments, producer extensions (hifiasm A lines),
            # and malformed-but-present lines: verbatim.
            extras.append(line)
            order.append(("X", len(extras) - 1))
    return {
        "segments": segments,
        "links": links,
        "paths": paths,
        "extras": extras,
        "order": order,
        "final_newline": final_newline,
    }


# ---------------------------------------------------------------------------
# write to the proposed layout
# ---------------------------------------------------------------------------

def write_h5(g, parsed) -> None:
    seqs = bytearray()
    seg_rows = []
    for name, seq, tags in parsed["segments"]:
        if seq == "*":
            off, ln, missing = len(seqs), 0, 1
        else:
            off, ln, missing = len(seqs), len(seq), 0
            seqs.extend(seq.encode("utf-8"))
        seg_rows.append((name, ln, off, missing, tags))

    seg_dt = np.dtype([("name", STR), ("length", "<u8"),
                       ("seq_offset", "<u8"), ("seq_missing", "u1"),
                       ("tags", STR)])
    sg = g.create_group("segments")
    sg.create_dataset("records", data=np.array(seg_rows, dtype=seg_dt))
    sg.create_dataset("sequences",
                      data=np.frombuffer(bytes(seqs), dtype=np.uint8)
                      if seqs else np.zeros(0, dtype=np.uint8))

    link_dt = np.dtype([("from", STR), ("from_orient", STR),
                        ("to", STR), ("to_orient", STR),
                        ("overlap", STR), ("tags", STR)])
    g.create_dataset("links", data=np.array(parsed["links"], dtype=link_dt))

    path_dt = np.dtype([("name", STR), ("segment_list", STR),
                        ("overlaps", STR), ("tags", STR)])
    g.create_dataset("paths", data=np.array(parsed["paths"], dtype=path_dt))

    g.create_dataset("extras",
                     data=np.array(parsed["extras"], dtype=STR))

    idx_dt = np.dtype([("line_type", "S1"), ("row", "<u8")])
    g.create_dataset("line_index",
                     data=np.array([(t.encode(), r)
                                    for t, r in parsed["order"]],
                                   dtype=idx_dt))
    g.attrs["gfa_version"] = "1.0"
    g.attrs["producer"] = ""
    g.attrs["final_newline"] = 1 if parsed["final_newline"] else 0


# ---------------------------------------------------------------------------
# read back + re-emit
# ---------------------------------------------------------------------------

def _s(v) -> str:
    return v.decode("utf-8") if isinstance(v, bytes) else str(v)


def emit_gfa(g) -> bytes:
    segs = g["segments/records"][()]
    seq_bytes = bytes(g["segments/sequences"][()])
    links = g["links"][()]
    paths = g["paths"][()]
    extras = g["extras"][()]
    order = g["line_index"][()]

    out = []
    for t_raw, row in order:
        t = t_raw.decode()
        if t == "S":
            r = segs[int(row)]
            if int(r["seq_missing"]):
                seq = "*"
            else:
                off, ln = int(r["seq_offset"]), int(r["length"])
                seq = seq_bytes[off:off + ln].decode("utf-8")
            fields = ["S", _s(r["name"]), seq]
            tags = _s(r["tags"])
            if tags:
                fields.append(tags)
            out.append("\t".join(fields))
        elif t == "L":
            r = links[int(row)]
            fields = ["L", _s(r["from"]), _s(r["from_orient"]),
                      _s(r["to"]), _s(r["to_orient"]), _s(r["overlap"])]
            tags = _s(r["tags"])
            if tags:
                fields.append(tags)
            out.append("\t".join(fields))
        elif t == "P":
            r = paths[int(row)]
            fields = ["P", _s(r["name"]), _s(r["segment_list"]),
                      _s(r["overlaps"])]
            tags = _s(r["tags"])
            if tags:
                fields.append(tags)
            out.append("\t".join(fields))
        else:
            out.append(_s(extras[int(row)]))
    text = "\n".join(out)
    if int(g.attrs["final_newline"]):
        text += "\n"
    return text.encode("utf-8")


# ---------------------------------------------------------------------------
# proof driver
# ---------------------------------------------------------------------------

def prove(path: Path, tmp_h5: Path) -> dict:
    data = path.read_bytes()
    parsed = parse_gfa(data)
    with h5py.File(tmp_h5, "w") as f:
        write_h5(f.create_group("study/assembly_graphs/g0"), parsed)
    with h5py.File(tmp_h5, "r") as f:
        emitted = emit_gfa(f["study/assembly_graphs/g0"])
    ok = emitted == data
    alphabet = set()
    for _, seq, _ in parsed["segments"]:
        if seq != "*":
            alphabet |= set(seq)
    return {
        "ok": ok,
        "bytes": len(data),
        "segments": len(parsed["segments"]),
        "links": len(parsed["links"]),
        "paths": len(parsed["paths"]),
        "extras": len(parsed["extras"]),
        "alphabet": "".join(sorted(alphabet)),
        "emitted": emitted,
    }


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: gfa_roundtrip_proof.py <graph.gfa> [...]")
        return 2
    all_ok = True
    for p in map(Path, argv):
        tmp = p.with_suffix(".phase0.h5")
        r = prove(p, tmp)
        status = "BYTE-EXACT" if r["ok"] else "DIVERGED"
        print(f"{p.name}: {status}  {r['bytes']:,} B  "
              f"S={r['segments']} L={r['links']} P={r['paths']} "
              f"extras={r['extras']}  alphabet={r['alphabet']!r}")
        if not r["ok"]:
            all_ok = False
            data = p.read_bytes()
            for i, (a, b) in enumerate(zip(data, r["emitted"])):
                if a != b:
                    print(f"  first diff at byte {i}: "
                          f"{data[max(0,i-30):i+30]!r} vs "
                          f"{r['emitted'][max(0,i-30):i+30]!r}")
                    break
            else:
                print(f"  length mismatch: {len(data)} vs "
                      f"{len(r['emitted'])}")
        tmp.unlink(missing_ok=True)
    print("PHASE0: BYTE-EXACT" if all_ok else "PHASE0: FAILED")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
