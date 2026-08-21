# GPU V6 Phase 0 + Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the Vulkan dev-loop and throughput questions (Phase 0),
then ship the CPU-only M94.Z V6 segmented adaptive qualities codec with
hint plumbing in all three SDKs (Phase 1).

**Architecture:** V6 splits a block's qualities into N contiguous
segments at read boundaries; each segment is an independent adaptive
chain using the existing sm_model + rc_cram coder with a slimmed
context word (Q quality bits, P position bits, D delta bits). Segments
run in parallel on a CPU pool; bytes are independent of thread count.
Phase 2 (not this plan) adds the Vulkan engine producing identical
bytes.

**Tech Stack:** C (native/src, mirrored to python/_native by the build
backend), pthreads, ctypes/JNI/ObjC FFI, GLSL->SPIR-V only in the
throwaway Phase 0 spike.

**Spec:** docs/superpowers/specs/2026-08-20-gpu-engine-v6-design.md

## Global Constraints

- V6 CPU output must be byte-identical across thread counts, runs, and
  SDKs (spec section 8).
- Ratio gate: V6 within 2% of the sticky-tuned V4/V5 size per corpus
  class, target 1% (spec section 8; corpora in Task P1.5).
- Model envelope: 2^C * n_symbols * 2 bytes per segment; N * model
  bytes <= 512 MB per in-flight block (spec section 3.2).
- No AI attribution anywhere; no change-describing comments; commit
  subjects short imperative ("kernel: ...", "python: ...").
- Apply kernel edits to native/ only (python/_native is generated and
  gitignored; edit a local copy only to keep local builds working).
- ObjC rebuilds: `. /usr/share/GNUstep/Makefiles/GNUstep.sh` first;
  GNUstep make has no header-dep tracking and UNC edits do not bump
  mtimes — touch edited files in WSL and verify new selectors with
  `strings objc/Source/obj/libTTIO.so.0.0.1` before running gates.
- Python tests: `TTIO_RANS_LIB_PATH=$PWD/native/_build/libttio_rans.so
  .venv/bin/python -m pytest ...` from the worktree root.
- Never gate on bare ctest; run test binaries directly and read output.
- Worktree: ~/TTI-O.worktrees/block-parallel, branch gpu-engine-v6.

---

## Phase 0 — spike (throwaway; output is a report, not kept code)

### Task P0.1: Vulkan dev-loop probe

**Files:**
- Create: `docs/superpowers/plans/2026-08-20-gpu-v6-phase0-findings.md`
  (started here, finished in P0.2)

**Interfaces:**
- Produces: a written verdict — "kernel dev happens in WSL via Dozen"
  or "kernel dev happens on native Windows" — that Phase 2 planning
  consumes.

- [ ] **Step 1: Probe WSL.** Run:

```bash
wsl -e bash -lc 'sudo apt-get install -y vulkan-tools mesa-vulkan-drivers 2>&1 | tail -1; vulkaninfo --summary 2>&1 | head -30'
```

Record every reported physical device (expect Mesa Dozen mapping the
RTX 4000 Ada through D3D12, possibly llvmpipe). If only llvmpipe
appears, WSL kernel dev is CPU-emulated only.

- [ ] **Step 2: Probe native Windows.** In PowerShell:

```powershell
vulkaninfo --summary 2>&1 | Select-Object -First 30
```

If vulkaninfo is absent, note that the LunarG Vulkan SDK install is a
Phase 2 prerequisite; the NVIDIA driver (596.58) already ships the
runtime loader, so also try:
`(Get-Item C:\Windows\System32\vulkan-1.dll).VersionInfo`.

- [ ] **Step 3: Write the findings file** with a table: environment,
  devices seen, driver/API version, verdict line for the dev loop.
  Commit: `docs: phase 0 vulkan environment probe`

### Task P0.2: GPU coding-pattern microbenchmark (throwaway)

**Files:**
- Create: `tools/perf/gpu_spike/README.md` (labels everything here
  throwaway; results copied into the findings file)
- Create: `tools/perf/gpu_spike/spike.c` (Vulkan harness, ~300 lines)
- Create: `tools/perf/gpu_spike/chain.comp` (GLSL compute kernel)
- Modify: `docs/superpowers/plans/2026-08-20-gpu-v6-phase0-findings.md`

