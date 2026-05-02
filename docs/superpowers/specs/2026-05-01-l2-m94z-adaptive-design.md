# L2 — M94.Z adaptive (CRAM-mimic) quality codec

**Task:** #82 Phase B.2 (L2 from `2026-05-01-chr22-byte-breakdown.md`)
**Status:** Design — math/spec proof phase per memory
                feedback `feedback_phase_0_spec_proof`
**Wire impact:** Replaces M94.Z V1/V2 entirely. Codec id 12 stays;
                 byte format changes; file-root format_version
                 1.5 → 1.6.
**Cross-language byte-exact contract:** TTI-O-internal canonical
fixtures (NOT htslib byte-equivalent). Compression target ≤ 0.25
B/qual on chr22 to hit the 1.15× CRAM ratio.

## 0. Why this spec exists

Phase B.1 (L1 + L3) closed 60% of the gap to the 1.15× CRAM target.
The remaining ~14 MB on chr22 is essentially all in the qualities
channel — current M94.Z static-per-block compresses at 0.395 B/qual,
CRAM 3.1 fqzcomp-Nx16 hits 0.20–0.25. The gap is the static-vs-adaptive
freq model, not the context model.

The current M94.Z spec at `2026-04-29-m94z-cram-mimic-design.md` §3.2
explicitly flagged this open question and recommended re-evaluation
"if compression delta vs v1.1.1 is < 5%". The actual delta is ~37%
off CRAM — well past the threshold.

This spec replaces M94.Z with the per-symbol adaptive variant. The
math in §2 is the gating constraint and must be reviewed before any
C code is committed. M94.X failed precisely because it skipped the
proof phase (per memory `feedback_phase_0_spec_proof`).

> **Implementation pivot (2026-05-01):** Phase 2 implementation
> revealed that the variable-T byte-pairing proof in §2 below is
> incomplete — it establishes `x' < M` (upper bound) but missed the
> lower bound `x' ≥ L`. With T_max = 65519 close to b = 2^16, rANS
> state can collapse to 0 and the decoder cannot recover (caught
> deterministically by `test_adaptive_halve_boundary`). CRAM 3.1's
> `fqzcomp_qual.c` uses a **Range Coder**, not rANS, which is why
> their T_max = 65519 works.
>
> **L2 was pivoted to a Subbotin Range Coder** (32-bit state, 24-bit
> renorm threshold, carry handled via Subbotin's merged-renorm
> idiom). Range Coders have no `[L, M)` state-range invariant, so
> any T_max fits. See `native/src/rc_arith.h`.
>
> The §2 byte-pairing proof below is left as the rANS analysis but
> is **not the implementation**. The Range Coder correctness
> argument is the standard arithmetic-coder result and does not
> require restating here. §3 (adaptive update rules) and §4
> (context model) are unchanged. §5 (wire format) was simplified —
> body has no `state_final` (RC has no trailing state). See
> memory `feedback_rans_nx16_variable_t_invariant` for the full
> rationale.

## 1. Algorithmic invariants

The L2 codec uses a Subbotin Range Coder (32-bit state, 24-bit
renorm) with adaptive per-context freq tables. 4-way interleaved
(lane = symbol_index mod 4) for parity with M94.Z V1.

| Constant | Value | Notes |
|---|---|---|
| RC_TOP | 2^24 | renorm fires when range < this |
| RC_BOT | 2^16 | underflow squeeze threshold (carry handling) |
| N (interleaved streams) | 4 | unchanged |
| T_init | max_sym | initial total per context (sum of count[s] = 1 each) |
| T_max | 65519 | halve trigger threshold (CRAM compatibility) |
| STEP | 16 | per-symbol count increment |
| max_sym | dynamic | active symbol range, stored 2 bytes (uint16 LE) in header; valid range [1, 256] |

T grows monotonically from T_init up to T_max, then halves and
grows again. Per-context (count, cum, T) tables maintained
identically on encoder and decoder side (lockstep adaptive
symmetry — see §2.4 below; the inductive proof there is unchanged
because it doesn't depend on which entropy coder consumes the
freq tables).

## 2. Byte-pairing proof (variable-T extension)

This section extends §2 of the existing M94.Z spec
(`2026-04-29-m94z-cram-mimic-design.md`) to non-power-of-2 T.

### 2.1 Encoder step at variable T

For symbol `s` with current freq `f = count[s]` and current
cumulative `c = cum[s]`:

```
x' = (x // f) · T + (x mod f) + c
```

