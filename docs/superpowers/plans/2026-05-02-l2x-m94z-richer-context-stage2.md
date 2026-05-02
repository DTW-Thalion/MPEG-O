# L2.X — M94.Z V4 (CRAM 3.1 fqzcomp port) — Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace M94.Z V3's bit-pack context model with a byte-compatible port of CRAM 3.1 `fqzcomp_qual` into our own native C, give Python access via the existing M94.Z dispatch, and validate byte-equality against `htscodecs` reference across all 4 Stage 1 corpora.

**Architecture:** Native C port of `htscodecs/fqzcomp_qual.c` lives in `native/src/{rc_cram,fqzcomp_qual,m94z_v4_wire}.{c,h}`. Our V4 outer wire format wraps a CRAM-byte-compatible inner body. `htscodecs` is vendored under `tools/perf/htscodecs/` for **test-time only** — `libttio_rans` does not link it at runtime. Python ctypes wrapper extends `python/src/ttio/codecs/fqzcomp_nx16_z.py` with `_encode_v4_native` / `_decode_v4_via_native` and makes V4 the default when `_HAVE_NATIVE_LIB`.

**Tech Stack:** C11 (no new compiler reqs), CMake (existing `native/CMakeLists.txt`), Python 3.12 + numpy + ctypes, htscodecs (BSD-3, test-time only), pytest. WSL Ubuntu environment, build artifacts in `native/_build/`.

**Spec:** `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage2-design.md` (HEAD `5b84553`) is the source of truth. Phasing, gates, and acceptance criteria come from the spec; this plan defines the discrete tasks.

**Phasing recap (per spec §5):** P0 PacBio HiFi sanity check → P1 RC primitives → P2 fixed-strategy context model → P3 auto-tuning + 5 presets → P4 V4 wire format + Python wrapper → P5 cross-corpus validation + spec/docs/WORKPLAN. Each phase has a byte-equality gate against `htscodecs` reference.

---

## File Structure

**New files:**

- `tools/perf/htscodecs/` — vendored htscodecs source (test-time only; gitignored after CMake build)
- `tools/perf/htscodecs_compare.sh` — helper script wrapping htscodecs CLI for byte-equality testing
- `native/src/rc_cram.c` — Subbotin Range Coder primitives byte-compatible with CRAM 3.1
- `native/src/rc_cram.h` — public RC API header
- `native/src/fqzcomp_qual.c` — CRAM 3.1 fqzcomp_qual port (encode + decode + auto-tune + 5 presets)
- `native/src/fqzcomp_qual.h` — public fqzcomp_qual API header
- `native/src/m94z_v4_wire.c` — M94.Z V4 outer-header pack/unpack
- `native/src/m94z_v4_wire.h` — public V4 wire-format API
- `native/tests/test_rc_cram_byte_equal.c` — Phase 1 RC byte-equality gate
- `native/tests/test_fqzcomp_qual_strategy1.c` — Phase 2 fixed-strategy gate
- `native/tests/test_fqzcomp_qual_autotune.c` — Phase 3 auto-tuning gate
- `python/tests/test_m94z_v4_dispatch.py` — Python V4 dispatch tests (~10 tests)
- `python/tests/integration/test_m94z_v4_byte_exact.py` — Python cross-corpus byte-equality (gated on htscodecs availability)
- `docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md` — final per-corpus B/qual + byte-equality status

**Modified files:**

- `native/include/ttio_rans.h` — add V4 entry points (`ttio_m94z_v4_encode`, `ttio_m94z_v4_decode`, `ttio_fqzcomp_qual_compress`, `ttio_fqzcomp_qual_uncompress`)
- `native/CMakeLists.txt` — register new sources + new test executables
- `python/src/ttio/codecs/fqzcomp_nx16_z.py` — add V4 ctypes bindings, `_encode_v4_native` / `_decode_v4_via_native`, V4 dispatch in `encode()` / `decode_with_metadata()`
- `python/tests/test_m94z_v3_dispatch.py` — V3 default tests become explicit `prefer_v4=False`
- `docs/codecs/fqzcomp_nx16_z.md` — document V4 wire format + auto-tune mechanism
- `WORKPLAN.md` — Task #84 Stage 2 outcome
- `.gitignore` — add `tools/perf/htscodecs/` (test-time only, not committed)

**Reused (read-only):**

- `data/genomic/na12878/na12878.chr22.lean.mapped.bam` — chr22 corpus
- `data/genomic/na12878_wes/na12878_wes.chr22.bam` — WES corpus
- `data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam` — HG002 Illumina 2×250 corpus (1M-read subset)
- `data/genomic/hg002_pacbio/hg002_pacbio.subset.bam` — HG002 PacBio HiFi corpus
- `python/src/ttio/importers/bam.py` — `BamReader.to_genomic_run` for corpus loading

**Operational notes (cooked into every shell command in this plan):**

- All shell via `wsl -d Ubuntu -- bash -c '...'` from this Windows-side environment.
- All paths absolute (`/home/toddw/TTI-O/...`); `$PWD` does NOT survive nested wsl-bash-c invocations (per `feedback_pwd_mangling_in_nested_wsl`).
- After every Edit/Write through `\\wsl.localhost\Ubuntu\...` paths, strip CRLF: `sed -i $'s/\r$//' <file>`; verify `tr -cd $'\r' < <file> | wc -c` returns `0` (per `feedback_crlf_on_wsl_clones`).
- All commits via `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...` (per `feedback_git_commit_identity_msys`).
- Push only when explicitly requested or in Phase 5; via Windows git per `feedback_git_push_via_windows`: `"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push origin main`.

---

## Phase 0 — htscodecs PacBio HiFi sanity check

### Task 1: Build htscodecs at `tools/perf/htscodecs/`, run on PacBio HiFi, document outcome

**Files:**
- Create: `tools/perf/htscodecs/` (cloned, not committed; gitignored)
- Modify: `.gitignore` (add `tools/perf/htscodecs/`)
- Run: `tools/perf/htscodecs/tests/fqzcomp_qual` against PacBio HiFi corpus

- [ ] **Step 1: Add htscodecs to `.gitignore`**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && grep -q "^tools/perf/htscodecs/$" .gitignore || echo "tools/perf/htscodecs/" >> .gitignore && tail -5 .gitignore'
```

Expected: `.gitignore` ends with `tools/perf/htscodecs/`. (If already present, no-op.)

- [ ] **Step 2: Clone htscodecs**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/tools/perf && git clone --depth 1 https://github.com/samtools/htscodecs.git htscodecs && cd htscodecs && git log -1 --format="%H %ci" '
```

Expected: a single-commit HEAD with a commit hash. Note the SHA — record it in the eventual results doc for reproducibility.

- [ ] **Step 3: Build htscodecs (autotools)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/tools/perf/htscodecs && autoreconf -i && ./configure && make -j4 2>&1 | tail -10'
```

Expected: build completes without errors. The test harness binary is at `tools/perf/htscodecs/tests/fqzcomp_qual` after build.

If `autoreconf` is missing, install via `sudo apt-get install autoconf automake libtool` (one-time; document in the eventual results doc if user-side action is needed).

- [ ] **Step 4: Verify the test harness runs**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/tools/perf/htscodecs && ls -la tests/fqzcomp_qual && ./tests/fqzcomp_qual 2>&1 | head -5'
```

Expected: `fqzcomp_qual` binary exists and prints usage when called with no args.

- [ ] **Step 5: Run htscodecs on PacBio HiFi qualities**

The test harness reads a flat qualities file (one Q-byte per byte). Extract qualities from the PacBio HiFi BAM and pipe to htscodecs:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && samtools view /home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam | awk -F$"\t" "{printf \"%s\", \$11}" > /tmp/pacbio_qual.bin && ls -la /tmp/pacbio_qual.bin'
```

Expected: `/tmp/pacbio_qual.bin` is ~264 MB (264,190,341 bytes — matches BamReader's reported n_qualities).

- [ ] **Step 6: Encode with htscodecs and report B/qual**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/tools/perf/htscodecs && ./tests/fqzcomp_qual /tmp/pacbio_qual.bin /tmp/pacbio_qual.fqz 2>&1 | tail -5 && ls -la /tmp/pacbio_qual.fqz && echo "B/qual = $(stat -c%s /tmp/pacbio_qual.fqz) / 264190341 = $(echo "scale=4; $(stat -c%s /tmp/pacbio_qual.fqz) / 264190341" | bc)"'
```

Expected: htscodecs prints encode time + compressed size; the bash echo prints B/qual in bytes.

- [ ] **Step 7: Apply the decision rule**

Per spec §5 Phase 0:
- If htscodecs B/qual ≤ 0.32 → **auto-tune saves PacBio**; the port is expected to land sub-0.32 on PacBio HiFi. Proceed to Phase 1.
- If htscodecs B/qual ≈ 0.42 → PacBio is platform-hard regardless. Document in the eventual Phase 5 results doc as a known limitation; **proceed to Phase 1 anyway** because Stage 1 already showed all other corpora benefit from the port.

- [ ] **Step 8: Record the outcome**

Create a temporary file `/tmp/p0_outcome.md` recording:
- htscodecs commit SHA
- PacBio HiFi B/qual (your measurement)
- Decision rule outcome (proceed-as-planned vs proceed-with-known-limitation)
- Date

This file is consumed by Phase 5's results doc; don't commit it yet.

```bash
wsl -d Ubuntu -- bash -c 'cat > /tmp/p0_outcome.md << "EOF"
# Phase 0 outcome
- htscodecs SHA: <FILL FROM STEP 2>
- PacBio HiFi corpus: /home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam (14,284 reads, 264,190,341 qualities)
- htscodecs compressed bytes: <FILL FROM STEP 6>
- htscodecs B/qual: <FILL FROM STEP 6>
- Decision: <PROCEED-AS-PLANNED | PROCEED-WITH-KNOWN-LIMITATION>
- Date: 2026-05-02
EOF'
```

Replace the `<FILL...>` placeholders with the actual values from Steps 2 and 6.

- [ ] **Step 9: Commit the .gitignore change**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add .gitignore && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "chore: gitignore tools/perf/htscodecs (Stage 2 P0 test-time dep)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

Expected: one-line commit with the .gitignore update only.

---

## Phase 1 — RC primitives byte-equal htscodecs

### Task 2: Vendor RC primitives header + skeleton implementation

**Files:**
- Create: `native/src/rc_cram.h` — public RC API header
- Create: `native/src/rc_cram.c` — empty skeleton with stubs

The CRAM 3.1 fqzcomp Range Coder is a 32-bit Subbotin RC. The byte-pairing algorithm is the same as our existing V3 RC (see `native/src/rans_encode_adaptive.c`), but the specific state initialization, lane handling, and renorm threshold differ. We start by defining the public API; implementation follows in Tasks 3-4.

- [ ] **Step 1: Write `native/src/rc_cram.h` with the public API**

```c
/* native/src/rc_cram.h
 *
 * CRAM 3.1 fqzcomp Range Coder primitives. Byte-compatible with
 * the embedded RC inside htscodecs/fqzcomp_qual.c.
 *
 * This is NOT shared with V3's adaptive RC kernel
 * (rans_encode_adaptive.c); CRAM's RC has subtle differences
 * (state init, renorm threshold, end-of-stream handling) that
 * make a unified primitive infeasible without breaking V3 byte
 * compatibility.
 */
#ifndef TTIO_RC_CRAM_H
#define TTIO_RC_CRAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Encoder state. Caller-allocates; opaque. */
typedef struct rc_cram_encoder {
    uint32_t low;
    uint32_t range;
    uint32_t carry;
    uint8_t  *out;          /* output buffer (caller-owned) */
    size_t    out_pos;      /* next write position */
    size_t    out_cap;      /* output buffer capacity */
    int       err;          /* 0 = OK; negative = error */
} rc_cram_encoder;

/* Decoder state. Caller-allocates; opaque. */
typedef struct rc_cram_decoder {
    uint32_t low;
    uint32_t range;
    uint32_t code;
    const uint8_t *in;
    size_t    in_pos;
    size_t    in_len;
    int       err;
} rc_cram_decoder;

/* Initialise encoder. out_cap must be >= input_size + slack. */
void rc_cram_encoder_init(rc_cram_encoder *e, uint8_t *out, size_t out_cap);

/* Initialise decoder by reading the first 5 bytes from `in`. */
void rc_cram_decoder_init(rc_cram_decoder *d, const uint8_t *in, size_t in_len);

/* Encode one symbol given its cumulative-frequency interval [cf, cf+f)
 * and the total frequency T. */
void rc_cram_encode(rc_cram_encoder *e, uint32_t cf, uint32_t f, uint32_t T);

/* Decode the next symbol. Caller maintains the freq table; this returns
 * the cumulative-frequency value to look up in the table. */
uint32_t rc_cram_decode_target(rc_cram_decoder *d, uint32_t T);

/* After decoding the symbol from the freq table, call this with the
 * decoded symbol's [cf, cf+f) to advance the decoder. */
void rc_cram_decode_advance(rc_cram_decoder *d, uint32_t cf, uint32_t f, uint32_t T);

/* Flush the encoder to produce the final byte stream. Returns the
 * number of bytes written. */
size_t rc_cram_encoder_finish(rc_cram_encoder *e);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_RC_CRAM_H */
```

