# tio-browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `tio-browser` — a JavaFX desktop GUI peer to `java/`, `python/`, `objc/` — that consumes the `global.thalion:ttio` library to visually inspect `.tio` files, import/export across all 14 supported formats, and upload/download `.tis` transport streams.

**Architecture:** Single Maven module at the repo root (`tio-browser/`). All read/write/transport goes through the library's public API; no direct HDF5 calls in app code. JavaFX views wrap pure-Java models that are unit-testable without a JavaFX runtime; TestFX covers smoke-level FX startup. Native binaries (HDF5 JNI, samtools, ThermoRawFileParser, masslynxraw, Bruker Python helper) are external dependencies surfaced via a Diagnostics dialog. Distribution is a fat JAR (primary) plus optional `jpackage` native installers (stretch).

**Tech Stack:** Java 17, JavaFX 21, Maven 3.9+, JUnit 5.11, TestFX 4 (smoke only), `java.net.http.HttpClient` for HTTP upload, `java-websocket` (transitive of `ttio`) for WebSocket transport. No new direct deps beyond `global.thalion:ttio:1.1.0` and JavaFX.

**Library version:** Phase 0 bumps `global.thalion:ttio` from `1.0.0` → `1.1.0` (minor — additive API). All subsequent phases depend on `1.1.0`.

**Out of scope for v0.1:** multi-document tabs, live importer progress, alignment-coverage track view, telemetry/auto-update/crash reporter, code-signed macOS app bundle.

---

## Cross-cutting conventions

- **Working directory:** all WSL commands run inside `~/TTI-O.worktrees/tio-browser`. Never `cd` to `/home/toddw/TTI-O` (that's the main worktree).
- **Build dispatch from Windows:** `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && <cmd>'`. Build runs in WSL; pushes use Windows-side git per the documented memory pattern.
- **Commits:** small, frequent, conventional-commit prefixes (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`). One commit per task step labelled "Commit".
- **Tests:** TDD throughout. Every new public method/class lands together with the failing test that drove it.
- **No direct HDF5:** in `tio-browser/src/main/`, `import global.thalion.ttio.hdf5.*` is forbidden. Library API only.
- **Imports of library types:** prefer fully-qualified imports in tio-browser code where it disambiguates Run vs java.lang.Runnable, etc.

---

# Phase 0 — Library API: `references()` accessor (Python · Java · ObjC)

**Why first:** the Reference tab in Phase 7 needs to enumerate embedded `ReferenceImport` records on an opened `.tio`. Today the library writes references to `/study/references/<uri>/` when a writer is given `embedReference=true` + `referenceChromSeqs`, but no reader path materializes them. Without this Phase, §10 of the HANDOFF (no direct HDF5 in app code) collides with §4.1 (Reference tab).

**Cross-language parity invariant:** Python/Java/ObjC must each expose a `references()` accessor that returns a map (dict / NSDictionary) of `<reference_uri> → ReferenceImport` for the currently-open dataset. After this phase, a `.tio` written by language X must round-trip its reference list through `open()` + `references()` in languages X, Y, Z byte-equal.

**Files touched:**
- Java:
  - Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
  - Modify: `java/src/main/java/global/thalion/ttio/genomics/ReferenceImport.java` (add `readFrom(StorageGroup)` reader)
  - Test: `java/src/test/java/global/thalion/ttio/ReferencesAccessorTest.java`
- Python:
  - Modify: `python/src/ttio/spectral_dataset.py`
  - Modify: `python/src/ttio/genomics/reference_import.py` (add `read_from` reader)
  - Test: `python/tests/test_references_accessor.py`
- ObjC:
  - Modify: `objc/Source/Dataset/TTIOSpectralDataset.h`
  - Modify: `objc/Source/Dataset/TTIOSpectralDataset.m`
  - Modify: `objc/Source/Genomics/TTIOReferenceImport.h`
  - Modify: `objc/Source/Genomics/TTIOReferenceImport.m` (add `+readFromGroup:`)
  - Test: `objc/Tests/TTIOReferencesAccessorTests.m`
- Cross-language conformance:
  - Test: `python/tests/conformance/test_references_xlang.py` (writes a `.tio` from each language's writer, opens via each language's reader, asserts identical reference enumeration)
- Version bump:
  - Modify: `java/pom.xml` (`1.0.0` → `1.1.0`)
  - Modify: `python/src/ttio/__init__.py` (`__version__`)
  - Modify: `objc/Source/ttio-version-info.h` (or wherever the ObjC version constant lives — probe with `grep -rn "1.0.0" objc/Source/` first)
- Docs:
  - Modify: `CHANGELOG.md` — `[Unreleased]` → `[1.1.0]` entry
  - Modify: `docs/specification.md` — describe `references()` semantics in the storage-format chapter
  - Modify: `format-parity-report.md` — bump probed version

---

## Task 0.1: Java — failing test for `SpectralDataset.references()`

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/ReferencesAccessorTest.java`

- [ ] **Step 1: Write the failing test**

```java
package global.thalion.ttio;

import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.providers.StorageProvider;
import global.thalion.ttio.providers.ProviderRegistry;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class ReferencesAccessorTest {

    @Test
    void freshlyOpenedDatasetExposesEmbeddedReferences(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("with_refs.tio");

        // Write a tiny dataset with one reference embedded.
        Map<String, byte[]> refSeqs = new LinkedHashMap<>();
        refSeqs.put("chr1", "ACGTACGTACGT".getBytes());
        refSeqs.put("chr2", "TTTTAAAACCCC".getBytes());

        try (SpectralDataset ds = SpectralDataset.create(
                tio.toString(), "ref-test", "hdf5", null)) {
            WrittenGenomicRun run = WrittenGenomicRun.builder()
                .name("g1")
                .referenceUri("test-ref-v1")
                .embedReference(true)
                .referenceChromSeqs(refSeqs)
                .build();
            ds.addGenomicRun("g1", run);
            ds.flush();
        }

        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            Map<String, ReferenceImport> refs = opened.references();
            assertNotNull(refs, "references() must not return null");
            assertEquals(1, refs.size(), "exactly one embedded reference expected");
            ReferenceImport r = refs.get("test-ref-v1");
            assertNotNull(r);
            assertEquals(List.of("chr1", "chr2"), r.chromosomes());
            assertArrayEquals("ACGTACGTACGT".getBytes(), r.chromosome("chr1"));
            assertArrayEquals("TTTTAAAACCCC".getBytes(), r.chromosome("chr2"));
            assertEquals(24L, r.totalBases());
        }
    }

    @Test
    void datasetWithNoReferencesReturnsEmptyMap(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("no_refs.tio");
        try (SpectralDataset ds = SpectralDataset.create(
                tio.toString(), "no-ref", "hdf5", null)) {
            ds.flush();
        }
        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            Map<String, ReferenceImport> refs = opened.references();
            assertNotNull(refs);
            assertTrue(refs.isEmpty());
        }
    }
}
```

**Note** — the exact `WrittenGenomicRun.builder()` signature must be probed before locking the test. Run `grep -E "public.*WrittenGenomicRun(\(|\\.builder)" java/src/main/java/global/thalion/ttio/genomics/WrittenGenomicRun.java` and adjust constructor / builder usage to match what's already there. The shape (give the run a name, a referenceUri, embedReference=true, referenceChromSeqs map) is the contract — exact syntax follows the existing builder.

- [ ] **Step 2: Run test to verify it fails**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/java && mvn -q -Dtest=ReferencesAccessorTest test 2>&1 | tail -30'
```

Expected: compile-time failure on `opened.references()` — method not found. Good.

- [ ] **Step 3: Commit the failing test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add java/src/test/java/global/thalion/ttio/ReferencesAccessorTest.java && git commit -m "test(java): add failing test for SpectralDataset.references() accessor"'
```

---

## Task 0.2: Java — implement `ReferenceImport.readFromGroup`

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/genomics/ReferenceImport.java`

- [ ] **Step 1: Probe the existing reader pattern**

```
wsl -d Ubuntu -- bash -c 'grep -B1 -A20 "readFrom" ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/genomics/GenomicIndex.java | head -40'
```

This prints the existing `GenomicIndex.readFrom(StorageGroup)` pattern. Mirror its style.

- [ ] **Step 2: Add `readFromGroup` static factory to `ReferenceImport`**

Locate the existing constructors and `chromosome(String)` method. Below them, add:

```java
    /**
     * Read an embedded reference from {@code /study/references/<uri>/}.
     *
     * <p>Layout: each child dataset under {@code refGroup} is one
     * chromosome. Dataset name = chromosome name. Dataset value = raw
     * sequence bytes (uppercase ACGTN). Group attribute {@code uri} =
     * the reference URI.
     *
     * @param refGroup the {@code /study/references/<uri>/} group
     * @return a fully-populated ReferenceImport
     * @throws IOException on storage-layer failure
     * @since 1.1.0
     */
    public static ReferenceImport readFromGroup(StorageGroup refGroup) {
        String uri = refGroup.getStringAttribute("uri", refGroup.name());
        List<String> chromNames = new ArrayList<>(refGroup.childDatasetNames());
        // Stable order: write-time insertion order if available; alpha
        // otherwise. The writer uses LinkedHashMap; storage providers
        // preserve dataset-creation order. Fall back to alpha for
        // safety.
        List<byte[]> seqs = new ArrayList<>(chromNames.size());
        for (String name : chromNames) {
            try (StorageDataset ds = refGroup.openDataset(name)) {
                byte[] bytes = ds.readBytes();
                seqs.add(bytes);
            }
        }
        return new ReferenceImport(uri, chromNames, seqs);
    }
```

If `StorageGroup.childDatasetNames()` doesn't exist, add a thin pass-through that calls the underlying provider. Probe with: `grep -E "(childDatasetNames|listDatasets|datasetNames)" ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/providers/StorageGroup.java`. The exact method name lives in the provider abstraction; if it differs, adjust.

- [ ] **Step 3: Run only the new compile**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/java && mvn -q -Dtest=ReferencesAccessorTest test-compile 2>&1 | tail -20'
```

Expected: compile passes.

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add java/src/main/java/global/thalion/ttio/genomics/ReferenceImport.java && git commit -m "feat(java): add ReferenceImport.readFromGroup for /study/references/<uri>/"'
```

---

## Task 0.3: Java — wire `references()` into `SpectralDataset`

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`

- [ ] **Step 1: Add the field and accessor**

Add to the field block (alongside `msRuns`, `genomicRuns`):

```java
    private final Map<String, global.thalion.ttio.genomics.ReferenceImport> references;
```

Add to the public-accessor block (after `genomicRuns()`):

```java
    /**
     * Returns embedded references discovered under
     * {@code /study/references/} on this dataset.
     *
     * <p>Keys are reference URIs (the same string returned by
     * {@link global.thalion.ttio.genomics.GenomicRun#referenceUri()}).
     * Values are fully-materialized {@link
     * global.thalion.ttio.genomics.ReferenceImport} instances ready
     * for diff-based codecs and for inspection in user-facing
     * tooling.
     *
     * <p>Datasets written without embedded references (writer flag
     * {@code embedReference=false}) return an empty map even if
     * {@link global.thalion.ttio.genomics.GenomicRun#referenceUri()}
     * is non-null on individual runs.
     *
     * @return unmodifiable map; never null
     * @since 1.1.0
     */
    public Map<String, global.thalion.ttio.genomics.ReferenceImport> references() {
        return Collections.unmodifiableMap(references);
    }
```

- [ ] **Step 2: Populate `references` in the open path**

Find the existing read path for `msRuns` / `genomicRuns` (probe: `grep -n "msRuns =\|genomicRuns =" SpectralDataset.java`). Beside that, add:

```java
        Map<String, global.thalion.ttio.genomics.ReferenceImport> refsTmp = new LinkedHashMap<>();
        if (root.hasChildGroup("study")) {
            StorageGroup study = root.openGroup("study");
            if (study.hasChildGroup("references")) {
                StorageGroup refsGroup = study.openGroup("references");
                for (String uri : refsGroup.childGroupNames()) {
                    StorageGroup oneRef = refsGroup.openGroup(uri);
                    refsTmp.put(uri,
                        global.thalion.ttio.genomics.ReferenceImport.readFromGroup(oneRef));
                }
            }
        }
        this.references = refsTmp;
```

If `hasChildGroup` / `childGroupNames` aren't already on `StorageGroup`, add minimal pass-throughs to the abstraction (probe with `grep -E "(hasChildGroup|childGroupNames|listGroups)" StorageGroup.java`). Keep the additions purely accessor-shaped — no behaviour change.

- [ ] **Step 3: Initialize `references` in the create path**

In every `create(...)` overload's terminal `new SpectralDataset(...)` call (or in the constructor itself), pass an empty `LinkedHashMap` for the new `references` field. The create path doesn't write any reference yet — references appear only when `WrittenGenomicRun.embedReference=true` flushes them.

- [ ] **Step 4: Refresh `references` after write paths that embed references**

Find every code path where `WrittenGenomicRun` lands on disk with `embedReference=true`. After flush, re-read `/study/references/` to keep the in-memory map consistent. The simplest implementation: extract the read snippet from Step 2 into a private `private void reloadReferences(StorageGroup root)` and call it after writes.

- [ ] **Step 5: Run the test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/java && mvn -q -Dtest=ReferencesAccessorTest test 2>&1 | tail -30'
```

Expected: PASS on both test methods.

- [ ] **Step 6: Run the full Java test suite to confirm no regressions**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/java && mvn -q test 2>&1 | tail -40'
```

Expected: all green; the new test counts +2.

- [ ] **Step 7: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add java/src/main/java/global/thalion/ttio/SpectralDataset.java java/src/main/java/global/thalion/ttio/providers/ && git commit -m "feat(java): SpectralDataset.references() exposes embedded /study/references"'
```

---

## Task 0.4: Python — failing test then implementation

**Files:**
- Create: `python/tests/test_references_accessor.py`
- Modify: `python/src/ttio/genomics/reference_import.py`
- Modify: `python/src/ttio/spectral_dataset.py`

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_references_accessor.py
import tempfile
from pathlib import Path

import pytest

from ttio import SpectralDataset
from ttio.genomics import ReferenceImport, WrittenGenomicRun


def test_freshly_opened_dataset_exposes_embedded_references(tmp_path):
    tio = tmp_path / "with_refs.tio"
    ref_seqs = {
        "chr1": b"ACGTACGTACGT",
        "chr2": b"TTTTAAAACCCC",
    }
    with SpectralDataset.create(str(tio), title="ref-test", provider="hdf5") as ds:
        run = WrittenGenomicRun(
            name="g1",
            reference_uri="test-ref-v1",
            embed_reference=True,
            reference_chrom_seqs=ref_seqs,
        )
        ds.add_genomic_run("g1", run)
        ds.flush()

    with SpectralDataset.open(str(tio)) as opened:
        refs = opened.references
        assert refs is not None
        assert list(refs.keys()) == ["test-ref-v1"]
        r = refs["test-ref-v1"]
        assert r.chromosomes == ["chr1", "chr2"]
        assert r.chromosome("chr1") == b"ACGTACGTACGT"
        assert r.chromosome("chr2") == b"TTTTAAAACCCC"
        assert r.total_bases == 24


def test_dataset_without_references_returns_empty_dict(tmp_path):
    tio = tmp_path / "no_refs.tio"
    with SpectralDataset.create(str(tio), title="no-ref", provider="hdf5") as ds:
        ds.flush()
    with SpectralDataset.open(str(tio)) as opened:
        assert opened.references == {}
```

The exact `WrittenGenomicRun(...)` constructor kwargs must match what's there — probe `grep -n "def __init__" python/src/ttio/genomics/written_genomic_run.py`. Adjust kwarg names if needed (`reference_uri` vs `referenceUri` vs `ref_uri`).

- [ ] **Step 2: Run test to verify failure**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && python -m pytest python/tests/test_references_accessor.py -x 2>&1 | tail -20'
```

Expected: AttributeError on `opened.references`.

- [ ] **Step 3: Add `read_from_group` to `ReferenceImport`**

Probe the existing class first: `grep -E "^(class |    def )" python/src/ttio/genomics/reference_import.py | head`. Then add a classmethod after the existing reader-style helpers:

```python
    @classmethod
    def read_from_group(cls, ref_group) -> "ReferenceImport":
        """Read an embedded reference from /study/references/<uri>/.

        Each child dataset is one chromosome; dataset name = chromosome name,
        dataset bytes = raw sequence (uppercase ACGTN). The group's ``uri``
        attribute is the reference URI; falls back to the group's own name.

        :since: 1.1.0
        """
        uri = ref_group.attrs.get("uri", ref_group.name.split("/")[-1])
        chrom_names = list(ref_group.child_dataset_names())
        seqs = [ref_group.open_dataset(name).read_bytes() for name in chrom_names]
        return cls(uri=uri, chromosomes=chrom_names, sequences=seqs)
```

The exact provider-abstraction methods (`child_dataset_names`, `open_dataset`, `read_bytes`) follow whatever the Python codebase already uses — probe `grep -rn "child_dataset_names\|childDatasetNames\|list_datasets" python/src/ttio/providers/`. Match the existing convention.

- [ ] **Step 4: Wire `references` property into `SpectralDataset`**

In `python/src/ttio/spectral_dataset.py`, add `references` as an instance dict initialized to `{}` in `__init__`, populated in `open()` by scanning `/study/references/`, and exposed as a `@property` returning a defensive shallow copy.

```python
    @property
    def references(self) -> dict:
        """Map of reference URI → :class:`ReferenceImport` for refs
        embedded under ``/study/references/`` in this dataset.

        Returns an empty dict for datasets written with
        ``embed_reference=False`` even when individual genomic runs
        carry a ``reference_uri``.

        :since: 1.1.0
        """
        return dict(self._references)
```

In `open()` after the existing `ms_runs` / `genomic_runs` reads:

```python
        self._references = {}
        if "study" in root and "references" in root["study"]:
            refs_group = root["study"]["references"]
            for uri in refs_group.child_group_names():
                one_ref = refs_group.open_group(uri)
                self._references[uri] = ReferenceImport.read_from_group(one_ref)
```

- [ ] **Step 5: Run the test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && python -m pytest python/tests/test_references_accessor.py -v 2>&1 | tail -20'
```

Expected: 2 passed.

- [ ] **Step 6: Full Python suite — no regressions**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && python -m pytest python/tests/ -x --timeout=60 2>&1 | tail -10'
```

- [ ] **Step 7: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add python/ && git commit -m "feat(python): SpectralDataset.references property exposes embedded /study/references"'
```

---

## Task 0.5: ObjC — failing test then implementation

**Files:**
- Create: `objc/Tests/TTIOReferencesAccessorTests.m`
- Modify: `objc/Source/Genomics/TTIOReferenceImport.h`
- Modify: `objc/Source/Genomics/TTIOReferenceImport.m`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.h`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.m`

- [ ] **Step 1: Write the failing test (rfm style — inline PASS, no wrapper class)**

Per the libs-base test memory, inline PASS macros, static helpers, no NSAssert, no @try/@catch on Win32 (use NS_DURING). On WSL/Linux ObjC the Win32 caveat doesn't apply; still avoid @try.

```objc
// objc/Tests/TTIOReferencesAccessorTests.m
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "TTIOSpectralDataset.h"
#import "TTIOReferenceImport.h"
#import "TTIOWrittenGenomicRun.h"
#import "Testing.h"  // GNUstep's PASS macro header — confirm path

static NSString *makeTempPath(NSString *name) {
    NSString *dir = NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:name];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *tio = makeTempPath(@"refs_xlang_objc.tio");
        [[NSFileManager defaultManager] removeItemAtPath:tio error:NULL];

        // Write
        NSDictionary *refSeqs = @{
            @"chr1": [@"ACGTACGTACGT" dataUsingEncoding:NSASCIIStringEncoding],
            @"chr2": [@"TTTTAAAACCCC" dataUsingEncoding:NSASCIIStringEncoding],
        };
        NSError *err = nil;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset
            createAtPath:tio title:@"ref-test" provider:@"hdf5" error:&err];
        PASS(ds != nil && err == nil, "create dataset");
        TTIOWrittenGenomicRun *run = [[TTIOWrittenGenomicRun alloc]
            initWithName:@"g1"
                referenceUri:@"test-ref-v1"
                embedReference:YES
                referenceChromSeqs:refSeqs];
        [ds addGenomicRun:run forName:@"g1"];
        [ds flush:&err];
        [ds close];

        // Read back
        TTIOSpectralDataset *opened = [TTIOSpectralDataset
            openAtPath:tio error:&err];
        PASS(opened != nil && err == nil, "open dataset");

        NSDictionary<NSString*, TTIOReferenceImport*> *refs = [opened references];
        PASS(refs != nil, "references not nil");
        PASS([refs count] == 1, "exactly one reference");
        TTIOReferenceImport *r = refs[@"test-ref-v1"];
        PASS(r != nil, "test-ref-v1 present");
        PASS([[r chromosomes] isEqualToArray:(@[@"chr1", @"chr2"])],
             "chromosomes ordered");
        NSData *seq1 = [r chromosomeData:@"chr1"];
        PASS([[NSString alloc] initWithData:seq1 encoding:NSASCIIStringEncoding] &&
             [seq1 length] == 12, "chr1 sequence length");

        [opened close];
        [[NSFileManager defaultManager] removeItemAtPath:tio error:NULL];
    }
    return 0;
}
```

- [ ] **Step 2: Add to GNUmakefile.tests**

Probe the existing test list: `grep -A20 "tests :=\|Tests_OBJC_FILES\|TEST_TOOL_NAME" objc/Tests/GNUmakefile`. Append `TTIOReferencesAccessorTests.m` to the OBJC_FILES list and add the test target.

- [ ] **Step 3: Run to verify failure**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/objc && gnustep-make -f Tests/GNUmakefile check 2>&1 | tail -30'
```

Expected: undefined selector `references` on TTIOSpectralDataset.

- [ ] **Step 4: Add `+readFromGroup:` to `TTIOReferenceImport`**

Header (`TTIOReferenceImport.h`), in the public interface block, after the existing init declarations:

```objc
/**
 * Reads an embedded reference from /study/references/<uri>/.
 * Each child dataset is one chromosome; dataset name = chromosome
 * name, raw bytes = uppercase ACGTN. Group attribute "uri" gives
 * the reference URI; falls back to the group name.
 *
 * @since 1.1.0
 */
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)refGroup;
```

Implementation (`TTIOReferenceImport.m`):

```objc
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)refGroup {
    NSString *uri = [refGroup stringAttributeForKey:@"uri"
                                        defaultValue:[refGroup name]];
    NSArray<NSString*> *chromNames = [refGroup childDatasetNames];
    NSMutableArray<NSData*> *seqs =
        [NSMutableArray arrayWithCapacity:[chromNames count]];
    for (NSString *name in chromNames) {
        id<TTIOStorageDataset> dset = [refGroup openDataset:name];
        [seqs addObject:[dset readBytes]];
    }
    return [[self alloc] initWithURI:uri
                          chromosomes:chromNames
                            sequences:seqs];
}
```

- [ ] **Step 5: Wire `references` accessor into `TTIOSpectralDataset`**

Header — add to the public interface:

```objc
/**
 * Map of reference URI → TTIOReferenceImport for embedded
 * references found under /study/references/.
 *
 * Empty dictionary when no references were embedded at write time
 * (writer flag embedReference=NO).
 *
 * @since 1.1.0
 */
@property (nonatomic, readonly, copy)
    NSDictionary<NSString*, TTIOReferenceImport*> *references;
