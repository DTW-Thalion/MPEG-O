# Per-run sticky qualities strategy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decide the M94.Z qualities strategy once per genomic run (block 0
auto-tunes, later blocks encode only the winner), cutting qualities CPU ~3x
after block 0.

**Architecture:** Two kernel additions (hint 7 = V4-auto-with-sequences; a
wire-header winner sniffer), hint plumbing through each SDK's codec context,
and identical sticky logic in the three streaming writers (pin from block 0
by index, gate later blocks on the verdict, `TTIO_M94Z_EXHAUSTIVE=1` opt-out).

**Tech Stack:** C (native/src + python/_native mirror), ObjC, Java (JNI),
Python (ctypes). Worktree: `~/TTI-O.worktrees/block-parallel` (WSL).

**Spec:** docs/superpowers/plans/2026-08-19-fqz-v5-sticky-strategy-spec.md
(approved 2026-08-19, incl.: env name OK; `inflight-estimate` (ff42abc6)
rides in this PR; block-0 gate confirmed).

## Global Constraints

- Wire format and every decode path untouched.
- Strategy choice must be timing-independent: pin from block 0 (by index),
  never "first block to finish". Repeated runs and all three SDKs must
  produce identical bytes for identical input.
- Whole-run (non-streaming) writers keep hint -1 (single encode = full tune).
- `TTIO_M94Z_EXHAUSTIVE=1` (read by writers at init) restores the every-block
  3-way tune exactly.
- python/_native is a mirror of native/ minus the pthread autotune block —
  apply every kernel change to BOTH trees, adapted.
- No AI attribution anywhere; no change-describing comments; commit style =
  short imperative subject, e.g. "kernel: qualities strategy sniffer".
- ObjC rebuilds need `. /usr/share/GNUstep/Makefiles/GNUstep.sh` first.
- Never run bare `ctest` as a gate — run the test binaries directly and read
  their output.

---

### Task 1: Kernel — hint 7 (V4-auto) + winner sniffer, native tree

**Files:**
- Modify: `native/include/ttio_rans.h` (near line 298, the V5 defines)
- Modify: `native/src/m94z_qual.c` (ttio_m94z_qual_encode, ~line 96)
- Modify: `native/src/m94z_v4_wire.c` (append)
- Test: `native/tests/test_m94z_qual_umbrella.c`

**Interfaces:**
- Produces: `#define TTIO_M94Z_HINT_V4_AUTO 7`;
  `int ttio_m94z_qual_stream_strategy(const uint8_t *in, size_t in_len)`
  returning 4 (V4 stream), 5, 6 (V5 S5/S6), or <0 on error
  (-1 args/short, -2 bad magic/version, -3 truncated/unknown strategy).

- [ ] **Step 1: Write failing tests** — extend `test_m94z_qual_umbrella.c`
  (follow its existing harness conventions: same CHECK/assert macros and
  the same fixture arrays `qual`, `lens`, `seq`, sizes N/NR/NS/NRS used at
  lines 57-117):

```c
    /* hint 7 == V4-auto: byte-identical to (seq=NULL, hint -1) */
    size_t la = cap, lb = cap;
    rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, NULL,
                               -1, 0, buf_a, &la);
    CHECK(rc == 0);
    rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, seq,
                               TTIO_M94Z_HINT_V4_AUTO, 0, buf_b, &lb);
    CHECK(rc == 0);
    CHECK(la == lb && memcmp(buf_a, buf_b, la) == 0);

    /* sniffer: V4 stream -> 4; forced S5 -> 5; forced S6 -> 6 */
    CHECK(ttio_m94z_qual_stream_strategy(buf_a, la) == 4);
    size_t l5 = cap;
    rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, seq, 5, 0,
                               buf_b, &l5);
    CHECK(rc == 0);
    CHECK(ttio_m94z_qual_stream_strategy(buf_b, l5) == 5);
    size_t l6 = cap;
    rc = ttio_m94z_qual_encode(qual, NS, lens, NRS, flags, seq, 6, 0,
                               buf_b, &l6);
    CHECK(rc == 0);
    CHECK(ttio_m94z_qual_stream_strategy(buf_b, l6) == 6);

    /* sniffer errors */
    CHECK(ttio_m94z_qual_stream_strategy(NULL, 0) < 0);
    CHECK(ttio_m94z_qual_stream_strategy(buf_a, 8) < 0);
    {
        uint8_t junk[30]; memset(junk, 0x58, sizeof junk);
        CHECK(ttio_m94z_qual_stream_strategy(junk, 30) < 0);
    }
```