- [ ] **Step 2: Write `native/src/rc_cram.c` skeleton with stubs**

```c
/* native/src/rc_cram.c
 *
 * CRAM 3.1 fqzcomp Range Coder primitives. See rc_cram.h.
 *
 * Implementation mirrors the embedded RC inside
 * htscodecs/fqzcomp_qual.c (functions RC_StartEncode, RC_FinishEncode,
 * RC_StartDecode, RC_GetFreq, RC_Decode, RC_Encode in the htscodecs
 * source). Byte-equality with htscodecs is enforced by
 * test_rc_cram_byte_equal.c (Phase 1 gate).
 */
#include "rc_cram.h"
#include <string.h>

#define TOP    (1u << 24)
#define BOTTOM (1u << 16)

void rc_cram_encoder_init(rc_cram_encoder *e, uint8_t *out, size_t out_cap) {
    e->low = 0;
    e->range = 0xFFFFFFFFu;
    e->carry = 0;
    e->out = out;
    e->out_pos = 0;
    e->out_cap = out_cap;
    e->err = 0;
}

void rc_cram_decoder_init(rc_cram_decoder *d, const uint8_t *in, size_t in_len) {
    /* Read first 5 bytes. */
    d->in = in;
    d->in_len = in_len;
    d->in_pos = 0;
    d->low = 0;
    d->range = 0xFFFFFFFFu;
    d->code = 0;
    d->err = 0;
    if (in_len < 5) { d->err = -1; return; }
    /* htscodecs reads first byte separately, then 4 more for code */
    d->code = ((uint32_t)in[1] << 24)
            | ((uint32_t)in[2] << 16)
            | ((uint32_t)in[3] <<  8)
            | ((uint32_t)in[4]);
    d->in_pos = 5;
}

void rc_cram_encode(rc_cram_encoder *e, uint32_t cf, uint32_t f, uint32_t T) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_Encode */
    (void)e; (void)cf; (void)f; (void)T;
}

uint32_t rc_cram_decode_target(rc_cram_decoder *d, uint32_t T) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_GetFreq */
    (void)d; (void)T;
    return 0;
}

void rc_cram_decode_advance(rc_cram_decoder *d, uint32_t cf, uint32_t f, uint32_t T) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_Decode */
    (void)d; (void)cf; (void)f; (void)T;
}

size_t rc_cram_encoder_finish(rc_cram_encoder *e) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_FinishEncode */
    return e->out_pos;
}
```

- [ ] **Step 3: Strip CRLF on both files**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/src/rc_cram.c native/src/rc_cram.h && tr -cd $"\r" < native/src/rc_cram.c | wc -c && tr -cd $"\r" < native/src/rc_cram.h | wc -c'
```

Expected: two `0` lines.

- [ ] **Step 4: Register in CMakeLists.txt**

Read `native/CMakeLists.txt`. Find the line listing `rans_encode_adaptive.c` and `rans_decode_adaptive.c`. Add `src/rc_cram.c` to the same source list (look for `add_library` or `set(LIB_SOURCES ...)` or similar).

After adding, rebuild:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake --build . 2>&1 | tail -10'
```

Expected: build succeeds (the stubs compile without warnings; unused-parameter warnings for the `(void)` casts are silenced).

- [ ] **Step 5: Commit the skeleton**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/rc_cram.h native/src/rc_cram.c native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "scaffold(L2.X V4): rc_cram.{h,c} skeleton for CRAM 3.1 RC primitives

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 3: Implement RC encode + decode bodies

**Files:**
- Modify: `native/src/rc_cram.c` — replace TODO stubs with the algorithm

This is the byte-pairing math. Reference: `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c` — search for `RC_Encode`, `RC_Decode`, `RC_FinishEncode`, `RC_GetFreq`. Port verbatim, preserving variable names where possible.

- [ ] **Step 1: Implement `rc_cram_encode` (matches htscodecs `RC_Encode`)**

In `native/src/rc_cram.c`, replace the body of `rc_cram_encode`:

```c
void rc_cram_encode(rc_cram_encoder *e, uint32_t cf, uint32_t f, uint32_t T) {
    if (e->err) return;
    uint32_t r = e->range / T;
    e->low += cf * r;
    e->range = f * r;
    /* Renormalise: while range < 2^16, output bytes */
    while (e->range < BOTTOM) {
        if (e->out_pos >= e->out_cap) { e->err = -1; return; }
        e->out[e->out_pos++] = (uint8_t)(e->low >> 24);
        e->range <<= 8;
        e->low   <<= 8;
    }
}
```

Note: this is the canonical 32-bit Subbotin RC encode step. If the byte-equality test fails in Step 6, the issue is most likely (a) renorm threshold (BOTTOM = 1<<16 vs 1<<23), (b) byte order in the output, or (c) state-init values. Read `htscodecs/fqzcomp_qual.c` lines around `RC_Encode` carefully and align.

- [ ] **Step 2: Implement `rc_cram_decode_target` (matches `RC_GetFreq`)**

```c
uint32_t rc_cram_decode_target(rc_cram_decoder *d, uint32_t T) {
    if (d->err) return 0;
    uint32_t r = d->range / T;
    return (d->code - d->low) / r;
}
```

- [ ] **Step 3: Implement `rc_cram_decode_advance` (matches `RC_Decode`)**

```c
void rc_cram_decode_advance(rc_cram_decoder *d, uint32_t cf, uint32_t f, uint32_t T) {
    if (d->err) return;
    uint32_t r = d->range / T;
    d->low += cf * r;
    d->range = f * r;
    while (d->range < BOTTOM) {
        if (d->in_pos >= d->in_len) { d->err = -1; return; }
        d->code = (d->code << 8) | d->in[d->in_pos++];
        d->range <<= 8;
        d->low   <<= 8;
    }
}
```

- [ ] **Step 4: Implement `rc_cram_encoder_finish` (matches `RC_FinishEncode`)**

```c
size_t rc_cram_encoder_finish(rc_cram_encoder *e) {
    if (e->err) return 0;
    /* Flush the final 5 bytes of state. htscodecs writes 5 bytes
     * because the encode loop's renorm condition is range < 2^16
     * which leaves up to 5 bytes of state to flush. */
    for (int i = 0; i < 5; i++) {
        if (e->out_pos >= e->out_cap) { e->err = -1; return 0; }
        e->out[e->out_pos++] = (uint8_t)(e->low >> 24);
        e->low <<= 8;
    }
    return e->out_pos;
}
```

- [ ] **Step 5: Strip CRLF + rebuild**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/src/rc_cram.c && tr -cd $"\r" < native/src/rc_cram.c | wc -c && cd native/_build && cmake --build . 2>&1 | tail -5'
```

Expected: `0` CRs and a clean rebuild.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/rc_cram.c && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(L2.X V4): rc_cram encode/decode primitives matching htscodecs

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 4: Phase 1 byte-equality test (RC primitives via degenerate fqzcomp_qual config)

**Files:**
- Create: `native/tests/test_rc_cram_byte_equal.c`
- Modify: `native/CMakeLists.txt` (add the test executable)

The cleanest way to test our RC byte-equality with htscodecs is to call htscodecs's full `fqzcomp_qual_compress` with all context dimensions zeroed (qbits=0, pbits=0, dbits=0, no selector). In that mode the codec is just RC + a single global freq table — i.e., a pure RC byte-equality test.

- [ ] **Step 1: Write the test**

```c
/* native/tests/test_rc_cram_byte_equal.c
 *
 * Phase 1 gate: rc_cram primitives produce byte-equal output to
 * htscodecs's embedded RC when both run in degenerate-context
 * config (qbits=0, pbits=0, dbits=0).
 *
 * This test does NOT call htscodecs at runtime. Instead it
 * compares against pre-generated reference bytes captured at
 * test-build time from htscodecs's CLI on a fixed synthetic input.
 * The reference bytes are committed alongside the test and live
 * at native/tests/fixtures/rc_cram_flat_freq_1M.bin.
 */
#include "rc_cram.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 1 M random uint8 with a fixed seed for determinism. */
static void make_synthetic_input(uint8_t *buf, size_t n, uint32_t seed) {
    uint32_t s = seed;
    for (size_t i = 0; i < n; i++) {
        /* Simple LCG for determinism */
        s = s * 1103515245u + 12345u;
        buf[i] = (uint8_t)(s >> 16);
    }
}

/* Encode one symbol stream against a flat freq table T=256, each
 * symbol freq=1. Cumulative freq for symbol s is just s. */
static size_t rc_encode_flat(const uint8_t *syms, size_t n, uint8_t *out, size_t out_cap) {
    rc_cram_encoder e;
    rc_cram_encoder_init(&e, out, out_cap);
    for (size_t i = 0; i < n; i++) {
        rc_cram_encode(&e, syms[i], 1, 256);
    }
    return rc_cram_encoder_finish(&e);
}

/* Decode round-trip: ensure our encoder + decoder agree internally. */
static int rc_decode_flat_check(const uint8_t *encoded, size_t enc_len,
                                 const uint8_t *expected_syms, size_t n_syms) {
    rc_cram_decoder d;
    rc_cram_decoder_init(&d, encoded, enc_len);
    for (size_t i = 0; i < n_syms; i++) {
        uint32_t target = rc_cram_decode_target(&d, 256);
        uint8_t sym = (uint8_t)target;
        if (sym != expected_syms[i]) {
            fprintf(stderr, "decode mismatch at i=%zu: got=%u expected=%u\n",
                    i, sym, expected_syms[i]);
            return 1;
        }
        rc_cram_decode_advance(&d, sym, 1, 256);
    }
    return 0;
}

