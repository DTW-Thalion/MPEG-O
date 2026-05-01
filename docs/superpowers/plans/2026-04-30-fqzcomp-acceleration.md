# FQZCOMP Acceleration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the legacy FQZCOMP_NX16 codec (id=10), make FQZCOMP_NX16_Z (id=12) the sole quality codec with NX16_Z decode dispatch in Java/ObjC, then accelerate NX16_Z via a C library (`libttio_rans`) with SIMD kernels and multi-threaded block processing.

**Architecture:** Two phases. Phase A deletes ~4500 lines of NX16 code across Python/Java/ObjC, swaps the default quality codec to NX16_Z, and wires up the missing Java/ObjC codec_id=12 decode dispatch. Phase B builds `libttio_rans` as a standalone C library with AVX2/SSE4.1/scalar kernels, a pthread thread pool, multi-block V2 wire format, and O(1) decode tables — integrated via Python ctypes, Java JNI, and ObjC direct linkage.

**Tech Stack:** C11 (CMake), pthreads, x86 SIMD intrinsics, Python ctypes, Java JNI, Objective-C/C

**Spec:** `docs/superpowers/specs/2026-04-30-fqzcomp-acceleration-design.md`

---

## Phase A — NX16 Removal + NX16_Z Default Swap

Phase A produces a working codebase where NX16 is gone, NX16_Z is the sole quality codec, and all three languages can encode AND decode via codec_id=12.

### Task 1: Remove FQZCOMP_NX16 Python codec module

**Files:**
- Delete: `python/src/ttio/codecs/fqzcomp_nx16.py`
- Delete: `python/src/ttio/codecs/_fqzcomp_nx16/` (entire directory)
- Modify: `python/src/ttio/codecs/__init__.py`
- Modify: `python/setup.py`

- [ ] **Step 1: Delete the NX16 pure-Python codec**

```bash
rm python/src/ttio/codecs/fqzcomp_nx16.py
```

- [ ] **Step 2: Delete the NX16 Cython extension directory**

```bash
rm -rf python/src/ttio/codecs/_fqzcomp_nx16/
```

- [ ] **Step 3: Remove NX16 imports from codecs __init__.py**

Edit `python/src/ttio/codecs/__init__.py` — remove lines 15 and 28-29:

```python
# REMOVE this import line:
from .fqzcomp_nx16 import decode as fqzcomp_nx16_decode, encode as fqzcomp_nx16_encode

# REMOVE from __all__:
    "fqzcomp_nx16_decode",
    "fqzcomp_nx16_encode",
```

The file should become:

```python
"""TTI-O compression codecs — clean-room implementations.

All codecs in this package are implemented from published academic
literature. No third-party codec library source code is consulted.

Codecs:
    rans       — rANS order-0 and order-1 entropy coding (Duda 2014)
    base_pack  — 2-bit nucleotide packing + sidecar mask (M84)
    quality    — Phred score quantisation (M85 Phase A)
    name_tok   — Read name tokenisation (M85 Phase B)
"""
from __future__ import annotations

from .base_pack import decode as base_pack_decode, encode as base_pack_encode
from .fqzcomp_nx16_z import (
    decode_with_metadata as fqzcomp_nx16_z_decode,
    encode as fqzcomp_nx16_z_encode,
)
from .name_tokenizer import decode as name_tok_decode, encode as name_tok_encode
from .quality import decode as quality_decode, encode as quality_encode
from .rans import decode as rans_decode, encode as rans_encode

__all__ = [
    "base_pack_decode",
    "base_pack_encode",
    "fqzcomp_nx16_z_decode",
    "fqzcomp_nx16_z_encode",
    "name_tok_decode",
    "name_tok_encode",
    "quality_decode",
    "quality_encode",
    "rans_decode",
    "rans_encode",
]
```

- [ ] **Step 4: Remove NX16 Cython extension from setup.py**

Edit `python/setup.py` — remove the Extension for `_fqzcomp_nx16`:

```python
# REMOVE this Extension block:
            Extension(
                name="ttio.codecs._fqzcomp_nx16._fqzcomp_nx16",
                sources=[
                    "src/ttio/codecs/_fqzcomp_nx16/_fqzcomp_nx16.pyx",
                ],
            ),
```

- [ ] **Step 5: Verify Python package imports**

Run:
```bash
cd ~/TTI-O/python && python -c "from ttio.codecs import fqzcomp_nx16_z_encode; print('OK')"
```
Expected: `OK`

Run:
```bash
cd ~/TTI-O/python && python -c "from ttio.codecs import fqzcomp_nx16_encode" 2>&1
```
Expected: `ImportError` (confirms removal)

- [ ] **Step 6: Commit**

```bash
git add -A python/src/ttio/codecs/ python/setup.py
git commit -m "refactor: remove FQZCOMP_NX16 Python codec module (~2300 lines)

No legacy .tio files use codec id=10. NX16_Z (id=12) is the sole quality codec."
```

---

### Task 2: Remove FQZCOMP_NX16 from Python enums, default codecs, and write/decode dispatch

**Files:**
- Modify: `python/src/ttio/enums.py:87-102`
- Modify: `python/src/ttio/genomic/_default_codecs.py:21-31`
- Modify: `python/src/ttio/genomic_run.py:375-474`
- Modify: `python/src/ttio/spectral_dataset.py` (multiple locations)

- [ ] **Step 1: Remove FQZCOMP_NX16 from enums.py**

Edit `python/src/ttio/enums.py` — remove the `FQZCOMP_NX16 = 10` member and its comments (lines 87-93). Keep DELTA_RANS_ORDER0 and FQZCOMP_NX16_Z. The Compression enum section should become:

```python
    REF_DIFF = 9
    # v1.2 M95: delta + zigzag + varint + rANS order-0 — sorted integer channels.
    DELTA_RANS_ORDER0 = 11
    # v1.2 M94.Z: CRAM-mimic rANS-Nx16 quality codec. Static-per-block
    # frequency tables, L=2^15, B=16, N=4, bit-pack 15-bit context.
    # Sole quality codec for the qualities channel; wire magic ``M94Z``.
    FQZCOMP_NX16_Z = 12
```

- [ ] **Step 2: Swap default codec in _default_codecs.py**

Edit `python/src/ttio/genomic/_default_codecs.py` line 23:

```python
# OLD:
    "qualities": Compression.FQZCOMP_NX16,
# NEW:
    "qualities": Compression.FQZCOMP_NX16_Z,
```

Also update the module docstring (line 8) to remove the M94 reference:

```python
# OLD:
M93 registers ``sequences → REF_DIFF``; M94 adds ``qualities →
FQZCOMP_NX16``. M95 adds the integer channels.
# NEW:
M93 registers ``sequences → REF_DIFF``; M94.Z adds ``qualities →
FQZCOMP_NX16_Z``. M95 adds the integer channels.
```

- [ ] **Step 3: Remove codec_id=10 decode path from genomic_run.py**

Edit `python/src/ttio/genomic_run.py` — remove the entire `elif codec_id == int(Compression.FQZCOMP_NX16)` block at lines 375-380 and the `_decode_fqzcomp_nx16_qualities` method at lines 455-474. The dispatch should jump directly from REF_DIFF to NX16_Z:

