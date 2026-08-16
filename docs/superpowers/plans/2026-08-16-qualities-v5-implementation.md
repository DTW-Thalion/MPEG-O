# Qualities V5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sequence-context strategies S5/S6 for the qualities channel (codec id 12): a V5 M94.Z stream flavor emitted only when it beats V4 by exact size, wired through the shared native kernel and all three language wrappers.

**Architecture:** One new native body coder (`fqzcomp_seqctx.c`) reusing the existing `sm_model` + CRAM range coder, a V5 outer-wire pack/unpack beside the V4 one, and an umbrella `ttio_m94z_qual_encode/decode` that auto-tunes across V4 presets 0-4 plus S5/S6 and keeps the smallest stream. Wrappers add an optional sequences argument; readers hand decoded sequence bytes to codec 12 lazily.

**Tech Stack:** C (libttio_rans, CMake tests), Python ctypes, Java JNI, ObjC direct link. All three wrappers call the same C, so encoder output is byte-identical across languages.

**Spec:** `docs/superpowers/specs/2026-08-16-qualities-v5-design.md`

## Global Constraints

- No AI attribution anywhere: commit messages, comments, PR text (account rule; the pre-commit style gate also rejects em dashes in commit messages — repo docs may use them, messages may not).
- Strategy parameters, verbatim from spec §2: S5 = qbits 6, qshift 5, pbits 7, pshift 0, sbits 5; S6 = qbits 8, qshift 5, pbits 4, pshift 0, sbits 6. Both 18 context bits.
- V5 body layout, spec §2.1: `param_version=1, strategy_id, qbits, qshift, pbits, pshift, sbits, reserved=0` (8 bytes) then the range-coded stream. Decoders read the explicit fields, never a preset table.
- V5 outer header: M94.Z header with `version=5`, flags bit 0 (`has_cram_body`) = 0, flags bit 1 (`has_seqctx_body`) = 1; pad_count bits 4-5 and the deflated RLT unchanged from V4.
- Auto-tune skips S5/S6 when `n_qualities < (1u<<20)` (spec §6.2, approved) or when sequences are absent/length-mismatched.
- `bcode`: A/a=0, C/c=1, G/g=2, T/t=3, everything else 0. `seqctx` rolls BEFORE coding q_i (window includes the current base). `pos = MIN((1<<pbits)-1, (len-1-i) >> pshift)`. No delta field.
- `native/src/ttio_rans_jni.c` and `python/_native/src/ttio_rans_jni.c` are two copies of the JNI shim; every shim change lands in BOTH.
- ObjC codec-availability probes use `+initialize`, never `dispatch_once`.
- Every language's tests include a file-level .tio round-trip, not only codec-level unit tests (the #285 lesson).
- Run suites in this order when cross-language tests are involved: build objc (`objc/build.sh`) and java (`mvn -q package -DskipTests`) BEFORE the python suite.
- Reference implementation of the model loop: `tools/perf/m94z_v4_prototype/fqzcomp_seqctx_ref.c` (throwaway, but its encode loop is the measured, round-trip-verified behavior the production coder must reproduce).

---

### Task 1: Native V5 body coder

**Files:**
- Create: `native/src/fqzcomp_seqctx.h`
- Create: `native/src/fqzcomp_seqctx.c`
- Test: `native/tests/test_fqzcomp_seqctx.c`
- Modify: `native/CMakeLists.txt` (add source + test target, same pattern as `test_fqzcomp_qual_strategy1` around line 176)

**Interfaces:**
- Consumes: `sm_model` / `sm_init` / `sm_destroy` / the sm encode+decode helpers and the CRAM range coder from `native/src/fqzcomp_qual.c` + `native/src/rc_cram.h`. The sm helpers are `static` in fqzcomp_qual.c today: move the sm_* block (struct + functions, lines ~130-330) into a new shared header `native/src/sm_model.h` as `static inline`, include it from both files, and delete the originals. No behavior change; the existing fqzcomp tests gate this.
- Produces:

```c
/* fqzcomp_seqctx.h */
typedef struct ttio_seqctx_param {
    uint8_t strategy_id;   /* 5 or 6 */
    uint8_t qbits, qshift, pbits, pshift, sbits;
} ttio_seqctx_param;

extern const ttio_seqctx_param TTIO_SEQCTX_S5;   /* {5, 6,5,7,0,5} */
extern const ttio_seqctx_param TTIO_SEQCTX_S6;   /* {6, 8,5,4,0,6} */

#define TTIO_SEQCTX_ERR_ARGS      (-1)
#define TTIO_SEQCTX_ERR_OOM      (-2)
#define TTIO_SEQCTX_ERR_CORRUPT  (-3)
#define TTIO_SEQCTX_ERR_NO_SEQ   (-30)
#define TTIO_SEQCTX_ERR_PARAM    (-31)

/* Body = 8-byte param block + RC stream (spec 2.1). seq_in must be
 * n_qualities bytes. out_len: capacity in, bytes written out. */
int ttio_fqz_seqctx_compress(
    const uint8_t *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t *seq_in,
    const ttio_seqctx_param *pm,
    uint8_t *out, size_t *out_len);

/* seq_in == NULL returns TTIO_SEQCTX_ERR_NO_SEQ. */
int ttio_fqz_seqctx_uncompress(
    const uint8_t *in, size_t in_len,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t *seq_in,
    uint8_t *out, size_t n_qualities);
```

- [ ] **Step 1: Extract `sm_model` into `native/src/sm_model.h`**