int main(int argc, char **argv) {
    const size_t N = 1u << 20;  /* 1 M symbols */
    uint8_t *syms = malloc(N);
    uint8_t *enc  = malloc(N * 2 + 16);
    if (!syms || !enc) { fprintf(stderr, "OOM\n"); return 2; }

    make_synthetic_input(syms, N, 0xDEADBEEF);
    size_t enc_len = rc_encode_flat(syms, N, enc, N * 2 + 16);
    if (enc_len == 0) { fprintf(stderr, "encode failed\n"); return 3; }
    fprintf(stderr, "rc_cram encoded %zu symbols to %zu bytes\n", N, enc_len);

    /* Self-consistency: decode should recover the input */
    if (rc_decode_flat_check(enc, enc_len, syms, N) != 0) {
        fprintf(stderr, "self-consistency check FAILED\n");
        return 4;
    }
    fprintf(stderr, "rc_cram self-consistency: OK\n");

    /* Byte-equality with htscodecs reference: see helper script
     * tools/perf/htscodecs_compare.sh. This binary itself does NOT
     * link htscodecs; the comparison happens in the shell script. */
    const char *out_path = (argc > 1) ? argv[1] : "/tmp/rc_cram_flat_1M.bin";
    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot open %s\n", out_path); return 5; }
    if (fwrite(enc, 1, enc_len, f) != enc_len) { fclose(f); return 6; }
    fclose(f);
    fprintf(stderr, "wrote encoded bytes to %s\n", out_path);

    free(syms); free(enc);
    return 0;
}
```

- [ ] **Step 2: Register the test in CMakeLists.txt**

Add to `native/CMakeLists.txt` near the other `add_executable(test_*` lines:

```cmake
add_executable(test_rc_cram_byte_equal tests/test_rc_cram_byte_equal.c)
target_link_libraries(test_rc_cram_byte_equal ttio_rans)
add_test(NAME rc_cram_byte_equal COMMAND test_rc_cram_byte_equal)
```

- [ ] **Step 3: Strip CRLF + rebuild**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/tests/test_rc_cram_byte_equal.c native/CMakeLists.txt && cd native/_build && cmake .. > /dev/null && cmake --build . 2>&1 | tail -5'
```

Expected: builds cleanly; `test_rc_cram_byte_equal` binary appears.

- [ ] **Step 4: Run our test (self-consistency only at this point)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && ./test_rc_cram_byte_equal /tmp/rc_cram_ours.bin 2>&1 | tail -5 && ls -la /tmp/rc_cram_ours.bin'
```

Expected output ends with `rc_cram self-consistency: OK` and writes a `/tmp/rc_cram_ours.bin` file.

If self-consistency fails, the encoder + decoder are inconsistent — debug `rc_cram_encode` vs `rc_cram_decode_advance` carefully. They must invert each other.

- [ ] **Step 5: Generate htscodecs reference bytes**

We use htscodecs's CLI in degenerate-context mode (qbits=0, pbits=0, dbits=0) on the same synthetic input. Write a small C harness that calls htscodecs directly, since the CLI's auto-tune may interfere:

```bash
wsl -d Ubuntu -- bash -c 'cat > /tmp/htscodecs_flat_ref.c << "EOF"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fqzcomp_qual.h"

static void make_synthetic_input(unsigned char *buf, size_t n, unsigned int seed) {
    unsigned int s = seed;
    for (size_t i = 0; i < n; i++) {
        s = s * 1103515245u + 12345u;
        buf[i] = (unsigned char)(s >> 16);
    }
}

int main(int argc, char **argv) {
    const size_t N = 1u << 20;
    unsigned char *syms = malloc(N);
    make_synthetic_input(syms, N, 0xDEADBEEFu);

    /* htscodecs fqzcomp_qual_compress with degenerate config */
    fqz_param strat = {0};
    strat.context  = 0;
    strat.qbits    = 0;
    strat.pbits    = 0;
    strat.dbits    = 0;
    strat.do_qa    = 0;
    strat.do_r2    = 0;
    fqz_gparams gp = { .max_sym = 256, .nparam = 1, .p = &strat };
    /* Provide minimum side metadata: one read of length N, no flags. */
    int read_lengths[1] = { (int)N };
    int flags[1] = { 0 };
    size_t out_len = 0;
    int *lengths_arr = read_lengths; (void)lengths_arr; (void)flags;
    /* Call htscodecs - actual API may differ; consult fqzcomp_qual.h */
    fprintf(stderr, "TODO: replace with actual htscodecs call signature\n");
    /* Save to /tmp/rc_cram_htscodecs.bin */
    free(syms);
    return 0;
}
EOF
echo "wrote /tmp/htscodecs_flat_ref.c"'
```

NOTE: the actual htscodecs API for `fqzcomp_qual_compress` may differ from the stub above. The test author should:

1. Read `tools/perf/htscodecs/htscodecs/fqzcomp_qual.h` and the example test in `tools/perf/htscodecs/tests/fqzcomp_qual.c`.
2. Adapt the harness above to match the real API.
3. Compile against the htscodecs library.

```bash
# Approximate compile command after harness is written:
wsl -d Ubuntu -- bash -c 'cd /tmp && gcc -O2 -I/home/toddw/TTI-O/tools/perf/htscodecs/htscodecs htscodecs_flat_ref.c -L/home/toddw/TTI-O/tools/perf/htscodecs/htscodecs/.libs -lhtscodecs -o htscodecs_flat_ref && ./htscodecs_flat_ref && ls -la /tmp/rc_cram_htscodecs.bin'
```

- [ ] **Step 6: Compare bytes**

```bash
wsl -d Ubuntu -- bash -c 'cmp /tmp/rc_cram_ours.bin /tmp/rc_cram_htscodecs.bin && echo "BYTE-EQUAL: OK" || echo "BYTE-EQUAL: FAIL — bytes differ at $(cmp /tmp/rc_cram_ours.bin /tmp/rc_cram_htscodecs.bin 2>&1 | head -1)"'
```

Expected: `BYTE-EQUAL: OK`.

If FAIL: this is the Phase 1 gate failure. Do NOT proceed. Likely culprits:
- Renorm threshold (we use BOTTOM=2^16; htscodecs may use a different value)
- State init bytes (the first 5 bytes of htscodecs output may be a header we're not emitting)
- Byte order on `low >> 24` shifts

Diff the first 32 bytes of both outputs (`xxd /tmp/rc_cram_ours.bin | head -2` vs `xxd /tmp/rc_cram_htscodecs.bin | head -2`) and trace divergence back to the `rc_cram_*` functions.

- [ ] **Step 7: Commit on success**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/tests/test_rc_cram_byte_equal.c native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L2.X V4): rc_cram_byte_equal — Phase 1 gate vs htscodecs

Phase 1 gate: byte-equality on synthetic 1M-symbol flat-freq input.
self-consistency + htscodecs reference comparison both pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 2 — Context model with fixed strategy (HiSeq, strategy_index=1)

### Task 5: Define `fqzcomp_qual.h` public API

**Files:**
- Create: `native/src/fqzcomp_qual.h`

The public API matches CRAM 3.1 fqzcomp_qual semantics: input is the flat qualities byte stream + per-read metadata (lengths, flags); output is the compressed body (CRAM-byte-compatible) + length.

- [ ] **Step 1: Write the header**

```c
/* native/src/fqzcomp_qual.h
 *
 * CRAM 3.1 fqzcomp_qual port. Byte-compatible with
 * htscodecs/fqzcomp_qual_compress / _uncompress.
 *
 * The public API takes the flat qualities byte stream + per-read
 * metadata (read_lengths, flags) and produces a CRAM-3.1-compatible
 * compressed body. The body's per-block parameter header is encoded
 * inline (qbits/pbits/dbits/qshift/qloc/sloc/ploc/dloc/strategy_index).
 */
#ifndef TTIO_FQZCOMP_QUAL_H
#define TTIO_FQZCOMP_QUAL_H

#include <stddef.h>
#include <stdint.h>
#include "rc_cram.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Per-block parameter strategy. Mirrors htscodecs `fqz_param`. */
typedef struct ttio_fqz_param {
    uint8_t  context;     /* selector context bits */
    uint8_t  qbits;       /* quality history bits */
    uint8_t  qshift;      /* quality value shift */
    uint8_t  qloc;        /* qctx bit position in 16-bit context */
    uint8_t  pbits;       /* position bits */
    uint8_t  pshift;      /* position shift */
    uint8_t  ploc;        /* position bit position */
    uint8_t  dbits;       /* delta bits */
    uint8_t  dshift;      /* delta shift */
    uint8_t  dloc;        /* delta bit position */
    uint8_t  sbits;       /* selector bits */
    uint8_t  sloc;        /* selector bit position */
    uint8_t  do_qa;       /* quality-average split (0/1/2/4) */
    uint8_t  do_r2;       /* READ1/READ2 split (0/1) */
    uint8_t  do_dedup;    /* duplicate detection (0/1) */
    uint16_t max_sym;     /* max symbol value + 1 */
    uint8_t  qmap[256];   /* optional quality remap; identity if all 0..255 */
} ttio_fqz_param;

/* Per-block flags (encoded in the CRAM body header). */
typedef struct ttio_fqz_block_flags {
    uint8_t  has_qmap;
    uint8_t  has_selectors;
    uint8_t  fixed_strategy_index; /* 0..4, only used by encoder hint */
} ttio_fqz_block_flags;

/* Encode flat qualities to CRAM-byte-compatible body.
 *
 *   qual_in       — n_qualities bytes (Phred-33 ASCII)
 *   read_lengths  — n_reads ints, each the per-read quality length
 *   flags         — n_reads bytes; bit 4 (0x10) = SAM_REVERSE_FLAG (V3 convention)
 *   strategy_hint — -1 = auto-tune (Phase 3); 0..4 = use that preset (Phase 2 calls with 1)
 *   out, out_cap  — caller-owned output buffer
 *   out_len       — in: capacity; out: bytes written
 *
 * Returns 0 on success, negative on error.
 */
int ttio_fqzcomp_qual_compress(
    const uint8_t  *qual_in,
    size_t          n_qualities,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t        *out,
    size_t         *out_len);

/* Decode CRAM-byte-compatible body to flat qualities.
 *
 *   in, in_len    — compressed body bytes (parameter header inlined)
 *   read_lengths  — n_reads ints (decoder needs them; they live in the
 *                   M94.Z V4 outer header, not the CRAM body)
 *   flags         — n_reads bytes
 *   out           — caller-owned buffer of size n_qualities
 *   n_qualities   — total quality count (sum of read_lengths)
 *
 * Returns 0 on success, negative on error.
 */
int ttio_fqzcomp_qual_uncompress(
    const uint8_t  *in,
    size_t          in_len,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    uint8_t        *out,
    size_t          n_qualities);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_FQZCOMP_QUAL_H */
```

- [ ] **Step 2: Strip CRLF + verify header parses**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/src/fqzcomp_qual.h && tr -cd $"\r" < native/src/fqzcomp_qual.h | wc -c && gcc -fsyntax-only -I native/src native/src/fqzcomp_qual.h 2>&1'
```

Expected: `0` and no compile errors.

- [ ] **Step 3: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/fqzcomp_qual.h && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "scaffold(L2.X V4): fqzcomp_qual.h public API

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 6: Implement `ttio_fqzcomp_qual_compress` with fixed strategy 1 (HiSeq)

**Files:**
- Create: `native/src/fqzcomp_qual.c`

The implementation mirrors `htscodecs/fqzcomp_qual.c::fqzcomp_qual_compress`. For Phase 2 we hardcode strategy 1 (HiSeq: qbits=8, qshift=4, do_r2=1) and skip the auto-tune path — the encoder uses the fixed parameters and emits the CRAM body header with those parameters baked in.

- [ ] **Step 1: Implement encode**

The Phase 2 implementation has these blocks (mirror htscodecs):

1. **Setup**: build the per-block parameters from the strategy preset (HiSeq fixed values).
2. **Parameter header emission**: write the qmap (if any) + qbits/pbits/dbits/etc. as the first ~30-50 bytes of the output.
3. **Main encode loop**: for each quality byte, derive context from (prev_q ring, position, delta, selector), look up freq table, call `rc_cram_encode`.
4. **Finish**: flush RC, write final 5 bytes.

Read `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c::fqzcomp_qual_compress` end-to-end and port. The per-symbol encode loop is the hot path (~80% of encode wall) and must be byte-exact with htscodecs.

Concrete implementation skeleton (the actual body is ~400 lines; this shows structure):

```c
/* native/src/fqzcomp_qual.c — see header for API doc.
 *
 * Implementation mirrors htscodecs/fqzcomp_qual.c verbatim where
 * possible. Functions are organized to match htscodecs internal
 * structure for ease of byte-equality debugging.
 */
#include "fqzcomp_qual.h"
#include "rc_cram.h"
#include <string.h>
#include <stdlib.h>

/* Strategy 1 (HiSeq) preset — verbatim from htscodecs strat_table[1]. */
static const ttio_fqz_param FQZ_STRATEGY_1 = {
    .qbits = 8, .qshift = 4, .qloc = 0,
    .pbits = 7, .pshift = 1, .ploc = 8,
    .dbits = 0, .dshift = 0, .dloc = 15,
    .sbits = 1, .sloc = 15,
    .do_qa = 0, .do_r2 = 1, .do_dedup = 0,
    .max_sym = 64,
    /* qmap = identity */
};

/* Compute the qctx update — shift in new quality. */
static inline uint32_t qctx_update(uint32_t qctx, uint8_t q,
                                    uint8_t qshift, uint32_t qmask) {
    return ((qctx << qshift) | (q & ((1u << qshift) - 1))) & qmask;
}

/* Encode the parameter header to the output buffer. Returns bytes written. */
static size_t encode_param_header(uint8_t *out, size_t out_cap,
                                   const ttio_fqz_param *p,
                                   uint8_t flags) {
    /* TODO: port from htscodecs. Format is documented in
     * htscodecs/fqzcomp_qual.c around the "Write parameters" block.
     * Approximately 20-50 bytes depending on qmap presence.
     */
    (void)out; (void)out_cap; (void)p; (void)flags;
    return 0;
}

int ttio_fqzcomp_qual_compress(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t        *out, size_t *out_len)
{
    if (strategy_hint != 1) {
        /* Phase 2: only strategy 1 supported. Phase 3 will add auto-tune. */
        return -2;
    }
    const ttio_fqz_param p = FQZ_STRATEGY_1;
    size_t out_pos = 0;
    out_pos += encode_param_header(out + out_pos, *out_len - out_pos, &p, 0);

    /* Allocate freq table: 1 << (qbits+pbits+dbits+sbits) contexts.
     * For strategy 1: 8+7+0+1 = 16 bits = 65536 contexts. */
    const uint32_t n_ctx = 1u << (p.qbits + p.pbits + p.dbits + p.sbits);
    const uint32_t T = 1024;  /* htscodecs uses T=1024 per-context */
    /* freq[ctx][sym] starts at flat distribution. */
    uint16_t *freq = calloc(n_ctx * 256, sizeof(uint16_t));
    /* TODO: port the rest from htscodecs */
    (void)freq; (void)qual_in; (void)n_qualities; (void)read_lengths;
    (void)n_reads; (void)flags;
    free(freq);

    *out_len = out_pos;
    return 0;
}

int ttio_fqzcomp_qual_uncompress(
    const uint8_t  *in, size_t in_len,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    uint8_t        *out, size_t n_qualities)
{
    /* TODO: port from htscodecs */
    (void)in; (void)in_len; (void)read_lengths; (void)n_reads;
    (void)flags; (void)out; (void)n_qualities;
    return -1;
}
```

The TODO blocks must be filled with the actual algorithm port. The implementer should:

1. Open `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c` in a side-by-side editor.
2. Port `encode_param_header` first (it's ~50 lines, tightly bounded).
3. Port the main encode loop (~200 lines) function by function, preserving variable names.
4. Port `ttio_fqzcomp_qual_uncompress` similarly (~150 lines).

The Phase 2 byte-equality test (Task 7) catches any port deviation.

- [ ] **Step 2: Strip CRLF + register in CMake + rebuild**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/src/fqzcomp_qual.c'
```

Add `src/fqzcomp_qual.c` to the library source list in `native/CMakeLists.txt` (next to `src/rc_cram.c`).

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null && cmake --build . 2>&1 | tail -10'
```

Expected: clean build (warnings on `(void)` casts only).

- [ ] **Step 3: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/fqzcomp_qual.c native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(L2.X V4): fqzcomp_qual encode + decode skeleton (strategy 1)

Strategy 1 (HiSeq) hardcoded; auto-tune deferred to Phase 3. Phase 2
gate is byte-equality with htscodecs --strategy=1 on chr22.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 7: Phase 2 byte-equality test on chr22 (strategy 1)

**Files:**
- Create: `native/tests/test_fqzcomp_qual_strategy1.c`
- Modify: `native/CMakeLists.txt`

- [ ] **Step 1: Write the test**

The test:
1. Reads chr22 qualities + read_lengths + flags from a pre-prepared binary file (created by a setup script).
2. Encodes via `ttio_fqzcomp_qual_compress(strategy_hint=1)`.
3. Writes the output to `/tmp/our_chr22_strategy1.fqz`.
4. (Outside the test binary) compares against `htscodecs --strategy=1` output.

```c
/* native/tests/test_fqzcomp_qual_strategy1.c
 *
 * Phase 2 gate: ttio_fqzcomp_qual_compress with strategy 1 (HiSeq)
 * produces byte-equal output to htscodecs's fqzcomp_qual --strategy=1
 * on chr22 NA12878 lean+mapped.
 *
 * Setup: tools/perf/m94z_v4_prototype/extract_chr22_inputs.py extracts
 * qualities + read_lengths + flags from the BAM into binary files at
 * /tmp/chr22_qual.bin, /tmp/chr22_lens.bin, /tmp/chr22_flags.bin.
 * The test reads these files and encodes; the comparison happens in
 * tools/perf/htscodecs_compare.sh.
 */
#include "fqzcomp_qual.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(*len);
    if (fread(buf, 1, *len, f) != *len) { free(buf); fclose(f); return NULL; }
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    const char *qual_path  = "/tmp/chr22_qual.bin";
    const char *lens_path  = "/tmp/chr22_lens.bin";
    const char *flags_path = "/tmp/chr22_flags.bin";
    const char *out_path   = (argc > 1) ? argv[1] : "/tmp/our_chr22_strategy1.fqz";

    size_t qual_len, lens_len, flags_len;
    uint8_t  *qual_in  = read_file(qual_path,  &qual_len);
    uint8_t  *lens_buf = read_file(lens_path,  &lens_len);
    uint8_t  *flags_in = read_file(flags_path, &flags_len);
    if (!qual_in || !lens_buf || !flags_in) {
        fprintf(stderr, "missing input files; run extract_chr22_inputs.py\n");
        return 1;
    }
    uint32_t *read_lengths = (uint32_t *)lens_buf;
    size_t    n_reads      = lens_len / sizeof(uint32_t);
    fprintf(stderr, "chr22: %zu qualities, %zu reads\n", qual_len, n_reads);

    size_t out_cap = qual_len * 2 + 1024;
    uint8_t *out = malloc(out_cap);
    size_t out_len = out_cap;
    int rc = ttio_fqzcomp_qual_compress(qual_in, qual_len,
                                          read_lengths, n_reads,
                                          flags_in,
                                          1,           /* strategy 1 */
                                          out, &out_len);
    if (rc != 0) { fprintf(stderr, "compress rc=%d\n", rc); return 2; }
    fprintf(stderr, "encoded %zu qualities to %zu bytes\n", qual_len, out_len);
    fprintf(stderr, "B/qual = %.4f\n", (double)out_len / (double)qual_len);

    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", out_path); return 3; }
    fwrite(out, 1, out_len, f); fclose(f);
    fprintf(stderr, "wrote to %s\n", out_path);

    free(qual_in); free(lens_buf); free(flags_in); free(out);
    return 0;
}
```

- [ ] **Step 2: Write the input-extraction Python helper**

Create `tools/perf/m94z_v4_prototype/extract_chr22_inputs.py`:

```python
"""Extract qualities + read_lengths + flags from a BAM into binary
files for the C-side byte-equality tests. Reuses BamReader.

Usage:
    .venv/bin/python -m tools.perf.m94z_v4_prototype.extract_chr22_inputs \
        --bam /home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam \
        --out-prefix /tmp/chr22
"""
from __future__ import annotations
import argparse
import sys

import numpy as np

from ttio.importers.bam import BamReader

SAM_REVERSE_FLAG = 16


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bam", required=True)
    ap.add_argument("--out-prefix", required=True,
                    help="e.g. /tmp/chr22 → produces _qual.bin, _lens.bin, _flags.bin")
    args = ap.parse_args()

    run = BamReader(args.bam).to_genomic_run(name="run_0001")
    qualities = bytes(run.qualities.tobytes())
    read_lengths = np.asarray([int(x) for x in run.lengths], dtype=np.uint32)
    flags = np.asarray(
        [int(f) for f in run.flags], dtype=np.uint8
    )

    with open(f"{args.out_prefix}_qual.bin", "wb") as f:
        f.write(qualities)
    read_lengths.tofile(f"{args.out_prefix}_lens.bin")
    flags.tofile(f"{args.out_prefix}_flags.bin")
    print(f"qualities: {len(qualities):,} bytes")
    print(f"reads: {read_lengths.shape[0]:,}")
    print(f"flags: {flags.shape[0]:,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Run the extractor on chr22**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && .venv/bin/python -m tools.perf.m94z_v4_prototype.extract_chr22_inputs --bam /home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam --out-prefix /tmp/chr22 && ls -la /tmp/chr22_*.bin'
```

Expected: 3 files at `/tmp/chr22_qual.bin` (~178 MB), `/tmp/chr22_lens.bin` (~7 MB), `/tmp/chr22_flags.bin` (~1.7 MB).

- [ ] **Step 4: Register the test in CMake**

Add to `native/CMakeLists.txt`:

```cmake
add_executable(test_fqzcomp_qual_strategy1 tests/test_fqzcomp_qual_strategy1.c)
target_link_libraries(test_fqzcomp_qual_strategy1 ttio_rans)
add_test(NAME fqzcomp_qual_strategy1 COMMAND test_fqzcomp_qual_strategy1)
```

- [ ] **Step 5: Build + run our test**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null && cmake --build . 2>&1 | tail -5 && ./test_fqzcomp_qual_strategy1 2>&1 | tail -5'
```

Expected: prints `chr22: 178409733 qualities, 1766433 reads` then `B/qual = X.XXXX` and `wrote to /tmp/our_chr22_strategy1.fqz`.

- [ ] **Step 6: Encode chr22 with htscodecs --strategy=1**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/tools/perf/htscodecs && ./tests/fqzcomp_qual --strategy=1 /tmp/chr22_qual.bin /tmp/htscodecs_chr22_strategy1.fqz 2>&1 | tail -5 && ls -la /tmp/htscodecs_chr22_strategy1.fqz'
```

(Adjust the htscodecs CLI flags based on the actual options exposed by `tests/fqzcomp_qual --help`.)

- [ ] **Step 7: Compare bytes**

```bash
wsl -d Ubuntu -- bash -c 'cmp /tmp/our_chr22_strategy1.fqz /tmp/htscodecs_chr22_strategy1.fqz && echo "BYTE-EQUAL: OK" || (echo "BYTE-EQUAL: FAIL" && cmp /tmp/our_chr22_strategy1.fqz /tmp/htscodecs_chr22_strategy1.fqz | head -3 && echo "first divergent byte:" && cmp -b /tmp/our_chr22_strategy1.fqz /tmp/htscodecs_chr22_strategy1.fqz | head -1)'
```

Expected: `BYTE-EQUAL: OK`. If FAIL, debug `ttio_fqzcomp_qual_compress` against htscodecs source — focus on the parameter header (most common divergence point) and the per-symbol context derivation.

- [ ] **Step 8: Round-trip self-check (decode our output, compare to input)**

Update `test_fqzcomp_qual_strategy1.c` to also call `ttio_fqzcomp_qual_uncompress` on the output and assert byte-equality with the input:

```c
/* After encode succeeds: */
uint8_t *recovered = malloc(qual_len);
int rc2 = ttio_fqzcomp_qual_uncompress(out, out_len,
                                        read_lengths, n_reads,
                                        flags_in,
                                        recovered, qual_len);
if (rc2 != 0) { fprintf(stderr, "decompress rc=%d\n", rc2); return 4; }
if (memcmp(recovered, qual_in, qual_len) != 0) {
    fprintf(stderr, "round-trip MISMATCH\n");
    return 5;
}
fprintf(stderr, "round-trip: OK\n");
free(recovered);
```

Rebuild and re-run; the output should now end with `round-trip: OK`.

- [ ] **Step 9: Commit on success**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/tests/test_fqzcomp_qual_strategy1.c native/CMakeLists.txt tools/perf/m94z_v4_prototype/extract_chr22_inputs.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L2.X V4): fqzcomp_qual strategy 1 byte-equality + round-trip

Phase 2 gate: byte-equal htscodecs --strategy=1 on chr22, plus
round-trip self-consistency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 3 — Auto-tuning + 5-strategy preset table

### Task 8: Add the 5-preset table + histogram-analysis pass

**Files:**
- Modify: `native/src/fqzcomp_qual.c` — add the auto-tune logic

- [ ] **Step 1: Port the strategy preset table**

Add to `native/src/fqzcomp_qual.c` near the existing `FQZ_STRATEGY_1`:

```c
/* All 5 strategy presets, verbatim from htscodecs strat_table[]. */
static const ttio_fqz_param FQZ_STRATEGIES[5] = {
    /* 0: Generic */
    { .qbits=10, .qshift=5, .qloc=0, .pbits=4, .pshift=0, .ploc=10,
      .dbits=2, .dshift=0, .dloc=14, .sbits=0, .sloc=15,
      .do_qa=0, .do_r2=0, .do_dedup=0, .max_sym=64 },
    /* 1: HiSeq 2000 — already defined as FQZ_STRATEGY_1 */
    { .qbits=8, .qshift=4, .qloc=0, .pbits=7, .pshift=1, .ploc=8,
      .dbits=0, .dshift=0, .dloc=15, .sbits=1, .sloc=15,
      .do_qa=0, .do_r2=1, .do_dedup=0, .max_sym=64 },
    /* 2: MiSeq */
    { .qbits=12, .qshift=6, .qloc=0, .pbits=4, .pshift=0, .ploc=12,
      .dbits=0, .dshift=0, .dloc=15, .sbits=0, .sloc=15,
      .do_qa=0, .do_r2=0, .do_dedup=0, .max_sym=64 },
    /* 3: IonTorrent */
    { .qbits=9, .qshift=4, .qloc=0, .pbits=5, .pshift=0, .ploc=9,
      .dbits=2, .dshift=0, .dloc=14, .sbits=0, .sloc=15,
      .do_qa=0, .do_r2=0, .do_dedup=0, .max_sym=64 },
    /* 4: Custom — reserved; encoder fills at runtime via auto-tune */
    {0}
};
```

(Verify these values against `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c::strat_table[]` and adjust if any differ.)

- [ ] **Step 2: Port the histogram-analysis auto-tune pass**

The auto-tune analyzes the input quality byte distribution + average per-read quality + duplicate detection to pick parameters. The exact algorithm is in `htscodecs/fqzcomp_qual.c` around the `auto_set_*` family of functions.

Add a static function in `fqzcomp_qual.c`:

```c
/* Pick a strategy by analyzing the input qualities + per-read avg.
 * Returns a fully-populated ttio_fqz_param.
 *
 * Mirrors htscodecs's auto_select_strategy(). */
static ttio_fqz_param auto_tune_strategy(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags)
{
    /* Histogram pass: count distinct Q values, compute avg per-read. */
    int q_count[256] = {0};
    for (size_t i = 0; i < n_qualities; i++) q_count[qual_in[i]]++;
    int distinct = 0;
    for (int i = 0; i < 256; i++) if (q_count[i] > 0) distinct++;

    /* Heuristics from htscodecs:
     * - distinct ≤ 4 → low-entropy: qshift=2, reduced pbits
     * - distinct ≤ 8 → moderate: qbits=9, qshift=3
     * - small input (<300 KB) → simplified: qbits=qshift, dbits=2
     * - else → strategy 1 (HiSeq) as default
     */
    ttio_fqz_param p;
    if (n_qualities < 300 * 1024) {
        p = FQZ_STRATEGIES[0];  /* generic + simplified */
        p.qbits = p.qshift; p.dbits = 2;
    } else if (distinct <= 4) {
        p = FQZ_STRATEGIES[0];
        p.qshift = 2; p.pbits = 2;
    } else if (distinct <= 8) {
        p = FQZ_STRATEGIES[0];
        p.qbits = 9; p.qshift = 3;
    } else {
        p = FQZ_STRATEGIES[1];  /* HiSeq default */
    }

    /* TODO: port do_qa (quality-average split detection) and do_r2
     * (READ1/READ2 split benefit detection) from htscodecs. */
    (void)read_lengths; (void)n_reads; (void)flags;
    return p;
}
```

- [ ] **Step 3: Wire auto-tune into the compress entry**

Modify `ttio_fqzcomp_qual_compress` to use auto-tune when `strategy_hint == -1`:

```c
int ttio_fqzcomp_qual_compress(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t        *out, size_t *out_len)
{
    ttio_fqz_param p;
    if (strategy_hint >= 0 && strategy_hint <= 4) {
        p = FQZ_STRATEGIES[strategy_hint];
    } else if (strategy_hint == -1) {
        p = auto_tune_strategy(qual_in, n_qualities,
                                read_lengths, n_reads, flags);
    } else {
        return -2;
    }
    /* ...rest of encode body using `p`... */
}
```

- [ ] **Step 4: Strip CRLF + rebuild**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/src/fqzcomp_qual.c && cd native/_build && cmake --build . 2>&1 | tail -5'
```

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/fqzcomp_qual.c && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(L2.X V4): fqzcomp_qual auto-tune + 5-preset table

Auto-tune picks a strategy preset based on quality histogram +
per-read avg + dedup hints. Mirrors htscodecs auto_set_* family.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 9: Phase 3 byte-equality test across all 4 corpora

**Files:**
- Create: `native/tests/test_fqzcomp_qual_autotune.c`
- Create: `tools/perf/htscodecs_compare.sh` — helper script

- [ ] **Step 1: Write the multi-corpus byte-equality script**

```bash
wsl -d Ubuntu -- bash -c 'cat > /home/toddw/TTI-O/tools/perf/htscodecs_compare.sh << "EOF"
#!/usr/bin/env bash
# Byte-equality helper: encode each corpus with both ours and htscodecs
# (auto-tune mode), compare bytes. Exit 0 if all match; non-zero otherwise.
#
# Usage:
#   tools/perf/htscodecs_compare.sh
set -euo pipefail

REPO=/home/toddw/TTI-O
HTSCODECS_BIN=$REPO/tools/perf/htscodecs/tests/fqzcomp_qual
OUR_BIN=$REPO/native/_build/test_fqzcomp_qual_autotune
PROTOTYPE=$REPO/.venv/bin/python\ -m\ tools.perf.m94z_v4_prototype.extract_chr22_inputs

declare -a CORPORA=(
  "chr22:$REPO/data/genomic/na12878/na12878.chr22.lean.mapped.bam"
  "wes:$REPO/data/genomic/na12878_wes/na12878_wes.chr22.bam"
  "hg002_illumina:$REPO/data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"
  "hg002_pacbio:$REPO/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"
)

ALL_OK=1
for entry in "${CORPORA[@]}"; do
  name="${entry%%:*}"
  bam="${entry#*:}"
  echo "=== $name ($bam) ==="
  cd $REPO
  .venv/bin/python -m tools.perf.m94z_v4_prototype.extract_chr22_inputs \
      --bam "$bam" --out-prefix /tmp/${name}_v4
  # Our encoder
  $OUR_BIN /tmp/${name}_v4_qual.bin /tmp/our_${name}_v4.fqz
  # htscodecs auto-tune
  $HTSCODECS_BIN /tmp/${name}_v4_qual.bin /tmp/htscodecs_${name}_v4.fqz
  if cmp -s /tmp/our_${name}_v4.fqz /tmp/htscodecs_${name}_v4.fqz; then
    echo "  ✓ BYTE-EQUAL"
  else
    echo "  ✗ DIFFER"
    ALL_OK=0
  fi
done

if [ $ALL_OK -eq 1 ]; then
  echo "ALL CORPORA: BYTE-EQUAL"
  exit 0
else
  echo "FAILURE: at least one corpus differs"
  exit 1
fi
EOF
chmod +x /home/toddw/TTI-O/tools/perf/htscodecs_compare.sh'
```

(Adjust the helper to handle the read_lengths/flags inputs the C test needs — the actual interface depends on how `test_fqzcomp_qual_autotune.c` reads its inputs.)

- [ ] **Step 2: Write the auto-tune C test**

```c
/* native/tests/test_fqzcomp_qual_autotune.c
 *
 * Phase 3 gate: byte-equality with htscodecs in auto-tune mode
 * across all 4 corpora.
 *
 * The test takes (qual_path, lens_path, flags_path, out_path) and
 * encodes with strategy_hint = -1 (auto-tune). The shell script
 * tools/perf/htscodecs_compare.sh wraps this for the multi-corpus
 * run.
 */
#include "fqzcomp_qual.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(*len);
    if (fread(buf, 1, *len, f) != *len) { free(buf); fclose(f); return NULL; }
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s qual.bin lens.bin flags.bin out.fqz\n", argv[0]);
        return 1;
    }
    size_t ql, ll, fl;
    uint8_t  *qual_in  = read_file(argv[1], &ql);
    uint8_t  *lens_buf = read_file(argv[2], &ll);
    uint8_t  *flags_in = read_file(argv[3], &fl);
    if (!qual_in || !lens_buf || !flags_in) {
        fprintf(stderr, "missing input files\n"); return 2;
    }
    uint32_t *read_lengths = (uint32_t *)lens_buf;
    size_t    n_reads      = ll / sizeof(uint32_t);

    size_t out_cap = ql * 2 + 1024;
    uint8_t *out = malloc(out_cap);
    size_t out_len = out_cap;
    int rc = ttio_fqzcomp_qual_compress(qual_in, ql,
                                          read_lengths, n_reads,
                                          flags_in,
                                          -1,           /* auto-tune */
                                          out, &out_len);
    if (rc != 0) { fprintf(stderr, "compress rc=%d\n", rc); return 3; }
    fprintf(stderr, "auto-tune encoded %zu qualities to %zu bytes (B/qual=%.4f)\n",
            ql, out_len, (double)out_len / (double)ql);

    /* Round-trip self-check. */
    uint8_t *recovered = malloc(ql);
    int rc2 = ttio_fqzcomp_qual_uncompress(out, out_len,
                                            read_lengths, n_reads,
                                            flags_in,
                                            recovered, ql);
    if (rc2 != 0) { fprintf(stderr, "decompress rc=%d\n", rc2); return 4; }
    if (memcmp(recovered, qual_in, ql) != 0) {
        fprintf(stderr, "round-trip MISMATCH\n"); return 5;
    }
    fprintf(stderr, "round-trip: OK\n");

    FILE *f = fopen(argv[4], "wb");
    fwrite(out, 1, out_len, f); fclose(f);
    fprintf(stderr, "wrote to %s\n", argv[4]);

    free(qual_in); free(lens_buf); free(flags_in); free(out); free(recovered);
    return 0;
}
```

- [ ] **Step 3: Register the test + build**

Add to `native/CMakeLists.txt`:

```cmake
add_executable(test_fqzcomp_qual_autotune tests/test_fqzcomp_qual_autotune.c)
target_link_libraries(test_fqzcomp_qual_autotune ttio_rans)
```

Build:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null && cmake --build . 2>&1 | tail -5'
```