**Interfaces:**
- Produces: measured segments/s and projected MB/s for the V6 access
  pattern on this GPU; the go/no-go number for Phase 2.

- [ ] **Step 1: Write the kernel.** One workgroup per simulated
  segment; invocation 0 of each workgroup runs a sequential
  adaptive-coder-shaped loop (the pattern that dominates V6): a
  context-model table in device memory (2^12 contexts x 48 u16), per
  symbol: context hash, table read, add-update write, running state
  multiply — no real entropy coding, same memory behaviour.

```glsl
#version 450
layout(local_size_x = 1) in;
layout(std430, binding = 0) buffer Quals   { uint8_t q[]; };
layout(std430, binding = 1) buffer Models  { uint16_t m[]; };
layout(std430, binding = 2) buffer Out     { uint acc[]; };
layout(push_constant) uniform P { uint seg_symbols; uint n_ctx_mask; };
void main() {
    uint seg = gl_WorkGroupID.x;
    uint base = seg * seg_symbols;
    uint mbase = seg * (n_ctx_mask + 1u) * 48u;
    uint ctx = 0u; uint state = 1u;
    for (uint i = 0u; i < seg_symbols; i++) {
        uint sym = uint(q[base + i]) % 48u;
        uint slot = mbase + (ctx & n_ctx_mask) * 48u + sym;
        uint f = uint(m[slot]);
        m[slot] = uint16_t(f + 32u);
        state = state * 0x9E3779B1u + f;
        ctx = (ctx << 3u) + sym;
    }
    acc[seg] = state;
}
```

(Requires the 8/16-bit storage extensions; if the device lacks them,
use uint arrays with manual packing — note it in the findings.)

- [ ] **Step 2: Write the harness** (spike.c): create instance/device/
  queue, allocate the three buffers (256 segments x 256 Ki symbols =
  64 MiB input), compile-in the SPIR-V (build line:
  `glslangValidator -V chain.comp -o chain.spv && xxd -i chain.spv >
  chain_spv.h`), dispatch 256 workgroups, time 10 iterations with a
  fence, print symbols/s. Build on whichever environment P0.1 chose
  (WSL: `gcc spike.c -lvulkan`; Windows: cl + vulkan-1.lib).

- [ ] **Step 3: Run and record.** Compute projected V6 encode MB/s =
  symbols/s (a quality symbol is one byte) discounted 3x for real
  coder arithmetic, and compare against the CPU baseline: the sticky
  encode does ~16 MB/s per core single-pass, 318 MB/s machine-wide on
  the 50 GB corpus. Record in the findings file with the raw numbers.

- [ ] **Step 4: Also measure occupancy variants** — 64/128/512
  workgroups and local_size_x 32 with one chain per subgroup lane
  (striped model banks) — record which shape the GPU prefers; Phase 2
  planning reads this.

- [ ] **Step 5: Commit** — `spike: vulkan chain-coding microbenchmark
  and findings` — and report the go/no-go to Todd before Phase 1 work
  begins (Phase 1 is CPU-only and proceeds either way; the verdict
  gates Phase 2).

---

## Phase 1 — CPU-only V6

### Task P1.1: V6 wire documentation

**Files:**
- Create: `docs/codecs/m94z_v6.md`

**Interfaces:**
- Produces: the byte-level contract every later task implements.

- [ ] **Step 1: Write the doc** from spec section 3: outer M94Z
  container with version byte 6; body layout exactly:

```
offset  size  field
0       1     body_version = 1
1       1     reserved = 0
2       2     segment_count N        (LE u16, >= 1)
4       4     segment_symbols S      (LE u32; last segment may be short)
8       1     qbits Q
9       1     qshift
10      1     pbits P
11      1     pshift
12      1     dbits D
13      3     reserved = 0
16      4*N   seg_len[N]             (LE u32 compressed chain lengths)
16+4N   ...   N chain bodies, back to back
```

  Context word: ctx = (qctx & ((1<<Q)-1))
                    | (pos_bucket << Q)
                    | (delta_bucket << (Q+P)), where qctx updates as
  (qctx << qshift) + q per symbol and resets to 0 at each read start;
  pos_bucket = min((1<<P)-1, (len-1-i) >> pshift); delta_bucket =
  min((1<<D)-1, |q_prev - q_prev2| when i >= 2 else 0). Segments split
  at read boundaries: a segment holds whole reads and closes at the
  first read boundary at or after S symbols. Symbols are coded with
  sm_model (256 symbols) + rc_cram, one fresh model array and coder
  per segment.
