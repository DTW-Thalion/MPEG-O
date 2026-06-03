# TTI-O — Object-Oriented Design Assessment (3-language stack)

**Date:** 2026-06-02
**Scope:** Cross-language OO design review of the TTI-O reference implementation across Python (`python/src/ttio/`), Java (`java/src/main/java/global/thalion/ttio/`), and Objective-C (`objc/Source/`).
**Baseline:** `main` @ `47ec1556`.
**Evaluation criteria (per request):** proper abstraction of the 3-language API; data-specific classes/methods abstracted as far as possible *without dramatic harm to performance or understanding*; performance optimization as a first-class criterion.
**Method:** four focused read-only analyses (data model, storage abstraction, pluggable subsystems, performance), each evidence-backed with `file:line` citations, then synthesized. Citations are point-in-time and should be re-verified before acting.

---

## 1. Scorecard

| Dimension | Grade | One-line |
|---|---|---|
| Data model abstraction | **C+** | Strong `Spectrum` hierarchy, undermined by stringly-typed type dispatch, un-abstracted images, god-object datasets |
| Storage abstraction | **C+** | Clean 3-tier interface that the production HDF5 backend largely bypasses |
| Codec subsystem | **D** | No codec interface in any language; 6–8 switch-ladders per language |
| Importers / Exporters | **C− / D** | Python has a registry; Java & ObjC have none |
| Transport | **B−** | Excellent Walker+Visitor (best design in repo), dragged by decode-side switch ladders + god-files |
| Abstraction cost (perf) | **B+** | Heavy work is native + amortized per-channel; leaks bounded to metadata paths |
| Performance optimization | **B+** | Native SIMD codecs, Cython, vectorized indexes, lazy I/O; a few un-accelerated gaps |
| Cross-language parity | **B− / C+** | Strong *nominal* parity; weaker *behavioral* parity |

**Overall:** A performance-conscious, nominally-consistent stack with genuinely good abstractions in two places (the `Spectrum` tree and the transport Visitor) sitting alongside three recurring anti-patterns: **switch-ladder dispatch**, **stringly-typed discriminators**, and **leaky / bypassed abstraction boundaries**.

---

## 2. Cross-cutting themes

### Theme 1 — Good base hierarchies coexist with ad-hoc parallel structures

Strengths:
- The `Spectrum` → `MassSpectrum` / `NMRSpectrum` / `RamanSpectrum` / `IRSpectrum` / `UVVisSpectrum` hierarchy is real and parity-faithful in all three languages, with a generic channel map plus typed subclass accessors (`spectrum.py:11,52`; `Spectrum.java:34`; `Spectra/TTIOSpectrum.h:37,41`).
- The transport `AccessUnitVisitor` / `TTIOTransportEventVisitor` is a textbook visitor — one method per event, default no-op bodies, documented ordering, cross-language equivalence notes (`AccessUnitVisitor.java`, `TTIODatasetWalker.h:60`). This is the strongest single piece of OO design in the codebase and is open/closed for consumers.

Weaknesses:
- **Stringly-typed spectrum dispatch.** The persisted discriminator is the literal ObjC class-name string (`"TTIOMassSpectrum"` etc.) even in Python and Java, materialized through if/string-equality ladders (`acquisition_run.py:742-764`; `AcquisitionRun.java:261,303-338`; `Run/TTIOAcquisitionRun.m:340,349,359`). The string appears across ~125 files and is redundant with the `AcquisitionMode` enum (`enums.py:146`); the two signals can disagree (Java even keeps a `spectrumClassOverride` *and* an `acquisitionMode` switch).
- **Un-abstracted images.** `MSImage` / `RamanImage` / `IRImage` share no base in any language; Java's `RamanImage` and `IRImage` are ~75% identical fields (`IRImage.java:35-51` vs `RamanImage.java:37-53`) and are surfaced as three parallel accessors (`image()`, `raman_image()`, `ir_image()`) rather than a uniform collection.
- **No codec interface.** Dispatch is integer-id switch ladders with codec bodies inlined or called as free functions (`genomic_run.py:359`; `_hdf5_io.py:646`; `GenomicRun.java:436`; `TTIOGenomicRun.m:346`), plus bespoke side-paths for the v2 codecs.