- [ ] **Step 4: Run the multi-corpus byte-equality script**

```bash
wsl -d Ubuntu -- bash -c '/home/toddw/TTI-O/tools/perf/htscodecs_compare.sh 2>&1 | tail -20'
```

Expected: `ALL CORPORA: BYTE-EQUAL`. If any corpus fails, the auto-tune is picking different strategies than htscodecs — debug by printing the picked strategy on both sides for the failing corpus.

- [ ] **Step 5: Commit on success**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/tests/test_fqzcomp_qual_autotune.c native/CMakeLists.txt tools/perf/htscodecs_compare.sh && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L2.X V4): auto-tune byte-equality across all 4 corpora

Phase 3 gate: byte-equal htscodecs (auto-tune mode) on chr22 + WES +
HG002 Illumina + HG002 PacBio HiFi. Plus round-trip self-consistency
on each corpus.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 4 — V4 wire format + Python wrapper

### Task 10: Implement V4 outer wire format (`m94z_v4_wire.{c,h}`)

**Files:**
- Create: `native/src/m94z_v4_wire.h`
- Create: `native/src/m94z_v4_wire.c`
- Modify: `native/include/ttio_rans.h` (add V4 entry points)

- [ ] **Step 1: Define the V4 wire-format API**

```c
/* native/src/m94z_v4_wire.h
 *
 * M94.Z V4 outer wire format: wraps a CRAM-byte-compatible
 * fqzcomp_qual body with our standard M94.Z header.
 *
 * Header format (per spec §4):
 *   offset  size   field
 *     0       4    magic = "M94Z"
 *     4       1    version = 4
 *     5       1    flags
 *     6       8    num_qualities (uint64 LE)
 *    14       8    num_reads     (uint64 LE)
 *    22       4    rlt_compressed_len (uint32 LE)
 *    26    var R   read_length_table (deflated)
 *  26+R       4    cram_body_len (uint32 LE)
 *  30+R   var      cram_body (CRAM-compatible)
 *
 * Total = 30 + R + cram_body_len.
 */
#ifndef TTIO_M94Z_V4_WIRE_H
#define TTIO_M94Z_V4_WIRE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TTIO_M94Z_V4_MAGIC "M94Z"
#define TTIO_M94Z_V4_VERSION 4

/* Pack a V4 stream: outer header + cram_body.
 *
 * Inputs:
 *   num_qualities, num_reads — for the header
 *   read_lengths             — input to compress as the RLT (deflated)
 *   pad_count                — 0..3 (V3 convention)
 *   cram_body, cram_body_len — output of ttio_fqzcomp_qual_compress
 *   out, out_cap             — caller-owned buffer
 *
 * Outputs:
 *   *out_len                 — bytes written
 *
 * Returns 0 on success, negative on error.
 */
int ttio_m94z_v4_pack(
    uint64_t          num_qualities,
    uint64_t          num_reads,
    const uint32_t   *read_lengths,
    uint8_t           pad_count,
    const uint8_t    *cram_body,
    size_t            cram_body_len,
    uint8_t          *out,
    size_t           *out_len);

/* Unpack a V4 stream: parse outer header, validate magic+version,
 * extract num_qualities/num_reads/read_lengths/cram_body.
 *
 * Returns 0 on success, negative on error. read_lengths buffer
 * is caller-owned; size in entries = num_reads (caller must
 * pre-allocate).
 */
int ttio_m94z_v4_unpack(
    const uint8_t    *in,
    size_t            in_len,
    uint64_t         *out_num_qualities,
    uint64_t         *out_num_reads,
    uint32_t         *out_read_lengths,
    uint8_t          *out_pad_count,
    const uint8_t   **out_cram_body,
    size_t           *out_cram_body_len);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_M94Z_V4_WIRE_H */
```