- [ ] **Step 2: Commit** — `docs: M94.Z V6 wire format`

### Task P1.2: single-chain coder

**Files:**
- Create: `native/src/m94z_v6.c`, `native/src/m94z_v6.h`
- Create: `native/tests/test_m94z_v6_chain.c`
- Modify: `native/CMakeLists.txt` (add m94z_v6.c to the ttio_rans
  sources next to fqzcomp_seqctx.c; add the test executable following
  the test_m94z_qual_umbrella block at lines 188-191)

**Interfaces:**
- Consumes: `sm_model.h` (sm_init(&m, 256, 256)/sm_encode/sm_decode/
  sm_destroy), `rc_cram.h` (rc_cram_encoder_init/rc_cram_encode/
  rc_cram_encoder_finish and decoder counterparts) — the same calls
  fqzcomp_seqctx.c makes.
- Produces:

```c
typedef struct {
    uint8_t qbits, qshift, pbits, pshift, dbits;
} ttio_v6_param;
extern const ttio_v6_param TTIO_V6_DEFAULT;   /* fixed in P1.5 */

/* One segment = whole reads. lengths/n_reads describe ONLY this
 * segment's reads; qual holds sum(lengths) bytes. Returns 0 or a
 * TTIO_SEQCTX_ERR_* value. *out_len in: capacity, out: bytes. */
int ttio_v6_chain_encode(const ttio_v6_param *pm,
                         const uint8_t *qual,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len);
int ttio_v6_chain_decode(const ttio_v6_param *pm,
                         const uint8_t *in, size_t in_len,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *qual_out, size_t n_qualities);
```

- [ ] **Step 1: Write the failing test** (same CHECK harness as
  test_m94z_qual_umbrella.c): build a 2000-read x 100 corpus with the
  motif generator (copy make_corpus from that file), encode one chain
  with TTIO_V6_DEFAULT, decode, CHECK round-trip equality; CHECK a
  second encode of the same input is byte-identical; CHECK an
  undersized out buffer returns nonzero; CHECK param validation
  rejects Q+P+D > 16.
- [ ] **Step 2: Build and run** `cmake --build native/_build --target
  test_m94z_v6_chain -j && native/_build/test_m94z_v6_chain` —
  expected: compile failure (missing files).
- [ ] **Step 3: Implement** m94z_v6.c: code_pass shaped exactly like
  fqzcomp_seqctx.c's but with the P1.1 context word (track q_prev,
  q_prev2 per read for the delta bucket; reset qctx/q_prev at read
  start). Allocate sm_model[1 << (Q+P+D)]; encode loop calls
  sm_encode, decode loop sm_decode; rc_cram_encoder_finish sets
  *out_len. Param validation: Q+P+D <= 16, qshift <= 8.
- [ ] **Step 4: Run to green**, plus the neighbour binaries
  (test_m94z_qual_umbrella, test_fqzcomp_qual_threaded) to prove no
  regression.
- [ ] **Step 5: Commit** — `kernel: V6 single-chain qualities coder`

### Task P1.3: segmented block encode/decode

**Files:**
- Modify: `native/src/m94z_v6.c` / `m94z_v6.h`
- Create: `native/tests/test_m94z_v6_block.c` (+ CMake entry)

**Interfaces:**
- Consumes: P1.2 chain functions; `m94z_v4_wire.h` pack helpers
  (ttio_m94z_v5_pack's shape — add a v6 pack/unpack pair alongside,
  same m94z_pack_any core with version byte 6 and flags 0x02).
- Produces:

```c
/* Whole-block API the umbrella calls. threads <= 1 = sequential;
 * output bytes are independent of threads. */
int ttio_m94z_v6_encode(const uint8_t *qual, size_t n_qualities,
                        const uint32_t *read_lengths, size_t n_reads,
                        const ttio_v6_param *pm, uint32_t seg_symbols,
                        int threads, uint8_t *out, size_t *out_len);
int ttio_m94z_v6_decode(const uint8_t *in, size_t in_len,
                        uint32_t *read_lengths, size_t n_reads,
                        int threads, uint8_t *qual_out,
                        size_t n_qualities);

/* Provisional until P1.5 fixes it from the ratio sweep. */
#define TTIO_V6_DEFAULT_SEG_SYMBOLS (256u * 1024u)
```