Move the vendored simple-model block from `fqzcomp_qual.c` (the `sm_symfreq`/`sm_model` structs and every `sm_*` function, including `SM_MAX_FREQ`/`SM_STEP` defines) into the new header verbatim, mark the functions `static inline`, include it from `fqzcomp_qual.c`.

- [ ] **Step 2: Rebuild native and run the existing fqzcomp tests**

Run: `cd native/_build && cmake --build . -j && ctest -R fqzcomp --output-on-failure`
Expected: all pass (pure code motion). Do not trust a silent ctest run; the `--output-on-failure` flag prints nothing for passes, so check the summary line says `100% tests passed`.

- [ ] **Step 3: Write the failing round-trip test**

`native/tests/test_fqzcomp_seqctx.c`, using the same bare-main + counter pattern as `native/tests/test_fqzcomp_qual_strategy1.c`:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "../src/fqzcomp_seqctx.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

/* xorshift64 so inputs are deterministic without srand */
static uint64_t xs(uint64_t *s) {
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}

/* Motif-correlated synthetic: base drawn from ACGTN, quality depends
 * on the base so sequence context is causal. */
static void make_corpus(uint8_t *qual, uint8_t *seq, uint32_t *lens,
                        size_t n_reads, uint32_t len) {
    static const uint8_t B[5] = {'A','C','G','T','N'};
    uint64_t s = 42;
    size_t k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        lens[r] = len;
        for (uint32_t i = 0; i < len; i++, k++) {
            uint8_t b = B[xs(&s) % 5];
            seq[k] = b;
            qual[k] = (uint8_t)(33 + (b == 'G' ? 8 : 30) + (xs(&s) % 8));
        }
    }
}

int main(void) {
    enum { NR = 300, LEN = 100, N = NR * LEN };
    uint8_t *qual = malloc(N), *seq = malloc(N), *back = malloc(N);
    uint32_t *lens = malloc(NR * sizeof(*lens));
    make_corpus(qual, seq, lens, NR, LEN);

    uint8_t *out = malloc(N + (1 << 16));
    size_t out_len = N + (1 << 16);
    int rc = ttio_fqz_seqctx_compress(qual, N, lens, NR, seq,
                                      &TTIO_SEQCTX_S5, out, &out_len);
    CHECK(rc == 0, "S5 compress rc");
    CHECK(out_len > 8 && out_len < N, "S5 output smaller than input");
    CHECK(out[0] == 1 && out[1] == 5 && out[2] == 6 && out[3] == 5
          && out[4] == 7 && out[5] == 0 && out[6] == 5 && out[7] == 0,
          "S5 param block bytes");

    memset(back, 0, N);
    rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, seq, back, N);
    CHECK(rc == 0, "S5 uncompress rc");
    CHECK(memcmp(back, qual, N) == 0, "S5 round trip bit-exact");

    out_len = N + (1 << 16);
    rc = ttio_fqz_seqctx_compress(qual, N, lens, NR, seq,
                                  &TTIO_SEQCTX_S6, out, &out_len);
    CHECK(rc == 0, "S6 compress rc");
    memset(back, 0, N);
    rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, seq, back, N);
    CHECK(rc == 0 && memcmp(back, qual, N) == 0, "S6 round trip");

    rc = ttio_fqz_seqctx_uncompress(out, out_len, lens, NR, NULL, back, N);
    CHECK(rc == TTIO_SEQCTX_ERR_NO_SEQ, "NULL seq rejected");

    rc = ttio_fqz_seqctx_uncompress(out, 4, lens, NR, seq, back, N);
    CHECK(rc == TTIO_SEQCTX_ERR_CORRUPT, "truncated body rejected");

    /* edge battery */
    uint32_t l1[1] = {1};
    uint8_t q1 = 70, s1 = 'N', b1 = 0;
    out_len = 1 << 16;
    rc = ttio_fqz_seqctx_compress(&q1, 1, l1, 1, &s1,
                                  &TTIO_SEQCTX_S5, out, &out_len);
    CHECK(rc == 0, "single N-base read compresses");
    rc = ttio_fqz_seqctx_uncompress(out, out_len, l1, 1, &s1, &b1, 1);
    CHECK(rc == 0 && b1 == 70, "single read round trips");

    out_len = 1 << 16;
    rc = ttio_fqz_seqctx_compress(NULL, 0, NULL, 0, NULL,
                                  &TTIO_SEQCTX_S5, out, &out_len);
    CHECK(rc == 0 && out_len == 8, "empty input yields bare param block");

    printf("%s: %d failures\n", __FILE__, failures);
    return failures ? 1 : 0;
}
```

Also cover lowercase bases and a 93-value HiFi-like alphabet in two further blocks of the same shape: lowercase `acgt` sequences must round-trip identically to their uppercase twins' sizes (same bcode), and a corpus with qualities spanning 33..126 must round-trip bit-exactly.

- [ ] **Step 4: Register the test in CMake and verify it fails to build**

Add to `native/CMakeLists.txt` (mirror the `test_roundtrip` block):

```cmake
add_executable(test_fqzcomp_seqctx tests/test_fqzcomp_seqctx.c)
target_link_libraries(test_fqzcomp_seqctx ttio_rans)
target_compile_options(test_fqzcomp_seqctx PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME fqzcomp_seqctx COMMAND test_fqzcomp_seqctx)
```

Run: `cd native/_build && cmake .. && cmake --build . -j 2>&1 | tail -5`
Expected: link failure, `ttio_fqz_seqctx_compress` undefined.

- [ ] **Step 5: Implement `fqzcomp_seqctx.c`**

The coding loop is the prototype's `code_pass` restated over `sm_model`:
allocate `(size_t)1 << (qbits+pbits+sbits)` models (`sm_init(m, 256, 256)`
each), heap-allocated as one array; walk reads exactly as the prototype
does (qctx/seqctx/pos as in Global Constraints; qctx and seqctx reset to
0 at each read start); encode with the CRAM range coder from `rc_cram.h`
(same RC functions `fqzcomp_qual.c` uses). Validate parameters first:
`qbits+pbits+sbits <= 18`, `sbits >= 2`, `qshift <= 8`, else
`TTIO_SEQCTX_ERR_PARAM`. Emit the 8-byte param block before RC output;
uncompress parses it, validates `param_version == 1` and the same bounds,
and requires `seq_in != NULL`. `sum(read_lengths) != n_qualities` is
`TTIO_SEQCTX_ERR_ARGS` on both sides. Free the model array on every path.

- [ ] **Step 6: Build and run the test until green**

Run: `cd native/_build && cmake --build . -j && ./test_fqzcomp_seqctx`
Expected: `0 failures` printed (run the binary directly; do not rely on the ctest exit path alone).

- [ ] **Step 7: Run the whole native suite**

Run: `cd native/_build && ctest --output-on-failure 2>&1 | tail -3`
Expected: `100% tests passed`.

- [ ] **Step 8: Commit**

```bash
git add native/src/sm_model.h native/src/fqzcomp_qual.c \
        native/src/fqzcomp_seqctx.h native/src/fqzcomp_seqctx.c \
        native/tests/test_fqzcomp_seqctx.c native/CMakeLists.txt
