# ReferenceImport embed-progress parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the per-contig progress sink on the reference-embed path to parity across SDKs by adding it to Python `ReferenceImport.write_to_dataset` and ObjC `-writeToDataset:…`, matching Java's existing emission; delete the three stale Java importer TODOs; and close the ObjC BAM-reader progress test gap.

**Architecture:** Java already emits `onProgress(0, N)` then per-chromosome `onProgress(i+1, N)` (N = sorted contig count) from `ReferenceImport.writeToDataset(...)`. We mirror that exact callback sequence in Python (new keyword-only `progress` param, fired via the existing `ttio.io.progress._fire` dispatcher) and ObjC (new `…progress:…` overload, fired via the `TTIOProgressBlock`). Progress is a runtime callback only — no wire/on-disk format changes. Tests are per-language (progress is not serialized, so no byte-level cross-language harness).

**Tech Stack:** Python 3.12 + pytest + h5py; Objective-C + GNUstep (`objc/build.sh`); Java 25 + Maven (compile-only check). Build/test in WSL Ubuntu at `~/TTI-O`; push from Windows git.

**Spec:** `docs/superpowers/specs/2026-06-02-importer-progress-parity-design.md`

**Pre-req:** Work on branch `feat/reference-import-progress-parity` (already created off `main`; the spec is already committed on it).

---

## File structure

| File | Change | Responsibility |
|------|--------|----------------|
| `python/src/ttio/genomic/reference_import.py` | Modify `write_to_dataset` | Add `progress` param + per-contig emission |
| `python/tests/test_reference_import_progress.py` | Create | Python progress unit tests |
| `objc/Source/Genomics/TTIOReferenceImport.h` | Modify | Declare `…progress:…` overload; import progress header |
| `objc/Source/Genomics/TTIOReferenceImport.m` | Modify | Implement overload + per-contig emission; old overload delegates |
| `objc/Tests/TTIOReferenceImportWriteToDatasetTests.m` | Modify | ObjC `writeToDataset…progress:` test case |
| `objc/Tests/TestProgressSink.m` | Modify | ObjC BAM-reader `…progress:` test case |
| `java/.../importers/FastaReader.java` | Modify | Delete stale TODO (lines 44-47) |
| `java/.../importers/FastqReader.java` | Modify | Delete stale TODO (lines 39-43) |
| `java/.../importers/BamReader.java` | Modify | Delete stale TODO (lines 60-64) |
| `CHANGELOG.md` | Modify | `[Unreleased]` entry |

Reference for emission semantics (read-only): `java/src/main/java/global/thalion/ttio/genomics/ReferenceImport.java:300-392`.

---

## Task 1: Python — `write_to_dataset` per-contig progress

**Files:**
- Test: `python/tests/test_reference_import_progress.py` (create)
- Modify: `python/src/ttio/genomic/reference_import.py` (`write_to_dataset`, ~line 213 + loop ~line 296)

- [ ] **Step 1: Write the failing test**

Create `python/tests/test_reference_import_progress.py`:

```python
"""ProgressSink coverage for ReferenceImport.write_to_dataset.

Mirrors Java ReferenceImport.writeToDataset(..., ProgressSink): emits
(0, N) before the embed loop then (i+1, N) after each contig, ending at
(N, N). N = number of chromosomes. Progress is a runtime callback only.
"""
from __future__ import annotations

from pathlib import Path

from ttio.genomic.reference_import import ReferenceImport
from ttio.spectral_dataset import SpectralDataset


def _embed(tio_path: Path, ri: ReferenceImport, progress=None) -> None:
    SpectralDataset.write_minimal(
        tio_path, title="", isa_investigation_id="", runs={},
    )
    with SpectralDataset.open(tio_path, writable=True) as ds:
        ri.write_to_dataset(ds, progress=progress)


def _ref(n: int) -> ReferenceImport:
    names = [f"chr{i}" for i in range(n)]
    seqs = [b"ACGTACGTACGT" for _ in range(n)]
    return ReferenceImport(uri="prog-v1", chromosomes=names, sequences=seqs)


def test_progress_emits_zero_then_per_contig(tmp_path: Path) -> None:
    n = 3
    events: list[tuple[int, int]] = []
    _embed(tmp_path / "p.tio", _ref(n), progress=lambda d, t: events.append((d, t)))
    # (0,3),(1,3),(2,3),(3,3) — N+1 callbacks, total always N.
    assert events == [(0, n), (1, n), (2, n), (3, n)]


def test_progress_protocol_object_sink(tmp_path: Path) -> None:
    n = 2

    class Collector:
        def __init__(self) -> None:
            self.events: list[tuple[int, int]] = []

        def on_progress(self, done: int, total: int) -> None:
            self.events.append((done, total))

    sink = Collector()
    _embed(tmp_path / "q.tio", _ref(n), progress=sink)
    assert sink.events == [(0, n), (1, n), (2, n)]


def test_progress_none_safe(tmp_path: Path) -> None:
    # No progress arg must still embed cleanly.
    _embed(tmp_path / "r.tio", _ref(2), progress=None)
    with SpectralDataset.open(tmp_path / "r.tio") as ds:
        assert list(ds.references["prog-v1"].chromosomes) == ["chr0", "chr1"]
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/python && . .venv/bin/activate && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so python -m pytest tests/test_reference_import_progress.py -v'
```
Expected: FAIL — `write_to_dataset()` raises `TypeError: ... unexpected keyword argument 'progress'`.

- [ ] **Step 3: Add the `progress` parameter to the signature**

In `python/src/ttio/genomic/reference_import.py`, change the signature (currently ~line 213):

```python
    def write_to_dataset(
        self,
        dataset: "SpectralDataset",
        *,
        overwrite: bool = False,
        progress: "ProgressSinkLike | None" = None,
    ) -> None:
```

- [ ] **Step 4: Import the fire helper inside the method body**

In the same method, find the in-body import block:

```python
        import numpy as np

        from .. import _hdf5_io as io
        from ..enums import Compression as _Compression
        from ..enums import Precision as _Precision
        from ..providers.hdf5 import _Group as _H5Group
```

Add one line:

```python
        from ..io.progress import _fire
```

- [ ] **Step 5: Emit progress around the embed loop**

Replace the existing loop (currently):

```python
        chroms_grp = ref_grp.create_group("chromosomes")
        # Sort alphabetically so the on-disk child order matches what
        # the canonical writer emits (read_from_group surfaces names in
        # on-disk order).
        for name in sorted(self.chromosomes):
            seq = self.chromosome(name)
```

with:

```python
        chroms_grp = ref_grp.create_group("chromosomes")
        # Sort alphabetically so the on-disk child order matches what
        # the canonical writer emits (read_from_group surfaces names in
        # on-disk order).
        sorted_names = sorted(self.chromosomes)
        total = len(sorted_names)
        # Mirror Java ReferenceImport.writeToDataset: (0, N) then
        # (i+1, N) per contig. Progress is a runtime callback only.
        _fire(progress, 0, total)
        for i, name in enumerate(sorted_names):
            seq = self.chromosome(name)
```

Then, at the END of the loop body (after the existing `ds.write(arr)` line that closes the loop), add the per-contig fire so it reads:

```python
            ds.write(arr)
            _fire(progress, i + 1, total)
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/python && . .venv/bin/activate && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so python -m pytest tests/test_reference_import_progress.py tests/test_reference_import_write_round_trip.py -v'
```
Expected: PASS (new progress tests + the existing round-trip test, proving the embed still works).

