"""M51 compound parity dumper — Python reference.

Reads an ``.mpgo`` file and emits ``/study/identifications``,
``/study/quantifications``, and ``/study/provenance`` as deterministic
JSON to stdout. The output is byte-identical to the Objective-C
``MpgoDumpIdentifications`` and Java ``DumpIdentifications`` tools.

Usage
-----
::

    python -m mpeg_o.tools.dump_identifications <path-to.mpgo>

Exit codes
----------
- ``0`` — wrote output successfully.
- ``1`` — argument error.
- ``2`` — open/read failure.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from ..spectral_dataset import SpectralDataset
from ._canonical_json import format_top_level


def _identification_record(ident: Any) -> dict[str, Any]:
    return {
        "chemical_entity": ident.chemical_entity,
        "confidence_score": float(ident.confidence_score),
        "evidence_chain": list(ident.evidence_chain),
        "run_name": ident.run_name,
        "spectrum_index": int(ident.spectrum_index),
    }


def _quantification_record(q: Any) -> dict[str, Any]:
    return {
        "abundance": float(q.abundance),
        "chemical_entity": q.chemical_entity,
        "normalization_method": q.normalization_method,
        "sample_ref": q.sample_ref,
    }


def _provenance_record(p: Any) -> dict[str, Any]:
    # ``parameters`` is dict[str, Any]; coerce values to str so the
    # three languages agree on wire format (ObjC stores NSString, Java
    # uses Map<String,String>).
    params = {str(k): str(v) for k, v in (p.parameters or {}).items()}
    return {
        "input_refs": list(p.input_refs),
        "output_refs": list(p.output_refs),
        "parameters": params,
        "software": p.software,
        "timestamp_unix": int(p.timestamp_unix),
    }


def dump(path: str | Path) -> str:
    """Return the canonical JSON for the dataset at ``path``."""
    with SpectralDataset.open(path) as ds:
        idents = [_identification_record(i) for i in ds.identifications()]
        quants = [_quantification_record(q) for q in ds.quantifications()]
        provs = [_provenance_record(p) for p in ds.provenance()]
    return format_top_level({
        "identifications": idents,
        "quantifications": quants,
        "provenance": provs,
    })


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        sys.stderr.write(
            "usage: python -m mpeg_o.tools.dump_identifications <path.mpgo>\n"
        )
        return 1
    try:
        blob = dump(args[0])
    except (OSError, RuntimeError) as e:
        sys.stderr.write(f"dump failed: {e}\n")
        return 2
    # Write raw bytes to stdout to avoid any re-encoding on Windows.
    sys.stdout.buffer.write(blob.encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