git commit -m "feat(native): V5 sequence-context qualities body coder"
```

### Task 2: V5 wire + umbrella encode/decode with exact-size pick

**Files:**
- Modify: `native/src/m94z_v4_wire.h`, `native/src/m94z_v4_wire.c` (V5 pack/unpack beside V4's)
- Create: `native/src/m94z_qual.c` (umbrella)
- Modify: `native/include/ttio_rans.h` (public declarations, next to `ttio_m94z_v4_encode` at line ~263)
- Test: `native/tests/test_m94z_qual_umbrella.c` (+ CMake block as in Task 1)

**Interfaces:**
- Consumes: `ttio_m94z_v4_pack/unpack`, `ttio_m94z_v4_encode/decode`, `ttio_fqz_seqctx_compress/uncompress`, `TTIO_SEQCTX_S5/S6` (Task 1).
- Produces (in `ttio_rans.h`):

```c
#define TTIO_M94Z_V5_VERSION 5
#define TTIO_M94Z_V5_MIN_QUALITIES (1u << 20)

/* V5 outer wire: same header fields as V4, version=5, flags bit1 set,
 * body = seqctx body. Same signatures as the v4 pair with cram_body
 * renamed body. */
int ttio_m94z_v5_pack(uint64_t num_qualities, uint64_t num_reads,
    const uint32_t *read_lengths, uint8_t pad_count,
    const uint8_t *body, size_t body_len,
    uint8_t *out, size_t *out_len);
int ttio_m94z_v5_unpack(const uint8_t *in, size_t in_len,
    uint64_t *out_num_qualities, uint64_t *out_num_reads,
    uint32_t *out_read_lengths, uint8_t *out_pad_count,
    const uint8_t **out_body, size_t *out_body_len);

/* Umbrella. strategy_hint: -1 auto (V4 presets + S5/S6 when eligible),
 * 0..4 V4 preset, 5..6 forced sequence strategy (error without seq_in).
 * seq_in NULL or length != n_qualities disables S5/S6 in auto mode.
 * Auto mode also skips S5/S6 when n_qualities < TTIO_M94Z_V5_MIN_QUALITIES. */
int ttio_m94z_qual_encode(
    const uint8_t *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t *flags, const uint8_t *seq_in,
    int strategy_hint, uint8_t pad_count,
    uint8_t *out, size_t *out_len);

/* Dispatches on the version byte: 4 -> ttio_m94z_v4_decode (seq_in
 * ignored), 5 -> v5_unpack + seqctx_uncompress (seq_in required;
 * NULL -> TTIO_SEQCTX_ERR_NO_SEQ). */
int ttio_m94z_qual_decode(
    const uint8_t *in, size_t in_len,
    uint32_t *read_lengths, size_t n_reads,
    const uint8_t *flags, const uint8_t *seq_in,
    uint8_t *out_qual, size_t n_qualities);
