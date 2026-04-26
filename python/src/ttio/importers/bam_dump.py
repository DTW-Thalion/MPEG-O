"""bam_dump — canonical-JSON dump of a SAM/BAM file for the M87
cross-language conformance harness.

Usage::

    python -m ttio.importers.bam_dump <bam_or_sam_path>

Reads the file via :class:`~ttio.importers.bam.BamReader` and emits a
canonical JSON document on stdout matching the schema documented in
``HANDOFF.md`` §7. The same shape is produced by the ObjC
``TtioBamDump`` and Java ``BamDump`` CLIs; cross-language tests
diff the three outputs to verify field-equality decoding.

The JSON keys are sorted and the document is indented two spaces;
sequence/quality byte buffers are summarised by their MD5 hex digest
(rather than being embedded as base64) to keep the output a short
fixed-width fingerprint.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from typing import Any

from .bam import BamReader


__all__ = ["dump", "main"]


def dump(path: str, name: str = "genomic_0001") -> dict[str, Any]:
    """Read ``path`` and return the canonical-JSON-shaped dict.

    Returned keys (sorted by :func:`json.dumps(sort_keys=True)` for
    canonical output):

    * ``name`` — the run name passed in (default ``"genomic_0001"``)
    * ``read_count`` — number of alignment records
    * ``sample_name`` — first @RG SM: tag (or "")
    * ``platform`` — first @RG PL: tag (or "")
    * ``reference_uri`` — first @SQ SN: tag (or "")
    * ``read_names`` — list[str], length == read_count
    * ``positions`` — list[int], 1-based per Binding Decision §132
    * ``chromosomes`` — list[str]
    * ``flags`` — list[int]
    * ``mapping_qualities`` — list[int]
    * ``cigars`` — list[str], "*" preserved literally per Gotcha §153
    * ``mate_chromosomes`` — list[str], "=" expanded to RNAME per
      Binding Decision §131
    * ``mate_positions`` — list[int]
    * ``template_lengths`` — list[int], signed
    * ``sequences_md5`` — hex MD5 of concatenated SEQ buffer
    * ``qualities_md5`` — hex MD5 of concatenated QUAL buffer
    * ``provenance_count`` — number of @PG-derived provenance rows
    """
    reader = BamReader(path)
    run = reader.to_genomic_run(name=name)

    seq_md5 = hashlib.md5(bytes(run.sequences)).hexdigest()
    qual_md5 = hashlib.md5(bytes(run.qualities)).hexdigest()

    return {
        "name": name,
        "read_count": len(run.read_names),
        "sample_name": run.sample_name,
        "platform": run.platform,
        "reference_uri": run.reference_uri,
        "read_names": list(run.read_names),
        "positions": [int(x) for x in run.positions],
        "chromosomes": list(run.chromosomes),
        "flags": [int(x) for x in run.flags],
        "mapping_qualities": [int(x) for x in run.mapping_qualities],
        "cigars": list(run.cigars),
        "mate_chromosomes": list(run.mate_chromosomes),
        "mate_positions": [int(x) for x in run.mate_positions],
        "template_lengths": [int(x) for x in run.template_lengths],
        "sequences_md5": seq_md5,
        "qualities_md5": qual_md5,
        "provenance_count": len(run.provenance_records),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m ttio.importers.bam_dump",
        description="Emit the canonical M87 JSON dump for a SAM/BAM file.",
    )
    parser.add_argument(
        "path", help="Path to a SAM or BAM file (samtools auto-detects)."
    )
    parser.add_argument(
        "--name", default="genomic_0001",
        help="Genomic-run name to embed in the JSON (default: genomic_0001).",
    )
    args = parser.parse_args(argv)

    payload = dump(args.path, name=args.name)
    sys.stdout.write(json.dumps(payload, sort_keys=True, indent=2))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
