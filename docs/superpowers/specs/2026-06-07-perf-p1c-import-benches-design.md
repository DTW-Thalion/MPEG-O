# Perf P1c — real-format import benchmarks — Design

**Date:** 2026-06-07
**Origin:** `docs/architecture/2026-06-06-perf-suite-analysis.md` (coverage gap: real-format import
perf — mzML/nmrML none, BAM Python-only/ungated). Third sub-cycle of P1 (after P0, P1a, P1b).
**Scope:** Add real-format import benchmarks (BAM, mzML, nmrML) to all three SDK perf harnesses,
reading committed fixtures through each SDK's public importer API. Perf-tooling only — no SDK
product code.

## Problem
The harnesses bench only synthetic, in-memory data. There is no coverage of the real-format
**import** paths (BAM via samtools/htsjdk, mzML XML parse, nmrML base64+zlib FID decode) — a
notable gap since importers are a first-class, recently-expanded surface (Reader registry,
PR #213/#214/#216). We want timing numbers for "parse a real vendor file into a dataset".

## Design

### One new bench per harness: `import`
Add a `bench_import` (Python), `benchImport` (Java), `bench_import` (ObjC) that times reading
each committed fixture through the SDK's public importer, using the existing min-of-N timing
helper (`_timed` / `timedMinMs` / `timedMin`). Register it in the dispatch table under key
`import`, emitted scenario keys:

- `import.bam` — read the genomic BAM fixture → genomic run
- `import.mzml_tiny` — read the 4-spectrum ProteoWizard sample
- `import.mzml_1min` — read the 39-spectrum vendor file (primary heavy mzML decode)
- `import.nmrml` — read the BMRB nmrML (base64+zlib FID decode)

### Fixtures (committed, offline, shared across SDKs for comparability)
All three harnesses read the SAME files via repo-root-relative paths (`ROOT` is already derived
in each `build_and_run_*_full.sh`):
- mzML/nmrML: `objc/Tests/Fixtures/{tiny.pwiz.1.1.mzML, 1min.mzML, bmse000325.nmrML}`
- BAM: `objc/Tests/Fixtures/genomic/m87_test.bam` (same 554B file mirrored in python/tests +
  java resources; use the objc copy so all three read identical bytes)

### Importer APIs
- **Python:** `ttio.importers.bam.BamReader(path).to_genomic_run()`;
  `ttio.importers.mzml.read(path)`; `ttio.importers.nmrml.read(path)`.
- **Java:** `new BamReader(Path).toGenomicRun("r")` (htsjdk, no external tool);
  `MzMLReader.read(String)`; `NmrMLReader.read(String)`.
- **ObjC:** `[[TTIOBamReader alloc] initWithPath:] -toGenomicRunWithName:region:error:`;
  `+[TTIOMzMLReader readFromFilePath:error:]`; `+[TTIONmrMLReader readFromFilePath:error:]`.

### BAM external tool
Python + ObjC BAM import shells out to `samtools` (Java uses htsjdk). The suite is **manual-only**
(P1a) and runs on the maintainer's box where samtools is installed, so this is not a CI blocker.
If `samtools` is absent, the BAM phase must degrade to N/A (NaN / null — the harnesses already
support absent metrics) rather than abort the whole harness.

## Edge cases / known limitations
- **Small fixtures → sub-floor timings.** The fixtures are fixed-size (do not scale with
  `PERF_N`); `import.bam` (554B) and `import.mzml_tiny` (25KB) will likely time <5ms and so fall
  under the `min_abs_ms` floor → reported but not gated. That is acceptable: these are
  informational import-path numbers, and `import.mzml_1min` / `import.nmrml` exercise the heavy
  decode paths and may exceed the floor. Do NOT add larger fixtures yet (YAGNI); revisit only if
  a gateable import number is wanted.
- **Re-runnability:** import reads are read-only / pure (no fixture mutation), so the min-of-N
  helper can repeat them safely. Any importer returning an open handle must close it inside the
  timed op (mirror the transport-decode pattern).
- **Cross-SDK numbers** are comparable because all three read identical fixture bytes through
  equivalent APIs; absolute decode times will still differ by SDK (expected).

## Invariants & verification
- Perf-tooling only — no `src/`/SDK product code; only the 3 harness files + baseline.json.
- All three harnesses build and run the `import` bench end-to-end and emit finite numbers for
  every benchable phase (NaN/null only if samtools is genuinely absent).
- Cross-SDK: all three read the same fixtures; `import.mzml_1min` and `import.nmrml` produce
  numbers in the same ballpark order of magnitude.
- baseline.json re-captured at n=100000 (import phases added; they are fixture-fixed so `n` does
  not change them).

## Success criteria
An `import` bench in all three harnesses timing BAM + mzML(tiny,1min) + nmrML reads of committed
fixtures via min-of-N; baseline re-captured; numbers reported. One PR.

## Out of scope (later P1 sub-cycles)
P1d PQC sign/verify + mate_info_v2 benches + fix the `encryption.genomic` bench-validity bug
(impossible 3.7ms/10MB timing, currently report-only); P1e cross-SDK perf-parity check. Larger
real BAMs (175MB–1.6GB DVC data) stay with the separate CLI benchmark suite, not this harness.
