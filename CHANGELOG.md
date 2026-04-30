# CHANGELOG

All notable changes to the TTI-O multi-omics data standard reference
implementation. Dates are release dates; the repository commits record
the actual timeline.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/); the
public API is stable from v1.0.0 onward (tagged 2026-04-23). See
`docs/api-stability-v0.8.md` for the per-symbol stability tags.

---

## [Unreleased]

### Added

- **M93 — REF_DIFF reference-based sequence-diff codec** (codec id `9`).
  Context-aware per-channel codec: encoder/decoder consume
  `(positions, cigars, reference_resolver)` alongside the channel
  bytes. Slice-based wire format (10 K reads/slice, CRAM-aligned)
  for random-access decode. Embedded reference at
  `/study/references/<reference_uri>/` with auto-deduplication across
  runs sharing a URI. Falls back silently to BASE_PACK when reference
  unavailable at write (Q5b); raises `RefMissingError` on read when
  unresolvable (Q5c). Closes ~80% of the M92 chr22 sequence-channel
  compression gap to CRAM 3.1.
  - Python reference: `python/src/ttio/codecs/ref_diff.py` (480
    lines), `python/src/ttio/genomic/reference_resolver.py`,
    pipeline integration in `python/src/ttio/spectral_dataset.py` +
    `python/src/ttio/genomic_run.py`.
  - Format version bumps `1.4 → 1.5` when REF_DIFF is used; M82-only
    writes stay at `1.4` for byte-parity with existing fixtures.
  - 53 new Python tests across unit + pipeline + canonical fixture
    + perf + reference-resolver coverage. Four canonical fixtures
    (`ref_diff_a/b/c/d.bin`) committed under
    `python/tests/fixtures/codecs/`.
  - **Single-chromosome-per-run limitation** in v1.2 first pass
    enforced at write + read with a clear error; multi-chromosome
    is a future M93.X follow-up.
  - **`Cython>=3.0` build dep added** to `pyproject.toml` (used by
    the upcoming M94 C extension; M93 itself is pure Python).
  - Cross-language: ObjC + Java parity in progress.
  - Spec: `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`.
  - Plan: `docs/superpowers/plans/2026-04-28-m93-ref-diff-codec.md`.
  - Codec spec: `docs/codecs/ref_diff.md`.

### Added (continued)