- [ ] **Step 1: Write the failing test**: 30000 reads x 100 (3 MB, ~12
  segments at S = 256 Ki), encode with threads=1 and threads=8, CHECK
  byte-identical; decode with threads=1 and threads=8, CHECK
  round-trip; CHECK version byte out[4] == 6; CHECK a single-read
  block and an empty-ish block (1 read of length 1) round-trip; CHECK
  segment boundaries land on read boundaries by decoding with
  deliberately wrong n_reads and expecting an error.
- [ ] **Step 2: Run — compile failure expected.**
- [ ] **Step 3: Implement**: split reads greedily (close a segment at
  the first read boundary >= S symbols); write the P1.1 body header +
  seg_len table; encode segments on a pthread worker array (spawn
  min(threads, N), each pulls the next segment index from an atomic
  counter, writes into a per-segment scratch buffer; the main thread
  concatenates in order — assembly order fixes byte determinism).
  Decode mirrors it (seg_len table gives each worker its input span;
  output spans are disjoint so workers write in place). Wrap in the
  outer container via the new v6 pack/unpack.
- [ ] **Step 4: Run to green.**
- [ ] **Step 5: Commit** — `kernel: V6 segmented block coder`

### Task P1.4: umbrella + sniffer integration (hint 8)

**Files:**
- Modify: `native/include/ttio_rans.h` (next to TTIO_M94Z_HINT_V4_AUTO)
- Modify: `native/src/m94z_qual.c` (ttio_m94z_qual_encode /
  ttio_m94z_qual_decode)
- Modify: `native/src/m94z_v4_wire.c`
  (ttio_m94z_qual_stream_strategy)
- Modify: `native/tests/test_m94z_qual_umbrella.c`

**Interfaces:**
- Produces: `#define TTIO_M94Z_HINT_V6 8`; hint 8 through
  ttio_m94z_qual_encode emits a V6 stream (threads from the existing
  autotune knob); ttio_m94z_qual_decode dispatches version byte 6;
  ttio_m94z_qual_stream_strategy returns 8 for version byte 6. Auto
  (-1) NEVER selects V6 (spec 3.4: engine-driven, not size-driven).

- [ ] **Step 1: Failing umbrella tests**: hint 8 encode -> out[4] == 6,
  round-trips through ttio_m94z_qual_decode, sniffer returns 8;
  hint -1 output unchanged (regression check: hint -1 without
  sequences still equals the direct ttio_m94z_v4_encode bytes, the
  existing umbrella assertion); sniffer on a truncated V6 header
  returns negative.
- [ ] **Step 2: Run — failures expected. Step 3: Implement.** In
  qual_encode, before the 5/6 branch:

```c
    if (strategy_hint == TTIO_M94Z_HINT_V6) {
        return ttio_m94z_v6_encode(qual_in, n_qualities, read_lengths,
                                   n_reads, &TTIO_V6_DEFAULT,
                                   TTIO_V6_DEFAULT_SEG_SYMBOLS,
                                   ttio_m94z_get_autotune_threads(),
                                   out, out_len);
    }
```

  In qual_decode, before the V5 check: `if (in[4] == 6) return
  ttio_m94z_v6_decode(...)`. In the sniffer: `if (in[4] == 6) return
  8;`.
- [ ] **Step 4: Green + neighbours. Step 5: Commit** —
  `kernel: V6 through the qualities umbrella`

### Task P1.5: constants tuning and the ratio gate

**Files:**
- Create: `native/bench/bench_v6_ratio.c` (+ CMake entry, not a test)
- Modify: `native/src/m94z_v6.c` (final TTIO_V6_DEFAULT and
  TTIO_V6_DEFAULT_SEG_SYMBOLS)
- Modify: `docs/codecs/m94z_v6.md` (record measured ratios)

**Interfaces:**
- Consumes: raw quality+length dumps produced with the existing python
  tooling (fq.decode of blocks from the reference .tio files, or
  direct FASTQ slices).
- Produces: fixed default constants and a recorded ratio table.

- [ ] **Step 1: Build the corpus samples** (~256 MB each, one per
  class) from the standard corpora: HiFi /tmp/smoke.fastq; NovaSeq and
  2x250 and lowcov from ttio-bench-data/prepared BAMs via the python
  SDK (read qualities+lengths, write flat .bin + .lens files to
  /home/toddw/v6tune/). The lowcov class must be included — V5 wins
  there today and V6 must stay within 2% of V5's size, not V4's.