- [ ] **Step 7: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add python/src/ttio/genomic/reference_import.py python/tests/test_reference_import_progress.py && git commit -m "feat(py-reference-import): per-contig progress on write_to_dataset"'
```

---

## Task 2: ObjC — `-writeToDataset:overwrite:progress:error:` overload

**Files:**
- Modify: `objc/Source/Genomics/TTIOReferenceImport.h`
- Modify: `objc/Source/Genomics/TTIOReferenceImport.m`
- Test: `objc/Tests/TTIOReferenceImportWriteToDatasetTests.m`

- [ ] **Step 1: Write the failing test case**

In `objc/Tests/TTIOReferenceImportWriteToDatasetTests.m`, add the progress header import near the existing imports:

```objc
#import "Core/TTIOProgressSink.h"
```

Add this function just above the existing `void testReferenceImportWriteToDataset(void)` entry point (the helpers `makeWritableDatasetForPath` / `makeTempPathW` already exist in this file):

```objc
static void testWriteToDatasetProgressFires(void)
{
    NSError *err = nil;
    NSString *path = makeTempPathW(@"progress");
    TTIOSpectralDataset *ds = makeWritableDatasetForPath(path, &err);
    PASS(ds != nil, "progress: writable dataset created");

    TTIOReferenceImport *ri = [[TTIOReferenceImport alloc]
        initWithUri:@"prog-v1"
        chromosomes:@[@"chr1", @"chr2", @"chr3"]
          sequences:@[[@"ACGT" dataUsingEncoding:NSUTF8StringEncoding],
                      [@"GGGG" dataUsingEncoding:NSUTF8StringEncoding],
                      [@"TTTT" dataUsingEncoding:NSUTF8StringEncoding]]];

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };

    BOOL ok = [ri writeToDataset:ds overwrite:NO progress:cb error:&err];
    PASS(ok, "progress: writeToDataset:overwrite:progress:error: succeeds");
    // (0,3),(1,3),(2,3),(3,3): N+1 fires, total always 3.
    PASS(doneVals.count == 4, "progress: N+1 (=4) callbacks fired");
    PASS([doneVals.firstObject longLongValue] == 0
         && [totalVals.firstObject longLongValue] == 3,
         "progress: first fire is (0, N)");
    PASS([doneVals.lastObject longLongValue] == 3
         && [totalVals.lastObject longLongValue] == 3,
         "progress: last fire is (N, N)");

    // Legacy (no-progress) overload still works.
    NSString *path2 = makeTempPathW(@"legacy");
    NSError *err2 = nil;
    TTIOSpectralDataset *ds2 = makeWritableDatasetForPath(path2, &err2);
    TTIOReferenceImport *ri2 = [[TTIOReferenceImport alloc]
        initWithUri:@"legacy-v1"
        chromosomes:@[@"chr1"]
          sequences:@[[@"ACGT" dataUsingEncoding:NSUTF8StringEncoding]]];
    PASS([ri2 writeToDataset:ds2 overwrite:NO error:&err2],
         "progress: legacy writeToDataset:overwrite:error: still works");

    [ds closeFile];
    [ds2 closeFile];
    unlink([path fileSystemRepresentation]);
    unlink([path2 fileSystemRepresentation]);
}
```

Register it in the entry function:

```objc
void testReferenceImportWriteToDataset(void)
{
    testWriteToDatasetRoundTripsThroughReferences();
    testWriteToDatasetRejectsDuplicateUriWithoutOverwrite();
    testWriteToDatasetOverwriteReplacesExistingReference();
    testWriteToDatasetProgressFires();
}
```

- [ ] **Step 2: Run the suite to verify the new case fails**

Run:
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -30'
```
Expected: compile error — no visible `-writeToDataset:overwrite:progress:error:` selector (method not declared).

- [ ] **Step 3: Declare the overload in the header**

In `objc/Source/Genomics/TTIOReferenceImport.h`, add the progress import near the top imports:

```objc
#import "Core/TTIOProgressSink.h"
```

Immediately after the existing `- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset overwrite:(BOOL)overwrite error:(NSError **)error;` declaration, add:

```objc
/**
 * Overload of <code>-writeToDataset:overwrite:error:</code> that fires
 * <code>progress(i+1, totalChromosomes)</code> after each chromosome is
 * written (and <code>progress(0, total)</code> once before the loop),
 * mirroring Java's <code>writeToDataset(..., ProgressSink)</code> and
 * Python's <code>write_to_dataset(..., progress=...)</code>.
 *
 * @param progress Progress block; pass <code>nil</code> for none.
 * @since 1.6.4
 */
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
              progress:(nullable TTIOProgressBlock)progress
                 error:(NSError **)error;
```

- [ ] **Step 4: Implement the overload + delegation in the .m**

In `objc/Source/Genomics/TTIOReferenceImport.m`:

(a) Change the existing 3-arg method header from:

```objc
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
                 error:(NSError **)error
{
```

to the new 4-arg signature:

```objc
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
              progress:(nullable TTIOProgressBlock)progress
                 error:(NSError **)error
{
    if (progress == nil) progress = TTIOProgressDiscard();
```

(b) Add a thin delegating 3-arg overload just above it:

```objc
- (BOOL)writeToDataset:(TTIOSpectralDataset *)dataset
             overwrite:(BOOL)overwrite
                 error:(NSError **)error
{
    return [self writeToDataset:dataset overwrite:overwrite
                       progress:TTIOProgressDiscard() error:error];
}
```

(c) In the (now 4-arg) method body, find where `sortedNames` is computed:

```objc
    NSArray<NSString *> *sortedNames =
        [byName.allKeys sortedArrayUsingSelector:@selector(compare:)];

    for (NSString *cname in sortedNames) {
```

and insert the counter + initial fire so it reads:

```objc
    NSArray<NSString *> *sortedNames =
        [byName.allKeys sortedArrayUsingSelector:@selector(compare:)];

    int64_t total = (int64_t)sortedNames.count;
    int64_t done = 0;
    progress(0, total);  // mirror Java: (0, N) before the embed loop
    for (NSString *cname in sortedNames) {
```

(d) At the end of the loop body, after the existing `if (![ds writeAll:seq error:error]) return NO;`, add the per-contig fire:

```objc
        if (![ds writeAll:seq error:error]) return NO;
        progress(++done, total);  // (i+1, N) per contig
    }
    return YES;
}
```

- [ ] **Step 5: Run the suite to verify it passes**

Run:
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | grep -E "progress:|FAIL|failed|[0-9]+ (passed|failed)" | tail -30'
```
Expected: the four new `progress:` PASS lines present; no FAIL lines.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add objc/Source/Genomics/TTIOReferenceImport.h objc/Source/Genomics/TTIOReferenceImport.m objc/Tests/TTIOReferenceImportWriteToDatasetTests.m && git commit -m "feat(objc-reference-import): per-contig progress overload on writeToDataset"'
```

---

## Task 3: ObjC — BAM reader progress test (close the gap)

**Files:**
- Test: `objc/Tests/TestProgressSink.m` (modify)

The ObjC `TTIOBamReader …progress:` API already exists (`TTIOBamReader.h:118`) but is untested. The ObjC BAM reader shells out to `samtools` and accepts a SAM path (same as Python), so the test writes a SAM and gates on `samtools` being on PATH.

- [ ] **Step 1: Add the BAM reader import**

In `objc/Tests/TestProgressSink.m`, add near the existing imports:

```objc
#import "Import/TTIOBamReader.h"
```

- [ ] **Step 2: Write the failing/gated test case**

Add this function before the `void testProgressSink(void)` entry point:

```objc
static BOOL psSamtoolsAvailable(void)
{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/env";
    t.arguments = @[@"samtools", @"--version"];
    t.standardOutput = [NSPipe pipe];
    t.standardError = [NSPipe pipe];
    @try { [t launch]; [t waitUntilExit]; }
    @catch (NSException *e) { return NO; }
    return t.terminationStatus == 0;
}

static void testBamReaderProgressFires(void)
{
    if (!psSamtoolsAvailable()) {
        PASS(YES, "BAM reader progress: samtools unavailable (skipped)");
        return;
    }
    NSString *tmp = psMakeTempDir();
    NSUInteger n = 5000;
    NSMutableString *sam = [NSMutableString string];
    [sam appendString:@"@HD\tVN:1.6\tSO:unsorted\n@SQ\tSN:chr1\tLN:1000\n"];
    for (NSUInteger i = 0; i < n; i++) {
        [sam appendFormat:@"r%06lu\t4\t*\t0\t0\t*\t*\t0\t0\tACGTACGT\tIIIIIIII\n",
                          (unsigned long)i];
    }
    NSString *samPath = [tmp stringByAppendingPathComponent:@"synth.sam"];
    psWriteFile(samPath, sam);

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
    };

    NSError *err = nil;
    TTIOBamReader *reader = [[TTIOBamReader alloc] initWithPath:samPath];
    TTIOWrittenGenomicRun *run =
        [reader toGenomicRunWithName:nil region:nil sampleName:nil
                            progress:cb error:&err];
    PASS(run != nil, "BAM reader progress: SAM parses via samtools");
    PASS(doneVals.count >= 1, "BAM reader progress: at least one fire");
    PASS([doneVals.lastObject longLongValue] == (int64_t)n,
         "BAM reader progress: final fire reports total read count");
}
```

(`[[TTIOBamReader alloc] initWithPath:samPath]` is the correct constructor — confirmed against `TTIOBamReader.h:79` and `TestM87BamImporter.m`.)

Register it:

```objc
void testProgressSink(void)
{
    testProgressSinkDiscard();
    testProgressBlockTypedefAcceptsCapturedState();
    testFastqProgressFires();
    testFastqProgressCadence();
    testFastaUnalignedProgressFires();
    testBamReaderProgressFires();
}
```

- [ ] **Step 3: Run the suite**

Run:
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | grep -E "BAM reader progress|FAIL|failed" | tail -20'
```
Expected: the `BAM reader progress:` PASS lines present (or the single "skipped" PASS if samtools is absent); no FAIL.

- [ ] **Step 4: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add objc/Tests/TestProgressSink.m && git commit -m "test(objc-bam): cover TTIOBamReader progress sink (samtools-gated)"'
```

---

## Task 4: Delete the three stale Java importer TODOs

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/importers/FastaReader.java`
- Modify: `java/src/main/java/global/thalion/ttio/importers/FastqReader.java`
- Modify: `java/src/main/java/global/thalion/ttio/importers/BamReader.java`

- [ ] **Step 1: Delete the FastaReader TODO**

In `FastaReader.java`, delete these four Javadoc lines (currently 44-47) and the now-empty `* ` spacer line directly above them if it leaves a doubled blank line:

```java
 * <p>TODO (parity): the per-contig progress hook on {@code readReference}
 * is mirrored by Python's {@code ReferenceImport} sink wiring; the
 * {@code readUnaligned} sink added here should grow Python +
 * Objective-C equivalents in a future cross-language parity PR.</p>
```

Leave the surrounding class Javadoc otherwise intact (the `*/` and class declaration remain).

- [ ] **Step 2: Delete the FastqReader TODO**

In `FastqReader.java`, delete these lines (currently 39-43):

```java
 * <p>TODO (parity): Python {@code ttio.importers.fastq.FastqReader} and
 * Objective-C {@code TTIOFastqReader} should grow a matching
 * {@code ProgressSink}-style callback in a future cross-language parity
 * PR so all three implementations expose the same per-read progress
 * hook.</p>
```

- [ ] **Step 3: Delete the BamReader TODO**

In `BamReader.java`, delete these lines (currently 60-64):

```java
 * <p>TODO (parity): Python {@code ttio.importers.bam.BamReader} and
 * Objective-C {@code TTIOBamReader} should grow a matching
 * {@code ProgressSink}-style callback in a future cross-language parity
 * PR so all three implementations expose the same per-read progress
 * hook.</p>