We want post-encode `x' < M = b·L = 2^31`.

### 2.2 Renorm threshold

Define
  `x_max(s, T) = floor(M · f / T)`

with 64-bit integer arithmetic. Bound: `M · f ≤ 2^31 · 65519 ≈ 1.4 ×
10^14 < 2^47 < 2^63`, so `uint64_t` is safe.

**Claim:** for `x ∈ [L, x_max(s, T))`, the post-encode `x' < M`.

**Proof.**

For symbol `s` at context with current `count[s] = f` and current
`cum[s] = c`: the encoder computes

```
x' = (x // f) · T + (x mod f) + c.
```

Bounds on the components:
- `(x mod f) ∈ [0, f − 1]` (definition of integer remainder)
- `c ∈ [0, T − f]` (cumulative is at most `T − f` for the largest
  symbol — by `cum[max_sym] = T` and `cum[s] + count[s] ≤ T`)

so

```
x' ≤ (x // f) · T + (f − 1) + (T − f) = (x // f) · T + T − 1.
```

We require `x' < M = b · L = 2^31`. This holds when

```
(x // f) · T ≤ M − T,
i.e. (x // f) ≤ (M − T) / T = M/T − 1,
i.e. (x // f) < M/T   (strict).
```

The largest `x` satisfying `x // f < M/T` is

```
x_max(s, T) = floor(f · M / T).
```

**Verification (algebraic).** For `x ∈ [L, x_max(s, T))`,
`x ≤ x_max − 1 = floor(f · M / T) − 1 ≤ (f · M / T) − 1`, so
`x · T ≤ f · M − T`, so `(x // f) · T ≤ x · T / f · (1 + ε) ≤ M − T/f
≤ M − 1` (with `f ≥ 1`). Hence
`x' ≤ (x // f) · T + T − 1 ≤ M − 1 < M`. ✓

**Pre-encode lower bound.** The encoder enters the encode step with
`x ∈ [L, x_max(s, T))`. If `x ≥ x_max`, it first pops 16-bit chunks
to bring `x` into range:

```
while x ≥ x_max:
    emit_chunk(x & 0xFFFF)
    x >>= 16
```

Each pop divides `x` by `b = 2^16`, which is much larger than the
ratio `x_max / L = floor(f · M / T) / L`. With `f ≥ 1`, `T ≤ 65519`,
`M = 2^31`, `L = 2^15`: `x_max / L ≥ 2^31 / 65519 / 2^15 = 2^16 /
65519 ≈ 1`. So a single pop is sufficient to bring any `x < M` into
`[L, x_max)`.

**Lower bound on `x_max`.** The encoder must not enter an infinite-pop
loop, which requires `x_max(s, T) ≥ L` for any active symbol
(`f ≥ 1`). We have `x_max(1, T) = floor(M / T)`. With
`T ≤ T_max = 65519` and `M = 2^31`:

```
floor(M / T) ≥ floor(2^31 / 65519) = 32768 ≥ L = 2^15. ✓
```

So even at `f = 1` and `T = T_max`, `x_max ≥ L`. Active symbols
always have `f ≥ 1` by construction. Inactive symbols
(`count[s] = 0`) are never encoded, so their `x_max` is irrelevant.

**Decoder symmetry.** The decoder reads `x ∈ [L, M)`, computes

```
slot   = x mod T
sym    = inverse_cum(slot)
x_pre  = (x // T) · f + slot − c
```

By construction, `x_pre = original_x_pre` (the encoder's pre-encode
state), since rANS is an exact bijection on `(x_pre, s) ↔ x'` modulo
identical `(T, f, c)`. The decoder pulls 16-bit chunks while
`x_pre < L`:

```
while x_pre < L:
    x_pre = (x_pre << 16) | pull_chunk()
```

The number of pulls equals the number of encoder pops by the
symmetric renorm boundary: encoder pops while `x ≥ x_max`, decoder
pulls while `x_pre < L`. Both conditions are equivalent under the
encode/decode bijection, so chunk counts match. ∎

**(B) Verification by exhaustive search at boundaries.** The C
implementation includes a debug-mode assert that checks `x' < M`
after every encode step. Fuzz tests run random
`(symbols, contexts, max_sym)` over millions of inputs. Any boundary
violation aborts with a stack trace. See
`native/tests/test_adaptive_byte_pairing.c`.

### 2.3 Decoder symmetry

The decoder reads `x ∈ [L, M)` from state, computes
  `slot = x mod T`,  `sym = inverse_cum(slot)`,  `x_pre = (x // T) · f
+ slot − c`.