```python
            decoded = self._decode_ref_diff_sequences(all_bytes)
        elif codec_id == int(Compression.FQZCOMP_NX16_Z):
            # M94.Z v1.2: CRAM-mimic FQZCOMP_NX16 (rANS-Nx16). Same
            # plumbing as v1: codec carries read_lengths inside its
            # sidecar; revcomp_flags come from run.flags & 16. Different
            # on-wire format (magic ``M94Z``).
            decoded = self._decode_fqzcomp_nx16_z_qualities(all_bytes)
        else:
```

- [ ] **Step 4: Remove NX16 write path and references from spectral_dataset.py**

Edit `python/src/ttio/spectral_dataset.py`:

**(a)** Delete `_write_qualities_fqzcomp_nx16()` (lines 1217-1255) — the entire function. Keep `_write_qualities_fqzcomp_nx16_z()` (lines 1258-1289).

**(b)** Remove `_Compression.FQZCOMP_NX16` from the `_V1_5_CODECS` frozenset (line 996):

```python
    _V1_5_CODECS = frozenset({
        _Compression.REF_DIFF,         # M93
        _Compression.FQZCOMP_NX16_Z,   # M94.Z (CRAM-mimic rANS-Nx16)
    })
```

**(c)** Remove `_Compression.FQZCOMP_NX16` from the qualities allowed-set (line 1345):

```python
        "qualities": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.BASE_PACK,
            _Compression.QUALITY_BINNED,
            _Compression.FQZCOMP_NX16_Z,
        }),
```

**(d)** Remove the NX16 write-dispatch branch at lines 1694-1699:

```python
    # OLD: two branches — NX16 then NX16_Z
    # NEW: only NX16_Z
    if (
        _qual_codec is not None
        and _is_valid_compression(_qual_codec)
        and _Compression(_qual_codec) == _Compression.FQZCOMP_NX16_Z
    ):
        _write_qualities_fqzcomp_nx16_z(sc, run)
    else:
        io._write_byte_channel_with_codec(
            sc, "qualities", run.qualities, run.signal_compression,
            _qual_codec,
        )
```

**(e)** Remove `_Compression.FQZCOMP_NX16` from the v1.5 candidate check (line 1650):

```python
                    if _ce in (
                        _Compression.REF_DIFF,
                        _Compression.FQZCOMP_NX16_Z,
                        _Compression.DELTA_RANS_ORDER0,
                    ):
```

**(f)** Update docstring/comment references at lines 750, 977, 983, 986, 1619, 1625 to say NX16_Z instead of NX16.

- [ ] **Step 5: Run Python tests to verify no import/dispatch errors**

```bash
cd ~/TTI-O/python && python -m pytest tests/ -x -q --ignore=tests/perf --ignore=tests/test_m94_fqzcomp_unit.py --ignore=tests/test_m94_canonical_fixtures.py --ignore=tests/test_m94_fqzcomp_pipeline.py -k "not fqzcomp_nx16" 2>&1 | tail -20
```
Expected: All tests pass (no import errors, no missing codec dispatch).

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/enums.py python/src/ttio/genomic/_default_codecs.py python/src/ttio/genomic_run.py python/src/ttio/spectral_dataset.py
git commit -m "refactor: swap default quality codec NX16 → NX16_Z, remove NX16 dispatch

Default codec for qualities channel is now FQZCOMP_NX16_Z (id=12).
Removed codec_id=10 encode/decode paths from spectral_dataset and genomic_run."
```

---

### Task 3: Delete NX16 Python test files and fixtures

**Files:**
- Delete: `python/tests/test_m94_fqzcomp_unit.py`
- Delete: `python/tests/test_m94_canonical_fixtures.py`
- Delete: `python/tests/test_m94_fqzcomp_pipeline.py`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_a.bin`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_b.bin`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_c.bin`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_d.bin`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_f.bin`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_g.bin`
- Delete: `python/tests/fixtures/codecs/fqzcomp_nx16_h.bin`

- [ ] **Step 1: Delete NX16 test files**

```bash
rm python/tests/test_m94_fqzcomp_unit.py \
   python/tests/test_m94_canonical_fixtures.py \
   python/tests/test_m94_fqzcomp_pipeline.py
```

- [ ] **Step 2: Delete NX16 fixture files**

```bash
rm python/tests/fixtures/codecs/fqzcomp_nx16_*.bin
```

- [ ] **Step 3: Run remaining M94.Z tests to confirm they still pass**

```bash
cd ~/TTI-O/python && python -m pytest tests/test_m94z_unit.py tests/test_m94z_canonical_fixtures.py tests/test_m94z_byte_pairing.py tests/test_m94z_stress.py -v 2>&1 | tail -20
```
Expected: All M94.Z tests pass.

- [ ] **Step 4: Commit**

```bash
git add -A python/tests/
git commit -m "refactor: delete NX16 test files and fixtures (Python)

Removed 3 test modules and 7 conformance fixture .bin files for the
deleted FQZCOMP_NX16 codec. M94.Z tests retained."
```

---

### Task 4: Remove FQZCOMP_NX16 from Java + add NX16_Z decode dispatch

**Files:**
- Delete: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16.java`
- Modify: `java/src/main/java/global/thalion/ttio/Enums.java:107-112`
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`
- Modify: `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java:379-399`

- [ ] **Step 1: Delete FqzcompNx16.java**

```bash
rm java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16.java
```

- [ ] **Step 2: Remove FQZCOMP_NX16 from Java Enums**

Edit `java/src/main/java/global/thalion/ttio/Enums.java` — remove the `FQZCOMP_NX16` enum constant and its Javadoc (the block starting with `/** FQZCOMP_NX16 — lossless quality codec...`). Keep the comma after `REF_DIFF,` and keep `DELTA_RANS_ORDER0,` and `FQZCOMP_NX16_Z`.

**Important**: Java enums use ordinal position for codec ids. Since `FQZCOMP_NX16` is at ordinal 10, removing it shifts `DELTA_RANS_ORDER0` from ordinal 11 to 10 and `FQZCOMP_NX16_Z` from 12 to 11. This breaks wire-format compatibility. To fix, remove the enum constant but **leave a placeholder comment** preserving the ordinal:

Actually — the enum values need explicit `ordinal()` control. Check how the Java code currently maps codec ids. The enum constants are position-based (NONE=0, ZLIB=1, ..., FQZCOMP_NX16=10). Since Java enums don't support arbitrary int values natively, we need a different approach.

Read `GenomicRun.java` to see how `codecId` is compared — it uses `.ordinal()`. We cannot remove the enum constant without breaking ordinal mapping. Instead, mark it as deprecated/unused with a `@Deprecated` annotation or rename it to `_RESERVED_10`:

```java
    /** @deprecated Codec id 10 removed — no legacy .tio files exist. */
    @Deprecated
    _RESERVED_10,
    /** Delta + zigzag + varint + rANS order-0 for sorted integer channels
     *  (M95 v1.2, codec id 11). */
    DELTA_RANS_ORDER0,
    /** CRAM-mimic rANS-Nx16 quality codec (M94.Z v1.2, codec id 12). */
    FQZCOMP_NX16_Z