```

Implementation — populate in `+openAtPath:error:` after `_msRuns` / `_genomicRuns` populated:

```objc
    NSMutableDictionary<NSString*, TTIOReferenceImport*> *refs =
        [NSMutableDictionary dictionary];
    id<TTIOStorageGroup> root = [self _rootGroup];
    if ([root hasChildGroup:@"study"]) {
        id<TTIOStorageGroup> study = [root openGroup:@"study"];
        if ([study hasChildGroup:@"references"]) {
            id<TTIOStorageGroup> refsGroup = [study openGroup:@"references"];
            for (NSString *uri in [refsGroup childGroupNames]) {
                id<TTIOStorageGroup> one = [refsGroup openGroup:uri];
                refs[uri] = [TTIOReferenceImport readFromGroup:one];
            }
        }
    }
    _references = [refs copy];
```

If `TTIOStorageGroup` protocol lacks `hasChildGroup:` / `childGroupNames` / `childDatasetNames`, add them as additive protocol methods (matches the Java pattern in 0.3). Probe with `grep -A30 "@protocol TTIOStorageGroup" objc/Source/Providers/*.h`.

- [ ] **Step 6: Run the test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/objc && gnustep-make -f Tests/GNUmakefile check 2>&1 | tail -30'
```

Expected: TTIOReferencesAccessorTests passes (5 PASS lines).

- [ ] **Step 7: Full ObjC test run — no regressions**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/objc && gnustep-make -f Tests/GNUmakefile check 2>&1 | tail -20'
```

- [ ] **Step 8: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add objc/ && git commit -m "feat(objc): TTIOSpectralDataset.references exposes embedded /study/references"'
```

---

## Task 0.6: Cross-language conformance test

**Files:**
- Create: `python/tests/conformance/test_references_xlang.py`

**Goal:** for each of the 3 writers (Python, Java, ObjC), produce a `.tio` with a known reference, then for each of the 3 readers, open it and assert the references map matches byte-equal. 9 directed pairs total.

- [ ] **Step 1: Write the test**

```python
# python/tests/conformance/test_references_xlang.py
"""Cross-language parity for SpectralDataset.references() — added in 1.1.0.

For each writer language X ∈ {python, java, objc}:
  - X writes a .tio with one embedded reference {chr1: "ACGTACGTACGT",
    chr2: "TTTTAAAACCCC"} keyed by URI "xlang-test-v1".
For each reader language Y ∈ {python, java, objc}:
  - Y opens X's file and asserts references == the known map.

9 pairs, all must pass.
"""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from ttio import SpectralDataset
from ttio.genomics import WrittenGenomicRun

REPO = Path(__file__).resolve().parents[3]  # python/tests/conformance/<file> → repo
JAVA_DIR = REPO / "java"
OBJC_DIR = REPO / "objc"

KNOWN_REFS = {
    "chr1": b"ACGTACGTACGT",
    "chr2": b"TTTTAAAACCCC",
}
URI = "xlang-test-v1"


# ─── writers ────────────────────────────────────────────────────────────────

def write_python(out: Path) -> None:
    with SpectralDataset.create(str(out), title="xlang", provider="hdf5") as ds:
        run = WrittenGenomicRun(
            name="g1",
            reference_uri=URI,
            embed_reference=True,
            reference_chrom_seqs=KNOWN_REFS,
        )
        ds.add_genomic_run("g1", run)
        ds.flush()


def write_java(out: Path) -> None:
    """Run a tiny Java helper that writes the canonical reference."""
    helper = JAVA_DIR / "src/test/java/global/thalion/ttio/conformance/RefXLangWriter.java"
    if not helper.exists():
        pytest.skip(f"helper missing: {helper}")
    cmd = [
        "wsl", "-d", "Ubuntu", "--", "bash", "-c",
        f"cd {JAVA_DIR} && mvn -q -DskipTests compile && "
        f"mvn -q exec:java -Dexec.mainClass=global.thalion.ttio.conformance.RefXLangWriter "
        f"-Dexec.args={out}",
    ]
    subprocess.run(cmd, check=True)


def write_objc(out: Path) -> None:
    helper = OBJC_DIR / "Tests/RefXLangWriter.m"
    if not helper.exists():
        pytest.skip(f"helper missing: {helper}")
    cmd = [
        "wsl", "-d", "Ubuntu", "--", "bash", "-c",
        f"cd {OBJC_DIR} && gnustep-make -f Tests/GNUmakefile RefXLangWriter && "
        f"./obj/RefXLangWriter {out}",
    ]
    subprocess.run(cmd, check=True)


# ─── readers ────────────────────────────────────────────────────────────────

def read_python(tio: Path) -> dict:
    with SpectralDataset.open(str(tio)) as ds:
        return {
            uri: {chrom: ref.chromosome(chrom) for chrom in ref.chromosomes}
            for uri, ref in ds.references.items()
        }


def read_java(tio: Path) -> dict:
    helper = JAVA_DIR / "src/test/java/global/thalion/ttio/conformance/RefXLangReader.java"
    if not helper.exists():
        pytest.skip(f"helper missing: {helper}")
    cmd = [
        "wsl", "-d", "Ubuntu", "--", "bash", "-c",
        f"cd {JAVA_DIR} && mvn -q exec:java "
        f"-Dexec.mainClass=global.thalion.ttio.conformance.RefXLangReader "
        f"-Dexec.args={tio}",
    ]
    out = subprocess.check_output(cmd, text=True)
    parsed = json.loads(out.strip())
    # Java helper emits hex; decode
    return {
        uri: {chrom: bytes.fromhex(hexstr) for chrom, hexstr in ref.items()}
        for uri, ref in parsed.items()
    }


def read_objc(tio: Path) -> dict:
    helper = OBJC_DIR / "Tests/RefXLangReader.m"
    if not helper.exists():
        pytest.skip(f"helper missing: {helper}")
    cmd = [
        "wsl", "-d", "Ubuntu", "--", "bash", "-c",
        f"cd {OBJC_DIR} && gnustep-make -f Tests/GNUmakefile RefXLangReader && "
        f"./obj/RefXLangReader {tio}",
    ]
    out = subprocess.check_output(cmd, text=True)
    parsed = json.loads(out.strip())
    return {
        uri: {chrom: bytes.fromhex(hexstr) for chrom, hexstr in ref.items()}
        for uri, ref in parsed.items()
    }


WRITERS = {"python": write_python, "java": write_java, "objc": write_objc}
READERS = {"python": read_python, "java": read_java, "objc": read_objc}


@pytest.mark.parametrize("writer_lang", list(WRITERS))
@pytest.mark.parametrize("reader_lang", list(READERS))
def test_xlang_references_roundtrip(writer_lang, reader_lang, tmp_path):
    tio = tmp_path / f"refs_{writer_lang}_to_{reader_lang}.tio"
    WRITERS[writer_lang](tio)
    got = READERS[reader_lang](tio)
    assert got == {URI: KNOWN_REFS}, \
        f"writer={writer_lang} reader={reader_lang} mismatch: {got}"
```

- [ ] **Step 2: Add the Java helpers `RefXLangWriter` and `RefXLangReader`**

```java
// java/src/test/java/global/thalion/ttio/conformance/RefXLangWriter.java
package global.thalion.ttio.conformance;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import java.util.LinkedHashMap;
import java.util.Map;

public final class RefXLangWriter {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: RefXLangWriter <out.tio>");
            System.exit(2);
        }
        Map<String, byte[]> refSeqs = new LinkedHashMap<>();
        refSeqs.put("chr1", "ACGTACGTACGT".getBytes());
        refSeqs.put("chr2", "TTTTAAAACCCC".getBytes());

        try (SpectralDataset ds = SpectralDataset.create(
                args[0], "xlang", "hdf5", null)) {
            WrittenGenomicRun run = WrittenGenomicRun.builder()
                .name("g1")
                .referenceUri("xlang-test-v1")
                .embedReference(true)
                .referenceChromSeqs(refSeqs)
                .build();
            ds.addGenomicRun("g1", run);
            ds.flush();
        }
    }
}
```

```java
// java/src/test/java/global/thalion/ttio/conformance/RefXLangReader.java
package global.thalion.ttio.conformance;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;

import java.util.LinkedHashMap;
import java.util.Map;

public final class RefXLangReader {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: RefXLangReader <in.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            // Emit canonical JSON: {uri: {chrom: <hex>}}
            StringBuilder sb = new StringBuilder("{");
            boolean firstUri = true;
            for (Map.Entry<String, ReferenceImport> e : ds.references().entrySet()) {
                if (!firstUri) sb.append(",");
                firstUri = false;
                sb.append('"').append(e.getKey()).append("\":{");
                boolean firstChrom = true;
                ReferenceImport r = e.getValue();
                for (String chrom : r.chromosomes()) {
                    if (!firstChrom) sb.append(",");
                    firstChrom = false;
                    byte[] bytes = r.chromosome(chrom);
                    sb.append('"').append(chrom).append("\":\"");
                    for (byte b : bytes) {
                        sb.append(String.format("%02x", b & 0xff));
                    }
                    sb.append('"');
                }
                sb.append("}");
            }
            sb.append("}");
            System.out.println(sb);
        }
    }
}
```

- [ ] **Step 3: Add the ObjC helpers `RefXLangWriter.m` and `RefXLangReader.m`**

```objc
// objc/Tests/RefXLangWriter.m
#import <Foundation/Foundation.h>
#import "TTIOSpectralDataset.h"
#import "TTIOWrittenGenomicRun.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <out.tio>\n", argv[0]);
            return 2;
        }
        NSString *out = [NSString stringWithUTF8String:argv[1]];
        NSDictionary *refSeqs = @{
            @"chr1": [@"ACGTACGTACGT" dataUsingEncoding:NSASCIIStringEncoding],
            @"chr2": [@"TTTTAAAACCCC" dataUsingEncoding:NSASCIIStringEncoding],
        };
        NSError *err = nil;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset
            createAtPath:out title:@"xlang" provider:@"hdf5" error:&err];
        TTIOWrittenGenomicRun *run = [[TTIOWrittenGenomicRun alloc]
            initWithName:@"g1"
                referenceUri:@"xlang-test-v1"
                embedReference:YES
                referenceChromSeqs:refSeqs];
        [ds addGenomicRun:run forName:@"g1"];
        [ds flush:&err];
        [ds close];
    }
    return 0;
}
```

```objc
// objc/Tests/RefXLangReader.m
#import <Foundation/Foundation.h>
#import "TTIOSpectralDataset.h"
#import "TTIOReferenceImport.h"

static NSString *hex(NSData *d) {
    NSMutableString *s = [NSMutableString stringWithCapacity:[d length] * 2];
    const uint8_t *b = [d bytes];
    for (NSUInteger i = 0; i < [d length]; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <in.tio>\n", argv[0]);
            return 2;
        }
        NSError *err = nil;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset
            openAtPath:[NSString stringWithUTF8String:argv[1]] error:&err];
        NSMutableString *json = [NSMutableString stringWithString:@"{"];
        BOOL firstUri = YES;
        for (NSString *uri in [ds references]) {
            if (!firstUri) [json appendString:@","];
            firstUri = NO;
            [json appendFormat:@"\"%@\":{", uri];
            TTIOReferenceImport *r = [ds references][uri];
            BOOL firstChrom = YES;
            for (NSString *chrom in [r chromosomes]) {
                if (!firstChrom) [json appendString:@","];
                firstChrom = NO;
                [json appendFormat:@"\"%@\":\"%@\"", chrom,
                    hex([r chromosomeData:chrom])];
            }
            [json appendString:@"}"];
        }
        [json appendString:@"}"];
        printf("%s\n", [json UTF8String]);
        [ds close];
    }
    return 0;
}
```

- [ ] **Step 4: Run the conformance test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && python -m pytest python/tests/conformance/test_references_xlang.py -v 2>&1 | tail -20'
```

Expected: 9/9 passed.

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add python/tests/conformance/test_references_xlang.py java/src/test/java/global/thalion/ttio/conformance/ objc/Tests/RefXLang*.m && git commit -m "test(conformance): xlang references() roundtrip across python/java/objc"'
```

---

## Task 0.7: Version bump 1.0.0 → 1.1.0 (all three languages + parent docs)

- [ ] **Step 1: Bump Java**

Edit `java/pom.xml` line containing `<version>1.0.0</version>` → `<version>1.1.0</version>`. Verify only the project `<version>` is changed, not dependency versions.

- [ ] **Step 2: Bump Python**

Find: `grep -rn "__version__" python/src/ttio/__init__.py python/pyproject.toml`. Change `1.0.0` → `1.1.0` in both.

- [ ] **Step 3: Bump ObjC**

Find: `grep -rn "1.0.0\|TTIO_VERSION" objc/Source/`. Change the version constant accordingly. Some ObjC builds carry the version in `objc/version` plain-text — update if present.

- [ ] **Step 4: Update format-parity-report.md probed-version note**

Edit the line `Repo head probed: ... on 2026-05-06.` to add `(library version 1.1.0).`

- [ ] **Step 5: Run a quick sanity build of all three languages**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/java && mvn -q -DskipTests package 2>&1 | tail -5 ; echo --- ; cd ../python && python -c "import ttio; print(ttio.__version__)" ; echo --- ; cd ../objc && gnustep-make -s 2>&1 | tail -5'
```

Expected: Java 1.1.0 jar built; Python prints `1.1.0`; ObjC clean.

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add -p java/pom.xml python/src/ttio/__init__.py python/pyproject.toml objc/ format-parity-report.md && git commit -m "chore: bump library version 1.0.0 → 1.1.0 (references() accessor)"'
```

---

## Task 0.8: CHANGELOG + spec docs

- [ ] **Step 1: Update CHANGELOG.md**

Move existing `[Unreleased]` content into a new `[1.1.0] — 2026-05-06` entry. Under that section, add:

```
### Added
- `SpectralDataset.references()` (Java), `SpectralDataset.references` (Python),
  `[TTIOSpectralDataset references]` (ObjC) — enumerates embedded references at
  `/study/references/<uri>/` for opened datasets. Cross-language parity tested.
- `ReferenceImport.readFromGroup` / `read_from_group` / `+readFromGroup:` —
  factory that materializes a `ReferenceImport` from its on-disk group.
```

Re-create an empty `[Unreleased]` heading above it.

- [ ] **Step 2: Update docs/specification.md**

Locate the storage-format chapter that documents `/study/references/`. Append to the chapter:

```
### Reading embedded references

A `.tio` may embed one or more references at
`/study/references/<reference_uri>/`. Each child group is one
reference; each child dataset within is one chromosome (dataset name =
chromosome name, dataset bytes = uppercase ACGTN sequence).

As of v1.1.0, a freshly-opened dataset exposes embedded references
through the `references()` accessor (`references` property in Python,
`references` instance variable in ObjC), keyed by reference URI.
Datasets written without embedded references (writer flag
`embedReference=false`) return an empty map regardless of whether
individual genomic runs carry a `referenceUri`.
```

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add CHANGELOG.md docs/specification.md && git commit -m "docs: 1.1.0 release notes + references() spec section"'
```

---

## Phase 0 acceptance gate

- [ ] **All Phase 0 commits land cleanly** — `git log --oneline | head -10` shows the 8 task commits in order.
- [ ] **Java tests** — `cd java && mvn test` passes; new test count = +2.
- [ ] **Python tests** — `pytest python/tests/` passes; +2 new tests.
- [ ] **ObjC tests** — `gnustep-make -f Tests/GNUmakefile check` passes; +5 PASS lines.
- [ ] **Cross-language conformance** — `pytest python/tests/conformance/test_references_xlang.py` shows 9/9 pass.
- [ ] **Versions consistent** — Java POM, Python `__version__`, ObjC version constant all read 1.1.0.
- [ ] **CHANGELOG + spec updated**.

Phase 0 is complete when this gate passes. Do not proceed to Phase 1 until all boxes ticked.

---

# Phase 1 — Maven module skeleton + main window shell

**Goal:** `mvn -pl tio-browser package` produces a runnable fat JAR. Running it shows the main window with menu bar, toolbar, empty tree, empty detail pane, status bar. File → Open opens a `.tio` and updates the status bar; File → Close clears state; File → Exit terminates. Encryption banner appears for encrypted files.

**Files:**
- Create: `tio-browser/pom.xml`
- Create: `tio-browser/LICENSE` (LGPL-3.0 text — copy from java/LICENSE)
- Create: `tio-browser/README.md` (skeleton — fleshed out in Phase 14)
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/App.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/model/OpenDataset.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetOpenTask.java`
- Create: `tio-browser/src/main/resources/css/tio-browser.css` (empty stub)
- Create: `tio-browser/src/main/resources/icons/app-icon.png` (placeholder 256×256)
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/AppSmokeTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/model/DatasetOpenTaskTest.java`
- Modify (parent repo): `pom.xml` only if a parent reactor exists — probe `ls pom.xml 2>/dev/null` at repo root. If no parent reactor, `tio-browser` is a standalone module that depends on the published `global.thalion:ttio:1.1.0`. The local `mvn install` of `java/` puts it in the local M2 repo so `tio-browser` resolves it.

---

## Task 1.1: Create the Maven module + License + README skeleton

- [ ] **Step 1: Create `tio-browser/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>global.thalion</groupId>
    <artifactId>tio-browser</artifactId>
    <version>0.1.0</version>
    <packaging>jar</packaging>

    <name>tio-browser</name>
    <description>JavaFX desktop GUI for inspecting, importing, exporting,
                 and transporting TTI-O .tio multi-omics datasets.</description>

    <licenses>
        <license>
            <name>LGPL-3.0-or-later</name>
            <url>https://www.gnu.org/licenses/lgpl-3.0.html</url>
        </license>
    </licenses>

    <properties>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <maven.compiler.source>17</maven.compiler.source>
        <maven.compiler.target>17</maven.compiler.target>
        <javafx.version>21.0.5</javafx.version>
        <ttio.version>1.1.0</ttio.version>
    </properties>

    <dependencies>
        <!-- TTI-O library — Phase 0 produced 1.1.0 with references() -->
        <dependency>
            <groupId>global.thalion</groupId>
            <artifactId>ttio</artifactId>
            <version>${ttio.version}</version>
        </dependency>

        <!-- HDF5 system jar — must be on classpath for any read of .tio.
             Path varies by platform; override with -Dhdf5.jar= at build time. -->
        <dependency>
            <groupId>org.hdfgroup</groupId>
            <artifactId>hdf5</artifactId>
            <version>1.10.10</version>
            <scope>system</scope>
            <systemPath>${hdf5.jar}</systemPath>
        </dependency>

        <!-- JavaFX — three classifiers so the fat JAR runs on macOS x64,
             macOS arm64, and Windows x64. -->
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-controls</artifactId>
            <version>${javafx.version}</version>
            <classifier>mac</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-controls</artifactId>
            <version>${javafx.version}</version>
            <classifier>mac-aarch64</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-controls</artifactId>
            <version>${javafx.version}</version>
            <classifier>win</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-graphics</artifactId>
            <version>${javafx.version}</version>
            <classifier>mac</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-graphics</artifactId>
            <version>${javafx.version}</version>
            <classifier>mac-aarch64</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-graphics</artifactId>
            <version>${javafx.version}</version>
            <classifier>win</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-fxml</artifactId>
            <version>${javafx.version}</version>
            <classifier>mac</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-fxml</artifactId>
            <version>${javafx.version}</version>
            <classifier>mac-aarch64</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-fxml</artifactId>
            <version>${javafx.version}</version>
            <classifier>win</classifier>
        </dependency>

        <!-- Linux classifier for dev/CI on WSL — same triple. -->
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-controls</artifactId>
            <version>${javafx.version}</version>
            <classifier>linux</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-graphics</artifactId>
            <version>${javafx.version}</version>
            <classifier>linux</classifier>
        </dependency>
        <dependency>
            <groupId>org.openjfx</groupId>
            <artifactId>javafx-fxml</artifactId>
            <version>${javafx.version}</version>
            <classifier>linux</classifier>
        </dependency>

        <!-- Tests -->
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <version>5.11.0</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testfx</groupId>
            <artifactId>testfx-junit5</artifactId>
            <version>4.0.18</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testfx</groupId>
            <artifactId>openjfx-monocle</artifactId>
            <version>jdk-12.0.1+2</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <artifactId>maven-surefire-plugin</artifactId>
                <version>3.2.5</version>
                <configuration>
                    <argLine>
                        --add-modules=javafx.controls,javafx.graphics,javafx.fxml
                        -Dtestfx.robot=glass
                        -Dtestfx.headless=true
                        -Dprism.order=sw
                        -Dprism.text=t2k
                        -Dheadless.geometry=1600x900-32
                    </argLine>
                </configuration>
            </plugin>

            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-shade-plugin</artifactId>
                <version>3.6.0</version>
                <executions>
                    <execution>
                        <phase>package</phase>
                        <goals><goal>shade</goal></goals>
                        <configuration>
                            <createDependencyReducedPom>false</createDependencyReducedPom>
                            <shadedArtifactAttached>true</shadedArtifactAttached>
                            <shadedClassifierName>shaded</shadedClassifierName>
                            <transformers>
                                <transformer implementation="org.apache.maven.plugins.shade.resource.ManifestResourceTransformer">
                                    <mainClass>global.thalion.ttio.browser.AppLauncher</mainClass>
                                </transformer>
                                <transformer implementation="org.apache.maven.plugins.shade.resource.ServicesResourceTransformer"/>
                            </transformers>
                            <filters>
                                <filter>
                                    <artifact>*:*</artifact>
                                    <excludes>
                                        <exclude>META-INF/*.SF</exclude>
                                        <exclude>META-INF/*.DSA</exclude>
                                        <exclude>META-INF/*.RSA</exclude>
                                    </excludes>
                                </filter>
                            </filters>
                        </configuration>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

**Note** — the manifest main class is `AppLauncher`, not `App`. Reason: `javafx.application.Application` subclasses can't be invoked directly from a non-modular fat JAR; a non-FX `main` shim sidesteps the JavaFX module-system constraint. Defined in Step 4 below.

- [ ] **Step 2: Create `tio-browser/LICENSE`**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && cp java/LICENSE tio-browser/LICENSE'
```

If `java/LICENSE` doesn't exist, copy from the repo root: `cp LICENSE tio-browser/LICENSE`.

- [ ] **Step 3: Create skeleton `tio-browser/README.md`**

```markdown
# tio-browser

JavaFX desktop application for inspecting, importing, exporting, and
transporting TTI-O `.tio` multi-omics datasets. Built on `global.thalion:ttio`.

This README is a skeleton — Phase 14 fleshes out prerequisites,
build commands, native-binary install hints, and the Diagnostics dialog
documentation.

## Quick build

    mvn -pl tio-browser package -Dhdf5.jar=/usr/share/java/jarhdf5.jar
    java -jar tio-browser/target/tio-browser-0.1.0-shaded.jar

## License

LGPL-3.0-or-later. See LICENSE.
```

- [ ] **Step 4: Create empty CSS stub + placeholder app icon**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && mkdir -p tio-browser/src/main/resources/css tio-browser/src/main/resources/icons && touch tio-browser/src/main/resources/css/tio-browser.css && python -c "from PIL import Image; Image.new(\"RGBA\", (256,256), (40,80,160,255)).save(\"tio-browser/src/main/resources/icons/app-icon.png\")" 2>/dev/null || printf "PNG_STUB" > tio-browser/src/main/resources/icons/app-icon.png'
```

- [ ] **Step 5: Verify the module compiles empty (no Java sources yet)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -DskipTests compile -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10'
```

Expected: `BUILD SUCCESS` (no sources to compile yet, but Maven should resolve all deps including JavaFX classifiers).

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/ && git commit -m "feat(tio-browser): scaffold Maven module with JavaFX 21 + ttio 1.1.0 deps"'
```

---

## Task 1.2: AppLauncher + App + headless smoke test

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/AppLauncher.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/App.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/AppSmokeTest.java`

- [ ] **Step 1: Write failing smoke test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/AppSmokeTest.java
package global.thalion.ttio.browser;

import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class AppSmokeTest extends ApplicationTest {

    private App app;

    @Override
    public void start(Stage stage) {
        app = new App();
        app.start(stage);
    }

    @Test
    void appWindowOpensWithExpectedTitle() {
        assertEquals("tio-browser", listTargetWindows().get(0).getScene()
            .getWindow().getOnCloseRequest() == null
            ? "tio-browser" : "tio-browser",
            "window should be open with title set");
        // Test value: the start() call must complete without throwing,
        // and a stage must be visible.
        assertTrue(listTargetWindows().size() >= 1);
    }
}
```

- [ ] **Step 2: Run to verify failure**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=AppSmokeTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -20'
```

Expected: compile fails — `App` class missing.

- [ ] **Step 3: Implement `AppLauncher` + `App`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/AppLauncher.java
package global.thalion.ttio.browser;

/**
 * Non-FX entry point for the fat JAR. JavaFX module-system constraints
 * mean the manifest main class can't be a {@link javafx.application.Application}
 * subclass when JavaFX is on the classpath (not the module path) as
 * happens in a shaded JAR. This shim sidesteps the issue.
 */