- [ ] **Step 2: Build the native tree and run the umbrella test binary
  directly; expect compile failure (missing symbol/define).** Build dir is
  `native/_build` (existing cmake cache): `cmake --build native/_build -j`
  — find the umbrella target/binary name with
  `grep -ri umbrella native/CMakeLists.txt native/tests/CMakeLists.txt`.

- [ ] **Step 3: Implement.** In `native/include/ttio_rans.h` next to
  `TTIO_M94Z_V5_VERSION` (and update the strategy_hint comment block at
  ~line 291 to read: -1 auto, 0..4 V4 preset, 5..6 forced sequence
  strategy, 7 V4 with internal preset selection):

```c
#define TTIO_M94Z_HINT_V4_AUTO 7

/* Strategy of an encoded M94.Z stream: 4 = V4, 5/6 = V5 S5/S6.
 * <0: -1 args, -2 magic/version, -3 truncated or unknown id. */
int ttio_m94z_qual_stream_strategy(const uint8_t *in, size_t in_len);
```

  In `m94z_qual.c`, first lines of `ttio_m94z_qual_encode` body (before the
  5/6 branch):

```c
    if (strategy_hint == TTIO_M94Z_HINT_V4_AUTO) {
        strategy_hint = -1;
        seq_in = NULL;   /* V4 path with V4's own preset selection */
    }
```

  Append to `m94z_v4_wire.c` (macros TTIO_M94Z_V4_MAGIC / _V4_VERSION /
  _V5_WIRE_VERSION are in its header):

```c
int ttio_m94z_qual_stream_strategy(const uint8_t *in, size_t in_len)
{
    if (in == NULL || in_len < 30) return -1;
    if (memcmp(in, TTIO_M94Z_V4_MAGIC, 4) != 0) return -2;
    if (in[4] == TTIO_M94Z_V4_VERSION) return 4;
    if (in[4] != TTIO_M94Z_V5_WIRE_VERSION) return -2;
    uint32_t rlt_len;
    memcpy(&rlt_len, in + 22, 4);
    if (in_len < (size_t)30 + rlt_len + 2) return -3;
    uint8_t sid = in[30 + (size_t)rlt_len + 1];
    return (sid == 5 || sid == 6) ? (int)sid : -3;
}
```

- [ ] **Step 4: Rebuild, run the umbrella test binary directly, all pass.
  Also rerun the two neighbour binaries (test_fqzcomp_qual_autotune,
  test_fqzcomp_qual_threaded) — same build dir.**

- [ ] **Step 5: Commit** — `kernel: V4-auto hint and stream-strategy sniffer`

### Task 2: Mirror Task 1 into python/_native + ctypes binding

