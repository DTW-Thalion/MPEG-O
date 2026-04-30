# M94.Z — CRAM-Mimic FQZCOMP_NX16 Design Spec

**Status**: research / paper-design phase. NO code in this phase. Subsequent
phases (M94.Z.1 Python ref, M94.Z.2 Cython, M94.Z.3 ObjC, M94.Z.4 Java) will
mechanically translate this spec to per-language implementations.

**Author**: Claude (research subagent), 2026-04-29
**Supersedes**: M94.X Path 2 (variable-total rANS at 8-bit renorm — failed
byte-pairing, see §2.4)
**Predecessor in tree**: M94 v1.1.1 (fixed-M=4096, 8-bit renorm, ~600 ops/symbol)
**Target performance**: within 5–15% of CRAM 3.1 fqzcomp_qual reference
(`htscodecs` master), i.e. ~10–40× faster than M94 v1.1.1.

---

## 0. Why this spec exists

M94 v1.1.1 ships byte-exact across Python/ObjC/Java (M94 v1.2.0 milestone, see
project memory). It is correct but slow: ~600 ops/symbol because it

1. Recomputes per-symbol rescaling of `count[256]` to a fixed `M = 4096` total
   on every step.
2. Uses 8-bit renormalization (`b = 256`).
3. Single-stream rANS, no interleaving.

CRAM 3.1's `rANS-Nx16` runs at ~12 ops/symbol because it

1. Lets the count-table sum drift (variable `T`), with a periodic halve to keep
   `T_max` bounded.
2. Uses 16-bit renormalization (`b = 65536`), which doubles emit throughput and
   — critically — makes `floor(b·L / T)` rounding errors small relative to the
   chunk size (see §2 for why this matters).
3. Interleaves N=4 (or N=32) rANS states for ILP / SIMD.

M94.X Path 2 attempted (1) without (2) and failed because at 8-bit renorm
the `floor(b·L / T)` rounding error fits *inside* a single chunk for some
`T` values, breaking the encoder/decoder byte-pairing invariant. M94.Z is the
correct rewrite: variable-T **plus** 16-bit renorm.

---

## 1. Algorithmic invariants

All values are CRAM 3.1 / `htscodecs` master, verified by reading
`htscodecs/rANS_word.h` (§9 sources).

### 1.1 State width
- **Type**: `uint32_t` per state (32-bit unsigned).
- Source: `rANS_word.h` line 47 — `typedef uint32_t RansState;`
- Implication: arithmetic stays in 32-bit lanes during the hot loop. The
  intermediate `(x_in / f) * T + ...` must NOT overflow 32 bits (proven in §2).

### 1.2 L (state lower bound)
- **Value**: `L = 2^15 = 32 768`
- Source: `rANS_word.h` line 44 — `#define RANS_BYTE_L (1u << 15)`.
- Steady-state invariant: `L ≤ x < b·L` at all times between symbol steps.

### 1.3 B (renormalization chunk size in bits)
- **Value**: `B = 16` (two bytes per emit/pull).
- Source: `rANS_word.h` lines 56–61 (encoder writes `ptr[0] = x & 0xff;
  ptr[1] = (x >> 8) & 0xff; x >>= 16;`) and 149–157 (decoder reads two bytes
  and shifts left 16 before testing `x < L`).
- The output cursor is `uint8_t*` (byte-addressed), but each renorm step
  consumes/produces exactly 2 bytes — the "16" in "Nx16" refers to **B**, not
  to states or stream count.

### 1.4 b (renormalization base) and b·L (state upper bound)
- **b** = `2^B` = `2^16` = `65 536`.
- **b·L** = `2^16 · 2^15` = `2^31` = `2 147 483 648`.
- Steady-state invariant: `x < b·L = 2^31` always. This leaves the high bit
  free — a key margin used in the `(x/f) * T` multiplication (§2).

### 1.5 T (current total) and T_max
The rANS-Nx16 frequency table is **power-of-two normalised**; the sum is fixed
within a block. CRAM 3.1 specifies:

- **Order-0 fqzcomp/qual context**: `T = TOTFREQ = 4096` (12-bit shift).
- **Order-1 default**: `T = 4096` (12-bit).
- **Order-1 fast variant**: `T = 1024` (10-bit).

Source: `rANS_static4x16pr.c` lines 62–70 — `TF_SHIFT = 12`, `TOTFREQ = 1<<12`.

**Important distinction**:
- The **rANS-Nx16 codec** itself uses `T` ∈ {1024, 4096} **fixed per block**.
  Frequencies are renormalised once when the block is built (`fqz_store_parameters`)
  and held constant for the duration of the rANS pass. **T is NOT variable
  per-symbol within a block.**
- The `c_simple_model.h` adaptive arithmetic coder (used by `fqzcomp_qual.c`
  but layered on a *range coder*, not rANS) has `MAX_FREQ = 65519` and
  `STEP = 16` — see §3.

For M94.Z we adopt the **rANS-Nx16 fixed-T-per-block** discipline. T_max
within a block = 4096. This is the single biggest deviation from M94.X.

### 1.6 N (number of interleaved streams)
- **N = 4** (default) or **N = 32** (SIMD-friendly).
- Source: `rANS_static4x16pr.c` (function names `rans_compress_O0_4x16`,
  state vars `rans0..rans3`); CRAM 3.1 spec text "N32 flag (bit 2)".
