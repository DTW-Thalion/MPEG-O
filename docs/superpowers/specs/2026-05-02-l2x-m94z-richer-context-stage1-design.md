# L2.X — M94.Z richer-context model — Stage 1 (prototype) design

> **Two-stage spec.** Stage 1 (this document) defines a Python prototype
> harness that empirically validates 5 candidate context-model designs
> on chr22 against a hard 1.15× CRAM compression gate. Stage 2 — the
> actual V4 wire format + C kernel + Python wrapper — is written only
> after Stage 1 lands a winning candidate. Each stage is its own
> writing-plans → implementation cycle.

> **Status (2026-05-02).** Brainstormed in conversation. Stage 1 only.
> Stage 2 deferred to a separate spec, written after the prototype
> results doc lands.

> **WORKPLAN entry:** Task #84 — richer-context M94.Z.

## 0. Why this spec exists

L2 Phase B.2 (HEAD `b2a5571`) shipped the V3 adaptive Range Coder
infrastructure on chr22 at **113.33 MB / 1.316× CRAM** with qualities
at 0.393 B/qual — essentially unchanged from V1's 0.395 B/qual under
static-per-block frequencies. The V3 wire format, native C kernel
(`ttio_rans_encode_block_adaptive` / `ttio_rans_decode_block_adaptive_m94z`),
and Python ctypes wrapper all ship working with 553 M94.Z tests green
and the encode wall vectorized to 25.83 s — but **per-symbol adaptive
frequencies alone, on top of the existing context formula
(`prev_q × pos_bucket × revcomp`, `sloc=14`), do not move the needle
on chr22.** Block sizes are large enough that V1's per-block static
frequency fit is already near-optimal for that context model;
adaptivity buys only the freq-tables sidecar overhead (~5–10 KB),
which amortizes to rounding error at chr22 scale.

The remaining 14.32 MB gap (1.316× → 1.15×) is at the model layer,
not the entropy-coder layer. CRAM 3.1 fqzcomp hits 0.20–0.25 B/qual
on the same Illumina-class data via richer conditioning features —
deeper `prev_q` history at 8-bit precision, `length_bucket`, finer
`pos_bucket` — combined through a SplitMix64 hash. M94.Z V3 carries
roughly half of CRAM's modeling capacity in three different ways:

| Feature | CRAM 3.1 fqzcomp | M94.Z V3 |
|---|---|---|
| `prev_q` precision | 3 × 8-bit (24 bits) | 3 × 4-bit ring (12 bits, low-bit hash) |
| `pos_bucket` | 4-bit (16 buckets) | 2-bit (4 buckets) |
| `length_bucket` | 3-bit (8 buckets at 50/100/150/200/300/1000/10000) | absent |
| `revcomp` | 1-bit | 1-bit |
| total feature bits | 28 | ~15 |
| context table size | 4 K (after SplitMix64 → 12-bit mask) | 16 K (sloc=14, no hash) |

Task #84 closes the model gap. This Stage 1 spec defines the
empirical validation phase that picks *which* feature set + encoding
discipline to commit to, before any C kernel work is done.

## 1. Goal and gate

**Goal.** Pick a candidate context model that, when fed through the
existing V3 RC kernel, hits **≤ 1.15× CRAM (~99 MB) on
`chr22_na12878_mapped`**.

**Gate.** Hard. If no candidate hits 1.15×, the prototype's results
doc triggers an escalation decision (§5), not a Stage 2 spec.

**Why empirical validation is the right proof phase here.** Per
`feedback_phase_0_spec_proof`, wire-format-breaking codec rewrites
need a math/spec proof phase before implementation. L2 itself had
algebraic invariants for byte-pairing under variable T (rANS state
range, then the Range Coder pivot). Task #84 introduces no new
entropy-coding math — the V3 RC kernel is unchanged. The "proof"
obligation here is information-theoretic and operational: does a
candidate context model achieve the target compression on real data,
within the operational ceilings, before we pay for a wire-format
break + 3-language wrapper port? Empirical measurement on chr22 is
the appropriate validation; the prototype harness is the proof
artifact.

## 2. Approach

Hybrid bit-pack with CRAM-equivalent features. Keep TTI-O's bit-pack
discipline (cheap reversible context construction, ~5 ops/symbol vs
~20 for SplitMix64) but expand the feature set to match CRAM's
conditioning capacity.

Quantization moves from V3's `q & 0xF` low-bit hash to **value-aligned
`(q − 33) >> N`** for `prev_q` features — silently fixes a known
weakness where Q0 (`q=33`) collides with Q16 (`q=49`) under V3's
hash. Same bits, much better signal.

A SplitMix64-hash candidate (`c4` below) is included as a reference
to isolate "feature gap" vs "hash gap": if the hash candidate hits
1.15× but no bit-pack candidate does, we know the bit-pack constraint
itself is binding and the Stage 2 spec must escalate to hash.