```

- [ ] **Step 1: Write the failing test**

`native/tests/test_m94z_qual_umbrella.c`, same CHECK pattern as Task 1. Reuse Task 1's `make_corpus` (copy it in; tests are standalone binaries). Cases, each a CHECK:

1. Motif corpus, `n_qualities >= 1 MiB` (use NR=11000, LEN=100), auto hint, seq present: encode succeeds, `out[4] == 5` (version byte; header offset 4 per `m94z_v4_wire.h`), and the stream is smaller than the same call with `seq_in = NULL`.
2. The `seq_in = NULL` call emits `out[4] == 4` and its bytes are identical to a direct `ttio_m94z_v4_encode` call with the same inputs (memcmp).
3. Uniform-quality corpus (every qual byte 70, bases random): auto emits version 4 (V4 wins on flat data).
4. Small corpus (NR=300) with seq present: auto emits version 4 (below the 1 MiB floor).
5. Forced hint 5 on the small corpus emits version 5 and round-trips through `ttio_m94z_qual_decode` bit-exactly with `read_lengths` recovered from the RLT.
6. Forced hint 5 with `seq_in = NULL` returns `TTIO_SEQCTX_ERR_NO_SEQ`.
7. Decoding the version-5 stream with `seq_in = NULL` returns `TTIO_SEQCTX_ERR_NO_SEQ`; with a length-mismatched seq buffer returns `TTIO_SEQCTX_ERR_ARGS`.
8. Version-5 stream, flags bit 1 cleared by hand: unpack rejects it (corrupt).
9. V4 stream through `ttio_m94z_qual_decode` with seq_in NULL round-trips (regression: the umbrella must not disturb V4).

- [ ] **Step 2: Register in CMake, build, verify link failure**

Run: `cd native/_build && cmake .. && cmake --build . -j 2>&1 | tail -3`
Expected: `ttio_m94z_qual_encode` undefined.

- [ ] **Step 3: Implement V5 pack/unpack**

In `m94z_v4_wire.c`: `ttio_m94z_v5_pack` is `ttio_m94z_v4_pack` with `version = 5` and `flags = 0x02 | (pad_count << 4)`; factor the shared header emitter into a static helper taking the version and flags-bit rather than duplicating. `ttio_m94z_v5_unpack` validates magic, `version == 5`, flags bit 0 clear and bit 1 set.

- [ ] **Step 4: Implement the umbrella**

`m94z_qual.c`: encode runs `ttio_m94z_v4_encode` (same hint pass-through for 0..4 and -1) into a scratch buffer, then, when eligible (auto + seq + floor, or forced 5/6), runs `ttio_fqz_seqctx_compress` for each eligible strategy into a second scratch, packs with `ttio_m94z_v5_pack`, and copies the smallest into `out`. Scratch buffers are heap-allocated at `*out_len` capacity and freed on all paths. Ties go to V4 (compatibility wins at equal size). Decode reads byte 4 and dispatches.

- [ ] **Step 5: Build and run until green, then whole native suite**

Run: `cd native/_build && cmake --build . -j && ./test_m94z_qual_umbrella && ctest --output-on-failure 2>&1 | tail -3`
Expected: `0 failures`, `100% tests passed`.

- [ ] **Step 6: Commit**

```bash
git add native/src/m94z_v4_wire.h native/src/m94z_v4_wire.c \
        native/src/m94z_qual.c native/include/ttio_rans.h \
        native/tests/test_m94z_qual_umbrella.c native/CMakeLists.txt
git commit -m "feat(native): M94.Z V5 wire + exact-size qualities strategy pick"
```

### Task 3: Python wrapper, registry, writer/reader wiring, golden fixture

**Files:**
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py` (bind the umbrella; `encode` line ~535, `decode_with_metadata` line ~623)
- Modify: `python/src/ttio/codecs/_context.py` (CodecContext field)
- Modify: `python/src/ttio/codecs/_registry.py` (`_FqzcompNx16ZCodec` lines ~92-116)
- Modify: `python/src/ttio/genomic_run.py` (ctx build, line ~405)
- Modify: `python/src/ttio/written_genomic_run.py` (opt flag, next to `signal_compression` line ~88)
- Modify: `python/src/ttio/_dataset_write_genomic.py` (qualities encode block, lines ~340-365)
- Create: `python/tests/fixtures/codecs/qualities_v5_golden.bin`, `qualities_v5_golden_seq.bin`, `qualities_v5_golden_qual.bin` (+ generator entry in `python/tests/fixtures/generate.py`)
- Test: `python/tests/test_qualities_v5.py`

**Interfaces:**
- Consumes: `ttio_m94z_qual_encode/decode` via ctypes (bind exactly as the `ttio_m94z_v4_*` bindings in `fqzcomp_nx16_z.py` are bound today, adding one `POINTER(c_uint8)` seq argument; NULL is `None`).
- Produces:
  - `fqzcomp_nx16_z.encode(qualities, read_lengths, revcomp_flags, *, v4_strategy_hint=-1, sequences: bytes | None = None, ...)` (existing keyword args unchanged)
  - `fqzcomp_nx16_z.decode_with_metadata(encoded, revcomp_flags, sequences_provider: "Callable[[], bytes] | None" = None)` returning the existing tuple
  - `CodecContext.sequences_provider: "Callable[[], bytes] | None" = None`
  - `WrittenGenomicRun.opt_disable_qualities_v5: bool = False`

- [ ] **Step 1: Write the failing tests**

`python/tests/test_qualities_v5.py`:

```python
"""Qualities V5 (sequence-context) — wrapper dispatch, writer gate,
reader ordering, and the golden decode fixture."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import fqzcomp_nx16_z as fz

FIXDIR = Path(__file__).parent / "fixtures" / "codecs"


def _motif_corpus(n_reads=11000, length=100):
    rng = np.random.default_rng(7)
    bases = np.frombuffer(b"ACGTN", dtype=np.uint8)
    seq = bases[rng.integers(0, 5, n_reads * length)]
    qual = np.where(seq == ord("G"),
                    41 + rng.integers(0, 8, seq.shape[0]),
                    63 + rng.integers(0, 8, seq.shape[0])).astype(np.uint8)
    lens = [length] * n_reads
    flags = [0] * n_reads
    return bytes(qual), bytes(seq), lens, flags


class TestWrapper:
    def test_v5_emitted_and_smaller(self):
        qual, seq, lens, flags = _motif_corpus()
        v4 = fz.encode(qual, lens, flags)
        v5 = fz.encode(qual, lens, flags, sequences=seq)
        assert v4[4] == 4
        assert v5[4] == 5
        assert len(v5) < len(v4)

    def test_no_sequences_is_byte_identical_v4(self):
        qual, _seq, lens, flags = _motif_corpus(n_reads=2000)
        assert fz.encode(qual, lens, flags) == \
            fz.encode(qual, lens, flags, sequences=None)

    def test_v5_round_trips(self):
        qual, seq, lens, flags = _motif_corpus()
        blob = fz.encode(qual, lens, flags, sequences=seq)
        back, back_lens, _rc = fz.decode_with_metadata(
            blob, flags, sequences_provider=lambda: seq)
        assert bytes(back) == qual
        assert list(back_lens) == lens

    def test_v5_decode_without_sequences_raises(self):
        qual, seq, lens, flags = _motif_corpus()
        blob = fz.encode(qual, lens, flags, sequences=seq)
        assert blob[4] == 5
        with pytest.raises(ValueError, match="sequences"):
            fz.decode_with_metadata(blob, flags)

    def test_small_channel_stays_v4(self):
        qual, seq, lens, flags = _motif_corpus(n_reads=300)
        assert fz.encode(qual, lens, flags, sequences=seq)[4] == 4


class TestGolden:
    def test_golden_decodes(self):
        blob = (FIXDIR / "qualities_v5_golden.bin").read_bytes()
        seq = (FIXDIR / "qualities_v5_golden_seq.bin").read_bytes()
        expected = (FIXDIR / "qualities_v5_golden_qual.bin").read_bytes()
        n_reads = 300
        back, lens, _rc = fz.decode_with_metadata(
            blob, [0] * n_reads, sequences_provider=lambda: seq)
        assert bytes(back) == expected


class TestFileLevel:
    def _run(self, tmp_path, *, disable=False, n_reads=11000):
        from ttio import SpectralDataset
        from ttio.written_genomic_run import WrittenGenomicRun
        qual, seq, lens, flags = _motif_corpus(n_reads=n_reads)
        run = WrittenGenomicRun(
            read_names=[f"r{i}" for i in range(n_reads)],
            sequences=np.frombuffer(seq, dtype=np.uint8),
            qualities=np.frombuffer(qual, dtype=np.uint8),
            lengths=np.asarray(lens, dtype=np.uint32),
            flags=np.asarray(flags, dtype=np.uint32),
            positions=np.zeros(n_reads, dtype=np.int64),
            mapping_qualities=np.zeros(n_reads, dtype=np.uint8),
            cigars=["100M"] * n_reads,
            reference_uri="", reference_md5=b"\0" * 16,
            mate_chromosomes=[], mate_positions=np.zeros(0, dtype=np.int64),
            template_lengths=np.zeros(0, dtype=np.int32),
            chromosomes=["chr1"] * n_reads,
            opt_disable_qualities_v5=disable,
        )
        p = tmp_path / "v5.tio"
        SpectralDataset.write_minimal(
            p, title="v5", isa_investigation_id="V5",
            runs={"g": run})
        return p, qual

    def test_file_round_trip_v5(self, tmp_path):
        from ttio import SpectralDataset
        import h5py
        p, qual = self._run(tmp_path)
        with h5py.File(p, "r") as f:
            blob = bytes(
                f["/study/genomic_runs/g/signal_channels/qualities"][()])
            assert blob[4] == 5
        with SpectralDataset.open(p) as ds:
            run = ds.genomic_runs["g"]
            got = b"".join(run[i].qualities for i in range(3))
            assert got == qual[:300]

    def test_opt_disable_stays_v4(self, tmp_path):
        import h5py
        p, _ = self._run(tmp_path, disable=True)
        with h5py.File(p, "r") as f:
            blob = bytes(
                f["/study/genomic_runs/g/signal_channels/qualities"][()])
            assert blob[4] == 4
```

Adjust the `WrittenGenomicRun` constructor call to the dataclass's actual required fields (read them from `python/src/ttio/written_genomic_run.py`; the test above lists the semantic content, and `test_m82_genomic_run.py` has a working construction to copy). Same for the per-read qualities accessor (`run[i].qualities` per `aligned_read.py`).

- [ ] **Step 2: Run and verify failures**

Run: `.venv/bin/python -m pytest python/tests/test_qualities_v5.py -x -q`
Expected: FAIL, `encode() got an unexpected keyword argument 'sequences'`.

- [ ] **Step 3: Bind the umbrella and extend the wrapper**

In `fqzcomp_nx16_z.py`: bind `ttio_m94z_qual_encode`/`ttio_m94z_qual_decode` next to the existing v4 bindings (same argtypes plus one seq pointer). `encode(..., sequences=None)` validates `len(sequences) == len(qualities)` when given (raise `ValueError`), then calls the umbrella with seq or NULL. `decode_with_metadata` peeks `encoded[4]`; on 5 it requires `sequences_provider` (else `ValueError("... V5 stream requires sequences ...")`), materializes the bytes once, validates the length against the header's `num_qualities`, and calls the umbrella decode. Version 4 path is unchanged and must not call the provider.

- [ ] **Step 4: Registry + reader + writer wiring**