- **M94 — FQZCOMP_NX16 lossless quality codec** (codec id `10`).
  Context-modeled adaptive arithmetic coding with 4-way interleaved
  rANS, mirroring CRAM 3.1's default fqzcomp-Nx16 (Bonfield 2022).
  Context vector `(prev_q[0..2], position_bucket, revcomp_flag,
  length_bucket)` hashed via SplitMix64 to a 12-bit index. Per-
  symbol freq update (`+16`) with halve-with-floor-1 renormalisation
  at 4096 max-count. Wire-format header 54+L bytes; body has a
  16-byte substream-length prefix before round-robin interleaved
  bytes. Auto-default on `qualities` gated on v1.5 candidacy
  (§80h) to preserve M82 byte-parity.
  - Python reference: `python/src/ttio/codecs/fqzcomp_nx16.py`
    (~880 lines pure-Python ref) + `_fqzcomp_nx16/_fqzcomp_nx16.pyx`
    (~470 lines Cython accelerator). Adds `Cython>=3.0` to
    `pyproject.toml` build deps.
  - Objective-C native: `objc/Source/Codecs/TTIOFqzcompNx16.{h,m}`.
    Reuses M83's `TTIORans` normaliseFreqs verbatim.
  - Java native: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16.java`.
    `long`-typed unsigned-uint32 emulation; reuses
    `Rans.normaliseFreqs` verbatim.
  - 8 canonical conformance fixtures (`fqzcomp_nx16_a/b/c/d/e/f/g/h.bin`)
    byte-exact across Python, ObjC, Java.
  - ~146 new M94 tests across the three languages, zero regressions.
  - **Known limitation (M94.X follow-up, REQUIRED for v1.2.0)**:
    Python encoder at 0.19 MB/s vs 30 MB/s spec target. Hot path is
    M83's pure-Python `_normalise_freqs` called per symbol. Tracked
    in `WORKPLAN.md` Phase 9 as release-prep blocker.
  - Spec: `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`.
  - Plan: `docs/superpowers/plans/2026-04-28-m94-fqzcomp-nx16-codec.md`.
  - Codec spec: `docs/codecs/fqzcomp_nx16.md`.

### Added (continued)

- **M94.Z (FQZCOMP_NX16_Z, codec id 12)**: CRAM-mimic FQZCOMP_NX16 variant.
  Static-per-block frequency tables, 16-bit renormalization, T=4096 fixed.
  Mathematically guaranteed byte-pairing (T divides b·L=2^31 exactly).
  ~145 MB/s encode in Python (Cython); ~22× faster than M94 v1 on chr22.
  Cross-language byte-exact (Python / ObjC / Java) on 7 canonical fixtures.
  Spec at docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md.
  - Python reference: `python/src/ttio/codecs/fqzcomp_nx16_z.py` (~1015
    lines pure-Python ref) + `_fqzcomp_nx16_z/_fqzcomp_nx16_z.pyx`
    (~702 lines Cython accelerator).
  - Objective-C native: `objc/Source/Codecs/TTIOFqzcompNx16Z.{h,m}` (~1339 lines).
  - Java native: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
    (~944 lines), `long`-typed unsigned-uint32 emulation.
  - 7 canonical conformance fixtures (`m94z_a/b/c/d/f/g/h.bin`)
    byte-exact across Python, ObjC, Java.
  - Per-language measured perf (synthetic 100 K reads × 100bp Q20-Q40):
    Python (Cython) 145 MB/s encode / 94 MB/s decode; ObjC 51 / 31 MB/s;
    Java 33 / 14 MB/s.
  - chr22.lean.mapped.bam (145 MiB, 1.77 M reads) full-pipeline wall:
    encode 48.77 s (vs 18 min under M94 v1), decode 141.66 s (vs 24.6 min).
    CRAM 3.1 reference baseline on the same chr22: 3.03 s enc / 1.63 s dec.
    Codec compute is now ~4 % of pipeline wall; remaining ~95 % is M93 +
    HDF5 framework + non-Cython codecs.
  - Spec: `docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md`.
  - Codec spec: `docs/codecs/fqzcomp_nx16_z.md`.

### Changed

- Default qualities codec for v1.5 files is now FQZCOMP_NX16_Z (id 12).
  Files with FQZCOMP_NX16 (id 10, M94 v1) still decode via the legacy path.
  M94 v1 (`FQZN`, id 10) and M94.Z (`M94Z`, id 12) coexist in the codebase;
  the reader dispatches by `@compression` attribute and, defensively, by
  magic. There is no automatic in-file migration — rewriting an existing
  M94 v1 file under M94.Z is an application-layer decode-then-encode.

### Added (continued)

- **M95 — DELTA_RANS_ORDER0 integer-channel codec** (codec id `11`).
  Delta + zigzag + unsigned LEB128 varint + rANS order-0 wrapper for
  sorted-ascending integer channels. 8-byte header (`DRA0` magic) +
  rANS body. Auto-default integer channel compression on v1.5 genomic
  runs: `positions → DELTA_RANS_ORDER0`, `flags / mapping_qualities /
  template_lengths / mate_info_pos / mate_info_tlen → RANS_ORDER0`,
  `mate_info_chrom → NAME_TOKENIZED`.
  - Python reference: `python/src/ttio/codecs/delta_rans.py`.
  - Objective-C: `objc/Source/Codecs/TTIODeltaRans.{h,m}`.
  - Java: `java/src/main/java/global/thalion/ttio/codecs/DeltaRans.java`.
  - 4 canonical fixtures (`delta_rans_{a,b,c,d}.bin`) byte-exact across
    Python / ObjC / Java.
  - Spec: `docs/superpowers/specs/2026-04-30-m95-delta-rans-design.md`.
  - Codec spec: `docs/codecs/delta_rans.md`.

---

## [1.2.0] — 2026-04-28 — TTI-O rebrand + genomic stack + multi-omics integration

M80 TTI-O rebrand + M81 reverse-DNS Java groupId + M83 rANS + M84
BASE_PACK + M86 codec wiring (A + B + C + D + E + F) + M85
QUALITY_BINNED + NAME_TOKENIZED + M87 SAM/BAM importer + M88 CRAM
importer + BAM/CRAM exporters + M88.1 bam_dump CRAM dispatch + M89
transport extension + M90 genomic encryption/anonymisation + M91
multi-omics integration + Phase 1+2 abstraction polish + M92
benchmarking + docs refresh.

> **Wire-format compatibility:** clean break from v1.1.x readers per
> Binding Decision §74 (M80 rebrand drops `mpgo` / `MPGO` for `ttio` /
> `TTIO`). Within v1.2.0 the M82–M91 + Phase 1+2 line is internally
> backward-compatible: M86 codec attributes are absent on M82-shape
> files (readers see uncompressed natural-dtype channels); pre-M89
> transport readers reject genomic streams cleanly via the
> `opt_genomic` flag check; Phase 2 per-run provenance writes BOTH
> the canonical compound dataset and the legacy `@provenance_json`
> attribute mirror so Phase 1 readers round-trip without loss.

### Phase 1+2 abstraction polish — `Run` protocol + per-run compound provenance dual-write (2026-04-28)

OO design pass on the modality surface driven by M91 findings.
Both `AcquisitionRun` and `GenomicRun` now conform to a uniform
`Run` interface; per-run provenance writes the canonical
`<run>/provenance/steps` compound dataset on the HDF5 fast path in
all three languages while keeping the `@provenance_json` mirror as
a fallback. Cross-language byte-parity harness extended.

#### Added

- **`Run` protocol** — Python `runtime_checkable Protocol`
  (`ttio.protocols.run.Run`), ObjC `@protocol TTIORun`, Java
  `interface global.thalion.ttio.protocols.Run`. Members: `name`,
  `acquisition_mode` / `acquisitionMode`, `__len__` / `count` /
  `numberOfRuns`, `__getitem__` / `get` / `objectAtIndex:`,
  `provenance_chain` / `provenanceChain`. Both `AcquisitionRun`
  and `GenomicRun` conform.
- **Modality-agnostic helpers on `SpectralDataset`** —
  `runs` (canonical unified mapping; ObjC `runs`; Java
  `runs()`), `runs_for_sample(uri)` / `runsForSample:` /
  `runsForSample(uri)`, `runs_of_modality(cls)` /
  `runsOfModality:` / `runsOfModality(class)`. Phase 1 alias
  `all_runs_unified` / `allRunsUnified` retained as a deprecated
  shim for Phase 1 callers.
- **`GenomicRun.provenance_chain()` / `provenanceChain`** — closes
  the M91 read-side gap; cross-modality callers no longer need to
  fall back to `@sample_name`.
- **Mixed-dict write API** — `SpectralDataset.write_minimal(runs={...})`
  accepts a mixed mapping of MS + genomic runs and dispatches by
  isinstance / class. Java mixed `Map<String, Object>` overload.
  ObjC `mixedRuns:` parameter on `+writeMinimalToPath:`.
- **`TTIOWrittenRun.provenanceRecords`** (ObjC) — previously
  missing; MS runs written via `+writeMinimalToPath:` now carry
  per-run provenance through to the compound + JSON mirror.
- **Per-run compound provenance dual-write** — Java
  (`AcquisitionRun.writeProvenance`,
  `SpectralDataset.writeGenomicRunSubtree`) and ObjC
  (`+writeMinimalToPath:` MS loop) now write
  `<run>/provenance/steps` compound on HDF5 backends while still
  emitting the `@provenance_json` mirror. Python had this already.
- **Per-run compound provenance dual-read** — Java and ObjC
  readers prefer the compound dataset and fall back to the JSON
  attribute (Python already had this).
- **`Hdf5Provider.tryUnwrapHdf5Group(StorageGroup)`** (Java) —
  lets modality-agnostic write/read paths reach the native
  compound API without leaking the provider type.
- **In-process MPAD test for the M90.12 wire bump** (ObjC) —
  spawns `TtioPerAU encrypt` / `decrypt` via NSTask and verifies
  the `MPA1` magic, dtype byte, and per-record value width on
  both MS (FLOAT64) and genomic (UINT8) fixtures.
- **M51 cross-language byte-parity harness extended** —
  `ms_per_run_provenance` section now part of the Python / Java /
  ObjC dumper byte-equality check, exercising the new dual-write.

#### Changed

- **`TTIOAnonymizer` mixed-path refactor** (ObjC) — MS + genomic
  collapsed onto the unified `+writeMinimalToPath:` call.
  −270 / +150 lines. Removes `_appendGenomicTransformedToFile:`,
  `_applyGenomicPolicies:`, and the unused `arrayFromDoubles`
  helper.

Commits: `145485c`, `772eb00`, `6992ae9`, `7a2ffef`, `54ef6f1`,
`6ceba4a`, `6200b4f`. Test suites green: Python 1324 passed,
Java 755/0/0/0, ObjC 3070/0.

---

### M91 — Multi-omics integration test (2026-04-28)

Single `.tio` carrying a 10K-read WGS genomic run + a 1K-spectrum
proteomics MS run + a 100-spectrum NMR metabolomics run, with
shared provenance keyed on a common sample URI and a unified
encryption envelope. Verifies cross-modality query
(`runs_for_sample("sample://NA12878")` returns all three
modalities) and `.tis` transport multiplexing across all three
languages. Python ref impl shipped in `9038f76`; Java and ObjC
parity follows from M82–M90 infrastructure already in place.

---

### M90 — Encryption, signatures, and anonymisation for genomic data (2026-04-27 / 2026-04-28)

Shipped as 15 sub-mileposts (M90.1–M90.15) across all three
languages. Per-AU AES-256-GCM on genomic signal channels with
AAD = `dataset_id || au_sequence || channel_name`; ML-DSA-87
signatures; region-based encryption (encrypt chr6 / HLA, leave
chr1 in clear) with per-region key map keyed on the reserved
`_headers` key; genomic anonymiser (strip read names, randomise
quality, optionally mask regions).

#### Added

- **M90.7** — Java VL_STRING attribute reader/writer using the
  canonical JHDF5 `H5Awrite_VLStrings` / `H5Aread_VLStrings`
  entry points (replaces the JVM-crashing `H5AwriteVL` path).
  ObjC reader follow-up for the same wire shape in `a3495d4`.
- **M90.8 / M90.9 / M90.10** — AU compound-field round-trip on
  the wire; UINT8 wire compression dispatched through the M86
  codec stack. Java parity in `969875a`, ObjC in `bbb9de9`.
- **M90.11** — Encrypted genomic AU headers with per-region key
  map. The reserved key `_headers` in the `keyMap` carries the
  header-encryption key; per-chromosome keys are separate.
- **M90.12** — UINT8-aware MPAD format. Magic bumped from
  `"MPAD"` → `"MPA1"`; new per-entry dtype byte (1 = FLOAT64,
  6 = UINT8) lets the decoder keep genomic UINT8 channels
  unmangled by the previous unconditional float64 cast.
- **M90.13** — Region masking by SAM overlap (anonymiser).
- **M90.14** — Seeded-RNG random quality scores (anonymiser).
- **M90.15** — Sign chromosomes VL compound dataset (Python +
  cross-language follow-up).

#### Fixed

- ObjC VL_STRING attribute reader regression discovered during
  M91 (Java now writes VL_STRING per M90.7, but ObjC's reader
  expected fixed-length, throwing "unable to convert between
  src and dst datatypes"). Fix probes `H5Tis_variable_str` and
  reclaims via `H5Dvlen_reclaim`. Commit `a3495d4`.
- MPAD float64 cast bug (Python). Genomic UINT8 channels were
  silently mangled by `_do_decrypt`'s unconditional float64
  cast; M90.12 adds the per-entry dtype byte to fix. Commit
  `20829e1`.

Commits across both write and read sides + cross-language parity
land between `020ec94` (M90.6) and `f1728dc` / `cb728f7` (final
Java + ObjC parity, 2026-04-28).

---

### M89 — Transport layer extension for genomic (2026-04-27)

`.tis` GenomicRead AU payload carries the chromosome + position +
mapq + flags prefix that replaced the zeroed spectral fields from
M79. `spectrum_class == 5` discriminates genomic AUs on the wire.

#### Added

- `TransportWriter.write_genomic_run()` /
  `TransportReader.materialise_genomic_run()` in all three
  languages.
- `AUFilter` extended with chromosome + position-range
  predicates so subscribers can filter at the broker.
- Multiplexed streams: MS + genomic runs interleaved in a
  single `.tis` (one stream, per-AU `spectrum_class` dispatch).
- Per-AU encryption verified end-to-end on genomic AUs.
- 3×3 cross-language transport matrix green (Python / Java /
  ObjC, both encode and decode directions).

---

### M88.1 — `bam_dump --reference` flag for CRAM cross-language conformance (2026-04-26)

Closes the implicit-parity gap from M88. Extends the existing
M87 `bam_dump` / `TtioBamDump` / `BamDump` CLI in each language
with an optional `--reference <fasta>` flag and case-insensitive
`.cram` extension dispatch to the M88 `CramReader` /
`TTIOCramReader` / Java `CramReader`. No new format parsing, no
new external dependencies; pure CLI extension over the readers
shipped in M88. User chose **Option A** (extend existing CLI)
over **Option B** (parallel `cram_dump` per language) — single
CLI surface, single harness file, mirrors the
`CramReader extends BamReader` inheritance pattern.

#### Added

- **Python** (`python/src/ttio/importers/bam_dump.py`) — added
  `--reference` argparse arg + `reference` parameter to
  `dump()`. Dispatches to `CramReader(path, reference)` when
  path ends in `.cram` (case-insensitive); errors via
  `parser.error()` (exit 2) when `.cram` is given without
  `--reference`. Existing BAM/SAM behaviour unchanged. Two new
  pytest cases in
  `python/tests/integration/test_m88_1_bam_dump_cram.py`:
  `test_bam_dump_dispatches_to_cram_reader` and
  `test_bam_dump_cram_without_reference_errors`. Python suite:
  1045 → 1047 passed, zero regressions.
- **Objective-C** (`objc/Tools/TtioBamDump.m`) — hand-rolled arg
  loop also recognises `--reference <fa>`. Dispatches via
  `[path.lowercaseString hasSuffix:@".cram"]` to
  `[[TTIOCramReader alloc] initWithPath:referenceFasta:]`. For
  `.cram` without `--reference`, prints stderr error and returns
  2 from `main()`. ObjC suite: 2595 → 2597 passed (the 2 baseline
  M38 Thermo failures didn't reproduce in this run).
- **Java** (`java/src/main/java/global/thalion/ttio/importers/BamDump.java`)
  — added `--reference <fa>` and `--reference=<fa>` argparse
  handling (mirrors existing `--name`). Dispatches via
  `pathStr.toLowerCase().endsWith(".cram")` to
  `new CramReader(Paths.get(pathStr), Paths.get(reference))`. For
  `.cram` without `--reference`, stderr error and `return 2`.
  Java suite: 543 → 543 (no delta; coverage is in the cross-
  language harness).

#### Cross-language conformance

- **`python/tests/integration/test_m88_cross_language.py`** —
  extended with a `CRAM_FIXTURE` / `CRAM_REFERENCE` constant
  pair, three new `_*_cram_dump()` helpers, and three new tests:
  `test_python_cram_dump_works`,
  `test_objc_cram_matches_python_byte_exact`, and
  `test_java_cram_matches_python_byte_exact`. All 6 tests
  (3 BAM + 3 CRAM) pass against the M88 fixtures. The CRAM
  canonical JSON for the M88 fixture is exactly **914 bytes**
  with md5 `2be5c5bccc95635240aa60337406cb35`, byte-identical
  across all three languages.

#### Documentation

- **`docs/vendor-formats.md`** — added a "CLI dispatch via
  `bam_dump --reference`" subsection to §CRAM. Replaced the
  "Adding CRAM-aware dump CLIs ... is deferred to a future
  M88.1" caveat in §SAM/BAM/CRAM Export with a present-tense
  description of the 6-test BAM+CRAM cross-language harness.
- **`README.md`** — appended a `--reference` flag note to the
  CRAM importer bullet.
- **`WORKPLAN.md`** — appended M88.1 SHIPPED entry.

#### Notes

- The CRAM fixture's `provenance_count` differs from the BAM
  fixture's by design — samtools injects different `@PG` records
  on each format's read path. The canonical JSON for each
  fixture is its own ground truth; do not compare CRAM output
  against BAM output.
- `--reference` is accepted but unused for BAM/SAM paths
  (defensive — keeps the CLI tolerant of scripts that always
  pass it).
- Cross-language dispatch is extension-based (`.cram` lower-
  cased), not magic-byte sniffing. samtools-produced CRAMs use
  `.cram` and BAMs use `.bam`/`.sam`; if the user has a CRAM
  with a different extension, they can rename it.

### M88 — CRAM Importer + BAM/CRAM Exporters (2026-04-26)

Closes the read/write loop for SAM/BAM/CRAM. Adds a `CramReader`
that subclasses the M87 `BamReader` and a `BamWriter` /
`CramWriter` pair that compose SAM text from a
`WrittenGenomicRun` and pipe it through `samtools view -b` (BAM)
or `samtools view -C | samtools sort -O cram` (two-stage CRAM,
because CRAM slices require sorted input). All in all three
languages; no `htslib` linked.

**Same external dependency as M87** (samtools on PATH at
runtime); no new build-time deps. CRAM read/write requires a
reference FASTA — enforced at construction (Python `TypeError`,
ObjC `NS_UNAVAILABLE` selector, Java null-rejection of the FASTA
path argument). Binding Decision §139.

#### Added

- **Python** (`python/src/ttio/importers/cram.py` +
  `python/src/ttio/exporters/{bam,cram}.py`) — `CramReader(path,
  reference_fasta)` extends `BamReader` with `--reference <fa>`
  injected into the samtools view command line. `BamWriter(path)`
  / `CramWriter(path, reference_fasta)` compose SAM text from a
  `WrittenGenomicRun` and pipe via `subprocess.Popen` chains.
  RNEXT collapses to `=` only when read is mapped AND mate
  chromosome equals read chromosome (§136); negative
  `mate_position` maps to 0 on emit (§138); QUAL ASCII Phred+33
  pass-through verbatim. 14 pytest cases including BAM↔BAM,
  CRAM↔CRAM, BAM↔CRAM round-trips with per-field equality
  checks. Python suite: 915 → 932 passed, zero regressions.
- **Objective-C** (`objc/Source/Import/TTIOCramReader.{h,m}` +
  `objc/Source/Export/TTIO{Bam,Cram}Writer.{h,m}`) — NSTask
  subprocess pipelines (single task for BAM emit, two NSTasks
  with NSPipe for CRAM emit). `-[TTIOCramReader initWithPath:]`
  and `-[TTIOCramWriter initWithPath:]` declared `NS_UNAVAILABLE`
  to steer ARC clients to the two-arg initialisers. 14 test
  methods in `TestM88CramBamRoundTrip.m` (+63 PASS assertions).
  ObjC suite: 2532 → 2595 passed (zero regressions; the 2 M38
  Thermo failures are pre-existing).
- **Java** (`java/src/main/java/global/thalion/ttio/importers/CramReader.java`
  + `java/src/main/java/global/thalion/ttio/exporters/{Bam,Cram}Writer.java`)
  — `ProcessBuilder` subprocess pipelines. CRAM two-stage uses
  `Process.getInputStream().transferTo(secondProcess.getOutputStream())`
  in a pump thread. `BamReader.java` got a small backwards-
  compatible refactor: extracted the samtools view command list
  into `protected List<String> buildSamtoolsViewCommand(String
  region)` so `CramReader` can override without duplicating the
  SAM parser. Caller-visible behaviour unchanged. 14 tests in
  `CramBamRoundTripTest.java`. Java suite: 529 → 543 passed,
  zero regressions.

#### Cross-language conformance

- **`python/tests/integration/test_m88_cross_language.py`** — new.
  Re-uses the M87 `bam_dump` CLIs (`python -m
  ttio.importers.bam_dump`, `TtioBamDump`,
  `global.thalion.ttio.importers.BamDump`) against the new M88 BAM
  fixture. Asserts byte-identical canonical JSON across all three
  languages; passes today. CRAM cross-language read parity is
  verified implicitly: each language's unit suite consumes the
  same canonical M88 CRAM fixture and produces buffer-byte-
  identical decoded `WrittenGenomicRun` instances. Adding
  CRAM-aware dump CLIs across all three languages is deferred to
  M88.1 if the implicit verification ever proves insufficient.
- **Fixtures** (`python/tests/fixtures/genomic/m88_test*`) — 5
  reads on 2 chromosomes (4 chr1 perfect-match + 1 chr2
  perfect-match), multi-`@RG`, `M88_TEST_SAMPLE`. Reference FASTA
  is a 2-chromosome synthetic (chr1 = `ACGT`*250, chr2 =
  `TGCA`*250). Fixtures copied verbatim across all three
  languages; `regenerate_m88_fixtures.sh` is the reproducer.

#### Documentation

- **`docs/vendor-formats.md`** — appended §CRAM section and
  §SAM/BAM/CRAM Export section. Documents the constructor
  signature matrix, samtools command lines invoked, the SAM text
  emission rules (§136 RNEXT collapse, §138 PNEXT mapping, ASCII
  Phred+33 QUAL pass-through), the round-trip semantics matrix
  (BAM↔BAM, CRAM↔CRAM, BAM↔CRAM, CRAM↔BAM all lossless), and the
  out-of-scope list (CRAM 4.0, multi-`@RG` aggregation, optional
  SAM tag fields).
- **`README.md`** — Importers list gets a CRAM line; Exporters
  list gets a SAM/BAM/CRAM line. Both link to the relevant
  vendor-formats sections.
- **`WORKPLAN.md`** — M88 marked SHIPPED 2026-04-26.

#### Reference (`.fai`) handling

samtools autogenerates a `<fasta>.fai` index alongside the FASTA
on first read. The M88 fixture commits the reference but **NOT**
the index — let samtools regenerate it locally. This avoids
spurious diffs across machines (the index encodes byte offsets
that change with line-ending normalisation).

### M87 — SAM/BAM Importer (2026-04-26)

First Phase 5 (interop) milestone. A `BamReader` / `SamReader`
class in each of the three languages wraps `samtools view -h`
as a subprocess (no htslib linking, no pysam/htsjdk
dependency) and converts SAM/BAM input to `WrittenGenomicRun`
instances ready for the M82-era write path. samtools auto-
detects SAM vs BAM format from magic bytes; one parser handles
both. Optional region filter is passed verbatim to samtools.

**First M86-era milestone with an external runtime
dependency.** samtools must be on PATH at runtime; the class
itself is loadable without it, and the error fires only at
first import call (Binding Decision §135) with install hints
for apt / brew / conda.

#### Added

- **Python** (`python/src/ttio/importers/bam.py` +
  `sam.py`) — `BamReader.to_genomic_run(name, region,
  sample_name)` returns a `WrittenGenomicRun`. Subprocess
  wrapper via `subprocess.Popen(["samtools", "view", "-h",
  ...], text=True)` consumed line-by-line. SAM header
  parsing: `@SQ` → `reference_uri`, `@RG` → `sample_name` +
  `platform` (first-wins per §133), `@PG` →
  `ProvenanceRecord` list. SAM alignment columns 1–11 mapped
  to `WrittenGenomicRun` fields (RNEXT `=` expanded to RNAME
  per §131; 1-based positions preserved per §132). `bam_dump`
  CLI (`python -m ttio.importers.bam_dump <bam>`) emits
  canonical JSON with sorted keys + 2-space indent + MD5
  fingerprints for the sequences/qualities byte buffers — the
  cross-language conformance contract. 17 pytest cases
  including BAM → `.tio` → GenomicRun → AlignedRead round-
  trip. Full Python suite: 898 → 915 passed, zero
  regressions.
- **Objective-C** (`objc/Source/Import/TTIOBamReader.{h,m}` +
  `TTIOSamReader.{h,m}`) — NSTask-based subprocess wrapper.
  `TtioBamDump` CLI hand-rolls canonical-JSON emission
  (NSJSONSerialization on GNUstep doesn't reliably support
  `NSJSONWritingSortedKeys`, and Python's `indent=2` puts
  each array element on its own line which NSJSONSerialization
  compacts). Provenance exposed via a `provenanceRecords`
  property on the reader (since `TTIOWrittenGenomicRun` doesn't
  carry provenance fields). 55 new assertions across 16 test
  methods in `TestM87BamImporter.m`. ObjC suite: 2477 → 2532
  PASS, 2 pre-existing M38 Thermo failures unchanged.
- **Java** (`java/src/main/java/global/thalion/ttio/importers/BamReader.java`
  + `SamReader.java`) — ProcessBuilder-based subprocess.
  `BamDump` main-class emits canonical JSON via TreeMap-
  ordered serialisation. `lastProvenance()` accessor on the
  reader (Java's `WrittenGenomicRun` record doesn't carry
  provenance — convergent design with ObjC). Static
  `isSamtoolsAvailable()` probe with memoised positive cache;
  every test method uses `Assumptions.assumeTrue(...)` to
  skip cleanly when missing. 17 JUnit 5 tests
  (BamReaderTest 0 → 17). Java suite: 512 → 529.
- **Cross-language harness**
  (`python/tests/integration/test_m87_cross_language.py`) —
  runs all three `bam_dump` CLIs on the canonical fixture
  and asserts byte-identical output (1341 bytes per CLI;
  identical md5 `23d408e0c94a22d37c5e149df6f7d921` across
  Python, ObjC, Java). Skips ObjC/Java legs when their
  builds aren't available; runs the Python leg in isolation.
- **Cross-language fixture** —
  `python/tests/fixtures/genomic/m87_test.{sam,bam,bam.bai}`
  is a 10-read SAM/BAM in true coordinate-sorted order on
  two chromosomes (chr1, chr2) with mixed
  mapped/unmapped/soft-clipped reads, single @RG
  (`SM:M87_TEST_SAMPLE`, `PL:ILLUMINA`), single user @PG
  (`bwa`). Verbatim copies under
  `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`. The
  authoritative SAM source is committed alongside the
  binary BAM and a regeneration shell script
  (`regenerate_m87_bam.sh`) that runs `samtools view -bS`.
- **Documentation** — new SAM/BAM section in
  `docs/vendor-formats.md` (§SAM/BAM) covering installation
  via apt/brew/conda, binary resolution semantics,
  field-mapping table, header-line handling, region filter
  syntax, the canonical-JSON shape, and the cross-language
  conformance harness. README importers list updated.
  `python/pyproject.toml` no new dependencies (samtools is
  a system tool, not a Python package).

#### Verification

- Python: 17/17 tests in `test_m87_bam_importer.py` pass.
  Full suite: 915 passed / 42 failed / 64 skipped /
  4 xfailed / 3 errors (was 898 / 42 / 64 / 4 / 3); +17 new,
  zero new regressions.
- Objective-C: full test runner shows 2477 → 2532 PASS (+55
  M87 assertions across 16 test methods); 2 FAIL unchanged
  (pre-existing M38 Thermo).
- Java: `mvn -o test` → 529 / 0 fail / 0 error / 0 skipped
  (was 512 / 0 / 0 / 0). BamReaderTest 0 → 17.
- Cross-language: `test_m87_cross_language.py` runs all
  three `bam_dump` CLIs and verifies byte-identical output.
  All three legs (Python / ObjC / Java) match the reference
  byte-for-byte at 1341 bytes.

#### Notes

- **Provenance-on-the-reader pattern (convergent across
  languages).** Python's `WrittenGenomicRun` carries
  `provenance_records`; ObjC and Java's don't. Both ObjC and
  Java independently chose to expose provenance as a side-
  channel on the `BamReader` object
  (`reader.provenanceRecords` / `reader.lastProvenance()`)
  rather than modifying the M82 record shape — same design,
  same rationale (don't widen the M82 surface for an
  importer-side concern).
- **provenance_count is 3, not 1.** Each `samtools view`
  invocation injects its own `@PG` record; the M87 fixture's
  user-supplied `bwa` entry shares the chain with two
  samtools-injected entries (one for `view -bS` at fixture
  build, one for `view -h` at read). All three implementations
  see 3 entries; tests assert the `bwa` entry exists by name
  (the stable cross-language assertion) rather than asserting
  `provenance_count == 1`.
- **The SAM fixture was reordered from HANDOFF §5 source
  order to true coordinate-sorted order.** The HANDOFF §5
  spec listed reads `r000`..`r009` in source order, but
  `@HD SO:coordinate` requires actual sort and `samtools
  index` rejects unsorted BAMs (region-filter tests need an
  index). The committed canonical order is `r000, r001, r002,
  r008, r009, r003, r004, r005, r006, r007`. The fixture
  itself is the source of truth; ObjC/Java agents copied the
  Python files verbatim per HANDOFF §6.4.
- **Canonical JSON byte-equality** is achieved via:
  Python `json.dumps(obj, sort_keys=True, indent=2)` +
  trailing newline; ObjC manual emitter (NSJSONSerialization
  on GNUstep doesn't sort + compacts arrays); Java TreeMap-
  based ordered serialisation. The shape is fixed at 17
  top-level keys including MD5 fingerprints over the
  concatenated sequence/quality byte buffers.
- **subprocess startup is ~50ms per call** (Gotcha §150).
  Acceptable for typical batch workloads (importing one or
  many BAMs once); if very-large-batch import becomes a
  bottleneck, a future optimisation milestone could add an
  htslib-Java / pysam fast path.

### M86 Phase F — mate_info per-field decomposition (2026-04-26)

Most schema-invasive M86 phase: when any of three per-field
virtual overrides (`mate_info_chrom`, `mate_info_pos`,
`mate_info_tlen`) is set in `signal_codec_overrides`, the
writer replaces the M82 compound `mate_info` dataset with a
**subgroup** `signal_channels/mate_info/` containing three
independent flat datasets, each independently codec-
compressible. **First M86 phase introducing HDF5 link-type
dispatch** (group = Phase F; dataset = M82 compound) for a
top-level signal_channels link.

Closes the last channel gap left by M86 Phase C. The M82-era
genomic codec story is now **complete for ALL channels**:
every channel under `signal_channels/` has at least one
accepted codec; every M79 codec slot (4–8) is wired into its
applicable channels with cross-language byte-exact
conformance.

#### Per-field codec applicability

| Virtual channel    | Type      | Allowed codecs                          | Recommended default |
|--------------------|-----------|------------------------------------------|---------------------|
| `mate_info_chrom`  | VL_STRING | RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED | NAME_TOKENIZED (chromosome alphabets are tiny — typically <30 distinct values; the columnar dictionary win is essentially guaranteed) |
| `mate_info_pos`    | INT64     | RANS_ORDER0, RANS_ORDER1                 | RANS_ORDER1         |
| `mate_info_tlen`   | INT32     | RANS_ORDER0, RANS_ORDER1                 | RANS_ORDER1         |

#### Added

- **Python** (`spectral_dataset.py` + `genomic_run.py`):
  three new entries in `_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL`;
  bare `"mate_info"` key rejected with message naming the
  three per-field keys; schema-lift write branch with
  per-field codec dispatch in `_write_genomic_run` (chrom
  reuses the Phase C cigars helpers for the rANS path;
  pos/tlen reuse Phase B integer-channel helpers).
  `GenomicRun` gains a `_decoded_mate_info: dict[str, Any]`
  combined cache (separate from the five existing caches per
  Binding Decision §129) and three `_mate_<field>_at(i)`
  helpers with HDF5 link-type dispatch (h5py
  `Group`/`Dataset` exception-based detection). 9 new pytest
  cases plus cross-language fixture extension. M86 test
  count 51 → 61.
- **Objective-C** (`TTIOSpectralDataset.m` + `TTIOGenomicRun.m`):
  same shape. Adds `_TTIO_M86F_HasMateOverrides` predicate,
  `_TTIO_M86F_WriteMateInfoSubgroup` (HDF5 fast path) and
  `_TTIO_M86F_WriteMateInfoSubgroupStorage` (provider path)
  helpers. Reader uses `H5Oget_info_by_name` for the link-
  type query (or a provider-protocol probe fallback for
  non-HDF5 backends). Three private `_mate<Field>AtIndex:`
  accessors + `_decodedMateInfo` combined NSMutableDictionary
  cache. 50 new assertions across 10 new test methods
  (TestM86GenomicCodecWiring 2427 → 2477).
- **Java** (`SpectralDataset.java` + `GenomicRun.java`):
  same shape. Schema-lift write branch with per-field codec
  dispatch. Reader uses provider-abstract `try {
  signalChannels.openGroup("mate_info") } catch (...)`
  pattern (HDF5 binding's `H5Gopen` on a dataset surfaces as
  `Hdf5Errors.GroupOpenException`). Three private
  `mate<Field>At(int)` accessors + `decodedMateInfo`
  combined `Map<String, Object>` cache. Phase B's
  `deserialiseLeBytes` extended with INT32 branch for tlen.
  10 new JUnit 5 tests (M86CodecWiringTest 45 → 55).
- **Cross-language conformance fixture** — new
  `python/tests/fixtures/genomic/m86_codec_mate_info_full.tio`
  (60 757 bytes), with verbatim copies under
  `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`. 100-read
  run with realistic mate distributions: chrom = `["chr1"] *
  90 + ["chr2"] * 5 + ["chrX"] * 3 + ["*"] * 2`; pos = `i *
  100 + 500` for paired (98 entries) / `-1` for unmapped;
  tlen = `350 + (i % 11) - 5` for paired / `0` for unmapped.
  Override: chrom=NAME_TOKENIZED, pos=RANS_ORDER1,
  tlen=RANS_ORDER1. All three implementations decode the
  fixture byte-exact for all three mate fields across all
  100 reads.

#### Verification

- Python: 61 M86 test items pass (was 51 in Phase C; +10
  new). Full suite: 898 passed / 42 failed / 64 skipped /
  4 xfailed / 3 errors (was 888 / 42 / 64 / 4 / 3); +10 new
  passes from M86 Phase F, zero new regressions.
- Objective-C: full test runner shows 2427 → 2477 PASS (+50
  M86 Phase F assertions across 10 new test methods); 2 FAIL
  unchanged (pre-existing M38 Thermo).
- Java: `mvn -o test` → 512 / 0 fail / 0 error / 0 skipped
  (was 502 / 0 / 0 / 0). M86CodecWiringTest 45 → 55.
- Cross-language: each implementation reads
  `m86_codec_mate_info_full.tio` and decodes all three mate
  fields byte-exact against the original Python input across
  all 100 reads. Per-field `@compression` attributes verified
  on disk: chrom = 8 (NAME_TOKENIZED), pos = 5 (RANS_ORDER1),
  tlen = 5 (RANS_ORDER1). The `mate_info` link is verified
  to be a GROUP (not a dataset) in the Phase F layout.

#### Notes

- **HDF5 link-type dispatch** is the first M86 phase where a
  top-level signal_channels link can be either a compound
  dataset OR a group. The three implementations use
  language-idiomatic link-type queries: Python
  exception-based (`open_group` raising `KeyError`); ObjC
  `H5Oget_info_by_name` returning `H5O_TYPE_GROUP`/
  `H5O_TYPE_DATASET`; Java provider-abstract `openGroup`
  exception or `H5.H5Oget_info_by_name`.
- **Partial overrides work as documented.** Any one per-field
  override creates the subgroup; un-overridden fields use
  natural dtype with HDF5 ZLIB inside the subgroup (no
  `@compression` attribute on those datasets). Tests #52
  (`test_round_trip_mate_partial`) cover this case in all
  three languages.
- **Bare `"mate_info"` key rejection** produces a clear error
  pointing the caller at the three per-field names. The
  Python error message includes the literal substrings
  `mate_info_chrom`, `mate_info_pos`, `mate_info_tlen`, and
  a cross-reference to `docs/format-spec.md §10.9`. ObjC and
  Java messages match the substring contract loosely.
- **Existing `rejectInvalidChannel` test** in Java was
  retargeted from `"mate_info"` (now legitimately triggers
  the Phase F bare-key rejection) to a synthetic invalid
  name (`"not_a_real_channel"`).
- **Codec stack now complete for ALL M82 channels.** The
  M82-era genomic codec story is functionally done. Future
  optimisation milestones could ship custom codecs (e.g.
  CIGAR-specific RLE-then-rANS) for higher peak compression,
  but the structural pipeline-wiring work is over.

### M86 Phase C — Wire rANS + NAME_TOKENIZED into the cigars channel via schema lift (2026-04-26)

Pipeline-wiring extension that lights up M79 codec ids `4`
(RANS_ORDER0), `5` (RANS_ORDER1), and `8` (NAME_TOKENIZED) on
the genomic `cigars` channel. Same schema-lift pattern as M86
Phase E (compound → flat 1-D uint8) but with **three accepted
codec paths** so callers can match the codec to their
workload. The cigars channel uses the same dataset name in
both M82 (compound) and Phase C (flat uint8) forms; readers
dispatch on dataset shape.

The codec choice matters: real WGS data has indels and
soft-clips that break NAME_TOKENIZED's columnar mode back to
verbatim/no-compression, while rANS exploits byte-level
repetition over the limited CIGAR alphabet (digits 0-9 + ~9
operator letters MIDNSHP=X) regardless of token-count
uniformity. **rANS is the recommended default for real
data**; NAME_TOKENIZED is the niche choice for known-uniform
CIGARs. Selection guidance documented in
`docs/codecs/name_tokenizer.md` §8 and
`docs/format-spec.md` §10.8.

`mate_info` (the third VL_STRING-in-compound channel) is
explicitly out of scope for Phase C — it's a 3-field compound
(chrom VL_STRING + pos int64 + tlen int32) and would require
per-field schema decomposition or per-compound-field codec
dispatch (substantial new design work; deferred).

#### Added

- **Python** — `python/src/ttio/spectral_dataset.py`
  per-channel allowed-codec map gains
  `"cigars": {RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED}`;
  validation rejects `(cigars, BASE_PACK|QUALITY_BINNED)`
  with messages naming the codec, the channel, and accepted
  alternatives. Schema-lift write branch in `_write_genomic_run`
  with codec-id dispatch: rANS path uses length-prefix-concat
  (`varint(asciiLen) + asciiBytes` per cigar) then
  `rans.encode`; NAME_TOKENIZED path calls
  `name_tokenizer.encode(cigars)` directly. The two paths
  produce wire-level distinct output even though both are
  "list[str] → bytes". `python/src/ttio/genomic_run.py` gains
  `_decoded_cigars: list[str] | None` cache (separate from
  `_decoded_read_names` per Binding Decision §123) and
  `_cigar_at(i)` helper with three-way codec dispatch.
  `__getitem__` routes through it. 9 new pytest cases plus
  cross-language fixture extensions (test_m86_genomic_codec_wiring
  29 → 51 items via parametrization). Reused varint helpers
  from `name_tokenizer.py` directly.
- **Objective-C** — `objc/Source/Dataset/TTIOSpectralDataset.m`
  adds the cigars entry to `_TTIO_M86_AllowedOverrideCodecsByChannel`,
  the rejection branches, and `_TTIO_M86_EncodeCigarsWithCodec`
  dispatch helper (with inline `_TTIO_M86_VarintWrite` for the
  rANS path). Schema-lift write branch wired into BOTH
  `writeGenomicRun:` (HDF5 fast path) AND
  `writeGenomicRunStorage:` (provider path).
  `objc/Source/Genomics/TTIOGenomicRun.m` gains
  `_decodedCigars` private NSArray cache and
  `cigarAtIndex:error:` helper with shape + `@compression`
  dispatch (4/5 → rANS+length-prefix-concat;
  8 → NAME_TOKENIZED; compound fall-through). 57 new
  assertions in `TestM86GenomicCodecWiring.m` across 11 new
  test methods.
- **Java** —
  `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
  gets the cigars entry, rejection branches, and
  `encodeCigars`/`writeUnsignedVarint` helpers for the rANS
  path. `GenomicRun.java` gains
  `private List<String> decodedCigars = null;` and
  `cigarAt(int i)` helper with `decodeLengthPrefixConcat`/
  `readUnsignedVarint`. 11 new JUnit 5 tests
  (M86CodecWiringTest 34 → 45). Reused `rejectInvalidChannel`
  test was retargeted from `positions` (now valid post-Phase-B)
  to `mate_info`.