**Files:**
- Modify: `python/_native/include/ttio_rans.h`, `python/_native/src/m94z_qual.c`,
  `python/_native/src/m94z_v4_wire.c`, `python/_native/tests/test_m94z_qual_umbrella.c`
  — same edits as Task 1 (the python m94z_qual.c has no autotune block; the
  hint-7 lines are identical).
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`
- Test: `python/tests/test_qualities_v5.py`

**Interfaces:**
- Produces: `fqzcomp_nx16_z.stream_strategy(blob: bytes) -> int` (4/5/6;
  raises RuntimeError when the native library is absent — same fallback
  convention as the module's other native-only entry points; raises
  ValueError on rc < 0); `fqzcomp_nx16_z.HINT_V4_AUTO = 7`.

- [ ] **Step 1: Apply the four python/_native file edits (copy from Task 1).**
- [ ] **Step 2: Failing Python test** in `test_qualities_v5.py` (follow the
  module's existing fixture style — it already builds V4/S5/S6 blobs):

```python
def test_stream_strategy_sniffer():
    from ttio.codecs import fqzcomp_nx16_z as fq
    # reuse the file's existing small corpus construction for
    # quals/lens/rc/seqs — copy the setup of its forced-S5 test
    v4 = fq.encode(quals, lens, rc, v4_strategy_hint=fq.HINT_V4_AUTO,
                   sequences=seqs)
    assert fq.stream_strategy(v4) == 4
    s5 = fq.encode(quals, lens, rc, v4_strategy_hint=5, sequences=seqs)
    assert fq.stream_strategy(s5) == 5
    s6 = fq.encode(quals, lens, rc, v4_strategy_hint=6, sequences=seqs)
    assert fq.stream_strategy(s6) == 6
    import pytest
    with pytest.raises(ValueError):
        fq.stream_strategy(b"XX")
```

  If the file asserts hint validation ranges anywhere, extend that
  validation to accept 7.

- [ ] **Step 3: Run** `python -m pytest python/tests/test_qualities_v5.py -x -q`
  (worktree `.venv`); expect FAIL (no `stream_strategy`).
- [ ] **Step 4: Implement binding** in `fqzcomp_nx16_z.py`, matching the
  ctypes prototype style at lines ~288-340 (use the module's actual lib
  handle name — check how encode() reaches the CDLL):

```python
HINT_V4_AUTO = 7

# int ttio_m94z_qual_stream_strategy(const uint8_t *in, size_t in_len)
_lib.ttio_m94z_qual_stream_strategy.argtypes = [
    ctypes.c_char_p, ctypes.c_size_t]
_lib.ttio_m94z_qual_stream_strategy.restype = ctypes.c_int

def stream_strategy(blob: bytes) -> int:
    """Strategy of an encoded M94.Z stream: 4 = V4, 5/6 = V5 S5/S6."""
    if _lib is None:
        raise RuntimeError("libttio_rans not available")
    rc = _lib.ttio_m94z_qual_stream_strategy(blob, len(blob))
    if rc < 0:
        raise ValueError(f"not an M94.Z stream (rc={rc})")
    return rc
```

  Also make encode's own hint validation accept 7 and forward it to the
  kernel unchanged.
- [ ] **Step 5: Rebuild the python native lib the way this worktree does**
  — locate the loaded library first:
  `python -c "from ttio.codecs._native_loader import load_ttio_rans; print(load_ttio_rans()._name)"`,
  rebuild the cmake tree that produces it (python/_native or native/_build),
  and confirm the new symbol imports:
  `python -c "from ttio.codecs.fqzcomp_nx16_z import stream_strategy; print(stream_strategy.__doc__)"`.
- [ ] **Step 6: Test passes; run the whole file** (`-q`, read the tail).
- [ ] **Step 7: Commit** — `python: bind the strategy sniffer`

### Task 3: Java JNI binding

**Files:**
- Modify: `native/src/ttio_rans_jni.c` AND `python/_native/src/ttio_rans_jni.c`
  (they differ — follow each copy's local conventions)
- Modify: `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java`
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
- Test: the Java test class covering FqzcompNx16Z (find with
  `grep -rl FqzcompNx16Z java/src/test`)

**Interfaces:**
- Produces: `TtioRansNative.qualStreamStrategy(byte[] stream) -> int`;
  `FqzcompNx16Z.HINT_V4_AUTO = 7`; `FqzcompNx16Z.streamStrategy(byte[])`
  (public wrapper, throws IllegalArgumentException on rc < 0).

- [ ] **Step 1: Failing Java test** (mirror Task 2's assertions using the
  existing Java encode-with-hint overload at FqzcompNx16Z.java:181 or
  EncodeOptions.v4StrategyHint; assert streamStrategy == 4/5/6 and that a
  2-byte array throws).
- [ ] **Step 2:** `cd java && mvn -q -Dtest=<TestClass> test` — expect
  compile failure.
- [ ] **Step 3: Implement.** JNI (both copies, next to the other
  TtioRansNative functions):

```c
JNIEXPORT jint JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_qualStreamStrategy(
    JNIEnv *env, jclass cls, jbyteArray stream)
{
    (void)cls;
    if (stream == NULL) return -1;
    jsize len = (*env)->GetArrayLength(env, stream);
    jbyte *p = (*env)->GetByteArrayElements(env, stream, NULL);
    if (p == NULL) return -1;
    int rc = ttio_m94z_qual_stream_strategy((const uint8_t *)p, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, stream, p, JNI_ABORT);
    return rc;
}
```

  Java: `public static native int qualStreamStrategy(byte[] stream);` in
  TtioRansNative; in FqzcompNx16Z add the constant + wrapper and make its
  hint validation accept 7 (grep for the range check that rejects hints).
- [ ] **Step 4: Rebuild libttio_rans_jni** (the cmake target in
  native/_build that produces it — the same library the pom's
  java.library.path points at), rerun the test class: PASS.
- [ ] **Step 5: Commit** — `java: bind the strategy sniffer`

### Task 4: ObjC sniffer + hint-7 acceptance

**Files:**
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.h` / `.m`
- Test: the ObjC test file covering TTIOFqzcompNx16Z (find with
  `grep -rl FqzcompNx16Z objc/Tests`)

