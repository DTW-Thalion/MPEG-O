# HANDOFF — M88.1: extend `bam_dump` CLI with `--reference` for CRAM (cross-language conformance)

**Scope:** Extend the existing M87 `bam_dump` / `TtioBamDump` /
`BamDump` CLI in each of the three languages with a `--reference
<fasta>` flag. When the input path ends in `.cram`, dispatch to
the M88 `CramReader` instead of `BamReader`. This closes the
"CRAM cross-language parity verified implicitly" gap from M88 by
giving the harness the same byte-exact cross-language treatment
that M87 BAM has.

**Branch from:** `main` after the M88 docs (`3e56d0a`).

**IP provenance:** Pure CLI extension over the existing
`CramReader` / `TTIOCramReader` / Java `CramReader` classes
shipped in M88. No new format parsing; no new external
dependencies; no `htslib` linking.

---

## 1. Why extending `bam_dump` (not a separate `cram_dump`)

User chose **Option A** — extend the existing CLI rather than
ship a parallel `cram_dump` per language. Rationale:

- Mirrors the reader inheritance pattern: `CramReader extends
  BamReader`, so `bam_dump` becoming the universal aligned-read
  dump tool reflects how the classes actually relate.
- Single CLI surface; users learn one tool that handles SAM, BAM,
  and CRAM.
- Single cross-language harness file
  (`test_m88_cross_language.py`) gets new CRAM tests appended;
  no parallel harness file proliferation.
- The CLI already takes a path; adding one optional flag is the
  smallest possible surface change.

## 2. CLI contract (all three languages)

### Invocation

```
# BAM/SAM (M87 behaviour, unchanged):
python -m ttio.importers.bam_dump <bam_path> [--name <str>]
TtioBamDump <bam_path> [--name <str>]
mvn -o -q exec:java -Dexec.mainClass=global.thalion.ttio.importers.BamDump -Dexec.args="<bam_path>"

# CRAM (new in M88.1):
python -m ttio.importers.bam_dump <cram_path> --reference <fa_path> [--name <str>]
TtioBamDump <cram_path> --reference <fa_path> [--name <str>]
mvn -o -q exec:java -Dexec.mainClass=global.thalion.ttio.importers.BamDump -Dexec.args="<cram_path> --reference <fa_path>"
```

### Dispatch logic

```python
if path.lower().endswith(".cram"):
    if reference is None:
        error("--reference is required for .cram input")
    reader = CramReader(path, reference)
else:
    if reference is not None:
        # Accepted but unused; samtools auto-detects BAM/SAM.
        # Do NOT error — keeps the CLI tolerant of scripts that
        # always pass --reference.
        pass
    reader = BamReader(path)
```

Extension-based dispatch (`.cram` lowercased). Magic-byte sniffing
is unnecessary — samtools-produced CRAMs use `.cram` and BAMs use
`.bam`/`.sam`. If a user passes a CRAM file without the `.cram`
extension, they can rename it; we don't sniff.

### Output (canonical JSON to stdout)

**Unchanged from M87.** Same schema, same serialisation
(sorted keys, 2-space indent, MD5 fingerprints, trailing
newline). The `provenance_count` field will naturally differ
between BAM and CRAM fixtures because samtools injects different
`@PG` records on each format's read path — that is correct and
expected.

### Exit codes

* `0` — success
* `2` — argparse error (missing path, `--reference` missing for `.cram`, etc.)
* `1` — runtime error (samtools not on PATH, FASTA missing, malformed input)

Errors go to stderr; stdout is reserved for canonical JSON only.

## 3. File-by-file plan

### Python (Task 53 — reference implementation, run first)

**Modify** `python/src/ttio/importers/bam_dump.py`:

```python
"""bam_dump — canonical-JSON dump of a SAM/BAM/CRAM file for the
M87 / M88.1 cross-language conformance harness.

Usage::

    # BAM/SAM (M87):
    python -m ttio.importers.bam_dump <path>

    # CRAM (M88.1):
    python -m ttio.importers.bam_dump <path.cram> --reference <fa>

Reads the file via :class:`~ttio.importers.bam.BamReader` for SAM/BAM
or :class:`~ttio.importers.cram.CramReader` for CRAM (auto-dispatched
on the `.cram` extension) and emits a canonical JSON document on
stdout matching the schema documented in HANDOFF.md M87 §7. The
same shape is produced by the ObjC ``TtioBamDump`` and Java
``BamDump`` CLIs.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from typing import Any

from .bam import BamReader
from .cram import CramReader


__all__ = ["dump", "main"]


def dump(
    path: str,
    name: str = "genomic_0001",
    reference: str | None = None,
) -> dict[str, Any]:
    """Read ``path`` and return the canonical-JSON-shaped dict.

    If ``path`` ends in ``.cram`` (case-insensitive), a
    :class:`CramReader` is used; ``reference`` must then be provided.
    Otherwise a :class:`BamReader` handles the file (samtools
    auto-detects SAM vs BAM); ``reference`` is accepted but unused.

    Returned keys are unchanged from M87 — see this module's
    docstring for the full schema.
    """
    if path.lower().endswith(".cram"):
        if reference is None:
            raise ValueError(
                "--reference <fasta> is required for .cram input"
            )
        reader = CramReader(path, reference)
    else:
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
        description=(
            "Emit canonical M87/M88.1 JSON for a SAM, BAM, or CRAM file."
        ),
    )
    parser.add_argument(
        "path",
        help="Path to a SAM, BAM, or CRAM file (.cram dispatches to CramReader).",
    )
    parser.add_argument(
        "--reference", default=None,
        help="Path to reference FASTA — required for .cram input, ignored otherwise.",
    )
    parser.add_argument(
        "--name", default="genomic_0001",
        help="Genomic-run name to embed in the JSON (default: genomic_0001).",
    )
    args = parser.parse_args(argv)

    try:
        payload = dump(args.path, name=args.name, reference=args.reference)
    except ValueError as exc:
        parser.error(str(exc))  # exits 2 with message on stderr

    sys.stdout.write(json.dumps(payload, sort_keys=True, indent=2))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

**Tests:** add 2 pytest cases to a new
`python/tests/integration/test_m88_1_bam_dump_cram.py` (or extend
the existing `test_m87_bam_dump.py` if it exists — implementer's
call):

1. `test_bam_dump_dispatches_to_cram_reader` — runs the CLI as a
   subprocess against the M88 CRAM fixture with `--reference`,
   asserts JSON parses, has `read_count == 5`, `sample_name ==
   "M88_TEST_SAMPLE"`.
2. `test_bam_dump_cram_without_reference_errors` — runs the CLI
   on the M88 CRAM fixture without `--reference`, asserts
   non-zero exit + error message on stderr mentioning `--reference`.

**Commit (Python only):**
```
git add python/src/ttio/importers/bam_dump.py \
        python/tests/integration/test_m88_1_bam_dump_cram.py
git commit -m "feat(M88.1): bam_dump --reference flag + .cram extension dispatch"
```

After Python commits, capture the canonical JSON output for the
M88 CRAM fixture (write to a scratch file, do not commit). ObjC
and Java implementers will diff their outputs against this
reference.

### ObjC (Task 54 — implements after Python)

**Modify** `objc/Tools/TtioBamDump.m`:

- Parse `--reference <fa>` flag in main() (alongside existing
  positional path + `--name`).
- After parsing args, check `[path hasSuffix:@".cram"]` (case-
  insensitive) and dispatch to `[[TTIOCramReader alloc]
  initWithPath:path referenceFasta:reference]` if true; else use
  the existing `TTIOBamReader` path.
- If the path is `.cram` and `--reference` is absent, fprintf an
  error to stderr and exit 2.

The canonical-JSON serialisation logic stays identical (this is
the byte-exact contract — do not touch it).

**Verification:** rebuild the binary, run it against the M88 CRAM
fixture with `--reference`, diff output against the Python
reference output. Must be byte-identical.

**Commit (ObjC only):**
```
git add objc/Tools/TtioBamDump.m
git commit -m "feat(M88.1): TtioBamDump --reference flag + .cram extension dispatch"
```

### Java (Task 55 — implements after Python, parallel with ObjC)

**Modify** `java/src/main/java/global/thalion/ttio/importers/BamDump.java`:

- Parse `--reference <fa>` flag in main() (alongside existing
  positional path + `--name`).
- After parsing, check `path.toLowerCase().endsWith(".cram")` and
  dispatch to `new CramReader(Paths.get(path), Paths.get(reference))`
  if true; else use existing `BamReader` path.
- If the path is `.cram` and `--reference` is absent, print error
  to stderr and `System.exit(2)`.

The canonical-JSON serialisation logic stays identical (byte-exact
contract).

**Verification:** `mvn -o compile`, then run via `mvn -o -q
exec:java -Dexec.mainClass=...BamDump -Dexec.args="<cram>
--reference <fa>"`. Diff against Python reference.