- `_context.py`: add `sequences_provider: "Callable[[], bytes] | None" = None` with a comment naming codec 12 V5 as its consumer.
- `_registry.py` `_FqzcompNx16ZCodec.decode`: pass `sequences_provider=ctx.sequences_provider`. `encode`: pass `sequences=ctx.sequences` — add the twin encode-only field `sequences: "bytes | None" = None` to `CodecContext` as well (mirrors the ref_diff encode-only fields).
- `genomic_run.py` ctx build (~line 405): add `sequences_provider=lambda: self._decoded_channel_bytes("sequences")` where `_decoded_channel_bytes` is whatever helper the decode-once cache exposes; if only `_byte_channel_slice` exists, add a small `_whole_channel_bytes(name)` next to it that returns the cached full channel.
- `_dataset_write_genomic.py` qualities block (~line 351): build the ctx with `sequences=bytes(np.asarray(run.sequences, dtype=np.uint8).tobytes())` when `not run.opt_disable_qualities_v5` and the length matches `len(qualities)`, else `sequences=None`.
- `written_genomic_run.py`: add field + docstring naming the Java/ObjC twins:

```python
    # Removes the V5 sequence-context strategies from the qualities
    # auto-tune set (spec 2.4). Java/ObjC: optDisableQualitiesV5.
    opt_disable_qualities_v5: bool = False
```

- [ ] **Step 5: Generate the golden fixture**

Add to `python/tests/fixtures/generate.py` (follow the file's existing entry pattern) a `qualities_v5` entry that builds the 300-read motif corpus with the same constants as `TestGolden` (seed 7, 100 bp — small is fine for a fixture; force V5 with `v4_strategy_hint=5`) and writes the three files. Run the generator, then run `TestGolden` and verify it passes. Record the three files in `python/tests/fixtures/checksums.json` if the generator maintains it (read the generator's convention).

- [ ] **Step 6: Full test file green, then the python suite**

Run: `.venv/bin/python -m pytest python/tests/test_qualities_v5.py -q`
Expected: all pass.
Run: `.venv/bin/python -m pytest python/tests -q -p no:cacheprovider 2>&1 | tail -3`
Expected: 0 failures (existing V4 tests must be untouched: byte-identical V4 emission is a hard requirement).

- [ ] **Step 7: Commit**

```bash
git add python/src/ttio python/tests/test_qualities_v5.py \
        python/tests/fixtures/codecs/qualities_v5_golden*.bin \
        python/tests/fixtures/generate.py python/tests/fixtures/checksums.json
git commit -m "feat(python): qualities V5 wiring, writer gate, golden fixture"
```

### Task 4: Java wrapper, registry, writer/reader, tests

**Files:**
- Modify: `native/src/ttio_rans_jni.c` AND `python/_native/src/ttio_rans_jni.c` (new JNI pair beside the V4 bindings at line ~386)
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
- Modify: `java/src/main/java/global/thalion/ttio/codecs/registry/CodecContext.java` (+ its Builder)
- Modify: `java/src/main/java/global/thalion/ttio/codecs/registry/CodecRegistry.java` (codec-12 entry, lines ~100-113)
- Modify: `java/src/main/java/global/thalion/ttio/genomics/WrittenGenomicRun.java` (opt flag)
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDatasetGenomicWriter.java` (qualities encode ctx)
- Modify: the Java genomic read path that builds the decode `CodecContext` (find with `grep -rn "CodecContext.builder" java/src/main/java`)
- Test: `java/src/test/java/global/thalion/ttio/codecs/QualitiesV5Test.java`
- Copy: the three golden fixture files into `java/src/test/resources/ttio/fixtures/`

**Interfaces:**
- Consumes: `ttio_m94z_qual_encode/decode` (Task 2), fixture files (Task 3).
- Produces:
  - `FqzcompNx16Z.encode(byte[] qualities, int[] readLengths, int[] revcompFlags, byte[] sequences)` (sequences nullable; existing 3-arg overload delegates with null)
  - `FqzcompNx16Z.decode(byte[] encoded, int[] revcompFlags, java.util.function.Supplier<byte[]> sequencesProvider)` returning the existing `DecodeResult` (existing 2-arg overload delegates with null; a V5 stream with a null provider throws `IllegalStateException` naming sequences)
  - `CodecContext.sequences()` (encode-only, byte[]) and `CodecContext.sequencesProvider()` (decode, `Supplier<byte[]>`), both nullable, via new record components + Builder setters — update every existing `new CodecContext(...)` positional construction to the Builder if any exist (grep first)
  - `WrittenGenomicRun.optDisableQualitiesV5` (boolean field, setter `setOptDisableQualitiesV5`, default false)

- [ ] **Step 1: Write the failing test**

`QualitiesV5Test.java`, JUnit 5, same conventions as `FloatDeltaZstdTest`:

```java
class QualitiesV5Test {

    private static byte[][] motifCorpus(int nReads, int len) {
        byte[] bases = {'A','C','G','T','N'};
        java.util.Random r = new java.util.Random(7);
        byte[] seq = new byte[nReads * len];
        byte[] qual = new byte[nReads * len];
        for (int i = 0; i < seq.length; i++) {
            seq[i] = bases[r.nextInt(5)];
            qual[i] = (byte)((seq[i] == 'G' ? 41 : 63) + r.nextInt(8));
        }
        return new byte[][]{qual, seq};
    }

    private static int[] fill(int n, int v) {
        int[] a = new int[n]; java.util.Arrays.fill(a, v); return a;
    }