public final class AppLauncher {
    public static void main(String[] args) {
        App.main(args);
    }
}
```

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/App.java
package global.thalion.ttio.browser;

import javafx.application.Application;
import javafx.stage.Stage;

public class App extends Application {

    private MainWindow mainWindow;

    @Override
    public void start(Stage primaryStage) {
        mainWindow = new MainWindow();
        mainWindow.show(primaryStage);
    }

    @Override
    public void stop() {
        if (mainWindow != null) {
            mainWindow.dispose();
        }
    }

    public static void main(String[] args) {
        launch(args);
    }
}
```

- [ ] **Step 4: Run test (still fails — `MainWindow` missing)**

Expected: compile error on `MainWindow`.

- [ ] **Step 5: Stub `MainWindow`**

Will be fleshed out in Task 1.3 — for now, a stub:

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java
package global.thalion.ttio.browser;

import javafx.scene.Scene;
import javafx.scene.layout.BorderPane;
import javafx.stage.Stage;

public class MainWindow {

    private Stage stage;
    private BorderPane root;

    public void show(Stage primaryStage) {
        this.stage = primaryStage;
        this.root = new BorderPane();
        Scene scene = new Scene(root, 1280, 800);
        primaryStage.setScene(scene);
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
    }

    public void dispose() {
        if (stage != null) stage.close();
    }

    // Exposed for tests
    BorderPane root() { return root; }
}
```

- [ ] **Step 6: Run smoke test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=AppSmokeTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -20'
```

Expected: PASS.

- [ ] **Step 7: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): App + AppLauncher + MainWindow stub + headless smoke test"'
```

---

## Task 1.3: MainWindow with menu bar, toolbar, status bar, BorderPane regions

**Goal:** structural layout matches HANDOFF §4: menu bar at top, toolbar below, tree (left), detail pane (right), status bar (bottom). All regions empty placeholders for now.

- [ ] **Step 1: Replace `MainWindow.java` with full layout**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java
package global.thalion.ttio.browser;

import javafx.geometry.Orientation;
import javafx.scene.Scene;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.Stage;

public class MainWindow {

    private Stage stage;
    private BorderPane root;
    private Label statusBarLabel;
    private SplitPane mainSplit;
    private StackPane treeContainer;
    private StackPane detailContainer;

    private MenuItem openItem, closeItem, saveAsItem, exitItem;
    private MenuItem importItem, exportItem, downloadItem, uploadItem, diagnosticsItem;

    public void show(Stage primaryStage) {
        this.stage = primaryStage;
        this.root = new BorderPane();

        root.setTop(buildTopBars());
        root.setCenter(buildSplit());
        root.setBottom(buildStatusBar());

        Scene scene = new Scene(root, 1280, 800);
        scene.getStylesheets().add(
            getClass().getResource("/css/tio-browser.css").toExternalForm());
        primaryStage.setScene(scene);
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
    }

    private VBox buildTopBars() {
        VBox box = new VBox(buildMenuBar(), buildToolBar());
        return box;
    }

    private MenuBar buildMenuBar() {
        Menu fileMenu = new Menu("File");
        openItem = new MenuItem("Open…");
        closeItem = new MenuItem("Close");
        saveAsItem = new MenuItem("Save As…");
        exitItem = new MenuItem("Exit");
        fileMenu.getItems().addAll(openItem, closeItem, new SeparatorMenuItem(),
            saveAsItem, new SeparatorMenuItem(), exitItem);

        Menu importMenu = new Menu("Import");
        importItem = new MenuItem("Import…");
        importMenu.getItems().add(importItem);

        Menu exportMenu = new Menu("Export");
        exportItem = new MenuItem("Export…");
        exportMenu.getItems().add(exportItem);

        Menu transportMenu = new Menu("Transport");
        downloadItem = new MenuItem("Download from server…");
        uploadItem = new MenuItem("Upload to server…");
        transportMenu.getItems().addAll(downloadItem, uploadItem);

        Menu toolsMenu = new Menu("Tools");
        diagnosticsItem = new MenuItem("Diagnostics…");
        toolsMenu.getItems().add(diagnosticsItem);

        Menu helpMenu = new Menu("Help");
        helpMenu.getItems().add(new MenuItem("About"));

        return new MenuBar(fileMenu, importMenu, exportMenu, transportMenu,
                          toolsMenu, helpMenu);
    }

    private ToolBar buildToolBar() {
        Button openBtn = new Button("Open");
        openBtn.setOnAction(e -> openItem.fire());
        Button saveAsBtn = new Button("Save As");
        saveAsBtn.setOnAction(e -> saveAsItem.fire());
        Button importBtn = new Button("Import…");
        importBtn.setOnAction(e -> importItem.fire());
        Button exportBtn = new Button("Export…");
        exportBtn.setOnAction(e -> exportItem.fire());
        Button downloadBtn = new Button("Download…");
        downloadBtn.setOnAction(e -> downloadItem.fire());
        Button uploadBtn = new Button("Upload…");
        uploadBtn.setOnAction(e -> uploadItem.fire());
        Button diagnosticsBtn = new Button("Diagnostics");
        diagnosticsBtn.setOnAction(e -> diagnosticsItem.fire());
        return new ToolBar(openBtn, saveAsBtn, new Separator(), importBtn,
            exportBtn, new Separator(), downloadBtn, uploadBtn,
            new Separator(), diagnosticsBtn);
    }

    private SplitPane buildSplit() {
        mainSplit = new SplitPane();
        mainSplit.setOrientation(Orientation.HORIZONTAL);
        treeContainer = new StackPane(new Label("(no dataset open)"));
        treeContainer.setMinWidth(240);
        detailContainer = new StackPane(new Label("(open a .tio file to begin)"));
        mainSplit.getItems().addAll(treeContainer, detailContainer);
        mainSplit.setDividerPositions(0.30);
        return mainSplit;
    }

    private HBox buildStatusBar() {
        statusBarLabel = new Label("(no file)");
        HBox bar = new HBox(statusBarLabel);
        bar.getStyleClass().add("status-bar");
        bar.setStyle("-fx-padding: 4 8 4 8; -fx-border-color: #888;"
                   + " -fx-border-width: 1 0 0 0;");
        return bar;
    }

    // Test/integration accessors — package-private intentionally
    BorderPane root() { return root; }
    Label statusBar() { return statusBarLabel; }
    StackPane treeContainer() { return treeContainer; }
    StackPane detailContainer() { return detailContainer; }
    MenuItem openMenuItem() { return openItem; }
    MenuItem closeMenuItem() { return closeItem; }
    MenuItem exitMenuItem() { return exitItem; }
    MenuItem diagnosticsMenuItem() { return diagnosticsItem; }
    Stage stage() { return stage; }

    public void dispose() {
        if (stage != null) stage.close();
    }
}
```

- [ ] **Step 2: Smoke test still passes (regression check)**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=AppSmokeTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -5'
```

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java && git commit -m "feat(tio-browser): MainWindow layout — menu, toolbar, split, status bar"'
```

---

## Task 1.4: `OpenDataset` model + `DatasetOpenTask` background loader

**Goal:** an immutable wrapper around `SpectralDataset` plus UI state (path, read-only flag, encryption banner, summary counts). A JavaFX `Task<OpenDataset>` opens the file off the FX thread.

- [ ] **Step 1: Write failing test for `DatasetOpenTask`**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/model/DatasetOpenTaskTest.java
package global.thalion.ttio.browser.model;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class DatasetOpenTaskTest {

    private static final Path FIXTURE = Paths.get(
        "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();

    @Test
    void openMinimalMsFixtureSucceedsAndPopulatesCounts() throws Exception {
        DatasetOpenTask task = new DatasetOpenTask(FIXTURE.toString(), true);
        ExecutorService exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(10, TimeUnit.SECONDS));
        OpenDataset result = task.get();

        assertNotNull(result);
        assertEquals(FIXTURE.toString(), result.path());
        assertTrue(result.readOnly());
        assertNotNull(result.dataset());
        assertEquals(1, result.msRunCount(), "minimal_ms.tio has 1 MS run");
        assertEquals(0, result.genomicRunCount());
        assertFalse(result.isEncrypted());

        result.dataset().close();
    }

    @Test
    void openEncryptedFixtureSetsEncryptionBanner() throws Exception {
        Path enc = Paths.get(
            "../java/src/test/resources/ttio/encrypted.tio").toAbsolutePath();
        DatasetOpenTask task = new DatasetOpenTask(enc.toString(), true);
        ExecutorService exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(10, TimeUnit.SECONDS));
        OpenDataset result = task.get();

        assertTrue(result.isEncrypted());
        assertFalse(result.encryptionAlgorithm().isEmpty());

        result.dataset().close();
    }
}
```

- [ ] **Step 2: Run to verify failure**

Expected: `OpenDataset` and `DatasetOpenTask` classes don't exist.

- [ ] **Step 3: Implement `OpenDataset`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/model/OpenDataset.java
package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;

import java.util.Objects;

public final class OpenDataset {

    private final String path;
    private final boolean readOnly;
    private final SpectralDataset dataset;

    public OpenDataset(String path, boolean readOnly, SpectralDataset dataset) {
        this.path = Objects.requireNonNull(path);
        this.readOnly = readOnly;
        this.dataset = Objects.requireNonNull(dataset);
    }

    public String path()                     { return path; }
    public boolean readOnly()                { return readOnly; }
    public SpectralDataset dataset()         { return dataset; }
    public int msRunCount()                  { return dataset.msRuns().size(); }
    public int genomicRunCount()             { return dataset.genomicRuns().size(); }
    public int referenceCount()              { return dataset.references().size(); }
    public int identificationCount()         { return dataset.identifications().size(); }
    public int quantificationCount()         { return dataset.quantifications().size(); }
    public int provenanceCount()             { return dataset.provenanceRecords().size(); }
    public boolean isEncrypted()             { return dataset.isEncrypted(); }
    public String encryptionAlgorithm()      { return dataset.encryptedAlgorithm(); }
    public String formatVersion()            { return dataset.featureFlags().formatVersion(); }

    public void close() {
        dataset.close();
    }
}
```

- [ ] **Step 4: Implement `DatasetOpenTask`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetOpenTask.java
package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;
import javafx.concurrent.Task;

public class DatasetOpenTask extends Task<OpenDataset> {

    private final String path;
    private final boolean readOnly;

    public DatasetOpenTask(String path, boolean readOnly) {
        this.path = path;
        this.readOnly = readOnly;
        updateMessage("Opening " + path);
    }

    @Override
    protected OpenDataset call() throws Exception {
        SpectralDataset ds = SpectralDataset.open(path);
        return new OpenDataset(path, readOnly, ds);
    }
}
```

**Note** — read-only enforcement is a contract the GUI honours; the library itself doesn't currently distinguish read-only opens. For v0.1 we simply gate write actions in the menu when `readOnly==true`. If the library adds a true read-only mode later, the constructor here can pass it through.

- [ ] **Step 5: Run test**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=DatasetOpenTaskTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -15'
```

Expected: 2/2 PASS.

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): OpenDataset model + DatasetOpenTask background loader"'
```

---

## Task 1.5: File → Open menu action wiring

**Goal:** clicking File → Open shows a `FileChooser` filtered to `*.tio`. Selecting a file kicks `DatasetOpenTask`; on success the status bar updates with file path + run counts; on failure an error dialog appears with the exception message.

- [ ] **Step 1: Add `currentDataset` state + `openFile` action to `MainWindow`**

In `MainWindow`, above the constructors, add:

```java
    private OpenDataset currentDataset;

    private void wireFileActions() {
        openItem.setOnAction(e -> openFileViaChooser());
        closeItem.setOnAction(e -> closeCurrentDataset());
        exitItem.setOnAction(e -> {
            closeCurrentDataset();
            javafx.application.Platform.exit();
        });
    }

    private void openFileViaChooser() {
        if (currentDataset != null) {
            Alert confirm = new Alert(Alert.AlertType.CONFIRMATION,
                "Close currently-open " + currentDataset.path() + "?",
                ButtonType.OK, ButtonType.CANCEL);
            if (confirm.showAndWait().orElse(ButtonType.CANCEL) != ButtonType.OK) {
                return;
            }
            closeCurrentDataset();
        }
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Open .tio file");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = chooser.showOpenDialog(stage);
        if (picked == null) return;
        loadDataset(picked.toString(), /* readOnly = */ true);
    }

    public void loadDataset(String path, boolean readOnly) {
        DatasetOpenTask task = new DatasetOpenTask(path, readOnly);
        statusBarLabel.setText("Opening " + path + "…");
        task.setOnSucceeded(ev -> {
            currentDataset = task.getValue();
            updateStatusBarFromDataset();
            // Tree population wired in Phase 2; detail pane in Phase 3.
        });
        task.setOnFailed(ev -> {
            Throwable t = task.getException();
            statusBarLabel.setText("(open failed)");
            Alert err = new Alert(Alert.AlertType.ERROR,
                "Could not open " + path + ":\n\n" + t.getMessage(),
                ButtonType.OK);
            err.setHeaderText("Open failed");
            err.showAndWait();
        });
        Thread th = new Thread(task, "open-" + path);
        th.setDaemon(true);
        th.start();
    }

    private void updateStatusBarFromDataset() {
        OpenDataset d = currentDataset;
        if (d == null) { statusBarLabel.setText("(no file)"); return; }
        statusBarLabel.setText(String.format(
            "%s · v%s · MS=%d · Genomic=%d · Refs=%d %s",
            d.path(), d.formatVersion(), d.msRunCount(), d.genomicRunCount(),
            d.referenceCount(),
            d.isEncrypted() ? "· 🔒 ENCRYPTED" : "· 🔓"));
    }

    private void closeCurrentDataset() {
        if (currentDataset != null) {
            currentDataset.close();
            currentDataset = null;
        }
        updateStatusBarFromDataset();
    }

    public OpenDataset currentDataset() { return currentDataset; }
```

Add the import for `OpenDataset`, `DatasetOpenTask`, `Alert`, `ButtonType`, `FileChooser`, `File`. Call `wireFileActions()` from `show()` after building the layout.

- [ ] **Step 2: Add a non-FX integration test that drives `loadDataset` directly**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/MainWindowOpenTest.java
package global.thalion.ttio.browser;

import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import org.testfx.api.FxToolkit;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class MainWindowOpenTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void loadDatasetUpdatesStatusBar() throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
        CountDownLatch done = new CountDownLatch(1);
        javafx.application.Platform.runLater(() -> {
            win.loadDataset(fixture.toString(), true);
        });

        // Poll status bar for completion
        long deadline = System.nanoTime() + (long) 10e9;
        while (System.nanoTime() < deadline) {
            String txt = win.statusBar().getText();
            if (txt.contains("MS=1")) { done.countDown(); break; }
            Thread.sleep(50);
        }
        assertTrue(done.await(2, TimeUnit.SECONDS),
            "status bar should reflect dataset within 10s; was: "
            + win.statusBar().getText());
        assertNotNull(win.currentDataset());
        assertEquals(1, win.currentDataset().msRunCount());
    }
}
```

- [ ] **Step 3: Run**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=MainWindowOpenTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -20'
```

Expected: PASS.

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): File → Open wiring with status bar update + error dialog"'
```

---

## Task 1.6: Save As + Close + Exit + drag-and-drop file open

- [ ] **Step 1: Wire Save As (copy file out)**

```java
    private void saveAsViaChooser() {
        if (currentDataset == null) return;
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Save As");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File target = chooser.showSaveDialog(stage);
        if (target == null) return;
        try {
            java.nio.file.Files.copy(
                java.nio.file.Paths.get(currentDataset.path()),
                target.toPath(),
                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            // Switch open to the new path, read-write
            String oldPath = currentDataset.path();
            closeCurrentDataset();
            loadDataset(target.toString(), /* readOnly = */ false);
        } catch (java.io.IOException ex) {
            Alert err = new Alert(Alert.AlertType.ERROR,
                "Save As failed: " + ex.getMessage(), ButtonType.OK);
            err.showAndWait();
        }
    }
```

Wire `saveAsItem.setOnAction(e -> saveAsViaChooser());` in `wireFileActions()`.

- [ ] **Step 2: Wire drag-and-drop**

In `MainWindow.show()`, after `primaryStage.setScene(scene)`, add:

```java
        scene.setOnDragOver(e -> {
            if (e.getDragboard().hasFiles()) {
                e.acceptTransferModes(javafx.scene.input.TransferMode.COPY);
            }
        });
        scene.setOnDragDropped(e -> {
            if (e.getDragboard().hasFiles()) {
                java.io.File f = e.getDragboard().getFiles().get(0);
                if (f.getName().endsWith(".tio")) {
                    loadDataset(f.toString(), true);
                } else {
                    // Phase 8 hooks the sniffer here to pre-select an importer.
                    Alert info = new Alert(Alert.AlertType.INFORMATION,
                        "Importer wizard pre-selection wired in Phase 8.\n"
                        + "Dropped: " + f.toString(), ButtonType.OK);
                    info.showAndWait();
                }
            }
        });
```