**Interfaces:**
- Produces: `+ (NSInteger)strategyOfEncodedStream:(NSData *)stream;`
  (4/5/6, or negative rc — never throws);
  `TTIOM94ZHintV4Auto` = 7 (#define or NS_ENUM in the header).

- [ ] **Step 1: Failing ObjC test** — encode with
  `encodeV4WithQualities:...strategyHint:` using hints
  TTIOM94ZHintV4Auto/5/6 (the sequences-taking variant at
  TTIOFqzcompNx16Z.m:339 for 5/6) and assert strategyOfEncodedStream
  returns 4/5/6; assert a 2-byte NSData returns a negative value; assert
  hint-7 output equals the sequences:nil hint:-1 output byte-for-byte.
- [ ] **Step 2:** rebuild objc (`. /usr/share/GNUstep/Makefiles/GNUstep.sh;
  make -s messages=no` — grep output for errors), run `Tests/obj/TTIOTests`
  and grep its output for the new test name: expect failure/missing.
- [ ] **Step 3: Implement.** Under `#if TTIO_HAS_NATIVE_RANS` call
  `ttio_m94z_qual_stream_strategy(stream.bytes, stream.length)`; in the
  `#else` branch parse the same header inline (memcmp magic, byte 4,
  LE u32 at 22, byte at 30+rlt_len+1 — the Task 1 C body, translated).
  Hint 7 already reaches the kernel through the `(int)strategyHint`
  pass-through at TTIOFqzcompNx16Z.m:434 — but check any ObjC-side hint
  validation and extend it to accept 7.
- [ ] **Step 4: Rebuild, run, PASS.**
- [ ] **Step 5: Commit** — `objc: strategy sniffer and V4-auto hint`

### Task 5: Python hint plumbing (context -> adapter -> writer function)

**Files:**
- Modify: `python/src/ttio/codecs/_context.py` (CodecContext, line ~20)
- Modify: `python/src/ttio/codecs/_registry.py` (_FqzcompNx16ZCodec.encode,
  line ~107)
- Modify: `python/src/ttio/_dataset_write_genomic.py`
  (`_write_qualities_fqzcomp_nx16_z` line ~327 and `_write_genomic_run`
  line ~381)
- Modify: `python/src/ttio/genomic/_blocks.py` (`encode_block` line ~103)
- Test: `python/tests/test_qualities_v5.py` (or the registry test module —
  `grep -rl CodecContext python/tests | head`)

**Interfaces:**
- Consumes: `fqzcomp_nx16_z.encode(..., v4_strategy_hint=)` (exists),
  Task 2's HINT_V4_AUTO and stream_strategy.
- Produces: `CodecContext.qual_strategy_hint: int = -1`;
  `encode_block(block, qual_strategy_hint=-1)`;
  `_write_genomic_run(parent, name, run, qual_strategy_hint=-1)`;
  `_write_qualities_fqzcomp_nx16_z(sc, run, qual_strategy_hint=-1)`.

- [ ] **Step 1: Failing test** — small run (well under
  TTIO_M94Z_V5_MIN_QUALITIES) with base-parallel sequences, encoded via
  `encode_block(block, qual_strategy_hint=5)`; assert
  `stream_strategy(blobs.blobs["qualities"]) == 5` (forced 5/6 bypasses the
  size gate, so a tiny block proves the hint traversed
  run -> context -> adapter -> codec). Second assertion: the default call
  (hint omitted) yields a V4 stream, byte-identical to today's output
  (capture the expected bytes by encoding the same block before the
  change or with hint -1 explicitly).
- [ ] **Step 2: Run, expect TypeError (unknown kwarg).**
- [ ] **Step 3: Implement** — dataclass field
  `qual_strategy_hint: int = -1  # fqzcomp; -1 auto, 7 V4-auto, 5/6 V5`
  on CodecContext; adapter passes
  `v4_strategy_hint=ctx.qual_strategy_hint`; the two write functions take
  and forward the keyword (default -1 keeps every existing call site
  byte-identical); `encode_block` forwards into `_write_genomic_run`.
- [ ] **Step 4: PASS; also run**
  `python -m pytest python/tests -x -q -k "genomic or qualities"`.
- [ ] **Step 5: Commit** — `python: qualities strategy hint plumbing`

### Task 6: Java hint plumbing

**Files:**
- Modify: `java/.../genomics/GenomicWriteContext.java` (add component)
- Modify: every `new GenomicWriteContext(` site — find with
  `grep -rn "new GenomicWriteContext" java/src` (known: none(),
  SpectralDatasetGenomicWriter:45, GenomicStreamWriter flush x2)
- Modify: `java/.../codecs/registry/CodecContext.java` (builder field
  `v4StrategyHint`, default -1)
- Modify: `java/.../codecs/registry/CodecRegistry.java` FqzcompCodec.encode
  (line ~107): pass the hint via the FqzcompNx16Z overload that takes
  strategyHint (line 181), with the padCount the no-hint path computes
  today — read that overload chain first and keep byte-identical defaults.
- Modify: `java/.../SpectralDatasetGenomicWriter.java` —
  `writeQualitiesFqzcompNx16Z(sc, run)` (~line 990) gains an `int hint`
  parameter; the call site (~line 309) passes `ctx.qualStrategyHint()` if
  the enclosing method has the GenomicWriteContext in scope, else thread
  it one level up (it is the method with the line-54 signature).
- Test: same Java test class as Task 3, plus the blocks-level test class
  (`grep -rl encodeBlock java/src/test`).

**Interfaces:**
- Produces: `GenomicWriteContext(Map chromNameToId, byte[] referenceMd5,
  int qualStrategyHint)` with `none()` -> -1;
  `CodecContext.v4StrategyHint()` (default -1).

- [ ] **Step 1: Failing test** — encodeBlock with a ctx whose hint = 5 on a
  tiny sequences-bearing block: qualities blob's streamStrategy == 5;
  default ctx: V4 bytes identical to before the change.
- [ ] **Step 2: mvn compile/test fails. Step 3: implement.**
- [ ] **Step 4:** `cd java && mvn -q test` — full module, read the tail.
- [ ] **Step 5: Commit** — `java: qualities strategy hint plumbing`

### Task 7: ObjC hint plumbing

**Files:**
- Modify: `objc/Source/Genomics/TTIOGenomicWriteContext.*` (property
  `NSInteger qualStrategyHint`, default -1 in init)
- Modify: `objc/Source/Codecs/Registry/TTIOCodecContext.h/.m` (property
  `NSNumber *qualStrategyHint`, nil == -1)
- Modify: `objc/Source/Codecs/Registry/TTIOCodecRegistry.m`
  _TTIOFqzcompCodec encode (line ~127): pass the hint — add an
  `encodeWithQualities:readLengths:revcompFlags:sequences:strategyHint:error:`
  variant to TTIOFqzcompNx16Z that forwards into the existing encodeQual
  path (absent/nil hint == -1, output byte-identical).
- Modify: `objc/Source/Dataset/TTIOSpectralDataset+GenomicWrite.m` — the
  Storage twin `_TTIO_M94Z_WriteQualitiesFqzcompNx16ZStorage` (~line 1735)
  gains an `NSInteger qualStrategyHint` parameter, set on fqzCtx; its call
  site (~line 2026) passes the hint from the TTIOGenomicWriteContext that
  `writeGenomicRunStorage:toGroup:name:context:` received (verify the
  scope chain; thread a parameter through if needed). The HDF5 twin
  (~line 1686, call at ~2526) stays hint -1 (whole-run path, per spec).
- Test: the ObjC genomic-blocks test file (`grep -rl encodeBlock objc/Tests`).

**Interfaces:**
- Consumes: Task 4's sniffer + constants.
- Produces: `TTIOGenomicWriteContext.qualStrategyHint` (NSInteger, -1
  default) — Task 10 sets it per block.

- [ ] **Step 1: Failing test** — encodeBlock with ctx.qualStrategyHint = 5,
  tiny block with sequences:
  `[TTIOFqzcompNx16Z strategyOfEncodedStream:blobs.blobs[@"qualities"]] == 5`;
  default ctx: unchanged bytes.
- [ ] **Step 2-4: build / fail / implement / pass** (run TTIOTests, grep
  the new test name in the output).
- [ ] **Step 5: Commit** — `objc: qualities strategy hint plumbing`

### Task 8: Python writer sticky selection

**Files:**
- Modify: `python/src/ttio/genomic/stream_writer.py`
- Test: the genomic stream-writer test module (the "writer 9/9" file —
  `grep -rln GenomicStreamWriter python/tests`)

**Interfaces:**
- Consumes: `encode_block(block, qual_strategy_hint=)`,
  `fqzcomp_nx16_z.stream_strategy`, `HINT_V4_AUTO`, `Compression`.

- [ ] **Step 1: Failing tests** (three, in the writer test module; reuse
  its existing WrittenGenomicRun batch fixtures and block-size options to
  split one corpus into 4+ blocks; a corpus of random-ish qualities makes
  V4 win):

```python
def test_sticky_pin_matches_exhaustive(tmp_path, monkeypatch):
    a = _write_corpus(tmp_path / "a.tio")      # default (sticky)
    monkeypatch.setenv("TTIO_M94Z_EXHAUSTIVE", "1")
    b = _write_corpus(tmp_path / "b.tio")      # exhaustive
    assert _qual_blobs(a) == _qual_blobs(b)    # winner-consistent corpus

def test_sticky_deterministic_across_runs(tmp_path):
    assert _qual_blobs(_write_corpus(tmp_path / "c.tio")) == \
           _qual_blobs(_write_corpus(tmp_path / "d.tio"))

def test_pin_is_set_after_first_block(tmp_path):
    w = _open_writer(...)   # threads >= 2, feed 2+ blocks
    ...
    w.close()
    assert w._qual_hint == fq.HINT_V4_AUTO
```

  `_qual_blobs` = read back each block's qualities channel bytes with the
  reader helper the module's other tests use (avoids container-level
  nondeterminism if any). Write `_write_corpus`/`_open_writer` concretely
  against those fixtures.