    @Test
    void v5EmittedAndSmaller() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] v4 = FqzcompNx16Z.encode(c[0], lens, flags);
        byte[] v5 = FqzcompNx16Z.encode(c[0], lens, flags, c[1]);
        assertEquals(4, v4[4]);
        assertEquals(5, v5[4]);
        assertTrue(v5.length < v4.length);
    }

    @Test
    void v5RoundTrips() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] blob = FqzcompNx16Z.encode(c[0], lens, flags, c[1]);
        var dr = FqzcompNx16Z.decode(blob, flags, () -> c[1]);
        assertArrayEquals(c[0], dr.qualities());
    }

    @Test
    void v5WithoutSequencesThrows() {
        byte[][] c = motifCorpus(11000, 100);
        int[] lens = fill(11000, 100), flags = fill(11000, 0);
        byte[] blob = FqzcompNx16Z.encode(c[0], lens, flags, c[1]);
        assertEquals(5, blob[4]);
        assertThrows(IllegalStateException.class,
            () -> FqzcompNx16Z.decode(blob, flags));
    }

    @Test
    void goldenFixtureDecodes() throws Exception {
        byte[] blob = res("/ttio/fixtures/qualities_v5_golden.bin");
        byte[] seq = res("/ttio/fixtures/qualities_v5_golden_seq.bin");
        byte[] expected = res("/ttio/fixtures/qualities_v5_golden_qual.bin");
        var dr = FqzcompNx16Z.decode(blob, fill(300, 0), () -> seq);
        assertArrayEquals(expected, dr.qualities());
    }

    private static byte[] res(String p) throws Exception {
        try (var in = QualitiesV5Test.class.getResourceAsStream(p)) {
            assertNotNull(in, p);
            return in.readAllBytes();
        }
    }
}
```

Plus a file-level test in the same class: write a genomic run through the Java writer with the motif corpus, assert the on-disk `qualities` dataset's byte 4 is 5, reopen and compare decoded qualities; repeat with `setOptDisableQualitiesV5(true)` asserting byte 4 is 4. Copy the run-construction shape from the existing Java genomic writer test (find with `grep -rln "WrittenGenomicRun" java/src/test`).

- [ ] **Step 2: Verify compile failure**

Run: `cd java && mvn -q test-compile 2>&1 | tail -5`
Expected: `cannot find symbol` for the 4-arg encode.

- [ ] **Step 3: JNI + Java implementation**

JNI (BOTH shim copies): `Java_global_thalion_ttio_codecs_FqzcompNx16Z_encodeQualNative` and `...decodeQualNative`, marshaling exactly as the V4 pair at lines ~394-540 does, with one extra nullable `jbyteArray seq` (NULL passes NULL). Rebuild the native lib and JNI (`cd native/_build && cmake --build . -j`; check how the JNI .so is built — the same CMake tree builds `libttio_rans_jni`). Java side: new overloads delegate to the native methods; on a V5 stream the 2-arg decode inspects `encoded[4]` and throws `IllegalStateException` before touching native. Registry: codec-12 `decode` passes `ctx.sequencesProvider()`, `encode` passes `ctx.sequences()`. Writer: populate `sequences` in the qualities-channel ctx when `!run.optDisableQualitiesV5()` and lengths match. Reader: populate `sequencesProvider` from the decoded sequences channel (the Java GenomicRun already decodes sequences for its own accessors; reuse that path lazily).

- [ ] **Step 4: Run the test class, then the Java suite**

Run: `cd java && mvn test -Dtest=QualitiesV5Test 2>&1 | grep -E "Tests run|BUILD"`
Expected: all pass.
Run: `cd java && mvn test 2>&1 | grep -E "Tests run: [0-9]+, Failures|BUILD" | tail -2`
Expected: 0 failures, BUILD SUCCESS. Delete `java/target/classpath.txt`, `java/target/_smoke_cp.txt`, `java/target/runtime-classpath.txt` if the pom gained any dependency (it should not).

- [ ] **Step 5: Commit**

```bash
git add native/src/ttio_rans_jni.c python/_native/src/ttio_rans_jni.c \
        java/src/main/java java/src/test
git commit -m "feat(java): qualities V5 wiring through JNI, registry, writer gate"
```

### Task 5: ObjC wrapper, registry, writer/reader, tests

**Files:**
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.h` / `.m` (read the header first; extend the existing encode/decode class methods with a `sequences:(nullable NSData *)` parameter, keeping the existing selectors as thin delegates passing nil)
- Modify: `objc/Source/Dataset/TTIOSpectralDataset+GenomicWrite.m` (qualities encode site: find with `grep -n "FqzcompNx16Z\|qualities" objc/Source/Dataset/TTIOSpectralDataset+GenomicWrite.m`)
- Modify: `objc/Source/Genomics/TTIOGenomicRun.m` (qualities decode site; hand it the decoded sequences bytes lazily)
- Modify: `objc/Source/Genomics/TTIOWrittenGenomicRun.h` / `.m` (`@property (nonatomic) BOOL optDisableQualitiesV5;`)
- Test: `objc/Tests/TestQualitiesV5.m` + registration in `objc/Tests/TTIOTestRunner.m` + `objc/Tests/GNUmakefile`
- Copy: the three golden fixture files into `objc/Tests/Fixtures/`

**Interfaces:**
- Consumes: `ttio_m94z_qual_encode/decode` (direct C calls — ObjC links libttio_rans), fixtures (Task 3).
- Produces: the extended TTIOFqzcompNx16Z selectors; `TTIOWrittenGenomicRun.optDisableQualitiesV5`; V5-aware file-level write/read.