## 3. Operational ceilings

The prototype harness must respect:

| Ceiling | Value | Why |
|---|---|---|
| `sloc` (context-table log2-size) | **≤ 17** (≤ 128 K contexts, ≤ 64 MB freq tables in C) | Externalized RAM cost; ships in users' processes |
| Encode wall (chr22) | soft; document, don't gate | One-time compression cost; users tolerate seconds, not GB |
| Decode wall (chr22) | soft; document | C-driven path; bigger freq tables hurt cache but not fatally |
| Memory during encode | ≤ ~1 GB peak (well inside chr22 fits) | Practical |

V3's encode wall (25.83 s) is the reference; a 2–3× regression on a
candidate that wins compression by 15+% is acceptable.

## 4. Candidate set

Five candidates measured in one prototype run on chr22. Each
bit-pack candidate (`c1`/`c2`/`c3`) sums to exactly 17 feature bits
masked to `sloc=17` (no hash collisions). `c0` and `c4` are
references.

### 4.1 Bit budgets

| ID | `prev_q` | `pos_bucket` | `length_bucket` | `revcomp` | Mechanism | sloc |
|---|---|---:|---:|---:|---|---:|
| **c0** | 4-bit ring × 3 (low-bit hash, `q & 0xF` per symbol) | 2 b (4) | — | 1 b | bit-pack mask | 14 |
| **c1** | 4 b (q≫2) + 3 b (q≫3) + 2 b (q≫4), value-aligned | 4 b (16) | 3 b (CRAM bounds) | 1 b | bit-pack mask | 17 |
| **c2** | 4 b × 3 symbols, value-aligned | 4 b (16) | — | 1 b | bit-pack mask | 17 |
| **c3** | 8 b (q − 33), full-Phred-aligned, single symbol | 4 b (16) | 4 b (16, finer than CRAM) | 1 b | bit-pack mask | 17 |
| **c4** | 3 × 8 b (raw byte) | 4 b (16) | 3 b (CRAM bounds) | 1 b | SplitMix64 → mask | 12 (4 K, CRAM-exact) |

### 4.2 Why these five

- **c0** — V3 unchanged baseline. The published 113.33 MB / 1.316×
  number this design is trying to beat.
- **c1** — closest analog to CRAM 3.1 inside the bit-pack constraint.
  Decreasing `prev_q` precision with depth (the 3rd-back symbol is
  much less informative than the 1st-back; spend bits accordingly).
  If CRAM-style features generally help, c1 should win.
- **c2** — tests the hypothesis that `length_bucket` is mostly noise
  on Illumina chr22 (uniform ~100 bp reads). If c2 ≥ c1, drop length.
- **c3** — bets on a single full-precision symbol of history plus
  fine length conditioning. Tests whether deep history is necessary.
- **c4** — pure CRAM port for reference. SplitMix64 hash on the full
  28-bit feature vector → 12-bit index → 4096 contexts (CRAM
  defaults). If c4 dramatically beats c1/c2/c3, the hash itself is
  doing real work and the bit-pack hypothesis is structurally
  limited; Stage 2 must escalate to hash.

### 4.3 Quantization

Phred-33 ASCII encoding: `q ∈ [33, 126]`, Phred value
`P = q − 33 ∈ [0, 93]`. NA12878 chr22 clusters in `P ∈ [0, 40]`.
Quantizations:

| Bits | Formula | Bins | Notes |
|---|---|---:|---|
| 8 | `q − 33` | 64–94 | Full Phred precision; clamped to byte |
| 4 | `(q − 33) >> 2` | 16 | Spans Q0..Q63 in 4-Phred-wide bins |
| 3 | `(q − 33) >> 3` | 8 | Spans Q0..Q63 in 8-Phred-wide bins |
| 2 | `(q − 33) >> 4` | 4 | Coarse: Q0–15, 16–31, 32–47, 48+ |

`prev_q` resets to 0 at every read start, mirroring V3 / M94 v1
convention. Pad bytes (positions ≥ `len(qualities)`) use
`pad_ctx = m94z_context(0, 0, 0, ...)` regardless of feature set.

### 4.4 `length_bucket` boundaries

CRAM 3.1 directly: `(50, 100, 150, 200, 300, 1000, 10000)`.
`length_bucket = first index i where read_length ≤ boundary[i]` (so 8
buckets including the catch-all). No chr22-tuning; we want
generality.

### 4.5 `pos_bucket` formula

V3 spec §4.2 already standardizes
`pos_bucket = min(2^pbits − 1, (pos × 2^pbits) // read_length)`.
Same formula at 2-bit (c0) or 4-bit (c1/c2/c3/c4).

### 4.6 SplitMix64 (c4 only)

