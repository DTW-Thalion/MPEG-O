# Drop genomic signal_channels integer-field duplicates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop writing `positions`, `flags`, `mapping_qualities` under `signal_channels/` for genomic runs. These three fields are per-record metadata that already live in `genomic_index/` (where the reader actually reads them). The duplicate copies in `signal_channels/` are dead bytes — provisioned for an aspirational "streaming reader prefers signal_channels" future that never arrived. Removing them brings genomic in line with MS's clean separation (`spectrum_index/` = metadata, `signal_channels/` = bulk data).

**Architecture:** Three-language synchronous wire-format change. Drop the writer code in Python/Java/ObjC, remove the dead read helpers (`_int_channel_array` for these names, `_TTIO_M86_WriteIntChannelStorage` for these names, `writeIntChannelWithCodec` calls for these names), reject the corresponding `signal_codec_overrides` keys at write-time. Old files (with the duplicates) remain readable since the active reader path uses `genomic_index/`. New files are ~3.87 MB smaller on chr22 (1.77M reads).

**Tech Stack:** Python (h5py), Java (HDF5/Maven), Objective-C (GNUstep + libhdf5), shared HDF5 wire format. No new dependencies.

---

## Background — current state

**Three-language inventory** (verified with grep before writing this plan):

| Language | Writer file | Override validation | Reader helper |
|---|---|---|---|
| Python | `python/src/ttio/spectral_dataset.py:1635-1668` (3 calls to `_write_int_channel_with_codec`) | (validation lives in same file via `_resolve_int_override`) | `python/src/ttio/genomic_run.py:_INTEGER_CHANNEL_DTYPES` (dict has *only* these 3 names) + `_int_channel_array` method |
| Java | `java/src/main/java/global/thalion/ttio/SpectralDataset.java:1048,1112,1115` (3 calls to `writeIntChannelWithCodec`) | `:835-868` (`Set.of("positions", "flags", "mapping_qualities", ...)` allowed-codecs map) | `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java` integer-channel codec read path |
| ObjC | `objc/Source/Dataset/TTIOSpectralDataset.m:2117-2125, 2552-2560` (2 sites: HDF5 fast path + provider-abstracted path) | `:119-218` (allowed-codecs dictionary) | `objc/Source/Genomics/TTIOGenomicRun.m` int-channel decode path (`_TTIO_M86_*`) |

**Reader path verified:**
- Per-record `__getitem__` → `GenomicIndex.{positions, mapping_qualities, flags}` (from genomic_index/)
- M89 transport (`transport/encrypted.py:303-311`) → reads `genomic_index/` directly, NOT signal_channels
- `_int_channel_array(name)` Python helper exists but per its docstring is "callable but not currently called by `__getitem__`" (Binding Decision §119) — no external callers found via grep

**chr22 lean+mapped baseline (current):**
- Total: 109,129,739 bytes
- `signal_channels/positions`: 2,809,635 bytes (byte-identical to `genomic_index/positions`)
- `signal_channels/flags`: 941,257 bytes (byte-identical to `genomic_index/flags`)
- `signal_channels/mapping_qualities`: 307,648 bytes (byte-identical to `genomic_index/mapping_qualities`)
- **Duplicate total: 4,058,540 bytes (~3.87 MB)**

---

## Task 1: Verification baseline + capture pre-change byte sizes

**Files:**
- Read-only verification

- [ ] **Step 1: Confirm git state is clean and at the post-Stage-3 / threaded-histogram baseline**

```bash
wsl -d Ubuntu -- bash -c '
cd /home/toddw/TTI-O && git status --short && git log --oneline -3
'
```

Expected: working tree clean, HEAD points to the threaded-histogram commit (or its push-rebased equivalent on origin/main).

- [ ] **Step 2: Confirm current chr22 .tio has the duplicates we expect to remove**

```bash
wsl -d Ubuntu -- bash -c '
cd /home/toddw/TTI-O && .venv/bin/python -c "
import h5py
f = h5py.File(\"/home/toddw/TTI-O/tools/perf/_out_bench/profile.tio\", \"r\")
sc = f[\"study/genomic_runs/run_0001/signal_channels\"]
gi = f[\"study/genomic_runs/run_0001/genomic_index\"]
total_dup = 0
for ch in [\"positions\", \"flags\", \"mapping_qualities\"]:
    sc_size = sc[ch].id.get_storage_size()
    gi_size = gi[ch].id.get_storage_size()
    print(f\"{ch}: sc={sc_size}, gi={gi_size}\")
    total_dup += min(sc_size, gi_size)
print(f\"TOTAL DUPLICATE: {total_dup} bytes\")"
'
```

Expected: `TOTAL DUPLICATE: 4058540 bytes` (or similar, within ~1KB).

