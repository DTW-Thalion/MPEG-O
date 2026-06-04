# P1.2 — Java/ObjC GenomicIndex region-query vectorization — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Finish the parity gap PR #202 left: vectorize `GenomicIndex.indicesForRegion`/`indicesForFlag` in **Java** and **Objective-C** by retaining the interned `chromosome_ids` (already loaded from disk, then discarded today) and scanning integer comparisons instead of per-read string compares. Byte-identical results, faster.

**Architecture:** Pure optimization — **identical returned indices (same order), faster**. No wire/format/API change. Disk-loaded indexes carry interned uint16 ids + a name→id map; `indicesForRegion` resolves the query chromosome to its id once, then scans `ids[i] == targetId && start <= positions[i] < end`. In-memory-constructed indexes (encode side, no ids) keep the existing string-compare fallback — exactly as Python #202 does (`indices_for_region` in `python/src/ttio/genomic_index.py:126-146`).

**Hard invariant:** `indicesForRegion`/`indicesForFlag` return the **same indices in the same order** as before, for both disk-loaded and in-memory indexes — verified by an old-vs-new equivalence test. No change to `writeTo`/on-disk bytes.

**Reference:** OO assessment P1.2; Python reference `python/src/ttio/genomic_index.py:126-146` (interned-id branch + fallback). Java: `java/src/main/java/global/thalion/ttio/genomics/GenomicIndex.java`. ObjC: `objc/Source/Genomics/TTIOGenomicIndex.{h,m}`.