**Commit (Java only):**
```
git add java/src/main/java/global/thalion/ttio/importers/BamDump.java
git commit -m "feat(M88.1): BamDump --reference flag + .cram extension dispatch"
```

### Cross-language harness + docs (Task 56)

**Modify** `python/tests/integration/test_m88_cross_language.py`:

Append three new tests (no new harness file):

1. `test_python_cram_dump_works` — sanity check: Python CLI on M88
   CRAM with `--reference` produces non-empty JSON with
   `read_count == 5`, `sample_name == "M88_TEST_SAMPLE"`.
2. `test_objc_cram_matches_python_byte_exact` — ObjC CLI output
   on M88 CRAM == Python output (byte-exact).
3. `test_java_cram_matches_python_byte_exact` — same for Java.

Add a CRAM fixture path constant + `_python_cram_dump()` /
`_objc_cram_dump()` / `_java_cram_dump()` helpers next to the
existing BAM helpers. Each new helper just invokes the same CLI
with the CRAM fixture path + `--reference` arg.

**Update `docs/vendor-formats.md`** — in the M88 §SAM/BAM/CRAM
Export section's "Cross-language conformance" subsection, replace
the "Adding CRAM-aware dump CLIs across all three languages is
deferred to a future M88.1" text with a present-tense statement
that M88.1 extends the existing `bam_dump` CLI with a
`--reference` flag and the harness verifies byte-identical
canonical JSON across all three languages for both BAM and CRAM.

Also update the §CRAM section to note that the `bam_dump` CLI
auto-dispatches to `CramReader` when the input path ends in
`.cram`.

**Update `CHANGELOG.md`** — append M88.1 section under Unreleased
(after the M88 section).

**Update `WORKPLAN.md`** — append M88.1 entry after the M88
SHIPPED block.

**Update `README.md`** — append a short note to the CRAM importer
bullet mentioning the `bam_dump` CLI's `--reference` flag for CRAM.

**Commit (docs):**
```
git add python/tests/integration/test_m88_cross_language.py \
        docs/vendor-formats.md CHANGELOG.md WORKPLAN.md README.md
git commit -m "docs(M88.1): extend cross-language harness with CRAM + docs sweep"
```

## 4. Acceptance criteria

- All three CLIs accept `--reference` and dispatch to CramReader
  on `.cram` paths.
- All three CLIs reject `.cram` input without `--reference` (exit
  2, error mentions `--reference`).
- Existing M87 BAM behaviour is unchanged: `bam_dump foo.bam`
  still works without `--reference`.
- Extended `test_m88_cross_language.py` — all six tests pass:
  Python sanity (BAM), ObjC byte-exact (BAM), Java byte-exact
  (BAM), Python sanity (CRAM), ObjC byte-exact (CRAM), Java
  byte-exact (CRAM).
- No regressions in any language's existing test suite.

## 5. Critical notes

- **Canonical-JSON contract is unchanged.** The serialisation
  logic in each language MUST produce byte-identical output for
  the same WrittenGenomicRun. Do not touch the JSON emission —
  only the dispatch logic before it.
- **CRAM `provenance_count` will differ from BAM** for the same
  fixture pair, because samtools injects different `@PG` records
  per format. The canonical JSON for the CRAM fixture is its own
  ground truth; do not compare CRAM output against BAM output.
- **Extension dispatch is case-insensitive.** `Path.cram`,
  `Path.CRAM`, `Path.Cram` all dispatch to CramReader.
- **`--reference` for BAM/SAM is accepted but unused.** Do not
  error — keeps the CLI tolerant of scripts that always pass
  `--reference` (defensive).
- **Do NOT commit the autogenerated `<fasta>.fai`** index — it's
  reproducible at runtime and was deliberately excluded from M88.
- **No `git add -A`.** Each implementer commits only their own
  language paths to prevent the M84-style commit-bundling race.
- **One commit per language; one commit for docs.** Four commits
  total expected on top of `3e56d0a`.

## 6. Sequencing

1. Python implementer (Task 53) — produces reference canonical JSON
   for M88 CRAM fixture.
2. ObjC implementer (Task 54) + Java implementer (Task 55) in
   parallel — both diff against Python reference.
3. Docs + harness (Task 56) — extends harness, runs end-to-end,
   sweeps docs.
4. Push.