Claim: `x_pre ∈ [floor(L/T) · f, x_max(s, T))`. The lower bound is
trivially `≥ 0`; whether `≥ L` depends on whether we need a renorm
pull. The decoder pulls 16-bit chunks while `x_pre < L` and
`x_pre = (x_pre << 16) | next_chunk`.

**Byte-pairing claim:** the decoder pulls exactly the same number of
chunks the encoder popped. Proof: encoder pops while `x ≥ x_max(s,
T)` BEFORE encoding. Equivalent: encoder ensures pre-encode `x ∈ [L,
x_max(s, T))` so post-encode `x' ∈ [L, M)`. Decoder reverses: from
`x ∈ [L, M)`, decode step gives `x_pre ∈ [floor(L/T) · f, x_max(s,
T))`. If `x_pre < L`, pull until `x_pre ∈ [L, b·L)`. The number of
pulls is the same as the number of pops by symmetry of `(x → x') = (x
↔ x_pre)` modulo the rANS update.

A formal proof of the chunk-count invariant follows the standard
Duda 2014 argument with the substitution `T = T_t` (current total at
time `t`). The substitution is valid because both sides see the same
`T_t` at the same step (adaptive symmetry, §3 below).

### 2.4 Adaptive symmetry

After each symbol, encoder and decoder both apply:

```
count[sym] += STEP   // STEP = 16
T += STEP
if (T > T_max - STEP) {
    halve(count, T)   // see §3.2
}
```

**Lemma (adaptive symmetry).** Encoder and decoder maintain
identical `(count[ctx][·], T[ctx])` trajectories at every step.

**Proof by induction on symbol index `i`:**

*Base case `(i = 0)`:* both sides initialise
`count[ctx][s] = 1` for `s ∈ [0, max_sym)`, `0` otherwise;
`T[ctx] = max_sym`. Identical by construction.

*Inductive step:* assume identical trajectories at step `i`, i.e.,
both sides have the same `count[][]`, `T[]` tables. Symbol `i` is
encoded by the encoder using freq `f = count[ctx_i][sym_i]` and
cumulative `c = cum[ctx_i][sym_i]` derived from these tables. The
decoder, having received the same byte stream from the encoder,
recovers `slot = x mod T[ctx_i]` and looks up `sym_i` via the same
`inv_cum` on the same `count[][], T[]` tables (induction hypothesis
+ encoder/decoder bijection from §2.3). So
`sym_i_decoded = sym_i_encoded`. Both sides then update:

```
count[ctx_i][sym_i] += 16
T[ctx_i]            += 16
```

Both sides apply the halve check `T[ctx_i] + STEP > T_max`
identically (deterministic predicate over identical state). The
halve operation (§3.2) is deterministic. So post-update tables are
identical at step `i+1`. ∎

**Context remap symmetry.** The `ctx_remap` (sparse → dense) is
identical encoder/decoder side because:
- Encoder builds it from a forward pass over input symbols,
  recording first-encounter order of sparse ctx ids.
- Decoder reads the active sparse ctx ids from the body header
  prelude (`n_active` + `sparse_ids[]`, see §5.2) and rebuilds the
  remap in the same order.

Both sides see the same sequence of dense ctx ids and apply
`update_ctx(ctx_dense, sym)` identically. ∎

### 2.5 State-range invariants under adaptive T

**Lower bound on T:** after halving, T can drop. The smallest
possible T is when all counts are 1 — that's T = max_sym. So
`T_min = max_sym ≥ 1`. With M = 2^31 and `T_min = max_sym ≤ 256`:
  `M / T_min ≥ 2^31 / 256 = 2^23 ≥ L = 2^15` ✓
i.e., `x_max(f=1, T_min) = floor(M / T_min) ≥ 2^23 ≥ L`. The renorm
threshold never falls below the state lower bound.

**Upper bound on T:** halve fires at `T > T_max - STEP = 65503`, so
T is bounded above by T_max = 65519 (after the last symbol pre-halve
plus STEP).

**Conclusion:** the rANS state machine remains well-defined for all
T ∈ [max_sym, 65519] and all f ∈ [1, T]. Byte-pairing holds.

### 2.6 What the proof does not address

- Multi-context independence: each of ≤16384 contexts maintains its
  own (count[], T) trajectory; the proof above is per-context,
  replicated. No interaction.
- 4-way interleaving: orthogonal to the math above; same as current
  M94.Z. Each lane's state evolves independently; symbol → lane
  mapping is `lane = symbol_index mod 4`.