### Theme 2 — Boundaries are defined cleanly, then bypassed

- The `StorageProvider` / `StorageGroup` / `StorageDataset` contract is well-shaped and proven by a working in-memory implementation — but the production HDF5 path is reached through `_hdf5_io._unwrap_to_h5py()` (22 call sites) and a public `SpectralDataset.file: h5py.File` handle (`spectral_dataset.py:93`), so the abstraction is the *secondary* path for the backend that most needs it. Its own docstring admits new call sites should use `provider.root_group()` instead (`spectral_dataset.py:116`).
- `native_handle()` is a sanctioned escape hatch wired into mainline flows and leaks a *different concrete type per backend* (h5py file / live `sqlite3.Connection` / Zarr root dir) — the textbook leaky abstraction (`base.py:476`; `StorageProvider.java:71` `@Deprecated(forRemoval=true)`; `SqliteProvider.java:148`).
- SQLite cannot meet the declared capability floor: no array/bytes attributes (schema `value_type IN ('string','int','float')`, `sqlite.py:63-77`), and `VL_BYTES` compound fields raise `NotImplementedError` (`sqlite.py:483-489`) so per-AU encryption silently doesn't work there.

### Theme 3 — Abstraction-vs-performance is handled deliberately and well

- The expensive work (entropy coding, ref-diff, name tokenization, mate-info) is native C in all three languages, and dispatch is **amortized over whole channels via decode caches** rather than paid per record (`genomic_run.py:217-219,342-344`). This is the single most important decision keeping the OO model affordable.
- The free-function / static-method codec style is a *conscious* sacrifice of abstraction for a virtual-dispatch-free hot loop, and it is justified.
- Residual abstraction costs (provider re-lookups, boxing) are confined to metadata-sized index data, not the multi-GB signal path.

---

## 3. Cross-language parity

**Faithful (nominal/structural):** class names, the `Spectrum` inheritance tree, enum integer values, `PacketType`, the visitor method set (Java↔ObjC identical 17 methods), `ProgressSink`, the provider 3-tier shape, the default-codec name→enum table.