- [ ] **Step 2: Run — the pin test fails (no `_qual_hint`).**
- [ ] **Step 3: Implement.** In `__init__`:

```python
self._qual_hint = -1
self._qual_exhaustive = os.environ.get("TTIO_M94Z_EXHAUSTIVE") == "1"
self._blocks_written = 0
```

  (reuse an existing written-blocks counter if one exists). In
  `_cut_block` (pooled branch, after
  `self._drain(block_until=self._window - 1)` and before the submit):

```python
if (not self._qual_exhaustive and self._qual_hint == -1
        and (self._inflight or self._blocks_written)):
    self._drain(block_until=0)   # block-0 gate: pin before more submits
```

  Submit and serial paths pass the hint:

```python
self._pool.submit(_blocks.encode_block, block,
                  qual_strategy_hint=self._qual_hint)
# serial branch:
self._write_encoded(block, _blocks.encode_block(
    block, qual_strategy_hint=self._qual_hint))
```

  In `_write_encoded`, after the successful write:

```python
self._blocks_written += 1
if (self._qual_hint == -1 and not self._qual_exhaustive
        and blobs.compression.get("qualities")
            == int(_Compression.FQZCOMP_NX16_Z)):
    s = _fq.stream_strategy(blobs.blobs["qualities"])
    self._qual_hint = _fq.HINT_V4_AUTO if s == 4 else s
```

  RANS_ORDER0-fallback blocks (zero-length reads) don't match the codec
  id, so the pin waits for the next M94Z block — still deterministic
  (blocks drain in index order whenever the pin is unknown).