```

> If deleting a `<p>…</p>` block leaves a dangling empty `*` line that doubles a blank Javadoc line, remove the extra spacer so the Javadoc stays clean.

- [ ] **Step 4: Verify Java still compiles + no TODO remains**

Run:
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -q compile 2>&1 | tail -5; echo "--- remaining importer TODOs ---"; grep -rIn "TODO" src/main/java/global/thalion/ttio/importers/ || echo "(none)"'
```
Expected: clean compile; `(none)` for remaining importer TODOs.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add java/src/main/java/global/thalion/ttio/importers/FastaReader.java java/src/main/java/global/thalion/ttio/importers/FastqReader.java java/src/main/java/global/thalion/ttio/importers/BamReader.java && git commit -m "docs(java-importers): delete stale progress-sink parity TODOs"'
```

---

## Task 5: CHANGELOG + final verification + PR

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the CHANGELOG entry**

In `CHANGELOG.md`, directly under `## [Unreleased]` (above the existing first entry), add:

```markdown
### Added — Reference-embed progress parity (Python + ObjC)

`ReferenceImport.write_to_dataset` (Python) gains a keyword-only
`progress` parameter, and `TTIOReferenceImport` (ObjC) gains a
`-writeToDataset:overwrite:progress:error:` overload, both firing
per-contig progress (`(0, N)` then `(i+1, N)` ending at `(N, N)`) to
match Java's `ReferenceImport.writeToDataset(..., ProgressSink)`
(`@since 1.3.0`). Closes the last cross-language gap in the importer
progress-sink surface; the three stale "future parity PR" TODOs in the
Java importers are removed (the reader sinks they described already
shipped in all three SDKs). Added an ObjC test for the existing
`TTIOBamReader` progress sink (was untested). No wire/on-disk format
change. New tests: `test_reference_import_progress.py` (Python),
`writeToDataset…progress:` + BAM-reader cases (ObjC).
```

- [ ] **Step 2: Run the full per-language progress suites once more**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/python && . .venv/bin/activate && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so python -m pytest tests/test_reference_import_progress.py tests/test_reference_import_write_round_trip.py -q'
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | grep -E "[0-9]+ (passed|failed)|FAIL" | tail -10'
```
Expected: Python all pass; ObjC suite 0 failures.

- [ ] **Step 3: Commit the CHANGELOG**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add CHANGELOG.md && git commit -m "docs(changelog): reference-embed progress parity"'
```

- [ ] **Step 4: Push + open the PR**

Push from Windows git (WSL hangs on HTTPS auth):
```powershell
& 'C:\Program Files\Git\bin\git.exe' -C '\\wsl.localhost\Ubuntu\home\toddw\TTI-O' push -u origin feat/reference-import-progress-parity
```
Then open a PR (base `main`) summarising the parity addition, the deleted TODOs, and the new tests. CI's "Cross-language parity (ObjC ⇄ Python ⇄ Java)" job exercises the changes.

---

## Notes / gotchas

- **Empty reference (`N == 0`)**: with no chromosomes, Python emits only `(0, 0)` and ObjC only `progress(0, 0)` — one callback, consistent with Java (loop runs zero times). Tests use N≥2, but the code path is naturally correct; no special-casing needed.
- **`from __future__ import annotations`** is at the top of `reference_import.py`, so the string-quoted `"ProgressSinkLike | None"` annotation needs no runtime import; `_fire` is imported in the method body alongside the other lazy imports.
- **ObjC body move (Task 2)**: only the method *signature* line changes plus four inserted lines (`if (progress==nil)…`, `int64_t total/done`, `progress(0,total)`, `progress(++done,total)`) and the new delegating wrapper. Do not otherwise alter the embed body — the on-disk layout must stay byte-identical.
- **Java**: comment-only deletions; `mvn compile` is the safety check (no test change — `FastaReaderProgressTest` already covers the Java sink).
- **`@since` tags** use **1.6.4** (next patch release).