- [ ] **Step 2: Implement `m94z_v4_wire.c`**

```c
/* native/src/m94z_v4_wire.c — see header for spec. */
#include "m94z_v4_wire.h"
#include <string.h>
#include <zlib.h>

/* RLT compression: deflate the read_lengths array as-is (LE uint32). */
static int compress_rlt(const uint32_t *read_lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len) {
    uLongf dst = *out_len;
    int rc = compress2(out, &dst,
                        (const Bytef *)read_lengths,
                        n_reads * sizeof(uint32_t),
                        9);
    if (rc != Z_OK) return -1;
    *out_len = dst;
    return 0;
}

static int decompress_rlt(const uint8_t *in, size_t in_len,
                            uint32_t *out, size_t n_reads) {
    uLongf dst = n_reads * sizeof(uint32_t);
    int rc = uncompress((Bytef *)out, &dst, in, in_len);
    if (rc != Z_OK) return -1;
    if (dst != n_reads * sizeof(uint32_t)) return -2;
    return 0;
}

int ttio_m94z_v4_pack(
    uint64_t num_qualities, uint64_t num_reads,
    const uint32_t *read_lengths,
    uint8_t pad_count,
    const uint8_t *cram_body, size_t cram_body_len,
    uint8_t *out, size_t *out_len)
{
    if (*out_len < 30 + cram_body_len + 64) return -1;
    /* Compress RLT into a scratch buffer. */
    size_t rlt_cap = num_reads * sizeof(uint32_t) + 256;
    uint8_t *rlt = malloc(rlt_cap);
    if (!rlt) return -2;
    size_t rlt_len = rlt_cap;
    if (compress_rlt(read_lengths, num_reads, rlt, &rlt_len) != 0) {
        free(rlt); return -3;
    }
    if (*out_len < 30 + rlt_len + cram_body_len) {
        free(rlt); return -4;
    }
    /* Write outer header. */
    memcpy(out, TTIO_M94Z_V4_MAGIC, 4);
    out[4] = TTIO_M94Z_V4_VERSION;
    /* flags: bit 0 = has_cram_body (must be 1); bits 4-5 = pad_count */
    out[5] = (uint8_t)(0x01u | ((pad_count & 0x3) << 4));
    memcpy(out + 6, &num_qualities, 8);
    memcpy(out + 14, &num_reads, 8);
    uint32_t rlt32 = (uint32_t)rlt_len;
    memcpy(out + 22, &rlt32, 4);
    memcpy(out + 26, rlt, rlt_len);
    uint32_t cram32 = (uint32_t)cram_body_len;
    memcpy(out + 26 + rlt_len, &cram32, 4);
    memcpy(out + 30 + rlt_len, cram_body, cram_body_len);
    *out_len = 30 + rlt_len + cram_body_len;
    free(rlt);
    return 0;
}

int ttio_m94z_v4_unpack(
    const uint8_t *in, size_t in_len,
    uint64_t *out_nq, uint64_t *out_nr,
    uint32_t *out_rl,
    uint8_t  *out_pad,
    const uint8_t **out_body, size_t *out_body_len)
{
    if (in_len < 30) return -1;
    if (memcmp(in, TTIO_M94Z_V4_MAGIC, 4) != 0) return -2;
    if (in[4] != TTIO_M94Z_V4_VERSION) return -3;
    uint8_t flags = in[5];
    if (!(flags & 0x01)) return -4;  /* has_cram_body must be set */
    *out_pad = (flags >> 4) & 0x3;
    memcpy(out_nq, in + 6, 8);
    memcpy(out_nr, in + 14, 8);
    uint32_t rlt_len;
    memcpy(&rlt_len, in + 22, 4);
    if (in_len < 26 + rlt_len + 4) return -5;
    if (decompress_rlt(in + 26, rlt_len, out_rl, *out_nr) != 0) return -6;
    uint32_t cram_len;
    memcpy(&cram_len, in + 26 + rlt_len, 4);
    if (in_len < 30 + rlt_len + cram_len) return -7;
    *out_body = in + 30 + rlt_len;
    *out_body_len = cram_len;
    return 0;
}
```