Reference fingerprint per `htscodecs/fqzcomp_qual.c`; the M94.Z V1
spec already documented this in §80d before the bit-pack pivot.
Build the 64-bit feature key:

```
bits  0.. 7 : prev_q[0]                   (raw byte, Phred-33 ASCII)
bits  8..15 : prev_q[1]
bits 16..23 : prev_q[2]
bits 24..27 : pos_bucket  (4 bits)
bits 28     : revcomp_flag (1 bit)
bits 29..31 : length_bucket (3 bits)
bits 32..63 : context_hash_seed = 0xC0FFEE
```

Then SplitMix64 mix:

```c
uint64_t splitmix64(uint64_t x) {
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}
ctx = splitmix64(key) & ((1 << sloc) - 1);   // sloc = 12
```

Identical to CRAM 3.1 default. Prototype implements in pure Python /
numpy.

## 5. Decision rule

After the prototype harness lands (one chr22 run, 5 candidates), the
results doc summarizes compressed size + B/qual + ratio vs CRAM
(86.094 MB) for each candidate. The decision rule:

| Outcome | Action |
|---|---|
| Some bit-pack candidate (c1/c2/c3) hits ≤ 1.15× | Stage 2 spec around that candidate's bit budget. Bit-pack discipline preserved. Done. |
| Only c4 (hash) hits ≤ 1.15× | Escalate. Stage 2 spec uses SplitMix64 hash. Option B was wrong; Option A wins. |
| Best candidate ∈ (1.15×, 1.316×) | All candidates fail. Prototype's findings inform a re-charter discussion: extend feature set (`distance_from_end`, mate-pair, error-context), or renegotiate the v1.2.0 gate. No Stage 2 spec until re-charter resolves. |
| Best candidate ≥ c0's 1.316× | Fundamental model wrong. Brainstorm Task #84 again from scratch. |

## 6. Prototype harness

### 6.1 Location

```
tools/perf/m94z_v4_prototype/
├── README.md                  # how to run, expected output
├── candidates.py              # 5 context-derivation functions, vectorized
├── harness.py                 # entry point: load BAM, run candidates, emit results
└── verify_roundtrip.py        # per-candidate decode + byte-exact check
```

Throwaway research code. No pytest integration. No ObjC / Java port.
Lives outside `python/src/` and `python/tests/`.

### 6.2 Candidate function signature

```python
def derive_contexts_<id>(
    qualities: bytes,
    read_lengths: np.ndarray,    # int64
    revcomp_flags: np.ndarray,   # uint8 (0/1)
    n_padded: int,
    sloc: int,
) -> tuple[np.ndarray, int]:
    """Return (sparse_seq, n_active_estimate).

    sparse_seq is ndarray[uint32] of length n_padded; sparse_seq[i] is
    the raw context value (in [0, 2^sloc)) for symbol i. uint32 not
    uint16 because sloc=17 produces values up to 131071 which does
    not fit in uint16.

    n_active_estimate is an upper bound on distinct sparse contexts
    actually used (n_active is computed by the first-encounter pass at
    the harness level, not the candidate level).
    """
```

Five implementations: `derive_contexts_c0` (mirrors current V3
`_build_context_seq_arr_vec`), `derive_contexts_c1`, `c2`, `c3`,
`c4`. Each is numpy-vectorized in the same shape as
`_build_context_seq_arr_vec` — one outer loop over `p = 0..max_len`,
all reads updated in parallel via numpy ops. The c4 SplitMix64 variant
just does the hash inline in numpy.

### 6.3 Encode pipeline per candidate

```
qualities, read_lens, revcomp_flags  ─→  derive_contexts_<id>  ─→  sparse_seq
                                                                       │
                                                                       ▼
                                              _vectorize_first_encounter (existing)
                                                                       │
                                                                       ▼
                                              dense_seq, sparse_ids, n_active
                                                                       │
                                                                       ▼
                                  ttio_rans_encode_block_adaptive (existing C entry)
                                                                       │
                                                                       ▼
                                                           rc_body bytes
```

The harness reuses the existing `_vectorize_first_encounter` and
the V3 C entry — no Python or C changes outside
`tools/perf/m94z_v4_prototype/`.

### 6.4 Round-trip verification

For each candidate, decode the produced `rc_body` via the same
`derive_contexts_<id>` (or by stashing the dense sequence) and
`ttio_rans_decode_block_adaptive_m94z`, then assert
`decoded_qualities == qualities_in` byte-for-byte. This is
candidate-by-candidate; not a unit test.

(Detail: V3 decode currently re-derives contexts inline in C using
the M94.Z V3 formula. For the prototype, decode-side context
derivation will live in Python alongside the encode-side derivation
to avoid C kernel changes. This is acceptable because the prototype
is for compression validation only — decode-side perf isn't being
measured.)