```

- [ ] **Step 3: Replace NX16 decode dispatch with NX16_Z in GenomicRun.java**

Edit `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java` — replace the `FQZCOMP_NX16.ordinal()` block (lines ~379-399). Remove the NX16 case and add NX16_Z:

```java
} else if (codecId == global.thalion.ttio.Enums.Compression
        .FQZCOMP_NX16_Z.ordinal()) {
    // M94.Z v1.2: CRAM-mimic FQZCOMP_NX16_Z quality codec.
    // Wire format carries read_lengths in the header sidecar;
    // revcomp_flags reconstructed from run.flags & 16 (SAM REVERSE).
    int n = index.count();
    int[] revcompFlags = new int[n];
    for (int i = 0; i < n; i++) {
        int f = index.flagsAt(i);
        revcompFlags[i] = ((f & 16) != 0) ? 1 : 0;
    }
    global.thalion.ttio.codecs.FqzcompNx16Z.DecodeResult dr =
        global.thalion.ttio.codecs.FqzcompNx16Z
            .decodeWithMetadata(all, revcompFlags);
    decoded = dr.qualities();
} else {
    throw new IllegalStateException(
        "signal_channel '" + name + "': @compression="
        + codecId + " is not a supported TTIO codec id");
}
```

- [ ] **Step 4: Update SpectralDataset.java default codec**

Edit `java/src/main/java/global/thalion/ttio/SpectralDataset.java`:

**(a)** Find the qualities default codec assignment (where `qualCodec` is set to `FQZCOMP_NX16`) and change to `FQZCOMP_NX16_Z`.

**(b)** Find the allowed-set for qualities and remove `FQZCOMP_NX16`, keeping `FQZCOMP_NX16_Z`.

**(c)** Find the write dispatch that calls `FqzcompNx16.encode()` and redirect to `FqzcompNx16Z.encode()`.

**(d)** Remove any remaining import of `FqzcompNx16` (not `FqzcompNx16Z`).

- [ ] **Step 5: Build Java and run NX16_Z tests**

```bash
cd ~/TTI-O/java && mvn compile -q && mvn test -pl . -Dtest="FqzcompNx16ZUnitTest" -q 2>&1 | tail -10
```
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add -A java/
git commit -m "refactor: remove FQZCOMP_NX16 from Java, add NX16_Z decode dispatch

Deleted FqzcompNx16.java (~1077 lines). Replaced ordinal 10 with
_RESERVED_10 placeholder to preserve enum ordinal mapping.
Added codec_id=12 decode dispatch in GenomicRun.java.
Default quality codec now FQZCOMP_NX16_Z."
```

---

### Task 5: Delete Java NX16 test files and fixtures

**Files:**
- Delete: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16UnitTest.java`
- Delete: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16PipelineTest.java`
- Delete: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16PerfTest.java`
- Delete: `java/src/test/resources/ttio/codecs/fqzcomp_nx16_*.bin` (7 files)

- [ ] **Step 1: Delete NX16 Java test files**

```bash
rm java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16UnitTest.java \
   java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16PipelineTest.java \
   java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16PerfTest.java
```

- [ ] **Step 2: Delete NX16 Java fixture files**

```bash
rm java/src/test/resources/ttio/codecs/fqzcomp_nx16_*.bin
```

- [ ] **Step 3: Build and run remaining NX16_Z tests**

```bash
cd ~/TTI-O/java && mvn test -pl . -Dtest="FqzcompNx16ZUnitTest,FqzcompNx16ZPerfTest" -q 2>&1 | tail -10
```
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add -A java/src/test/
git commit -m "refactor: delete NX16 test files and fixtures (Java)

Removed 3 test classes and 7 conformance fixture .bin files for the
deleted FQZCOMP_NX16 codec. NX16_Z tests retained."
```

---

### Task 6: Remove FQZCOMP_NX16 from Objective-C + add NX16_Z decode dispatch

**Files:**
- Delete: `objc/Source/Codecs/TTIOFqzcompNx16.h`
- Delete: `objc/Source/Codecs/TTIOFqzcompNx16.m`
- Modify: `objc/Source/ValueClasses/TTIOEnums.h:54`
- Modify: `objc/Source/Genomics/TTIOGenomicRun.m:310-329,465-483`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.m:151,1585,1860,1896-1926`

- [ ] **Step 1: Delete TTIOFqzcompNx16 files**

```bash
rm objc/Source/Codecs/TTIOFqzcompNx16.h objc/Source/Codecs/TTIOFqzcompNx16.m
```

- [ ] **Step 2: Update TTIOEnums.h — mark id=10 as reserved**

Edit `objc/Source/ValueClasses/TTIOEnums.h` — replace line 54:

```objc
// OLD:
    TTIOCompressionFqzcompNx16 = 10, // v1.2 M94: lossless quality codec (fqzcomp-Nx16)
// NEW:
    TTIOCompressionReserved10 = 10,   // removed — no legacy .tio files exist
```

- [ ] **Step 3: Replace NX16 decode with NX16_Z in TTIOGenomicRun.m**

Edit `objc/Source/Genomics/TTIOGenomicRun.m`:

**(a)** Replace `case 10:` dispatch (lines ~310-315) with `case 12:` for NX16_Z:

```objc
case 12: // TTIOCompressionFqzcompNx16Z (M94.Z v1.2)
    decoded = [self _ttio_m94z_decodeFqzcompNx16Z:encoded error:&decErr];
    break;
```

**(b)** Delete the old `case 10:` and the `_ttio_m94_decodeFqzcompNx16:error:` method (lines ~465-483).

**(c)** Add the `_ttio_m94z_decodeFqzcompNx16Z:error:` method. This should mirror the Python `_decode_fqzcomp_nx16_z_qualities` logic:

```objc
- (NSData *)_ttio_m94z_decodeFqzcompNx16Z:(NSData *)encoded
                                     error:(NSError **)error
{
    NSUInteger n = self.index.count;
    NSMutableArray<NSNumber *> *revcomp = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        uint32_t f = [self.index flagsAtIndex:i];
        [revcomp addObject:@((f & 16) ? 1 : 0)];
    }
    TTIOFqzcompNx16ZDecodeResult *dr =
        [TTIOFqzcompNx16Z decodeWithMetadata:encoded
                                revcompFlags:revcomp
                                       error:error];
    if (!dr) return nil;
    return dr.qualities;
}
```

**(d)** Remove `#import "Codecs/TTIOFqzcompNx16.h"` and add `#import "Codecs/TTIOFqzcompNx16Z.h"` if not already present.

- [ ] **Step 4: Update TTIOSpectralDataset.m**

Edit `objc/Source/Dataset/TTIOSpectralDataset.m`:

**(a)** Remove `TTIOCompressionFqzcompNx16` from the allowed-set (line ~151).

**(b)** Change `_TTIO_M94_DefaultQualitiesCodec()` to return `TTIOCompressionFqzcompNx16Z` (line ~1860):

```objc
    return @(TTIOCompressionFqzcompNx16Z);
```

**(c)** Delete `_TTIO_M94_WriteQualitiesFqzcompNx16()` (lines ~1896-1926).

**(d)** Update the write dispatch to call the NX16_Z writer instead of NX16.

**(e)** Remove `#import "Codecs/TTIOFqzcompNx16.h"`.

- [ ] **Step 5: Build ObjC and run tests**

```bash
cd ~/TTI-O/objc && make -j$(nproc) 2>&1 | tail -10
```
Expected: Build succeeds with no undefined-symbol errors.

```bash
cd ~/TTI-O/objc && make check 2>&1 | tail -20
```
Expected: Tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A objc/
git commit -m "refactor: remove FQZCOMP_NX16 from ObjC, add NX16_Z decode dispatch