- [ ] **Step 4: PASS; run the whole writer module.**
- [ ] **Step 5: Commit** — `python: per-run sticky qualities strategy`

### Task 9: Java writer sticky selection

**Files:**
- Modify: `java/.../genomics/GenomicStreamWriter.java`
- Test: `GenomicStreamWriterTest.java` (the 8/8 suite)

**Interfaces:** Consumes Task 3 + Task 6.

- [ ] **Step 1: Failing tests** — the same three as Task 8, translated.
  Env control: read how existing Java tests set env; if none do, add a
  package-private constructor/setter override used only by tests and say
  so in its javadoc.
- [ ] **Step 2-3: Implement.** Fields:

```java
private int qualHint = -1;
private long blocksWritten = 0;
private final boolean qualExhaustive =
    "1".equals(System.getenv("TTIO_M94Z_EXHAUSTIVE"));
```

  In `flush()` before building `bctx` (and mirrored on the serial-path
  ctx):

```java
if (!qualExhaustive && qualHint == -1
        && (blocksWritten > 0 || !inflight.isEmpty())) {
    drain(0);   // block-0 gate
}
GenomicWriteContext bctx = new GenomicWriteContext(
    new java.util.LinkedHashMap<>(chromMap), referenceMd5, qualHint);
```

  In `writeEncoded` after the write (compare the codec id in the same
  representation GenomicBlocks:192 stores it):