- Soft halving / fractional halving: not used. Hard halve as
  specified in §3.2.

## 3. Adaptive update rules

### 3.1 Initialization

For each context (1 ≤ ctx ≤ n_active_contexts):
- `count[s] = 1` for s ∈ [0, max_sym)
- `count[s] = 0` for s ∈ [max_sym, 256)
- `T = max_sym`
- `cum[s] = s` for s ∈ [0, max_sym]
- `cum[s] = max_sym` for s > max_sym

### 3.2 Halve operation

When `T + STEP > T_max` (i.e., `T > T_max - STEP = 65503`):

```
for s in [0, max_sym):
    count[s] -= count[s] >> 1   // == ceil(count[s] / 2)
T = sum(count[s] for s in [0, max_sym))
rebuild cum[]
```

The halve preserves `count[s] ≥ 1` for any active symbol that had
`count[s] ≥ 1` before. Verified inline:
- `count = 1`: `1 - (1 >> 1) = 1 - 0 = 1` ✓
- `count = 2`: `2 - 1 = 1` ✓
- `count = 3`: `3 - 1 = 2` ✓
- `count = 4`: `4 - 2 = 2` ✓

### 3.3 Per-symbol update

After encoding/decoding symbol `s`:
```
count[s] += STEP        // STEP = 16
T += STEP
// Halve check happens BEFORE next symbol's encode/decode:
if T + STEP > T_max:
    halve(count, T)
```

The halve check is *before* the next symbol's encode, not after the
current symbol's update. This matters for the boundary case where
the last symbol of a block triggers halve — both encoder and decoder
see the same predicate at the same point.

### 3.4 Cumulative table maintenance

Recomputing `cum[]` from scratch after every count update is O(256).
For 100M+ symbols this costs `100M × 256 = 2.56 × 10^10` ops —
prohibitive.

**Optimization:** incremental cum update. After `count[s] += STEP`:
- For all `t > s`: `cum[t] += STEP`.

That's O(max_sym - s) per update. With max_sym = 94, average ~47 ops.
Total: ~5 × 10^9 ops on 100M symbols. Still high but feasible.

**Better optimization:** Fenwick tree / binary indexed tree gives
O(log max_sym) per update and O(log max_sym) per slot lookup.
Implementation in C is straightforward (~50 lines). With max_sym ≤
256, log2(256) = 8, so 8 ops per update × 100M = 8 × 10^8 ops.
Comfortable.

**Decision:** start with the naive O(max_sym) update; if the C
benchmark shows it's slow, switch to Fenwick. The byte-pairing math
is identical either way (same numerical results).

## 4. Context model

**Unchanged from M94.Z.** Per Q5 (c) we defer context extension —
adaptive freqs alone should close the gap; if it doesn't, a follow-up
PR adds context extensions.

The encoder builds the context array in the language wrapper (existing
`buildContextSeq` / `_build_context_seq_c` / etc.); the decoder
derives contexts inline in C (mirrors Task #81's
`ttio_rans_decode_block_m94z` pattern).

`ctx_remap` (sparse → dense, length `1 << sloc`) is built encoder-side
and passed to both the encode and decode entries. Pad context handled
identically to M94.Z V1.

## 5. Wire format

Replaces M94.Z V1/V2 entirely. Magic `M94Z` and codec id 12 stay.

### 5.1 Header (36 bytes fixed + variable RLT)

```
Offset  Size   Field
──────  ────   ─────────────────────────────────────────────
0       4      magic = "M94Z"
4       1      version = 1   (single-version format; old V1/V2 dropped)
5       1      flags
                 bit 4–5: pad_count (0..3)
                 all other bits: reserved (must be 0)
6       8      num_qualities    (uint64 LE)
14      8      num_reads        (uint64 LE)
22      4      rlt_compressed_len (uint32 LE)
26      8      context_params:
                 qbits (u8, default 12)
                 pbits (u8, default 2)
                 dbits (u8, default 0)
                 sloc  (u8, default 14)
                 reserved (u8 × 4, must be 0)
34      2      max_sym (uint16 LE)   ← NEW; valid range [1, 256]
36      var    read_length_table (deflated)
```

### 5.2 Body

After the header (and before passing to the C kernel), the wrapper
prepends a sparse → dense context remap prelude so the decoder can
rebuild the same `ctx_remap` table the encoder used:

```
prelude  4      n_active                  (uint32 LE; count of
                                           sparse ctxs encountered)
+4       2*n    sparse_ids[n_active]      (uint16 LE × n_active;
                                           order = encoder
                                           encounter order)
```