If the file `/home/toddw/TTI-O/tools/perf/_out_bench/profile.tio` is missing, re-run the chr22 benchmark first:

```bash
wsl -d Ubuntu -- bash -c '
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m tools.benchmarks.cli run \
    --dataset chr22_na12878_mapped --formats ttio \
    --json-out /home/toddw/TTI-O/tools/perf/_out_bench/chr22_baseline.json
'
```

- [ ] **Step 3: No commit (read-only verification task)**

---

## Task 2: Find all writer + override + reader sites in Python

**Files:**
- Read-only inventory of `python/src/ttio/spectral_dataset.py`, `python/src/ttio/genomic_run.py`, `python/src/ttio/written_genomic_run.py`, `python/src/ttio/_hdf5_io.py`

- [ ] **Step 1: Locate Python writer call sites**

```bash
wsl -d Ubuntu -- bash -c "
grep -nE '_resolve_int_override|_write_int_channel_with_codec' /home/toddw/TTI-O/python/src/ttio/spectral_dataset.py | head -10
"
```

Expected: 3 calls to `_write_int_channel_with_codec` writing positions/flags/mapping_qualities under `sc` (signal_channels) at lines around 1635, 1661, 1665 (numbers may shift after recent edits — read the actual content).

- [ ] **Step 2: Locate the override map**

```bash
wsl -d Ubuntu -- bash -c "
grep -nE 'signal_codec_overrides|_resolve_int_override' /home/toddw/TTI-O/python/src/ttio/spectral_dataset.py | head -20
"
```

Find the `_resolve_int_override` helper (or similar) that gates the `signal_codec_overrides` keys. Note its allowed-keys list.

- [ ] **Step 3: Locate `_INTEGER_CHANNEL_DTYPES`**

```bash
wsl -d Ubuntu -- bash -c "
grep -nA 5 '_INTEGER_CHANNEL_DTYPES' /home/toddw/TTI-O/python/src/ttio/genomic_run.py
"
```

Confirm the dict has *only* `positions`, `flags`, `mapping_qualities` (already verified — confirm again as guard against drift).

- [ ] **Step 4: Find any callers of `_int_channel_array`**

```bash
wsl -d Ubuntu -- bash -c "
grep -rn '_int_channel_array' /home/toddw/TTI-O/python/ /home/toddw/TTI-O/tools/ 2>&1 | grep -v '__pycache__\|\.pyc'
"
```

Expected: only the definition site in `genomic_run.py` and possibly its own error-message string. No external callers. Verify and capture for later removal.

- [ ] **Step 5: No commit (inventory only)**

---

## Task 3: Update Python tests to expect new on-disk layout

**Files:**
- Modify: any tests that assert presence of `signal_channels/{positions,flags,mapping_qualities}`

- [ ] **Step 1: Find tests that touch these dataset paths**

```bash
wsl -d Ubuntu -- bash -c "
grep -rnE 'signal_channels.*positions|signal_channels.*flags|signal_channels.*mapping_qualities' /home/toddw/TTI-O/python/tests/ 2>&1 | head -20
"
```

For each match, decide:
- If the test asserts the DATASET EXISTS in signal_channels → update to assert it DOES NOT exist (or removed entirely)
- If the test reads from signal_channels for these fields → update to read from genomic_index
- If the test asserts a codec-override-on-positions effect → mark as expected-to-fail (XFail) or remove

- [ ] **Step 2: Find tests that test the override API for these channels**

```bash
wsl -d Ubuntu -- bash -c "
grep -rnE 'signal_codec_overrides.*positions|signal_codec_overrides.*flags|signal_codec_overrides.*mapping_quality' /home/toddw/TTI-O/python/tests/ 2>&1 | head -10
"
```

For each match, update the assertion to the new behavior: setting these keys raises a `ValueError`.

- [ ] **Step 3: Find tests that call `_int_channel_array`**

```bash
wsl -d Ubuntu -- bash -c "
grep -rn '_int_channel_array' /home/toddw/TTI-O/python/tests/ 2>&1
"
```

Update or remove tests that exercise this helper for these three channel names.

- [ ] **Step 4: Run the targeted tests to capture current state**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/ -k 'genomic_index or signal_channels or int_channel or m86' --tb=short 2>&1 | tail -10
"
```

Expected: tests that you have NOT yet edited may pass against the OLD code; tests you HAVE edited will fail (because writer still writes the duplicates). This step is the RED phase.

- [ ] **Step 5: No commit yet (tests are in transitional / failing state until Task 4 lands)**

---

## Task 4: Drop Python writer code for the three duplicate channels

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py` (around lines 1635, 1661, 1665 — the three `_write_int_channel_with_codec` calls under `sc` for positions/flags/mapping_qualities)

- [ ] **Step 1: Read the current writer code**