**Verified facts (baseline `main`):**
- Java `GenomicIndex`: in-memory holds only `List<String> chromosomes` (`:37`); `indicesForRegion` does `chromosomes.get(i).equals(chromosome)` + `out.add(i)` boxing (`:84-94`); `indicesForFlag` `(flags[i]&mask)!=0` + boxing (`:99-104`). `readFrom` (`:181-216`) reads `chromosome_ids` (short[] `ids`, `:194`) + `chromosome_names`, rebuilds `chroms` List<String>, and **discards `ids`** when calling `new GenomicIndex(...)`. Returns `List<Integer>`.
- ObjC `TTIOGenomicIndex`: `indicesForRegion` does `[_chromosomes[i] isEqualToString:chromosome]` (`:118`); `readFromGroup` reads `chromosome_ids` (`:254`) then builds `_chromosomes`, discarding the ids. Returns `NSIndexSet`.
- Both write chromosomes as encounter-order uint16 ids on disk (Task #82 Phase B.1) — the id↔name correspondence is available at read time.

---

### Task PJ1: Java `GenomicIndex` — retain interned ids + vectorize

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/genomics/GenomicIndex.java`
- Test: `java/src/test/java/global/thalion/ttio/genomics/GenomicIndexRegionQueryTest.java`

- [ ] **Step 1: Study** `readFrom` (`:181-216`) — how `ids` (short[], one uint16 per read) + `chromosome_names` (compound id→name) are read and turned into `chroms`. Note the id is unsigned (Java `short` is signed; use `& 0xFFFF`). Study the existing public constructor + `indicesForRegion`/`indicesForFlag`/`chromosomeAt`.
- [ ] **Step 2: Write the equivalence test** `GenomicIndexRegionQueryTest.java`:
  - Build a genomic `.tio` with ≥2 chromosomes and reads at varied positions (reuse `test`-side genomic fixture helpers — `grep -rn "GenomicIndex\|WrittenGenomicRun\|genomic_index" java/src/test`), write + reopen so the index is DISK-LOADED (has interned ids).
  - For several `(chromosome, start, end)` queries (incl. a chromosome NOT present, an empty range, the full range, boundary positions `start`/`end`), assert `indicesForRegion(...)` returns the **exact same List<Integer> (same order)** as a reference scalar computation (compute the expected indices independently in the test via `chromosomeAt(i)` + `positionAt(i)`). Same for `indicesForFlag` over a few masks (incl. 0x4 unmapped).
  - Also test an IN-MEMORY-constructed index (via the public constructor, no disk ids) to exercise the fallback path — same equivalence.
- [ ] **Step 3: Run** against current code → PASS (baseline; current behavior is the reference). `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest=GenomicIndexRegionQueryTest test`
- [ ] **Step 4: Implement**
  - Add nullable fields: `private final short[] chromosomeIds;` (per-read uint16 ids, null when constructed in-memory) and `private final java.util.Map<String,Integer> chromosomeNameToId;` (null when no ids). Add a private constructor (or extend the existing one) that accepts them; keep the existing public constructor passing `null, null` (in-memory path → fallback).
  - In `readFrom`, retain `ids` + build the `nameToId` map from `chromosome_names` (the id→name compound: invert it), and pass them to the new constructor (still also pass `chroms` for `chromosomeAt`).
  - Rewrite `indicesForRegion`: if `chromosomeIds != null`, `Integer tid = chromosomeNameToId.get(chromosome); if (tid == null) return List.of();` then scan `for i: if ((chromosomeIds[i] & 0xFFFF) == tid && positions[i] >= start && positions[i] < end) add`. Else (null) keep the existing `chromosomes.get(i).equals(...)` loop. Collect into a primitive growable (e.g. an `int[]` with size-doubling, or a two-pass count+fill) and box into `List<Integer>` ONCE at the end to avoid per-add autoboxing. Preserve ascending-index order.
  - `indicesForFlag`: keep the int scan but use the same primitive accumulator → one boxing pass (minor; the flag path has no string compare).
  - Do NOT change `writeTo`, `chromosomeAt`, or the on-disk format.
- [ ] **Step 5: Run** the equivalence test + the genomic suite → green, identical results:
  `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest='GenomicIndexRegionQueryTest,*GenomicIndex*,*GenomicRun*' test`
- [ ] **Step 6: Microbench** (report only): build a 1M-read index (one chromosome), time `indicesForRegion` old-vs-new (`git stash`); report speedup.
- [ ] **Step 7: Commit** `perf(java-genomic): vectorize GenomicIndex region/flag queries via interned ids`.

---

### Task PO1: ObjC `TTIOGenomicIndex` — retain interned ids + vectorize

**Files:**
- Modify: `objc/Source/Genomics/TTIOGenomicIndex.{h,m}`
- Test: `objc/Tests/TestGenomicIndexRegionQuery.m` (register 3 surfaces)

Mirror PJ1 for ObjC. `readFromGroup` (`:230-270`) already reads `idsData` (chromosome_ids) — retain it + build a name→id map; `indicesForRegion` resolves the query once + scans uint16 comparisons; keep the `isEqualToString:` fallback for in-memory indexes. Returns `NSIndexSet` (no boxing concern; the win is the string→int compare).

- [ ] **Step 1: Study** `readFromGroup` (`:230-270`), `indicesForRegion` (`:110-126`), the in-memory init + how `_chromosomes` is built. Note the uint16 ids.
- [ ] **Step 2: Failing/equivalence test** `TestGenomicIndexRegionQuery.m`: build a genomic `.tio` with ≥2 chromosomes, reopen (disk-loaded), assert `indicesForRegion:start:end:` returns the same `NSIndexSet` as an independent scalar computation (via `chromosomeAt:`/`positionAt:`); cover absent chromosome, empty/full range, boundaries; flag queries. Also an in-memory-constructed index (fallback path).
- [ ] **Step 3: Run** current code → PASS baseline (`cd ~/TTI-O/objc && ./build.sh check` after registering).
- [ ] **Step 4: Implement** — retain a `uint16_t *` (or `NSData` of ids) + an `NSDictionary<NSString*,NSNumber*> *nameToId` (nullable, set only on disk-load); `indicesForRegion`: if ids present, `NSNumber *tid = nameToId[chromosome]; if (!tid) return [NSIndexSet indexSet];` then scan `ids[i] == tid.unsignedShortValue && pos in range` into an `NSMutableIndexSet`; else keep `isEqualToString:`. No on-disk/format/`chromosomeAt:` change. Register any new test via the 3 surfaces.
- [ ] **Step 5: `cd ~/TTI-O/objc && ./build.sh check`** → green (identical results); remove stray `build-check.log`.
- [ ] **Step 6: Commit** `perf(objc-genomic): vectorize TTIOGenomicIndex region/flag queries via interned ids`.

---

### Task PF1: Regression + CHANGELOG

- [ ] **Step 1:** Java genomic suite green (`JAVA_HOME=~/jdk25 mvn -o -Djacoco.skip=true -Dtest='*Genomic*' test`) + full `./build.sh check` ObjC green (already from PO1). Note: a FULL `mvn verify` runs the jacoco 0.84 gate — the new test + small code change shouldn't drop coverage, but run `mvn -o verify -B` once to confirm the gate holds (the new public-ish code is small + tested). If coverage dips below 0.84, add a test or BLOCK-report.
- [ ] **Step 2: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Performance — Vectorized genomic region/flag queries (Java + Objective-C)

  `GenomicIndex.indicesForRegion`/`indicesForFlag` (Java) and
  `TTIOGenomicIndex` (Objective-C) now scan the interned `chromosome_ids`
  (uint16) with integer comparisons instead of a per-read string compare,
  resolving the query chromosome to its id once — finishing the parity with the
  Python `indices_for_region` vectorization (PR #202). Identical returned
  indices; no wire/format change. (OO-assessment P1.2.)
  ```
- [ ] **Step 3: Commit** `docs: changelog for Java/ObjC genomic query vectorization (P1.2)`.

---

## Self-review notes (author)
- **Identical results is the bar.** Both tasks' equivalence tests compare new vs an independent scalar reference (same indices, same order) for disk-loaded AND in-memory indexes (fallback). The interned-id path must return empty when the query chromosome is absent (matches the old string-compare-never-matches behavior).
- **No wire/format change** — `writeTo`/`chromosomeAt`/on-disk layout untouched; the ids are already on disk (just retained in memory now). Unsigned uint16 handling: Java `& 0xFFFF`.
- This completes **P1** (P1.3/P1.4 shipped in #217; P1.2 here). Next: **P2.5 shared Image base**.