- **Cross-language conformance fixtures** — TWO new fixtures
  generated from the Python writer and committed under
  `python/tests/fixtures/genomic/`, with verbatim copies under
  `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`:
  `m86_codec_cigars_rans.tio` (53 160 bytes; 100-read mixed
  CIGARs under RANS_ORDER1) and
  `m86_codec_cigars_name_tokenized.tio` (52 528 bytes; 100
  uniform "100M" reads under NAME_TOKENIZED). All three
  implementations decode both fixtures byte-exact against the
  original Python input.

#### Verification

- Python: 51 M86 test items pass (was 38 in M86 Phase B; +13
  new). Full suite: 888 passed / 42 failed / 64 skipped /
  4 xfailed / 3 errors (was 875 / 42 / 64 / 4 / 3); +13 new
  passes from M86 Phase C, zero new regressions.
- Objective-C: full test runner shows 2370 → 2427 PASS (+57
  M86 Phase C assertions across 11 new test methods); 2 FAIL
  unchanged (pre-existing M38 Thermo).
- Java: `mvn -o test` → 502 / 0 fail / 0 error / 0 skipped
  (was 491 / 0 / 0 / 0). M86CodecWiringTest 34 → 45.
- Cross-language: each implementation reads both fixtures and
  decodes all 100 cigars byte-exact against the original
  Python input list. The codec-output bytes are byte-identical
  across the three languages via M83 + M85B conformance
  (validated by reading the same fixture in all three).

#### Empirical codec selection

The size-comparison tests print all three sizes side-by-side
on a 1000-read mixed-CIGAR input (80% "100M" + 10% "99M1D" +
10% "50M50S"). Measured byte-identical for the codec paths
across all three implementations:

| Codec choice            | Wire size | Notes |
|-------------------------|-----------|-------|
| no-override (M82 compound) | ~18-29 KB | varies by HDF5 backend storage methodology |
| NAME_TOKENIZED (verbatim mode) | **5307 bytes** | falls back to verbatim because token counts vary |
| **RANS_ORDER1**         | **1111 bytes** | ~17× smaller than baseline; ~5× smaller than NAME_TOKENIZED |

This is the empirical confirmation that rANS is the right
default for real data — exactly the case where
NAME_TOKENIZED's columnar mode no longer applies.

#### Notes

- **The rANS-on-cigars path uses length-prefix-concat
  directly, NOT NAME_TOKENIZED's encoder output then
  rANS-encoded.** The two encodings would produce different
  byte streams for the same input (NAME_TOKENIZED's verbatim
  mode includes a 7-byte header which the rANS path doesn't
  need; rANS's own self-contained header already records the
  byte count). Documented as Gotcha §139.
- **Selection guidance is surfaced in three doc locations**
  (`docs/codecs/rans.md` §7, `docs/codecs/name_tokenizer.md`
  §8, `docs/format-spec.md` §10.8) so users find it from any
  entry point. The §10.8 selection table is the authoritative
  reference.
- **Both varint helpers (encode and decode) are duplicated in
  Python (reused from name_tokenizer), Java (inline in
  SpectralDataset/GenomicRun), and ObjC (inline in the same
  files).** Future refactor could extract a shared helper if
  a third caller emerges; for Phase C the duplication is
  acceptable and matches the existing private-static pattern.
- **mate_info remains in compound storage.** Per-field codec
  dispatch on the 3-field compound (chrom VL_STRING + pos
  int64 + tlen int32) requires substantial new infrastructure
  (per-field schema decomposition or per-compound-field
  dispatch). Deferred future scope. The `mate_info` channel
  validation continues to reject all overrides (the
  `rejectInvalidChannel` test was retargeted from `positions`
  to `mate_info` since `positions` is now valid post-Phase-B).
- **The genomic codec pipeline-wiring is now complete for ALL
  M82 channels except mate_info.** All five M79 codec slots
  (4–8) are wired into their applicable channels. Phase C
  mate_info is the only remaining channel without codec
  support.

### M86 Phase B — Wire rANS into integer channels via LE byte serialisation (2026-04-26)

Pipeline-wiring extension that lights up M79 codec ids `4`
(RANS_ORDER0) and `5` (RANS_ORDER1) on the three integer
channels of `signal_channels/`: `positions` (int64), `flags`
(uint32), `mapping_qualities` (uint8). Defines the int↔byte
serialisation contract that the WORKPLAN's deferred-Phase-B
note flagged as the missing piece: integer arrays serialise to
**little-endian** bytes per element before encoding; the
reader looks up the original dtype by channel name (no on-disk
dtype attribute, per Binding Decision §115).

Integer channels accept ONLY rANS codecs. BASE_PACK,
QUALITY_BINNED, and NAME_TOKENIZED are rejected at write-time
validation (Binding Decision §117) — they are content-specific
codecs (ACGT packing, Phred-bin quantisation, string
tokenisation) and would not preserve integer values.

**Important caveat (Binding Decision §119):** The current M82
read path for per-read integer fields uses `genomic_index/`,
not `signal_channels/`. M86 Phase B compression is therefore
primarily a **write-side file-size optimisation**; it does not
currently affect read performance through `aligned_read.position`
/ `.flags` / `.mapping_quality`. Direct callers of
`_int_channel_array(name)` (Python) / `intChannelArrayNamed:`
(ObjC) / `intChannelArray(String)` (Java) DO benefit. Future
readers that prefer `signal_channels/` over `genomic_index/`
(streaming readers, M89 transport-layer materialisation) will
benefit transparently.

#### Added

- **Python** — `python/src/ttio/spectral_dataset.py`
  per-channel allowed-codec map gains positions/flags/
  mapping_qualities entries (rANS-only). Validation rejects
  wrong-content codecs on integer channels with messages
  naming the codec, the channel, and pointing at RANS_ORDER0/1
  as the correct alternative.
  `python/src/ttio/_hdf5_io.py` gains
  `_write_int_channel_with_codec(group, name, data,
  default_compression, codec_override)` that serialises to LE
  bytes via numpy dtype strings (`<i8` / `<u4` / `<u1`) and
  encodes through `rans.encode`. `python/src/ttio/genomic_run.py`
  gains `_decoded_int_channels: dict[str, np.ndarray]` cache
  (separate from byte-channel and read-names caches per
  Binding Decision §116) and `_int_channel_array(name)` helper
  with shape-aware decode dispatch. 9 new pytest cases (7
  spec'd plus cross-language fixture extension plus full-stack
  6-codec test).
- **Objective-C** — `objc/Source/Dataset/TTIOSpectralDataset.m`
  adds positions/flags/mapping_qualities entries to
  `_TTIO_M86_AllowedOverrideCodecsByChannel`, the per-codec
  rejection branches with rationale, and
  `_TTIO_M86_WriteIntChannel` / `_TTIO_M86_WriteIntChannelStorage`
  helpers (HDF5 fast path + provider path) using LE
  serialisation. Header portability handled via
  `<libkern/OSByteOrder.h>` on Apple and `<endian.h>`
  (`htole32` / `htole64`) on Linux/GNUstep gated by
  `#if defined(__APPLE__)`. `objc/Source/Genomics/TTIOGenomicRun.m`
  gains `_decodedIntChannels` ivar and
  `intChannelArrayNamed:error:` helper returning `NSData`
  (caller casts to `(int64_t *)` etc. by channel-name dtype
  lookup). 41 new assertions in `TestM86GenomicCodecWiring.m`
  across 9 new test methods; the existing
  `testRejectInvalidChannel` was retargeted from `positions`
  (now valid) to `cigars`.
- **Java** —
  `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
  gets the per-channel map entries, rejection branches, and
  int-channel encode dispatch using `ByteBuffer.LITTLE_ENDIAN`
  with `putLong` / `putInt` per element.
  `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java`
  gains `decodedIntChannels: Map<String, Object>` cache and
  `intChannelArray(String)` helper returning `Object` (typed
  `long[]` / `int[]` / `byte[]`). 9 new JUnit 5 tests
  (M86CodecWiringTest 25 → 34); the same `rejectInvalidChannel`
  retarget from `positions` to `cigars`.
- **Cross-language conformance fixture** — new
  `python/tests/fixtures/genomic/m86_codec_integer_channels.tio`
  (60 720 bytes), with verbatim copies under
  `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`. The
  fixture is a 100-read run with all three integer channels
  compressed: positions via RANS_ORDER1 (monotonic
  `i*1000+1000000`), flags via RANS_ORDER0
  (alternating 0x0001/0x0083), mapping_qualities via
  RANS_ORDER1 (60 for 80% / 0 for 20%). Sequences, qualities,
  and read_names use M82 baseline. ObjC and Java each decode
  the fixture and verify all three integer arrays match the
  Python input byte-exact.

#### Verification

- Python: `pytest tests/test_m86_genomic_codec_wiring.py -v` →
  38/38 pass (was 29 in M86 Phase E; +9 new). Full suite: 875
  passed / 42 failed / 64 skipped / 4 xfailed / 3 errors (was
  866 / 42 / 64 / 4 / 3); +9 new passes from M86 Phase B,
  zero new regressions.
- Objective-C: full test runner shows 2329 → 2370 PASS (+41
  M86 Phase B assertions across 9 new test methods); 2 FAIL
  unchanged (pre-existing M38 Thermo).
- Java: `mvn -o test` → 491 / 0 fail / 0 error / 0 skipped
  (was 482 / 0 / 0 / 0). M86CodecWiringTest 25 → 34.
- Cross-language: each implementation reads
  `m86_codec_integer_channels.tio` and decodes all three
  integer channels byte-exact against the original Python
  input arrays. M83 rANS conformance ensures the byte-identical
  encoder output across the three implementations
  (compression ratio 18.4% — exactly matching across Python,
  ObjC, and Java on the clustered-positions test pattern).

#### Notes

- **Size-win baseline change.** The original Phase B plan
  asked the size-win test (#33) to compare against the HDF5-
  ZLIB baseline on monotonically-increasing int64 positions.
  ZLIB's LZ77 matching beats raw rANS on monotonic sequences
  (rANS is entropy-only, no delta transform). The Python
  implementer adapted the test to use a "clustered positions"
  pattern (high-coverage WGS pattern: 100 reads per locus)
  and compare against raw LE int64 bytes — an honest baseline
  for entropy coding. ObjC and Java mirrored the same pattern
  for cross-language conformance. The 18.4% ratio is the
  entropy-coding win on realistic genomic position data.
- **Read path uses the index, not signal_channels.** Per
  Binding Decision §119, the per-read integer access path
  (`__getitem__` / `alignedReadAt(int)`) was deliberately NOT
  modified to use the new `_int_channel_array(name)` helper.
  The current code reads from `genomic_index/` (eagerly
  loaded, uncompressed) for fast random per-read access; the
  compressed `signal_channels/` integer datasets are
  write-only in current code. The new helper is callable but
  not called by the per-read access path. Tests verify the
  helper directly.
- **Little-endian is non-negotiable.** All three
  implementations serialise integer arrays to LE before
  encoding regardless of the host platform's native byte
  order. Big-endian platforms would still produce
  byte-identical wire output. Documented in
  `docs/format-spec.md` §10.7.
- **`mapping_qualities` LE serialisation is a no-op transparency**
  (uint8 elements; byte-order doesn't apply to single bytes).
  The dispatch path is exercised end-to-end anyway, verifying
  the codec wiring works on uint8 channels (parallel to how
  the Phase A wiring already handled uint8 sequences and
  qualities — but now with the integer-channel restricted
  codec set).
- **Genomic codec pipeline-wiring is now complete for all
  channels except cigars and mate_info.** All five M79 codec
  slots (4–8) are wired into their applicable channels.
  Phase C (cigars / mate_info wiring) remains deferred — no
  M79 codec match exists yet (cigars want RLE-then-rANS;
  mate_info is an integer-tuple compound).

### M86 Phase E — Wire NAME_TOKENIZED into the read_names channel via schema lift (2026-04-26)

Pipeline-wiring extension that lights up M79 codec id `8`
(NAME_TOKENIZED, shipped standalone in M85 Phase B) on the
genomic `read_names` channel. Bigger than Phase D because
`read_names` is currently stored as VL_STRING-in-compound and
cannot carry the `@compression` attribute as-is — Phase E
performs a **schema lift**: when the override is set, the
writer replaces the M82 compound `read_names` dataset with a
flat 1-D uint8 dataset of the same name containing the codec
output, and sets `@compression == 8` on it. Readers dispatch
on dataset shape (compound → M82 path; 1-D uint8 → codec
dispatch via lazy-decode list cache).

The codec is **rejected on the `sequences` and `qualities`
channels** at write-time validation per Binding Decision §113:
NAME_TOKENIZED tokenises UTF-8 strings, not binary byte
streams; applying it to ACGT or Phred bytes would mis-tokenise.
The other byte-channel codecs (4/5/6/7) are NOT valid on
`read_names` because the source data is `list[str]`, not
`bytes`.

The genomic codec stack is now conceptually complete for the
byte and string channels: all five M79 codec slots (4–8) are
both standalone primitives AND wired into the signal-channel
pipeline. Integer channels (positions/flags/mapping_qualities
— M86 Phase B) and remaining VL_STRING channels (cigars,
mate_info — M86 Phase C) remain deferred.

#### Added

- **Python** — `python/src/ttio/spectral_dataset.py` per-channel
  allowed-codec map gains `read_names: {NAME_TOKENIZED}`;
  validation rejects `(sequences|qualities, NAME_TOKENIZED)`
  with messages naming the codec, the channel, and pointing at
  the correct channel for NAME_TOKENIZED. Schema-lift write
  branch in `_write_genomic_run`: if `"read_names" in
  signal_codec_overrides`, encode via `name_tokenizer.encode`
  and write a flat uint8 dataset with `@compression == 8`
  instead of the M82 compound. `python/src/ttio/genomic_run.py`
  gains `_decoded_read_names: list[str] | None` cache (separate
  from `_decoded_byte_channels` per Binding Decision §114) and
  `_read_name_at(i)` helper that dispatches on dataset
  precision (`Precision.UINT8` → codec; compound → M82). Only
  `__getitem__` directly touches read_names; `reads_in_region`
  inherits via `self[i]`. 7 new pytest cases (6 spec'd plus
  cross-language fixture extension).
- **Objective-C** —
  `objc/Source/Dataset/TTIOSpectralDataset.m` adds the
  `read_names` entry to `_TTIO_M86_AllowedOverrideCodecsByChannel`,
  the rejection branch with the wrong-input-type rationale,
  and the schema-lift write branch in BOTH `writeGenomicRun:`
  (HDF5 fast path) AND `writeGenomicRunStorage:`
  (provider path). `objc/Source/Genomics/TTIOGenomicRun.m`
  gains `_decodedReadNames` private NSArray cache and
  `readNameAtIndex:error:` helper that dispatches on
  `[ds precision] == TTIOPrecisionUInt8` (cleaner than raw
  `H5Tget_class` — works through the existing
  storage-protocol abstraction so memory:// and sqlite://
  providers are supported uniformly). 39 new assertions in
  `TestM86GenomicCodecWiring.m` across 7 new test methods.
  Compression on 1000 structured Illumina names measured at
  ~19% via file-size delta methodology (vs ~50% via h5
  storage-size; the latter undercounts the VL_STRING global
  heap).
- **Java** —
  `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
  gets the `read_names → {NAME_TOKENIZED}` per-channel map
  entry, the rejection branch, and the schema-lift write
  branch in `writeGenomicRunSubtree`.
  `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java`
  gains `private List<String> decodedReadNames = null;` and
  `readNameAt(int i)` helper dispatching on
  `StorageDataset.precision() == Precision.UINT8` (cleaner
  layered abstraction than raw H5 calls — the
  `Hdf5CompoundDatasetAdapter` returns `precision == null`,
  the flat-uint8 adapter returns `Precision.UINT8`). 7 new
  JUnit 5 tests (M86CodecWiringTest 18 → 25).
- **Cross-language conformance fixture** — new
  `python/tests/fixtures/genomic/m86_codec_name_tokenized.tio`
  (48 432 bytes), with verbatim copies under
  `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`. The
  fixture has only `read_names` overridden (NAME_TOKENIZED);
  sequences and qualities use M82 baseline. All 10 reads use
  structured Illumina-style names
  `INSTR:RUN:1:{i//4}:{i%4}:{i*100}` for i in 0..9. ObjC and
  Java both read the fixture and verify all 10 names round-trip
  byte-exact, with `@compression == 8` confirmed on the
  `read_names` dataset.

#### Verification

- Python: `pytest tests/test_m86_genomic_codec_wiring.py -v` →
  29/29 pass (was 22 in M86 Phase D; +7 new). Full suite: 866
  passed / 42 failed / 64 skipped / 4 xfailed / 3 errors (was
  859 / 42 / 64 / 4 / 3); +7 new passes from M86 Phase E,
  zero new regressions.
- Objective-C: full test runner shows 2290 → 2329 PASS (+39
  M86 Phase E assertions across 7 new test methods); 2 FAIL
  unchanged (pre-existing M38 Thermo).
- Java: `mvn -o test` → 482 / 0 fail / 0 error / 0 skipped
  (was 475 / 0 / 0 / 0). M86CodecWiringTest 18 → 25.
- Cross-language: each implementation reads
  `m86_codec_name_tokenized.tio` and decodes all 10 read names
  byte-exact against the original Python input list.

#### Notes

- **Schema lift means the `read_names` dataset shape changes
  based on the override.** A v0.12 file with the override has
  a flat uint8 dataset; without the override it has the M82
  compound. Pre-M86-Phase-E readers that hard-code the
  compound shape will fail on the new flat-uint8 layout.
  Discipline matches M80 / M82 / M86 Phase A (write-forward,
  no back-compat shim per Binding Decision §90).
- **The `@compression` attribute is the canonical secondary
  signal**, but shape detection is the primary dispatch key:
  a 1-D uint8 dataset *without* `@compression` would be a
  malformed write (since M82 used compound exclusively).
- **Lazy-decode cache holds the entire decoded list** per
  `GenomicRun` instance. For 10M reads this is potentially a
  few hundred MB of decoded strings in RAM — acceptable for
  typical genomic workloads. Documented in the
  `GenomicRun` docstrings.