```bash
wsl -d Ubuntu -- bash -c "
sed -n '1620,1685p' /home/toddw/TTI-O/python/src/ttio/spectral_dataset.py
"
```

Identify the exact block writing positions, flags, mapping_qualities under `sc` (signal_channels). Note any context (override-resolution helpers, nearby comments).

- [ ] **Step 2: Remove the three writes**

The block writes:

```python
io._write_int_channel_with_codec(
    sc, "positions", run.positions, run.signal_compression,
    _resolve_int_override("positions"),
)
# … (similar for flags) …
# … (similar for mapping_qualities) …
```

Replace with a comment block explaining the removal:

```python
# v1.6: positions/flags/mapping_qualities are NOT written under
# signal_channels/. They live exclusively in genomic_index/, mirroring
# MS's spectrum_index/ pattern (per-record metadata = index;
# signal_channels = bulk data). See docs/format-spec.md §4 and §10.7.
# Old files (v1.5 and earlier) may have these channels under
# signal_channels — readers ignore them; the genomic_index/ copy is
# the canonical source.
```

- [ ] **Step 3: Update `_resolve_int_override` to reject these channel names**

If `_resolve_int_override` checks the override key against an allow-list, remove these three keys from the allow-list and add a hard-error path:

```python
_DROPPED_INT_CHANNELS = frozenset({"positions", "flags", "mapping_qualities"})

def _resolve_int_override(channel: str):
    if channel in _DROPPED_INT_CHANNELS:
        raise ValueError(
            f"signal_codec_overrides[{channel!r}]: removed in v1.6 — "
            f"these per-record integer fields are stored only under "
            f"genomic_index/, not signal_channels/. Override no longer "
            f"applies."
        )
    # … existing logic for other channels (cigars, mate_info_*, etc.) …
```

If `_resolve_int_override` is a generic helper that doesn't have a per-channel allow-list, add the check at the dispatch site in `_write_genomic_run` instead — before the writer block, validate that none of the three keys are present in `run.signal_codec_overrides`.

- [ ] **Step 4: Run the affected tests to verify Python passes**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/ -k 'genomic_index or signal_channels or int_channel or m86' --tb=short 2>&1 | tail -15
"
```

Expected: tests updated in Task 3 now pass (writer no longer emits the duplicates; override raises). Tests not updated may now fail — those are tests that need updating. Iterate until green.

- [ ] **Step 5: Run the broader Python test suite**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/ --ignore=python/tests/integration --tb=short 2>&1 | tail -10
"
```

Expected: all non-integration tests pass. (Integration tests may temporarily fail due to cross-language fixture mismatch — that's Task 9's gate.)

- [ ] **Step 6: Commit Python writer change (still pre-cross-lang sync — Java/ObjC will diverge until their tasks land)**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && git add python/src/ttio/spectral_dataset.py python/tests/ && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"\$(cat <<'EOF'
feat(L4 v1.6 Python): drop signal_channels/{positions,flags,mapping_qualities}

Per-record integer metadata fields lived in BOTH genomic_index/ AND
signal_channels/ — the genomic_index/ copy is the canonical source
(reader path goes through GenomicIndex), the signal_channels/ copies
were dead bytes provisioned for an aspirational 'streaming reader
prefers signal_channels' future that never arrived.

Drop the writer code; reject the three keys from signal_codec_overrides
with a clear error. Old files (v1.5 and earlier) are unaffected — the
reader continues to use genomic_index/.

~3.87 MB savings on chr22 (1.77M reads). Java + ObjC follow in the
next two commits to preserve cross-language byte-equality.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)\""
```

---

## Task 5: Drop Java writer code

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java` (around lines 1048, 1112, 1115)

- [ ] **Step 1: Read the current Java writer block**

```bash
wsl -d Ubuntu -- bash -c "
sed -n '1040,1130p' /home/toddw/TTI-O/java/src/main/java/global/thalion/ttio/SpectralDataset.java
"
```

- [ ] **Step 2: Remove the three writeIntChannelWithCodec calls**

The block looks like:

```java
writeIntChannelWithCodec(sc, "positions",
    run.positions(), run.signalCompression(),
    resolveIntOverride(run, "positions"));
// (similar for flags + mapping_qualities)
```

Replace with a comment:

```java
// v1.6: positions/flags/mapping_qualities are NOT written under
// signal_channels/. They live exclusively in genomic_index/, mirroring
// the MS spectrum_index/ pattern. See docs/format-spec.md §4 and §10.7.
// Old files (v1.5 and earlier) may carry these under signal_channels —
// readers ignore them; the genomic_index/ copy is canonical.
```

- [ ] **Step 3: Update the override allow-list (around lines 835-868)**

Find the `Set.of("positions", java.util.Set.of(...), "flags", ..., "mapping_qualities", ...)` map. Remove these three entries from the allowed-codec map. Add a hard error path on detection:

```java
private static final java.util.Set<String> DROPPED_INT_CHANNELS =
    java.util.Set.of("positions", "flags", "mapping_qualities");

// At the override-validation site (around line 835-868):
for (String channel : run.signalCodecOverrides().keySet()) {
    if (DROPPED_INT_CHANNELS.contains(channel)) {
        throw new IllegalArgumentException(
            "signalCodecOverrides[\"" + channel + "\"]: removed in v1.6 — "
            + "these per-record integer fields are stored only under "
            + "genomic_index/, not signal_channels/. Override no longer "
            + "applies.");
    }
    // existing logic for other channels …
}
```

- [ ] **Step 4: Update Java tests that assert dual-write**

```bash
wsl -d Ubuntu -- bash -c "
grep -rnE 'signal_channels.*positions|signal_channels.*flags|signal_channels.*mapping_qualities|signalChannels.*positions' /home/toddw/TTI-O/java/src/test/ 2>&1 | head -20
"
```

Update each match: dataset should NOT exist in signal_channels; override should raise.

- [ ] **Step 5: Run Java tests**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O/java && mvn test -Dtest='*GenomicRun*,*M82*,*M86*' \
    -Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:/home/toddw/TTI-O/native/_build \
    2>&1 | tail -15
"
```

Expected: BUILD SUCCESS with all M82/M86/GenomicRun tests passing.

- [ ] **Step 6: Strip CRLF + commit**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && sed -i 's/\r\$//' java/src/main/java/global/thalion/ttio/SpectralDataset.java && git add java/src/main/java/global/thalion/ttio/SpectralDataset.java java/src/test/ && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"feat(L4 v1.6 Java): drop signal_channels/{positions,flags,mapping_qualities}

Java writer mirror of the Python change. Per-record integer metadata
no longer dual-written under signal_channels/; canonical home is
genomic_index/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 6: Drop ObjC writer code

**Files:**
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.m` (TWO sites: HDF5 fast path around line 2117 + provider-abstracted path around line 2552)

- [ ] **Step 1: Read both writer sites**

```bash
wsl -d Ubuntu -- bash -c "
echo '--- HDF5 fast path ---'
sed -n '2110,2135p' /home/toddw/TTI-O/objc/Source/Dataset/TTIOSpectralDataset.m
echo '--- provider-abstracted path ---'
sed -n '2548,2570p' /home/toddw/TTI-O/objc/Source/Dataset/TTIOSpectralDataset.m
"
```

- [ ] **Step 2: Remove both for-loops over the three integer channels**

At each site, the loop:

```objc
NSDictionary *intChannels = @{
    @"positions"         : run.positionsData,
    @"flags"             : run.flagsData,
    @"mapping_qualities" : run.mappingQualitiesData,
};
for (NSString *chName in @[@"positions", @"flags", @"mapping_qualities"]) {
    if (!_TTIO_M86_WriteIntChannelStorage(
            sc, chName, intChannels[chName], codec,
            _TTIO_M95_ResolveIntOverride(run, chName), error))
        return NO;
}
```

Remove entirely; replace with comment:

```objc
// v1.6: positions/flags/mapping_qualities are NOT written under
// signal_channels/. They live exclusively in genomic_index/. See
// docs/format-spec.md §4 and §10.7.
```

- [ ] **Step 3: Update the override allow-list (lines 119, 197-199, 218)**

Find the dictionary/array literals listing these three channel names and:
1. Remove the three entries from any "allowed override" list
2. Add a hard-error guard at the override-validation site:

```objc
static NSSet<NSString *> *kDroppedIntChannels;
static dispatch_once_t kDroppedOnce;
dispatch_once(&kDroppedOnce, ^{
    kDroppedIntChannels = [NSSet setWithArray:@[
        @"positions", @"flags", @"mapping_qualities"
    ]];
});

for (NSString *channel in run.signalCodecOverrides) {
    if ([kDroppedIntChannels containsObject:channel]) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2099
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"signalCodecOverrides[\"%@\"]: removed in v1.6 — "
                             "these per-record integer fields are stored only "
                             "under genomic_index/, not signal_channels/.",
                            channel]}];
        return NO;
    }
}
```

- [ ] **Step 4: Update ObjC tests**

```bash
wsl -d Ubuntu -- bash -c "
grep -rnE 'signal_channels.*positions|signalChannels.*positions|@\"positions\"' /home/toddw/TTI-O/objc/Tests/ 2>&1 | head -20
"
```

For each test that asserts the dataset exists or sets an override on these channels, update to expect absence/error.