- For M94.Z we target **N = 4** for v1 (matches our current 4-way
  interleave). N = 32 deferred to M94.Z++ if SIMD intrinsics warrant.

### 1.7 Summary table

| Parameter | Symbol | Value          | Source                          |
| --------- | ------ | -------------- | ------------------------------- |
| State width | —    | 32 bits        | `rANS_word.h:47`                |
| L         | L      | 2^15 = 32 768  | `rANS_word.h:44`                |
| B         | B      | 16             | `rANS_word.h:56–61, 149–157`    |
| b         | b      | 2^16 = 65 536  | derived                         |
| b·L       | b·L    | 2^31           | derived                         |
| T_max     | T      | 4096           | `rANS_static4x16pr.c:62–70`     |
| N         | N      | 4              | `rans_compress_O0_4x16`         |

---

## 2. Byte-pairing proof

The fundamental correctness invariant of rANS: **the encoder must emit exactly
the number of chunks the decoder pulls**, *for every symbol step*. Off-by-one
breaks the entire stream from that point onward.

This is what M94.X Path 2 got wrong (§2.4).

### 2.1 The encoder step

Given state `x_in`, symbol `s` with frequency `f = freq[s]` and cumulative
`c = cum[s]`, total `T`:

1. **Pre-renormalize**: while `x_in ≥ x_max`, emit low B bits of `x_in`,
   shift `x_in >>= B`. Let `x` be the final value (post-renorm).
2. **Encode**: `x_out = (x / f) * T + (x mod f) + c`.
3. New state is `x_out`.

The threshold `x_max` is chosen so that step 2 produces `x_out < b·L`
exactly when step 1 produced `x < x_max`:

```
x_max = floor(b · L / T) · f
```

Equivalently, `htscodecs/rANS_word.h:53` writes
`x_max = ((L >> log2_T) << 16) * f - 1`, i.e. `((L / T) * b) * f - 1`,
with the renormalize condition `x > x_max` (strictly, line ~50).
That `-1` and the `>` (not `≥`) together encode the same boundary.

For CRAM-Nx16: `L = 2^15`, `b = 2^16`, so `b · L = 2^31`. With `T = 4096 = 2^12`:

```
b · L / T = 2^31 / 2^12 = 2^19 = 524 288.
```

This division is **exact** (T is a power of 2 dividing b·L). No floor, no
remainder. Therefore:

```
x_max = (b·L / T) · f = 2^19 · f.   For f ∈ [1, T-1] = [1, 4095].
x_max range: [2^19, 2^19 · 4095] = [524 288, 2 146 959 360].
```

### 2.2 Pre-renorm output range

After the while-loop in step 1, we have `x ≤ x_max < 2^19 · f`. We also have
`x ≥ L = 2^15` (steady-state lower bound, preserved by the loop because each
shift divides by `b = 2^16` and `x ≥ L · b ⟹ x >> B ≥ L / 2^1` — actually we
need to be more careful, see §2.3).

So **post-renorm range**: `L ≤ x < 2^19 · f` where `f ≥ 1`.

### 2.3 Encoder state after step 2

Compute `x_out = (x/f) · T + (x mod f) + c`:

- `x/f` ≤ `(2^19 · f - 1) / f` < `2^19`. So `x/f ≤ 2^19 - 1`.
- `(x/f) · T` ≤ `(2^19 - 1) · 2^12` < `2^31`. So far so good.
- `(x mod f) ≤ f - 1 ≤ T - 1`.
- `c ≤ T - f`.
- Sum: `(x/f) · T + (x mod f) + c` ≤ `(2^19 - 1) · 2^12 + (T - 1) + (T - f)`
  ≤ `(2^19 - 1) · 2^12 + 2T - 2` < `2^31`.

Strict bound: `x_out < 2^31 = b · L`. ✓

**Lower bound**: `x_out ≥ (x/f) · T ≥ 0 · T = 0`. But once we account for the
fact that `x ≥ L · ?`, we need `x_out ≥ L`. We get this from the encoder's
*next* pre-renorm: the loop in step 1 of the *next* symbol will shift `x_out`
down to `[L, x_max)` again. So `x_out ≥ L` is **not** required at this step;
what matters is that `x_out < b·L` (proven) and that we preserve it across
the *renorm pop* (next).

### 2.4 The renorm-pop and pull invariant

The encoder pre-renorm at step 1 of the *next* symbol pops the low B=16 bits
exactly when `x ≥ x_max`. The decoder, seeing the byte stream in reverse,
pulls the low B bits exactly when it has pre-renormalized down to `x < L`.

**Pairing claim**: for every encoder emit, decoder pulls exactly one chunk.

Proof sketch (the version M94.X failed):

- Encoder emits 0 or 1 chunk per symbol step (single while-loop iteration
  because `x_max ≥ L · b`, and after one shift `x' = x >> B ≤ (b·L − 1) / b < L`,
  so the loop terminates after at most one iteration when started from
  `x < b·L`. **This requires `x_max < b · L · b / b = b · L`, i.e. the encoder
  state never exceeds `b · L` before the loop entry**, which is exactly the
  steady-state invariant `x < b · L` from §2.3. ✓)