Deleted TTIOFqzcompNx16.h/.m (~1200 lines). Added case 12 decode
dispatch in TTIOGenomicRun. Default quality codec now NX16_Z."
```

---

### Task 7: Delete ObjC NX16 test files and fixtures

**Files:**
- Delete: `objc/Tests/TestM94FqzcompUnit.m`
- Delete: `objc/Tests/TestM94FqzcompPerf.m`
- Delete: `objc/Tests/TestM94FqzcompPipeline.m`
- Delete: `objc/Tests/Fixtures/codecs/fqzcomp_nx16_*.bin` (7 files)

- [ ] **Step 1: Delete NX16 ObjC test files**

```bash
rm objc/Tests/TestM94FqzcompUnit.m \
   objc/Tests/TestM94FqzcompPerf.m \
   objc/Tests/TestM94FqzcompPipeline.m
```

- [ ] **Step 2: Delete NX16 ObjC fixture files**

```bash
rm objc/Tests/Fixtures/codecs/fqzcomp_nx16_*.bin
```

- [ ] **Step 3: Update ObjC test build (GNUmakefile or test runner)**

Check if the test GNUmakefile explicitly lists the deleted `.m` files. If so, remove them. The test runner at `objc/Tests/` may need its file list updated.

- [ ] **Step 4: Build and run remaining tests**

```bash
cd ~/TTI-O/objc && make check 2>&1 | tail -20
```
Expected: Tests pass with no missing-file errors.

- [ ] **Step 5: Commit**

```bash
git add -A objc/Tests/
git commit -m "refactor: delete NX16 test files and fixtures (ObjC)

Removed 3 test files and 7 conformance fixture .bin files for the
deleted FQZCOMP_NX16 codec. M94.Z tests retained."
```

---

### Task 8: Remove NX16 from benchmark harnesses and baseline

**Files:**
- Modify: `tools/perf/profile_python_full.py`
- Modify: `tools/perf/ProfileHarnessFull.java`
- Modify: `tools/perf/profile_objc_full.m`
- Modify: `tools/perf/baseline.json`

- [ ] **Step 1: Remove NX16 benchmarks from Python harness**

Edit `tools/perf/profile_python_full.py` — in `bench_codecs_genomic()`:

**(a)** Remove the `_fqzcomp_encode` / `_fqzcomp_decode` import and timing lines (~lines 483-485).

**(b)** Remove `fqzcomp_nx16_encode` and `fqzcomp_nx16_decode` from the return dict.

**(c)** Remove the import of the NX16 codec at the top of the function (if any).

- [ ] **Step 2: Remove NX16 benchmarks from Java harness**

Edit `tools/perf/ProfileHarnessFull.java` — in `benchCodecsGenomic()`:

**(a)** Remove the `FqzcompNx16.encode()` / `FqzcompNx16.decode()` benchmark lines (~lines 503-509).

**(b)** Remove `fqzcomp_nx16_encode` and `fqzcomp_nx16_decode` from the results.

**(c)** Remove the import of `FqzcompNx16` at the top.

- [ ] **Step 3: Remove NX16 benchmarks from ObjC harness**

Edit `tools/perf/profile_objc_full.m` — remove the NX16 encode/decode benchmark lines and `#import` of `TTIOFqzcompNx16.h`.

- [ ] **Step 4: Remove NX16 entries from baseline.json**

Edit `tools/perf/baseline.json` — remove these keys from the `codecs.genomic` section for all three languages:
- `"fqzcomp_nx16_encode"`
- `"fqzcomp_nx16_decode"`

Keep the `fqzcomp_nx16_z_*` entries.

- [ ] **Step 5: Run Python benchmark harness to verify it works**

```bash
cd ~/TTI-O && python tools/perf/profile_python_full.py --n 100 --peaks 4 2>&1 | grep -A2 "codecs.genomic"
```
Expected: Output shows `fqzcomp_nx16_z_encode/decode` but NOT `fqzcomp_nx16_encode/decode`.

- [ ] **Step 6: Commit**

```bash
git add tools/perf/
git commit -m "refactor: remove NX16 from benchmark harnesses and baseline

Removed fqzcomp_nx16_encode/decode benchmarks from Python/Java/ObjC
harnesses and baseline.json. NX16_Z benchmarks retained."
```

---

### Task 9: Phase A integration test — full Python test suite

**Files:** (none modified — verification only)

- [ ] **Step 1: Run full Python test suite (excluding perf)**

```bash
cd ~/TTI-O/python && python -m pytest tests/ -x -q --ignore=tests/perf 2>&1 | tail -20
```
Expected: All tests pass. No references to removed NX16 modules cause failures.

- [ ] **Step 2: Run M94.Z perf test**

```bash
cd ~/TTI-O/python && python -m pytest tests/perf/ -v -m perf 2>&1 | tail -10
```
Expected: M95 throughput test passes. No NX16 perf tests exist to fail.

- [ ] **Step 3: Run a quick Python benchmark to verify end-to-end**

```bash
cd ~/TTI-O && python tools/perf/profile_python_full.py --n 1000 --peaks 8 2>&1 | tail -30
```
Expected: Benchmark completes successfully with NX16_Z metrics only.

- [ ] **Step 4: Tag Phase A complete**

No commit needed — this is a verification-only task.

---

## Phase B — libttio_rans C Library + SIMD Acceleration

Phase B builds the native C library and integrates it across all three languages. Each task is independently testable.

### Task 10: Scaffold native/ directory and CMake build

**Files:**
- Create: `native/CMakeLists.txt`
- Create: `native/include/ttio_rans.h`
- Create: `native/src/rans_core.c`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p native/include native/src native/tests native/bench
```

- [ ] **Step 2: Write the public header**

Create `native/include/ttio_rans.h`:

```c
#ifndef TTIO_RANS_H
#define TTIO_RANS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TTIO_RANS_L       (1u << 15)
#define TTIO_RANS_B_BITS  16
#define TTIO_RANS_B       (1u << 16)
#define TTIO_RANS_B_MASK  (TTIO_RANS_B - 1)
#define TTIO_RANS_T       (1u << 12)
#define TTIO_RANS_T_BITS  12
#define TTIO_RANS_T_MASK  (TTIO_RANS_T - 1)
#define TTIO_RANS_STREAMS 4
#define TTIO_RANS_X_MAX_PREFACTOR  ((TTIO_RANS_L >> TTIO_RANS_T_BITS) << TTIO_RANS_B_BITS)

#define TTIO_RANS_OK           0
#define TTIO_RANS_ERR_PARAM   -1
#define TTIO_RANS_ERR_ALLOC   -2
#define TTIO_RANS_ERR_CORRUPT -3

typedef struct ttio_rans_pool ttio_rans_pool;

int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols
);

void ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T]
);

ttio_rans_pool *ttio_rans_pool_create(int n_threads);

int ttio_rans_encode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    size_t          reads_per_block,
    const size_t   *read_lengths,
    size_t          n_reads,
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols
);

void ttio_rans_pool_destroy(ttio_rans_pool *pool);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_RANS_H */
```

- [ ] **Step 3: Write rans_core.c with frequency table helpers**

Create `native/src/rans_core.c`:

```c
#include "ttio_rans.h"
#include <string.h>

void ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T])
{
    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        memset(dtab[ctx], 0, TTIO_RANS_T);
        for (int sym = 0; sym < 256; sym++) {
            uint32_t f = freq[ctx][sym];
            uint32_t c = cum[ctx][sym];
            for (uint32_t s = 0; s < f; s++) {
                dtab[ctx][c + s] = (uint8_t)sym;
            }
        }
    }
}
```

- [ ] **Step 4: Write minimal CMakeLists.txt**

Create `native/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.16)
project(ttio_rans C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(ttio_rans SHARED
    src/rans_core.c
)
target_include_directories(ttio_rans PUBLIC include)

# Install
install(TARGETS ttio_rans LIBRARY DESTINATION lib)
install(FILES include/ttio_rans.h DESTINATION include)
```

- [ ] **Step 5: Build and verify**

```bash
cd ~/TTI-O/native && mkdir -p _build && cd _build && cmake .. && make -j$(nproc) 2>&1 | tail -5
```
Expected: `libttio_rans.so` built successfully.

- [ ] **Step 6: Commit**

```bash
git add native/
git commit -m "feat: scaffold native/libttio_rans with CMake, header, and decode table builder"
```

---

### Task 11: Implement scalar rANS encode kernel

**Files:**
- Create: `native/src/rans_encode_scalar.c`
- Create: `native/tests/test_roundtrip.c`
- Modify: `native/CMakeLists.txt`

- [ ] **Step 1: Write the scalar encode kernel**

Create `native/src/rans_encode_scalar.c`:

```c
#include "ttio_rans.h"
#include <stdlib.h>
#include <string.h>

int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len)
{
    if (!symbols || !contexts || !freq || !out || !out_len)
        return TTIO_RANS_ERR_PARAM;
    if (n_symbols == 0) {
        *out_len = 0;
        return TTIO_RANS_OK;
    }

    size_t pad_count = (4 - (n_symbols & 3)) & 3;
    size_t n_padded = n_symbols + pad_count;

    /* Build cumulative freq tables */
    uint32_t (*cum)[256] = calloc(n_contexts, sizeof(*cum));
    if (!cum) return TTIO_RANS_ERR_ALLOC;
    for (uint16_t c = 0; c < n_contexts; c++) {
        cum[c][0] = 0;
        for (int s = 1; s < 256; s++)
            cum[c][s] = cum[c][s-1] + freq[c][s-1];
    }

    /* Per-lane output buffers (encode emits in reverse) */
    size_t max_chunks = n_padded + 16;
    uint16_t *lane_buf[TTIO_RANS_STREAMS];
    size_t lane_n[TTIO_RANS_STREAMS];
    for (int i = 0; i < TTIO_RANS_STREAMS; i++) {
        lane_buf[i] = malloc(max_chunks * sizeof(uint16_t));
        if (!lane_buf[i]) {
            for (int j = 0; j < i; j++) free(lane_buf[j]);
            free(cum);
            return TTIO_RANS_ERR_ALLOC;
        }
        lane_n[i] = 0;
    }

    /* Initial states */
    uint32_t state[TTIO_RANS_STREAMS];
    for (int i = 0; i < TTIO_RANS_STREAMS; i++)
        state[i] = TTIO_RANS_L;

    /* Encode in reverse order, interleaving across 4 lanes */
    for (size_t i = n_padded; i > 0; ) {
        i--;
        int lane = (int)(i & 3);
        uint16_t ctx;
        uint8_t sym;
        if (i >= n_symbols) {
            ctx = 0;
            sym = 0;
        } else {
            ctx = contexts[i];
            sym = symbols[i];
        }
        uint32_t f = freq[ctx][sym];
        uint32_t c = cum[ctx][sym];
        if (f == 0) { f = 1; } /* safety: should not happen with valid tables */

        uint32_t x = state[lane];
        uint32_t x_max = TTIO_RANS_X_MAX_PREFACTOR * f;

        while (x >= x_max) {
            lane_buf[lane][lane_n[lane]++] = (uint16_t)(x & TTIO_RANS_B_MASK);
            x >>= TTIO_RANS_B_BITS;
        }
        state[lane] = (x / f) * TTIO_RANS_T + (x % f) + c;
    }

    /* Pack output: 4 final states (LE) + interleaved lane chunks (reversed) */
    size_t pos = 0;
    size_t needed = 4 * 4; /* 4 states × 4 bytes */
    for (int i = 0; i < TTIO_RANS_STREAMS; i++)
        needed += lane_n[i] * 2;
    if (*out_len < needed) {
        for (int i = 0; i < TTIO_RANS_STREAMS; i++) free(lane_buf[i]);
        free(cum);
        return TTIO_RANS_ERR_PARAM;
    }

    /* Write final states */
    for (int i = 0; i < TTIO_RANS_STREAMS; i++) {
        out[pos++] = (uint8_t)(state[i]);
        out[pos++] = (uint8_t)(state[i] >> 8);
        out[pos++] = (uint8_t)(state[i] >> 16);
        out[pos++] = (uint8_t)(state[i] >> 24);
    }

    /* Write lane chunks in reverse (decode reads forward) */
    for (int i = 0; i < TTIO_RANS_STREAMS; i++) {
        for (size_t j = lane_n[i]; j > 0; ) {
            j--;
            out[pos++] = (uint8_t)(lane_buf[i][j]);
            out[pos++] = (uint8_t)(lane_buf[i][j] >> 8);
        }
    }

    *out_len = pos;
    for (int i = 0; i < TTIO_RANS_STREAMS; i++) free(lane_buf[i]);
    free(cum);
    return TTIO_RANS_OK;
}
```

- [ ] **Step 2: Write the scalar decode kernel**

Create `native/src/rans_decode_scalar.c`:

```c
#include "ttio_rans.h"
#include <string.h>

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols)
{
    if (!compressed || !freq || !cum || !dtab || !symbols)
        return TTIO_RANS_ERR_PARAM;
    if (n_symbols == 0)
        return TTIO_RANS_OK;
    if (comp_len < 16)
        return TTIO_RANS_ERR_CORRUPT;

    size_t pad_count = (4 - (n_symbols & 3)) & 3;
    size_t n_padded = n_symbols + pad_count;

    /* Read initial states */
    uint32_t state[TTIO_RANS_STREAMS];
    size_t pos = 0;
    for (int i = 0; i < TTIO_RANS_STREAMS; i++) {
        state[i] = (uint32_t)compressed[pos]
                 | ((uint32_t)compressed[pos+1] << 8)
                 | ((uint32_t)compressed[pos+2] << 16)
                 | ((uint32_t)compressed[pos+3] << 24);
        pos += 4;
    }

    /* Per-lane byte stream pointers — lanes are concatenated after states.
     * We need to find where each lane's data starts. For now, use a
     * single interleaved stream approach matching the Cython reference. */
    /* Actually: the encoder writes per-lane chunks contiguously (lane 0
     * chunks, then lane 1, etc.). We need lane offsets. For the scalar
     * decoder, we'll read from a single stream since the encoder
     * output is already structured. */

    /* Decode forward, 4-way interleaved */
    size_t stream_pos[TTIO_RANS_STREAMS];
    /* The compressed data after the 4 states is per-lane chunks.
     * We need the lane sizes to compute offsets. Since we don't store
     * them explicitly, we decode sequentially from the stream. */

    /* Simplified: single-stream decode matching the M94.Z Cython impl.
     * All 4 lanes read from the same byte cursor. */
    size_t byte_pos = pos;

    for (size_t i = 0; i < n_padded; i++) {
        int lane = (int)(i & 3);
        uint32_t x = state[lane];
        uint32_t slot = x & TTIO_RANS_T_MASK;

        /* Look up symbol via O(1) decode table */
        uint16_t ctx = (i < n_symbols) ? 0 : 0; /* context provided externally */
        uint8_t sym = dtab[ctx][slot];

        if (i < n_symbols)
            symbols[i] = sym;

        /* Advance state */
        uint32_t f = freq[ctx][sym];
        uint32_t c = cum[ctx][sym];
        x = (x >> TTIO_RANS_T_BITS) * f + slot - c;

        /* Renormalize */
        if (x < TTIO_RANS_L) {
            if (byte_pos + 1 < comp_len) {
                uint16_t chunk = (uint16_t)compressed[byte_pos]
                               | ((uint16_t)compressed[byte_pos+1] << 8);
                byte_pos += 2;
                x = (x << TTIO_RANS_B_BITS) | chunk;
            }
        }
        state[lane] = x;
    }

    return TTIO_RANS_OK;
}
```

**Note:** This is a placeholder scalar decode — the actual implementation must match the M94.Z Cython encoder's byte layout exactly (per-lane chunks reversed, then interleaved read). The implementer MUST verify byte-exact round-trip against the Cython reference by comparing compressed output byte-for-byte. Read `python/src/ttio/codecs/_fqzcomp_nx16_z/_fqzcomp_nx16_z.pyx` lines 394-411 (encode) and the decode path for the exact byte layout contract.

- [ ] **Step 3: Write a C round-trip test**

Create `native/tests/test_roundtrip.c`:

```c
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static void test_simple_roundtrip(void) {
    /* 8 symbols, 1 context, uniform freq */
    uint8_t symbols[] = {0, 1, 2, 3, 0, 1, 2, 3};
    uint16_t contexts[] = {0, 0, 0, 0, 0, 0, 0, 0};
    size_t n = 8;
    uint16_t n_ctx = 1;

    uint32_t freq[1][256];
    memset(freq, 0, sizeof(freq));
    /* Set freqs for symbols 0-3, sum must = T=4096 */
    freq[0][0] = 1024;
    freq[0][1] = 1024;
    freq[0][2] = 1024;
    freq[0][3] = 1024;

    uint32_t cum[1][256];
    memset(cum, 0, sizeof(cum));
    cum[0][0] = 0;
    cum[0][1] = 1024;
    cum[0][2] = 2048;
    cum[0][3] = 3072;

    /* Encode */
    uint8_t enc_buf[4096];
    size_t enc_len = sizeof(enc_buf);
    int rc = ttio_rans_encode_block(symbols, contexts, n, n_ctx,
                                     freq, enc_buf, &enc_len);
    assert(rc == TTIO_RANS_OK);
    assert(enc_len > 0);

    /* Build decode table */
    uint8_t dtab[1][TTIO_RANS_T];
    ttio_rans_build_decode_table(n_ctx, freq, cum, dtab);

    /* Decode */
    uint8_t dec_buf[8];
    rc = ttio_rans_decode_block(enc_buf, enc_len, n_ctx,
                                 freq, cum, dtab, dec_buf, n);
    assert(rc == TTIO_RANS_OK);
    assert(memcmp(symbols, dec_buf, n) == 0);

    printf("  test_simple_roundtrip: PASS\n");
}

