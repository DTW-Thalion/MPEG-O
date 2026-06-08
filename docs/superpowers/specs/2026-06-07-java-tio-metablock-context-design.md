# Java .tio meta-block bloat fix (#251) — Design

**Date:** 2026-06-07
**Origin:** issue #251 — `Hdf5File.create` (`java/src/main/java/global/thalion/ttio/hdf5/Hdf5File.java`)
unconditionally sets an 8MB meta-block + 2MB small-data-block on the FAPL for EVERY `.tio`,
bloating small spectral files by ~8MB of dead space (~26× for spectral data). The big block is
needed for genome-reference writes (~25k contigs → ~100k metadata ops; without it the encoder
collapses to ~17 records/s), but is pure waste for small spectral files.
**Scope:** Make the block sizes context-dependent in the Java SDK so only genomic writes get the
8MB block. Java product code. **HARD invariant: behavior-preserving — FAPL block size is purely
where bytes land in the file, NOT logical content or dataset bytes; files stay valid HDF5;
Python/ObjC reads + cross-SDK conformance unaffected. No format/wire change, no breaking
public-API change.**

## Confirmed facts (from investigation)
- `Hdf5File.create(String path)` (`:56-65`): sets `META_BLOCK_SIZE`=8MB (`:52`) +
  `SMALL_DATA_BLOCK_SIZE`=2MB (`:53`) on the FAPL unconditionally; fcpl is `H5P_DEFAULT` (`:64`).
- Sole non-test caller: `Hdf5Provider.open(path, Mode.CREATE)` (`providers/Hdf5Provider.java:61`).
- `SpectralDataset.createMixed` computes `boolean hasGenomic = genomicRuns != null &&
  !genomicRuns.isEmpty()` (`:1157`) BEFORE opening the file (`:1228`), and is the sole funnel for
  all create entry points. Genomic data is only ever written through this path.
- Encryption/transport/PerAU create sites (`EncryptedTransport.java:1026`, `PerAUFile.java:101,
  152,236,430,519`) are NEVER genomic.
- Python/ObjC set NO meta-block/small-data-block (use HDF5 2KB defaults) — so Java spectral files
  will simply match them after the fix.
- No test asserts the 8MB behaviour or an absolute file size (all `Files.size(...)` checks are
  `> 0`).

## Design (mechanism (a): context-dependent FAPL via the existing `hasGenomic` signal)
1. **`Hdf5File`:** add `create(String path, boolean largeBlocks)`. When `largeBlocks` → set the
   8MB/2MB blocks (current behaviour). Otherwise → skip both `H5Pset_*` calls (HDF5 defaults,
   matching Python/ObjC). Keep `create(String path)` delegating to `create(path, false)` — so the
   encryption/transport/PerAU sites (which call the provider that ends at the 1-arg path) get
   small blocks automatically and the bloat fix lands there for free.
2. **Plumb the hint** from `SpectralDataset.createMixed` to `Hdf5File.create`. The chain is
   `SpectralDataset` → `StorageProvider.open(path, mode)` → `Hdf5Provider.open` →
   `Hdf5File.create`. Add an overload that carries the hint:
   - `StorageProvider.open(path, mode, boolean largeBlocks)` (or a small `OpenHints`/enum) with a
     default method `open(path, mode)` → `open(path, mode, false)` so OTHER providers
     (Memory/SQLite/Zarr) need no change (they ignore it — they don't allocate HDF5 blocks).
   - `Hdf5Provider.open(path, mode, largeBlocks)` passes `largeBlocks` to `Hdf5File.create`.
   - Choose the minimal surface: an overload + default delegation, NOT a signature change to the
     existing interface method (keeps the public/SPI API non-breaking).
3. **Select at the funnel:** at `SpectralDataset.createMixed`'s HDF5 create site (`:1228`) and the
   URL-provider create site (`:666` `createViaProviderMixed`), pass `hasGenomic` (`:1157`) as the
   hint. Genomic → 8MB; pure spectral → default.

## Why behavior-preserving
`H5Pset_meta_block_size`/`H5Pset_small_data_block_size` are FAPL (file-access) allocation
strategy — they change only the file's free-space layout, never the logical objects or dataset
bytes. The file remains valid HDF5. Python/ObjC already read Java files without setting these, so
lowering Java's blocks to default for spectral makes Java behave like the other two SDKs. No
on-disk dataset bytes change; cross-SDK conformance is unaffected.

## Genomic-regression risk + tests
The one real risk is silently sending the genomic path down the small-block branch (re-introducing
the throughput collapse). Tests to add/keep:
1. **Genomic keeps large blocks:** a unit test asserting the genomic create path requests
   `largeBlocks=true`. Inject/observe the hint at the `Hdf5File.create`/`Hdf5Provider.open`
   boundary (add a minimal seam — e.g. a package-visible last-used-hint field on `Hdf5Provider`,
   or assert via a spy). Keep it small.
2. **Spectral file is small:** write a single-MS-run `.tio` and assert its size is well under 8MB
   (e.g. `< 2_000_000` bytes) — an ABSOLUTE floor/ceiling, NOT a ratio (per the HDF5-metadata-
   weight-varies lesson). This locks in the fix.
3. **Genomic round-trip stays green:** keep an existing multi-contig genomic write/read +
   cross-SDK conformance test passing (proves no correctness change).
4. Optionally a perf smoke over a synthetic many-contig reference to confirm throughput stays in
   the amortized regime (only if cheap).

## Invariants & verification
- Java product code only (`Hdf5File.java`, `Hdf5Provider.java`, `StorageProvider` interface,
  `SpectralDataset.java`) + tests. No format/wire change, no breaking API (overloads + default
  delegation).
- `cd java && JAVA_HOME=~/jdk25 mvn -q -Plinux-x64 test` (or the repo's Java test cmd) — ALL green,
  incl genomic + the new tests + JaCoCo coverage gate (≥0.84 bundle line) if enforced.
- Cross-SDK conformance green (ObjC/Python read Java-written spectral + genomic files).
- Spectral `.tio` size drops from ~8MB+ to its real (~KB–MB) size; genomic file size + write
  throughput unchanged.
- Re-baseline: Java `encryption`/`genomic` timings may shift slightly (small spectral files no
  longer carry 8MB dead space that the in-place encrypt bench was processing); re-capture Java
  baseline.

## Success criteria
Context-dependent meta-block: genomic keeps 8MB, spectral/encryption/transport get defaults;
small spectral `.tio` no longer carries ~8MB dead space; behavior-preserving (conformance + tests
green, no format change); genomic throughput unregressed; Java re-baselined. One PR.

## Out of scope
ObjC/Python (they already use defaults); the other follow-ups (Python Cython; Java
Cipher.getInstance hoist; per-SDK metric_overrides). Updates issue #251.