The actual RC-encoded payload (produced by the C kernel) follows:

```
+0      16     lane_lengths: 4× uint32 LE (lane_bytes[0..3])
+16     var    4 lane byte streams (concatenated, FIFO)
```

There is no `state_final` — the Range Coder's terminal state is
folded into the byte stream by the encoder's 4-byte flush. The
decoder reads bytes as needed; if it tries to read past the end of
a lane, it returns `TTIO_RANS_ERR_CORRUPT`.

### 5.3 Removed vs current M94.Z V1

- `freq_tables_compressed_len` (4 bytes) — removed (decoder rebuilds
  freq tables from adaptive update).
- `freq_tables` blob (~5–10 KB on chr22) — removed.
- `state_init` (16 bytes) — removed (RC's initial state is implicit:
  `low = 0, range = 0xFFFFFFFF`).
- `state_final` (16 bytes) — removed (RC has no rANS-style trailing
  state to carry over the decode boundary).

### 5.4 Format version

File-root `format_version` bumps `1.5 → 1.6` to mark the wire-format
break. v1.6 readers reject v1.5 quality channels with a clear error.
v1.5 readers reject v1.6 files via the existing format-version
gate. Pre-publication, no migration path needed.

## 6. C library API

Two new entry points in `native/include/ttio_rans.h`:

```c
typedef struct {
    uint32_t qbits;
    uint32_t pbits;
    uint32_t sloc;
} ttio_m94z_params;   // already defined for Task #81

int ttio_rans_encode_block_adaptive(
    const uint8_t  *symbols,         // n_symbols quality bytes
    const uint16_t *contexts,        // n_symbols dense ctx indices
    size_t          n_symbols,
    uint16_t        n_contexts,
    uint8_t         max_sym,
    uint8_t        *out,
    size_t         *out_len);

int ttio_rans_decode_block_adaptive_m94z(
    const uint8_t           *compressed,
    size_t                   comp_len,
    uint16_t                 n_contexts,
    uint8_t                  max_sym,
    const ttio_m94z_params  *params,
    const uint16_t          *ctx_remap,
    const uint32_t          *read_lengths,
    size_t                   n_reads,
    const uint8_t           *revcomp_flags,
    uint16_t                 pad_ctx_dense,
    uint8_t                 *symbols,
    size_t                   n_symbols);
```

**Implementation files:**
- `native/src/rans_encode_adaptive.c` — encoder
- `native/src/rans_decode_adaptive.c` — decoder with inline M94.Z
  context derivation

**Internal data structures (per active context):**
- `uint16_t count[max_sym]` — adaptive counts
- `uint16_t T` — current total
- `uint32_t cum[max_sym + 1]` — incrementally maintained cumulative

For ≤16384 contexts × max_sym ≤ 256: workspace ≤ 16384 × (256 × 6 +
4) ≈ 25 MB. Allocate once per encode/decode call; free on completion.

## 7. Per-language wrapper changes

| Language | File(s) | Current LOC | Post-L2 LOC (est.) |
|---|---|---:|---:|
| Python | `fqzcomp_nx16_z.py` + `_fqzcomp_nx16_z/_fqzcomp_nx16_z.pyx` | ~2600 | ~600 |
| Java | `FqzcompNx16Z.java` | ~1700 | ~700 |
| ObjC | `TTIOFqzcompNx16Z.{h,m}` | ~1300 | ~600 |

Each wrapper retains:
- Wire-format outer shell (magic, header pack/unpack, RLT
  zlib-compress/decompress)
- M94.Z context-derivation helpers (encoder-side only)
- Sparse→dense ctx_remap construction (encoder-side)
- Native-library loader / JNI bridge / direct linkage glue
- Top-level `encode()` / `decode_with_metadata()` API surface (caller
  contract unchanged)

Each wrapper drops:
- Pure-language rANS encode/decode loops
- Freq-table normalization (`normalise_to_total`)
- Freq-table sidecar zlib pack/unpack
- Cython/per-language pre-pass for freq counting
- pure-language fallback (native lib becomes mandatory)

**Native availability becomes mandatory.** Pip wheels / Maven jars /
ObjC framework must bundle libttio_rans (~200 KB compiled). Same
approach as numpy/scipy/pandas. CI updated to require native build
before language tests.

## 8. Testing strategy

### 8.1 C-level (native ctest)