int main(void) {
    printf("ttio_rans C tests:\n");
    test_simple_roundtrip();
    printf("All tests passed.\n");
    return 0;
}
```

- [ ] **Step 4: Update CMakeLists.txt**

Add to `native/CMakeLists.txt`:

```cmake
target_sources(ttio_rans PRIVATE
    src/rans_encode_scalar.c
    src/rans_decode_scalar.c
)

# Tests
enable_testing()
add_executable(test_roundtrip tests/test_roundtrip.c)
target_link_libraries(test_roundtrip ttio_rans)
add_test(NAME roundtrip COMMAND test_roundtrip)
```

- [ ] **Step 5: Build and run tests**

```bash
cd ~/TTI-O/native/_build && cmake .. && make -j$(nproc) && ctest --output-on-failure
```
Expected: `test_simple_roundtrip: PASS`

- [ ] **Step 6: Commit**

```bash
git add native/
git commit -m "feat: scalar rANS encode/decode kernels with round-trip test"
```

---

### Task 12: Implement SIMD dispatch + SSE4.1/AVX2 encode kernels

**Files:**
- Create: `native/src/dispatch.c`
- Create: `native/src/rans_encode_sse41.c`
- Create: `native/src/rans_encode_avx2.c`
- Create: `native/src/rans_decode_sse41.c`
- Create: `native/src/rans_decode_avx2.c`
- Modify: `native/CMakeLists.txt`

- [ ] **Step 1: Write cpuid dispatch**

Create `native/src/dispatch.c` — runtime detection of AVX2/SSE4.1 via `cpuid` intrinsics, populates function pointers at library load time (`__attribute__((constructor))`).

- [ ] **Step 2: Write SSE4.1 encode/decode kernels**

Create `native/src/rans_encode_sse41.c` and `native/src/rans_decode_sse41.c` using `<smmintrin.h>` intrinsics. The hot loop processes 4 rANS states in parallel using 128-bit SSE registers.

- [ ] **Step 3: Write AVX2 encode/decode kernels**

Create `native/src/rans_encode_avx2.c` and `native/src/rans_decode_avx2.c` using `<immintrin.h>` intrinsics. Process 8 states (2 groups of 4) using 256-bit registers.

- [ ] **Step 4: Update CMakeLists.txt with per-file SIMD flags**

```cmake
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    target_sources(ttio_rans PRIVATE
        src/dispatch.c
        src/rans_encode_sse41.c
        src/rans_decode_sse41.c
        src/rans_encode_avx2.c
        src/rans_decode_avx2.c
    )
    set_source_files_properties(
        src/rans_encode_sse41.c src/rans_decode_sse41.c
        PROPERTIES COMPILE_FLAGS "-msse4.1"
    )
    set_source_files_properties(
        src/rans_encode_avx2.c src/rans_decode_avx2.c
        PROPERTIES COMPILE_FLAGS "-mavx2"
    )
endif()
```

- [ ] **Step 5: Verify round-trip test still passes with dispatch**

```bash
cd ~/TTI-O/native/_build && cmake .. && make -j$(nproc) && ctest --output-on-failure
```
Expected: PASS (dispatch selects best available kernel)

- [ ] **Step 6: Commit**

```bash
git add native/
git commit -m "feat: SIMD dispatch + SSE4.1/AVX2 encode/decode kernels"
```

---

### Task 13: Implement pthread thread pool

**Files:**
- Create: `native/src/threadpool.c`
- Create: `native/tests/test_thread_safety.c`
- Modify: `native/CMakeLists.txt`

- [ ] **Step 1: Write thread pool implementation**

Create `native/src/threadpool.c`:
- `ttio_rans_pool_create(n_threads)`: Creates a fixed-size pthread pool. `n_threads <= 0` uses `sysconf(_SC_NPROCESSORS_ONLN)`.
- `ttio_rans_pool_destroy(pool)`: Joins all threads and frees resources.
- Internal: work queue with mutex + condition variable, worker function that dequeues and executes encode/decode block tasks.

- [ ] **Step 2: Implement multi-threaded encode/decode**

Add to `native/src/threadpool.c` (or a separate `rans_mt.c`):
- `ttio_rans_encode_mt()`: Splits input into blocks by `reads_per_block`, submits each block to the pool, collects results, concatenates output with V2 container header.
- `ttio_rans_decode_mt()`: Parses V2 container header, submits per-block decode tasks to pool, concatenates decoded output.

- [ ] **Step 3: Write thread-safety test**

Create `native/tests/test_thread_safety.c`:
- Spawn multiple threads that each encode/decode independently using a shared pool.
- Verify all round-trips are correct.
- Build with `-fsanitize=thread` to detect races.

- [ ] **Step 4: Update CMakeLists.txt**

```cmake
target_sources(ttio_rans PRIVATE src/threadpool.c)
find_package(Threads REQUIRED)
target_link_libraries(ttio_rans Threads::Threads)