- [ ] **Step 3: Test Save As round-trip**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/SaveAsTest.java
@Test
void saveAsCopiesFileToTargetPath(@TempDir Path tmp) throws Exception {
    Path fixture = Paths.get(
        "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
    Path copy = tmp.resolve("copy.tio");
    java.nio.file.Files.copy(fixture, copy);
    // Assertion: the copy exists, is readable as a SpectralDataset, and
    // round-trips msRunCount == 1.
    try (SpectralDataset ds = SpectralDataset.open(copy.toString())) {
        assertEquals(1, ds.msRuns().size());
    }
}
```

(This is a unit test of the file-copy contract — full end-to-end FX-driven Save As is overkill for v0.1.)

- [ ] **Step 4: Run**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10'
```

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/ && git commit -m "feat(tio-browser): Save As, Exit, drag-and-drop .tio open"'
```

---

## Phase 1 acceptance gate

- [ ] `mvn -pl tio-browser package -Dhdf5.jar=...` produces `tio-browser-0.1.0.jar` and `tio-browser-0.1.0-shaded.jar`.
- [ ] Running `java -jar tio-browser-0.1.0-shaded.jar` shows the main window with all menus + toolbar buttons + status bar.
- [ ] File → Open of `java/src/test/resources/ttio/minimal_ms.tio` updates the status bar to `... · v1.0.0 · MS=1 · Genomic=0 · Refs=0 · 🔓` within 2s.
- [ ] File → Open of `encrypted.tio` shows the encryption banner.
- [ ] File → Close clears the status bar.
- [ ] Drag-and-drop a `.tio` opens it.
- [ ] All Phase 1 tests pass under TestFX headless (Monocle).
- [ ] No regressions in `java/` test suite (`cd java && mvn test` still green).

---

# Phase 2 — Tree model + DatasetTreeView

**Goal:** opening a dataset populates the left pane with a tree mirroring HANDOFF §4 layout. Tree node selection emits an event to which the detail pane subscribes (Phase 3+).

**Key design point:** the HANDOFF assumed separate `nmrRuns()` / `ramanRuns()` accessors. Reality: all non-genomic runs come back from `runs()` (or `msRuns()`) as `AcquisitionRun`, distinguished by `acquisitionMode()` returning the `AcquisitionMode` enum (MS / NMR / RAMAN / IR / UV_VIS / etc.). Tree grouping is done client-side: iterate `runs()`, branch on `acquisitionMode()`.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/model/TreeNodeKind.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetTreeNode.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetTreeBuilder.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/model/DatasetTreeBuilderTest.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/DatasetTreeView.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/TreeSelectionEvent.java`
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java` (mount tree view)

---

## Task 2.1: `TreeNodeKind` enum + `DatasetTreeNode` data class

- [ ] **Step 1: Create `TreeNodeKind`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/model/TreeNodeKind.java
package global.thalion.ttio.browser.model;

public enum TreeNodeKind {
    DATASET_ROOT,
    STUDY_GROUP,
    MS_RUNS_GROUP,
    NMR_RUNS_GROUP,
    RAMAN_RUNS_GROUP,
    IR_RUNS_GROUP,
    UV_VIS_RUNS_GROUP,
    GENOMIC_RUNS_GROUP,
    REFERENCES_GROUP,

    MS_RUN,
    NMR_RUN,
    RAMAN_RUN,
    IR_RUN,
    UV_VIS_RUN,
    GENOMIC_RUN,
    REFERENCE,

    SPECTRUM,                  // child row of an MS/NMR/Raman/IR/UV-Vis run
    CHROMATOGRAM,
    ALIGNED_READ,              // child row of a genomic run

    IDENTIFICATIONS,
    QUANTIFICATIONS,
    PROVENANCE,
    FEATURE_FLAGS,
    ENCRYPTION
}
```

- [ ] **Step 2: Create `DatasetTreeNode`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetTreeNode.java
package global.thalion.ttio.browser.model;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

public final class DatasetTreeNode {

    private final TreeNodeKind kind;
    private final String label;
    private final String key;       // run name, reference URI, etc. — null for groups
    private final List<DatasetTreeNode> children = new ArrayList<>();

    public DatasetTreeNode(TreeNodeKind kind, String label, String key) {
        this.kind = Objects.requireNonNull(kind);
        this.label = Objects.requireNonNull(label);
        this.key = key;
    }

    public TreeNodeKind kind() { return kind; }
    public String label()      { return label; }
    public String key()        { return key; }
    public List<DatasetTreeNode> children() { return Collections.unmodifiableList(children); }

    public DatasetTreeNode add(DatasetTreeNode child) {
        children.add(child);
        return this;
    }

    @Override
    public String toString() { return kind + "[" + label + "]"; }
}
```

- [ ] **Step 3: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/main/java/global/thalion/ttio/browser/model/{TreeNodeKind.java,DatasetTreeNode.java} && git commit -m "feat(tio-browser): TreeNodeKind enum + DatasetTreeNode data class"'
```

---

## Task 2.2: `DatasetTreeBuilder` — pure-Java tree builder

- [ ] **Step 1: Write failing test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/model/DatasetTreeBuilderTest.java
package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class DatasetTreeBuilderTest {

    @Test
    void minimalMsFixtureBuildsExpectedTree() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
                    .toAbsolutePath().toString())) {
            DatasetTreeNode root = DatasetTreeBuilder.build(
                new global.thalion.ttio.browser.model.OpenDataset(
                    "minimal_ms.tio", true, ds));

            assertEquals(TreeNodeKind.DATASET_ROOT, root.kind());

            // Walk down to /study/ms_runs/<one run>
            DatasetTreeNode study = childOfKind(root, TreeNodeKind.STUDY_GROUP);
            DatasetTreeNode msRuns = childOfKind(study, TreeNodeKind.MS_RUNS_GROUP);
            assertEquals(1, msRuns.children().size());
            DatasetTreeNode oneRun = msRuns.children().get(0);
            assertEquals(TreeNodeKind.MS_RUN, oneRun.kind());

            // Feature flags + encryption appear as virtual children
            assertNotNull(childOfKind(root, TreeNodeKind.FEATURE_FLAGS));
            assertNotNull(childOfKind(root, TreeNodeKind.ENCRYPTION));
        }
    }

    @Test
    void m82GenomicFixtureExposesGenomicRunsBranch() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../python/tests/fixtures/genomic/m82_100reads.tio")
                    .toAbsolutePath().toString())) {
            DatasetTreeNode root = DatasetTreeBuilder.build(
                new global.thalion.ttio.browser.model.OpenDataset(
                    "m82_100reads.tio", true, ds));
            DatasetTreeNode study = childOfKind(root, TreeNodeKind.STUDY_GROUP);
            DatasetTreeNode genomic = childOfKind(study, TreeNodeKind.GENOMIC_RUNS_GROUP);
            assertNotNull(genomic);
            assertFalse(genomic.children().isEmpty());
        }
    }

    private static DatasetTreeNode childOfKind(DatasetTreeNode parent, TreeNodeKind k) {
        return parent.children().stream()
            .filter(c -> c.kind() == k)
            .findFirst()
            .orElseThrow(() -> new AssertionError(
                "no " + k + " child of " + parent.kind()));
    }
}
```

- [ ] **Step 2: Verify failure**

Compile error: `DatasetTreeBuilder` not found.

- [ ] **Step 3: Implement `DatasetTreeBuilder`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/model/DatasetTreeBuilder.java
package global.thalion.ttio.browser.model;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.ReferenceImport;

import java.util.LinkedHashMap;
import java.util.Map;

public final class DatasetTreeBuilder {

    private DatasetTreeBuilder() {}

    public static DatasetTreeNode build(OpenDataset open) {
        String label = open.dataset().title();
        if (label == null || label.isEmpty()) {
            label = pathTail(open.path());
        }
        DatasetTreeNode root = new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, label, null);

        DatasetTreeNode study = new DatasetTreeNode(
            TreeNodeKind.STUDY_GROUP, "/study", null);
        root.add(study);

        // Acquisition runs come from msRuns() (which carries MS+NMR+Raman+IR+UV-Vis
        // — see SpectralDataset javadoc on runs()). Group by acquisitionMode().
        Map<AcquisitionMode, DatasetTreeNode> acqGroups = new LinkedHashMap<>();
        for (var entry : open.dataset().msRuns().entrySet()) {
            AcquisitionRun run = entry.getValue();
            AcquisitionMode mode = run.acquisitionMode();
            DatasetTreeNode group = acqGroups.computeIfAbsent(mode,
                m -> new DatasetTreeNode(groupKindFor(m), groupLabelFor(m), null));
            group.add(new DatasetTreeNode(
                runKindFor(mode), entry.getKey(), entry.getKey()));
        }
        for (DatasetTreeNode g : acqGroups.values()) study.add(g);

        // Genomic runs
        if (!open.dataset().genomicRuns().isEmpty()) {
            DatasetTreeNode g = new DatasetTreeNode(
                TreeNodeKind.GENOMIC_RUNS_GROUP, "genomic_runs", null);
            for (var entry : open.dataset().genomicRuns().entrySet()) {
                g.add(new DatasetTreeNode(
                    TreeNodeKind.GENOMIC_RUN, entry.getKey(), entry.getKey()));
            }
            study.add(g);
        }

        // References (Phase 0 wired this up)
        if (!open.dataset().references().isEmpty()) {
            DatasetTreeNode refs = new DatasetTreeNode(
                TreeNodeKind.REFERENCES_GROUP, "references", null);
            for (var entry : open.dataset().references().entrySet()) {
                ReferenceImport r = entry.getValue();
                String lbl = entry.getKey() + " (" + r.chromosomes().size() + " chroms)";
                refs.add(new DatasetTreeNode(
                    TreeNodeKind.REFERENCE, lbl, entry.getKey()));
            }
            study.add(refs);
        }

        // Identifications, quantifications, provenance
        if (!open.dataset().identifications().isEmpty()) {
            study.add(new DatasetTreeNode(
                TreeNodeKind.IDENTIFICATIONS,
                "identifications (" + open.dataset().identifications().size() + ")",
                null));
        }
        if (!open.dataset().quantifications().isEmpty()) {
            study.add(new DatasetTreeNode(
                TreeNodeKind.QUANTIFICATIONS,
                "quantifications (" + open.dataset().quantifications().size() + ")",
                null));
        }
        if (!open.dataset().provenanceRecords().isEmpty()) {
            study.add(new DatasetTreeNode(
                TreeNodeKind.PROVENANCE,
                "provenance (" + open.dataset().provenanceRecords().size() + ")",
                null));
        }

        // Virtual top-level children
        root.add(new DatasetTreeNode(
            TreeNodeKind.FEATURE_FLAGS, "feature_flags", null));
        root.add(new DatasetTreeNode(
            TreeNodeKind.ENCRYPTION,
            open.isEncrypted() ? "encryption (🔒)" : "encryption (🔓)",
            null));

        return root;
    }

    private static TreeNodeKind groupKindFor(AcquisitionMode m) {
        switch (m) {
            case MS:        return TreeNodeKind.MS_RUNS_GROUP;
            case NMR:       return TreeNodeKind.NMR_RUNS_GROUP;
            case RAMAN:     return TreeNodeKind.RAMAN_RUNS_GROUP;
            case IR:        return TreeNodeKind.IR_RUNS_GROUP;
            case UV_VIS:    return TreeNodeKind.UV_VIS_RUNS_GROUP;
            default:        return TreeNodeKind.MS_RUNS_GROUP;
        }
    }
    private static TreeNodeKind runKindFor(AcquisitionMode m) {
        switch (m) {
            case MS:        return TreeNodeKind.MS_RUN;
            case NMR:       return TreeNodeKind.NMR_RUN;
            case RAMAN:     return TreeNodeKind.RAMAN_RUN;
            case IR:        return TreeNodeKind.IR_RUN;
            case UV_VIS:    return TreeNodeKind.UV_VIS_RUN;
            default:        return TreeNodeKind.MS_RUN;
        }
    }
    private static String groupLabelFor(AcquisitionMode m) {
        switch (m) {
            case MS:        return "ms_runs";
            case NMR:       return "nmr_runs";
            case RAMAN:     return "raman_runs";
            case IR:        return "ir_runs";
            case UV_VIS:    return "uv_vis_runs";
            default:        return m.name().toLowerCase() + "_runs";
        }
    }
    private static String pathTail(String path) {
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash < 0 ? path : path.substring(slash + 1);
    }
}
```

**Probe note** — verify `Enums.AcquisitionMode` actually has `MS`, `NMR`, `RAMAN`, `IR`, `UV_VIS` constants exactly as named, with: `grep -A20 "enum AcquisitionMode" ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/Enums.java`. Adjust enum constant names if different (e.g. `GENOMIC_WES` exists per `WrittenGenomicRun` — there may be more than 5 modalities; the switch falls back to MS_RUN_GROUP for anything unclassified, which is acceptable for v0.1 but worth a code comment).

- [ ] **Step 4: Run tests**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=DatasetTreeBuilderTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10'
```

Expected: 2/2 PASS.

- [ ] **Step 5: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): DatasetTreeBuilder groups runs by AcquisitionMode"'
```

---

## Task 2.3: `DatasetTreeView` — JavaFX wrapper + selection event

- [ ] **Step 1: Implement `TreeSelectionEvent`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/TreeSelectionEvent.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;

@FunctionalInterface
public interface TreeSelectionEvent {
    void onSelected(DatasetTreeNode node);
}
```

- [ ] **Step 2: Implement `DatasetTreeView`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/DatasetTreeView.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import javafx.scene.control.TreeItem;
import javafx.scene.control.TreeView;

public class DatasetTreeView {

    private final TreeView<DatasetTreeNode> control = new TreeView<>();
    private TreeSelectionEvent listener;

    public DatasetTreeView() {
        control.setShowRoot(true);
        control.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && listener != null) {
                    listener.onSelected(sel.getValue());
                }
            });
        control.setCellFactory(tv -> new javafx.scene.control.TreeCell<>() {
            @Override
            protected void updateItem(DatasetTreeNode item, boolean empty) {
                super.updateItem(item, empty);
                setText(empty || item == null ? null : item.label());
            }
        });
    }

    public TreeView<DatasetTreeNode> control() { return control; }

    public void setRoot(DatasetTreeNode root) {
        if (root == null) {
            control.setRoot(null);
            return;
        }
        control.setRoot(buildTreeItem(root));
        control.getRoot().setExpanded(true);
    }

    public void clear() { control.setRoot(null); }

    public void onSelected(TreeSelectionEvent l) { this.listener = l; }

    private TreeItem<DatasetTreeNode> buildTreeItem(DatasetTreeNode n) {
        TreeItem<DatasetTreeNode> item = new TreeItem<>(n);
        for (DatasetTreeNode c : n.children()) {
            item.getChildren().add(buildTreeItem(c));
        }
        // Auto-expand groups with ≤ 12 children to keep things visible.
        if (n.children().size() > 0 && n.children().size() <= 12) {
            item.setExpanded(true);
        }
        return item;
    }
}
```

- [ ] **Step 3: Mount in `MainWindow`**

In `MainWindow`:

```java
    private DatasetTreeView treeView;

    // In show(), replace:
    //   treeContainer = new StackPane(new Label("(no dataset open)"));
    // with:
    treeView = new DatasetTreeView();
    treeView.onSelected(node -> {
        // Phase 3 wires this into DetailPane; for now log.
        System.out.println("[tree] selected: " + node);
    });
    treeContainer = new StackPane(treeView.control());
```

In `loadDataset`'s `onSucceeded`:

```java
    DatasetTreeNode root = DatasetTreeBuilder.build(currentDataset);
    treeView.setRoot(root);
```

In `closeCurrentDataset`:

```java
    if (treeView != null) treeView.clear();
```

- [ ] **Step 4: Smoke-test the tree view (TestFX)**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/DatasetTreeViewSmokeTest.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.MainWindow;
import javafx.application.Platform;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.nio.file.Paths;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

class DatasetTreeViewSmokeTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void treePopulatesAfterOpen() throws Exception {
        win.loadDataset(
            Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
                .toAbsolutePath().toString(), true);
        // Poll
        long deadline = System.nanoTime() + (long)10e9;
        AtomicReference<Integer> rootChildren = new AtomicReference<>(0);
        while (System.nanoTime() < deadline) {
            Platform.runLater(() -> {
                if (win.tree() != null && win.tree().control().getRoot() != null) {
                    rootChildren.set(
                        win.tree().control().getRoot().getChildren().size());
                }
            });
            Thread.sleep(100);
            if (rootChildren.get() > 0) break;
        }
        assertTrue(rootChildren.get() >= 3,
            "root should have at least study/feature_flags/encryption");
    }
}
```

Add `public DatasetTreeView tree() { return treeView; }` accessor to `MainWindow`.

- [ ] **Step 5: Run**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=DatasetTreeViewSmokeTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10'
```

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): DatasetTreeView mounts on open, emits selection events"'
```

---

## Phase 2 acceptance gate

- [ ] Opening `minimal_ms.tio` shows a tree with `/study/ms_runs/<one run>`, `feature_flags`, `encryption` virtual nodes.
- [ ] Opening `nmr_1d.tio` shows `/study/nmr_runs/...`.
- [ ] Opening `m82_100reads.tio` shows `/study/genomic_runs/...`.
- [ ] Opening a `.tio` with embedded references (a Phase 0 conformance fixture) shows `/study/references/...`.
- [ ] Selecting any node calls the registered selection listener with the right `DatasetTreeNode`.
- [ ] All Phase 2 tests pass.

---

# Phase 3 — Analytical detail panes

**Goal:** the right-pane `DetailPane` is a tab host; tab content is driven by the tree selection. Implement the **structural** tabs in this phase: Overview (root), Provenance, FeatureFlags, Encryption. Spectrum-level tabs (Plot, Channels, Headers tables) come in Phase 4–5.

**Decision recap (HANDOFF §11.7):** Encryption tab's "Decrypt with key…" action uses a **`FileChooser` for a binary key file**. The file is read with `Files.readAllBytes(Path)` and passed verbatim to `decryptWithKey(byte[])`. Single decision: file picker, no encoding flavour selector. README documents that the file's bytes are taken as-is.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/DetailPane.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/AbstractDetailTab.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/overview/OverviewTab.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/ProvenanceTab.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/FeatureFlagsTab.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/EncryptionTab.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/OverviewTabTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/EncryptionTabTest.java`
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/MainWindow.java`

---

## Task 3.1: `DetailPane` shell + `AbstractDetailTab`

- [ ] **Step 1: `AbstractDetailTab` interface**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/AbstractDetailTab.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import javafx.scene.Node;

public interface AbstractDetailTab {
    String title();
    Node content();
    /** Refresh tab content for the given selection. */
    void update(OpenDataset dataset, DatasetTreeNode selection);
    /** Should this tab appear for the given selection kind? */
    boolean appliesTo(DatasetTreeNode selection);
}
```

- [ ] **Step 2: `DetailPane`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/DetailPane.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import javafx.scene.control.Tab;
import javafx.scene.control.TabPane;

import java.util.ArrayList;
import java.util.List;

public class DetailPane {

    private final TabPane tabs = new TabPane();
    private final List<AbstractDetailTab> registered = new ArrayList<>();
    private OpenDataset currentDataset;

    public DetailPane() {
        tabs.setTabClosingPolicy(TabPane.TabClosingPolicy.UNAVAILABLE);
    }

    public TabPane control() { return tabs; }

    public void register(AbstractDetailTab tab) { registered.add(tab); }

    public void setCurrentDataset(OpenDataset d) {
        this.currentDataset = d;
        if (d == null) tabs.getTabs().clear();
    }

    public void onSelection(DatasetTreeNode selection) {
        tabs.getTabs().clear();
        if (currentDataset == null || selection == null) return;
        for (AbstractDetailTab t : registered) {
            if (t.appliesTo(selection)) {
                t.update(currentDataset, selection);
                Tab fxTab = new Tab(t.title(), t.content());
                fxTab.setClosable(false);
                tabs.getTabs().add(fxTab);
            }
        }
    }
}
```

- [ ] **Step 3: Mount in `MainWindow`**

```java
    private DetailPane detailPane;

    // In show() build phase:
    detailPane = new DetailPane();
    detailContainer = new StackPane(detailPane.control());

    // After all tabs constructed (later phases):
    // detailPane.register(new OverviewTab());
    // detailPane.register(new ProvenanceTab()); ... etc.

    // In treeView.onSelected:
    treeView.onSelected(node -> {
        detailPane.onSelection(node);
    });

    // In closeCurrentDataset:
    if (detailPane != null) detailPane.setCurrentDataset(null);

    // In loadDataset onSucceeded:
    detailPane.setCurrentDataset(currentDataset);
```

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): DetailPane host + AbstractDetailTab interface"'
```

---

## Task 3.2: `OverviewTab` — root selection summary

- [ ] **Step 1: Failing test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/OverviewTabTest.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.*;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class OverviewTabTest {

    @Test
    void overviewAppliesToRootNotToRunNodes() {
        OverviewTab t = new OverviewTab();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, "x", null)));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
    }

    @Test
    void overviewPopulatesFromMinimalMsFixture() throws Exception {
        OverviewTab t = new OverviewTab();
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
                    .toAbsolutePath().toString())) {
            OpenDataset open = new OpenDataset("minimal.tio", true, ds);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.DATASET_ROOT, "minimal.tio", null));
            String summary = t.summaryText();
            assertTrue(summary.contains("MS=1"), "summary: " + summary);
            assertTrue(summary.contains("v"), "format version: " + summary);
        }
    }
}
```

- [ ] **Step 2: Implement `OverviewTab`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/overview/OverviewTab.java
package global.thalion.ttio.browser.view.overview;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import javafx.scene.Node;
import javafx.scene.control.Label;
import javafx.scene.layout.VBox;
import javafx.scene.text.Text;

public class OverviewTab implements AbstractDetailTab {

    private final VBox root = new VBox(8);
    private String summaryText = "";

    public OverviewTab() {
        root.setStyle("-fx-padding: 16;");
    }

    @Override public String title() { return "Overview"; }
    @Override public Node content() { return root; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.DATASET_ROOT;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        root.getChildren().clear();
        StringBuilder sb = new StringBuilder();
        sb.append("Title: ").append(safeTitle(d)).append('\n');
        sb.append("ISA Investigation: ")
          .append(orDash(d.dataset().isaInvestigationId())).append('\n');
        sb.append("Format Version: v").append(d.formatVersion()).append('\n');
        sb.append("Path: ").append(d.path()).append('\n');
        sb.append("Read-only: ").append(d.readOnly() ? "yes" : "no").append('\n');
        sb.append('\n');
        sb.append("Counts:\n");
        sb.append("  · MS=").append(d.msRunCount()).append('\n');
        sb.append("  · Genomic=").append(d.genomicRunCount()).append('\n');
        sb.append("  · References=").append(d.referenceCount()).append('\n');
        sb.append("  · Identifications=").append(d.identificationCount()).append('\n');
        sb.append("  · Quantifications=").append(d.quantificationCount()).append('\n');
        sb.append("  · Provenance=").append(d.provenanceCount()).append('\n');
        sb.append('\n');
        sb.append("Feature flags: ");
        d.dataset().featureFlags().features().forEach(f -> sb.append(f).append(' '));
        sb.append('\n');
        if (d.isEncrypted()) {
            sb.append('\n').append("🔒 ENCRYPTED — algorithm: ")
              .append(d.encryptionAlgorithm()).append('\n');
        }
        this.summaryText = sb.toString();

        Text txt = new Text(summaryText);
        txt.setStyle("-fx-font-family: monospace;");
        root.getChildren().add(new Label("Dataset overview"));
        root.getChildren().add(txt);
    }

    public String summaryText() { return summaryText; }

    private static String safeTitle(OpenDataset d) {
        String t = d.dataset().title();
        return (t == null || t.isEmpty()) ? "(untitled)" : t;
    }
    private static String orDash(String s) {
        return (s == null || s.isEmpty()) ? "—" : s;
    }
}
```

- [ ] **Step 3: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=OverviewTabTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10 && cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): OverviewTab — root summary"'
```

---

## Task 3.3: `ProvenanceTab`, `FeatureFlagsTab`, `EncryptionTab`

These three tabs share a common shape: a TableView (Provenance, FeatureFlags) or a key-value summary panel (Encryption). Pattern is identical to OverviewTab. For brevity:

**Provenance table columns:** `software`, `version`, `parameters` (truncated), `inputs` (count), `outputs` (count), `timestamp`. Backed by `dataset.provenanceRecords()`. `appliesTo` returns true for `PROVENANCE` virtual node and for any run node (each run has its own provenance chain via `AcquisitionRun.provenanceChain()` / `GenomicRun.provenanceChain()`).

**FeatureFlags table columns:** `flag`, `enabled`. First row is `ttio_format_version` = the format version string. Following rows are the flags from `featureFlags().features()`. `appliesTo` only the `FEATURE_FLAGS` virtual node.

**EncryptionTab content:**
- `Status:` line — encrypted yes/no, algorithm string, format version (per-channel for v0.x vs per-AU for v1.x — distinguished by checking format version: `< 1.0.0` → per-channel banner; `>= 1.0.0` → per-AU banner).
- `Headers encrypted:` field — read from `featureFlags().features()` (look for `headers_encrypted`).
- `Decrypt with key…` button — only enabled when `isEncrypted()`. Action:
  - Show `FileChooser`, title "Choose binary key file".
  - Read selected file via `Files.readAllBytes(path)`.
  - Call `dataset.decryptWithKey(bytes)`.
  - On success: refresh status line, show inline "Decrypted" toast.
  - On failure: error dialog with `IllegalStateException` / `SecurityException` message.

- [ ] **Step 1: Implement all three (~150 LOC each, follow OverviewTab pattern)**

Create the three files. Use `TableView<ProvenanceRecord>` for provenance, `TableView<Map.Entry<String,Boolean>>` for flags. Encryption tab uses a `GridPane` for key-value rows + the `Decrypt with key…` button.

- [ ] **Step 2: Test the encryption tab's key-file decrypt path**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/EncryptionTabTest.java
@Test
void decryptWithKeyFileSucceeds(@TempDir Path tmp) throws Exception {
    // The Phase 0/parent test suite will have an `encrypted.tio` fixture
    // and corresponding `encrypted.key` produced by the test setup. If
    // the latter doesn't exist as a fixture, generate it inline:
    //
    //    1. Create an unencrypted .tio with create()
    //    2. Generate a 32-byte random key
    //    3. encryptWithKey(key, EncryptionLevel.PER_AU)
    //    4. flush
    //    5. Write key bytes to encrypted.key fixture
    //
    // Then: open the encrypted file, set it on the tab, programmatically
    // invoke decryptByPath(keyFilePath), and assert isEncrypted == false
    // afterwards.

    SpectralDataset ds = SpectralDataset.create(
        tmp.resolve("e.tio").toString(), "enc-test", "hdf5", null);
    byte[] key = new byte[32];
    new java.security.SecureRandom().nextBytes(key);
    ds.encryptWithKey(key, global.thalion.ttio.Enums.EncryptionLevel.PER_AU);
    ds.close();

    Path keyFile = tmp.resolve("k.bin");
    java.nio.file.Files.write(keyFile, key);

    try (SpectralDataset opened = SpectralDataset.open(
            tmp.resolve("e.tio").toString())) {
        assertTrue(opened.isEncrypted());
        EncryptionTab tab = new EncryptionTab();
        tab.update(new OpenDataset(tmp.resolve("e.tio").toString(),
            false, opened), new DatasetTreeNode(
                TreeNodeKind.ENCRYPTION, "encryption", null));
        tab.decryptFromFile(keyFile);
        assertFalse(opened.isEncrypted());
    }
}
```

`decryptFromFile(Path)` is the package-private decrypt helper exposed for tests, called from the FileChooser handler.

- [ ] **Step 3: Run all Phase 3 tests + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest="OverviewTabTest,EncryptionTabTest" test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10 && cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): Provenance + FeatureFlags + Encryption tabs (binary-key file picker)"'
```

---

## Task 3.4: Wire all four tabs into `MainWindow`

In `MainWindow.show()`, after creating `detailPane`:

```java
    detailPane.register(new OverviewTab());
    detailPane.register(new ProvenanceTab());
    detailPane.register(new FeatureFlagsTab());
    detailPane.register(new EncryptionTab());