- `test_adaptive_roundtrip.c` — encode/decode parity on 1000 symbols ×
  10 reads × 100bp = 100K input.
- `test_adaptive_byte_pairing.c` — fuzz: 1000 random
  `(symbols, contexts, max_sym)` inputs through encoder, then
  decoder, assert byte-exact recovery + `state_final` matches.
- `test_adaptive_halve_boundary.c` — input designed to trigger halve
  at every possible block boundary (i.e., last symbol pre-halve).
- `test_adaptive_max_sym_bounds.c` — `max_sym ∈ {1, 2, 41, 94, 256}`.

### 8.2 Cross-language byte-exact (per-language fixtures)

Five canonical fixtures committed under
`python/tests/fixtures/codecs/`, copied to Java/ObjC test resources:

- `m94z_a.bin` — 100 reads × 100bp, all Q40, all forward
- `m94z_b.bin` — 100 reads × 100bp, Q20–Q40 mixed, seed `0xBEEF`
- `m94z_c.bin` — 50 reads × 100bp, PacBio Q40 majority + Q30/Q60
- `m94z_d.bin` — 4 reads × 100bp, mixed revcomp `[0,1,0,1]`
- `m94z_f.bin` — 100 reads × 100bp, 80% revcomp

Each fixture is regenerated from the new spec (replaces current
M94.Z V1 fixtures). Cross-language byte-exact tests in all three
languages decode them and assert exact qualities recovery.

### 8.3 Compression target acceptance

`docs/benchmarks/v1.2.0-chr22-smoke.md` rerun shows TTI-O total ≤ 99
MB (1.15× CRAM 86 MB) on `chr22_na12878_mapped`. **Hard gate.**

If after Phase 6 (Python wrapper + benchmark) the chr22 result is
> 99 MB, we iterate the C kernel before paying the Java + ObjC port
cost.

### 8.4 Regression coverage

- All Python unit tests (1744+ post-L1+L3) green.
- Java suite (878+) green.
- ObjC suite (3260+) green; the 2 pre-existing TestMilestone29
  failures stay pre-existing.
- M94.Z conformance tests (`test_m94z*.py`, `FqzcompNx16Z*Test`,
  `TestM94Z*.m`) updated for the new wire format.

## 9. Acceptance criteria

**Hard gates** (all must pass):
1. Spec proof in §2 reviewed by user before any C code committed.
2. C ctest suite green (4 new tests).
3. Python ctypes wrapper produces byte-exact output on all 5
   canonical fixtures.
4. Java JNI wrapper produces byte-exact output on the same fixtures.
5. ObjC direct-linkage wrapper produces byte-exact output on the
   same fixtures.
6. chr22_na12878_mapped TTI-O total ≤ 99 MB (1.15× CRAM).
7. All Python/Java/ObjC unit tests green (excluding the 2
   pre-existing TestMilestone29 ObjC fails).

**Stretch gates:**
- chr22_na12878_mapped TTI-O ≤ 92 MB (1.07× CRAM).
- M94.Z encode wall ≤ M94.Z V1 (i.e., adaptive doesn't slow encode
  vs static).

## 10. Phasing

Six phases, gated:

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| 1 | Spec proof (§2 expanded) | User review |
| 2 | C kernel (`rans_encode_adaptive.c`, `rans_decode_adaptive.c`) + ctest suite | All 4 new ctests green |
| 3 | Python ctypes wrapper rewrite | All Python M94.Z tests green |
| 4 | Python chr22 benchmark | TTI-O ≤ 99 MB on chr22 |
| 5 | Java JNI wrapper rewrite | All Java tests green; cross-lang fixtures byte-exact |
| 6 | ObjC direct-linkage wrapper rewrite | All ObjC tests green; cross-lang fixtures byte-exact; final benchmark report |

Phases 5 and 6 only run if Phase 4 confirms the compression target.
Phases 2–6 are committable independently; the codebase stays in a
working state at each gate (M94.Z is not multiplexed across V1 + new
during the rewrite — instead, in-place file-by-file with format-version
gate).

## 11. Out of scope

- Context model extension (length bucket, larger pbits) — deferred to
  L2.X follow-up if compression < 0.20 B/qual.
- Soft halving / decay schedules — not used; hard halve at
  T > T_max - STEP.
- Multi-block streaming format — one block per qualities channel,
  same as current M94.Z.
- Asymmetric encoder/decoder fast paths — both sides use the same
  C kernel structure.
- htslib byte-equivalence — explicitly opted out per Q3 (b);
  TTI-O-internal byte-exactness is the contract.