- [ ] **Step 3: Add V4 entry points to `native/include/ttio_rans.h`**

Add at the end (before the closing `#endif`):

```c
/* M94.Z V4: CRAM 3.1 fqzcomp port. See native/src/m94z_v4_wire.h
 * + native/src/fqzcomp_qual.h for details. */
int ttio_m94z_v4_encode(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    int             strategy_hint,    /* -1 = auto-tune */
    uint8_t         pad_count,
    uint8_t        *out, size_t *out_len);

int ttio_m94z_v4_decode(
    const uint8_t  *in, size_t in_len,
    uint32_t       *read_lengths,    /* caller pre-allocates n_reads */
    size_t          n_reads,
    const uint8_t  *flags,
    uint8_t        *out_qual,
    size_t          n_qualities);
```

- [ ] **Step 4: Implement the V4 encode/decode entry points**

In `native/src/m94z_v4_wire.c`, after the pack/unpack functions, add:

```c
#include "fqzcomp_qual.h"

int ttio_m94z_v4_encode(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t         pad_count,
    uint8_t        *out, size_t *out_len)
{
    /* Step 1: encode the inner CRAM body. */
    size_t cram_cap = n_qualities * 2 + 1024;
    uint8_t *cram_body = malloc(cram_cap);
    if (!cram_body) return -1;
    size_t cram_len = cram_cap;
    int rc = ttio_fqzcomp_qual_compress(qual_in, n_qualities,
                                          read_lengths, n_reads, flags,
                                          strategy_hint,
                                          cram_body, &cram_len);
    if (rc != 0) { free(cram_body); return -2; }
    /* Step 2: wrap with outer V4 header. */
    rc = ttio_m94z_v4_pack(n_qualities, n_reads, read_lengths, pad_count,
                            cram_body, cram_len, out, out_len);
    free(cram_body);
    return rc;
}

int ttio_m94z_v4_decode(
    const uint8_t *in, size_t in_len,
    uint32_t *read_lengths, size_t n_reads,
    const uint8_t *flags,
    uint8_t *out_qual, size_t n_qualities)
{
    uint64_t nq, nr;
    uint8_t pad;
    const uint8_t *body;
    size_t body_len;
    int rc = ttio_m94z_v4_unpack(in, in_len, &nq, &nr,
                                   read_lengths, &pad, &body, &body_len);
    if (rc != 0) return rc;
    if (nq != n_qualities || nr != n_reads) return -10;
    return ttio_fqzcomp_qual_uncompress(body, body_len,
                                          read_lengths, n_reads, flags,
                                          out_qual, n_qualities);
}
```

- [ ] **Step 5: Register sources + rebuild**

Add `src/m94z_v4_wire.c` to the library source list in `native/CMakeLists.txt`. Ensure `zlib` is linked (it's already linked for V3's RLT compression — verify).

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" native/src/m94z_v4_wire.h native/src/m94z_v4_wire.c native/include/ttio_rans.h && cd native/_build && cmake .. > /dev/null && cmake --build . 2>&1 | tail -10'
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/m94z_v4_wire.h native/src/m94z_v4_wire.c native/include/ttio_rans.h native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(L2.X V4): m94z_v4_wire + entry points

Outer V4 wire format (M94.Z header wrapping CRAM-byte-compatible
fqzcomp body) + ttio_m94z_v4_encode/decode entry points wired
through ttio_rans.h.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 11: Add Python ctypes V4 dispatch

**Files:**
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`

- [ ] **Step 1: Add V4 ctypes bindings**

Open `python/src/ttio/codecs/fqzcomp_nx16_z.py`. Find the section near line 880-920 where V3 ctypes bindings are configured. Add V4 bindings:

```python
# Configure V4 entry points (after existing V3 bindings)
if _HAVE_NATIVE_LIB:
    _lib.ttio_m94z_v4_encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),  # qual_in
        ctypes.c_size_t,                  # n_qualities
        ctypes.POINTER(ctypes.c_uint32),  # read_lengths
        ctypes.c_size_t,                  # n_reads
        ctypes.POINTER(ctypes.c_uint8),   # flags
        ctypes.c_int,                     # strategy_hint
        ctypes.c_uint8,                   # pad_count
        ctypes.POINTER(ctypes.c_uint8),   # out
        ctypes.POINTER(ctypes.c_size_t),  # out_len
    ]
    _lib.ttio_m94z_v4_encode.restype = ctypes.c_int

    _lib.ttio_m94z_v4_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),  # in
        ctypes.c_size_t,                  # in_len
        ctypes.POINTER(ctypes.c_uint32),  # read_lengths (out)
        ctypes.c_size_t,                  # n_reads
        ctypes.POINTER(ctypes.c_uint8),   # flags
        ctypes.POINTER(ctypes.c_uint8),   # out_qual
        ctypes.c_size_t,                  # n_qualities
    ]
    _lib.ttio_m94z_v4_decode.restype = ctypes.c_int