- [ ] **Step 5: Strip CRLF + rebuild + run ObjC tests**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && sed -i 's/\r\$//' objc/Source/Dataset/TTIOSpectralDataset.m objc/Tests/*.m && cd objc && bash build.sh 2>&1 | tail -3 && cd Tests && LD_LIBRARY_PATH=../Source/obj:/home/toddw/TTI-O/native/_build:\$LD_LIBRARY_PATH timeout 600 ./obj/TTIOTests 2>&1 | grep -E 'Failed|Tests:' | head -10
"
```

Expected: build clean, all M82/M86/GenomicRun-related tests pass.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && git add objc/Source/Dataset/TTIOSpectralDataset.m objc/Tests/ && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"feat(L4 v1.6 ObjC): drop signal_channels/{positions,flags,mapping_qualities}

ObjC writer mirror of the Python + Java change. Per-record integer
metadata no longer dual-written. Canonical home is genomic_index/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 7: Cross-language byte-equality verification (3-way matrix)

**Files:**
- Read-only verification

- [ ] **Step 1: Re-encode chr22 across all 3 languages and compare bytes**

The cross-language byte-equality contract says Python, Java, ObjC all produce byte-identical .tio files for the same input. With the change landed in all three writers, regenerate fixtures + run the cross-language tests:

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && bash python/tests/fixtures/regenerate.sh 2>&1 | tail -10 || \
    echo 'no regenerate.sh — fixtures may be regenerated inside individual test files'
"
```

If there's no fixture-regen script, the cross-language tests typically generate their own ephemeral test files in `tmp_path` and compare bytes — those will simply pass once all three writers are in sync.

- [ ] **Step 2: Run 3×3 cross-language test matrix (M82)**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/integration/test_m82_3x3_matrix.py -v --tb=short 2>&1 | tail -15
"
```

Expected: 9/9 cells pass (Python writes → Python/Java/ObjC reads = identical, etc.).

- [ ] **Step 3: Run M89 cross-language transport test**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/integration/test_m89_cross_language.py -v --tb=short 2>&1 | tail -15 || true
"
```

Expected: pass — M89 transport reads from `genomic_index/` for these fields, unaffected by signal_channels removal.

- [ ] **Step 4: Run V4 byte-equality gate (qualities — should be unchanged)**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/integration/test_m94z_v4_byte_exact.py -m integration --tb=short 2>&1 | tail -10
"
```

Expected: 4/4 corpora byte-equal htscodecs (qualities channel unaffected by the change).

- [ ] **Step 5: Run cross-language Python ↔ Java ↔ ObjC V4 matrix**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/integration/test_m94z_v4_cross_language.py -m integration --tb=short 2>&1 | tail -10
"
```

Expected: 4/4 corpora pass (12 byte-equality assertions — Python = Java = ObjC for V4 qualities).

- [ ] **Step 6: Measure new chr22 .tio size**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m tools.benchmarks.cli run --dataset chr22_na12878_mapped --formats ttio --json-out /home/toddw/TTI-O/tools/perf/_out_bench/chr22_post_dedup.json 2>&1 | tail -3
.venv/bin/python -c \"
import json, h5py
data = json.load(open('/home/toddw/TTI-O/tools/perf/_out_bench/chr22_post_dedup.json'))[0]
size = data['formats']['ttio']['compress']['output_size_bytes']
print(f'chr22 post-dedup: {size:,} bytes ({size/1024/1024:.2f} MB)')
print(f'expected: ~105.27 MB (was 109.13 MB; recovering ~3.87 MB)')

# Verify dedup is gone
import h5py
f = h5py.File('/home/toddw/TTI-O/tools/perf/_out_bench/profile.tio', 'r')
sc = f['study/genomic_runs/run_0001/signal_channels']
present = [c for c in ['positions', 'flags', 'mapping_qualities'] if c in sc]
print(f'signal_channels still has: {present}')
print(f'signal_channels keys: {list(sc.keys())}')
\"
"
```

Expected output:
- size approximately 105,071,000 bytes (109,129,739 - 4,058,540)
- `signal_channels still has: []`
- `signal_channels keys` no longer contains positions/flags/mapping_qualities

- [ ] **Step 7: No commit (verification only)**

If any test fails: stop and triage. Do not proceed to Task 8 until all tests green.

---

## Task 8: Remove dead reader code in Python (`_int_channel_array` + `_INTEGER_CHANNEL_DTYPES`)

**Files:**
- Modify: `python/src/ttio/genomic_run.py` (around lines 39-43 and 493-540)

- [ ] **Step 1: Confirm no external callers**

```bash
wsl -d Ubuntu -- bash -c "
grep -rn '_int_channel_array' /home/toddw/TTI-O/ --include='*.py' 2>&1 | grep -v '__pycache__'
"
```

Expected: only the definition and one error-message string in `genomic_run.py`. No callers from tests, tools, or other modules.

- [ ] **Step 2: Read the current code**

```bash
wsl -d Ubuntu -- bash -c "
sed -n '30,45p' /home/toddw/TTI-O/python/src/ttio/genomic_run.py
echo '---'
sed -n '490,545p' /home/toddw/TTI-O/python/src/ttio/genomic_run.py
"
```

- [ ] **Step 3: Remove `_INTEGER_CHANNEL_DTYPES` dict and `_int_channel_array` method**

Delete:

```python
# Lines ~30-43: the _INTEGER_CHANNEL_DTYPES dict
_INTEGER_CHANNEL_DTYPES = {
    "positions": "<i8",
    "flags": "<u4",
    "mapping_qualities": "<u1",
}
```

Delete the `_int_channel_array` method (lines 493-540) entirely. Update any nearby docstrings that mention it.

- [ ] **Step 4: Run Python tests to confirm no regression**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/ --ignore=python/tests/integration --tb=short 2>&1 | tail -10
"
```

Expected: full Python test suite green.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && git add python/src/ttio/genomic_run.py && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"refactor(L4 Python): remove dead _int_channel_array helper

The helper supported reading positions/flags/mapping_qualities from
signal_channels/ via codec dispatch. Per its docstring (Binding
Decision §119) it was 'callable but not currently called by
__getitem__' — provisioned for a 'future reader that prefers
signal_channels/ over genomic_index/' that contradicted MS's
spectrum_index/ pattern and never landed.

With v1.6 dropping the dual-write, the helper has zero valid channel
names. Remove _INTEGER_CHANNEL_DTYPES dict and _int_channel_array
method entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 9: Remove dead reader code in Java + ObjC

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java` (integer-channel codec read path)
- Modify: `objc/Source/Genomics/TTIOGenomicRun.m` (`_TTIO_M86_*` integer-channel decode paths if specific to these channels)

- [ ] **Step 1: Find Java equivalent of `_int_channel_array`**

```bash
wsl -d Ubuntu -- bash -c "
grep -nE 'integer.*channel|intChannel|signal_channels.*read.*positions' /home/toddw/TTI-O/java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java | head -15
"
```

Identify the method (if any) that reads positions/flags/mapping_qualities from signal_channels with codec dispatch. Confirm it has no external callers (search the test suite).

- [ ] **Step 2: Remove the Java reader helper if it's only for these three channels**

If the helper is integer-channel-specific to these three names, remove it entirely. If the helper is shared with cigars or mate_info_pos/tlen reads, leave the helper but remove the three-channel-name branches.

- [ ] **Step 3: Find ObjC equivalent**

```bash
wsl -d Ubuntu -- bash -c "
grep -nE 'IntChannel|TTIO_M86_Read.*Int|isEqualToString:@\"positions' /home/toddw/TTI-O/objc/Source/Genomics/TTIOGenomicRun.m 2>&1 | head -15
"
```

Same logic: remove if dedicated to these three channels; trim if shared.

- [ ] **Step 4: Build + test Java**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O/java && mvn test \
    -Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:/home/toddw/TTI-O/native/_build \
    2>&1 | tail -10
"
```

Expected: BUILD SUCCESS.

- [ ] **Step 5: Build + test ObjC**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O/objc && bash build.sh 2>&1 | tail -3 && cd Tests && LD_LIBRARY_PATH=../Source/obj:/home/toddw/TTI-O/native/_build:\$LD_LIBRARY_PATH ./obj/TTIOTests 2>&1 | grep -E 'Failed|^[0-9]+ test' | head -5
"
```

Expected: build clean, no failures beyond pre-existing M38/perf/etc. that already fail unrelated to this change.

- [ ] **Step 6: Commit Java + ObjC dead-code removal together**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && git add java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java objc/Source/Genomics/TTIOGenomicRun.m && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"refactor(L4 Java+ObjC): remove dead integer-channel read helpers

Mirror of the Python _int_channel_array removal. With v1.6 dropping
the signal_channels/{positions,flags,mapping_qualities} duplicates,
the codec-dispatch read path for these three channel names has zero
valid channel names — remove.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 10: Update format-spec §10.7

**Files:**
- Modify: `docs/format-spec.md` §10.7

- [ ] **Step 1: Read current §10.7**

```bash
wsl -d Ubuntu -- bash -c "
sed -n '935,985p' /home/toddw/TTI-O/docs/format-spec.md
"
```

- [ ] **Step 2: Mark §10.7 as legacy / removed in v1.6**

Replace the section's opening prose with:

```markdown
## 10.7 Integer-channel codec wiring under signal_channels (v1.5 LEGACY — REMOVED in v1.6)

> **Status: Legacy.** v1.5 and earlier wrote `positions` (int64),
> `flags` (uint32), and `mapping_qualities` (uint8) under
> `signal_channels/` AS WELL AS under `genomic_index/`. v1.6 stops
> writing the signal_channels/ copies — the genomic_index/ copy is the
> canonical home, mirroring MS's `spectrum_index/` pattern (§4).
> Setting `signal_codec_overrides[positions|flags|mapping_qualities]`
> raises an error in v1.6+; readers ignore the duplicates if they
> encounter v1.5 files.

The remainder of this section describes the on-disk codec format that
v1.5 and earlier files MAY contain under `signal_channels/` for these
channels, kept here for legacy decode reference. v1.6+ readers
intentionally do NOT decode these bytes — the canonical source is
`genomic_index/`.

[… preserve the existing detailed format description …]
```

- [ ] **Step 3: Add a §4 cross-reference**

In §4 (genomic_runs structure overview), if there's a comment about positions/flags/mapping_qualities living in both groups, update it to clarify they live ONLY in genomic_index/ as of v1.6.

- [ ] **Step 4: Commit**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && sed -i 's/\r\$//' docs/format-spec.md && git add docs/format-spec.md && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"docs(L4 v1.6): mark format-spec §10.7 legacy (signal_channels integer dups)

v1.5 wrote positions/flags/mapping_qualities under both
signal_channels/ and genomic_index/. v1.6 drops the signal_channels/
copies; canonical home is genomic_index/. Spec section preserved as
legacy decode reference for v1.5 files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 11: Bump format version + feature flag

**Files:**
- Modify: format-version constant + feature-flag bit in `python/src/ttio/feature_flags.py` and equivalents

- [ ] **Step 1: Find the current format-version-string constant**

```bash
wsl -d Ubuntu -- bash -c "
grep -rnE 'FORMAT_VERSION|format_version|TTIO_VERSION|file_format' /home/toddw/TTI-O/python/src/ttio/ 2>&1 | grep -v '__pycache__\|\.pyc' | head -15
"
```

Identify the string written into the file's root attribute (e.g. `1.5` from M93 era).

- [ ] **Step 2: Bump to `1.6` (or per-project convention)**

```python
# python/src/ttio/feature_flags.py or similar
FORMAT_VERSION = "1.6"  # was "1.5" (M93/M94/M95 era)
```

Mirror in Java + ObjC.

- [ ] **Step 3: Decide on a feature flag (optional)**

If the project uses feature-flag bits for per-feature gating, add a bit like `FEATURE_NO_SIGNAL_CHANNELS_INT_DUPS = 1 << 16` (or similar). Set it in the writer; old readers see a higher bit they don't understand and warn (or just ignore).

- [ ] **Step 4: Run all 3 language test suites to confirm version bump didn't break anything**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/ --ignore=python/tests/integration --tb=short 2>&1 | tail -5
cd /home/toddw/TTI-O/java && mvn -q test -Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:/home/toddw/TTI-O/native/_build 2>&1 | tail -3
cd /home/toddw/TTI-O/objc && bash build.sh 2>&1 | tail -3 && cd Tests && LD_LIBRARY_PATH=../Source/obj:/home/toddw/TTI-O/native/_build ./obj/TTIOTests 2>&1 | grep -E 'Failed test:' | head -5
"
```

Expected: all green (modulo pre-existing unrelated failures).

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && git add python/src/ttio/feature_flags.py java/src/main/java/global/thalion/ttio/ objc/Source/ && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"feat(L4 v1.6): bump format version to 1.6

Marks files as v1.6 — written without signal_channels/{positions,
flags,mapping_qualities} duplicates. v1.5 readers continue to work on
v1.6 files (the channels they look for live in genomic_index/, which
is unchanged).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 12: Update CHANGELOG, WORKPLAN, project memory

**Files:**
- Modify: `CHANGELOG.md`, `WORKPLAN.md`
- Modify: `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\project_tti_o_v1_2_codecs.md`
- Modify: `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\MEMORY.md`

- [ ] **Step 1: CHANGELOG entry**

Add a v1.6 section documenting:
- Removed `signal_channels/{positions,flags,mapping_qualities}` (duplicates of `genomic_index/`)
- ~3.87 MB savings on chr22-class WGS files
- API-breaking: `signal_codec_overrides[{positions,flags,mapping_qualities}]` now raises
- Removed dead code: `_int_channel_array` (Python), equivalents in Java/ObjC

- [ ] **Step 2: WORKPLAN update**

Add a Task #85 entry (or similar): "L4 v1.6 — drop signal_channels integer dups (DONE 2026-05-03)" with the hard numbers.

- [ ] **Step 3: Project memory update**

In `project_tti_o_v1_2_codecs.md`, add a status section for the v1.6 change:

```markdown
## Status (2026-05-03 evening) — L4 v1.6 SHIPPED: signal_channels integer dups removed

**Why:** Per-record positions/flags/mapping_qualities lived in BOTH
genomic_index/ AND signal_channels/ since M82. The signal_channels/
copy was provisioned for a "streaming reader prefers signal_channels"
future that contradicted MS's spectrum_index/ pattern and never
landed. ~3.87 MB recovered on chr22-class WGS files; cleaner
abstraction symmetry with MS.

**How to apply:** When reading or writing genomic per-record integer
metadata, use `genomic_index/`. Setting `signal_codec_overrides[name]`
for `positions`, `flags`, or `mapping_qualities` raises in v1.6+.
```

- [ ] **Step 4: MEMORY.md index entry**

Update the existing project_tti_o_v1_2_codecs.md hook line to mention v1.6.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c "cd /home/toddw/TTI-O && sed -i 's/\r\$//' CHANGELOG.md WORKPLAN.md && git add CHANGELOG.md WORKPLAN.md && git -c user.name='Todd White' -c user.email='todd.white@thalion.global' commit -m \"docs(L4 v1.6): CHANGELOG + WORKPLAN update for signal_channels dedup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\""
```

---

## Task 13: Final verification + push

**Files:**
- Read-only verification

- [ ] **Step 1: Full Python test suite (incl. integration)**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/ -m 'not slow' --tb=short 2>&1 | tail -15
"
```

Expected: all green.

- [ ] **Step 2: Java full test suite**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O/java && mvn -q test \
    -Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:/home/toddw/TTI-O/native/_build 2>&1 | tail -10
"
```

Expected: BUILD SUCCESS.

- [ ] **Step 3: ObjC full test suite**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O/objc/Tests && LD_LIBRARY_PATH=../Source/obj:/home/toddw/TTI-O/native/_build:\$LD_LIBRARY_PATH ./obj/TTIOTests 2>&1 | grep -E '^Tests:|^Total:|Failed:|FAIL' | head -10
"
```

Expected: all M82/M86/M89/M93/M94 tests pass (modulo pre-existing M38 + perf flakes).

- [ ] **Step 4: Cross-language byte-equality matrix**

```bash
wsl -d Ubuntu -- bash -c "
cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
    .venv/bin/python -m pytest python/tests/integration/test_m82_3x3_matrix.py python/tests/integration/test_m89_cross_language.py python/tests/integration/test_m94z_v4_cross_language.py -v --tb=short 2>&1 | tail -20
"
```

Expected: all green — Python, Java, ObjC produce byte-identical .tio files for chr22 inputs.

- [ ] **Step 5: chr22 size confirmation**

```bash
wsl -d Ubuntu -- bash -c "
ls -la /home/toddw/TTI-O/tools/perf/_out_bench/profile.tio 2>&1 | awk '{print \$5, \$9}'
"
```

Expected: ~105.07 MB (was 109.13 MB).

- [ ] **Step 6: Push origin/main**

```bash
\"/c/Program Files/Git/bin/git.exe\" -C \"//wsl.localhost/Ubuntu/home/toddw/TTI-O\" fetch origin main
\"/c/Program Files/Git/bin/git.exe\" -C \"//wsl.localhost/Ubuntu/home/toddw/TTI-O\" log --oneline origin/main..HEAD
\"/c/Program Files/Git/bin/git.exe\" -C \"//wsl.localhost/Ubuntu/home/toddw/TTI-O\" push origin main
```

Expected: clean push, origin/main advanced.

---

## Out of scope (this plan)

- Codec engineering for sequences (REF_DIFF tuning), names (NameTokenized), mate_info — those would close another ~12-15 MB of the gap to CRAM (separate multi-week scope per the audit memo)
- Wrapping CRAM as a binary BLOB inside HDF5 — bigger architectural decision (htslib dep across 3 langs)
- Threaded histogram pass — already shipped

## Notes for the implementer

- **Synchronous three-language change.** Python, Java, ObjC writers must change in lock-step. Tasks 4/5/6 land sequentially but cross-language byte-equality is only verified at Task 7 (after all three writers are updated). It's expected that the cross-language tests fail temporarily after Task 4 alone — that's fine, just don't proceed past Task 7 with red.
- **CRLF discipline.** Per project memory: every file edited via `\\wsl.localhost\...` needs `sed -i $'s/\r$//'` before staging.
- **Old files keep working.** Readers don't touch the signal_channels duplicates. The change is fully backward-compatible at read time.
- **API break is intentional.** `signal_codec_overrides[{positions,flags,mapping_qualities}]` was always a write-only optimization per format-spec §10.7; no caller used the resulting bytes. Hard error is preferred over silent ignore — surfaces stale code immediately.
- **Format spec §10.7 stays in the doc** as legacy decode reference. v1.5 files may have these bytes; we document the historical format so readers can interpret them if they ever need to (today they don't).
- **TDD discipline:** tests get updated in Task 3 (assert NEW behavior), then writer change in Task 4 makes them pass. Same pattern across Java (Task 5) and ObjC (Task 6).