add_executable(test_thread_safety tests/test_thread_safety.c)
target_link_libraries(test_thread_safety ttio_rans Threads::Threads)
add_test(NAME thread_safety COMMAND test_thread_safety)
```

- [ ] **Step 5: Build and run all tests**

```bash
cd ~/TTI-O/native/_build && cmake .. && make -j$(nproc) && ctest --output-on-failure
```
Expected: Both roundtrip and thread_safety tests PASS.

- [ ] **Step 6: Commit**

```bash
git add native/
git commit -m "feat: pthread thread pool for multi-block parallel rANS encode/decode"
```

---

### Task 14: Multi-block V2 wire format

**Files:**
- Modify: `native/src/threadpool.c` (or create `native/src/wire_format.c`)
- Create: `native/tests/test_v2_format.c`
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`

- [ ] **Step 1: Implement V2 container serialization in C**

The V2 header:
```
magic: "M94Z" (4 bytes)
version: 2 (1 byte)
block_count: N (uint32 LE)
reads_per_block: 65536 (uint32 LE)
context_params: {qbits, pbits, dbits, sloc} (4 bytes)
```

Each block:
```
compressed_size (uint32 LE)
[freq tables + rANS bitstream]
```

- [ ] **Step 2: Implement V2 container parsing in C**

Read V2 header, extract block_count, iterate blocks with their compressed_size prefix.

- [ ] **Step 3: Add V1 backwards compatibility in decoder**

When version byte = 1, treat the entire stream as a single block (current M94.Z V1 format). Parse using the existing single-block logic.

- [ ] **Step 4: Write V2 format test**

Create `native/tests/test_v2_format.c`:
- Encode with V2 format, decode with V2 decoder — verify round-trip.
- Encode with V1 format (existing Python encoder output), decode with V2 decoder — verify backwards compat.

- [ ] **Step 5: Update Python decoder to handle V2**

Edit `python/src/ttio/codecs/fqzcomp_nx16_z.py` — in the decode path, after reading the magic and version byte: if version == 2, parse V2 header and decode blocks. If version == 1, use existing single-block path.

- [ ] **Step 6: Build and test**

```bash
cd ~/TTI-O/native/_build && cmake .. && make -j$(nproc) && ctest --output-on-failure
```

```bash
cd ~/TTI-O/python && python -m pytest tests/test_m94z_unit.py -v 2>&1 | tail -10
```

- [ ] **Step 7: Commit**

```bash
git add native/ python/src/ttio/codecs/fqzcomp_nx16_z.py
git commit -m "feat: multi-block V2 wire format with V1 backwards compatibility"
```

---

### Task 15: Python ctypes integration

**Files:**
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`

- [ ] **Step 1: Add native library loader**

Edit `python/src/ttio/codecs/fqzcomp_nx16_z.py` — add after the Cython extension check (line ~632):

```python
import ctypes
import ctypes.util

_native_lib = None

def _load_native_lib():
    global _native_lib
    if _native_lib is not None:
        return _native_lib
    for name in ("libttio_rans.so", "libttio_rans.dylib", "ttio_rans.dll"):
        try:
            _native_lib = ctypes.CDLL(name)
            return _native_lib
        except OSError:
            continue
    path = ctypes.util.find_library("ttio_rans")
    if path:
        try:
            _native_lib = ctypes.CDLL(path)
            return _native_lib
        except OSError:
            pass
    return None

_HAVE_NATIVE_LIB = _load_native_lib() is not None
```

- [ ] **Step 2: Add native encode wrapper**

Add a function that marshals Python arrays to ctypes pointers and calls `ttio_rans_encode_block`:

```python
def _encode_via_native(symbols, contexts, n_symbols, n_contexts, freq):
    lib = _native_lib
    # ... ctypes argtypes/restype setup
    # ... call lib.ttio_rans_encode_block(...)
    # ... return bytes(out_buf[:out_len.value])
```

- [ ] **Step 3: Add native decode wrapper**

Similar ctypes wrapper for `ttio_rans_decode_block`.

- [ ] **Step 4: Wire into the three-tier fallback**

Update the encode/decode dispatch to check `_HAVE_NATIVE_LIB` first:

```python
def _encode_rans_block(...):
    if _HAVE_NATIVE_LIB:
        return _encode_via_native(...)
    if _HAVE_C_EXTENSION:
        return _encode_via_cython(...)
    return _encode_pure_python(...)
```

- [ ] **Step 5: Test with native library**

```bash
cd ~/TTI-O/python && LD_LIBRARY_PATH=../native/_build python -m pytest tests/test_m94z_unit.py -v 2>&1 | tail -10
```
Expected: Tests pass using native library.

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/codecs/fqzcomp_nx16_z.py
git commit -m "feat: Python ctypes integration for libttio_rans (three-tier fallback)"
```

---

### Task 16: Java JNI integration

**Files:**
- Create: `native/src/ttio_rans_jni.c`
- Create: `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java`
- Modify: `native/CMakeLists.txt`
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`

- [ ] **Step 1: Write JNI wrapper C file**

Create `native/src/ttio_rans_jni.c` — JNI native methods bridging Java byte arrays to the C API.

- [ ] **Step 2: Write Java native class**

Create `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java`:

```java
package global.thalion.ttio.codecs;

public class TtioRansNative {
    private static boolean loaded = false;

    static {
        try {
            System.loadLibrary("ttio_rans_jni");
            loaded = true;
        } catch (UnsatisfiedLinkError e) {
            loaded = false;
        }
    }

    public static boolean isAvailable() { return loaded; }

    public static native int encodeBlock(
        byte[] symbols, short[] contexts, int nContexts,
        int[][] freq, byte[] out, int[] outLen);

    public static native int decodeBlock(
        byte[] compressed, int nContexts,
        int[][] freq, int[][] cum,
        byte[] symbols, int nSymbols);
}
```

- [ ] **Step 3: Wire into FqzcompNx16Z.java encode/decode**

Add native fast path in `FqzcompNx16Z.java`:

```java
if (TtioRansNative.isAvailable()) {
    // use native encode
} else {
    // existing pure Java path
}
```

- [ ] **Step 4: Add JNI CMake target**

```cmake
option(TTIO_RANS_BUILD_JNI "Build JNI wrapper" OFF)
if(TTIO_RANS_BUILD_JNI)
    find_package(JNI REQUIRED)
    add_library(ttio_rans_jni SHARED src/ttio_rans_jni.c)
    target_link_libraries(ttio_rans_jni ttio_rans JNI::JNI)
    target_include_directories(ttio_rans_jni PRIVATE ${JNI_INCLUDE_DIRS})
endif()
```

- [ ] **Step 5: Build and test**

```bash
cd ~/TTI-O/native/_build && cmake -DTTIO_RANS_BUILD_JNI=ON .. && make -j$(nproc)
cd ~/TTI-O/java && mvn test -Dtest="FqzcompNx16ZUnitTest" -q 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add native/ java/
git commit -m "feat: Java JNI integration for libttio_rans"
```

---

### Task 17: Objective-C direct C linkage integration

**Files:**
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.m`
- Modify: `objc/Source/GNUmakefile` (or equivalent)

- [ ] **Step 1: Add libttio_rans include and link**

Edit `objc/Source/GNUmakefile` to add:
- `-I../../native/include` to CFLAGS
- `-L../../native/_build -lttio_rans` to LDFLAGS