```

- [ ] **Step 2: Add `_encode_v4_native` function**

Near the existing `_encode_v3_native` (around line 1467), add:

```python
def _encode_v4_native(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    n_padded: int,
    pad_count: int,
    strategy_hint: int = -1,  # -1 = auto-tune
) -> bytes:
    """V4 (CRAM 3.1 fqzcomp port) encode.

    Calls the native C entry ttio_m94z_v4_encode which wraps the
    CRAM-byte-compatible body with our M94.Z V4 outer header.

    Per spec §4: the outer M94.Z header carries num_qualities,
    num_reads, deflated read_length_table, pad_count; the inner CRAM
    body carries everything else (parameters, qmap, freq tables,
    encoded symbols).
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_encode_v4_native called but libttio_rans is not available"
        )

    n = len(qualities)
    n_reads = len(read_lengths)

    # Build flat-byte inputs for the C call. SAM_REVERSE_FLAG is bit 4;
    # the C side reads it directly. We pass full flags bytes (V3
    # convention preserved).
    SAM_REVERSE_FLAG = 16
    flags_bytes = bytes(
        ((1 if (int(f) & SAM_REVERSE_FLAG) else 0) << 4) for f in revcomp_flags
    )

    qual_arr = np.frombuffer(qualities, dtype=np.uint8)
    lens_arr = np.asarray(read_lengths, dtype=np.uint32)
    flags_arr = np.frombuffer(flags_bytes, dtype=np.uint8)

    out_cap = n * 2 + 1024
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_m94z_v4_encode(
        qual_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_size_t(n),
        lens_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32)),
        ctypes.c_size_t(n_reads),
        flags_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_int(strategy_hint),
        ctypes.c_uint8(pad_count),
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_v4_encode failed: rc={rc}")
    return bytes(out_buf[:out_len.value])
```

- [ ] **Step 3: Add `_decode_v4_via_native` function**

```python
def _decode_v4_via_native(
    encoded: bytes,
    revcomp_flags: list[int] | None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode a V4 (CRAM port) M94.Z blob.

    Pipeline:
      1. Parse V4 outer header (num_qualities, num_reads,
         read_length_table, pad_count). The C entry decompresses
         the RLT internally.
      2. Allocate output buffer of n_qualities bytes.
      3. Pass the inner CRAM body to the C decoder.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_decode_v4_via_native called but libttio_rans is not available"
        )

    # First pass: parse the header to get num_qualities + num_reads.
    # We re-parse in C for the actual decode, but Python needs the
    # numbers to allocate the output buffer.
    if len(encoded) < 30 or encoded[:4] != b"M94Z" or encoded[4] != 4:
        raise ValueError("not a V4 stream")
    import struct
    num_qualities = struct.unpack_from("<Q", encoded, 6)[0]
    num_reads = struct.unpack_from("<Q", encoded, 14)[0]
    pad_count = (encoded[5] >> 4) & 0x3

    if revcomp_flags is None:
        revcomp_flags = [0] * num_reads
    elif len(revcomp_flags) != num_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != num_reads {num_reads}"
        )

    SAM_REVERSE_FLAG = 16
    flags_bytes = bytes(
        ((1 if (int(f) & SAM_REVERSE_FLAG) else 0) << 4) for f in revcomp_flags
    )
    flags_arr = np.frombuffer(flags_bytes, dtype=np.uint8)
    in_arr = np.frombuffer(encoded, dtype=np.uint8)
    lens_arr = np.zeros(num_reads, dtype=np.uint32)
    out_arr = np.zeros(num_qualities, dtype=np.uint8)

    rc = _lib.ttio_m94z_v4_decode(
        in_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_size_t(len(encoded)),
        lens_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32)),
        ctypes.c_size_t(num_reads),
        flags_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        out_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)),
        ctypes.c_size_t(num_qualities),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_v4_decode failed: rc={rc}")

    return (
        bytes(out_arr.tobytes()),
        [int(x) for x in lens_arr],
        list(revcomp_flags),
    )
```

- [ ] **Step 4: Update `encode()` to dispatch V4 by default**

Find the existing `encode(...)` function (around line 1710). Update the dispatch to include V4:

```python
def encode(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    prefer_v4: bool | None = None,
    prefer_v3: bool | None = None,
    prefer_native: bool | None = None,  # V2 native (legacy)
    qbits: int = DEFAULT_QBITS,
    pbits: int = DEFAULT_PBITS,
    sloc: int = DEFAULT_SLOC,
) -> bytes:
    """Encode M94.Z stream. Dispatch order:

    Default (no flags): V4 if native available; else V3 if native; else V1.

    Env var TTIO_M94Z_VERSION="4" / "3" / "2" / "1" forces a version.
    Per-call kwargs prefer_v4 / prefer_v3 / prefer_native override env.
    """
    n = len(qualities)
    pad_count = (-n) & 0x3
    n_padded = n + pad_count

    env_ver = os.environ.get("TTIO_M94Z_VERSION", "").strip()
    if prefer_v4 is None:
        if env_ver == "4":
            prefer_v4 = True
        elif env_ver in ("1", "2", "3"):
            prefer_v4 = False
        else:
            prefer_v4 = _HAVE_NATIVE_LIB  # V4 default when native available

    if prefer_v4 and _HAVE_NATIVE_LIB:
        return _encode_v4_native(qualities, read_lengths, revcomp_flags,
                                  n_padded, pad_count)

    # Existing V3 / V2 / V1 dispatch unchanged below.
    # ...
```

- [ ] **Step 5: Update `decode_with_metadata()` to handle V4**

Find the version-byte dispatch (around line 1900):

```python
def decode_with_metadata(encoded: bytes, revcomp_flags=None):
    if len(encoded) < 5:
        raise ValueError("M94.Z stream too short")
    if encoded[:4] != MAGIC:
        raise ValueError("not an M94.Z stream")
    version = encoded[4]
    if version == 4:
        return _decode_v4_via_native(encoded, revcomp_flags)
    elif version == 3:
        return _decode_v3_via_native(encoded, revcomp_flags)
    elif version == 2:
        # ... existing V2
    elif version == 1:
        # ... existing V1
    else:
        raise ValueError(f"unsupported M94.Z version: {version}")
```

- [ ] **Step 6: Strip CRLF + run existing tests to confirm nothing broke**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" python/src/ttio/codecs/fqzcomp_nx16_z.py && tr -cd $"\r" < python/src/ttio/codecs/fqzcomp_nx16_z.py | wc -c && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/test_m94z_v3_dispatch.py -x -q 2>&1 | tail -10'
```

Expected: 0 CRs; existing V3 tests still green (we haven't changed V3 behavior).

- [ ] **Step 7: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/src/ttio/codecs/fqzcomp_nx16_z.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(L2.X V4): Python V4 dispatch via ctypes

_encode_v4_native + _decode_v4_via_native + V4-default encoder
selection when _HAVE_NATIVE_LIB. Existing V3/V2/V1 dispatch preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 12: Python V4 dispatch tests

**Files:**
- Create: `python/tests/test_m94z_v4_dispatch.py`
- Modify: `python/tests/test_m94z_v3_dispatch.py` (V3 default tests become explicit)

- [ ] **Step 1: Write the V4 dispatch test suite (~10 tests)**

```python
"""V4 dispatch tests for fqzcomp_nx16_z.encode / decode_with_metadata."""
from __future__ import annotations

import os
import pytest

import numpy as np

from ttio.codecs.fqzcomp_nx16_z import (
    encode,
    decode_with_metadata,
    _HAVE_NATIVE_LIB,
)

# 3 reads × 4 qualities, mixed Q-values, mixed revcomp.
SYNTH_QUALITIES = bytes([
    ord('I'), ord('I'), ord('?'), ord('?'),
    ord('5'), ord('5'), ord('5'), ord('5'),
    ord('I'), ord('?'), ord('I'), ord('?'),
])
SYNTH_READ_LENS = [4, 4, 4]
SYNTH_REVCOMP = [0, 16, 0]  # SAM_REVERSE_FLAG = 16 on read 1


pytestmark = pytest.mark.skipif(not _HAVE_NATIVE_LIB,
                                  reason="V4 needs libttio_rans")


def test_v4_smoke_roundtrip():
    out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP, prefer_v4=True)
    assert out[:4] == b"M94Z"
    assert out[4] == 4
    qual, lens, rev = decode_with_metadata(out, SYNTH_REVCOMP)
    assert qual == SYNTH_QUALITIES
    assert list(lens) == SYNTH_READ_LENS


def test_v4_default_when_native():
    """Without prefer_v4, V4 is chosen when native lib is loaded."""
    out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP)
    assert out[4] == 4


def test_v3_explicit_still_works():
    """prefer_v3=True (with prefer_v4=False) uses V3."""
    out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP,
                  prefer_v4=False, prefer_v3=True)
    assert out[4] == 3
    qual, _, _ = decode_with_metadata(out, SYNTH_REVCOMP)
    assert qual == SYNTH_QUALITIES


def test_env_var_v4(monkeypatch):
    monkeypatch.setenv("TTIO_M94Z_VERSION", "4")
    out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP)
    assert out[4] == 4


def test_env_var_v3(monkeypatch):
    monkeypatch.setenv("TTIO_M94Z_VERSION", "3")
    out = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP)
    assert out[4] == 3


def test_v4_smaller_than_v3_on_realistic_input():
    """Sanity: on a meaningful Illumina-like input V4 should beat V3."""
    rng = np.random.default_rng(0xBEEF)
    n_reads = 1000
    read_lens = [101] * n_reads
    qualities = bytes((rng.integers(33, 73, size=101 * n_reads)).astype(np.uint8))
    revcomp = [0] * n_reads
    v3 = encode(qualities, read_lens, revcomp, prefer_v4=False, prefer_v3=True)
    v4 = encode(qualities, read_lens, revcomp, prefer_v4=True)
    # V4 should be at least as small as V3 on Illumina-like data.
    assert len(v4) <= len(v3) + 100, f"V4={len(v4)} V3={len(v3)}"


def test_v4_v3_cross_decode_fails():
    """V4-encoded stream cannot be decoded as V3 (different version byte)."""
    v4 = encode(SYNTH_QUALITIES, SYNTH_READ_LENS, SYNTH_REVCOMP, prefer_v4=True)
    # decode_with_metadata dispatches on version byte; V4 stays in V4 path.
    # We just sanity-check the version byte mismatch detection:
    assert v4[4] == 4
    # Tamper with version byte to V3 — should fail because the body isn't V3 format
    tampered = v4[:4] + bytes([3]) + v4[5:]
    with pytest.raises((ValueError, RuntimeError)):
        decode_with_metadata(tampered, SYNTH_REVCOMP)


def test_v4_pad_count_correct():
    """13 qualities → pad_count = 3; output should round-trip."""
    qual_13 = SYNTH_QUALITIES + bytes([ord('@')])  # 13 bytes
    lens_13 = SYNTH_READ_LENS + [1]
    rev_13 = SYNTH_REVCOMP + [0]
    out = encode(qual_13, lens_13, rev_13, prefer_v4=True)
    qual, lens, _ = decode_with_metadata(out, rev_13)
    assert qual == qual_13
    assert list(lens) == lens_13


def test_v4_empty_input():
    """Empty qualities should encode + decode cleanly."""
    out = encode(b"", [], [], prefer_v4=True)
    qual, lens, _ = decode_with_metadata(out, [])
    assert qual == b""
    assert list(lens) == []


def test_v4_single_read():
    """Single-read input."""
    qual = bytes([ord('I')] * 50)
    out = encode(qual, [50], [0], prefer_v4=True)
    qual_back, _, _ = decode_with_metadata(out, [0])
    assert qual_back == qual
```

- [ ] **Step 2: Update existing V3 default tests to be explicit**

Open `python/tests/test_m94z_v3_dispatch.py`. For tests that previously asserted V3 was the default (e.g. `assert out[4] == 3`), update them to use `prefer_v4=False, prefer_v3=True`. Keep the env-var V3 tests as-is.

- [ ] **Step 3: Run V4 + V3 test suites**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" python/tests/test_m94z_v4_dispatch.py python/tests/test_m94z_v3_dispatch.py && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/test_m94z_v4_dispatch.py python/tests/test_m94z_v3_dispatch.py -x -q 2>&1 | tail -10'
```

Expected: V4 ~10 tests pass; V3 tests pass with the explicit `prefer_v4=False`.

- [ ] **Step 4: Run the full M94.Z suite**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/ -k "m94z" -q 2>&1 | tail -10'
```

Expected: full M94.Z suite (V1+V2+V3+V4) green.

- [ ] **Step 5: Run the full Python suite (excl integration)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/ --ignore=python/tests/integration -q 2>&1 | tail -10'
```

Expected: all 1811+ existing tests + ~10 new V4 dispatch tests = ~1821 pass.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/tests/test_m94z_v4_dispatch.py python/tests/test_m94z_v3_dispatch.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L2.X V4): Python V4 dispatch suite (~10 tests)

V4 smoke + default + env-var + cross-version + pad/empty/single-read
edge cases. V3 default tests updated to explicit prefer_v4=False.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 5 — Cross-corpus validation + spec docs + WORKPLAN

### Task 13: Run V4 byte-equality across all 4 corpora end-to-end (Python path)

**Files:**
- Create: `python/tests/integration/test_m94z_v4_byte_exact.py`

The C-level byte-equality test (Phase 3) confirmed our `fqzcomp_qual.c` matches htscodecs byte-for-byte. Phase 5 confirms the same property holds end-to-end through the Python wrapper + V4 wire format. The Python test extracts qualities via `BamReader`, encodes via `encode(prefer_v4=True)`, strips the M94.Z V4 outer header, and byte-compares the inner CRAM body to htscodecs CLI output on the same input.

- [ ] **Step 1: Write the cross-corpus byte-exact test**

```python
"""V4 cross-corpus byte-exact integration tests.