- [ ] **Step 1: Write the failing test**

`TestQualitiesV5.m` with the `PASS(cond, "name")` convention from `TestFloatDeltaZstd.m` and a `fdzFixturePath`-style locator for `Fixtures/qualities_v5_golden.bin`. Cases: (1) codec-level motif-corpus encode with sequences emits version byte 5, smaller than the nil-sequences encode, and round-trips bit-exactly; (2) nil-sequences encode is byte-identical to the pre-change encode (compare against a V4 call through the existing selector); (3) decoding a V5 stream with nil sequences returns nil + NSError mentioning sequences; (4) the golden fixture decodes bit-exactly; (5) file-level: write a genomic run with the motif corpus through the ObjC writer, assert the on-disk qualities dataset's fifth byte is 5, reopen, compare qualities for the first 3 reads; (6) `optDisableQualitiesV5 = YES` keeps byte 5 == 4. Copy the genomic-run construction from an existing ObjC genomic test (find with `grep -rln "TTIOWrittenGenomicRun" objc/Tests`).

- [ ] **Step 2: Build and verify the compile failure**

Run: `cd objc && ./build.sh 2>&1 | grep -c "error:"`
Expected: nonzero (unknown selector / property).

- [ ] **Step 3: Implement**

Wrapper: extend the class methods; V5 decode without sequences fails with a distinct `NSError` (reuse `TTIOMakeError` with a new message naming the sequences requirement) before calling C. Writer: at the qualities encode site pass the run's sequences bytes when `!run.optDisableQualitiesV5` and the byte lengths match, else nil. Reader: `TTIOGenomicRun` qualities decode passes the decoded sequences channel; sequences decode already precedes or is triggered by the same open path — mirror how the python reader orders it, and surface a sequences-decode failure as the qualities error's underlying error.

- [ ] **Step 4: Run the ObjC suite**

Run: `cd objc && ./build.sh check 2>&1 | grep -cE "Failed test"` then `grep -c "Passed test"` on the log.
Expected: 0 failed; passed count grows by the new tests. Read the tally lines, never the exit code alone.

- [ ] **Step 5: Commit**

```bash
git add objc/Source objc/Tests
git commit -m "feat(objc): qualities V5 wiring, writer gate, golden fixture"
```

### Task 6: Cross-language conformance edge + docs + full matrix

**Files:**
- Create: `python/tests/conformance/test_qualities_v5_xlang.py` (follow `test_references_xlang.py`: python writes a motif-corpus genomic .tio, the java reader (`TtioVerify` or the harness that file already shells to) and the objc reader helper open it and report decoded qualities; assert equality with the source. Skip cells whose runtime is absent, exactly as that file does.)
- Modify: `docs/format-spec.md` (the codec-id table's id-12 row and the §10.4 id-12 bullet at line ~852: name V5, the sequence-context strategies, the encode-time gate, and the explicit-parameter body)
- Modify: `CHANGELOG.md` ([Unreleased] Added: qualities V5, with the bake-off numbers and the older-reader note for V5 files; V4-winning files unchanged)
- Modify: `docs/benchmarks/2026-08-16-qualities-v5-bakeoff.md` (status line: implemented)

- [ ] **Step 1: Write the xlang test, watch the java/objc cells fail before their wrappers exist only if executed out of order** (in-order execution: they pass; the test still gates the matrix in CI)

Run: `.venv/bin/python -m pytest python/tests/conformance/test_qualities_v5_xlang.py -q`
Expected: pass (or skip cells with missing runtimes locally; CI runs all).

- [ ] **Step 2: Docs edits** (as listed above; keep the id-12 row wording parallel to the id-17 row's default/opt-out phrasing)

- [ ] **Step 3: Full matrix in order**

Run: `cd objc && ./build.sh check` (tally: 0 failed), `cd java && mvn -q package -DskipTests && mvn test` (0 failures), `.venv/bin/python -m pytest python/tests -q -p no:cacheprovider` (0 failures), and the perf-suite qualities bench if `tools/perf` has a codec-12 bench (grep `tools/perf` for `fqzcomp`; add a V5 row mirroring the V4 one if a bench file exists, else note its absence in the PR body).

- [ ] **Step 4: Commit**

```bash
git add python/tests/conformance/test_qualities_v5_xlang.py docs CHANGELOG.md
git commit -m "test: qualities V5 cross-language conformance edge + docs"
```

### Task 7: PR

- [ ] **Step 1: Attribution + style audit on the full diff** (`git diff main | grep -inE "co-authored|generated with|claude|anthropic"` must print nothing; print the grep exit code, 1 = clean; never bury it in a `|| echo` fallback)
- [ ] **Step 2: Push via Windows git** (`"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push origin <branch>`; verify with `ls-remote`)
- [ ] **Step 3: PR body**: 5 plain paragraphs, under 200 words with title, no headings/labels/em dashes: problem (V4 leaves motif-correlated corpora 22.7% above measured reachable), fix (S5/S6 + exact-size pick + V5 wire), caveats (V5 files unreadable by older releases; V4-winning files byte-identical), test path (`python/tests/test_qualities_v5.py`, `QualitiesV5Test.java`, `objc/Tests/TestQualitiesV5.m`, the xlang edge), and the new-test fail-before/pass-after counts. Audit the LIVE body after posting with explicit grep exit codes.