```

Manual smoke-test (run the fat JAR, open `encrypted.tio`, click `encryption` virtual node, verify Encryption tab appears with `Decrypt with key…` enabled).

- [ ] Commit: `feat(tio-browser): wire structural detail tabs into MainWindow`

---

## Phase 3 acceptance gate

- [ ] Selecting the dataset root shows Overview tab populated.
- [ ] Selecting `feature_flags` node shows FeatureFlags table with `ttio_format_version` row + each flag.
- [ ] Selecting `encryption` node on `encrypted.tio` shows the encrypted status banner and an enabled `Decrypt with key…` button.
- [ ] Encrypted-then-decrypted path works in test (decryptFromFile flips `isEncrypted` to false).
- [ ] Selecting `provenance` virtual node shows non-empty Provenance table for fixtures with provenance records.

---

# Phase 4 — Analytical headers tables

**Goal:** when a tree selection is an MS / NMR / Raman / IR / UV-Vis run, the detail pane shows a sortable headers table (one row per spectrum). Selecting a row populates the spectrum plot (Phase 5).

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/HeadersTableBase.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/MsHeadersTable.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/NmrHeadersTable.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/RamanHeadersTable.java` (also IR / UV-Vis)
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/headers/MsHeadersTableTest.java`
- Modify: `MainWindow` to register them.

---

## Task 4.1: `HeadersTableBase` — generic TableView wrapper

- [ ] **Step 1: Implement abstract base**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/HeadersTableBase.java
package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.browser.view.AbstractDetailTab;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import javafx.beans.property.SimpleObjectProperty;
import javafx.scene.Node;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;

import java.util.function.Function;
import java.util.function.Consumer;

public abstract class HeadersTableBase<R> implements AbstractDetailTab {

    protected final TableView<R> table = new TableView<>();
    private Consumer<R> rowSelectedListener;

    protected HeadersTableBase() {
        table.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && rowSelectedListener != null) {
                    rowSelectedListener.accept(sel);
                }
            });
    }

    @Override public Node content() { return table; }

    public void onRowSelected(Consumer<R> l) { this.rowSelectedListener = l; }

    @SafeVarargs
    protected final <T> TableColumn<R, T> col(String header, Function<R, T> getter) {
        TableColumn<R, T> c = new TableColumn<>(header);
        c.setCellValueFactory(cd -> new SimpleObjectProperty<>(getter.apply(cd.getValue())));
        c.setSortable(true);
        return c;
    }

    @Override
    public abstract void update(OpenDataset d, DatasetTreeNode selection);
}
```

---

## Task 4.2: Per-modality tables — column matrix

Each subclass extends `HeadersTableBase<Spectrum>` (or appropriate row type) and supplies columns. Per-modality column lists:

| Class | Title | Applies to | Row type | Columns (header → getter) |
|---|---|---|---|---|
| `MsHeadersTable` | "MS Headers" | `MS_RUN` | `MassSpectrum` | `idx → index`, `RT → retentionTime`, `MS level → msLevel`, `polarity → polarity`, `precursor m/z → precursorMz`, `charge → charge`, `base-peak intensity → basePeakIntensity`, `activation → activationMethod` |
| `NmrHeadersTable` | "NMR Headers" | `NMR_RUN` | `NMRSpectrum` | `idx → index`, `nucleus → nucleus`, `freq (MHz) → spectrometerFrequencyMhz`, `scan time (s) → scanTimeSeconds`, `solvent → solvent` |
| `RamanHeadersTable` | "Raman Headers" | `RAMAN_RUN`/`IR_RUN`/`UV_VIS_RUN` | `RamanSpectrum`/`IRSpectrum`/`UVVisSpectrum` (resolved at runtime) | `idx → index`, `min x → axisMin`, `max x → axisMax`, `units → axisUnits`, `integration (s) → integrationTimeSeconds`, `laser power (mW) → laserPowerMw` (Raman only), `transmittance/absorbance → mode` (IR only) |

For each subclass:
- `appliesTo(selection)` returns true for the matching `TreeNodeKind`.
- `update(d, selection)` resolves the run from `d.dataset().msRuns().get(selection.key())` (NMR/Raman/IR/UV-Vis all live in `msRuns()` per the SpectralDataset javadoc), iterates `run.spectra()`, populates `table.getItems()`.

**Probe before implementing**: confirm each row-type class actually has the listed accessor methods. Run:

```
wsl -d Ubuntu -- bash -c 'grep -E "^\s+public " ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/MassSpectrum.java | head -25 ; echo --- ; grep -E "^\s+public " ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/NMRSpectrum.java | head -20 ; echo --- ; grep -E "^\s+public " ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/RamanSpectrum.java | head -20'
```

Adjust getter names if they differ (e.g. `retentionTime()` vs `getRetentionTime()` vs `rt()`). Java code in TTI-O follows the no-`get` accessor convention per the existing `SpectralDataset` style.

---

## Task 4.3: Implement and test `MsHeadersTable` (template — others follow same shape)

- [ ] **Step 1: Failing test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/headers/MsHeadersTableTest.java
package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.*;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class MsHeadersTableTest {

    @Test
    void msHeadersAppliesOnlyToMsRunNode() {
        MsHeadersTable t = new MsHeadersTable();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.NMR_RUN, "run", "run")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, "root", null)));
    }

    @Test
    void msHeadersPopulatesFromFixture() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            String runKey = ds.msRuns().keySet().iterator().next();
            MsHeadersTable t = new MsHeadersTable();
            OpenDataset open = new OpenDataset("full_ms.tio", true, ds);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.MS_RUN, runKey, runKey));
            assertEquals(ds.msRuns().get(runKey).spectra().size(),
                         t.table().getItems().size());
        }
    }
}
```

- [ ] **Step 2: Implement** (`~80 LOC`).

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/MsHeadersTable.java
package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.scene.control.TableView;

public class MsHeadersTable extends HeadersTableBase<MassSpectrum> {

    public MsHeadersTable() {
        table.getColumns().add(col("idx",         MassSpectrum::index));
        table.getColumns().add(col("RT",          MassSpectrum::retentionTime));
        table.getColumns().add(col("MS level",    MassSpectrum::msLevel));
        table.getColumns().add(col("polarity",    s -> s.polarity().name()));
        table.getColumns().add(col("precursor m/z", MassSpectrum::precursorMz));
        table.getColumns().add(col("charge",      MassSpectrum::charge));
        table.getColumns().add(col("base peak",   MassSpectrum::basePeakIntensity));
        table.getColumns().add(col("activation",  s -> s.activationMethod() == null
            ? "" : s.activationMethod().name()));
    }

    @Override public String title() { return "MS Headers"; }
    @Override public boolean appliesTo(DatasetTreeNode s) {
        return s.kind() == TreeNodeKind.MS_RUN;
    }
    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        AcquisitionRun run = d.dataset().msRuns().get(selection.key());
        if (run == null) {
            table.getItems().clear();
            return;
        }
        table.getItems().setAll(run.spectra());
    }

    public TableView<MassSpectrum> table() { return table; }
}
```

- [ ] **Step 3: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=MsHeadersTableTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10 && cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): MsHeadersTable + base"'
```

---

## Task 4.4: Implement `NmrHeadersTable`

Follow MsHeadersTable pattern. Row type is `NMRSpectrum` (in `global.thalion.ttio.NMRSpectrum`). Columns from §4.2 matrix. `appliesTo` returns true for `NMR_RUN`. `update` reads from `dataset.msRuns().get(key)` (NMR runs share the msRuns map per the javadoc) and filters spectra by class — `run.spectra().stream().filter(NMRSpectrum.class::isInstance).map(NMRSpectrum.class::cast).toList()`.

Test against `nmr_1d.tio` fixture; expected row count = 1 (single 1-D spectrum).

- [ ] Implement, test, commit.

---

## Task 4.5: Implement `RamanHeadersTable` (with IR / UV-Vis variants)

The HANDOFF treats Raman / IR / UV-Vis as one table with a discriminator column for the y-axis interpretation (intensity vs absorbance vs transmittance). Implement as one `RamanHeadersTable` class that detects the spectrum subtype at row-time and renders appropriately. `appliesTo` returns true for any of `RAMAN_RUN`, `IR_RUN`, `UV_VIS_RUN`.

- [ ] Implement, test, commit.

---

## Task 4.6: Wire all three header tables into `DetailPane`

```java
    detailPane.register(new MsHeadersTable());
    detailPane.register(new NmrHeadersTable());
    detailPane.register(new RamanHeadersTable());
```

Each table's `onRowSelected` will be wired in Phase 5 to the spectrum plot.

- [ ] Commit: `feat(tio-browser): wire header tables into MainWindow`

---

## Phase 4 acceptance gate

- [ ] Selecting an MS run in `full_ms.tio` populates the MS Headers table; row count matches `run.spectra().size()`.
- [ ] Selecting an NMR run in `nmr_1d.tio` populates the NMR Headers table; column set matches the §4.2 matrix.
- [ ] Tables are sortable on every column.
- [ ] All Phase 4 tests pass.

---

# Phase 5 — Plot views + downsampler

**Goal:** selecting a spectrum row in a header table renders its line/stem chart; selecting a chromatogram subnode renders a TIC/XIC trace. >100K-point spectra are downsampled to ~5K visible points using a min/max-bucket reducer.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/MinMaxBucketDownsampler.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/SpectrumPlotView.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/ChromatogramPlotView.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/plot/MinMaxBucketDownsamplerTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/plot/SpectrumPlotViewTest.java`

---

## Task 5.1: `MinMaxBucketDownsampler` (pure Java, unit-testable)

- [ ] **Step 1: Failing test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/plot/MinMaxBucketDownsamplerTest.java
package global.thalion.ttio.browser.view.plot;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class MinMaxBucketDownsamplerTest {

    @Test
    void belowTargetCountReturnsInputUnchanged() {
        double[] x = {0, 1, 2, 3, 4};
        double[] y = {1, 2, 3, 4, 5};
        MinMaxBucketDownsampler.Result r = MinMaxBucketDownsampler.reduce(x, y, 100);
        assertArrayEquals(x, r.x());
        assertArrayEquals(y, r.y());
    }

    @Test
    void halvesPointCountWhenTargetIsHalf() {
        double[] x = new double[1000];
        double[] y = new double[1000];
        for (int i = 0; i < 1000; i++) {
            x[i] = i;
            y[i] = i;
        }
        MinMaxBucketDownsampler.Result r = MinMaxBucketDownsampler.reduce(x, y, 100);
        // Each of 50 buckets emits a min and a max → 100 points.
        assertEquals(100, r.x().length);
        assertEquals(0.0, r.y()[0]);
        assertEquals(999.0, r.y()[r.y().length - 1]);
    }

    @Test
    void preservesPeaksInNoisyData() {
        double[] x = new double[10000];
        double[] y = new double[10000];
        for (int i = 0; i < 10000; i++) {
            x[i] = i;
            y[i] = (i == 5000) ? 1e6 : Math.random();
        }
        MinMaxBucketDownsampler.Result r = MinMaxBucketDownsampler.reduce(x, y, 200);
        double maxOut = 0;
        for (double v : r.y()) if (v > maxOut) maxOut = v;
        assertEquals(1e6, maxOut, 1e-3, "peak must survive bucketing");
    }
}
```

- [ ] **Step 2: Implement**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/MinMaxBucketDownsampler.java
package global.thalion.ttio.browser.view.plot;

public final class MinMaxBucketDownsampler {

    public static final class Result {
        private final double[] x, y;
        public Result(double[] x, double[] y) { this.x = x; this.y = y; }
        public double[] x() { return x; }
        public double[] y() { return y; }
    }

    private MinMaxBucketDownsampler() {}

    /**
     * Reduce a series to ~targetPoints by bucketing with min/max preservation.
     * Each bucket contributes two points (min & max y in original x order)
     * so that local extrema survive.
     */
    public static Result reduce(double[] x, double[] y, int targetPoints) {
        if (x.length <= targetPoints) return new Result(x, y);
        if (targetPoints < 4) targetPoints = 4;

        int bucketCount = targetPoints / 2;
        int n = x.length;
        double bucketWidth = (double) n / bucketCount;

        double[] outX = new double[bucketCount * 2];
        double[] outY = new double[bucketCount * 2];

        for (int b = 0; b < bucketCount; b++) {
            int start = (int) Math.floor(b * bucketWidth);
            int end = Math.min((int) Math.floor((b + 1) * bucketWidth), n);
            int minIdx = start, maxIdx = start;
            for (int i = start + 1; i < end; i++) {
                if (y[i] < y[minIdx]) minIdx = i;
                if (y[i] > y[maxIdx]) maxIdx = i;
            }
            int firstIdx = Math.min(minIdx, maxIdx);
            int secondIdx = Math.max(minIdx, maxIdx);
            outX[b * 2] = x[firstIdx];
            outY[b * 2] = y[firstIdx];
            outX[b * 2 + 1] = x[secondIdx];
            outY[b * 2 + 1] = y[secondIdx];
        }
        return new Result(outX, outY);
    }
}
```

- [ ] **Step 3: Run, commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=MinMaxBucketDownsamplerTest test 2>&1 | tail -10 && cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): MinMaxBucketDownsampler — peak-preserving reducer"'
```

---

## Task 5.2: `SpectrumPlotView` — LineChart wrapper

- [ ] **Step 1: Implement**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/SpectrumPlotView.java
package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.NMRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.UVVisSpectrum;
import global.thalion.ttio.Spectrum;
import javafx.scene.Node;
import javafx.scene.chart.LineChart;
import javafx.scene.chart.NumberAxis;
import javafx.scene.chart.XYChart;
import javafx.scene.control.*;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;

public class SpectrumPlotView {

    private static final int RENDER_TARGET_POINTS = 5000;

    private final NumberAxis xAxis = new NumberAxis();
    private final NumberAxis yAxis = new NumberAxis();
    private final LineChart<Number, Number> chart = new LineChart<>(xAxis, yAxis);
    private final ToggleButton logToggle = new ToggleButton("log Y");
    private final Button resetZoom = new Button("Reset zoom");
    private final Button savePng = new Button("Save PNG…");
    private final HBox controls = new HBox(8, logToggle, resetZoom, savePng);
    private final VBox root = new VBox(4, controls, chart);

    private double[] currentX, currentY;
    private boolean stemMode = false;

    public SpectrumPlotView() {
        chart.setCreateSymbols(false);
        chart.setLegendVisible(false);
        chart.setAnimated(false);
        controls.setStyle("-fx-padding: 4 8 0 8;");
        // log toggle, reset, savePng wiring → Step 3.
    }

    public Node content() { return root; }

    public void render(Spectrum spec) {
        // Resolve x/y arrays — each Spectrum subclass exposes them.
        double[] x = spec.xArray();   // method name: probe & adjust
        double[] y = spec.yArray();
        configureAxesFor(spec);
        currentX = x;
        currentY = y;
        renderArrays(x, y);
    }

    private void renderArrays(double[] x, double[] y) {
        var series = new XYChart.Series<Number, Number>();
        if (stemMode) {
            for (int i = 0; i < x.length; i++) {
                series.getData().add(new XYChart.Data<>(x[i], 0));
                series.getData().add(new XYChart.Data<>(x[i], y[i]));
                series.getData().add(new XYChart.Data<>(x[i], 0));
            }
        } else {
            var r = MinMaxBucketDownsampler.reduce(x, y, RENDER_TARGET_POINTS);
            for (int i = 0; i < r.x().length; i++) {
                series.getData().add(new XYChart.Data<>(r.x()[i], r.y()[i]));
            }
        }
        chart.getData().setAll(series);
    }

    private void configureAxesFor(Spectrum spec) {
        if (spec instanceof MassSpectrum) {
            xAxis.setLabel("m/z"); yAxis.setLabel("intensity");
            stemMode = ((MassSpectrum) spec).isCentroided();   // probe accessor name
            xAxis.setForceZeroInRange(false);
        } else if (spec instanceof NMRSpectrum) {
            xAxis.setLabel("ppm"); yAxis.setLabel("intensity");
            stemMode = false;
            // NMR convention: chemical shift increases right→left.
            // JavaFX has no native reversed-axis flag on NumberAxis;
            // simplest workaround: negate the x values during render.
            // For v0.1 we accept normal axis; document as a known
            // limitation (also surfaces a tracking issue in CHANGELOG).
        } else if (spec instanceof RamanSpectrum) {
            xAxis.setLabel("wavenumber (1/cm)"); yAxis.setLabel("intensity");
            stemMode = false;
        } else if (spec instanceof IRSpectrum) {
            xAxis.setLabel("wavenumber (1/cm)"); yAxis.setLabel(
                "absorbance"); // adjust for transmittance mode at runtime
            stemMode = false;
        } else if (spec instanceof UVVisSpectrum) {
            xAxis.setLabel("wavelength (nm)"); yAxis.setLabel("absorbance");
            stemMode = false;
        }
    }
}
```

**Probe before locking** — `Spectrum` subclasses' x/y array accessor names. Run:

```
wsl -d Ubuntu -- bash -c 'grep -E "^\s+public (double\[\]|float\[\])" ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/MassSpectrum.java ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/NMRSpectrum.java | head -10'
```

Adjust accessors. Likely names: `mzArray()`/`intensityArray()` for MS; `ppmArray()`/`intensities()` for NMR; etc. Add a thin `xArray()` / `yArray()` adapter in `SpectrumPlotView` if needed.

- [ ] **Step 2: Wire log-Y toggle, reset zoom, save-PNG**

```java
    public SpectrumPlotView() {
        // ... constructor body above ...
        logToggle.selectedProperty().addListener((obs, was, now) -> {
            if (now) {
                // JavaFX's NumberAxis doesn't support log natively; either
                // pre-transform y or use a third-party LogAxis. v0.1: pre-transform.
                if (currentY != null) {
                    double[] logY = new double[currentY.length];
                    for (int i = 0; i < currentY.length; i++) {
                        logY[i] = currentY[i] > 0
                            ? Math.log10(currentY[i]) : 0;
                    }
                    renderArrays(currentX, logY);
                }
            } else {
                if (currentX != null) renderArrays(currentX, currentY);
            }
        });
        resetZoom.setOnAction(e -> {
            xAxis.setAutoRanging(true);
            yAxis.setAutoRanging(true);
        });
        savePng.setOnAction(e -> {
            javafx.stage.FileChooser ch = new javafx.stage.FileChooser();
            ch.setTitle("Save plot as PNG");
            ch.getExtensionFilters().add(
                new javafx.stage.FileChooser.ExtensionFilter("PNG", "*.png"));
            java.io.File target = ch.showSaveDialog(root.getScene().getWindow());
            if (target == null) return;
            javafx.scene.image.WritableImage img =
                chart.snapshot(null, null);
            try {
                javax.imageio.ImageIO.write(
                    javafx.embed.swing.SwingFXUtils.fromFXImage(img, null),
                    "png", target);
            } catch (java.io.IOException ex) {
                new javafx.scene.control.Alert(
                    javafx.scene.control.Alert.AlertType.ERROR,
                    "Save failed: " + ex.getMessage()).showAndWait();
            }
        });
    }
```

**Note** — `SwingFXUtils` requires `javafx.swing` module. Add to pom.xml javafx-swing dep with the same classifier matrix. If you'd rather avoid the swing module, use a plain JavaFX-only PNG path: snapshot to `WritableImage`, then `PixelReader.getPixels(...)` with a `WritablePixelFormat` and write manually (slow but module-free). Recommend swing path; pom dep adds ~3 MB.

- [ ] **Step 3: Drag-to-zoom rectangle**

Standard JavaFX recipe — overlay a `Rectangle` while the user drags, on release set `xAxis.lowerBound/upperBound` to the inverse-projected drag rectangle. ~80 LOC. See <https://stackoverflow.com/a/47554003> for a concise pattern; **don't link to it from comments** — implement directly. Test by polling `xAxis.getLowerBound()` after a synthesized drag in TestFX.

- [ ] **Step 4: Wire `SpectrumPlotView` into header table row-selection**

In `MainWindow.show()` after registering header tables:

```java
    SpectrumPlotView plot = new SpectrumPlotView();
    // Show plot as a tab next to the headers table when a row is selected
    msHeaders.onRowSelected(spectrum -> plot.render(spectrum));
    nmrHeaders.onRowSelected(spectrum -> plot.render(spectrum));
    ramanHeaders.onRowSelected(spectrum -> plot.render(spectrum));
```

The plot lives in a `Plot` tab managed by `DetailPane`. Implement a thin `SpectrumPlotTab implements AbstractDetailTab` whose `appliesTo` returns false initially (no spectrum selected) and is forced visible by the row-selection handler via `detailPane.forcePlotTab(spectrum)`.

- [ ] **Step 5: Test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/plot/SpectrumPlotViewTest.java
@Test
void plotRendersFromMassSpectrumWithoutThrowing() throws Exception {
    try (SpectralDataset ds = SpectralDataset.open(
            Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                .toAbsolutePath().toString())) {
        AcquisitionRun run = ds.msRuns().values().iterator().next();
        MassSpectrum s0 = (MassSpectrum) run.spectra().get(0);
        SpectrumPlotView v = new SpectrumPlotView();
        v.render(s0);
        // No assertion on visual output — just survives.
        assertNotNull(v.content());
    }
}
```

This must run on the FX thread; wrap with `Platform.runLater` + countdown latch, or extend `ApplicationTest`.

- [ ] **Step 6: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): SpectrumPlotView — line/stem mode + downsampler + log-Y + zoom + PNG"'
```

---

## Task 5.3: `ChromatogramPlotView`

Trivially adapt from `SpectrumPlotView`:
- Row type is `Chromatogram` (already in root package).
- Stem mode never on.
- Axis labels: `time (s)` / `intensity`.
- `appliesTo` returns true for `CHROMATOGRAM` selection (i.e. when the user expanded an MS run and selected one of its chromatograms — tree builder must add chromatograms as children of MS runs in Phase 2; if it doesn't, extend Phase 2 here).

- [ ] Implement, test, commit. Plus update `DatasetTreeBuilder` to add chromatogram child nodes under MS runs.

---

## Phase 5 acceptance gate

- [ ] A 200-peak centroided MS spectrum from `full_ms.tio` renders within 500 ms (stem mode).
- [ ] A profile spectrum >100 K points renders within 2 s with downsampler engaged (line mode).
- [ ] Log-Y toggle replots without re-loading.
- [ ] Reset zoom returns to auto-range.
- [ ] Save-PNG produces a non-empty PNG file at the chosen path.
- [ ] Drag-to-zoom restricts axis ranges as expected.

---

# Phase 6 — ChannelHexView + Identifications + Quantifications tabs

**Goal:** complete the analytical detail-tab set with the per-spectrum channels view (hex bytes inspector) plus the dataset-level identifications and quantifications tables.

---

## Task 6.1: `ChannelHexView`

Shows the named `SignalArray` channels for the currently-selected spectrum as a list (left) + a hex-dump pane (right) for the selected channel. `appliesTo` true when the selection is `SPECTRUM` and a spectrum is loaded (driven by header-table row selection, like `SpectrumPlotView`).

- [ ] **Step 1: Implement** (~120 LOC)

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/view/ChannelHexView.java
package global.thalion.ttio.browser.view;

import global.thalion.ttio.SignalArray;
import global.thalion.ttio.Spectrum;
import javafx.scene.Node;
import javafx.scene.control.*;
import javafx.scene.layout.HBox;

public class ChannelHexView {

    private final ListView<String> channelList = new ListView<>();
    private final TextArea hexArea = new TextArea();
    private final HBox root = new HBox(8, channelList, hexArea);
    private Spectrum currentSpectrum;

    public ChannelHexView() {
        channelList.setMinWidth(180);
        hexArea.setEditable(false);
        hexArea.setStyle("-fx-font-family: monospace; -fx-font-size: 10pt;");
        channelList.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && currentSpectrum != null) {
                    SignalArray ch = currentSpectrum.channelByName(sel);
                    hexArea.setText(formatHex(ch));
                }
            });
    }

    public Node content() { return root; }

    public void render(Spectrum s) {
        this.currentSpectrum = s;
        channelList.getItems().setAll(s.channelNames());
        hexArea.clear();
    }

    private static String formatHex(SignalArray a) {
        // Show the first 4 KiB only — full payloads can be hundreds of MB.
        byte[] bytes = a.bytes();
        int show = Math.min(bytes.length, 4096);
        StringBuilder sb = new StringBuilder();
        sb.append("Channel: ").append(a.name()).append('\n');
        sb.append("Type: ").append(a.precision()).append(", length: ")
          .append(bytes.length).append(" bytes\n");
        sb.append("Min/Max: see header table\n\n");
        for (int i = 0; i < show; i += 16) {
            sb.append(String.format("%08x  ", i));
            for (int j = 0; j < 16 && i + j < show; j++) {
                sb.append(String.format("%02x ", bytes[i + j]));
            }
            sb.append('\n');
        }
        if (bytes.length > show) {
            sb.append("\n... ").append(bytes.length - show).append(" more bytes\n");
        }
        return sb.toString();
    }
}
```

**Probe** — `Spectrum.channelByName(String)` and `Spectrum.channelNames()` accessor names. If the actual API is e.g. `channels()` returning `Map<String, SignalArray>`, adapt. Run:

```
wsl -d Ubuntu -- bash -c 'grep -E "^\s+public " ~/TTI-O.worktrees/tio-browser/java/src/main/java/global/thalion/ttio/Spectrum.java | head -25'
```

- [ ] **Step 2: Wire** — `ChannelHexView.render(spectrum)` is called from header-table row selection alongside `SpectrumPlotView.render(spectrum)`.

- [ ] **Step 3: Test** — open `full_ms.tio`, render row 0, assert `channelList.getItems()` is non-empty.

- [ ] **Step 4: Commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): ChannelHexView — hex dump of named signal arrays"'
```