Skipped automatically if htscodecs CLI is not built at
tools/perf/htscodecs/tests/fqzcomp_qual. Run manually during
Stage 2 development; not required in CI for now.
"""
from __future__ import annotations

import os
import struct
import subprocess
from pathlib import Path

import pytest

from ttio.codecs.fqzcomp_nx16_z import encode, _HAVE_NATIVE_LIB
from ttio.importers.bam import BamReader

REPO = Path("/home/toddw/TTI-O")
HTS_BIN = REPO / "tools/perf/htscodecs/tests/fqzcomp_qual"
NATIVE_LIB = REPO / "native/_build/libttio_rans.so"

CORPORA = [
    ("chr22",          "data/genomic/na12878/na12878.chr22.lean.mapped.bam"),
    ("wes",            "data/genomic/na12878_wes/na12878_wes.chr22.bam"),
    ("hg002_illumina", "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"),
    ("hg002_pacbio",   "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"),
]

pytestmark = [
    pytest.mark.skipif(not _HAVE_NATIVE_LIB, reason="V4 needs libttio_rans"),
    pytest.mark.skipif(not HTS_BIN.exists(), reason="htscodecs CLI not built"),
    pytest.mark.integration,
]


def _strip_m94z_v4_header(blob: bytes) -> bytes:
    """Return the inner CRAM body from an M94.Z V4 stream."""
    assert blob[:4] == b"M94Z" and blob[4] == 4
    rlt_len = struct.unpack_from("<I", blob, 22)[0]
    body_len_off = 26 + rlt_len
    body_len = struct.unpack_from("<I", blob, body_len_off)[0]
    body_off = body_len_off + 4
    return blob[body_off:body_off + body_len]


@pytest.mark.parametrize("name,bam_rel", CORPORA)
def test_v4_byte_exact_vs_htscodecs(tmp_path, name, bam_rel):
    bam = REPO / bam_rel
    if not bam.exists():
        pytest.skip(f"corpus not present: {bam}")

    run = BamReader(str(bam)).to_genomic_run(name="run")
    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp = [int(f) for f in run.flags]

    # Our encoder
    v4_blob = encode(qualities, read_lengths, revcomp, prefer_v4=True)
    our_body = _strip_m94z_v4_header(v4_blob)
    our_path = tmp_path / f"our_{name}.fqz"
    our_path.write_bytes(our_body)

    # htscodecs encoder (auto-tune)
    qual_path = tmp_path / f"{name}_qual.bin"
    qual_path.write_bytes(qualities)
    hts_path = tmp_path / f"htscodecs_{name}.fqz"
    subprocess.run(
        [str(HTS_BIN), str(qual_path), str(hts_path)],
        check=True, capture_output=True,
    )
    hts_body = hts_path.read_bytes()

    assert our_body == hts_body, (
        f"{name}: our={len(our_body)} htscodecs={len(hts_body)}; "
        f"first divergent byte at {next((i for i in range(min(len(our_body), len(hts_body))) if our_body[i] != hts_body[i]), -1)}"
    )
```

- [ ] **Step 2: Run the integration test**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" python/tests/integration/test_m94z_v4_byte_exact.py && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_m94z_v4_byte_exact.py -x -v 2>&1 | tail -15'
```

Expected: 4 parametrized cases, all PASS. Each case prints the corpus name + the 2 file sizes if they differ.

If any case fails:
- The C-level byte-equality (Phase 3) passed but the Python-level didn't → the V4 outer header wrapping is corrupting bytes somehow (unlikely, but possible in `m94z_v4_wire.c` pack code).
- Or the BamReader-extracted qualities differ from the raw FASTQ-level qualities htscodecs sees → check that `qualities` matches across both paths.

- [ ] **Step 3: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/tests/integration/test_m94z_v4_byte_exact.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L2.X V4): cross-corpus byte-exact integration test

Phase 5 gate: end-to-end Python encode produces a V4 stream whose
inner CRAM body byte-equals htscodecs CLI output across all 4
corpora (chr22 + WES + HG002 Illumina + HG002 PacBio HiFi).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 14: Generate Stage 2 results doc

**Files:**
- Create: `docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md`

- [ ] **Step 1: Run V4 across all 4 corpora and capture B/qual + sizes**

Reuse `tools/perf/m94z_v4_prototype/harness.py` (the Stage 1 multi-corpus harness) but with V4 set as the encoder. Add a small wrapper or just edit the harness invocation to call `encode(prefer_v4=True)` instead of going through the candidate functions.

For pragmatism: write a small one-off script `tools/perf/m94z_v4_prototype/run_v4_final.py` that:

1. For each of the 4 corpora, loads BAM + extracts qualities via `BamReader`.
2. Calls `encode(qualities, read_lengths, revcomp, prefer_v4=True)`.
3. Strips the V4 header and reports inner-body size + B/qual.
4. Compares to htscodecs CLI output (already byte-equal from Task 13 but the script also reports the absolute B/qual).
5. Captures the auto-tuned strategy index per corpus.

Run:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m tools.perf.m94z_v4_prototype.run_v4_final 2>&1 | tee /tmp/v4_final.log'
```

- [ ] **Step 2: Write the results doc**

Create `docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md`:

```markdown
# M94.Z V4 — Stage 2 final results

CRAM 3.1 fqzcomp port. Byte-equal htscodecs across all 4 corpora.

- Date: 2026-05-02
- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage2-design.md`
- Plan: `docs/superpowers/plans/2026-05-02-l2x-m94z-richer-context-stage2.md`
- Phase 0 outcome (PacBio HiFi sanity check): see results below
- htscodecs commit SHA: <FILL>

## Per-corpus compression

| Corpus | n_qualities | V3 best (Stage 1) | V4 (this) | V4 vs V3 | Auto-tuned strategy |
|---|---:|---:|---:|---:|---|
| chr22 NA12878 | 178,409,733 | 64.24 MB / 0.358 B/qual | <FILL> | <FILL> | <FILL> |
| NA12878 WES | 95,035,281 | 25.85 MB / 0.272 B/qual | <FILL> | <FILL> | <FILL> |
| HG002 Illumina 2×250 | 248,184,765 | 64.16 MB / 0.259 B/qual | <FILL> | <FILL> | <FILL> |
| HG002 PacBio HiFi | 264,190,341 | 109.68 MB / 0.415 B/qual | <FILL> | <FILL> | <FILL> |

## Byte-equality with htscodecs

All 4 corpora pass byte-equality with htscodecs CLI (auto-tune mode):

- Phase 3 native test: `test_fqzcomp_qual_autotune` (4 corpora)
- Phase 5 Python integration test: `python/tests/integration/test_m94z_v4_byte_exact.py` (4 corpora)

## Encode wall

| Corpus | V3 wall | V4 wall (with auto-tune) |
|---|---:|---:|
| chr22 | 25.83 s | <FILL> |
| ... | | |

## Phase 0 PacBio HiFi outcome

<COPY FROM /tmp/p0_outcome.md>

## Reproducing this report

[Reproduction commands from Stage 1 results doc, with V4 path
substituted]
```

Replace `<FILL>` with values from `/tmp/v4_final.log`.

- [ ] **Step 3: Strip CRLF + commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md tools/perf/m94z_v4_prototype/run_v4_final.py && git add docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md tools/perf/m94z_v4_prototype/run_v4_final.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs(L2.X V4): Stage 2 results doc — cross-corpus byte-equality + B/qual

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 15: Update `docs/codecs/fqzcomp_nx16_z.md` + WORKPLAN + memory

**Files:**
- Modify: `docs/codecs/fqzcomp_nx16_z.md` — V4 wire format documentation
- Modify: `WORKPLAN.md` — Task #84 Stage 2 outcome

- [ ] **Step 1: Update `docs/codecs/fqzcomp_nx16_z.md`**

Add a new section after the V3 wire-format section:

```markdown
### M94.Z V4 wire format (Stage 2 / 2026-05-02)

V4 replaces V3's bit-pack adaptive context model with a CRAM 3.1
fqzcomp_qual byte-compatible port. The outer M94.Z header preserves
V3's framing pattern; the inner body is a CRAM-byte-compatible blob.

[Full wire format from spec §4]

V4 is the default encoded format when `_HAVE_NATIVE_LIB`; V3 stays
as the no-native-lib fallback and read-compat path for legacy files.

V4 byte-equality with htscodecs is guaranteed across all 4
benchmark corpora (chr22 NA12878 + WES NA12878 + HG002 Illumina 2×250
+ HG002 PacBio HiFi). See
`docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md`.
```

- [ ] **Step 2: Update WORKPLAN.md**

Find the Task #84 entry. Replace the "Stage 1 done" block with a "Stage 1 + Stage 2 done" block listing the V4 outcomes per corpus. Mark Java/ObjC as Stage 3 follow-up.

- [ ] **Step 3: Update project memory**

Edit `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\project_tti_o_v1_2_codecs.md`:

- Update description frontmatter to reference V4 + Stage 2 done
- Add a new "Status (2026-05-02 evening) — Task #84 Stage 2 V4 shipped" section with the per-corpus B/qual numbers and the byte-equality status
- Update `MEMORY.md` index entry

- [ ] **Step 4: Strip CRLF + commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $"s/\r$//" docs/codecs/fqzcomp_nx16_z.md WORKPLAN.md && git add docs/codecs/fqzcomp_nx16_z.md WORKPLAN.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs: V4 wire format + WORKPLAN Stage 2 done

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

- [ ] **Step 5: Push everything to origin**

```bash
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push origin main 2>&1 | tail -3
```

Expected: push succeeds; HEAD on `origin/main` is the WORKPLAN-update commit.

---

## Out of scope (this plan)

- Java JNI wrapper (Stage 3, separate spec/plan)
- ObjC direct-linkage wrapper (Stage 3)
- ONT platform corpus validation (no source data with QUAL preserved)
- V3 deprecation / removal (separate minor release after V4 soak)
- CRAM `.cram` container compatibility
- htscodecs runtime dependency (we link only at test time)

## Notes for the implementer

- **Byte-equality is the hard constraint, everywhere.** If a phase gate
  fails, do NOT skip ahead. The phased structure exists specifically
  because the failure modes (renorm threshold, parameter encoding,
  auto-tune strategy selection) are easier to debug at the smallest
  unit that fails than after compounded across phases.
- **The htscodecs source IS the spec.** Where this plan and htscodecs
  disagree, htscodecs wins. Read `tools/perf/htscodecs/htscodecs/fqzcomp_qual.c`
  side-by-side with our port during Phases 1-3.
- **Always use absolute lib paths.** `$PWD` is unreliable inside
  `wsl -d Ubuntu -- bash -c '...'` per `feedback_pwd_mangling_in_nested_wsl`.
- **Strip CRLF after every Python/C edit through `\\wsl.localhost\\…`.**
  Per `feedback_crlf_on_wsl_clones`.
- **The Stage 1 prototype directory `tools/perf/m94z_v4_prototype/`
  stays intact.** It's research code; don't rewrite it. Add new
  V4-specific scripts (extract_chr22_inputs.py, run_v4_final.py) but
  don't touch the candidate functions.
- **The htscodecs vendoring (`tools/perf/htscodecs/`) is gitignored
  and test-time only.** Never link it from `libttio_rans` shipped
  binaries. The runtime dependency surface stays exactly what it is
  for V3 (zlib + libc).