- [ ] **Step 2: Write the bench** — bench_v6_ratio in.bin in.lens:
  encodes the sample with hint -1 (today's best) and with a sweep
  {Q in 8..12} x {D in 0..3} x {P in 4..6} x {S in 128Ki, 256Ki,
  512Ki}, subject to Q+P+D <= 16 and the 512 MB model envelope at
  N = ceil(block/S); prints a CSV: params, size, delta% vs today.
- [ ] **Step 3: Run on the four classes**, pick the smallest default
  meeting <= 2% (target <= 1%) on the WORST class; record the full
  table in docs/codecs/m94z_v6.md and set TTIO_V6_DEFAULT /
  TTIO_V6_DEFAULT_SEG_SYMBOLS. If no point meets 2% on some class,
  STOP and report to Todd with the table (spec gate; the likely knobs
  are a per-class parameter choice or a bigger model — his call).
- [ ] **Step 4: Re-run all P1.2-P1.4 tests with the final constants.**
- [ ] **Step 5: Commit** — `kernel: V6 default parameters from the
  ratio sweep`

### Task P1.6: Python plumbing

**Files:**
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`
- Modify: `python/tests/test_qualities_v5.py` (the V6 tests live next
  to the V5 ones)

**Interfaces:**
- Consumes: existing encode(v4_strategy_hint=)/decode_with_metadata/
  stream_strategy plumbing (hint passes through unchanged).
- Produces: `HINT_V6 = 8`; docstrings mention 8; decode of a V6 blob
  works with NO sequences argument (V6 needs none).

- [ ] **Step 1: Failing tests**:

```python
def test_v6_round_trips_and_sniffs():
    qual, _seq, lens, flags = _motif_corpus(n_reads=2000)
    blob = fz.encode(qual, lens, flags, v4_strategy_hint=fz.HINT_V6)
    assert blob[4] == 6
    assert fz.stream_strategy(blob) == 8
    back, back_lens, _rc = fz.decode_with_metadata(blob, flags)
    assert bytes(back) == qual and list(back_lens) == lens

def test_auto_never_picks_v6():
    qual, seq, lens, flags = _motif_corpus()
    assert fz.encode(qual, lens, flags, sequences=seq)[4] in (4, 5)
```

- [ ] **Step 2: Run — expect AttributeError (HINT_V6).**
- [ ] **Step 3: Implement**: `HINT_V6 = 8` beside HINT_V4_AUTO; extend
  the two docstrings; verify decode_with_metadata's version dispatch
  reaches the kernel qual_decode for version 6 (it dispatches V5 by
  byte — follow that path and add 6 to whatever gate exists; V6 must
  NOT demand a sequences provider).
- [ ] **Step 4: Rebuild native lib, run the file. Step 5: Commit** —
  `python: V6 hint and decode dispatch`

### Task P1.7: Java plumbing

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
- Modify: `java/src/test/java/global/thalion/ttio/codecs/QualitiesV5Test.java`

**Interfaces:**
- Produces: `FqzcompNx16Z.HINT_V6 = 8`; decode() of a version-6 stream
  works without a sequences supplier; streamStrategy returns 8.

- [ ] **Step 1: Failing test** (in QualitiesV5Test, motifCorpus
  helpers):

```java
@Test
void v6RoundTripsAndSniffs() {
    byte[][] c = motifCorpus(2000, 100);
    int[] lens = fill(2000, 100), flags = fill(2000, 0);
    byte[] v6 = FqzcompNx16Z.encode(c[0], lens, flags,
        new FqzcompNx16Z.EncodeOptions().v4StrategyHint(FqzcompNx16Z.HINT_V6));
    assertEquals(6, v6[4]);
    assertEquals(8, FqzcompNx16Z.streamStrategy(v6));
    FqzcompNx16Z.DecodeResult dr = FqzcompNx16Z.decode(v6, flags, null);
    assertArrayEquals(c[0], dr.qualities());
}
```

- [ ] **Step 2: mvn -Dtest=QualitiesV5Test — compile failure.**
- [ ] **Step 3: Implement**: the constant; check decode()'s version-5
  gate (it throws when byte 5 has no supplier — version 6 must pass
  straight to the native decode, seq NULL). Rebuild
  native/_build (JNI lib picks up the kernel change automatically —
  no new JNI function needed).
- [ ] **Step 4: Green. Step 5: Commit** — `java: V6 hint and decode
  dispatch`

### Task P1.8: ObjC plumbing

**Files:**
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.h` / `.m`
- Modify: `objc/Tests/TestQualitiesV5.m`

**Interfaces:**
- Produces: `TTIOM94ZHintV6` (8) beside TTIOM94ZHintV4Auto;
  decodeData:revcompFlags:error: handles version 6 without sequences;
  strategyOfEncodedStream: returns 8 for version byte 6 in BOTH the
  native call and the non-native fallback parser.

- [ ] **Step 1: Failing tests** in testQualitiesV5 (motif corpus
  already there): encodeQualWithQualities hint TTIOM94ZHintV6 ->
  bytes[4] == 6, strategyOfEncodedStream == 8, decodeData round-trips
  without a sequences provider; fallback-parse branch covered by the
  same call on native builds (the #else parser edit is code-reviewed,
  exercised on non-native CI).
- [ ] **Step 2: Rebuild (touch UNC-edited files first), run TTIOTests,
  see failures. Step 3: Implement** (the #else fallback in
  strategyOfEncodedStream gains `if (in[4] == 6) return 8;` before
  the version-5 check; check the decode path's V5 sequences gate skips
  version 6).
- [ ] **Step 4: Full capped gate green (bash
  /home/toddw/bp_objc_capped.sh; baseline 4991 tests, expect +new).
  Step 5: Commit** — `objc: V6 hint and decode dispatch`

### Task P1.9: cross-SDK golden, gates, CHANGELOG, PR

**Files:**
- Create: `python/tests/fixtures/codecs/qualities_v6_golden.bin`
  (+ .lens sidecar) via a small generator run
- Modify: `python/tests/test_qualities_v5.py`,
  `java/.../QualitiesV5Test.java`, `objc/Tests/TestQualitiesV5.m`
  (one golden-decode test each, mirroring the existing V5 golden
  tests in the same files)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Generate the golden** with the Python binding
  (motif-corpus 300 reads, fixed seed, TTIO_V6_DEFAULT), commit the
  fixture to the SAME fixture directories the V5 goldens use (python
  tests/fixtures/codecs/ and the ObjC/Java fixture paths referenced by
  their existing golden tests).
- [ ] **Step 2: One golden-decode test per SDK** asserting identical
  decoded bytes — this pins the wire across SDKs and future edits.
- [ ] **Step 3: Full gates**: python full suite, java mvn -q test,
  ObjC capped gate, native binaries (v6_chain, v6_block, umbrella,
  autotune, threaded) in native/_build.
- [ ] **Step 4: CHANGELOG** Unreleased/Added: the V6 wire variant,
  hint 8, thread-count-independent bytes, measured ratio deltas, and
  that auto never selects it (GPU engine arrives in Phase 2).
- [ ] **Step 5: Commit, push via Windows git from PowerShell
  (`git -C "\\wsl.localhost\Ubuntu\home\toddw\TTI-O.worktrees\block-parallel"
  push -u origin gpu-engine-v6`), PR** with the 5-part <200-word body
  through the style gate (pass --body-file an /mnt/c/... path — the
  gate hook reads it from the Windows side), then the live audit:
  WSL `grep -c` for attribution strings and bold over the fetched live
  body and every pushed commit message, and verify each number quoted
  in the body against the P1.5 table.

## Self-review notes

- Spec coverage: sections 3.1-3.2 (P1.1-P1.3, P1.5), 3.4 hint 8 +
  sniffer + auto-never-V6 (P1.4, tested in P1.6), section 7 SDK
  surface (P1.6-P1.8), section 8 gates: byte determinism across
  threads (P1.3), ratio (P1.5), cross-SDK (P1.9); section 5 dev-loop
  note and section 8 throughput projection (P0.1-P0.2). Engine API,
  scheduler, writer pin, TTIO_GPU knobs are Phase 2 by design and
  absent here on purpose.
- Sequences segmentation (spec 3.3) is Phase 3; not in this plan.
- P1.5 has an explicit STOP path if the ratio gate cannot be met —
  that is a spec decision point, not a plan gap.