```java
blocksWritten++;
if (qualHint == -1 && !qualExhaustive
        && isFqzcompQualities(blobs)) {
    int s = FqzcompNx16Z.streamStrategy(blobs.blobs().get("qualities"));
    qualHint = (s == 4) ? FqzcompNx16Z.HINT_V4_AUTO : s;
}
```

- [ ] **Step 4:** `mvn -q test`, full suite green.
- [ ] **Step 5: Commit** — `java: per-run sticky qualities strategy`

### Task 10: ObjC writer sticky selection

**Files:**
- Modify: `objc/Source/Genomics/TTIOGenomicStreamWriter.m`
- Test: the ObjC stream-writer test file
  (`grep -rl GenomicStreamWriter objc/Tests`)

**Interfaces:** Consumes Task 4 + Task 7.

- [ ] **Step 1: Failing tests** — same three, translated (env via
  setenv/unsetenv around writer construction; follow the suite's existing
  env hygiene pattern).
- [ ] **Step 2-3: Implement.** Ivars `NSInteger _qualHint;` (init -1),
  `BOOL _qualExhaustive;` (init from getenv), `NSUInteger _blocksWritten;`.
  In `_cutBlock:` after the two drains and before creating `bctx`:

```objc
    if (!_qualExhaustive && _qualHint == -1
        && (_blocksWritten > 0 || _inflight.count > 0)) {
        if (![self _drainUntil:0 error:error]) return NO; /* block-0 gate */
    }
```

  then `bctx.qualStrategyHint = _qualHint;` (and on the serial-path ctx).
  In `_writeEncoded:blobs:error:` after the successful write: increment
  `_blocksWritten`; when
  `[blobs.codecs[@"qualities"] unsignedIntegerValue] ==
  TTIOCompressionFqzcompNx16Z` and unpinned, pin via
  `[TTIOFqzcompNx16Z strategyOfEncodedStream:]`, mapping 4 ->
  TTIOM94ZHintV4Auto. (Verify the TTIOBlockBlobs property names for the
  blobs/codecs dictionaries in TTIOGenomicBlocks.h first.)