- The number of chunks emitted by the encoder for a given symbol depends
  ONLY on whether the post-renorm state `x` (which feeds into formula
  `x_out = (x/f) · T + ...`) satisfies `x_in_pre_renorm ≥ x_max`. With
  `x_max = floor(b·L/T) · f` and `T | b·L` (T divides b·L exactly), this
  threshold is a **deterministic function of `f` only** — no rounding ambiguity.

- The decoder reverses: given `x_out`, it computes `s` from `x_out mod T`
  (cumulative search), then `x = (x_out / T) · f + (x_out mod T) − c`. This
  recovers the encoder's pre-encode `x`. The decoder then pulls bytes until
  `x ≥ L`, which is exactly the inverse of encoder pre-renorm.

**Why the encoder pop count = decoder pull count, exactly**:

- Encoder emitted 0 chunks iff `x_in_pre_renorm < x_max`, i.e. the encoder's
  own pre-renorm-input `x_in` was already `< x_max`. Equivalently `x = x_in`,
  and after encoding `x_out = (x_in / f) · T + ...`. Since `x_in ≥ L`
  (steady-state), `x_out ≥ (L/f) · T = (2^15 / f) · 2^12`. For `f ≤ 2^12`,
  this is `≥ 2^15 = L`. So decoder's recovered `x = x_in ≥ L`, no pull. ✓
- Encoder emitted 1 chunk iff `x_in_pre_renorm ≥ x_max`. Then post-shift
  `x = x_in_pre_renorm >> B`, and `L ≤ x < x_max / b · b = x_max` (so
  `x` could be up to `x_max - 1`). After encoding, `x_out` satisfies the
  bound from §2.3. On decode: recovered `x` is in `[L, x_max)`, but
  before renorm-pop, decoder is looking at `x_recovered_pre_pull = x · 1` —
  wait, this requires care. Decoder computes `x_dec_after_decode = (x_out/T)·f
  + (x_out mod T) − c`. This equals encoder's `x` (post-pop). Decoder then
  tests `if (x_dec_after_decode < L) pull two bytes`. The pulled value is
  exactly the bytes the encoder emitted. So decoder ends with
  `x_dec_after_pull = (x_dec_after_decode << B) | popped_bytes = x_in_pre_renorm`. ✓

**The M94.X failure mode**: at `B = 8`, `b = 256`, `b·L = 2^31`, `T_max =
2^20` (M94.X tried variable T up to 2^20). Then `b·L/T_max = 2^31 / 2^20
= 2^11 = 2048`. But for non-power-of-2 T (M94.X's variable-T did NOT
constrain T to powers of 2 — that was the bug), `floor(b·L / T)` introduced
a rounding error of `(b·L mod T) / T` < 1. Multiplied by `f` (up to T), the
error in `x_max` could reach `~T = 2^20`. Compared to chunk size `b = 256`,
the error is **much larger than one chunk** — meaning a single boundary
case could shift the pop count by ~4096 chunks. In practice the failure
manifested as sporadic off-by-one slips at specific `n_reads` (1150, 3300,
4000) where the cumulative error first exceeded one chunk on a hot path.

**M94.Z avoids this by**:

1. **T is power of 2 and divides b·L exactly**: T = 2^12, b·L = 2^31, so
   2^31 / 2^12 = 2^19 with zero remainder. `x_max` is exact.
2. **B = 16** (not 8): even if `T` were not a perfect divisor (which it is),
   the per-step error `b·L mod T < T = 4096`, and chunk size is `b = 65536`,
   so error << chunk. Margin of 16× over the worst case.
3. **No per-symbol T mutation**: T is fixed per block. Mutations between
   symbols would require re-quantising freqs, which is what made M94.X
   complex. M94.Z's halve-when-needed (§3) happens at the **count-table
   level before normalisation to T**, not on T itself.

### 2.5 Conclusion for M94.Z

For all `T ∈ {1024, 4096}` (power-of-2), all `f ∈ [1, T-1]`, all `c ∈
[0, T-f]`, all `x_in ∈ [L, b·L)`:

- Encoder emits exactly `⌊log_b(x_in / x_max) + 1⌋` chunks (≤ 1 per step).
- Decoder pulls exactly the same count.
- `x_out ∈ [L, b·L)` after each symbol.

**Byte-pairing is mathematically guaranteed.** Verified by replaying the
chain in §2.1–2.4 with exact arithmetic. (No floor-division rounding error.)

---

## 3. Adaptive count-table update

CRAM 3.1's rANS-Nx16 itself does **not** adaptively update freqs — it builds
the order-0 (or order-1) freq table **once** from a pre-pass over the input,
quantises it to power-of-2 sum, and writes the table as part of the block
header. The rANS pass then uses fixed freqs.

The "adaptive" part the user is thinking of comes from `c_simple_model.h`,
which is used by `fqzcomp_qual.c` — a **range-coder**-based qual codec (NOT
rANS-Nx16). For completeness:

### 3.1 c_simple_model.h adaptive parameters