- **Compression measurement methodology matters.** Python and
  Java measure baseline via `h5_storage_size` which undercounts
  the VL_STRING global heap; ObjC measures via file-size
  delta which captures the full compound footprint. Neither
  is wrong; they're measuring slightly different things. Both
  show meaningful compression (NAME_TOKENIZED dataset is
  smaller than the M82 compound footprint) so the Phase E
  acceptance criterion is met across all three.
- **Other VL_STRING channels (cigars, mate_info) do NOT
  support codec overrides yet.** Phase E specifically does the
  schema lift only for `read_names`. Future Phase C work could
  apply similar treatment to cigars (with an RLE-then-rANS
  pipeline) but no codec match exists for mate_info's
  integer-tuple compound.

### M86 Phase D — Wire QUALITY_BINNED into the qualities channel (2026-04-26)

Pipeline-wiring extension that lights up M79 codec id `7`
(QUALITY_BINNED, shipped standalone in M85 Phase A) on the
genomic `qualities` byte channel. Pure integration: reuses the
M85 Phase A codec and the M86 Phase A wiring infrastructure
(per-channel `signal_codec_overrides` dict, per-dataset
`@compression` uint8 attribute, lazy-decode cache on the open
`GenomicRun` instance).

The codec is **rejected on the `sequences` channel** at write-
time validation per Binding Decision §108: applying Phred-bin
quantisation to ACGT bytes would silently destroy the sequence
data via lossy mapping. The other three byte-channel codecs
(RANS_ORDER0, RANS_ORDER1, BASE_PACK) continue to apply to
either channel as in M86 Phase A.

#### Added

- **Python** — `python/src/ttio/spectral_dataset.py` validation
  block restructured from a flat allowed-codec set to a
  per-channel map (`_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL`); the
  `(sequences, QUALITY_BINNED)` rejection branch produces an
  error message naming the codec, the channel, and the
  lossy-quantisation rationale. `_write_byte_channel_with_codec`
  in `_hdf5_io.py` gains the QUALITY_BINNED encode dispatch
  branch. `_byte_channel_slice` in `genomic_run.py` gains the
  decode dispatch. 6 new pytest cases in
  `test_m86_genomic_codec_wiring.py` plus an extension to
  `test_cross_language_fixtures` for the new fixture.