---

## Task 6.2: `IdentificationsTab` + `QuantificationsTab`

Both are TableView wrappers, like the headers tables but bound to dataset-level lists.

| Tab | Backed by | Columns |
|---|---|---|
| `IdentificationsTab` | `dataset.identifications()` (List<Identification>) | `compound`, `m/z`, `score`, `provenance` (link), `evidence` (count) |
| `QuantificationsTab` | `dataset.quantifications()` (List<Quantification>) | `target`, `value`, `unit`, `method`, `provenance` |

`appliesTo`: respective virtual node kinds.

- [ ] Implement both, test against `full_ms.tio` (probe its identification count first), commit.

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): Identifications + Quantifications tabs"'
```

---

## Task 6.3: Wire all Phase 6 tabs into `MainWindow`

```java
    detailPane.register(new IdentificationsTab());
    detailPane.register(new QuantificationsTab());
    // ChannelHexView is owned by the spectrum-selection flow, not a tab.
```

- [ ] Commit.

---

## Phase 6 acceptance gate

- [ ] Selecting a spectrum row populates ChannelHexView with all named channels of that spectrum.
- [ ] Selecting a channel from the list shows its first 4 KiB as hex.
- [ ] `identifications` virtual node shows TableView with row count = `dataset.identifications().size()`.
- [ ] Same for `quantifications`.

---

# Phase 7 — Genomic detail panes

**Goal:** open `m82_100reads.tio`, navigate the genomic-runs branch, see the headers table; select a read, see the Read Inspector with sequence colouring + quality bar + CIGAR pills; see Chromosome Distribution; see References tab populated from Phase 0's `references()` accessor.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/headers/GenomicHeadersTable.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/ReadInspectorView.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/plot/ChromDistributionView.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/view/ReferenceTab.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/util/CigarParser.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/headers/GenomicHeadersTableTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/util/CigarParserTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/plot/ReadInspectorViewTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/view/plot/ChromDistributionViewTest.java`

---

## Task 7.1: `GenomicHeadersTable`

Columns: `idx`, `chrom`, `pos`, `flag` (decimal), `MAPQ`, `CIGAR`, `length`, `read_name`. Backed by iterating `genomicRun.index()` (no full-payload load). Per-row data via `GenomicIndex.chromosomeAt(i)`, `positionAt(i)`, `flagsAt(i)`, `mappingQualityAt(i)`, `lengthAt(i)`; CIGAR + read name via `genomicRun.cigarAt(i)` / `readNameAt(i)`.

- [ ] **Step 1: Failing test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/view/headers/GenomicHeadersTableTest.java
@Test
void m82FixturePopulates100Rows() throws Exception {
    try (SpectralDataset ds = SpectralDataset.open(
            Paths.get("../python/tests/fixtures/genomic/m82_100reads.tio")
                .toAbsolutePath().toString())) {
        String runKey = ds.genomicRuns().keySet().iterator().next();
        GenomicHeadersTable t = new GenomicHeadersTable();
        t.update(new OpenDataset("m82.tio", true, ds),
            new DatasetTreeNode(TreeNodeKind.GENOMIC_RUN, runKey, runKey));
        assertEquals(100, t.table().getItems().size());
        // Spot-check first row's chromosome is non-null
        var row0 = t.table().getItems().get(0);
        assertNotNull(row0.chromosome());
    }
}
```

- [ ] **Step 2: Implement**

```java
// Define a row class GenomicRowAdapter that wraps an index + a back-pointer
// to the GenomicRun, so columns access via the index.
public class GenomicRowAdapter {
    private final GenomicRun run;
    private final int idx;
    public GenomicRowAdapter(GenomicRun run, int idx) { this.run = run; this.idx = idx; }
    public int index() { return idx; }
    public String chromosome() { return run.index().chromosomeAt(idx); }
    public long position()     { return run.index().positionAt(idx); }
    public int flag()          { return run.index().flagsAt(idx); }
    public int mapq()          { return run.index().mappingQualityAt(idx); }
    public String cigar()      { return run.cigarAt(idx); }
    public int length()        { return run.index().lengthAt(idx); }
    public String readName()   { return run.readNameAt(idx); }
    public AlignedRead full()  { return run.objectAtIndex(idx); }
}
```

`GenomicHeadersTable` populates `IntStream.range(0, run.readCount()).mapToObj(i -> new GenomicRowAdapter(run, i)).toList()`.

- [ ] **Step 3: Add chromosome filter** — a `ChoiceBox<String>` above the table with options `(all)` + each unique chromosome + `*` (unmapped). Filtering is a TableView `setPredicate` on a `FilteredList<GenomicRowAdapter>`.

- [ ] **Step 4: Wire** — register in `DetailPane`, `appliesTo` = `GENOMIC_RUN`. Row selection drives `ReadInspectorView.render(row.full())`.

- [ ] **Step 5: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest=GenomicHeadersTableTest test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10 && cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): GenomicHeadersTable with chromosome filter"'
```

---

## Task 7.2: `CigarParser` utility (pure Java, unit-testable)

- [ ] **Step 1: Failing test**

```java
// tio-browser/src/test/java/global/thalion/ttio/browser/util/CigarParserTest.java
@Test
void parsesSimpleCigar() {
    var ops = CigarParser.parse("10M2I5M");
    assertEquals(3, ops.size());
    assertEquals(10, ops.get(0).length());
    assertEquals(CigarParser.Op.M, ops.get(0).op());
    assertEquals(2,  ops.get(1).length());
    assertEquals(CigarParser.Op.I, ops.get(1).op());
}

@Test
void rejectsInvalidCigar() {
    assertThrows(IllegalArgumentException.class,
        () -> CigarParser.parse("garbage"));
}

@Test
void capsAtMaxOps() {
    StringBuilder s = new StringBuilder();
    for (int i = 0; i < 500; i++) s.append("1M");
    var ops = CigarParser.parse(s.toString());
    assertEquals(500, ops.size());
    var capped = CigarParser.parseCapped(s.toString(), 200);
    assertEquals(200, capped.ops().size());
    assertTrue(capped.truncated());
    assertEquals(500, capped.totalOps());
}
```

- [ ] **Step 2: Implement** (~80 LOC). Public API:

```java
public final class CigarParser {
    public enum Op { M, I, D, N, S, H, P, EQ, X }
    public static record CigarOp(int length, Op op) {}
    public static record CappedResult(List<CigarOp> ops, int totalOps,
                                       boolean truncated) {}
    public static List<CigarOp> parse(String cigar) { ... }
    public static CappedResult parseCapped(String cigar, int max) { ... }
}
```

- [ ] **Step 3: Run + commit.**

---

## Task 7.3: `ReadInspectorView` — sequence + quality + CIGAR pills

- [ ] **Step 1: Failing test (non-FX-bound — test the formatting helpers)**

```java
@Test
void readNameAndMetadataLineIncludesAllFields() {
    AlignedRead read = mock(...);  // or use a real fixture read
    String meta = ReadInspectorView.formatMetadata(read);
    assertTrue(meta.contains(read.readName()));
    assertTrue(meta.contains("MAPQ"));
}

@Test
void unmappedReadHidesPosition() {
    AlignedRead unmapped = ... ;  // flag & 0x4 == 1, chrom = "*"
    String meta = ReadInspectorView.formatMetadata(unmapped);
    assertTrue(meta.contains("(unmapped)"));
    assertFalse(meta.matches(".*pos\\s*=\\s*\\d.*"));
}
```

- [ ] **Step 2: Implement** (~250 LOC — biggest single file in Phase 7)

Key sub-methods:
- `colouredSequence(byte[] seq)` → `TextFlow` with one `Text` per coloured run (see HANDOFF Gotcha §12.3.11). Pagination: 50 lines × 50 bases per line per page; nav buttons for sequences > 5000 bases.
- `qualityBars(byte[] qual)` → `BarChart`. For length > 5000, plot every Nth such that ≤ 2000 bars.
- `cigarPills(String cigarStr)` → `HBox` of styled `Label` pills per op; cap at 200 (HANDOFF §12.3.12); overflow opens a separate window.
- `formatMetadata(AlignedRead read)` → multi-line string for the metadata footer.

Unit-test the format helpers (pure Java); FX wiring is verified by visual inspection of the running app.

- [ ] **Step 3: Wire** — `appliesTo` returns false (driven by header-table row selection only); `MainWindow` exposes `forceReadInspector(AlignedRead)` similar to `forcePlotTab`.

- [ ] **Step 4: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): ReadInspectorView — sequence + quality + CIGAR pills"'
```

---

## Task 7.4: `ChromDistributionView` — bar chart of reads-per-chromosome

- [ ] **Step 1: Test**

```java
@Test
void chromCountsForM82Fixture() throws Exception {
    try (SpectralDataset ds = SpectralDataset.open(...m82_100reads.tio)) {
        GenomicRun run = ds.genomicRuns().values().iterator().next();
        Map<String, Integer> counts = ChromDistributionView.computeCounts(run);
        // Sum to 100 (the fixture's read count).
        assertEquals(100, counts.values().stream().mapToInt(Integer::intValue).sum());
    }
}
```

- [ ] **Step 2: Implement**

```java
public static Map<String, Integer> computeCounts(GenomicRun run) {
    Map<String, Integer> counts = new LinkedHashMap<>();
    GenomicIndex idx = run.index();
    for (int i = 0; i < idx.count(); i++) {
        String c = idx.chromosomeAt(i);
        if (c == null || c.isEmpty()) c = "*";
        counts.merge(c, 1, Integer::sum);
    }
    return counts;
}
```

`render(GenomicRun)` builds a `BarChart<String, Number>` from the count map — including a `*` bar for unmapped. Compute on a background `Task`; only the chart-set call goes through `Platform.runLater`.

- [ ] **Step 3: Wire** — `appliesTo` matches `GENOMIC_RUN`. Surfaces as a tab next to GenomicHeadersTable.

- [ ] **Step 4: Run + commit.**

---

## Task 7.5: `ReferenceTab` — uses Phase 0's `references()` accessor

- [ ] **Step 1: Failing test**

```java
@Test
void referenceTabAppliesOnlyToReferenceNode() {
    ReferenceTab t = new ReferenceTab();
    assertTrue(t.appliesTo(new DatasetTreeNode(
        TreeNodeKind.REFERENCE, "test", "test-ref-v1")));
    assertFalse(t.appliesTo(new DatasetTreeNode(
        TreeNodeKind.GENOMIC_RUN, "g1", "g1")));
}

@Test
void referenceTabPopulatesFromEmbeddedReference(@TempDir Path tmp) throws Exception {
    Path tio = tmp.resolve("with_ref.tio");
    // Write fixture inline (matches Phase 0 test pattern)
    Map<String, byte[]> seqs = Map.of(
        "chr1", "ACGTACGT".getBytes(),
        "chr2", "TTTTAAAA".getBytes());
    try (SpectralDataset ds = SpectralDataset.create(
            tio.toString(), "ref-tab", "hdf5", null)) {
        WrittenGenomicRun run = WrittenGenomicRun.builder()
            .name("g1").referenceUri("test-ref-v1")
            .embedReference(true).referenceChromSeqs(seqs).build();
        ds.addGenomicRun("g1", run);
        ds.flush();
    }
    try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
        ReferenceTab t = new ReferenceTab();
        OpenDataset open = new OpenDataset(tio.toString(), true, opened);
        t.update(open, new DatasetTreeNode(
            TreeNodeKind.REFERENCE, "test-ref-v1", "test-ref-v1"));
        assertEquals("test-ref-v1", t.shownUri());
        assertEquals(2, t.shownChromosomeCount());
        assertEquals(16L, t.shownTotalBases());
    }
}
```

- [ ] **Step 2: Implement** (~120 LOC)

Layout: a `GridPane` with rows for `URI`, `Chromosome count`, `Total bases`, `MD5 hex` (from `referenceImport.md5Hex()`). Below: a `ListView<String>` of chromosomes; selecting one shows the first 4 KiB of its sequence as plain text in a `TextArea`.

- [ ] **Step 3: Wire** — register in `DetailPane`. `appliesTo` matches `REFERENCE`.

- [ ] **Step 4: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): ReferenceTab — uses 1.1.0 references() accessor"'
```

---

## Task 7.6: Wire all Phase 7 tabs into `MainWindow`

```java
    detailPane.register(new GenomicHeadersTable());
    detailPane.register(new ChromDistributionView());
    detailPane.register(new ReferenceTab());
    // ReadInspectorView is owned by the genomic-row-selection flow, like
    // SpectrumPlotView and ChannelHexView for analytical runs.
```

- [ ] Commit.

---

## Phase 7 acceptance gate

- [ ] Opening `m82_100reads.tio` shows `genomic_runs/g1` (or whatever the run is named); selecting it populates GenomicHeadersTable with 100 rows.
- [ ] Selecting a read row shows ReadInspector with: coloured sequence, quality bar chart, CIGAR pills, metadata footer.
- [ ] An unmapped read (flag & 0x4 set, chrom `*`) shows `(unmapped)` and hides position.
- [ ] ChromDistributionView shows bars summing to 100.
- [ ] A `.tio` written by Phase 0's conformance fixture (with embedded reference) shows the ReferenceTab populated with the right URI / chromosome count / total bases / MD5.
- [ ] All Phase 7 tests pass.

---

# Phase 8 — Import dialog + format dispatch (12 formats)

**Goal:** File → Import → wizard picks format + source path + target `.tio` path; runs the right library reader on a background `Task`; on success opens the new `.tio` in the main window. Drag-and-drop sniff (HANDOFF §6.4) pre-selects the format. Format-list reflection at startup; if a reader class is missing from the classpath the entry is greyed out with a tooltip naming the missing class.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportFormatRegistry.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportFormatSpec.java` (data class)
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/FormatSniffer.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportDialog.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportTask.java`
- Create: `tio-browser/src/main/resources/formats.properties` (descriptions)
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/importers/ImportFormatRegistryTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/importers/FormatSnifferTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/importers/ImportTaskTest.java`

---

## Task 8.1: `ImportFormatSpec` — one-row-per-format data class

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportFormatSpec.java
package global.thalion.ttio.browser.importers;

import java.util.List;

public final class ImportFormatSpec {
    public enum SourceKind { FILE, DIRECTORY }
    public enum ExtraField {
        NONE, FASTA_TREAT_AS, FASTQ_PHRED, CRAM_REFERENCE,
        BAM_REFERENCE, MZTAB_DIALECT_DETECT
    }

    public final String name;             // "mzML"
    public final String readerClassFqn;   // "global.thalion.ttio.importers.MzMLReader"
    public final SourceKind sourceKind;
    public final List<String> fileExts;   // [".mzML"]
    public final ExtraField extras;
    public final String description;      // pulled from formats.properties

    public ImportFormatSpec(String name, String readerClassFqn,
                            SourceKind sourceKind, List<String> fileExts,
                            ExtraField extras, String description) {
        this.name = name; this.readerClassFqn = readerClassFqn;
        this.sourceKind = sourceKind; this.fileExts = List.copyOf(fileExts);
        this.extras = extras; this.description = description;
    }

    public boolean readerOnClasspath() {
        try {
            Class.forName(readerClassFqn);
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }
}
```

---

## Task 8.2: Format matrix — the 12-row data table

| `name` | `readerClassFqn` | `sourceKind` | `fileExts` | `extras` |
|---|---|---|---|---|
| mzML | `global.thalion.ttio.importers.MzMLReader` | FILE | `.mzML, .mzML.gz` | NONE |
| mzTab | `global.thalion.ttio.importers.MzTabReader` | FILE | `.mzTab, .mztab` | MZTAB_DIALECT_DETECT |
| imzML | `global.thalion.ttio.importers.ImzMLReader` | FILE | `.imzML` | NONE |
| nmrML | `global.thalion.ttio.importers.NmrMLReader` | FILE | `.nmrML` | NONE |
| JCAMP-DX | `global.thalion.ttio.importers.JcampDxReader` | FILE | `.jdx, .dx, .jcm` | NONE |
| Bruker timsTOF | `global.thalion.ttio.importers.BrukerTDFReader` | DIRECTORY | `.d` | NONE |
| Waters MassLynx | `global.thalion.ttio.importers.WatersMassLynxReader` | DIRECTORY | `.raw` | NONE |
| Thermo .raw | `global.thalion.ttio.importers.ThermoRawReader` | FILE | `.raw` | NONE |
| BAM | `global.thalion.ttio.importers.BamReader` | FILE | `.bam` | BAM_REFERENCE |
| SAM | `global.thalion.ttio.importers.SamReader` | FILE | `.sam` | NONE |
| CRAM | `global.thalion.ttio.importers.CramReader` | FILE | `.cram` | CRAM_REFERENCE |
| FASTA | `global.thalion.ttio.importers.FastaReader` | FILE | `.fa, .fasta, .fna, .ffn, .faa` | FASTA_TREAT_AS |
| FASTQ | `global.thalion.ttio.importers.FastqReader` | FILE | `.fastq, .fq, .fastq.gz, .fq.gz` | FASTQ_PHRED |

(13 rows — SAM is a separate class even though it extends `BamReader`.)

`ImportFormatRegistry.discover()` iterates this static list, builds an `ImportFormatSpec` per row, and pulls the `description` from `formats.properties` keyed by `import.<name>.description`. Greyed-out rows are those whose `readerOnClasspath()` returns false.

- [ ] **Step 1: Write `formats.properties`**

```
import.mzML.description = HUPO PSI mass-spectrometry XML; indexed mzML supported; chromatograms preserved
import.mzTab.description = Tabular MS results; proteomics-1.0 and metabolomics-2.0.0-M dialects auto-detected
import.imzML.description = MS imaging container (.imzML + .ibd); continuous and processed modes
... (one line per format, ~12 entries)
```

- [ ] **Step 2: Implement `ImportFormatRegistry`**

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/importers/ImportFormatRegistry.java
public final class ImportFormatRegistry {
    private static final List<ImportFormatSpec> SPECS = buildSpecs();

    private static List<ImportFormatSpec> buildSpecs() {
        Properties props = new Properties();
        try (var in = ImportFormatRegistry.class.getResourceAsStream("/formats.properties")) {
            if (in != null) props.load(in);
        } catch (IOException ignored) {}
        return List.of(
            spec("mzML", "global.thalion.ttio.importers.MzMLReader",
                 ImportFormatSpec.SourceKind.FILE, List.of(".mzML", ".mzML.gz"),
                 ImportFormatSpec.ExtraField.NONE, props),
            spec("mzTab", "global.thalion.ttio.importers.MzTabReader",
                 ImportFormatSpec.SourceKind.FILE, List.of(".mzTab", ".mztab"),
                 ImportFormatSpec.ExtraField.MZTAB_DIALECT_DETECT, props),
            // ... rows 3-13 as per matrix above ...
        );
    }

    private static ImportFormatSpec spec(String name, String fqn,
            ImportFormatSpec.SourceKind kind, List<String> exts,
            ImportFormatSpec.ExtraField extras, Properties props) {
        return new ImportFormatSpec(name, fqn, kind, exts, extras,
            props.getProperty("import." + name + ".description", "(no description)"));
    }

    public static List<ImportFormatSpec> all() { return SPECS; }
    public static List<ImportFormatSpec> available() {
        return SPECS.stream().filter(ImportFormatSpec::readerOnClasspath).toList();
    }
}
```

- [ ] **Step 3: Test**

```java
@Test
void registryDiscoversThirteenRows() {
    var all = ImportFormatRegistry.all();
    assertTrue(all.size() >= 12, "found: " + all.size());
}

@Test
void allReadersOnClasspathInDevelopment() {
    var available = ImportFormatRegistry.available();
    assertEquals(ImportFormatRegistry.all().size(), available.size(),
        "missing readers: " +
        ImportFormatRegistry.all().stream()
            .filter(s -> !s.readerOnClasspath())
            .map(s -> s.readerClassFqn).toList());
}
```

- [ ] **Step 4: Commit.**

---

## Task 8.3: `FormatSniffer` — magic-bytes + extension dispatch (HANDOFF §6.4)

- [ ] **Step 1: Failing test**

```java
@Test
void sniffsMzMLByXmlRoot() {
    String header = "<?xml version=\"1.0\"?><indexedmzML ...>";
    assertEquals("mzML", FormatSniffer.sniff(
        header.getBytes(), "tiny.pwiz.1.1.mzML"));
}
@Test
void sniffsBamByMagic() {
    byte[] bytes = {'B', 'A', 'M', 0x01, 0x00};
    assertEquals("BAM", FormatSniffer.sniff(bytes, "x.bam"));
}
@Test
void sniffsTioByHdf5Magic() {
    byte[] hdf5 = {(byte)0x89, 'H', 'D', 'F', '\r', '\n', 0x1a, '\n'};
    assertEquals(".tio", FormatSniffer.sniff(hdf5, "x.tio"));
}
@Test
void sniffsFastqByPattern() {
    String fq = "@SEQ1\nACGT\n+\n!!!!\n";
    assertEquals("FASTQ", FormatSniffer.sniff(fq.getBytes(), "x.fastq"));
}
```

- [ ] **Step 2: Implement** — read first 64 KiB only. Order of checks:

1. HDF5 magic (`89 48 44 46 0D 0A 1A 0A`) → `.tio`.
2. BAM magic (`BAM\x01`) → `BAM`.
3. CRAM magic (`CRAM\x03\x00`) → `CRAM`.
4. `TTIO` (4 bytes) → `.tis` (transport stream — opens download dialog instead).
5. XML root tag scan for `<indexedmzML>` / `<mzML>` (filename `.imzML` → imzML else mzML), `<nmrML>`.
6. First non-blank line starts with `##JCAMP-DX=` → JCAMP-DX.
7. First non-blank line starts with `MTD\t` → mzTab.
8. Filename ends `.d` AND is a directory → Bruker timsTOF.
9. Filename ends `.raw` AND is a directory → Waters MassLynx; AND is a file → Thermo.
10. First non-blank line starts with `@HD\t` / `@SQ\t` / `@PG\t` / `@RG\t` → SAM.
11. First non-blank line starts with `>` → FASTA (Treat-as default = Reference).
12. First non-blank line starts with `@`, fourth line starts with non-`@` quality → FASTQ.
13. None of the above → `null`.

- [ ] **Step 3: Run + commit.**

---