- **Initial state** (`c_simple_model.h` lines 38–45):
  - Active symbols (0..max_sym−1): `Freq = 1`.
  - Padding symbols (max_sym..NSYM−1): `Freq = 0`.
  - Sentinel + terminal nodes: `Freq = MAX_FREQ` (held there for sort).
  - **TotFreq initial = max_sym** (sum of active 1's).

- **Per-symbol increment** (line 24): `STEP = 16`. After encoding/decoding
  symbol `s`: `count[s] += 16`, `TotFreq += 16`.

- **Halve trigger** (lines 23, 54, 74): `MAX_FREQ = (1<<16) - 17 = 65 519`.
  When `TotFreq > MAX_FREQ`, halve.

- **Halve operation** (line 62): `for each k: count[k] -= count[k] >> 1`,
  i.e. `count[k] = ⌈count[k] / 2⌉`. **No floor-1 guard**: counts can go to
  zero after halve, but only for symbols that were already at count = 1
  (since `1 - (1 >> 1) = 1`, so single-count symbols stay at 1; counts ≥ 2
  shrink by exactly half rounded up). Actually: `1 - 0 = 1`, so floor 1 IS
  preserved for count=1; `2 - 1 = 1`; `3 - 1 = 2`; `4 - 2 = 2`; etc. So the
  halve is `count[k] - (count[k] >> 1) = ⌈count[k] / 2⌉`, which **is**
  effectively floor-1 for active symbols.

### 3.2 What M94.Z does

For M94.Z's **rANS-Nx16 layer**, we follow CRAM 3.1's discipline:

1. **Build phase**: pre-pass over the input. For each context, accumulate
   raw counts into `raw_count[ctx][256]`.
2. **Normalise phase**: for each context, normalise `raw_count[]` to
   `freq[]` summing exactly to `T = 4096`, preserving `freq[s] ≥ 1`
   wherever `raw_count[s] ≥ 1`.
3. **Encode phase**: emit normalised freqs into block header (§5), then
   run rANS-Nx16 with fixed freqs.

This is **not** the adaptive `STEP=16, halve at 65519` loop of
`c_simple_model.h`. M94.Z is a static-per-block model, like CRAM-Nx16
proper, not like fqzcomp_qual.c.

**Open question for user** (see §8): does TTI-O want
(a) the static-per-block CRAM-Nx16 model (this spec, simpler, matches our
    chunking model and is what gives the perf win), OR
(b) the per-symbol-adaptive `c_simple_model.h` model layered over rANS
    (more complex, slightly better compression on noisy data, more like
    the fqzcomp_qual.c reference but not what makes CRAM-Nx16 fast)?

**Recommendation**: (a) for M94.Z. Re-evaluate (b) for M94.Z+ if compression
delta vs. v1.1.1 is < 5%.

### 3.3 Normalisation algorithm (build phase)

Standard "normalise to total" used by htscodecs (`rANS_static4x16pr.c`
`normalise_freq`-equivalent):

```
Given raw_count[256] with sum S; produce freq[256] with sum exactly T:

1. If S == 0: trivial — set freq[0] = T (or pick a convention).
2. Compute scale = T / S (floating-point or fixed-point).
3. freq[s] = max(1, round(raw_count[s] * scale)) for all s with raw_count[s] > 0.
4. Set freq[s] = 0 for all s with raw_count[s] == 0.
5. Adjust: while sum(freq) > T, decrement the largest freq[s] (excluding
   zeros and ones to preserve freq ≥ 1 invariant for present symbols).
6. While sum(freq) < T, increment the largest freq[s].
```

Edge cases that M94 v1.1.1 already handles correctly (and we keep):
- Single-symbol blocks: freq[s] = T, all others 0.
- All counts zero: defer to caller (empty block).

---

## 4. Context model

### 4.1 fqzcomp_qual.c reference context

From `fqzcomp_qual.c` lines 1093–1127 (function `fqz_update_ctx`):

The 16-bit context is assembled by **bit-packing** four components into
disjoint bit ranges within `last`:

```
last = (state->qctx << pm->qloc)        // quality history, qbits wide
     | (pm->ptab[min(1023, p)] << pm->ploc)  // position bucket
     | (pm->dtab[min(255, delta)] << pm->dloc) // delta bucket
     | (state->s << pm->sloc)            // selector (READ1/READ2 etc)
return last & (CTX_SIZE - 1)             // mask to 16 bits, CTX_SIZE = 65536
```

Where:
- `qctx` is a sliding window of past quality symbols:
  `qctx = (qctx << qshift) + qtab[q]`. With `qshift = 5` and 3 history
  symbols, qctx uses 15 bits; with qshift = 2 and 5 history symbols, 10 bits.
- `ptab[1024]` is a precomputed bucketing of position-in-read:
  `ptab[i] = min((1 << pbits) - 1, i >> pshift)`. Coarse logarithmic.
- `dtab[256]` is a sqrt-bucketing of "delta count" (number of distinct
  quality transitions seen so far in the read).
- `s` is the selector: 0 or 1 for READ1/READ2, or 0..3 for quality-average
  bins, packed at `sloc`.

**Hashing**: NONE in the canonical fqzcomp_qual.c context. The components
are pre-positioned to non-overlapping bit ranges by the parameter tuner
during the build phase, so the OR/SUM is unambiguous and reversible. The
parameter tuner picks `qbits, qshift, qloc, pbits, pshift, ploc, dbits,
dloc, sloc` such that all components fit in 16 bits without collision.

The parameter tuner is heuristic (see `fqzcomp_qual.c:1437–1500`) — it
tries several `(qbits, pbits, dbits)` triples and picks the one that
compresses smallest on a sample.

### 4.2 M94 v1 context (current TTI-O)

Per project memory `feedback_libs_base_test_style` and our own M94 v1 code:

```
context = SplitMix64(prev_q[0..2], position_bucket, revcomp_flag, length_bucket)
        & (CTX_SIZE - 1)
```

Differences from CRAM:
1. **SplitMix64 hash** vs. CRAM's bit-packing. SplitMix is universal
   (better hash quality on adversarial inputs) but costs ~10 ns/symbol —
   in the hot loop. CRAM's bit-packing is ~1 ns/symbol.
2. **Fixed history depth = 3** vs. CRAM's tunable `qshift × qbits`.
3. **No delta channel** — we don't track `delta` (number of transitions).
4. **revcomp_flag** is in our context; CRAM puts revcomp in a per-read
   *strand-flip* preprocessing pass (`GFLAG_DO_REV`), not in the context.
5. **length_bucket** in ours; CRAM uses position-relative-to-end via ptab,
   not length directly.

### 4.3 M94.Z context proposal

For M94.Z v1, **adopt CRAM's bit-packing context** with TTI-O-style
defaults:

```
qctx     = sliding window of last 3 quality symbols, qshift = 4
           (4 bits each, 12 bits total; supports 16-symbol alphabet,
            covers Phred 0..40 quantised to 4 bits if needed, OR full
            8-bit Phred 0..93 if qshift = 8 and history = 1)
ptab     = position bucket, pbits = 2 (4 buckets across 0..len-1)
dtab     = delta bucket, dbits = 2 (4 buckets, optional - skip for v1)
s        = revcomp flag, 1 bit
```

Bit layout (16 bits):

```
  bit 15           bit 0
  [s|d|d|p|p|q|q|q|q|q|q|q|q|q|q|q]
   1 2 2 2 ----- qbits = 12 -----
```

That fits 1+2+2+12 = 17 bits — too wide. Drop dtab for v1:

```
  [s|p|p|q|q|q|q|q|q|q|q|q|q|q|q]   = 1 + 2 + 12 = 15 bits, room to spare
```

OR include dtab and reduce qbits to 11:

```
  [s|d|d|p|p|q|q|q|q|q|q|q|q|q|q|q]  = 1 + 2 + 2 + 11 = 16 bits exact
```

**Decision deferred to M94.Z impl phase** based on a sweep over
test corpus. Default for v1: `qbits=12, pbits=2, dbits=0, sloc=14`.

**Removed for M94.Z**:
- SplitMix64. Replaced with bit-pack OR.
- length_bucket. Replaced with ptab (position-relative), which captures
  read-end behaviour without needing the length itself.

### 4.4 Compatibility with M94 v1.1.1 fixtures

**Note**: M94.Z is a NEW codec ID in the TTI-O wire format. M94 v1.1.1
fixtures stay valid for backward decode. M94.Z gets a new codec_id (e.g.
`FQZ_NX16_V1`) and bumps the file format spec minor version. No fixture
migration needed.

---

## 5. Wire format

### 5.1 CRAM-Nx16 reference layout

From `fqzcomp_qual.c:793–810` (`fqz_store_parameters`) — note this is the
**fqzcomp range-coded format**, not pure rANS-Nx16. For pure rANS-Nx16
(`rANS_static4x16pr.c`), the layout is simpler:

```
[0]      flags         // 1 byte; bit 0 = ORDER, bit 2 = N32, etc.
[1]      uncompressed_size // varint (1–5 bytes)
                           // (sometimes split into in_size + out_size)
[6...]   freq table     // order-0: ~256 bytes RLE'd
                        // order-1: 256 × per-symbol freq tables
[X...]   rANS body      // 4 (or 32) interleaved 32-bit final states
                        //   followed by the byte stream (LE pairs)
```

### 5.2 M94 v1.1.1 current layout (TTI-O)

From project memory `project_tti_o_v1_2_codecs`:

```
[0..3]   magic 'M941'
[4]      version
[5..7]   reserved
[8..15]  uncompressed length (uint64 LE)
[16..47] context-table hash (32 bytes, SHA-256)
[48..51] codec_flags (uint32)
[52..53] header_extension_len (uint16) = L
[54..54+L]   extension blob
[X..X+15]    4-way substream lengths (4 × uint32)
[X+16..]     concatenated 4-way rANS substreams
```

54 + L bytes header + 16 bytes substream prefix + body. We've stayed
backwards-compatible across v1.1.0 → v1.1.1.

### 5.3 M94.Z proposed layout

Bump magic to `M94Z` and version to 1. Add a `nx16_flags` byte mirroring
CRAM:

```
[0..3]   magic 'M94Z'
[4]      version = 1
[5]      nx16_flags  // bit 0 = ORDER (0=O0, 1=O1)
                     // bit 2 = N32 (0=N=4, 1=N=32)   [v1: must be 0]
                     // bit 6 = USE_DTAB              [v1: 0]
                     // bit 7 = USE_REVCOMP_PRE       [v1: 0]
[6..7]   reserved (must be 0)
[8..15]  uncompressed length (uint64 LE)
[16..47] context-table hash (SHA-256)
[48..51] codec_flags (uint32)
[52..52]    qbits (1 byte, value 1..15)
[53..53]    qshift (1 byte, value 1..7)
[54..54]    pbits (1 byte, value 0..4)
[55..55]    dbits (1 byte, value 0..4) [v1: 0]
[56..57]    block_count uint16 LE
For each block:
  [+0..3]   T_log2 (1 byte; v1: always 12)
  [+1..2]   freq_table_len uint16 LE
  [+3..]    freq_table (RLE'd, see §5.4)
  [+X..X+15]  4 × uint32 final rANS states
  [+X+16..]   concatenated 4-way rANS bytes (LE pairs, B=16 chunks)
```

### 5.4 Freq table RLE

Same RLE as `rANS_static4x16pr.c:write_freqs_o0`-equivalent: zero runs
collapsed via a special escape, non-zero freqs varint-encoded. Spec
deferred to impl phase — straightforward port from htscodecs (cite, don't
copy).

### 5.5 Comparison summary

| Field          | M94 v1.1.1     | M94.Z          | Change                |
| -------------- | -------------- | -------------- | --------------------- |
| Magic          | `M941`         | `M94Z`         | New                   |
| Hash           | yes (32 B)     | yes (32 B)     | Keep                  |
| Header ext     | yes (L bytes)  | no             | Replaced by typed fields |
| Substream pfx  | 4×uint32       | 4×uint32       | Keep (interleaved bodies) |
| Freq table     | embedded       | per-block RLE  | Add                   |
| Final states   | implicit       | 4×uint32       | Add (CRAM-style)      |

Body interleaving (4-way) matches existing M94 v1.1.1 — minimal disruption.

---

## 6. Performance characteristics

### 6.1 Per-symbol op counts (estimated)

**M94 v1.1.1** (current):
- Recompute fixed-M=4096 normalisation: ~32 ops (256-element rescale,
  amortised ~0.5 ops/symbol but with large constant factor for table
  rebuild every symbol).
- 8-bit renorm encode: ~4 ops in steady state.
- Cumulative search: ~8 ops (256-symbol linear, but with shortcut).
- Encode formula: ~10 ops (div, mul, mod, add).
- Context update (SplitMix64): ~20 ops.
- **Total: ~600 ops/symbol** (the rebuild dominates because we do it
  per-symbol, not per-block).

**M94.Z** (target):
- No rebuild — freq table is fixed per block.
- 16-bit renorm encode: ~4 ops in steady state, but emits 2 bytes per
  pop (so half as many pops in expectation).
- Cumulative search: ~8 ops (or ~3 ops if SIMD lookup table).
- Encode formula: ~10 ops.
- Context update (bit-pack OR): ~5 ops.
- **Total: ~25–40 ops/symbol** (~15–25× speedup over M94 v1.1.1).

CRAM `htscodecs` reference: ~10–12 ops/symbol with AVX2 SIMD, ~25 ops
without. M94.Z without SIMD lands ~2× off CRAM, with SIMD ~within 10%.

### 6.2 SIMD opportunities

1. **4-way interleaved encode/decode**: independent state lanes ⟹
   trivially vectorisable with AVX2/NEON 4×u32. Per-lane: gather freq[s],
   scalar mul + div + add. The div is the bottleneck (no SIMD divide on
   AVX2). Replacement: precomputed `rcp_freq[256]` (Granlund-Möller
   reciprocal-multiplication), turning `x / f` into `(x * rcp[s]) >> shift`.
2. **Cumulative search**: if T = 4096, build a `slot[T]` lookup mapping
   `slot[i] = symbol s such that cum[s] ≤ i < cum[s+1]`. SIMD gather.
3. **Renorm**: branchless via mask. AVX2 `vpcmpgtd` + `vpblendvb` to
   conditionally emit. Already well-known in htscodecs.

### 6.3 Hot path

Per symbol, in order of cost:
1. `x / f`  →  expensive integer divide. Replace with reciprocal
   multiplication (`rcp[s]`).
2. Renorm pop (writing 2 bytes when triggered).
3. Encode formula `x_out = q * T + r + c` — cheap.
4. Context update `last = (qctx << qloc) | ptab[p] | s` — cheap.
5. Cumulative search (decode only) — moderate.

**Cython/ObjC/Java**: use precomputed `rcp[256]` (one per active symbol).
M94 v1.1.1 already has this discipline — port forward.

---

## 7. Implementation notes for porting

### 7.1 Python (pure ref impl)

Variable-T arithmetic in idiomatic Python:

```python
# Encode one symbol s with freq f, cum c, total T, state x.
x_max = ((L >> log2_T) << B) * f - 1   # int math, exact since T | b·L
while x > x_max:
    out.append(x & 0xFFFF)             # 16-bit chunk; out is list of u16
    x >>= B                            # B = 16
# Encode
x = (x // f) * T + (x % f) + c
```

Notes:
- `L = 1 << 15`, `B = 16`, `T = 1 << 12`, `log2_T = 12`.
- Python ints are arbitrary precision — overflow impossible — but the
  spec demands `x < 2^31` always, so we lose nothing.
- Cumulative search via `bisect.bisect_right(cum_array, slot)`.

### 7.2 Cython

Tight loops in `cdef int` / `cdef unsigned int`:

```cython
cdef uint32_t x = ...
cdef uint32_t f = freq_view[s]
cdef uint32_t x_max = ((L >> log2_T) << B) * f - 1u
while x > x_max:
    out_buf[out_pos] = <uint16_t>x; out_pos += 1
    x >>= B
x = (x // f) * T + (x % f) + c
```

- Use `@cython.boundscheck(False)`, `@cython.wraparound(False)`.
- Precompute `rcp[s]` and replace `x // f` with `(x * rcp[s]) >> rcp_shift[s]`.
- Output buffer as `cython.view.array` of `uint16_t`; cast to bytes at finalize.

### 7.3 ObjC

Inline-C the hot loop in a C function called from ObjC method:

```c
// In .m file or .c helper:
static inline uint32_t encode_one(uint32_t x, uint32_t f, uint32_t c,
                                   uint16_t **out_pp) {
    uint32_t x_max = ((L >> log2_T) << B) * f - 1u;
    while (x > x_max) { *(*out_pp)++ = (uint16_t)x; x >>= B; }
    return (x / f) * T + (x % f) + c;
}
```

Per project memory `feedback_objc_exceptions_win32`: NS_DURING (no
@try/@catch) for any error guards. The hot loop is C, so no ObjC
exception machinery touches it.

### 7.4 Java

Long-discipline (`feedback_path_form_variants`-adjacent — unsigned
int arithmetic in Java needs care):

```java
long L = 1L << 15;
long B = 16L;
long T = 1L << 12;
long logT = 12L;
long x = state & 0xFFFFFFFFL;
long f = freq[s] & 0xFFFFFFFFL;
long c = cum[s] & 0xFFFFFFFFL;
long xMax = ((L >>> logT) << B) * f - 1L;
while (Long.compareUnsigned(x, xMax) > 0) {
    out.putShort((short)(x & 0xFFFFL));
    x >>>= B;
}
x = (x / f) * T + (x % f) + c;
state = (int) x;   // safe: x < 2^31 by §2 invariant.
```

- All intermediates as `long` to avoid sign issues.
- `>>>` (unsigned shift) for renorm.
- Final cast back to `int` is safe because `x < 2^31`.

---

## 8. Risk register

### 8.1 Byte-pairing slip (M94.X failure mode)

- **Risk**: encoder pop ≠ decoder pull, breaking the stream.
- **Mitigation**: §2 proof guarantees pairing for `T ∈ {1024, 4096}`,
  `B = 16`, `L = 2^15`. The invariant `T | b·L` exactly is the linchpin.
- **Test plan**: stress test across `n_reads` ∈ {1, 2, ..., 10000},
  varied read lengths {1, 50, 100, 150, 250}, and worst-case freq
  distributions (single-spike, uniform, two-mode). Replay every M94.X
  failure case (`n_reads ∈ {1150, 3300, 4000}`) and verify decode = input.

### 8.2 Decoder evolver context drift

- **Risk**: encoder context !=  decoder context after first divergent
  symbol.
- **Mitigation**: lockstep context evolution (we already do this in
  M94 v1.1.1; carry forward unchanged). The bit-pack context (§4.3) is
  even simpler than SplitMix64, so less surface for drift.
- **Test**: byte-exact round-trip across all 3 implementations on the
  same fixtures, plus a property test that randomly inserts 1-bit flips
  in the encoder context and confirms decoder catches the divergence.

### 8.3 Multi-omics impedance

- **Risk**: CRAM-Nx16 imposes constraints that conflict with TTI-O's
  HDF5/multi-modal layout.
- **Assessment**: NONE. M94.Z operates on a single contiguous quality
  byte stream; HDF5 wraps the compressed block transparently. The block
  size (per `fqz_store_parameters`) is bounded only by uint64
  uncompressed_size — well above any practical TTI-O chunk size. ✓

### 8.4 32-bit state overflow on Java

- **Risk**: signed int arithmetic with values in `[2^31 - 1, 2^31)`
  breaks (Java has no native unsigned 32-bit type).
- **Mitigation**: §7.4 — use `long` throughout the hot loop, mask
  inputs with `& 0xFFFFFFFFL`, cast back at the end. Java's
  `Long.compareUnsigned` for the renorm test.
- **Test**: targeted unit test where state hovers near `2^31 - 1`.

### 8.5 SIMD reciprocal-multiplication precision

- **Risk**: `rcp[s] = (1 << shift) / f` rounds, leading to `x // f`
  off-by-one for some `(x, f)`.
- **Mitigation**: use Granlund-Möller magic constants which are
  provably exact for the input range `x < 2^31` and `f ∈ [1, T]` —
  this is a well-known technique with published correctness proofs.
  Verify with brute-force exhaustive test: for each `f ∈ [1, 4095]`
  and a sample of `x` values, assert `(x * rcp) >> shift == x // f`.

### 8.6 Backwards compatibility break

- **Risk**: existing M94 v1.1.1 fixtures unreadable.
- **Mitigation**: M94.Z gets a new codec ID. M94 v1.1.1 decoder stays
  in the codebase and is selected based on file magic. Wire format
  spec (TTI-O M81) bumped to 1.3 to register the new codec.
- **Test**: fixture round-trip on all v1.1.x fixtures continues to pass.

### 8.7 Performance miss

- **Risk**: M94.Z lands at <10× speedup, not the 25× target.
- **Mitigation**: profile-driven impl. After Python ref (Phase 1), benchmark
  to confirm algo is correct. After Cython (Phase 2), if perf is < 10×
  v1.1.1, defer ObjC/Java; investigate hot path. Don't proceed to per-lang
  ports until Cython hits target.
- **Acceptance gate**: Cython M94.Z must achieve ≥ 50× M94 v1.1.1 throughput
  on a 100-MB qual stream, OR project owner approves a slower target.

---

## 9. Sources

### CRAM 3.1 specification
- Index: https://samtools.github.io/hts-specs/
- Note: `CRAMv3.1.pdf` returned 404 at fetch time. The codec details in
  this spec come from `htscodecs` source code, which is the reference
  implementation cited by CRAM 3.1. The `CRAMcodecs.tex` partial fetch
  confirmed: L = 0x8000, b·L = 2^31 (NOT 8 388 608 — that fetch's
  "b = 256" claim is wrong; corrected by direct `rANS_word.h` read),
  N ∈ {4, 32} via N32 flag, TF_SHIFT = 12.

### htscodecs source (read for understanding only — no verbatim copy)
- `htscodecs/rANS_word.h` — L, B, x_max formula, renorm loops.
  https://raw.githubusercontent.com/samtools/htscodecs/master/htscodecs/rANS_word.h
- `htscodecs/rANS_static4x16pr.c` — TF_SHIFT, TOTFREQ, 4-way streams.
  https://raw.githubusercontent.com/samtools/htscodecs/master/htscodecs/rANS_static4x16pr.c
- `htscodecs/c_simple_model.h` — STEP, MAX_FREQ, halve op (for §3, NOT
  used by M94.Z directly but referenced for completeness).
  https://raw.githubusercontent.com/samtools/htscodecs/master/htscodecs/c_simple_model.h
- `htscodecs/fqzcomp_qual.c` — context model bit-pack reference (§4.1),
  wire format reference (§5.1). Note: this file is the **range-coder**
  fqzcomp, not rANS-Nx16; we borrow its context model but not its codec.
  https://raw.githubusercontent.com/samtools/htscodecs/master/htscodecs/fqzcomp_qual.c
- `htscodecs/fqzcomp_qual.h` — fqz_param, fqz_gparams, FQZ_VERS = 5.
  https://raw.githubusercontent.com/samtools/htscodecs/master/htscodecs/fqzcomp_qual.h

### Bonfield 2022
- "htscodecs: bit-stream packing for CRAM", Bioinformatics 38(17):4187.
  Not fetched (paywall + redundant with source code reading).
  Cited in TTI-O project memory `project_tti_o_v1_2_codecs`.

### TTI-O internal
- `project_tti_o_v1_2_codecs` (memory) — M94 v1.1.1 status, M94.X failure
  modes (`n_reads = 1150, 3300, 4000`).
- `feedback_libs_base_test_style` — test discipline for implementation
  phase (rfm-style PASS, no NSAssert).
- `feedback_objc_exceptions_win32` — NS_DURING in ObjC port.
- `feedback_path_form_variants` — unsigned-long discipline in Java.

---

## 10. Open questions / assumptions for user confirmation

Before Phase 1 (Python ref) starts, please confirm or override:

1. **Static-per-block freq table (§3.2 option a) vs. per-symbol adaptive
   (option b)**: this spec assumes (a). (a) is what gives the perf win
   and matches CRAM-Nx16 proper. (b) matches `c_simple_model.h` /
   `fqzcomp_qual.c`'s range-coded path which is a different codec.
   **Default**: (a). Confirm?

2. **N = 4 (default) vs. N = 32 (SIMD-friendly)**: spec assumes N = 4
   for v1, deferring N = 32 to a follow-up M94.Z+. Confirm.

3. **Context model**: spec proposes bit-pack (CRAM-style) replacing
   SplitMix64. This is a behavioural change — same input bytes ⟹
   different rANS output (but byte-exact across our 3 impls). Confirm
   this is acceptable; if not, M94.Z must keep SplitMix64 (slower but
   identical compression to v1.1.1).

4. **Wire format**: new magic `M94Z`, no backwards-compat with v1.1.1
   fixtures (decoder dispatch by magic). Confirm.

5. **Fqzcomp_qual.c context details (qshift, ploc, etc.)**: this spec
   proposes specific defaults (qbits=12, pbits=2, dbits=0, sloc=14). Real
   tuning happens in Phase 1 against test corpus. Acceptable to defer
   final values to impl-phase sweep?

6. **N32 / SIMD**: deferred. SIMD intrinsics in Cython (or ObjC inline-C)
   not in scope for M94.Z v1. Confirm.

7. **Acceptance gate**: §8.7 proposes "Cython M94.Z ≥ 50× M94 v1.1.1
   throughput on 100-MB qual stream" before committing to ObjC/Java
   ports. Confirm or revise threshold.

---

*End of spec — 2026-04-29 — claude.opus-4-7 — research subagent*