### 6.5 Results doc

Lands at `docs/benchmarks/2026-05-02-m94z-v4-candidates.md` with:

- Host + git HEAD
- Per-candidate row: compressed bytes, B/qual, vs-V1 delta, vs-CRAM
  ratio, encode wall (Python harness, indicative only), decode wall,
  `n_active`, peak freq-table memory estimate
- Diagnostic stats per candidate: distinct contexts used, mean
  symbols/context, top-10 most-frequent contexts and their entropy
- Decision rule output: which §5 case fired
- If a winner is identified: a one-paragraph "Stage 2 starting point"
  pointing at the bit budget + feature set to spec

## 7. Out of scope (Stage 1)

- C kernel changes
- V4 wire format definition
- Java JNI / ObjC wrapper updates
- Test fixtures or pytest integration of the prototype
- Production code paths into the prototype's candidates
- Mate-pair / error-context / distance-from-end features (only fire
  if §5's "all fail, re-charter" path triggers)
- Automation / CI integration

## 8. Acceptance criteria

Stage 1 is done when:

1. The 5 candidate functions are implemented and vectorized.
2. A single harness invocation runs all 5 on
   `data/genomic/na12878/na12878.chr22.lean.mapped.bam`, completing
   within an hour of wall time end-to-end (rough cap; actual is
   probably minutes).
3. Each candidate's output round-trips byte-exact.
4. The results doc lands and identifies the §5 outcome category.
5. WORKPLAN's Task #84 entry references the results doc and either
   (a) names the Stage 2 winner, or (b) records the re-charter
   discussion.

The Stage 2 spec is *not* a Stage 1 deliverable.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| All bit-pack candidates miss 1.15× | c4 hash baseline tells us which way to escalate (§5) |
| c4 hash also misses 1.15× | Re-charter (§5); not a wasted prototype — the data informs the re-charter |
| Prototype encode is too slow on chr22 (pure-Python ctx derivation × 178 M qualities) | All candidates use numpy vectorization in the same shape as `_build_context_seq_arr_vec`. Measured prior: vectorized V3 ctx derivation runs in ~5 s of pure-numpy time. 5 candidates × 5 s + RC kernel call × 5 ≈ minutes |
| Prototype's compression numbers don't match Stage 2's eventual implementation | The prototype uses the same C RC kernel as production. Compression is a function of (sym, ctx) pairs only; if ctx derivation produces the same dense sequence in Python and (eventually) in C, output is byte-exact. Verified by §6.4 round-trip |
| sloc=17 wastes memory if winner has effective `n_active` ≪ 128 K | The dense remap in V3's wire format only stores `n_active` contexts (not all 2^sloc). Memory is fine in the kernel; only the freq-table workspace is sloc-sized |

## 10. Stage 2 trigger and structure

Stage 2 spec gets written if and only if §5 lands a "winner" case
(bit-pack hit, hash escalation, or — possibly — a re-chartered
broader feature set after Stage 1's re-charter discussion).

Stage 2 covers:

- V4 wire-format (header, body, version byte = 4, `context_params` and
  any new fields — e.g. `length_bucket_boundaries` if CRAM's are
  hard-coded vs configurable)
- C kernel changes (context derivation in C, mirroring Task #81's
  `ttio_rans_decode_block_m94z` pattern, but for the new feature set)
- Python wrapper update (replace `_build_context_seq_arr_vec`
  contents)
- chr22 conformance test (formal hard-gate check that the C
  implementation matches the prototype's compressed output
  byte-exact)
- Migration: V3 stays as the readable floor for files written before
  V4; V4 supersedes V3 for new writes
- Java + ObjC wrappers explicitly remain deferred to a follow-up
  ("Stage 3"); only after Stage 2 ships and is stable in Python

Stage 2 has its own writing-plans → implementation cycle; this
document does not pre-empt it.

## 11. References

- L2 spec: `docs/superpowers/specs/2026-05-01-l2-m94z-adaptive-design.md`
- L2 plan: `docs/superpowers/plans/2026-05-01-l2-m94z-adaptive.md`
- L2 results: `docs/benchmarks/2026-05-01-chr22-byte-breakdown.md` §8
- M94 v1 (CRAM-mimic with SplitMix64) doc:
  `docs/codecs/fqzcomp_nx16.md` §80d
- M94.Z (current bit-pack) doc: `docs/codecs/fqzcomp_nx16_z.md`
- htscodecs upstream reference: `fqzcomp_qual.c`
  (samtools/htscodecs)
- Memory:
  `feedback_phase_0_spec_proof.md`,
  `feedback_rans_nx16_variable_t_invariant.md`,
  `feedback_pwd_mangling_in_nested_wsl.md`,
  `project_tti_o_v1_2_codecs.md`