- [ ] **Step 2: Add native fast path in TTIOFqzcompNx16Z.m**

```objc
#if __has_include("ttio_rans.h")
#include "ttio_rans.h"
#define HAVE_NATIVE_RANS 1
#else
#define HAVE_NATIVE_RANS 0
#endif
```

In the encode method, check `HAVE_NATIVE_RANS` and call `ttio_rans_encode_block()` directly.

- [ ] **Step 3: Build and test**

```bash
cd ~/TTI-O/objc && make -j$(nproc) && make check 2>&1 | tail -20
```

- [ ] **Step 4: Commit**

```bash
git add objc/
git commit -m "feat: ObjC direct C linkage for libttio_rans"
```

---

### Task 18: Performance throughput test

**Files:**
- Create: `python/tests/perf/test_m94z_throughput.py`
- Create: `native/bench/bench_throughput.c`

- [ ] **Step 1: Write Python throughput test**

Create `python/tests/perf/test_m94z_throughput.py`:

```python
"""M94.Z FQZCOMP_NX16_Z throughput regression smoke.

Marked ``perf`` so it doesn't run in the default pytest pass; opt-in via
``pytest -m perf``. Asserts conservative lower bounds on encode/decode.

Run::

    pytest python/tests/perf/test_m94z_throughput.py -v -s -m perf
"""
from __future__ import annotations

import time

import pytest

from ttio.codecs.fqzcomp_nx16_z import decode_with_metadata, encode

MIN_CYTHON_ENCODE_MBPS = 30.0
MIN_CYTHON_DECODE_MBPS = 10.0


def _build_quality_data(n_reads: int, read_len: int) -> tuple[bytes, list[int], list[int]]:
    """Generate deterministic quality data matching V10 harness."""
    n_qual = n_reads * read_len
    qual_buf = bytearray(n_qual)
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for i in range(n_qual):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        qual_buf[i] = 33 + 20 + ((s >> 32) % 21)
    read_lengths = [read_len] * n_reads
    revcomp_flags = [(1 if (i & 7) == 0 else 0) for i in range(n_reads)]
    return bytes(qual_buf), read_lengths, revcomp_flags


@pytest.mark.perf
def test_fqzcomp_nx16_z_throughput(capsys):
    """Encode+decode 100K × 100bp qualities (~10 MiB)."""
    qualities, read_lengths, revcomp_flags = _build_quality_data(100_000, 100)
    raw_mb = len(qualities) / 1e6

    t0 = time.perf_counter()
    encoded = encode(qualities, read_lengths, revcomp_flags)
    t_enc = time.perf_counter() - t0

    t1 = time.perf_counter()
    decoded, _, _ = decode_with_metadata(encoded, revcomp_flags=revcomp_flags)
    t_dec = time.perf_counter() - t1

    enc_mbps = raw_mb / t_enc if t_enc > 0 else float("inf")
    dec_mbps = raw_mb / t_dec if t_dec > 0 else float("inf")
    ratio = len(encoded) / len(qualities)

    with capsys.disabled():
        print(
            f"\n[m94z perf] 100K × 100bp qualities, "
            f"{raw_mb:.1f}MB raw -> {len(encoded)/1e6:.2f}MB encoded "
            f"({ratio:.3f}x ratio)"
        )
        print(
            f"  encode {enc_mbps:.1f} MB/s ({t_enc:.3f}s), "
            f"decode {dec_mbps:.1f} MB/s ({t_dec:.3f}s)"
        )

    assert decoded == qualities, "round-trip mismatch"
    assert enc_mbps >= MIN_CYTHON_ENCODE_MBPS, (
        f"NX16_Z encode at {enc_mbps:.1f} MB/s, need >={MIN_CYTHON_ENCODE_MBPS} MB/s"
    )
    assert dec_mbps >= MIN_CYTHON_DECODE_MBPS, (
        f"NX16_Z decode at {dec_mbps:.1f} MB/s, need >={MIN_CYTHON_DECODE_MBPS} MB/s"
    )
```

- [ ] **Step 2: Write C benchmark**

Create `native/bench/bench_throughput.c`:

```c
#include "ttio_rans.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int main(void) {
    size_t n = 10 * 1024 * 1024; /* 10 MiB */
    uint8_t *symbols = malloc(n);
    uint16_t *contexts = malloc(n * sizeof(uint16_t));
    /* ... generate test data, build freq tables ... */
    /* ... time encode/decode, report MB/s ... */
    printf("Encode: %.1f MB/s\n", n / 1e6 / t_enc);
    printf("Decode: %.1f MB/s\n", n / 1e6 / t_dec);
    free(symbols);
    free(contexts);
    return 0;
}
```

- [ ] **Step 3: Run throughput test**

```bash
cd ~/TTI-O/python && python -m pytest tests/perf/test_m94z_throughput.py -v -s -m perf 2>&1 | tail -10
```
Expected: PASS with throughput metrics printed.

- [ ] **Step 4: Commit**

```bash
git add python/tests/perf/test_m94z_throughput.py native/bench/
git commit -m "feat: M94.Z throughput regression test + C benchmark harness"
```

---

### Task 19: Update benchmark harnesses for native/Cython annotation

**Files:**
- Modify: `tools/perf/profile_python_full.py`
- Modify: `tools/perf/baseline.json`

- [ ] **Step 1: Add native/Cython annotation to Python harness**

Edit `tools/perf/profile_python_full.py` — in `bench_codecs_genomic()`, add a log line indicating which backend is in use:

```python
from ttio.codecs.fqzcomp_nx16_z import _HAVE_NATIVE_LIB, _HAVE_C_EXTENSION
backend = "native" if _HAVE_NATIVE_LIB else ("cython" if _HAVE_C_EXTENSION else "pure-python")
print(f"  [fqzcomp_nx16_z backend: {backend}]")
```

- [ ] **Step 2: Update baseline.json with current NX16_Z values**

Run the Python harness once and capture the updated NX16_Z timings for the baseline.

- [ ] **Step 3: Commit**

```bash
git add tools/perf/
git commit -m "perf: annotate fqzcomp_nx16_z backend in harness, update baseline"
```

---

### Task 20: Final cross-language conformance verification

**Files:** (none modified — verification only)

- [ ] **Step 1: Run full Python test suite**

```bash
cd ~/TTI-O/python && python -m pytest tests/ -x -q --ignore=tests/perf 2>&1 | tail -10
```
Expected: All tests pass.

- [ ] **Step 2: Build and test Java**

```bash
cd ~/TTI-O/java && mvn test -q 2>&1 | tail -10
```
Expected: BUILD SUCCESS.

- [ ] **Step 3: Build and test ObjC**

```bash
cd ~/TTI-O/objc && make check 2>&1 | tail -20
```
Expected: All tests pass.

- [ ] **Step 4: Run cross-language perf comparison**

```bash
cd ~/TTI-O && python tools/perf/profile_python_full.py --n 1000 --peaks 8 2>&1 | grep -A5 "codecs.genomic"
```
Expected: NX16_Z benchmarks only, no NX16 entries.

- [ ] **Step 5: Verify no stale NX16 references remain**

```bash
cd ~/TTI-O && grep -r "FQZCOMP_NX16[^_Z]" --include="*.py" --include="*.java" --include="*.m" --include="*.h" --include="*.json" -l
```
Expected: No results (all NX16 references removed except `_RESERVED_10` placeholder in Java enum and enum value comment in ObjC).