**Divergent (the real risks):**
- **Encapsulation philosophy differs three ways:** Python mutable dataclasses · Java immutable-with-copies (but `SignalArray.asDoubles()` returns the backing array by reference, `SignalArray.java:102-104`) · ObjC `(readonly, copy) NSData` (`Core/TTIOSignalArray.h:45`).
- **`Run` abstraction** is load-bearing in Java/ObjC (`AcquisitionRun.java:44`; `Run/TTIOAcquisitionRun.h:49`) but a "Provisional," unenforced structural Protocol in Python (`protocols/run.py:28`).
- **Importer/exporter registry exists only in Python** (`importers/registry.py:111`, `exporters/registry.py:197`); Java & ObjC have bare standalone reader/writer classes, so CLI format coverage diverges by language.
- **Hand-rolled vs library JSON:** Java parses SQLite compound JSON with a hand-written parser (`SqliteProvider.java:449-507`) vs Python `json` / ObjC `NSJSONSerialization` — the exact class of bug behind the recently-fixed whitespace incompatibility (#205).
- **Vectorization parity gap (direct follow-up to PR #202):** Java `GenomicIndex.indicesForRegion` still does a scalar per-read `chromosomes.get(i).equals(...)` loop with `Integer` autoboxing (`GenomicIndex.java:84-92`) — it never received the interned-id vectorization Python got in #202. ObjC is scalar too.

---

## 4. Performance

**Hot-path acceleration (well done):** native SIMD codec dispatch (AVX2→SSE4.1→scalar in `native/`), Cython for the two pure-algorithm Python codecs, vectorized Python index queries (`genomic_index.py:130-146`), a `bytes.translate` LUT for quality binning (`quality.py:76-141`), lazy signal channels with eager small indexes (`genomic_run.py:288-294`), whole-channel decode caching, the documented hot-loop-import fix (`genomic_run.py:24-34`), and a relative perf-regression gate (`test_compression_benchmark.py:113,124`).

**Gaps:**
1. `DELTA_RANS` is fully scalar pure-Python (`delta_rans.py:97-107,143-156`) — the slowest interpreted codec, trivially numpy-vectorizable.
2. Per-record `__getitem__` re-opens the `signal_channels` group ~10× with fresh adapter allocations and no caching (`genomic_run.py:322,395,…,739`; `hdf5.py:358-361`).
3. Java region query not vectorized (above) — cross-language perf-parity gap.
4. Python BAM import shells out to `samtools` + text-parses per line (`importers/bam.py:225-322`), structurally slower than Java's in-process htsjdk.
5. No **absolute** perf floor on the genomic decode path (gates are relative MS-codec ratios).

**Documented, justified parity-for-perf tradeoffs:** bulk-mode transport is ~2.4% larger to guarantee byte-identical cross-language output; rANS frequency normalization uses deterministic integer math (`rans.py:92-168`) for byte-exact parity. Both are reasonable and documented.

---

## 5. Prioritized recommendations

### P1 — high leverage, low/medium effort, no wire/format change
1. **Codec registry** (`{id: codec}` of objects exposing `encode/decode/is_context_aware`) replacing the per-language ladders + bespoke v2 side-paths. Largest open/closed win; ~zero runtime cost (decode is whole-channel + cached). Turns "add a codec" from ~6 edits/language into one registry entry.
2. **Vectorize Java `indicesForRegion`/`indicesForFlag`** using the interned `chromosomeIds` column, collecting into `int[]`/`IntArrayList` to avoid `Integer` boxing — finishes the parity left open by PR #202. (ObjC likewise.)
3. **Vectorize Python `DELTA_RANS`** with numpy (`np.diff`/vectorized zigzag; only varint emission stays serial).
4. **Cache the `signal_channels` group handle** on `GenomicRun` (open once, reuse).

### P2 — medium effort, mostly pure refactor
5. **Shared `Image` / `ImageCube` base** + a uniform image collection on `SpectralDataset`, removing the triplicate accessor and copy-paste fields.
6. **Lift the importer/exporter registry into Java & ObjC** behind real `Reader` / `Writer` interfaces (`read(input, ProgressSink) -> Dataset` / `write(Dataset, output)`), collapsing the Python adapter-normalization layer.
7. **Replace Java's hand-rolled JSON** with a real parser and add a cross-language compound round-trip conformance test.

### P3 — larger, needs migration or wire-proof
8. **Replace the stringly-typed `spectrum_class` discriminator** with the `AcquisitionMode` enum (or a `SpectrumKind` enum) + a single factory/registry. Requires an attribute-migration / compatibility shim; per the project's Phase-0 spec-proof rule, design first.
9. **Retire the `SpectralDataset.file` leak**; route all HDF5 IO through the protocol with a zero-copy fast-path so signature/encryption code stops needing the raw handle.
10. **Split the god-files** — `SpectralDataset` (2.8k–4.3k LOC; extract crypto + the image collection) and `transport/codec.py` (3157 LOC; separate framing / serialization / table-driven decode mirroring the clean encoder-side visitor).
11. **Encapsulation parity:** promote Python `Run` out of "Provisional," return read-only array *views* (numpy `flags.writeable=False`) rather than deep copies to preserve zero-copy, and fix Java `asDoubles()`.

---

## 6. Bottom line

For the stated goal — *abstract data-specific classes as far as possible without harming performance or understanding* — the two highest-value abstraction wins are the **codec registry (P1.1)** and the **shared `Image` base (P2.5)**: both remove genuine duplication, and the codec registry costs essentially nothing at runtime because the heavy work is native and amortized per channel. The **performance criterion is already well-served**; the residual perf items (P1.2–P1.4) are small, parity-neutral, and do not touch the wire format. The largest *latent* risk is **behavioral parity drift** (encapsulation models, Python-only registry, hand-rolled JSON, the Java vectorization gap) rather than nominal API shape, which is strong.

---

## Appendix — grading rubric

Grades are relative to a well-factored multi-language reference implementation, weighting: clarity of abstraction boundaries, open/closed-ness (cost to extend), cross-language consistency, and performance-per-unit-abstraction. `A` = exemplary; `C` = works but with notable structural debt; `D` = functionally correct but actively hostile to extension. Performance grades weight whether the *expensive* work is accelerated and whether abstraction overhead lands off the hot path.