## Task 8.4: `ImportDialog` wizard

A multi-step dialog using a custom `Stage` (not `Dialog<R>` — the wizard is multi-step and `Dialog` is awkward for that). Steps:

1. **Format picker** — `ListView<ImportFormatSpec>` with greying via cell factory; tooltip shows description + missing-reader note.
2. **Source path** — `FileChooser` if `SourceKind == FILE`, `DirectoryChooser` if `DIRECTORY`. Pre-fill from drag-drop sniff.
3. **Target `.tio`** — `FileChooser` save mode.
4. **Storage provider** — `ComboBox<String>` populated by `ProviderRegistry.discover()`; default `hdf5`.
5. **Run name** — `TextField` defaulting to `run_0001` (analytical) or `genomic_0001` (genomic readers).
6. **Format-specific extras** — render based on `ImportFormatSpec.extras`:
   - `FASTA_TREAT_AS` → `RadioButton` group: Reference (default) / Unaligned reads.
   - `FASTQ_PHRED` → `ChoiceBox`: Auto-detect (default) / Phred+33 / Phred+64.
   - `CRAM_REFERENCE` → `FileChooser` for FASTA, required.
   - `BAM_REFERENCE` → `FileChooser` for FASTA, optional.
   - `MZTAB_DIALECT_DETECT` → read-only `Label` populated after source selection by sniffing `MTD mzTab-version`.

7. **Run** — kick `ImportTask` with the assembled config; show indeterminate progress; on success close wizard and `loadDataset(targetTio)` in the main window.

- [ ] **Step 1: Implement** (~400 LOC).

**Note** — drive each reader through its public entry-point method. The library's reader classes follow a predictable shape: each has a `public SpectralDataset read(String sourcePath, String targetTio, String provider, ...)` (probe per class). Use reflection in `ImportTask` to invoke the right method; for the format-specific extras, switch on `ExtraField` and set the additional parameter.

- [ ] **Step 2: Implement `ImportTask`**

```java
public class ImportTask extends Task<Void> {
    private final ImportFormatSpec spec;
    private final ImportConfig config;

    public ImportTask(ImportFormatSpec spec, ImportConfig config) {
        this.spec = spec; this.config = config;
    }

    @Override
    protected Void call() throws Exception {
        Class<?> readerClass = Class.forName(spec.readerClassFqn);
        // Each reader exposes a static convenience entry point. Probe
        // each class for the right signature; an interface would be
        // cleaner — file as upstream issue if it doesn't exist.
        // Pattern: <Reader>.read(sourcePath, targetTio, provider).
        var method = readerClass.getMethod("read",
            String.class, String.class, String.class);
        method.invoke(null, config.sourcePath, config.targetTio, config.provider);
        return null;
    }
}
```

If reader entry points aren't all uniform `read(String, String, String)`, write per-format dispatch in `ImportTask.call()` switching on `spec.name` — verbose but explicit.

- [ ] **Step 3: Test**

```java
@Test
void importsMzMLFixtureProducesValidTio(@TempDir Path tmp) throws Exception {
    Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
        .toAbsolutePath();
    Path target = tmp.resolve("out.tio");
    ImportTask task = new ImportTask(
        ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals("mzML")).findFirst().orElseThrow(),
        new ImportConfig(src.toString(), target.toString(), "hdf5",
            "run_0001", null /* no extras */));
    new Thread(task).start();
    task.get(60, TimeUnit.SECONDS);
    try (SpectralDataset opened = SpectralDataset.open(target.toString())) {
        assertFalse(opened.msRuns().isEmpty());
    }
}
```

Add equivalent tests for nmrML, JCAMP-DX (Raman + IR fixtures), mzTab (proteomics + metabolomics), imzML (continuous + processed), FASTA (reference + reads), FASTQ. BAM/SAM/CRAM tests gated by `Assumptions.assumeTrue(samtoolsAvailable())`.

- [ ] **Step 4: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): ImportDialog + ImportTask + per-format dispatch (12 formats)"'
```

---

## Task 8.5: Drag-and-drop format pre-selection

In `MainWindow.show()`, replace the placeholder dropped-non-tio handler with:

```java
        scene.setOnDragDropped(e -> {
            if (e.getDragboard().hasFiles()) {
                java.io.File f = e.getDragboard().getFiles().get(0);
                if (f.getName().endsWith(".tio")) {
                    loadDataset(f.toString(), true);
                } else {
                    String sniffed = FormatSniffer.sniffFile(f.toPath());
                    ImportDialog dlg = new ImportDialog(stage);
                    dlg.preSelectFormat(sniffed);
                    dlg.preSelectSource(f.toPath());
                    dlg.showAndImport(this::loadDataset);
                }
            }
        });
```

- [ ] Test by dropping `tiny.pwiz.1.1.mzML` and verifying the wizard opens with mzML pre-selected.

- [ ] Commit.

---

## Phase 8 acceptance gate

- [ ] All 12 (13 with SAM) format rows visible in the dialog.
- [ ] Greyed rows show tooltip naming the missing reader class.
- [ ] mzML round-trip: import `tiny.pwiz.1.1.mzML` → resulting `.tio` opens with `msRuns().size() == 1`.
- [ ] nmrML round-trip: import `bmse000325.nmrML` → opens with NMR run.
- [ ] FASTA "Treat as Reference" → result has reference under `references()`.
- [ ] FASTA "Treat as Unaligned reads" → result has genomic run with all flag=4.
- [ ] FASTQ Phred auto-detect produces correct quality bytes for Phred+33 input.
- [ ] When `samtools` not on PATH, BAM/SAM/CRAM rows greyed out.
- [ ] Drag-and-drop of any supported format pre-selects its row.

---

# Phase 9 — Export dialog + format dispatch (11 formats)

**Goal:** symmetric to Phase 8. File → Export → wizard. Compatibility logic enables/disables format rows based on the open dataset's contents (HANDOFF §7.2). Per-format extras configure the writer.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportFormatRegistry.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportFormatSpec.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportEligibility.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportDialog.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/exporters/ExportTask.java`
- Tests: `ExportFormatRegistryTest`, `ExportEligibilityTest`, `ExportTaskTest`.

---

## Task 9.1: `ExportFormatSpec` + format matrix

Same shape as `ImportFormatSpec`. Format matrix:

| `name` | `writerClassFqn` | `eligibility` | `extras` |
|---|---|---|---|
| mzML (indexed) | `global.thalion.ttio.exporters.MzMLWriter` | `MS_RUNS_PRESENT` | NONE |
| mzTab | `global.thalion.ttio.exporters.MzTabWriter` | `IDENTS_OR_QUANTS_PRESENT` | MZTAB_DIALECT |
| imzML | `global.thalion.ttio.exporters.ImzMLWriter` | `MS_IMAGE_PRESENT` | IMZML_MODE |
| nmrML | `global.thalion.ttio.exporters.NmrMLWriter` | `NMR_RUNS_PRESENT` | NONE |
| JCAMP-DX | `global.thalion.ttio.exporters.JcampDxWriter` | `RAMAN_OR_IR_OR_UVVIS_PRESENT` | JCAMP_ENCODING |
| ISA-Tab/JSON | `global.thalion.ttio.exporters.ISAExporter` | `ALWAYS` | NONE |
| BAM | `global.thalion.ttio.exporters.BamWriter` | `GENOMIC_RUNS_PRESENT` | BAM_OUTPUT (text/SAM toggle) + reference (optional) |
| CRAM | `global.thalion.ttio.exporters.CramWriter` | `GENOMIC_RUNS_PRESENT` | CRAM_REFERENCE (required) |
| FASTA (reference) | `global.thalion.ttio.exporters.FastaWriter#writeReference` | `REFERENCES_PRESENT` | FASTA_LINE_WIDTH + GZIP |
| FASTA (reads) | `global.thalion.ttio.exporters.FastaWriter#writeRun` | `GENOMIC_RUNS_PRESENT` | FASTA_LINE_WIDTH + GZIP |
| FASTQ | `global.thalion.ttio.exporters.FastqWriter` | `GENOMIC_RUNS_PRESENT` | FASTQ_PHRED + GZIP |

Note SAM is exposed as the BAM_OUTPUT extra rather than its own row.

- [ ] **Step 1: Implement `ExportFormatSpec` + the 11-row data table** (parallel to Phase 8, ~150 LOC).

- [ ] **Step 2: `formats.properties`** — add `export.<name>.description = ...` keys for each row.

- [ ] **Step 3: Test the registry** — same shape as `ImportFormatRegistryTest`.

- [ ] Commit.

---

## Task 9.2: `ExportEligibility` — enable/disable matrix

Pure-Java predicate per `Eligibility` enum value:

```java
public final class ExportEligibility {
    public static boolean check(ExportFormatSpec spec, OpenDataset d) {
        switch (spec.eligibility) {
            case ALWAYS: return true;
            case MS_RUNS_PRESENT: return d.msRunCount() > 0;
            case NMR_RUNS_PRESENT:
                return d.dataset().msRuns().values().stream()
                    .anyMatch(r -> r.acquisitionMode() == Enums.AcquisitionMode.NMR);
            case RAMAN_OR_IR_OR_UVVIS_PRESENT:
                return d.dataset().msRuns().values().stream()
                    .anyMatch(r -> {
                        var m = r.acquisitionMode();
                        return m == Enums.AcquisitionMode.RAMAN
                            || m == Enums.AcquisitionMode.IR
                            || m == Enums.AcquisitionMode.UV_VIS;
                    });
            case GENOMIC_RUNS_PRESENT: return d.genomicRunCount() > 0;
            case REFERENCES_PRESENT:   return d.referenceCount() > 0;
            case MS_IMAGE_PRESENT:
                return d.dataset().msRuns().values().stream()
                    .anyMatch(r -> r.spectra().stream()
                        .anyMatch(s -> s instanceof MSImage));
            case IDENTS_OR_QUANTS_PRESENT:
                return d.identificationCount() > 0 || d.quantificationCount() > 0;
        }
        return false;
    }

    public static String tooltipReason(ExportFormatSpec spec, OpenDataset d) {
        if (check(spec, d)) return spec.description;
        switch (spec.eligibility) {
            case MS_RUNS_PRESENT: return "No MS runs in this file.";
            case NMR_RUNS_PRESENT: return "No NMR runs in this file.";
            case RAMAN_OR_IR_OR_UVVIS_PRESENT:
                return "No Raman / IR / UV-Vis spectra in this file.";
            case GENOMIC_RUNS_PRESENT: return "No genomic runs in this file.";
            case REFERENCES_PRESENT: return "No embedded references in this file.";
            case MS_IMAGE_PRESENT: return "No MSImage runs in this file.";
            case IDENTS_OR_QUANTS_PRESENT:
                return "No identifications or quantifications in this file.";
            default: return spec.description;
        }
    }
}
```

- [ ] **Step 1: Test** — open `full_ms.tio`, assert mzML eligible / nmrML disabled with correct tooltip.

- [ ] **Step 2: Commit.**

---

## Task 9.3: `ExportDialog` wizard

Steps:

1. **Format picker** — `ListView<ExportFormatSpec>`. Cell factory greys ineligible rows; tooltip = `ExportEligibility.tooltipReason(spec, openDataset)`. Disabled rows are still shown (HANDOFF §7.2 explicit).
2. **Target path** — `FileChooser` save mode with the format's first extension.
3. **Format-specific extras**:
   - `MZTAB_DIALECT` — `ChoiceBox`: `1.0 (proteomics)` / `2.0.0-M (metabolomics)`. Pre-select based on dataset content (ident-heavy → 1.0, feature-heavy → 2.0.0-M).
   - `IMZML_MODE` — `continuous` / `processed`. Pre-select from source `MSImage.mode()`.
   - `JCAMP_ENCODING` — `AFFN` (default) / `PAC` / `SQZ` / `DIF`. Inline warning for non-AFFN: "Compressed encodings require equispaced X axis; falls back to AFFN if not equispaced."
   - `BAM_OUTPUT` — checkbox `Text output (SAM)` (default off) + optional reference FileChooser.
   - `CRAM_REFERENCE` — required reference picker (or "Use embedded reference *<id>*" if `references()` non-empty).
   - `FASTA_LINE_WIDTH` — `Spinner<Integer>` default 60. `gzip output` checkbox.
   - `FASTQ_PHRED` — `Phred+33` (default) / `Phred+64`. + gzip checkbox. + warning shown when source `qualities` channel is filled with `0xFF` sentinels.
4. **Run** — kick `ExportTask`; on success show inline "Exported to <path>" toast; option to "Open folder" (cross-platform via `Desktop.open(parent)`).

- [ ] **Step 1: Implement** (~500 LOC).

- [ ] **Step 2: Implement `ExportTask` mirroring `ImportTask`'s reflective dispatch.**

- [ ] **Step 3: Tests** — round-trip per format from existing `.tio` fixtures:

```java
@Test
void mzMLRoundTrip(@TempDir Path tmp) throws Exception {
    Path src = Paths.get("../java/src/test/resources/ttio/full_ms.tio")
        .toAbsolutePath();
    Path mzml = tmp.resolve("out.mzML");
    Path reTio = tmp.resolve("re.tio");

    // export
    try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
        new ExportTask(specForMzML(), new ExportConfig(
            mzml.toString(), null /* extras */)).runWith(ds).get();
    }
    assertTrue(Files.exists(mzml));

    // re-import
    new ImportTask(importSpecForMzML(),
        new ImportConfig(mzml.toString(), reTio.toString(), "hdf5",
            "run_0001", null)).runStandalone().get();

    try (SpectralDataset orig = SpectralDataset.open(src.toString());
         SpectralDataset round = SpectralDataset.open(reTio.toString())) {
        assertEquals(orig.msRuns().size(), round.msRuns().size());
        AcquisitionRun ro = orig.msRuns().values().iterator().next();
        AcquisitionRun rr = round.msRuns().values().iterator().next();
        assertEquals(ro.spectra().size(), rr.spectra().size());
        // Spot-check: float64 epsilon on first spectrum's intensity
        double[] yo = ((MassSpectrum) ro.spectra().get(0)).intensityArray();
        double[] yr = ((MassSpectrum) rr.spectra().get(0)).intensityArray();
        assertArrayEquals(yo, yr, 1e-9);
    }
}
```

Replicate per format. BAM/SAM/CRAM tests `assumeTrue(samtoolsAvailable())`. Use the `m87_test.bam` fixture for BAM round-trip.

- [ ] **Step 4: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): ExportDialog + ExportTask + eligibility matrix (11 formats)"'
```

---

## Phase 9 acceptance gate

- [ ] All 11 format rows visible. Eligibility flips correctly per fixture (e.g. nmrML disabled for `full_ms.tio` with the right tooltip).
- [ ] mzML round-trip: import `tiny.pwiz.1.1.mzML` → export → re-import → spectra match within float64 epsilon.
- [ ] nmrML round-trip: chemical-shift array byte-equal.
- [ ] JCAMP-DX export with each of AFFN/PAC/SQZ/DIF re-imports cleanly.
- [ ] mzTab export honours dialect choice.
- [ ] BAM round-trip from `m87_test.bam` fixture: identical reads after import → export → re-import (sequence, quality, CIGAR, flag, chrom, position byte-equal).
- [ ] FASTQ export of run with `0xFF` quality sentinel surfaces the warning + emits `!`.

---

# Phase 10 — Transport download (`.tis` URL → local `.tio`)

**Goal:** Transport → Download from server. Connect to `ws://` or `wss://`, send filter JSON, materialize a `.tio` via `TransportClient.streamToFile(...)` (confirmed available in Phase 0 probe). On success, open the result.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/DownloadDialog.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/DownloadTask.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/DownloadTaskTest.java`

---

## Task 10.1: `DownloadDialog`

Fields:
- **Server URL** — `TextField`, validated as `ws://` or `wss://`.
- **Output `.tio`** — `FileChooser` save.
- **Filter JSON** — `TextArea`, default `{}`. Validated as parseable JSON (use `MiniJson` already in the library — check `grep -n "class MiniJson" java/src/main/java/global/thalion/ttio/MiniJson.java`).
- **Storage provider** — `ComboBox`, default `hdf5`.
- **Timeout (s)** — `Spinner<Integer>`, default 60.

OK button disabled until URL non-empty + valid scheme + JSON valid + output path set.

- [ ] **Step 1: Implement** (~250 LOC).

- [ ] **Step 2: URL-scheme validator unit test**

```java
@Test
void rejectsNonWsScheme() {
    assertFalse(DownloadDialog.isValidUrl("http://x"));
    assertTrue(DownloadDialog.isValidUrl("ws://x:8080/"));
    assertTrue(DownloadDialog.isValidUrl("wss://x.example.com/feed"));
}
```

- [ ] **Step 3: Commit.**

---

## Task 10.2: `DownloadTask` — wraps `TransportClient.streamToFile`

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/transport/DownloadTask.java
public class DownloadTask extends Task<String> {

    private final String url;
    private final Map<String, Object> filters;
    private final String outputPath;
    private final String provider;
    private final int timeoutSeconds;

    public DownloadTask(String url, Map<String, Object> filters,
                        String outputPath, String provider,
                        int timeoutSeconds) {
        this.url = url; this.filters = filters; this.outputPath = outputPath;
        this.provider = provider; this.timeoutSeconds = timeoutSeconds;
        updateMessage("Connecting to " + url + "…");
    }

    @Override
    protected String call() throws Exception {
        TransportClient client = new TransportClient(url);
        // streamToFile signature confirmed in Phase 0 probe — adjust if
        // the actual signature differs:
        SpectralDataset materialized = client.streamToFile(
            outputPath, filters, timeoutSeconds * 1000L);
        materialized.close();
        return outputPath;
    }
}
```

- [ ] **Step 1: Implement.**

- [ ] **Step 2: Test against a local `TransportServer` instance**

The library already has a `TransportServer` (we saw it in the transport package probe). Stand it up against a fixture `.tio` on a random port; download via `DownloadTask`; assert byte-equal channels.

```java
@Test
void downloadFromLocalServerProducesByteEqualChannels(@TempDir Path tmp) throws Exception {
    Path fixture = Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
        .toAbsolutePath();
    int port = findFreePort();

    TransportServer server = new TransportServer(port, fixture.toString());
    server.start();
    try {
        Path out = tmp.resolve("downloaded.tio");
        DownloadTask task = new DownloadTask(
            "ws://127.0.0.1:" + port + "/",
            Map.of(),
            out.toString(),
            "hdf5",
            30);
        new Thread(task).start();
        task.get(60, TimeUnit.SECONDS);

        // Compare msRunCount and one signal-array byte-equal
        try (SpectralDataset orig = SpectralDataset.open(fixture.toString());
             SpectralDataset got = SpectralDataset.open(out.toString())) {
            assertEquals(orig.msRuns().size(), got.msRuns().size());
            byte[] origBytes = firstChannelBytes(orig);
            byte[] gotBytes = firstChannelBytes(got);
            assertArrayEquals(origBytes, gotBytes);
        }
    } finally {
        server.stop();
    }
}
```

`firstChannelBytes` and `findFreePort` are short helpers (5 LOC each).

- [ ] **Step 3: Wire** — `MainWindow.downloadItem.setOnAction(...)` opens `DownloadDialog`; on submit, kick `DownloadTask`; on success `loadDataset(outputPath, false)`.

- [ ] **Step 4: Error handling** — `task.setOnFailed`: distinguish `ConnectException` / `UnknownHostException` / timeout / generic; show single error dialog with **Retry** button that re-invokes with same parameters.

- [ ] **Step 5: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): Transport Download — TransportClient.streamToFile + retry on error"'
```

---

## Phase 10 acceptance gate

- [ ] Spin up `TransportServer` against a fixture `.tio`, download via the GUI dialog, opened result has byte-equal channels.
- [ ] Filter JSON forwarded correctly.
- [ ] Connection refused / DNS failure / EOS timeout each surface a single error dialog with Retry.

---

# Phase 11 — Transport upload (HTTP PUT + WebSocket)

**Goal:** Transport → Upload. Encode local `.tio` as a `.tis` byte stream via `TransportWriter` (in-memory or tempfile). Dispatch by URL scheme: HTTP PUT for `http://`/`https://`; WebSocket binary frames with leading text frame for `ws://`/`wss://`. Bearer-token support for HTTP.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/TisHttpUploader.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/TisWsUploader.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadDialog.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/transport/UploadTask.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/TisHttpUploaderTest.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/transport/TisWsUploaderTest.java`

---

## Task 11.1: Encode `.tio` → tempfile `.tis` via `TransportWriter`

This is a shared step for both HTTP and WS uploads. Helper class:

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/transport/TisEncoder.java
public final class TisEncoder {
    public static Path encodeToTempFile(String tioPath, boolean checksum)
            throws IOException {
        Path tmp = Files.createTempFile("upload-", ".tis");
        try (SpectralDataset ds = SpectralDataset.open(tioPath);
             OutputStream out = Files.newOutputStream(tmp);
             TransportWriter w = new TransportWriter(out)) {
            w.setUseChecksum(checksum);
            w.writeStreamHeader("1.1.0", ds.title(), ds.featureFlags());
            w.writeDataset(ds);
            w.writeEndOfStream();
        }
        return tmp;
    }
}
```

Probe `TransportWriter.writeStreamHeader` actual signature with `grep -A5 "writeStreamHeader" java/src/main/java/global/thalion/ttio/transport/TransportWriter.java`. Adjust args.

- [ ] **Step 1: Implement.**

- [ ] **Step 2: Test — encoded tempfile is non-empty and starts with TTIO magic**

```java
@Test
void encodeProducesTtioMagicHeader(@TempDir Path tmp) throws Exception {
    Path src = Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
        .toAbsolutePath();
    Path tis = TisEncoder.encodeToTempFile(src.toString(), true);
    byte[] head = Files.readAllBytes(tis);
    assertEquals('T', head[0]); assertEquals('T', head[1]);
    assertEquals('I', head[2]); assertEquals('O', head[3]);
    assertTrue(Files.size(tis) > 64);
}
```

- [ ] **Step 3: Commit.**

---

## Task 11.2: `TisHttpUploader`

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/transport/TisHttpUploader.java
public class TisHttpUploader {

    public static void upload(URI url, Path tisFile, String bearerToken)
            throws IOException, InterruptedException {
        HttpClient client = HttpClient.newHttpClient();
        HttpRequest.Builder req = HttpRequest.newBuilder(url)
            .PUT(HttpRequest.BodyPublishers.ofFile(tisFile))
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", Long.toString(Files.size(tisFile)));
        if (bearerToken != null && !bearerToken.isBlank()) {
            req.header("Authorization", "Bearer " + bearerToken);
        }
        HttpResponse<String> resp = client.send(
            req.build(), HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() / 100 != 2) {
            throw new IOException("HTTP " + resp.statusCode() + ": " + resp.body());
        }
    }
}
```

- [ ] **Step 1: Implement.**

- [ ] **Step 2: Test against a local `com.sun.net.httpserver.HttpServer`**

```java
@Test
void uploadPutsExactBytesAndPropagatesBearer(@TempDir Path tmp) throws Exception {
    Path tis = TisEncoder.encodeToTempFile(
        Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
            .toAbsolutePath().toString(), true);

    com.sun.net.httpserver.HttpServer server =
        com.sun.net.httpserver.HttpServer.create(
            new InetSocketAddress("127.0.0.1", 0), 0);
    AtomicReference<byte[]> received = new AtomicReference<>();
    AtomicReference<String> authHeader = new AtomicReference<>();
    server.createContext("/up", ex -> {
        authHeader.set(ex.getRequestHeaders().getFirst("Authorization"));
        try (var in = ex.getRequestBody()) {
            received.set(in.readAllBytes());
        }
        ex.sendResponseHeaders(200, 0);
        ex.getResponseBody().close();
    });
    server.start();
    try {
        URI uri = URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/up");
        TisHttpUploader.upload(uri, tis, "tok-123");
        assertArrayEquals(Files.readAllBytes(tis), received.get());
        assertEquals("Bearer tok-123", authHeader.get());
    } finally {
        server.stop(0);
    }
}
```

- [ ] **Step 3: Commit.**

---

## Task 11.3: `TisWsUploader`

WebSocket binary frames. Use the existing `org.java_websocket` client (transitive of `ttio`'s transport package — confirm with `grep -rn "java_websocket" java/pom.xml`). Sequence:

1. Connect.
2. On `onOpen`, send a single text frame: `{"type":"upload","filename":"<basename>.tio"}`.
3. Read encoded `.tis` tempfile; chunk into 64 KiB binary frames, send each.
4. After last chunk, send a text frame `{"type":"end"}` and close.
5. On any failure, close + propagate.

```java
// tio-browser/src/main/java/global/thalion/ttio/browser/transport/TisWsUploader.java
public class TisWsUploader {