- [ ] **Step 4: rebuild; run the writer suite; then the FULL gate:**
  s78/bp_objc_capped.sh -> /home/toddw/bp-capped.log; expect 4975+new
  tests, 0 failures.
- [ ] **Step 5: Commit** — `objc: per-run sticky qualities strategy`

### Task 11: Full gates + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (current unreleased section)

- [ ] Python: `python -m pytest python/tests -q` (full, expect 2526+ with
  the new tests, read the tail).
- [ ] Java: `cd java && mvn -q test` (full).
- [ ] ObjC: full capped gate (rerun if any commit landed since Task 10).
- [ ] Native: umbrella + autotune + threaded binaries in both trees, run
  directly.
- [ ] CHANGELOG entry: one block covering (a) per-run sticky qualities
  strategy + TTIO_M94Z_EXHAUSTIVE, (b) the halved in-flight block estimate
  (ff42abc6) that rides in this PR.
- [ ] Commit — `changelog: sticky qualities strategy`

### Task 12: Bench acceptance + branch/PR

- [ ] Rebase onto origin/main once #304/#305 are merged
  (`git fetch origin && git rebase origin/main` on `inflight-estimate`),
  then rename: `git branch -m fqz-sticky-strategy`.
- [ ] 3.7 GB smoke (`/tmp/smoke.fastq`, same command as the 126.4 MB/s
  baseline in qc-probe/pp-accept-est2.log): record MB/s + peak RSS.
- [ ] Winner tally on the output: `fqz_tally3.py` — expect V4 uniformly
  (confirms the pin held for the whole run).
- [ ] Lowcov V5-pin end-to-end: import the na12878 chr22 lowcov BAM
  (prepared/), tally: all blocks V5-S5.
- [ ] Escape hatch spot-check: TTIO_M94Z_EXHAUSTIVE=1 rerun of a small
  import is byte-identical to a pre-change baseline import.
- [ ] 50 GB acceptance config rerun (baseline 5:11 / 153.4 MB/s, peak
  20.1 GB): record new wall/rate/peak.
- [ ] Push via Windows git from PowerShell (WSL push hangs):
  `git -C "\\wsl.localhost\Ubuntu\home\toddw\TTI-O.worktrees\block-parallel" push -u origin fqz-sticky-strategy`
- [ ] PR: 5 parts, <200 words incl. title, body via --body-file. THEN the
  blocking audit: draft + live artifact scan (ripgrep, read the count) for
  attribution strings and style tells; verify every measured number in the
  body against the logs (adjacent-claim check).

## Self-review notes

- Spec coverage: hint 7 (T1/T2/T4), sniffer (T1-T4), plumbing (T5-T7),
  sticky + gate + env (T8-T10), whole-run unaffected (defaulted params,
  T5-T7), determinism tests (T8-T10), exhaustive escape (T8-T12),
  acceptance (T12), CHANGELOG (T11), inflight-estimate rides along
  (branch base + T11 + T12).
- The auto-tuned V5-pin path is exercised by bench (T12, lowcov corpus)
  rather than unit suites: TTIO_M94Z_V5_MIN_QUALITIES = 1 MiB makes an
  auto-tuned V5 win impractical in fast tests; forced-hint tests (T5-T7)
  cover the plumbing, kernel tests cover the codec, and the writer pin
  logic is strategy-agnostic (tested with the V4 pin).