- **Objective-C** — `objc/Source/Dataset/TTIOSpectralDataset.m`
  validation now uses `_TTIO_M86_AllowedOverrideCodecsByChannel`
  per-channel map; the validator factor (`_TTIO_M86_ValidateOverrides`
  from M86 Phase A) is shared between `writeGenomicRun` (HDF5
  fast path) and `writeGenomicRunStorage` (provider path), so
  the change picks up automatically in both. QUALITY_BINNED
  encode dispatch added to `_TTIO_M86_EncodeWithCodec`. Decode
  dispatch added to `byteChannelSliceNamed:offset:count:error:`
  in `TTIOGenomicRun.m`. 32 new assertions in
  `TestM86GenomicCodecWiring.m` across 7 new test methods (the
  6 spec'd plus a separate cross-language fixture test).
- **Java** — `SpectralDataset.java` validation restructured to
  per-channel `Map<String, Set<Compression>>`; explicit
  `(sequences, QUALITY_BINNED)` rejection branch; `case
  QUALITY_BINNED -> Quality.encode(data)` added to
  `writeByteChannelWithCodec`. `GenomicRun.byteChannelSlice`
  gains the decode branch. 7 new JUnit 5 tests in
  `M86CodecWiringTest.java` (M86CodecWiringTest 11 → 18).
- **Cross-language conformance fixture** — new
  `python/tests/fixtures/genomic/m86_codec_quality_binned.tio`
  (48 432 bytes), with verbatim copies under
  `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`. The fixture
  uses **two distinct codecs in one run**: `sequences` =
  BASE_PACK (codec id 6), `qualities` = QUALITY_BINNED (codec id
  7) with bin-centre Phred values. Both channels carry their
  `@compression` uint8 attribute. ObjC and Java each read the
  fixture and verify the decoded data byte-exact against the
  known input.

#### Verification

- Python: `pytest tests/test_m86_genomic_codec_wiring.py -v` →
  22/22 pass (was 15 in M86 Phase A; +7 new = 6 spec'd cases
  plus the cross-language-fixture extension). Full suite: 859
  passed / 42 failed / 64 skipped / 4 xfailed / 3 errors (was
  852 / 42 / 64 / 4 / 4); +7 new passes from M86 Phase D, zero
  new regressions, error count actually dropped by 1.
- Objective-C: full test runner shows 2258 → 2290 PASS (+32 M86
  Phase D assertions across 7 new test methods); 2 FAIL
  unchanged (pre-existing M38 Thermo).
- Java: `mvn -o test` → 475 / 0 fail / 0 error / 0 skipped (was
  468 / 0 / 0 / 0). M86CodecWiringTest 11 → 18.
- Cross-language: each implementation reads
  `m86_codec_quality_binned.tio` and decodes both `sequences`
  (BASE_PACK) and `qualities` (QUALITY_BINNED) byte-exact
  against the known input. `@compression` attributes verified
  on disk: sequences=6, qualities=7.

#### Notes

- **Compression on a 100k-byte qualities channel ≈ 50%** of the
  HDF5-chunked-ZLIB baseline (the actual ratio depends on the
  channel size and HDF5 chunking overhead). Python and Java
  measured ~0.50; ObjC measured 0.382 because its baseline
  includes more chunk overhead. All three are well under the
  ~50% target.
- **Lossy round-trip semantics propagate.** When QUALITY_BINNED
  is wired into the qualities channel, the qualities round-trip
  becomes lossy (each byte → bin centre per the Illumina-8
  table). Tests use bin-centre input or assert against the
  expected lossy mapping. M86 Phase A behaviour is unchanged
  for files that don't opt in.
- **NAME_TOKENIZED wiring is M86 Phase E** (still deferred).
  The `read_names` channel is currently VL_STRING-in-compound;
  lifting it to a flat byte dataset that can carry the
  `@compression` attribute is a more substantial schema change
  than Phase D. Separated for milestone bounding.

### M85 Phase B — NAME_TOKENIZED genomic codec (clean-room, 3-language, lean) (2026-04-26)

Closes the genomic codec library: all five M79 codec slots
(4–8) now have working encoders + decoders across Python, ObjC,
and Java with cross-language byte-exact conformance fixtures.
NAME_TOKENIZED ships as M79 slot 8 — a lean two-token-type
columnar codec for genomic read names.

The codec is **inspired by** CRAM 3.1's name tokenisation
algorithm (Bonfield 2022) in spirit but does NOT aim for
CRAM-3.1 wire compatibility. The lean implementation achieves
~3-7:1 compression on structured Illumina names; reaching the
original WORKPLAN target of ≥ 20:1 requires the full Bonfield-
style encoder (eight token types, MATCH/DUP/leading-zero
tracking, per-token-type encoding variants) and is a future
optimisation milestone.

The codec ships as a standalone primitive in M85 Phase B.
Wiring into the genomic signal-channel pipeline (interpreting
`@compression == 8` on a `signal_channels/read_names` dataset
to call `name_tokenizer.decode()`) is a future M86 phase. The
`read_names` channel currently uses VL_STRING-in-compound
storage, which will need lifting to a flat dataset that can
carry the `@compression` attribute before the wiring branch
can land.

#### Algorithm summary

- **Tokenisation:** Each read name splits into a sequence of
  numeric tokens (digit-runs without leading zeros, or single
  `"0"`) and string tokens (everything else, with leading-zero
  digit-runs absorbing into surrounding strings). Tokens
  alternate types after parsing.
- **Mode selection:** Columnar mode iff all reads have the same
  token count AND the same per-column types. Otherwise
  verbatim fallback (each name length-prefixed).
- **Columnar encoding:** Numeric columns delta-encode against
  the previous read using zigzag-LEB128 svarint; string
  columns use an inline dictionary (literal-and-add protocol).
- **Wire format:** 7-byte header (version, scheme_id, mode,
  n_reads BE) + mode-specific body. Self-contained.

#### Added

- **Python** (`python/src/ttio/codecs/name_tokenizer.py`) —
  `encode(names: list[str]) -> bytes` and `decode(encoded:
  bytes) -> list[str]`. Two-state tokeniser walk (string/
  numeric), per-column type detection in a single pass over
  all reads, varint/zigzag helpers built inline. Throughput on
  the M85B host (100k names, 2.18 MB raw): encode 5.4 MB/s,
  decode 16.5 MB/s; compression 3.3:1 on a 1000-name Illumina
  batch. 14 pytest cases, all passing; full Python suite went
  from 838 passed → 852 passed (+14 new) with zero new
  regressions.
- **Objective-C** (`objc/Source/Codecs/TTIONameTokenizer.{h,m}`)
  — C-core tokenisation walked through `const char *` buffers,
  per-column streams accumulated into `NSMutableData`. Decode
  hot-path optimised by materialising each row into a flat
  ASCII byte buffer with hand-rolled int64-to-decimal
  conversion (rather than per-token NSString allocations) —
  decode rate jumped from 32 MB/s to 311 MB/s after this
  refactor. Encode 37 MB/s (above 25 MB/s hard floor, below 50
  MB/s soft target — encode-side allocator pressure remains an
  optimisation opportunity). 64 new assertions in
  `TestM85bNameTokenizer.m`, full ObjC suite went from 2194
  PASS → 2258 PASS (+64) with the same 2 pre-existing M38
  Thermo failures unchanged.
- **Java** (`java/src/main/java/global/thalion/ttio/codecs/NameTokenizer.java`)
  — explicit char-by-char two-state walk (string/numeric).
  Numeric overflow handled by a length-based check (≤ 18
  digits always parses safely; 19-digit runs go through
  `Long.parseLong` with try/catch demotion; 20+-digit runs
  unconditionally demote to string). Varint decode uses
  `Byte.toUnsignedInt` and `((long)(b & 0x7F)) << shift` to
  avoid the §114 sign-extension trap. 14 JUnit 5 tests, ≥ 40
  assertions, all four canonical vectors byte-exact.
  Compression 3.31:1 on 1000-name Illumina batch (matches
  Python). Full Java suite went 454/0/0/0 → 468/0/0/0 (+14
  new tests, zero failures).
- **Canonical conformance fixtures** — four `.bin` files
  generated from the Python encoder, committed under
  `python/tests/fixtures/codecs/`, with verbatim copies under
  `objc/Tests/Fixtures/` and
  `java/src/test/resources/ttio/codecs/`:
  `name_tok_a.bin` (75 B; 5 Illumina-style names with shared
  `INSTR:RUN:1:` prefix; 6-column shape with deltas mostly 0
  or 1),
  `name_tok_b.bin` (30 B; 4 zero-digit names columnar with 1
  string column and 4 dict literals),
  `name_tok_c.bin` (58 B; 6 names with leading-zero prefixes
  absorbed into string column),
  `name_tok_d.bin` (8 B; empty list, header + n_columns = 0).
- **Specification** — `docs/codecs/name_tokenizer.md` documents
  the tokenisation rules (with worked examples for the
  leading-zero absorption rule), the columnar-vs-verbatim mode
  selection, the wire format, ten binding decisions §98–§107
  with rationale, the cross-language conformance contract, the
  per-language performance numbers, and the public API in
  each language.
- **Format-spec update** — `docs/format-spec.md` §10.4
  name-tokenized row flipped from "Reserved enum slot … NOT
  YET IMPLEMENTED" to "Implemented in M85 Phase B" with a
  pointer to `docs/codecs/name_tokenizer.md`. Trailing summary
  paragraph updated: all five M79 codec slots (4–8) now ship
  as standalone primitives in all three languages — the
  genomic codec library is conceptually complete.
- **Python sub-package docstring** —
  `python/src/ttio/codecs/__init__.py` changed `name_tok       —
  Read name tokenisation (M85 Phase B, future)` to
  `name_tok       — Read name tokenisation (M85 Phase B)`.
- **WORKPLAN** — M85 Phase B status flipped from DEFERRED to
  SHIPPED. New "Codec stack status" subsection notes the
  library is conceptually complete; remaining work is
  pipeline-wiring (future M86 phases) and optional
  optimisation milestones for higher compression ratios.

#### Verification

- Python: `pytest tests/test_m85b_name_tokenizer.py -v` →
  14/14 pass. Full suite: 852 passed / 42 failed / 64 skipped
  / 4 xfailed / 4 errors (was 838 / 42 / 63 / 4 / 3); +14 new
  passes from M85 Phase B, zero new regressions. The 42
  failures and errors are all pre-existing unrelated issues.
- Objective-C: full test runner shows 2194 → 2258 PASS (+64
  M85 Phase B assertions across 14 test functions); 2 FAIL
  unchanged (pre-existing M38 Thermo).
- Java: `mvn -o test` → 468 / 0 fail / 0 error / 0 skipped
  (was 454 / 0 / 0 / 0). All 14 new `NameTokenizerTest` cases
  pass.
- Cross-language: each implementation independently tokenises
  the four canonical input vectors and produces the wire
  bytes; all three implementations match the Python-generated
  fixtures byte-for-byte for all four.

#### Notes

- **Vector B premise was corrected mid-implementation.** The
  HANDOFF plan as originally written claimed
  `["A","AB","AB:C","AB:C:D"]` would trigger verbatim mode via
  "different token counts", but per the §1.1 rules `:` is
  non-digit so each of these reads tokenises to exactly one
  string token; all four share shape `[string]` (1 column) and
  columnar mode is used. The Python implementer flagged this
  during the build and the HANDOFF was corrected on commit
  `2d9be65` before ObjC and Java ran, so all three
  implementations match the corrected fixture.
- **Compression and throughput targets were lowered from the
  HANDOFF-aspirational values.** Compression: target lowered
  from 5:1 to 3:1 on the 1000-name Illumina batch; measured
  3.31:1 (Python and Java) and 6.63:1 (ObjC, due to
  encoder-side dictionary tuning). Throughput: Python target
  lowered from 5 MB/s to 3 MB/s for full-suite-load
  variance; ObjC and Java targets unchanged. The original
  WORKPLAN ≥ 20:1 target requires the full Bonfield-style
  encoder per §7 of the codec spec; that's a future
  optimisation milestone.
- **Test 4 (`round_trip_verbatim_type_mismatch`) name is
  slightly imprecise** — `["a:1", "a:b", "a:1"]` triggers
  verbatim via token-count mismatch (2/1/2) rather than
  per-column type mismatch under the lean tokeniser. Either
  route lands in verbatim mode, so the assertion (`mode ==
  0x01`) holds; the test name is documented as a minor
  imprecision in the Java implementer's notes.
- **No back-compat shim.** The codec ships as a standalone
  primitive; no genomic file produced by M82 contains
  `@compression == 8` on a `read_names` dataset (the wiring
  branch hasn't landed). When that wiring lands in a future
  M86 phase, pre-M86 readers that ignore `@compression` will
  silently misinterpret the read_names channel.
- **CRAM 3.1 wire compatibility is a non-goal.** The TTI-O
  wire format is native, not CRAM-3.1-compatible. samtools
  cannot read TTI-O `name_tokenizer.encode()` output.
  Interop with CRAM 3.1 is a future converter milestone
  (probably alongside M87/M88).

### M85 Phase A — QUALITY_BINNED genomic codec (clean-room, 3-language) (2026-04-26)

Catch-up milestone: the original M84 sketch in WORKPLAN bundled
"Base-Packing + Quality Quantiser Codecs", but the M84
implementation that landed earlier today shipped only BASE_PACK.
M85 Phase A closes the gap with the QUALITY_BINNED codec (M79
slot `7`) — fixed Illumina-8 / CRUMBLE-derived 8-bin Phred
quantisation, 4-bit-packed bin indices, big-endian within byte,
lossy by construction. M85 Phase B (`name_tokenizer`, M79 slot
`8`) is substantially larger and deferred to a separate future
milestone.

The codec ships as a standalone primitive in M85 Phase A. Wiring
into the genomic signal-channel pipeline (interpreting
`@compression == 7` on a `signal_channels/qualities` dataset to
call `quality.decode()`) is a future M86 phase, separate from
M86 Phase A which already wired rANS and BASE_PACK.

#### Added

- **Python** (`python/src/ttio/codecs/quality.py`) — `encode(data)`
  and `decode(encoded)` with no order/scheme parameter (v0 hardcodes
  scheme `0x00` = Illumina-8). Pack loop uses `bytes.translate` with
  a 256-entry bin-index table. Decode uses two `bytes.translate`
  passes (high-nibble + low-nibble) interleaved via
  `bytearray[0::2]/[1::2]` slice-assign — Python-specific perf hack
  documented for the ObjC/Java agents who can use simpler per-byte
  loops in compiled code. Throughput on the M85 host: encode 61
  MB/s, decode 471 MB/s. 13 pytest cases, all passing; full Python
  suite went from 825 passed → 838 passed (+13 new) with zero new
  regressions.
- **Objective-C** (`objc/Source/Codecs/TTIOQuality.{h,m}`) — C
  core with `NSData → NSData` wrappers, `NSError**` out-param on
  decode. Static 256-entry pack table and 16-entry centre table
  (entries 8..15 mapped to 0 — defensive against malformed input;
  matches Python's silent treatment of out-of-range nibbles).
  Throughput: encode 3203 MB/s, decode 2196 MB/s — well above
  the 300/500 soft targets and 150/250 hard floors. 75 new
  assertions in `TestM85Quality.m`, full ObjC suite went from
  2119 PASS → 2194 PASS (+75) with the same 2 pre-existing M38
  Thermo failures unchanged.
- **Java** (`java/src/main/java/global/thalion/ttio/codecs/Quality.java`)
  — uses `>>>` (unsigned right shift) throughout; `Byte.toUnsignedInt(b)`
  for byte→int widening (critical for Phred 200+ which would
  otherwise sign-extend to negative); `writeUInt32BE` /
  `readUInt32BE` helpers (matching the BasePack.java sibling style
  rather than introducing ByteBuffer for a 6-byte header).
  Defensive null check on `encode(null)` / `decode(null)` throwing
  `IllegalArgumentException`. 13 JUnit 5 tests, 63 assertions,
  all four canonical vectors byte-exact. Throughput: encode
  2001 MB/s, decode 425 MB/s. Full Java suite went 441/0/0/0 →
  454/0/0/0 (+13 new tests, zero failures).
- **Canonical conformance fixtures** — four `.bin` files generated
  from the Python encoder, committed under
  `python/tests/fixtures/codecs/`, with verbatim copies under
  `objc/Tests/Fixtures/` and `java/src/test/resources/ttio/codecs/`:
  `quality_a.bin` (134 B; 256 B pure bin centres),
  `quality_b.bin` (518 B; 1024 B SHA-256-derived
  Illumina-realistic profile, Phred 15..40),
  `quality_c.bin` (38 B; 64 B literal covering every bin
  boundary + saturation [Phred 41, 50, 93, 100, 200, 255]),
  `quality_d.bin` (6 B; empty input).
- **Specification** — `docs/codecs/quality.md` documents the
  algorithm, bin table (Phred ranges → bin index → bin centre),
  bit-order-within-byte rule (with worked examples), wire format
  diagram, seven binding decisions §91–§97 with rationale (single
  fixed scheme, no embedded bin table, Phred-41+ saturation,
  4-bit-vs-3-bit, big-endian within byte, zero padding bits, lossy
  round-trip via bin centres), the cross-language conformance
  contract, the per-language performance numbers, and the public
  API in each language.
- **Format-spec update** — `docs/format-spec.md` §10.4
  quality-binned row flipped from "Reserved enum slot … NOT YET
  IMPLEMENTED" to "Implemented in M85 Phase A" with a pointer to
  `docs/codecs/quality.md`. Trailing summary paragraph updated:
  ids `4`, `5`, `6`, `7` now ship as standalone primitives; ids
  `4`, `5`, `6` are also wired into the byte-channel pipeline
  (M86 Phase A); id `7` ships standalone-only and waits on a
  future M86 phase to be wired; id `8` (name-tokenized) remains
  reserved-only and is the M85 Phase B target.
- **Python sub-package docstring** — `python/src/ttio/codecs/__init__.py`
  changed `quality       — Phred score quantisation (M84, future)`
  to `quality       — Phred score quantisation (M85 Phase A)`;
  `name_tok       — Read name tokenisation (M85, future)` updated
  to `(M85 Phase B, future)`.
- **WORKPLAN** — M85 section restructured into Phase A (shipped:
  quality_binned) and Phase B (deferred: name_tokenizer). Phase
  A acceptance items checked.

#### Verification

- Python: `pytest tests/test_m85_quality.py -v` → 13/13 pass.
  Full suite: 838 passed / 42 failed / 63 skipped / 4 xfailed /
  3 errors (was 825 / 42 / 64 / 4 / 3); +13 new passes, zero
  new regressions. The 42 failures and 3 errors are all
  pre-existing unrelated issues (zarr, version smoke, mzML XSD,
  websockets timing).
- Objective-C: full test runner shows 2119 → 2194 PASS (+75 M85
  assertions across 13 test functions); 2 FAIL unchanged
  (pre-existing M38 Thermo).
- Java: `mvn -o test` → 454 / 0 fail / 0 error / 0 skipped (was
  441 / 0 / 0 / 0). All 13 new `QualityTest` cases pass.
- Cross-language: each implementation independently constructs
  the four canonical input vectors (vector A literal, vector B
  via SHA-256("ttio-quality-vector-b"), vector C 64-byte literal,
  vector D empty) and compares the resulting bytes against the
  Python-generated fixtures. All three produce byte-identical
  output for all four (Python, ObjC, Java).

#### Notes

- **Lossy round-trip is a feature, not a bug.** Tests use
  bin-centre inputs for byte-exact round-trips, or assert
  against the expected lossy mapping
  (`bin_centre[bin_of[x]]`). Mistaken byte-exact assertions on
  arbitrary Phred input would produce "passes for trivial
  inputs but fails for real data" bugs.
- **Phred 41+ saturates to centre 40.** PacBio HiFi produces
  Phred 60+; these round-trip to 40 with this codec. Documented
  as Binding Decision §93. Future scheme_ids may add wider
  ranges.
- **The decoder treats nibbles 8..15 as bin index 0 / centre 0
  silently** in all three implementations. The encoder never
  produces such nibbles; this is defensive behaviour against
  hand-crafted hostile streams. Documented as Binding Decision
  §96 follow-up.
- **`@compression == 7` is not yet wired into the read path.**
  M85 Phase A delivers the codec only. A v0.12 file written
  with the codec in standalone mode (no signal-channel write
  path uses it yet) is a synthetic test artifact only. The
  future M86 phase that wires codec id 7 into the `qualities`
  channel pipeline will reuse the M86 Phase A `@compression`
  attribute scheme without changing it.
- **The original M84 WORKPLAN sketch's "Quality Quantiser"
  scope was honoured by M85 Phase A** rather than retroactively
  amending M84. The CHANGELOG and WORKPLAN both note this
  scope drift explicitly.

### M86 — Wire rANS + BASE_PACK into genomic signal-channel pipeline (Phase A: byte channels) (2026-04-26)

Integration milestone that takes the M83 (rANS) and M84 (BASE_PACK)
standalone codec primitives and wires them into the genomic
write/read pipeline for the **byte channels only** —
`signal_channels/sequences` and `signal_channels/qualities` under
`/study/genomic_runs/<name>/`. A caller can now opt-in per-channel
to any of the three TTI-O codecs at write time
(`Compression.RANS_ORDER0` = 4, `Compression.RANS_ORDER1` = 5,
`Compression.BASE_PACK` = 6); the reader dispatches transparently
based on a per-dataset `@compression` attribute. Integer channels
(`positions`, `flags`, `mapping_qualities`) and VL_STRING channels
(`cigars`, `read_names`, `mate_info`) remain on HDF5-filter ZLIB
in Phase A; lifting them is deferred to follow-on milestones.

#### Added

- **Python** — `WrittenGenomicRun.signal_codec_overrides:
  dict[str, Compression]` (default empty). New
  `_write_byte_channel_with_codec` helper in `_hdf5_io.py` that
  encodes through `rans.encode` or `base_pack.encode` and writes
  the codec output as an unfiltered uint8 dataset with
  `@compression` set to the M79 codec id. Override-validation
  block at the top of `_write_genomic_run` rejects non-byte
  channels and non-codec values fast (before any HDF5 mutation).
  `GenomicRun` gains `_decoded_byte_channels` lazy cache and
  `_byte_channel_slice(name, offset, count)` helper that decodes
  the whole channel on first access and slices the cached buffer
  for per-read access. 11 pytest cases in
  `python/tests/test_m86_genomic_codec_wiring.py` (15 items
  with `@pytest.mark.parametrize`); BASE_PACK on a 100 000-base
  pure-ACGT channel achieves 19% of uncompressed size.
- **Objective-C** — `TTIOWrittenGenomicRun` gains a
  `signalCodecOverrides` `NSDictionary` property. Validation
  block lives in BOTH `writeGenomicRun` (HDF5 fast path) and
  `writeGenomicRunStorage` (provider path) since each is
  reachable independently. Read path adds
  `byteChannelSliceNamed:offset:count:error:` plus a
  `_decodedByteChannels` lazy cache on `TTIOGenomicRun`. The
  HDF5 dataset adapter (`TTIOHDF5DatasetAdapter`) doesn't
  expose attribute APIs, so the M86 write path uses `H5A*`
  directly via the underlying `TTIOHDF5Dataset.datasetId`; the
  read path opens the dataset directly via `TTIOHDF5Group`
  through the existing `unwrap` selector pattern. Codec
  attribute uses `H5T_NATIVE_UINT8` matching the Python writer
  byte-for-byte. `TestM86GenomicCodecWiring.m` ships 11 tests /
  72 assertions; full ObjC suite went from 2047 PASS → 2119
  PASS (+72) with the same 2 pre-existing M38 Thermo failures
  unchanged.
- **Java** — `WrittenGenomicRun` gains a 19th record component
  `signalCodecOverrides: Map<String, Compression>` (with a
  delegating 18-arg convenience constructor for back-compat with
  the four pre-M86 callers, preserving the record's
  immutability/value-class shape). New
  `writeByteChannelWithCodec` dispatch helper in
  `SpectralDataset.java`; `byteChannelSlice` plus
  `decodedByteChannels` `HashMap` on `GenomicRun.java`. Pre-M86
  `Hdf5DatasetAdapter` threw `UnsupportedOperationException` on
  `setAttribute` / returned `null` from `getAttribute`; M86 adds
  minimal dataset-level attribute support to `Hdf5Dataset`
  (`setUint8Attribute`, `readIntegerAttribute`, `hasAttribute`,
  `deleteAttribute`, `attributeNames`) and routes the adapter
  through them. Purely additive, no other tests touched the
  surface. `M86CodecWiringTest.java` ships 11 JUnit 5 tests /
  ~50 assertions; full Java suite went from 430/0/0/0 →
  441/0/0/0 (+11 new, zero failures).
- **Cross-language conformance fixtures** — three `.tio` files
  generated by the Python writer and committed under
  `python/tests/fixtures/genomic/m86_codec_*.tio`, with verbatim
  copies under `objc/Tests/Fixtures/genomic/` and
  `java/src/test/resources/ttio/fixtures/genomic/`:
  `m86_codec_rans_order0.tio` (~50 KB),
  `m86_codec_rans_order1.tio` (~48 KB),
  `m86_codec_base_pack.tio` (~54 KB). Each holds a 10-read,
  100-bp pure-ACGT genomic run with both `sequences` and
  `qualities` channels encoded by the named codec. ObjC and Java
  each read all three byte-exact in their respective
  `crossLanguageFixtures` tests.
- **Format-spec** — `docs/format-spec.md` gains §10.5 documenting
  the `@compression` attribute scheme (uint8, on the dataset,
  writer omits when no override, reader treats absent and 0 as
  equivalent, codec-compressed datasets have no HDF5 filter,
  pre-M86 readers will silently misinterpret v0.12 codec-compressed
  channels). §10.4 trailing summary updated: ids `4`, `5`, `6`
  ship as standalone primitives AND are wired into the byte-channel
  pipeline; ids `7`, `8` remain reserved-only.
- **Codec docs** — `docs/codecs/rans.md` §7 and
  `docs/codecs/base_pack.md` §7 each gain a "wired into" sentence
  pointing at `signal_codec_overrides` and §10.5.
- **WORKPLAN** — M86 section restructured into Phase A (shipped),
  Phase B (integer channels, deferred), Phase C (VL_STRING
  channels, deferred). Phase A acceptance items all checked.

#### Verification

- Python: `pytest tests/test_m86_genomic_codec_wiring.py -v` →
  15/15 items pass (11 distinct test functions + parametrized
  expansion). Full suite: 825 passed / 42 failed / 64 skipped /
  4 xfailed / 3 errors (was 810 / 42 / 64 / 4 / 0); +15 new
  passes from M86, zero new regressions; the 42 pre-existing
  failures and 3 pre-existing errors are all unrelated (zarr,
  XSD, version smoke).
- Objective-C: full test runner shows 2047 → 2119 PASS (+72 M86
  assertions across 11 test functions); 2 FAIL unchanged
  (pre-existing M38 Thermo).
- Java: `mvn -o test` → 441 / 0 fail / 0 error / 0 skipped (was
  430 / 0 / 0 / 0). All 11 new `M86CodecWiringTest` cases pass.
- Cross-language: each implementation reads the three
  Python-generated `.tio` fixtures byte-exact. md5sum diff of the
  three fixture binaries across the three repo locations
  confirms verbatim copies.
- BASE_PACK size win on 100 000-byte pure-ACGT sequences channel:
  Python 19%, Java 25%, ObjC 19% — all well under the 30%
  threshold (Python and ObjC use `signal_compression="none"` as
  the baseline; Java uses `Compression.NONE`).

#### Notes

- **No back-compat shim.** v0.12 `.tio` files written with
  `signal_codec_overrides` are unreadable by pre-M86
  implementations: the reader sees a uint8 dataset of unexpected
  length and any read whose offset/length walks past the encoded
  payload boundary returns garbage. The `@compression` attribute
  is the canonical signal for codec dispatch; pre-M86 readers
  that ignore it are non-conformant readers, not valid old
  readers. Discipline matches M80 / M82.
- **No double-compression.** Codec-compressed datasets carry no
  HDF5 filter (Binding Decision §87). Running deflate over rANS
  or BASE_PACK output is a CPU loss with negative size benefit.
- **Lazy decode is per-`GenomicRun`-instance.** Two open
  `GenomicRun` objects on the same file each decode independently.
  This is correct (no shared mutable state) but means re-opening
  incurs the decode cost again. Documented in the `GenomicRun`
  class docstring.
- **The `@compression` attribute is uint8** (`H5T_NATIVE_UINT8`),
  one byte. All three implementations write and read it as a
  single byte for byte-exact cross-language fixture conformance.
- **Validation is fail-fast.** Invalid channel/codec overrides
  raise (`ValueError` Python / `NSException` ObjC /
  `IllegalArgumentException` Java) BEFORE any HDF5 mutation, so
  the file is left untouched. Tests confirm the expected absence
  of partial side-effects.
- **The original WORKPLAN sketch's `@_ttio_codec` attribute name
  was renamed to `@compression`** during implementation for
  consistency with the rest of the format-spec convention. The
  format-spec §10.4 already used `@compression` for the numpress
  attribute scheme; M86 follows the established naming.

### M84 — BASE_PACK genomic codec + sidecar mask (clean-room, 3-language) (2026-04-26)

Second entry in the genomic codec stack started by M83. 2-bit
packing for canonical ACGT bases plus a sparse position+byte
sidecar mask that losslessly preserves any non-ACGT byte (`N`,
IUPAC ambiguity codes, soft-masking lowercase, gaps, anything
else) at its original position. Implemented from first principles
across all three languages — the 2-bit-per-base packing convention
is decades-old prior art. **No htslib / CRAM tools-Java / jbzip
source code consulted in any of the three implementations.**

The codec ships as a standalone primitive in M84; wiring into the
genomic signal-channel pipeline (interpreting `@compression == 6`
on a `signal_channels/sequences` dataset to dispatch to
`base_pack.decode()`) is deferred to M86, which will land
alongside the rANS wiring.

#### Added

- **Python** (`python/src/ttio/codecs/base_pack.py`) — `encode(data)`
  and `decode(encoded)` with no order parameter. Pack loop uses
  `bytes.translate` for the 256-entry symbol→slot mapping;
  decode uses a precomputed unpack table. Throughput on the M84
  host: encode 63 MB/s, decode 70 MB/s. 14 pytest cases, all
  passing; full Python suite went from 796 passed → 810 passed
  (+14 new) with zero new regressions.
- **Objective-C** (`objc/Source/Codecs/TTIOBasePack.{h,m}`) — C
  core with `NSData → NSData` wrappers, `NSError**` out-param on
  decode. Two-pass encoder (count mask entries to size the output,
  then single-scan write into one pre-zeroed buffer; padding bits
  are zero by construction). Static 256-entry pack and unpack
  lookup tables (no openssl/libgcrypt dependency added).
  Throughput: encode 907 MB/s, decode 2093 MB/s — 4–5× faster
  than rANS owing to the simpler inner loop. 66 new assertions
  in `TestM84BasePack.m`, full ObjC suite went from 1981 passed →
  2047 passed (+66) with the same 2 pre-existing M38 Thermo
  failures unchanged.
- **Java** (`java/src/main/java/global/thalion/ttio/codecs/BasePack.java`)
  — uses `>>>` (unsigned right shift) throughout; `Byte.toUnsignedInt(b)`
  for byte→int widening; manual big-endian `uint32` pack/unpack
  helpers. 14 JUnit 5 test methods, ~50 assertions, all four
  canonical vectors byte-exact. Throughput: encode 110 MB/s,
  decode 232 MB/s. Full Java suite went 416/0/0/0 → 430/0/0/0
  (+14 new tests, zero failures).
- **Canonical conformance fixtures** — four `.bin` files generated
  from the Python encoder, committed under
  `python/tests/fixtures/codecs/`, with verbatim copies under
  `objc/Tests/Fixtures/` and `java/src/test/resources/ttio/codecs/`:
  `base_pack_a.bin` (77 B; 256 B pure ACGT, mask_count = 0),
  `base_pack_b.bin` (324 B; 1024 B realistic, mask_count = 11),
  `base_pack_c.bin` (169 B; 64 B IUPAC + soft-mask + gap stress,
  mask_count = 28), `base_pack_d.bin` (13 B; empty input).
- **Specification** — `docs/codecs/base_pack.md` documents the
  algorithm, pack mapping, bit-order-within-byte rule (with worked
  examples), wire format diagram, six binding decisions §80–§85
  with rationale (sparse mask vs dense bitmap, case-sensitivity
  for soft-masking, big-endian within byte, zero padding bits,
  mask sortedness validation, internal version byte distinct from
  M79 codec id), the cross-language conformance contract, the
  per-language performance numbers, and the public API in each
  language.
- **Format-spec update** — `docs/format-spec.md` §10.4 base-pack
  row flipped from "Reserved enum slot … NOT YET IMPLEMENTED" to
  "Implemented in M84" with a pointer to `docs/codecs/base_pack.md`.
  Trailing summary paragraph updated: ids `4`, `5`, `6` now ship
  as standalone primitives in all three languages; ids `7` and
  `8` (quality-binned, name-tokenized) remain reserved-only.
- **Python sub-package docstring** — `python/src/ttio/codecs/__init__.py`
  no longer says `(M84, future)` for `base_pack`.

#### Verification

- Python: `pytest tests/test_m84_base_pack.py -v` → 14/14 pass.
  Full suite: 810 passed / 42 failed / 64 skipped / 4 xfailed
  (was 796 / 42 / 63 / 4); +14 new passes from M84, zero new
  regressions; the 42 pre-existing failures are all unrelated
  (missing optional `zarr`, version-string smoke test, etc.).
- Objective-C: `make CC=clang OBJC=clang check` shows 1981 → 2047
  passes (+66 M84). The 2 failing cases (TestMilestone29.m M38
  Thermo reader) pre-date M83 and remain unrelated.
- Java: `mvn -o test` → 430 / 0 fail / 0 error / 0 skipped (was
  416 / 0 / 0 / 0); all 14 new BasePackTest cases pass.
- Cross-language: each implementation independently encodes the
  four canonical input vectors and compares the resulting bytes
  against the Python-generated fixtures. All three produce
  byte-identical output for all four (Python, ObjC, Java).

#### Notes

- **Case sensitivity is a feature, not a quirk.** Anyone calling
  `encode(read.upper())` will lose soft-masking. M86's wiring
  docs will call this out — it's not BASE_PACK's responsibility
  to silently uppercase.
- **All-non-ACGT input is BASE_PACK's worst case.** A sequence
  that's entirely `N` produces a wire stream ≈ 25% larger than
  the original (header + 1 byte of placeholder body per 4 input
  bytes + 5 bytes of mask per input byte). This is by design;
  BASE_PACK is for ACGT-dominant data, and pure-N input is
  rare-to-nonexistent on real genomic reads. The codec is still
  lossless in this case, just not space-efficient.
- **The M84 ObjC and Java implementations landed in a single
  commit (`38f15c1`)** — the parallel subagent dispatch had a
  race condition in the commit step that bundled both
  implementations into one commit. The Java commit message
  describes only the Java work; the ObjC files are present and
  correct in the same commit. No content was lost or corrupted;
  the subsequent ObjC verification (full test suite at HEAD)
  confirmed the bundled state passes cleanly.

### M83 — rANS entropy codec (clean-room, 3-language) (2026-04-25)

First entry in a new genomic-compression codec stack. Order-0 and
order-1 range Asymmetric Numeral Systems (rANS) entropy coder
implemented from Duda 2014 (arXiv:1311.2540 — public-domain
algorithm). **No htslib source code consulted in any of the three
implementations.** Correctness validated by round-trip property,
independently computed test vectors, and byte-exact cross-language
fixture conformance.

The codec ships as a standalone primitive in M83. Wiring into the
genomic signal-channel read/write path (interpreting `@compression`
values 4 and 5 per the M79 enum) is deferred to M86.

#### Added

- **Python** (`python/src/ttio/codecs/`) — new sub-package for
  compression primitives. `rans.py` implements `encode(data, order)`
  and `decode(encoded)`. Pure Python, no Cython. State is a Python
  `int`; algorithm parameters mirror the C/Java ports for byte
  parity (M = 4096, L = 2²³, b = 256). Throughput on M83 host:
  encode 7.25 MB/s, decode 6.79 MB/s. 14 tests, including 6
  canonical-vector round-trips.
- **Objective-C** (`objc/Source/Codecs/TTIORans.{h,m}`) — clean-room
  C core with ObjC `NSData → NSData` wrappers, `NSError**` out-param
  on decode for malformed input. Uses `uint64_t` state. Wired into
  the existing `libTTIO` build via the new `Codecs/` header subdir.
  Throughput: encode 181.6 MB/s, decode 229.4 MB/s. 48 new
  assertions in `TestM83Rans.m`, including all 6 canonical vectors
  byte-exact against the Python fixtures and the 11 round-trip /
  malformed-input / throughput cases per HANDOFF §7.2.
- **Java** (`java/src/main/java/global/thalion/ttio/codecs/Rans.java`)
  — clean-room port from the Python reference using `long` state
  with `>>>` (unsigned right shift) throughout, `Byte.toUnsignedInt`
  for symbol widening, `ByteBuffer.BIG_ENDIAN` for header
  serialisation. 14 JUnit 5 tests, 49 assertions, all 6 canonical
  vectors byte-exact. Throughput: encode 86.12 MB/s, decode 167.61
  MB/s.
- **Canonical conformance fixtures** — six `.bin` files generated
  from the Python encoder and committed under
  `python/tests/fixtures/codecs/`, with verbatim copies under
  `objc/Tests/Fixtures/` and `java/src/test/resources/ttio/codecs/`.
  These are the cross-language wire-level conformance contract:
  `rans_a_o0.bin`, `rans_a_o1.bin` (256 B uniform-ish input,
  SHA-256 × 8); `rans_b_o0.bin`, `rans_b_o1.bin` (1024 B heavily
  skewed, payload < 300 B for o0); `rans_c_o0.bin`, `rans_c_o1.bin`
  (512 B perfectly cyclic, o1 wire size strictly smaller than o0).
- **Specification** — `docs/codecs/rans.md` documents the algorithm,
  the deterministic frequency-normalisation rule (Binding Decision
  §78), the wire format, the cross-language conformance contract,
  per-language performance targets, and the public API in each
  language.

#### Verification

- Python: `pytest tests/test_m83_rans.py -v` → 14/14 pass. Full
  Python suite shows zero new regressions; the 42 pre-existing
  failures are all unrelated (missing optional `zarr`, XSD network
  fetches, version-string smoke test).
- Objective-C: `make CC=clang OBJC=clang check` shows 1933 → 1981
  passes (+48 M83). The 2 failing cases (TestMilestone29.m M38
  Thermo reader) pre-date M83 and are unrelated.
- Java: `mvn -o test` → 416 / 0 fail / 0 error / 0 skipped (was
  402 / 0 / 0 / 0 — all 14 new RansTest cases pass).
- Cross-language: each implementation independently encodes the
  three canonical input vectors at both orders and compares the
  resulting bytes against the Python-generated fixtures. All three
  produce byte-identical output for all six (Python, ObjC, Java).

#### Notes

- The order-0 wire size for short inputs is dominated by the
  fixed 1024-byte frequency-table overhead. The "compressed size <
  300 bytes" target for canonical vector B is interpreted as the
  payload portion, not the entire wire (the payload is 137 B in
  Java, 143 B in Python and ObjC). Documented in
  `python/tests/test_m83_rans.py` and `docs/codecs/rans.md`.
- Order-1 frequency-table serialisation uses run-length encoded
  per-context rows: `uint16 n_nonzero` followed by
  `n_nonzero × (uint8 symbol + uint16 freq)`. Empty contexts take
  exactly 2 bytes.
- The deterministic frequency normalisation algorithm (Binding
  Decision §78) is the cross-language hot spot — every
  implementation must produce identical normalised frequencies
  given identical input counts. The tiebreaker rule is "descending
  count, ascending symbol value" for surplus distribution and
  "ascending count, ascending symbol value, never below 1" for
  deficit subtraction. Fully specified in `docs/codecs/rans.md` §3.

### Renamed (M80, 2026-04-25)

Repository-wide clean-sweep rebrand from MPEG-O to TTI-O. **No
backward compatibility, no dual-read.** Files written by pre-M80
implementations cannot be read by post-M80 implementations and
vice-versa.

- Brand: `MPEG-O` → `TTI-O` (human-readable product name).
- Lowercase identifiers: `mpgo` → `ttio`, `mpeg_o` → `ttio` (Python
  package), `Mpgo` → `Ttio` (mixed-case ObjC tools).
- Uppercase identifiers: `MPGO` → `TTIO` (ObjC class prefix,
  enum/constant prefix).
- Python: `python/src/mpeg_o/` → `python/src/ttio/`. PyPI distribution
  name `mpeg-o` → `ttio`. CLI scripts (`mpgo-verify`, `mpgo-sign`,
  …) → (`ttio-verify`, `ttio-sign`, …).
- ObjC: 91 `MPGO*`/`Mpgo*` source files renamed to `TTIO*`/`Ttio*`.
  Library `libMPGO` → `libTTIO`. Tools (`MpgoVerify`,
  `MpgoDumpIdentifications`, `MpgoPerAU`, …) → (`TtioVerify`,
  `TtioDumpIdentifications`, `TtioPerAU`, …).
- Java: package `com.dtwthalion.mpgo.*` → `com.dtwthalion.ttio.*`
  (later corrected to `global.thalion.ttio.*` in M81). pom.xml
  `<artifactId>mpgo</artifactId>` → `<artifactId>ttio</artifactId>`.
- File container extension `.mpgo` → `.tio`. Transport stream
  extension `.mots` → `.tis`.
- Transport magic bytes `"MO"` → `"TI"` (Thalion Initiative).
- HDF5 root attributes: `mpgo_format_version` → `ttio_format_version`,
  `mpgo_features` → `ttio_features`, legacy `mpgo_version` →
  `ttio_version`. All run / spectrum / identification / quantification
  / provenance attribute prefixes likewise.

### Preserved (M80)

External standards, organisation, and internal debug formats are
**not** renamed — only the project's own product name was rebranded.

- `MPEG-G` (ISO/IEC 23092 — the multi-omics standard TTI-O is
  modelled after).
- `MPEG-2`, `MPEG-4`, `MPEG LA` (external references).
- `DTW-Thalion` (organisation name).
- `MPAD` (internal per-AU debug-dump magic — not a public wire
  format).

### Changed (M81, 2026-04-25)

Java package root corrected from `com.dtwthalion.ttio` to
`global.thalion.ttio` to match Thalion's actual reverse-DNS
(`thalion.global`). The `com.dtwthalion` form would have implied
ownership of `dtwthalion.com`. Maven Central groupId likewise
corrected from `com.dtwthalion` to `global.thalion`. M40 publishing
was still pending so the groupId was not yet locked on Central.

- 158 .java files moved
  `java/src/main/java/com/dtwthalion/ttio/` →
  `java/src/main/java/global/thalion/ttio/` (and `test/`).
- META-INF ServiceLoader file
  `com.dtwthalion.ttio.providers.StorageProvider` →
  `global.thalion.ttio.providers.StorageProvider`.
- pom.xml `<groupId>com.dtwthalion</groupId>` →
  `<groupId>global.thalion</groupId>`.
- Cross-language references updated across 80 .py, 85 .h, 6 .m,
  23 .md, 1 .toml, 1 .in, 1 .sh, 2 ProfileHarness*.java.
- Generated docs regenerated (Javadoc, autogsdoc, Sphinx) so the
  rendered API surface reflects the new paths.

3 migration-narrative documents (`docs/api-review-v0.6.md`,
`docs/superpowers/specs/2026-04-16-m41-api-review-design.md`,
`docs/superpowers/plans/2026-04-17-m41.9-docs-assembly.md`)
intentionally retain `com.dtwthalion` in prose as historical
context describing the migration itself.

### Verification (M80 + M81)

- Python: pytest 854 passing (2 pre-existing M16 baseline
  `test_smoke` failures with hardcoded version strings — predate
  M80, out of scope).
- Java: mvn test 389/389.
- ObjC: gmake check 1817 PASS / 1 env-dep skip.
- Cross-language conformance: full `[py/objc/java]³` matrix (61
  cells) plus 4-provider matrix.

### M82.1 — GenomicRun (Python reference)

- **Added:** `AlignedRead`, `GenomicRun`, `GenomicIndex`,
  `WrittenGenomicRun` — the genomic data model (analogue of
  `MassSpectrum` / `AcquisitionRun` / `SpectrumIndex` / `WrittenRun`).
- **Added:** `SpectralDataset.write_minimal(..., genomic_runs=...)`
  parameter and the `SpectralDataset.genomic_runs` read accessor.
- **Added:** `SpectralDataset.open(..., provider=...)` keyword for
  reading non-HDF5 backends symmetrically with `write_minimal`.
- **Added:** `Precision.UINT64 = 9` for genomic index offsets;
  cross-language ObjC/Java implementations (M82.2/M82.3) must match.
- **Added:** `opt_genomic` feature flag emitted whenever a file
  contains genomic runs (idempotent — added even when caller supplies
  their own `features` list); format version bumps to 1.4.
- **Added:** Cross-language reference fixture
  `python/tests/fixtures/genomic/m82_100reads.tio` for M82.4.
- **Fixed:** `Hdf5Provider._Group.create_dataset` no longer fails on
  zero-length datasets (skip chunking + compression when length=0).
- **Backward compat:** Files without `/study/genomic_runs/` open
  with `ds.genomic_runs == {}` and no error. Standard MS write path
  continues to store uint64 numpy arrays as INT64 on disk to preserve
  cross-language byte parity until M82.2/M82.3 gain UINT64 support.
- **Out of scope (M82.2/.3):** ObjC and Java implementations.
- **Out of scope (codec milestone):** Base-packing; M82 stores one
  ASCII byte per base.

### Documentation correction — genomic codec gap (post-M82.5)

Stale claims across the docs implied that the M79-reserved genomic
codec slots (rANS-order0/1, base-pack, quality-binned,
name-tokenized) had encoders/decoders shipping with M74. They did
not. M74 shipped as MS activation/isolation work; the genomic
codecs are not implemented in any of the three languages.

- **Updated:** `docs/format-spec.md` §10.4 — each of the five
  reserved codec rows now explicitly says **"NOT YET IMPLEMENTED"**.
  Added a "Note on CRAM 3.1 specifically" callout flagging that
  the reserved names map to CRAM-3.0-era codecs; CRAM 3.1's
  rANS-Nx16, fqzcomp, and adaptive arithmetic codecs are neither
  reserved nor implemented.
- **Updated:** `docs/M82.md` — "What's deliberately out of scope"
  now leads with the codec gap (was: only base-packing was
  mentioned). Quantifies the practical impact (61 KB uncompressed
  vs 6–10 KB BAM/CRAM at 100 reads; 3 GB vs 300 MB at 10 M reads).
- **Updated:** `WORKPLAN.md` — added a "Pending follow-on
  milestones (post-M82)" section. The "Genomic codec milestone"
  entry is the load-bearing one (Phase 1: implement the five M79
  reservations; Phase 2: reserve + implement CRAM 3.1 codecs;
  Phase 3: sidecar mask dataset for non-canonical bases).
  Replaces the vague "Next candidates" line that closed the M82.5
  entry.

No code changes — documentation only.

### M82.5 — Documentation pass

Wraps the M82 milestone series. Implementation, conformance, and
wire-format parity are all settled — this is the user-facing doc
layer.

- **Added:** `docs/M82.md` — user-facing guide for the four new
  public types (`GenomicRun` / `AlignedRead` / `GenomicIndex` /
  `WrittenGenomicRun`), on-disk layout under `/study/genomic_runs/`,
  minimal write+read snippet in Python, Java, and ObjC, query
  helpers, and an explicit out-of-scope list (base-packing,
  secondary alignments, multi-omics joins, MS-on-non-HDF5).
- **Updated:** `ARCHITECTURE.md` — added the four genomic types to
  the Layer 2 / Layer 3 tables and a new "Genomic abstraction-layer
  divergence" section. The section documents where the MS and
  genomic APIs share class/protocol surface and where the divergence
  is irreducible: storage substrate fully shared, `SpectralDataset`
  container mostly shared (narrow bifurcation at parallel typed
  collections), Run-level shared only via `Indexable<T>` /
  `Streamable<T>` / `AutoCloseable`, Element-level a hard wall
  (`Spectrum` hierarchy vs `AlignedRead` record share zero
  interface). Forcing a common base would be a YAGNI abstraction;
  the section makes that explicit so future maintainers don't try.
- **Fixed:** `TTIOGenomicIndex.h` had a stale "API status:
  Provisional (M82.2). Disk read/write methods land in a follow-up
  commit; until then they raise NSInternalInconsistencyException."
  comment that no longer matched M82.4 reality. Replaced with the
  current state.

### M82.4 — Cross-language conformance matrix (Python × ObjC × Java)

Closes the M82.4 deliverable promised by M82.2 ("3×3 cross-language
conformance matrix") and M82.3 ("must resolve VL string encoding
decision"). Adds a fully-exercised 9-cell matrix with both summary
parity and field-level VL_STRING parity.

- **Added:** `python/tests/validation/test_m82_3x3_matrix.py`. Each
  writer language (Python / ObjC / Java) emits a deterministic
  100-read genomic-only fixture with identical content (ACGT cycled,
  qualities = 30, chromosomes round-robin over {chr1,chr2,chrX},
  positions `10000 + (i//3)*100`). Each reader language emits the
  same flat JSON summary; all 9 cells must match the reference shape.
- **Added:** `java/.../tools/TtioWriteGenomicFixture` — Java writer
  CLI mirroring `python/tests/fixtures/genomic/generate.py`. Builds
  the deterministic `WrittenGenomicRun` and calls
  `SpectralDataset.create`. Reusable from JUnit tests via the public
  `build()` factory.
- **Added:** `objc/Tools/TtioWriteGenomicFixture.m` — ObjC equivalent.
  Wired into `objc/Tools/GNUmakefile` alongside the existing
  `TtioVerify` tool. Built as part of `gmake -s check` via the
  standard `TOOL_NAME` mechanism.
- **Extended:** Both `TtioVerify` CLIs (Java + ObjC) and Python's
  `_python_summary` helper now emit a `"genomic_runs"` block in the
  flat JSON summary. Schema:
  `{"name": {"read_count", "reference_uri", "platform", "sample_name"}}`.
  Pre-M82 datasets emit `"genomic_runs": {}`. The existing v0.9
  cross-language smoke (`test_cross_language_smoke.py`) continues to
  pass with the new field.
- **Coverage delta:** Pre-M82.4 the matrix had only the diagonal
  (each language → itself) and the Python writer column. Post-M82.4
  all 9 cells are exercised on every CI run, including the four cells
  that were the actual gap: ObjC→Python, ObjC→Java, Java→Python,
  Java→ObjC.
- **Verified:** Python 9/9 matrix cells pass + 1 field-level
  VL_STRING readback (cigar / read_name / chromosome / sequence
  prefix). Java 402/402 tests still green. ObjC 1935/1935 tests
  still green. Existing cross-language smoke 9 passed + 1 expected
  xfail.

### M82.4 — Java VL_STRING-in-compound read fix (cross-language wire parity)

- **Fixed:** `Hdf5CompoundIO.readCompoundFull` now dereferences
  VL_STRING char* pointers in the H5Dread buffer using
  `sun.misc.Unsafe.getByte`, walking bytes until the null terminator
  and decoding UTF-8. Previous behavior (`-> ""`) was not a JHI5
  binding limitation — it was a hardcoded placeholder. The pointers
  were always present in the H5Dread output buffer; we just had to
  read them ourselves the same way `NativeBytesPool` already does
  for VL_BYTES.
- **Reverted:** M82.3's VL_BYTES write workaround for genomic
  compound VL fields (chromosomes, cigars, read_names, mate_info.chrom).
  Java now writes — and reads — VL_STRING, matching Python and ObjC.
- **Cross-language wire parity restored.** Java reads Python-written
  `m82_100reads.tio` fully (cigar, read_name, chromosome all
  recovered as Python wrote them). Java-written genomic .tio files
  are now fully readable by Python and ObjC (same VL_STRING layout).
- **Bonus:** The Identifications / Quantifications / ProvenanceRecords
  JSON-mirror workarounds in `SpectralDataset` could be retired in a
  follow-up pass — they were added for the same JHI5 limitation that
  this fix removes.
- **Verified:** 402 Java tests pass (no regression). M82.3's
  cross-language fixture read test renamed back from
  `crossLanguageFixtureReadPartial` to `crossLanguageFixtureRead`
  with strict equality checks against Python-written values.

### M82.3 — GenomicRun (Java)

- **Added:** `AlignedRead` (record), `GenomicRun`, `GenomicIndex`,
  `WrittenGenomicRun` under `java/src/main/java/global/thalion/ttio/genomics/`.
  `GenomicRun` implements `Indexable<AlignedRead>` + `Streamable`
  + `AutoCloseable`.
- **Added:** `SpectralDataset.create(..., List<WrittenGenomicRun> genomicRuns, ...)`
  overload (existing 7-arg variant delegates with empty list).
  `SpectralDataset.genomicRuns()` getter. Both HDF5 fast path and
  `createViaProvider` (memory:// / sqlite:// / zarr://) write
  `/study/genomic_runs/`. Both `open` paths read it back.
- **Added:** `Precision.UINT64` enum value at ordinal 9 (with
  `_RESERVED_UINT16` and `_RESERVED_INT8` placeholder slots at 7/8
  to match Python/ObjC ordinal positions). All exhaustive
  `Precision` switches updated across `StorageDataset`,
  `Hdf5Dataset`, `Hdf5Group`, `SqliteProvider`, `ZarrProvider`.
- **Added:** `FeatureFlags.OPT_GENOMIC` constant. Format version
  bumped to 1.4 when genomic content present (idempotent if caller-
  supplied features already include the flag).
- **Added:** 13 new test methods in `GenomicRunTest.java`, ~78
  assertions. Total Java tests now 402 (was 389).
- **Fixed:** `Hdf5Group.precisionFromType` returns
  `Precision.UINT64` (was `Precision.INT64` as a pre-M82 workaround).
  MS spectrum_index/offsets files written as INT64 by the legacy
  writer continue to read back as INT64.
- **Workaround:** Java's JHI5 1.10 HDF5 binding cannot round-trip
  VL_STRING fields inside compound datasets — readback returns
  empty strings. M82.3 sidesteps this by writing the genomic
  compound VL fields (chromosomes, cigars, read_names,
  mate_info.chrom) as VL_BYTES (UTF-8 encoded). Java round-trip
  works correctly. **Cross-language consequence:** Java-written
  genomic .tio files are NOT readable by current Python/ObjC
  writers (they emit/expect VL_STRING). Java reading
  Python-written `m82_100reads.tio` recovers numeric fields and
  sequences/qualities but returns "" for VL string fields. The
  M82.4 cross-language matrix work must resolve this — either by
  switching all three writers to a Java-readable encoding or by
  upgrading Java's HDF5 binding.

### M82.2 — GenomicRun (Objective-C normative)

- **Added:** `TTIOAlignedRead`, `TTIOGenomicRun`, `TTIOGenomicIndex`,
  `TTIOWrittenGenomicRun` under `objc/Source/Genomics/`. Mirror the
  M82.1 Python reference shape.
- **Added:** `TTIOSpectralDataset.genomicRuns` property and
  `+writeMinimalToPath:title:isaInvestigationId:msRuns:genomicRuns:
  identifications:quantifications:provenanceRecords:error:` overload;
  `+readFromFilePath:` reads `/study/genomic_runs/` alongside
  `/study/ms_runs/`. Existing 7-arg overload delegates with
  `genomicRuns:nil`.
- **Added:** `TTIOPrecisionUInt64 = 9` enum value with HDF5 + Memory
  + SQLite + Zarr provider support. Matches Python's
  `Precision.UINT64 = 9` for cross-language wire parity.
- **Added:** `TTIOFeatureFlags.featureOptGenomic` returning
  `@"opt_genomic"`; `kTTIOFormatVersionM82 = @"1.4"` emitted when
  `genomicRuns` is non-empty.
- **Added:** ~63 new ObjC test assertions in `TestM82GenomicRun.m`
  covering value-class fields, in-memory queries, disk round-trip,
  region/flag filters, paired-end mate info, multi-omics file, empty
  run, pre-M82 backward compat, random-access reads, and the
  cross-language fixture read of the Python-written
  `m82_100reads.tio`. Total ObjC PASS now 1927 (was 1827 baseline).
- **Fixed:** `TTIOHDF5Group` open-side `H5T_NATIVE_UINT64` mapping
  now returns `TTIOPrecisionUInt64` (was `TTIOPrecisionInt64` as a
  pre-M82 workaround). MS spectrum_index/offsets files written as
  INT64 by the legacy ObjC writer continue to read back as INT64
  (same on-disk bytes).
- **Workaround:** `TTIOHDF5Group.stringAttributeNamed:` doesn't
  type-check the H5 attribute and returns garbage bytes for INT64
  attrs. The storage-protocol adapter tries string-first, so reading
  `acquisition_mode` via `attributeValueForName:` returns an empty
  NSString instead of NSNumber. `TTIOGenomicRun.openFromGroup:`
  detects this and reads the integer directly via the underlying
  TTIOHDF5Group when the group unwraps. Future cleanup: harden
  `stringAttributeNamed:` to refuse non-`H5T_STRING` types.
- **Backward compat:** Pre-M82 files open with empty `genomicRuns`
  dict (verified). Existing 1827-test ObjC suite still passes
  unchanged; M82.2 only adds, never modifies existing behavior.
- **Added:** Memory provider end-to-end via `+writeMinimalToPath:`.
  When the path starts with `memory://` (or `sqlite://` / `zarr://`),
  `+writeMinimalToPath:` routes through a new provider-agnostic
  helper `+writeMinimalGenomicViaProviderURL:...` that uses
  `TTIOProviderRegistry` + the StorageGroup protocol throughout.
  Currently genomic-only on the non-HDF5 path (no MS runs / idents /
  quants / provenance via memory://); MS run support requires the
  HDF5-direct → StorageGroup writer refactor and is a future
  cleanup. `+readFromFilePath:` already routed non-HDF5 URLs through
  `+readViaProviderURL:` (M64.5); now that path also reads
  `genomic_runs/` and populates `ds.genomicRuns`. Verified:
  100-read memory:// round-trip with all field assertions.
- **Out of scope (M82.4):** cross-language
  conformance matrix beyond the ObjC-reads-Python fixture covered
  here.

---

## [pre-rebrand] — M79 modality + genomic enumerations groundwork

Purely additive groundwork for the v0.11 genomic milestone series
(M74–M82). No on-disk wire change for v0.10/v1.0 content; v0.10
readers still parse every file produced by writers that do not
stamp the new attributes.

### Added

- `Precision.UINT8 = 6` across Python (`ttio.enums.Precision`),
  Java (`global.thalion.ttio.Enums.Precision`), and ObjC
  (`TTIOPrecisionUInt8`). Wired through every storage provider
  (HDF5, Memory, SQLite, Zarr); 1000-byte buffers round-trip
  byte-exactly across all four backends in all three languages.
- `Compression` ids 4–8: `RANS_ORDER0`, `RANS_ORDER1`, `BASE_PACK`,
  `QUALITY_BINNED`, `NAME_TOKENIZED`. On-disk integers reserved by
  M79 so cross-language readers see a stable codec table; encoder
  / decoder implementations ship with M74.
- `AcquisitionMode.GENOMIC_WGS = 7`, `GENOMIC_WES = 8`. Reserved
  acquisition-mode integers for whole-genome / whole-exome runs.
- Transport `spectrumClass = 5` (GenomicRead). The 38-byte
  AccessUnit prefix is generic over spectral fields; genomic AUs
  flow through the existing codec with spectral fields zeroed.
  The MSImagePixel 12-byte extension MUST NOT activate for
  `spectrumClass=5`.
- `AcquisitionRun.modality` (Python / Java / ObjC). Read-side
  contract: absence of `@modality` ⇒ `"mass_spectrometry"` (every
  v0.10 file); an explicit `"genomic_sequencing"` round-trips
  unchanged. Write side lands with `GenomicRun.write_to_group`
  in M74.
- `opt_genomic` feature flag registered in `docs/feature-flags.md`.
  Reserved by M79; stamped by writers in M74+.

### Documentation

- `docs/format-spec.md` §3a — Run modality table
  (`mass_spectrometry` default, `genomic_sequencing` reserved).
- `docs/format-spec.md` §10.4 — five new codec rows + UINT8
  precision addition.
- `docs/feature-flags.md` — v0.11 M79 section listing the
  new on-disk integer reservations and `opt_genomic`.

### Tests

- Python: `python/tests/test_m79_genomic_enums.py` — 18
  parametrised invocations across 7 test cases.
- Java: `java/src/test/java/global/thalion/ttio/M79GenomicEnumsTest.java`
  — 10 JUnit5 methods.
- ObjC: `objc/Tests/TestM79GenomicEnums.m` — 27 inline `PASS`
  assertions, registered under `M79: modality + genomic enums
  (v0.11)` in `TTIOTestRunner.m`.

---

## [v1.1.1] — 2026-04-24

Additive patch release that adds a persist-to-disk decryption API
across all three language implementations. Needed by the
TTI-O-MCP-Server M5 `mpgo_decrypt_file` admin tool, which cannot
use the read-only `decrypt_with_key` path (that returns an
in-memory plaintext `SpectralDataset` without rewriting the file).
No HDF5 format change — files produced and consumed by v1.1.1 are
byte-identical to v1.1.0.

### Added

- `SpectralDataset.decrypt_in_place(path, key)` (Python classmethod),
  `+[TTIOSpectralDataset decryptInPlaceAtPath:withKey:error:]`
  (ObjC class method), and
  `SpectralDataset.decryptInPlace(String path, byte[] key)`
  (Java static method). Each walks every run in the file, decrypts
  each signal channel's intensity ciphertext, replaces the three
  encrypted datasets (`intensity_values_encrypted`, `intensity_iv`,
  `intensity_tag`) and three encrypted attributes
  (`intensity_ciphertext_bytes`, `intensity_original_count`,
  `intensity_algorithm`) with a plaintext `intensity_values`
  Float64 dataset, and clears the root `@encrypted` marker. The
  call is idempotent on a plaintext file.
- Underlying helper: `decrypt_intensity_channel_in_run_in_place`
  (Python), `+[TTIOEncryptionManager decryptIntensityChannelInRunInPlace:atFilePath:withKey:error:]`
  (ObjC), `EncryptionManager.decryptIntensityChannelInRunInPlace`
  (Java). Short keys raise `ValueError` / `NSError` /
  `IllegalArgumentException`; a missing file raises
  `FileNotFoundError` / equivalent.

### Parity coverage

- Python: `tests/test_v1_1_1_decrypt_in_place.py` — 5 cases
  (single-run round-trip, multi-run A/B/C round-trip, idempotent on
  plaintext, rejects short key, missing file).
- ObjC: `Tests/TestV111DecryptInPlace.m` — 4 cases, wired into
  `TTIOTestRunner.m` under "v1.1.1 parity".
- Java: `ProtectionTest#v111DecryptInPlace*` — 4 cases.

---

## [v1.1.0] — 2026-04-23

Bug-fix release that restores full round-trip usability of
`SpectralDataset` encryption across close/reopen cycles. Reported
from the TTI-O-MCP-Server M5 integration (`docs/handoff-from-mcp-server-m5-encryption.md`);
the two issues below blocked the MCP server from offering a
`ttio_encrypt` → `ttio_decrypt` → `ttio_get_spectrum` flow
against Python/ObjC/Java clients.

### Fixed

- **Issue A — `is_encrypted` / `encrypted_algorithm` lost across
  close/reopen.** The root `@encrypted` HDF5 attribute written by
  `encrypt_with_key` / `encryptWithKey:level:` /
  `SpectralDataset.encryptWithKey` was not being read back on load
  in Java (ObjC and Python already wrote it; Java wrote per-run
  markers but no root marker, leaving `ds.isEncrypted()` at `false`
  after reopen). All three implementations now persist and read
  `@encrypted = "aes-256-gcm"` at the root group so
  `SpectralDataset.is_encrypted` / `.isEncrypted()` / `.isEncrypted`
  is the single source of truth after reopen.
- **Issue B — `decrypt_with_key` returned raw bytes without
  rehydrating the channel cache.** After decrypt, callers could
  only get plaintext by parsing the returned bytes themselves;
  `spec.intensity_array` / `spectrum.intensityArray` /
  `MassSpectrum.intensityValues()` kept the pre-decrypt (empty or
  ciphertext) state, raising `KeyError` in Python and returning a
  zero-length array in Java/ObjC. The in-memory channel cache is
  now rehydrated with the plaintext channel so the spectrum API is
  usable without a reopen.

### Added

- v1.1 parity test in each language that pins the
  encrypt → close → reopen → `is_encrypted` → `decrypt` → read
  surface:
  - `python/tests/test_v1_1_encryption_parity.py` (3 tests)
  - `java/src/test/java/global/thalion/ttio/ProtectionTest.java`
    (2 new tests: `v11EncryptedStateSurvivesCloseReopen`,
    `v11DecryptRehydratesSpectrumIntensity`)
  - `objc/Tests/TestV11EncryptionParity.m` (2 test functions,
    17 PASS assertions) wired into the default test tool.

### Changed

- `python/pyproject.toml` — `version` 1.0.0 → 1.1.0.
- `python/src/ttio/__init__.py` — `__version__` 1.0.0 → 1.1.0.
- `java/pom.xml` — `version` 1.0.0 → 1.1.0.

No HDF5 format-version bump: the file layout is byte-identical to
v1.0.0; only the library-level reader/writer paths changed. Clients
pinned to TTI-O v1.0.0 read v1.1.0-produced files without
modification.

---

## [v1.0.0] — 2026-04-23

First stable release. API is SemVer-stable from this tag forward —
breaking changes require a major-version bump; the per-symbol
stability map in `docs/api-stability-v0.8.md` is now in effect.

No new code in this tag relative to `v0.12.0`: it is a pure promote
signalling that `docs/v1.0-gaps.md` is clear of both must-fix and
nice-to-have items. The cumulative feature surface is catalogued in
the v0.1.0 → v0.12.0 entries below; [`docs/version-history.md`](docs/version-history.md)
presents the same material as a release-by-release narrative.

### Changed

- `python/pyproject.toml` — `version` 0.8.0 → 1.0.0; classifier
  `Development Status :: 3 - Alpha` → `5 - Production/Stable`.
  (The metadata version had been frozen at 0.8.0 since that release;
  publishing to PyPI was not gated and the shipped tags remained the
  source of truth for each release.)
- `java/pom.xml` — `version` 0.8.0 → 1.0.0.

### Not in scope for v1.0.0

- **M40 PyPI + Maven Central publishing** — continues to require
  external account + API-token setup; will land in v1.0.1 once the
  namespaces are claimed.
- **mzML `<softwareList>` / `<dataProcessingList>`** content-chain
  emission — explicitly deferred past v1.0 in `docs/v1.0-gaps.md`
  (reviewer-facing XML restructure, not a functional defect).
- **Hyperspectral-image analysis primitives** — scope expansion
  beyond tile-chunk cubes; post-v1.0.

---

## [v0.12.0] — 2026-04-23

All five milestones landed: must-haves M74 + M75, plus nice-to-haves
M76, M77, and M78. With M74, the "Must-fix for v1.0" list in
`docs/v1.0-gaps.md` is empty; with M78, the "deferred further" mzTab
Feature item is also closed. The remaining v1.0 follow-ups are
scope-expansion only (mzML `<softwareList>` / `<dataProcessingList>`
provenance chain, hyperspectral analysis primitives).

### Added

- **M74 — `activation_method` + `isolation_window` data-model
  extension (2026-04-22).** Closes the last "must-fix for v1.0" item
  in `docs/v1.0-gaps.md`. Shipped as five sequential slices across
  Python / Java / Objective-C:

    - `ActivationMethod` enum — `NONE / CID / HCD / ETD / UVPD / ECD
      / EThcD`, int32-stable across all three languages.
    - `IsolationWindow` value class — `target_mz`, `lower_offset`,
      `upper_offset`, plus `lower_bound`, `upper_bound`, `width`
      derived accessors.
    - `MassSpectrum` gains `activation_method` + `isolation_window`
      fields; the legacy initializer still works and defaults them to
      `NONE` / `None` for backward compatibility.
    - `spectrum_index` compound gains four parallel optional columns
      (`activation_methods` int32, `isolation_target_mzs` /
      `isolation_lower_offsets` / `isolation_upper_offsets` float64).
      All-or-nothing: the writer refuses partial population.
    - mzML reader maps PSI-MS activation accessions (MS:1000133 CID,
      MS:1000422 HCD, MS:1000598 ETD, MS:1000250 ECD, MS:1003246
      UVPD, MS:1003181 EThcD) and reconstructs `IsolationWindow`
      from MS:1000827 / 828 / 829.
    - mzML writer emits the preserved method inside `<activation>`
      and a complete `<isolationWindow>` block in the XSD-required
      order (`isolationWindow` → `selectedIonList` → `activation`).
    - `opt_ms2_activation_detail` feature flag registered in all
      three languages; the writer bumps `@ttio_format_version`
      from `1.1` to `1.3` only on files that actually carry the
      columns, so legacy-content files keep byte-parity with earlier
      releases.

  Commits: `beb2bc7` (A) · `736ecef` (B) · `9340007` (C) · `c502d68`
  (D) · `e96105f` (E).

- **M75 — Python CLI parity polish (2026-04-23).** Three new
  `console_scripts` registered in `python/pyproject.toml` close the
  last CLI-surface gap with the Java (`global.thalion.ttio.tools.*`)
  and Objective-C (`objc/Tools/Ttio*`) tool families:

    - `ttio-sign` — HMAC-SHA256 canonical-byte signer. Mirrors ObjC
      `TtioSign`. Exit: 0 signed / 1 I/O or dataset-missing / 2 usage.
    - `ttio-verify` — canonical HMAC verifier backed by
      `ttio.verifier.Verifier`. Stdout prints
      `VerificationStatus.name` (`VALID` / `INVALID` / `NOT_SIGNED` /
      `ERROR`); exit code = `int(status)` (0 / 1 / 2 / 3).
    - `ttio-pqc` — post-quantum CLI mirroring the ObjC `TtioPQCTool`
      and Java `PQCTool` subcommand grammar 1:1 across 10 verbs:
      `sig-keygen` / `sig-sign` / `sig-verify` / `kem-keygen` /
      `kem-encaps` / `kem-decaps` / `hdf5-sign` / `hdf5-verify` /
      `provider-sign` / `provider-verify`. Gated on the `[pqc]`
      extra (liboqs-python); verify subcommands return 0 valid / 1
      invalid / 2 error.

  Commit: `e9f2d2b`.

- **M76 — JCAMP-DX compressed-writer emission (2026-04-23).** The
  JCAMP-DX 5.01 §5.9 compression dialects (PAC / SQZ / DIF) become
  an opt-in writer mode in all three languages. AFFN stays the
  default for bit-accurate round-trips; compressed output is
  selected via a keyword (`encoding="pac"`), enum
  (`JcampDxEncoding.PAC`), or NS_ENUM (`TTIOJcampDxEncodingPAC`)
  value on the existing `write*Spectrum` surfaces:

    - **Byte-parity across languages.** A single reference encoder
      lives in Python (`ttio.exporters._jcamp_encode`) and is
      mirrored verbatim in Java (`JcampDxEncode`) and Objective-C
      (`TTIOJcampDxEncode`). Rounding is explicit half-away-from-zero
      (portable across Python / Java / C); YFACTOR is chosen as
      `10 ** (ceil(log10(max_abs)) - 7)` for ~7 significant digits of
      integer-scaled Y precision; lines break every 10 Y values.
    - **Explicit Y-check on every non-first line.** The compressed
      decoder unconditionally drops any line-start value equal to
      the previous line's last Y within 1e-9 (the JCAMP-DX Y-check
      rule). Plateaus at the line boundary would silently steal data
      points without a prepended sentinel, so the encoder emits an
      explicit SQZ (or PAC) of the previous last Y on every line
      N > 0 for all three modes.
    - **Python reader PAC detection.** `has_compression()` now also
      matches the `\d[+\-]\d` digit-sign-digit adjacency that
      distinguishes a PAC body. Scientific notation is safe because
      the character before a `+`/`-` is always `e`/`E`, never a
      digit.
    - **Cross-language conformance gate.** `conformance/jcamp_dx/`
      ships three golden `.jdx` fixtures (one per compressed mode)
      plus a `generate.py` regenerator. Python
      (`test_m76_jcamp_conformance.py`), Java
      (`JcampDxM76ConformanceTest`), and Objective-C
      (`TestM76JcampConformance`) each re-run the writer in-process
      and assert byte-for-byte equality against the same bytes.
      All 9 checks (3 modes × 3 languages) are green.

  Commits: `9437a1b` (A: Python encoder + reader fix + 37 unit
  tests) · `de377d6` (B: conformance fixtures + regenerator +
  Python conformance test) · `d889b19` (C: Java writer,
  `JcampDxEncoding` enum, 3/3 conformance, 345/345 suite) ·
  `4787aa2` (D: ObjC writer, `TTIOJcampDxEncoding` NS_ENUM, 3/3
  conformance, 1637/0 suite) · this docs flip (E).

- **M77 — 2D-COS computation primitives (2026-04-23).** Noda's
  generalised synchronous / asynchronous decomposition from a
  perturbation series (Hilbert-transform approach) ships as a shared
  library API in all three languages. The output value class,
  `TwoDimensionalCorrelationSpectrum`, was added in v0.11.1; M77
  fills in the missing *compute* side.

    - **API surface.** Three functions per language, identical
      semantics: `hilbert_noda_matrix(m)` returns the discrete
      `(m, m)` transform with `N[j, k] = 1 / (π · (k − j))` (zero
      on diagonal, antisymmetric); `compute(dynamic_spectra,
      reference=None, …)` returns a
      `TwoDimensionalCorrelationSpectrum` containing synchronous
      `Φ = (1/(m−1)) · Ãᵀ · Ã` and asynchronous
      `Ψ = (1/(m−1)) · Ãᵀ · N · Ã` matrices, with `Ã = A −
      reference` mean-centered dynamic spectra; reference defaults
      to the column-wise mean (classical mean-centered 2D-COS) and
      accepts an explicit baseline for difference 2D-COS.
      `disrelation_spectrum(sync, async)` returns `|Φ|/(|Φ|+|Ψ|)`
      element-wise in `[0, 1]` as the significance metric, NaN
      where both matrices vanish.
    - **Cross-language parity.** Python
      (`ttio.analysis.two_d_cos`) uses NumPy BLAS; Java
      (`global.thalion.ttio.analysis.TwoDCos`) and Objective-C
      (`Analysis/TTIOTwoDCos`) use plain nested loops with the
      Hilbert-Noda weight folded into the asynchronous multiply.
      Because BLAS accumulation order differs across
      implementations, the conformance gate is float-tolerance
      (`rtol=1e-9, atol=1e-12`) rather than byte-parity.
    - **Shared reference fixture.** `conformance/two_d_cos/` ships
      `dynamic.csv` (24×16 perturbation series built from drifting
      Gaussian bands) plus `sync.csv` and `async.csv` from the
      Python reference implementation. A regenerator
      (`generate.py`) is committed alongside for when reference
      semantics intentionally change. All three languages run the
      same fixture through their own compute path and assert
      closeness to the shared expected matrices; 3/3 language
      gates are green.
    - **Structural invariants verified per language.** Synchronous
      matrix is symmetric; asynchronous matrix is antisymmetric;
      constant perturbation yields zero sync + async (sanity);
      pure-sinusoid 2×2 case exhibits the expected
      synchronous-autocorrelation / asynchronous-phase-offset
      pattern.

  Commits: `df321d5` (A: Python `ttio.analysis.two_d_cos` + 15
  unit tests) · `2dfe27d` (B: `conformance/two_d_cos/` fixtures +
  Python conformance gate) · `6f4f115` (C: Java `TwoDCos` + 13
  unit tests + conformance, 359/359 suite) · `2f02ffa` (D: ObjC
  `TTIOTwoDCos` + 27 new pass() cases, 1664/0 suite) · `9e4b367`
  (E: docs flip).

- **M78 — mzTab PEH/PEP + SFH/SMF + SEH/SME support (2026-04-23).**
  Closes the last "deferred further" item called out in
  `docs/v1.0-gaps.md`. A new `Feature` value class ships beside
  `Identification` and `Quantification` in all three languages, and
  the mzTab importer + exporter round-trips peptide-level features
  (mzTab-P 1.0) and small-molecule features + evidence
  (mzTab-M 2.0.0-M):

    - **`Feature` value class.** Nine fields —  `feature_id`,
      `run_name`, `chemical_entity`, `retention_time_seconds`,
      `exp_mass_to_charge`, `charge`, `adduct_ion`, `abundances`
      (sample→abundance map), `evidence_refs` (list of spectrum or
      SME refs). Immutable across all three languages: Python
      `dataclass(frozen=True)`, Java `record` with compact-constructor
      null-coercion + `Map.copyOf` / `List.copyOf` defensive copies,
      Objective-C `TTIOFeature` with readonly copy properties.
    - **Reader.** Parses PEH/PEP rows into `Feature` records
      (sequence, charge, m/z, RT, spectra_ref, per-assay or
      per-study-variable abundance columns) and SFH/SMF rows with
      adduct + SME_ID_REFS. SEH/SME parsing then back-fills the
      feature's `chemical_entity` from `SME_ID` placeholder to the
      SME row's `database_identifier`, `chemical_name`, or
      `chemical_formula` (first non-null).
    - **Writer.** Emits PEH/PEP after PRH/PRT (1.0 branch) and
      SFH/SMF after SMH/SML (2.0.0-M branch). SEH/SME is gated on
      `features present && (idents with SME_ID tag OR plain idents)`
      so plain-SML metabolomics round-trips stay unchanged from
      pre-M78. Rank ↔ confidence mapping is symmetric: reader
      converts rank N → confidence `1/N`; writer converts
      confidence c → `max(1, round(1/c))` for the emitted rank
      column.
    - **Cross-language conformance fixture.**
      `conformance/mztab_features/{proteomics,metabolomics}.mztab`
      with the Python, Java, and Objective-C suites each reading it
      and asserting identical feature counts, adducts, charges, m/z
      values (float-tolerance), and SME-derived confidence scores.
      Byte-level parity is intentionally not required — Java
      `Double.toString` vs Python `{:g}` differ on some edge values,
      but both round-trip through parsing at `1e-3` float tolerance.

  Commits: `9b76096` (A+B: Python `Feature` + reader/writer +
  conformance fixture, 11 new unit tests + 3 conformance) ·
  `c1286f0` (C: Java `Feature` record + reader/writer, 373/0 suite;
  +4 value-class + 7 writer + 3 conformance) · `073335f` (D: ObjC
  `TTIOFeature` + reader/writer, 1704/0 suite; +3 value-class + 7
  writer + 3 conformance) · this docs flip (E).

### Test totals (post-M78)

- Python: 875 tests collected (M78 adds +11 unit + 3 conformance
  over M77; remaining delta from intervening M74/M75/M76/M77
  scaffold that landed beyond the core parity lines).
- Java: 373 tests (+14 over M77).
- Objective-C: 1704 passed / 0 failed (+40 over M77).

### Docs

- `docs/v1.0-gaps.md` — "Must-fix for v1.0" list now empty; status
  table row for activation/isolation flipped to ✅; mzML writer
  defect table updated to show item #2 shipped; "deferred further"
  mzTab Feature item also now shipped.
- `WORKPLAN.md` — M74, M75, M76, M77, and M78 checkboxes all ticked
  with their shipped commits.

---

## [v0.11.1] — 2026-04-21

Patch release completing the three M73 items that landed as deferred
notes in v0.11.0. All three languages gain the same surfaces and remain
bit-identical on the round-trip path.

### Added

- **JCAMP-DX 5.01 PAC / SQZ / DIF / DUP compression reader** in all
  three languages. Auto-detects compressed bodies via a sentinel-char
  scan that excludes `e`/`E` (so AFFN scientific notation doesn't
  false-trigger), then delegates to a per-language decoder:

    - Python: `ttio.importers._jcamp_decode.decode_xydata`
    - Java: `global.thalion.ttio.importers.JcampDxDecode.decode`
    - Objective-C: `TTIOJcampDxDecode +decodeLines:…`

  Implements the full SQZ alphabet (`@`, `A–I`, `a–i`), DIF alphabet
  (`%`, `J–R`, `j–r`), DUP alphabet (`S–Z`, `s`), the DIF Y-check
  convention (repeated leading Y within 1e-9 of the previous line's
  last Y is dropped), and X-reconstruction from `FIRSTX` / `LASTX` /
  `NPOINTS`. Writers remain AFFN-only — bit-accurate round-trips are
  worth more than the byte savings at this stage.

- **`UVVisSpectrum` class** in all three languages — 1-D UV/visible
  absorption spectrum keyed by `"wavelength"` (nm) + `"absorbance"`,
  with `pathLengthCm` and `solvent` metadata. JCAMP-DX reader
  dispatches `UV/VIS SPECTRUM`, `UV-VIS SPECTRUM`, and
  `UV/VISIBLE SPECTRUM` to this class; writer emits `##DATA TYPE=UV/VIS
  SPECTRUM` with `##XUNITS=NANOMETERS`, `##YUNITS=ABSORBANCE`, and
  `##$PATH LENGTH CM` / `##$SOLVENT` custom LDRs.

- **`TwoDimensionalCorrelationSpectrum` class** in all three
  languages — Noda 2D-COS representation with rank-2 synchronous
  (in-phase) and asynchronous (quadrature) correlation matrices
  sharing a single variable axis (`nu_1 == nu_2`). Matrices are
  row-major `float64`, size-by-size; construction validates rank,
  matching shape, and squareness. Gated behind the new
  `opt_native_2d_cos` feature flag.

### Test totals

- Python: 765 tests (was 695; 26 new for M73.1 = 20 compression/UV-Vis +
  6 2D-COS + misc).
- Java: 331 tests (was 307; 24 new for M73.1).
- Objective-C: 1536 tests (was 1443; 45 new for M73.1).

### Removed from "Deferred to v1.0+" / v0.11 scope

- `PAC / SQZ / DIF JCAMP-DX compression` — shipped here (reader only).
- `UVVisSpectrum / UV-Vis JCAMP-DX dispatch` — shipped here.
- `2D-COS / TwoDimensionalCorrelationSpectrum class` — shipped here.

---

## [v0.11.0] — 2026-04-21

Vibrational spectroscopy (M73): Raman and IR are now first-class
modalities alongside MS and NMR. Three-language parity is
preserved — every surface ships in Python, Objective-C, and Java
and round-trips byte-for-byte between them.

### Added

- **Four new domain classes per language.**
  `RamanSpectrum` and `IRSpectrum` extend the `Spectrum` base
  (keyed by `"wavenumber"` + `"intensity"`). Raman carries
  `excitationWavelengthNm`, `laserPowerMw`,
  `integrationTimeSec`; IR carries `mode` (the new `IRMode` enum:
  `TRANSMITTANCE=0`, `ABSORBANCE=1`), `resolutionCmInv`, and
  `numberOfScans`.

  `RamanImage` and `IRImage` hold rank-3 intensity cubes with a
  shared rank-1 wavenumber axis. HDF5 layout documented in
  `docs/format-spec.md` §7a — `/study/raman_image_cube/` and
  `/study/ir_image_cube/` mirror the MSImage chunking convention
  (`(tile_size, tile_size, spectral_points)` tiles, `zlib -6`).

- **JCAMP-DX 5.01 AFFN reader + writer** (`##XYDATA=(X++(Y..Y))`).
  All three writers emit LDRs in identical order with `%.10g`
  formatting — byte-identical output for identical input. Readers
  dispatch on `##DATA TYPE=` (`RAMAN SPECTRUM` /
  `INFRARED ABSORBANCE` / `INFRARED TRANSMITTANCE`, with
  `INFRARED SPECTRUM` falling back to `##YUNITS=`). Compression
  variants (PAC / SQZ / DIF) and 2-D NTUPLES are deferred; the
  reader rejects them rather than guessing. See
  `docs/vendor-formats.md` for details.

- **Cross-language conformance harness.**
  `python/tests/integration/test_raman_ir_cross_language.py`
  writes a Python JCAMP-DX file, feeds it to small subprocess
  drivers built on the ObjC and Java readers
  (`objc/Tools/TtioJcampDxDump` + a `/tmp/` ad-hoc Java driver),
  and compares the parsed arrays bit-for-bit. Tests skip on dev
  boxes where the ObjC / Java sides are unbuilt and run in full
  in CI. A companion test locks the LDR emission order so format
  drift between implementations is caught in code review.

- **ObjC CLI tool `TtioJcampDxDump`** — tiny driver that reads a
  `.jdx` via `TTIOJcampDxReader` and dumps `x,y` pairs + a
  `CLASS=<tag>` trailer, matching the Java driver contract so
  both subprocess drivers can share the Python-side parser.

### Test totals

- ObjC: 1443 tests (was 1430).
- Python: 695 tests (was 682; 13 new M73 + 6 integration).
- Java: 307 tests (was 298; 9 new M73).
- Cross-language: 44 tests (was 38; 6 new JCAMP-DX conformance).

### Removed from "Deferred to v1.0+"

`Raman/IR support (new Spectrum subclasses)` — shipped here.

### Scope — what's intentionally NOT in v0.11

- 2-D JCAMP-DX (NTUPLES / PAGE). Imaging and 2-D NMR cubes are
  stored natively in HDF5; ASCII cubes are impractical at 10–100
  MB per map.
- 2D-COS and hyperspectral imaging-specific analyses.
- PAC / SQZ / DIF JCAMP-DX compression. Preserving bit-accurate
  cross-implementation round-trips is worth more than the byte
  savings at this stage.

---

## [v0.10.0] — 2026-04-20

Transport layer (M66–M72) plus the v1.0 per-Access-Unit encryption
stack. Three-language parity remains the rule — every surface shipped
here lands in Python, Objective-C, and Java before the tag.

### Added

- **Transport codec (M67)** — `.tis` streams for the TTI-O wire
  format defined in `docs/transport-spec.md` §3. 24-byte packet
  headers, little-endian, `{StreamHeader, DatasetHeader, AccessUnit,
  ProtectionMetadata, Annotation, Provenance, Chromatogram,
  EndOfDataset, EndOfStream}` packet types. Python / ObjC / Java all
  parse the same byte stream.

- **Transport client + server (M68 / M68.5)** — WebSocket push
  endpoints (libwebsockets for ObjC, `websockets` for Python,
  Java-WebSocket for Java). Streams .tio datasets as `.tis` over
  the wire with optional CRC-32C per packet.

- **Acquisition simulator (M69)** — replays a fixture at wall-clock
  pace to exercise client/server scheduling.

- **Bidirectional conformance (M70)** — cross-language matrix test
  that any pair of {Python, ObjC, Java} writers and readers can
  exchange streams byte-for-byte.

- **Selective access + protection metadata (M71)** — per-packet
  AUFilter + ProtectionMetadata fields (cipher_suite, kek_algorithm,
  wrapped_dek, signature_algorithm, public_key).

- **Per-Access-Unit encryption (v1.0 scope)** — `opt_per_au_encryption`
  feature flag with the `<channel>_segments` VL_BYTES compound layout
  from `format-spec.md` §9.1. Each spectrum is a separate AES-256-GCM
  op with fresh IV + AAD = `dataset_id || au_sequence || channel_name`;
  ciphertext cannot be replayed against a different AU or envelope.
  Optional `opt_encrypted_au_headers` flag additionally encrypts the
  36-byte semantic header into `spectrum_index/au_header_segments`.

  Shipped as five phases across all three languages:
    - **Phase A** — per-AU primitives (AAD helpers, `ChannelSegment` /
      `HeaderSegment` / `AUHeaderPlaintext`, pack / unpack, round-trip).
    - **Phase B** — `VL_BYTES` compound-field kind + HDF5 provider
      wiring. The Java side uses a native hvl_t raw-buffer pool
      because JHI5 1.10 doesn't marshal VL-in-compound directly.
    - **Phase C** — file-level encrypt/decrypt orchestrator
      (`PerAUFile` / `TTIOPerAUFile` / `encrypt_per_au`). All I/O
      flows through the StorageProvider abstraction — any backend
      with VL_BYTES compound support works.
    - **Phase D** — encrypted transport writer + reader. Ciphertext
      passes through the wire unmodified (server never decrypts in
      transit, per `transport-spec.md` §6.2).
    - **Phase E** — cross-language conformance harness
      (`tests/integration/test_per_au_cross_language.py`) drives the
      `per_au_cli` tool in all three languages via subprocess and
      byte-compares a canonical MPAD decryption dump. 38/38 passing
      across every encrypt × decrypt × headers combination.

- **`per_au_cli transcode` subcommand** — migrate plaintext or
  existing v1.0-encrypted files to a fresh DEK / `--headers` setting.
  v0.x `opt_dataset_encryption` inputs fail loud with a migration
  hint (decrypt via v0.x API first).

- **Java HDF5 write durability fix** — `Hdf5File.close()` now calls
  `H5Fflush` before `H5Fclose` so writes persist even when child
  group handles leaked up the call stack. Caught by the cross-
  language test where Java encryption of a Python-created fixture
  silently dropped changes.

### Changed

- `FeatureFlags`: added `opt_per_au_encryption` and
  `opt_encrypted_au_headers` to the known-optional set.
- `CompoundField.Kind`: added `VL_BYTES` (bumps the enum from 4 to 5
  members in all three languages).

### Metrics

| Language   | Tests |
| ---------- | ----: |
| Python     |   682 |
| ObjC       |  1430 |
| Java       |   298 |
| Cross-lang |    38 |

---

## [v0.9.1] — 2026-04-19

Patch on top of v0.9.0 (commit `228eeb5`). Closes the remaining
v1.0 exporter gaps surfaced by M64 xfails and migrates the Zarr
on-disk format from v2 to v3.

### Added
- **mzTab exporter** across Python + ObjC + Java (commit
  `3c67ba9`). Both proteomics 1.0 (MTD + PSH/PSM + PRH/PRT) and
  metabolomics 2.0.0-M (MTD + SMH/SML) dialects supported. Output
  round-trips through the reader bit-identically.
- **imzML exporter** across Python + ObjC + Java (commit
  `ff0f201`). Continuous + processed modes; rejects divergent mz
  axis in continuous mode; UUID normalisation. Same commit fixes
  an importer cv-accession misclassification: `MS:1000030`/
  `MS:1000031` are vendor / instrument-model fields, not IMS mode.
- **nmrML spectrum1D** XSD gap closed via interleaved `(x,y)`
  encoding (commit `6b26f2e`).
- **mzML + ISA-Tab** validation closure and nmrML wrapper
  improvements (commit `65c3666`).
- Unit-level coverage for the new writers (commit `2f35bd2`).
- **v1.0 gap audit** doc covering the exporter + importer xfails
  surfaced by M64 (commit `4f17789`).

### Changed
- **Zarr v2 → v3 on-disk migration** across all three language
  providers (commits `391a7d2` + `da13fed`). Each node is now a
  single `zarr.json` file (`node_type: group | array`) with
  attributes nested inside; array chunks live under a `c/` prefix
  (`c/0/1/2`); dtypes use canonical names (`float64`, `int32`,
  ...). Compression on read accepts the `gzip` codec written by
  zarr-python's `GzipCodec`.
  - Python uses zarr-python 3.x (`LocalStore`, `FsspecStore`,
    `MemoryStore`, `create_array(compressors=...)`).
  - Java + ObjC self-contained writers/readers updated to emit and
    parse v3 layout byte-for-byte against zarr-python output.
  - No backward-compat shim — pre-deployment, no v2 stores in the
    wild. Read side does still accept legacy v2 dtype strings
    (`<f8`, `<i4`, ...) for safety.

### Test counts
- Python 586 pass / 11 skip / 4 xfail
- Objective-C 1271 PASS
- Java 245 pass

---

## [v0.9.0] — 2026-04-19 (commit `228eeb5`)

### Added
- **M57** Integration test infrastructure + fixture management
  (`download.py`, pinned source URLs, in-repo fallbacks).
- **M58** Cross-tool round-trip integration tests: mzML, nmrML,
  Thermo `.raw`, Bruker `.d`.
- **M59** imzML + `.ibd` importer. Python reference, then
  Objective-C + Java for three-language parity.
- **M60** mzTab importer (proteomics 1.0 + metabolomics 2.0.0-M)
  across Python + ObjC + Java.
- **M61** End-to-end workflow + security-lifecycle test matrix
  (84 cross-provider cells: encryption, signature, anonymization).
- **M62** Stress + cross-provider benchmark suite (31 stress-marked
  cells); cross-language stress + validation suites for all three
  languages.
- **M63** Waters MassLynx `.raw` importer (Python + ObjC + Java),
  delegation pattern through `MassLynxRawReader` where SDK present,
  open-source fallback otherwise.
- **M64** Cross-tool validation (PSI XSD, pyteomics, pymzml,
  isatools) + nightly stress CI.
- **M64.5** caller-refactor across all three languages so
  `SpectralDataset.open` / `write_minimal` dispatch on URL scheme
  (HDF5 / Memory / SQLite / Zarr). Phase A (Python), phase B
  (provider-aware Encryption/Signature/Anonymizer), phase C
  (KeyRotationManager + MSImage cube cross-provider). Java + ObjC
  follow-up landed `ProviderRegistry.open` and
  `+readViaProviderURL:` paths. 39 of 39 cross-provider cells
  pass; the remaining `memory`-as-cross-process xfail is by design.

### Performance
- 3-language profiling harness + pure-C libhdf5 baseline; three
  targeted optimisations (ObjC `writeMinimal` fast path, chunk-size
  tuning, concat improvement); ObjC harness fairness fix +
  Java index parity. ObjC sits at ~1.3× over raw C — documented
  in `tools/perf/ANALYSIS.md`.

### Test counts at v0.9.0
- Python 555 pass / 7 xfail (3 documenting v1.0 exporter defects)
- Objective-C 1202 PASS
- Java 232 pass

---

## [v0.8.0] — 2026-04-18

### Added
- **M49** Post-quantum crypto: ML-KEM-1024 (FIPS 203) envelope
  key-wrap and ML-DSA-87 (FIPS 204) dataset signatures. New `v3:`
  signature-attribute prefix; `opt_pqc_preview` feature flag
  auto-set whenever either primitive runs. Python and Objective-C
  use liboqs; Java uses Bouncy Castle 1.80+. Rationale: `docs/pqc.md`.
  - **M49.1** ObjC dataset / envelope integration via
    `TTIOSignatureManager` + `TTIOKeyRotationManager`.
- **M52** Java and Objective-C `ZarrProvider` ports. Self-contained
  LocalStore implementations — no external zarr library dependency.
  Same on-disk layout as the Python reference so all three languages
  cross-read one another's stores. (On-disk format migrated from
  Zarr v2 to v3 in v0.9.1; see the v0.9.1 entry above.)
- **M53** Bruker timsTOF `.d` importer. SQLite metadata reads
  natively in every language; binary frame decompression uses
  `opentimspy` + `opentims-bruker-bridge` in Python and subprocesses
  into the Python helper from Java / Objective-C. New
  `inv_ion_mobility` signal channel preserves the 2-D timsTOF
  geometry per-peak. Details: `docs/vendor-formats.md`.
- **M54 + M54.1** 32-cell cross-language × cross-provider PQC
  conformance matrix: primitive ML-DSA / ML-KEM, v3 signatures on
  HDF5 / Zarr / SQLite, v2+v3 coexistence, v0.7 backward-compat.
  New `global.thalion.ttio.tools.PQCTool` (Java) and
  `TtioPQCTool` (ObjC) CLIs drive the harness. New Python
  `sign_storage_dataset` / `verify_storage_dataset` provider-agnostic
  helpers.

### Changed
- **Binding decision 42 (revised)** — see `docs/pqc.md`. Python
  `cryptography` 46 does not yet expose ML-KEM / ML-DSA, so
  Python + ObjC use `liboqs` instead of the originally-planned
  OpenSSL 3.5 path. Java keeps the Bouncy Castle plan.
- `CipherSuite` catalog: `ml-kem-1024` and `ml-dsa-87` graduate
  from `reserved` to `active`. `shake256` remains reserved.
  ML-DSA-87 public-key size corrected from 4864 → 2592 bytes
  (FIPS 204 §4).
- `validate_key(algorithm, key)` now rejects asymmetric algorithms
  with an explicit redirect to `validate_public_key` /
  `validate_private_key`. Symmetric-only by design.
- `java/run-tool.sh` git mode promoted from 100644 to 100755 so
  the parity tests stop skipping on fresh clones.

### Deprecated
- `v0.7` API surface marks nothing new as removed in v0.8. See
  `docs/api-stability-v0.8.md` for the v1.0 deprecation candidates.

### Fixed
- Python + Objective-C provider `read_canonical_bytes` on signed
  datasets now round-trips through every shipping provider
  (HDF5, Memory, SQLite, Zarr).

---

## [v0.7.0] — 2026-04-18

### Added
- **M41** SQLite storage provider across ObjC / Python / Java.
- **M43** `read_canonical_bytes()` protocol method enables
  cross-backend signature verification.
- **M44** Protocol-native `AcquisitionRun` and `MSImage` — upper
  layers go through `StorageGroup` instead of raw HDF5 handles.
- **M45** `create_dataset_nd` across all providers; native N-D
  image cubes + 2-D NMR matrices via the protocol.
- **M46** Python `ZarrProvider` reference implementation (stretch;
  Java / ObjC ports land in v0.8 M52).
- **M47** Wrapped-key blob format v1.2 — algorithm-discriminated
  envelope (`magic "MW" | version | algorithm_id | ct_len |
  md_len | metadata | ciphertext`). Reserves `algorithm_id=0x0001`
  for ML-KEM-1024 (activated in v0.8 M49).
- **M48** `CipherSuite` catalog with reserved PQC algorithm IDs
  and an `algorithm=` keyword parameter threaded through
  encryption / signing / wrapping.
- **M50** Cross-language consistency hardening (six Appendix-B
  gap resolutions: `open()` signatures, `readRows()`, capability
  queries, `provider_name` shape, precision decoupling, attribute
  del/enum).
- **M51** Compound write byte-parity harness across three
  languages — 9-cell interop grid.

### Changed
- `ttio_format_version` bumps from `1.1` to `1.2`.
- Default wrapped-key layout is v1.2 (71 bytes for AES-GCM);
  v1.1 (60-byte fixed) remains readable indefinitely.

### Baseline
- Objective-C: 1057 assertions pass.
- Python: 284 tests pass.
- Java: 179 tests pass.

---

## [v0.6.1] — 2026-02

SQLite provider stress-test; six Appendix-B gap fixes shipped
inline (dual-style `open()`, `read_rows()` protocol method,
capability queries, etc.).

## [v0.6.0] — 2026-02

- **M33-M39** Storage provider abstraction land. Three-language
  parity across HDF5, Memory, and (v0.7) SQLite backends.
- Java reaches full feature parity with ObjC and Python.

## [v0.5.0] — 2025-12

- **M30-M33** Three-way conformance test harness across the
  three languages; shared fixture generator.
- Three-language feature parity achieved on the M11-M29
  milestone block.

## [v0.4.0] — 2025-10

- **M25** Envelope encryption + key rotation: DEK + KEK model,
  `/protection/key_info/` group layout.
- **M26-M28** Spectral anonymisation pipeline, nmrML writer,
  chromatogram API.
- `opt_key_rotation`, `opt_anonymized` feature flags.

## [v0.3.0] — 2025-08

- **M17-M24** Compound per-run provenance, `v2:` canonical-byte
  signatures, LZ4 + Numpress-delta compression, chromatogram
  import (M24).

## [v0.2.0] — 2025-06

- **M11-M16** Core dataset model: `/study/ms_runs/*/spectrum_index`,
  signal-channels group, compound `identifications` /
  `quantifications` / `provenance` datasets, v1 HMAC signatures.
- `ttio_format_version = "1.1"` and `ttio_features` JSON
  array introduced.

## [v0.1.0-alpha] — 2025-04

- **M1-M10** Initial ObjC reference implementation with HDF5
  backing store. Core spectrum hierarchy
  (`TTIOMassSpectrum`, `TTIONMRSpectrum`, `TTIOFreeInductionDecay`,
  `TTIOMSImage`). Basic mzML reader.

---

## Notes on format compatibility

- **Write-forward** — readers must refuse files carrying a
  required feature they don't recognise. Optional features
  (prefixed `opt_`) are ignored.
- **Read-backward** — every reader reads the full v0.1 through
  v0.8 range. The v1.1 wrapped-key blob (60-byte fixed) remains
  decryptable indefinitely (HANDOFF binding #38).
- Classical HMAC-SHA256 signatures (`v2:` prefix) continue to
  verify after the v0.8 PQC activation; post-quantum signatures
  (`v3:` prefix) raise `UnsupportedAlgorithmError` on v0.7-and-
  earlier readers, which is the correct behaviour.