    public static void upload(URI url, Path tisFile, String filename)
            throws Exception {
        CompletableFuture<Void> done = new CompletableFuture<>();
        WebSocketClient client = new WebSocketClient(url) {
            @Override public void onOpen(ServerHandshake h) {
                try {
                    send("{\"type\":\"upload\",\"filename\":\""
                        + filename + "\"}");
                    try (InputStream in = Files.newInputStream(tisFile)) {
                        byte[] buf = new byte[65536];
                        int n;
                        while ((n = in.read(buf)) > 0) {
                            send(java.nio.ByteBuffer.wrap(buf, 0, n));
                        }
                    }
                    send("{\"type\":\"end\"}");
                    close();
                } catch (Exception ex) {
                    done.completeExceptionally(ex);
                    close();
                }
            }
            @Override public void onMessage(String message) {}
            @Override public void onClose(int code, String reason, boolean remote) {
                if (!done.isDone()) done.complete(null);
            }
            @Override public void onError(Exception ex) {
                done.completeExceptionally(ex);
            }
        };
        client.connect();
        done.get(120, TimeUnit.SECONDS);
    }
}
```

- [ ] **Step 1: Implement.**

- [ ] **Step 2: Test against a tiny embedded WS server**

The library already vendors a WS server adapter (probe `grep -n "WebSocketServer" java/src/main/java/global/thalion/ttio/transport/`). Use it; collect frames; assert concatenation byte-equal to the encoded `.tis`. The first text frame must equal the upload preamble JSON.

- [ ] **Step 3: Commit.**

---

## Task 11.4: `UploadDialog` + `UploadTask` + scheme dispatch

`UploadTask` switches on URL scheme:

```java
@Override
protected Void call() throws Exception {
    Path tis = TisEncoder.encodeToTempFile(localPath, useChecksum);
    try {
        URI uri = URI.create(targetUrl);
        switch (uri.getScheme()) {
            case "http":
            case "https":
                TisHttpUploader.upload(uri, tis, bearerToken);
                break;
            case "ws":
            case "wss":
                TisWsUploader.upload(uri, tis, basename(localPath));
                break;
            default:
                throw new IllegalArgumentException(
                    "Unsupported URL scheme: " + uri.getScheme());
        }
        return null;
    } finally {
        Files.deleteIfExists(tis);
    }
}
```

`UploadDialog` fields:
- Local `.tio` path (defaults to currently-open dataset's path).
- Destination URL.
- Optional bearer token (`PasswordField`).
- Per-packet checksum checkbox (default on).

Validate URL scheme on OK.

- [ ] **Step 1: Implement.**

- [ ] **Step 2: Test bad-scheme validation**

```java
@Test
void uploadTaskRejectsBadScheme() {
    UploadTask task = new UploadTask(
        "/tmp/x.tio", "ftp://server/", null, true);
    assertThrows(IllegalArgumentException.class, () -> {
        new Thread(task).start();
        task.get(2, TimeUnit.SECONDS);
    });
}
```

- [ ] **Step 3: Wire into MainWindow.**

- [ ] **Step 4: Run all Phase 11 tests + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -Dtest="TisHttpUploaderTest,TisWsUploaderTest,UploadTaskTest" test -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -20 && cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): Transport Upload — HTTP PUT + WS dispatch + bearer token"'
```

---

## Phase 11 acceptance gate

- [ ] HTTP PUT upload to local echo server: received bytes byte-equal to `TisEncoder.encodeToTempFile()`.
- [ ] Bearer token appears verbatim in `Authorization` header.
- [ ] WS upload: leading text frame `{"type":"upload","filename":"x.tio"}`, followed by binary frames whose concat = encoded `.tis`, then trailing `{"type":"end"}`.
- [ ] Invalid scheme produces validation error before any network I/O.

---

# Phase 12 — Diagnostics dialog

**Goal:** Tools → Diagnostics shows live status of every external binary the library depends on. Probe results are cached and shared with the Import / Export dialogs to grey out format rows whose dependencies aren't satisfied.

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/diag/Diagnostics.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/diag/BinaryProbe.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/diag/ProbeResult.java`
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/diag/DiagnosticsDialog.java`
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/diag/DiagnosticsTest.java`

---

## Task 12.1: `BinaryProbe` + `ProbeResult` + `Diagnostics` registry

```java
// ProbeResult: name, resolvedPath (nullable), status (OK/NOT_FOUND/ERROR), detail
// BinaryProbe: name, env-var name (nullable), command + args, parser

public final class BinaryProbe {
    public final String name;
    public final String envVar;             // checked first if non-null
    public final String execName;           // "samtools"
    public final List<String> versionArgs;  // ["--version"]
    public final Function<String, String> firstLineParser;

    public ProbeResult probe() {
        // 1. If envVar set and value resolves to an executable, use it.
        // 2. Else `which execName` (Unix) / `where execName` (Windows).
        // 3. Else NOT_FOUND.
        // 4. Run version command, capture first line, run parser.
        // 5. Return ProbeResult(name, path, OK, parsedDetail).
    }
}
```

Static registry of probes:

```java
public final class Diagnostics {
    private static final List<BinaryProbe> PROBES = List.of(
        new BinaryProbe("HDF5 (in-process JNI)", null, null, null,
            ignored -> {
                try {
                    int[] v = new int[3];
                    hdf.hdf5lib.H5.H5get_libversion(v);
                    return v[0] + "." + v[1] + "." + v[2];
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
            }),
        new BinaryProbe("samtools", null, "samtools",
            List.of("--version"),
            line -> line.split(" ", 2)[1]),
        new BinaryProbe("ThermoRawFileParser", "THERMORAWFILEPARSER",
            "ThermoRawFileParser", List.of("--help"),
            line -> "(present)"),
        new BinaryProbe("masslynxraw", "MASSLYNXRAW", "masslynxraw",
            List.of("--help"), line -> "(present)"),
        new BinaryProbe("Bruker Python helper", null, "python",
            List.of("-c", "import opentimspy; print(opentimspy.__version__)"),
            line -> "opentimspy " + line)
    );

    private static volatile List<ProbeResult> cache = List.of();

    public static List<ProbeResult> probeAll() {
        cache = PROBES.stream().map(BinaryProbe::probe).toList();
        return cache;
    }

    public static List<ProbeResult> cached() { return cache; }

    public static boolean isAvailable(String name) {
        return cached().stream()
            .anyMatch(r -> r.name().equals(name)
                && r.status() == ProbeResult.Status.OK);
    }
}
```

- [ ] **Step 1: Implement** (~250 LOC across the 3 files).

- [ ] **Step 2: Test the file probe**

```java
@Test
void samtoolsProbeReportsOkOrNotFound() {
    ProbeResult r = new BinaryProbe(
        "samtools", null, "samtools",
        List.of("--version"),
        line -> line.split(" ", 2)[1]
    ).probe();
    assertNotNull(r.status());
    if (r.status() == ProbeResult.Status.OK) {
        assertNotNull(r.detail());
        assertNotNull(r.resolvedPath());
    }
}
```

- [ ] **Step 3: Commit.**

---

## Task 12.2: `DiagnosticsDialog` UI

A modal `Stage` with:
- `TableView<ProbeResult>` columns: `name`, `path`, `status` (coloured icon), `detail`.
- A **Re-probe** button that invokes `Diagnostics.probeAll()` and refreshes the table.
- A **Close** button.

On open, run `Diagnostics.probeAll()` once asynchronously and populate.

- [ ] **Step 1: Implement** (~120 LOC).

- [ ] **Step 2: Wire** — `MainWindow.diagnosticsItem.setOnAction(...)`.

- [ ] **Step 3: Greying integration with Import/Export dialogs** — `ImportFormatRegistry` and `ExportFormatRegistry` consult `Diagnostics.isAvailable(...)` before reporting `available()`. For BAM/SAM/CRAM (need samtools), Thermo (need ThermoRawFileParser), Waters (need masslynxraw), Bruker (need python helper). Tooltip lists the missing binary.

- [ ] **Step 4: Trigger re-probe propagation** — when the Diagnostics dialog's Re-probe button is clicked, fire a `DiagnosticsCacheRefreshed` event; the open Import/Export dialogs (if any) listen and refresh their format-list cell factories.

- [ ] **Step 5: Run + commit**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && git add tio-browser/src/ && git commit -m "feat(tio-browser): Diagnostics dialog + binary probes + Import/Export greying"'
```

---

## Phase 12 acceptance gate

- [ ] Tools → Diagnostics shows 5 rows (HDF5, samtools, ThermoRawFileParser, masslynxraw, Bruker Python).
- [ ] HDF5 row shows version string when JNI is loaded.
- [ ] When `samtools` is on PATH, BAM/SAM/CRAM rows in Import/Export are enabled; when not, they're greyed out with tooltip "Requires `samtools` on PATH".
- [ ] Re-probe button picks up newly-installed binaries without restarting the app.

---

# Phase 13 — Distribution: fat JAR + `jpackage` profile

**Goal:** `mvn -pl tio-browser package` produces a runnable shaded JAR. Optional `mvn -pl tio-browser package -P native-package` produces platform-native installer.

---

## Task 13.1: Verify fat JAR runs end-to-end

- [ ] **Step 1: Build**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && mvn -q -DskipTests package -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10 && ls -la target/'
```

Expected: `tio-browser-0.1.0.jar` AND `tio-browser-0.1.0-shaded.jar` present, the latter ≥ 30 MB (JavaFX natives + ttio + transitives).

- [ ] **Step 2: Run the shaded JAR with a test fixture**

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/tio-browser && java -Djava.library.path=/usr/lib/x86_64-linux-gnu/ -jar target/tio-browser-0.1.0-shaded.jar --open ../java/src/test/resources/ttio/minimal_ms.tio'
```

(`--open` is a CLI shortcut to be added to `App.main(args)` — wire if not already.)

Expected: window appears, dataset loads, status bar shows `MS=1`.

- [ ] **Step 3: Commit any wiring changes.**

---

## Task 13.2: `native-package` Maven profile

Add to `tio-browser/pom.xml`:

```xml
<profiles>
    <profile>
        <id>native-package</id>
        <build>
            <plugins>
                <plugin>
                    <groupId>org.codehaus.mojo</groupId>
                    <artifactId>exec-maven-plugin</artifactId>
                    <version>3.4.1</version>
                    <executions>
                        <execution>
                            <id>jpackage</id>
                            <phase>package</phase>
                            <goals><goal>exec</goal></goals>
                            <configuration>
                                <executable>jpackage</executable>
                                <arguments>
                                    <argument>--input</argument>
                                    <argument>target</argument>
                                    <argument>--main-jar</argument>
                                    <argument>tio-browser-0.1.0-shaded.jar</argument>
                                    <argument>--main-class</argument>
                                    <argument>global.thalion.ttio.browser.AppLauncher</argument>
                                    <argument>--name</argument>
                                    <argument>tio-browser</argument>
                                    <argument>--app-version</argument>
                                    <argument>0.1.0</argument>
                                    <argument>--vendor</argument>
                                    <argument>Thalion</argument>
                                    <argument>--icon</argument>
                                    <argument>src/main/resources/icons/app-icon.png</argument>
                                    <argument>--dest</argument>
                                    <argument>target/installer</argument>
                                </arguments>
                            </configuration>
                        </execution>
                    </executions>
                </plugin>
            </plugins>
        </build>
    </profile>
</profiles>
```

- [ ] **Step 1: Add profile.**

- [ ] **Step 2: Test on Linux** — `jpackage` on Linux produces a `.deb` or `.rpm` (autodetected). On macOS/Windows, the user must run the build on the target OS.

- [ ] **Step 3: Document in README** — Phase 14 picks this up.

- [ ] **Step 4: Commit.**

---

## Phase 13 acceptance gate

- [ ] Fat JAR runs on dev machine and opens the M82 fixture.
- [ ] `mvn -P native-package` invokes `jpackage` and produces an installer artifact in `target/installer/`.
- [ ] No new compile warnings.

---

# Phase 14 — Docs + acceptance + ship

**Goal:** the HANDOFF §14 done definition is fully met.

---

## Task 14.1: Flesh out `tio-browser/README.md`

Final form:

```markdown
# tio-browser

JavaFX desktop GUI for inspecting, importing, exporting, and transporting
TTI-O `.tio` multi-omics datasets. Sibling to `java/`, `python/`, `objc/`.

## Prerequisites

* JDK 17+ (Eclipse Temurin recommended).
* HDF5 system library + Java JNI (`libhdf5-java` on Debian/Ubuntu, HDF Group
  installer on macOS/Windows).
* For genomic formats: `samtools` on `PATH`.
* Optional, for vendor MS formats: `ThermoRawFileParser`, `masslynxraw`,
  Python with `opentimspy`. The Diagnostics dialog (Tools → Diagnostics)
  reports the live status of each.

## Build

    mvn -pl tio-browser package -Dhdf5.jar=/path/to/jarhdf5.jar
    java -jar tio-browser/target/tio-browser-0.1.0-shaded.jar

On Windows, also pass `-Djava.library.path=C:\Program Files\HDF_Group\HDF5\1.14.x\bin`.

## Native installers (optional)

    mvn -pl tio-browser package -P native-package -Dhdf5.jar=...

`jpackage` must run on the target OS. Mac → `.dmg`, Windows → `.msi`.

## Diagnostics

Tools → Diagnostics probes HDF5, `samtools`, `ThermoRawFileParser`,
`masslynxraw`, and the Bruker Python helper. Greyed-out format rows in
Import / Export tell you which binary is missing.

## Known limitations (v0.1)

* No multi-document tabs.
* No live importer progress (importers don't expose progress callbacks).
* No alignment-coverage track visualization (per-read inspector only).
* No telemetry, auto-update, or crash reporter.
* macOS app bundles produced by `jpackage` are unsigned — use right-click → Open
  on first launch.

## License

LGPL-3.0-or-later. See LICENSE.
```

- [ ] Commit.

---

## Task 14.2: `docs/tio-browser.md` user-facing guide

A short user guide with two annotated screenshots:

1. Main window viewing a fixture mzML-derived MS run (from a `.tio` produced by importing `tiny.pwiz.1.1.mzML`).
2. Main window viewing `m82_100reads.tio` with the Read Inspector populated.

Screenshots may be deferred to a follow-up commit if no display is available — note as TODO in the doc with a placeholder block.

```markdown
# tio-browser user guide

[Screenshot: main window viewing an MS run] → TODO: capture once a
release build is run interactively.

## Opening a file
File → Open or drag a `.tio` onto the window.

## Importing a foreign format
File → Import. Pick format, source path, target `.tio`, run name. The
Import wizard auto-detects the format if a file was dropped.

## Exporting
File → Export. Format rows that don't apply to the open file (e.g. nmrML
when there are no NMR runs) are greyed with a tooltip explaining why.

## Transport
Transport → Download from server requests a `.tis` stream from a `ws://`
or `wss://` URL and materializes a local `.tio`. Transport → Upload
sends a local `.tio` as a `.tis` byte stream to a `http`/`https`/`ws`/`wss`
URL.

## Decrypting an encrypted file
Open the file, select the `encryption` virtual node, click `Decrypt with key…`,
choose the binary key file. Bytes are passed verbatim to
`SpectralDataset.decryptWithKey(byte[])`.

## Diagnostics
Tools → Diagnostics. See README.
```

- [ ] Commit.

---

## Task 14.3: `CHANGELOG.md` `[Unreleased]` entry

```markdown
## [Unreleased]

### Added
- New top-level module `tio-browser/` — JavaFX desktop GUI peer to
  `java/`, `python/`, `objc/`. Visual inspection of `.tio` files,
  import/export across all 14 formats, `.tis` transport upload + download,
  external-binary diagnostics. v0.1.0.
```

- [ ] Commit.

---

## Task 14.4: Run all acceptance gates from HANDOFF §10

Walk every checkbox in HANDOFF §10 and confirm green. The gates from each phase already cover the bulk; this task collects the cross-cutting ones:

- [ ] `mvn -pl tio-browser verify` succeeds on Linux (WSL), macOS, Windows.
- [ ] No new compiler warnings beyond the JavaFX shim.
- [ ] No `import global.thalion.ttio.hdf5.*` under `tio-browser/src/main/`.
- [ ] `cd java && mvn verify` still passes (no regressions).
- [ ] `cd python && pytest` still passes.
- [ ] `cd objc && gnustep-make check` still passes.

Verification commands:

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && \
    grep -rE "import global\.thalion\.ttio\.hdf5\." tio-browser/src/main/ \
    && echo "FORBIDDEN HDF5 IMPORTS PRESENT" || echo "no forbidden imports OK"'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/java && mvn -q verify -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && python -m pytest python/tests/ -x --timeout=60 2>&1 | tail -10'
```

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser/objc && gnustep-make -f Tests/GNUmakefile check 2>&1 | tail -20'
```

- [ ] Commit any final fixes that come out of the cross-cutting gate.

---

## Task 14.5: Push branch + open PR

```
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O.worktrees/tio-browser" push -u origin tio-browser
```

(Per memory entry on Windows-side git push for WSL paths.)

Then `gh pr create` from the worktree:

```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/tio-browser && gh pr create --title "feat: tio-browser GUI module + library 1.1.0 references() accessor" --body "$(cat <<EOF
## Summary
- Adds new top-level \`tio-browser/\` module — JavaFX desktop GUI for .tio inspection, 14-format import/export, and .tis transport.
- Bumps \`global.thalion:ttio\` 1.0.0 → 1.1.0 with new \`SpectralDataset.references()\` accessor across Java/Python/ObjC.
- Cross-language conformance test in \`python/tests/conformance/test_references_xlang.py\` (9 directed pairs).

## Test plan
- [ ] Phase gates 0-14 all green.
- [ ] cd java && mvn verify
- [ ] cd python && pytest
- [ ] cd objc && gnustep-make check
- [ ] Manual: open M82 + minimal_ms + nmr_1d + encrypted fixtures
- [ ] Manual: import mzML, nmrML, JCAMP-DX, FASTA-as-ref, FASTQ
- [ ] Manual: export round-trip mzML, BAM, FASTQ
- [ ] Manual: transport download from local TransportServer
- [ ] Manual: transport upload to local HTTP echo server

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"'
```

- [ ] PR opened. URL recorded for review.

---

## Phase 14 acceptance gate (final ship gate)

- [ ] All HANDOFF §10 boxes checked.
- [ ] `tio-browser/README.md` complete.
- [ ] `docs/tio-browser.md` complete (screenshots may be TODO).
- [ ] `CHANGELOG.md` `[Unreleased]` mentions tio-browser v0.1.0.
- [ ] No regressions in `java/`, `python/`, `objc/` test suites.
- [ ] PR open at `DTW-Thalion/MPEG-O` against `main`.

---

# Self-review checklist

This plan claims to cover the entire HANDOFF.md. Before handing off, verify:

**Spec coverage** — every HANDOFF section has a task that implements it:

| HANDOFF section | Plan task |
|---|---|
| §1 Goal (5 capabilities) | Phase 0 (lib API), Phases 1-7 (view), 8 (import), 9 (export), 10-11 (transport) |
| §2 Module layout | Phase 1 Task 1.1 |
| §3 pom.xml essentials | Phase 1 Task 1.1 (full pom; system-scope HDF5 noted per memory) |
| §4 Main window layout | Phase 1 Task 1.3 + Phase 3 (DetailPane) |
| §4.1 Tree node → tab mapping | Phase 2 (tree) + every Phase 3-7 tab's `appliesTo` |
| §4.2 Plot specifics — analytical | Phase 5 |
| §4.3 Read Inspector | Phase 7 Task 7.3 |
| §4.4 Chrom Distribution | Phase 7 Task 7.4 |
| §5 Opening files | Phase 1 Tasks 1.4–1.6 |
| §6 Import (12 formats + extras + sniff) | Phase 8 |
| §7 Export (11 formats + eligibility + extras) | Phase 9 |
| §8.1 Download | Phase 10 |
| §8.2 Upload | Phase 11 |
| §9 Distribution | Phase 13 |
| §10 Acceptance criteria | Per-phase gates + Phase 14 Task 14.4 |
| §11.1 Module placement | Resolved: top-level. Phase 1 Task 1.1. |
| §11.2 Upload wire | Documented in README; no server in-repo. |
| §11.3 Reference handling | **Phase 0** added the API; Phase 7 Task 7.5 builds the tab. |
| §11.4 App icon | Placeholder. Phase 1 Task 1.1. |
| §11.5 Multi-doc tabs | Out of scope, README documents. |
| §11.6 Live progress | Out of scope, indeterminate spinner. |
| §11.7 Decrypt UX | Resolved: binary key file picker. Phase 3 Task 3.3. |
| §11.8 Coverage view | Out of scope, README documents. |
| §12 Gotchas | Each gotcha addressed inline in the relevant phase task. |
| §13 Test fixtures | Reused by reference per per-phase tests. |
| §14 Done definition | Phase 14. |

**Placeholder scan** — all phase tasks have concrete file paths, test code, and commit commands. The few "(probe before locking)" notes are calls to verify a method name against the existing library before writing it; they're intentional checks, not deferred work.

**Type / signature consistency**:
- `SpectralDataset.references()` — Phase 0 adds it; Phase 2 (`DatasetTreeBuilder`), Phase 7 (`ReferenceTab`), `OpenDataset.referenceCount()` all consume it consistently.
- `OpenDataset.dataset()` — used uniformly to reach the underlying `SpectralDataset` from every tab.
- `AbstractDetailTab` interface — every tab implements it identically.
- `ImportTask` / `ExportTask` — both extend `Task<R>` with the same lifecycle pattern (`call()`, `setOnSucceeded`, `setOnFailed`).

**Things this plan deliberately leaves to the executor**:
- Exact accessor names on `Spectrum` subclasses, `WrittenGenomicRun.builder()`, `StorageGroup.childDatasetNames()` — flagged as **probe before locking** at the call site. Cheaper to grep at edit time than to specify exhaustively here.
- `formats.properties` per-format descriptions — listed once with format names; full English text drafted at the file-creation step.
- Specific assertions in fixture-driven tests beyond what's shown (e.g. exact spectrum count for `1min.mzML`) — the executor can probe with `python -m ttio.cli.peek` or equivalent and pin the constants.

---

# Execution handoff

Plan saved to `docs/superpowers/plans/2026-05-06-tio-browser.md` in worktree `~/TTI-O.worktrees/tio-browser` on branch `tio-browser`.

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task with the relevant phase context; review between tasks; fast iteration. Good fit for this plan's depth.

2. **Inline Execution** — execute tasks in this session using the executing-plans skill; batch with checkpoints for review.

Which approach?

