# NAME_TOKENIZED v2 design — TTI-O #11 channel 3

**Status:** approved 2026-05-04, ready for implementation plan.
**Target ship:** v1.9 (TTI-O `read_names` channel default).
**Hard gate:** ≥ 3 MB savings on chr22 NA12878 lean+mapped vs NAME_TOKENIZED v1.
**Codec id:** 15. **Wire magic:** `NTK2`. **Container version:** `0x01`.

## 1. Motivation

NAME_TOKENIZED v1 (codec id 8, M85 Phase B / M86 Phase E) compresses
`read_names` by tokenising each name into numeric/string tokens and
encoding columns separately (per-column delta-coded numerics, inline
dictionary for strings). On chr22 NA12878 lean+mapped (1,766,433 reads,
typical Illumina names) v1 produces a 7.14 MB encoded stream — about
5.9× compression vs raw, well under the Bonfield 2022 / CRAM 3.1 lean of
~20×.

The 7.14 MB is the third-largest signal channel after qualities (M94.Z,
69.7 MB) and sequences (REF_DIFF v2, ~6.8 MB encoded as of v1.8). At
chr22's 1.965×→1.220× compression progression, read_names is the next
codec lever to chip at the gap to CRAM 3.1.

**Goal:** add a v2 codec that closes ~half the gap to CRAM (target 3-4
MB savings on chr22) while staying inside the established #11
implementation pattern (shared C kernel + 3-language bindings +
cross-language byte-exact gate). v2 is wire-format-breaking (new codec
id); v1 stays read-compat.

## 2. What v2 adds vs v1

Three additive features, in order of expected savings:

1. **DUP-pool** — per-block FIFO of last 8 fully-decoded names. Each
   read may encode as a 3-bit pool index (full DUP) or a `(pool_idx,
   K)` PREFIX-MATCH against a pool entry. Catches paired-end reads
   that share a QNAME, plus structural similarities within a sliding
   window in position-sorted BAMs.
2. **Multi-substream layout** — split per-read flags, pool indices,
   match lengths, numeric deltas, dict codes, dict literals, and
   verbatim payloads into separate substreams, each independently
   rANS-O0-coded (auto-pick rANS-O0 vs raw passthrough per substream,
   smallest wins).
3. **Block reset at HDF5 chunk boundary** — pool resets every 4096
   reads, matching the existing HDF5 chunk size for `read_names`. Each
   block is independently decodable; container header carries a block
   offsets index for O(1) seek to any block.

Tokenisation rules from v1 are reused unchanged. The fallback
**verbatim** mode is preserved as a per-read escape (FLAG=11) for
malformed batches, but DUP/MATCH stay live across heterogeneous
shapes within a block.

## 3. Algorithm

### 3.1 Tokenisation (unchanged from v1)

Two-token-type model: numeric tokens are maximal digit-runs that are
either `"0"` or have no leading zero; string tokens are everything
else (with leading-zero digit-runs absorbed into surrounding string
tokens). See `docs/codecs/name_tokenizer.md` §1.1 for the full rules
including worked examples. v2 reuses v1's `_tokenize` function
verbatim.

### 3.2 Block partitioning

Reads are grouped into **blocks** of up to **B = 4096 reads** (last
block may be shorter). 4096 matches the `read_names` HDF5 chunk size,
so block boundaries align naturally with HDF5 chunks. Each block is
independently decodable.

### 3.3 Per-block DUP-pool

A FIFO of up to **N = 8** previously-decoded full names. State at
block start: empty pool. After each read decodes successfully, push
its full name to the back of the pool; if `len(pool) > N`, evict from
the front. Pool indexing: pool entries are addressed `pool_idx ∈
{0..len(pool)-1}` from oldest (0) to newest (len-1).

Note: pool_idx is encoded as 3 bits regardless of `len(pool)`. When
`len(pool) < 8` the encoder MUST emit a pool_idx within
`[0, len(pool))` (out-of-range = decoder error).

### 3.4 Per-read encoding strategies

For each read in block order, the encoder picks ONE of four strategies
encoded by a 2-bit FLAG:

| FLAG | Strategy | Body |
|------|----------|------|
| `00` | **DUP** — full match against pool entry | 3 bits `pool_idx` |
| `01` | **MATCH-K** — first K token columns match a pool entry, suffix differs | 3 bits `pool_idx` + varint K + suffix tokens (numeric deltas + dict codes) |
| `10` | **COL** — full columnar tokens, no match | numeric deltas + dict codes per column |
| `11` | **VERB** — verbatim length-prefixed bytes | varint length + raw bytes |

**Encoder selection:** for each read, the encoder MUST select the
smallest representable strategy in this priority order:

1. If any pool entry is byte-equal to the read, pick **DUP** with the
   smallest such `pool_idx`.
2. Otherwise, for each pool entry, compute K = the number of leading
   token-columns that match (token type AND value byte-equal). If
   any pool entry has K ≥ 1 AND K < (this read's column count), pick
   **MATCH-K** with the largest K, breaking ties by smallest pool_idx.
   Additional constraint: MATCH-K is only legal if (a) the row's own
   tokenisation matches the block's COL_TYPES shape (n_columns and
   per-column types — see §3.5) AND (b) the pool entry's first K
   columns have token types matching the block's COL_TYPES first K
   columns. If neither (a) nor (b) holds for any candidate pool entry,
   skip MATCH-K.
3. Otherwise, if the read can be represented in COL mode (the COL
   column-type table for this block is compatible — see §3.5), pick
   **COL**.
4. Otherwise, pick **VERB**.

**Encoding determinism:** the algorithm above is deterministic; given
the same input list it produces byte-identical output across all
reference implementations.

### 3.5 COL column-type table (per block)

The first read in a block that picks COL or MATCH-K (because both
emit columnar tokens) determines the block's `n_columns` and per-column
type bitmap (numeric vs string). All subsequent COL/MATCH-K rows in
the same block MUST match this shape exactly:

- Same `n_columns`.
- Same column-type bitmap (per-column numeric/string).

If a read in the block can't satisfy these constraints, the encoder
MUST pick VERB for that read instead. (DUP doesn't have this
constraint because it reuses a pool entry's full-byte representation.)

### 3.6 Numeric column delta state

Numeric column delta encoding (zigzag varint of `value - prev_value`)
maintains per-column state across COL+MATCH-K rows in a block, in
read order. The first COL or MATCH-K row's numeric tokens emit as
seed values (non-zigzag varints, value as-is). Subsequent rows emit
zigzag varints of the delta against the most recent prior row's
column value.

**MATCH-K subtlety:** for a MATCH-K row, columns `[0, K)` are matched
(values come from the pool entry), and only columns `[K, n_columns)`
emit deltas. Columns `[0, K)` still update the per-column delta state
(so the prev-value for column j after a MATCH-K row is the pool
entry's column j value).

### 3.7 String column dictionary state

Per-column dictionary state is shared across COL+MATCH-K rows in a
block. Same protocol as v1: literal-and-add. Code 0..D-1 = lookup,
code D = "new literal follows" (then `varint(len) + bytes`, push to
dict). MATCH-K rows for matched prefix columns DO NOT update the
dict (the matched value came from the pool, not as a fresh literal).
For unmatched suffix columns in MATCH-K, dict state updates as in COL.

### 3.8 Decode

1. Parse container header. Validate magic, version, n_reads.
2. For each requested block:
   - Parse block header (n_reads, body_len).
   - Parse 8 substreams (each with mode prefix; rANS-O0 decode if
     mode=01).
   - Replay per-read FLAG → reconstruct each name:
     - DUP: copy `pool[pool_idx]` to output, push to pool.
     - MATCH-K: take pool entry's first K columns; decode remaining
       suffix tokens from NUM_DELTA + DICT_CODE/DICT_LIT. Concatenate
       all column tokens to form the name. Update per-column delta
       state with all columns' values. Push reconstructed name to pool.
     - COL: decode all column tokens. Update column-type table on
       first COL row. Update delta + dict state. Push to pool.
     - VERB: decode `varint len + bytes` from VERB_LIT. Push to pool.

## 4. Wire format

Big-endian for the 4-byte magic; little-endian for everything else.
Varints unsigned LEB128 (low 7 bits first, top bit = continuation).
Signed varints zigzag (`(n << 1) ^ (n >> 63)`) then unsigned LEB128.

### 4.1 Container header

```
+--------+-------+--------+-----+-------+-------+-------+ ... +-------+
| "NTK2" | 0x01  | flags  | nrd | nblk  | bof_0 | bof_1 | ... | bof_K |
+--------+-------+--------+-----+-------+-------+-------+ ... +-------+
   4         1       1       4     2       4       4              4
```

| Field | Bytes | Type | Notes |
|-------|------:|------|-------|
| magic | 4 | bytes | `0x4E 0x54 0x4B 0x32` ("NTK2") |
| version | 1 | u8 | `0x01` |
| flags | 1 | u8 | bit 0 = empty stream (n_reads = 0); bits 1-7 reserved (must be 0; non-zero rejected on decode) |
| n_reads | 4 | u32 LE | total reads across all blocks |
| n_blocks | 2 | u16 LE | total blocks (≤ 65535; max ~268M reads at 4096/block) |
| block_offset[i] | 4 each | u32 LE | offset of block i body relative to start of first block; n_blocks entries; cumulative — block 0's offset is always 0 |

Empty stream: `flags.bit0 = 1`, `n_reads = 0`, `n_blocks = 0`. Total
container = 12 bytes (no offsets array).

### 4.2 Block

```
+-------+-------+-----------------------------------------+
| n_blk | bod_l |  body (8 substreams)                    |
+-------+-------+-----------------------------------------+
   4       4
```

| Field | Bytes | Type |
|-------|------:|------|
| block_n_reads | 4 | u32 LE (≤ 4096) |
| block_body_len | 4 | u32 LE |
| body | block_body_len | substreams |

### 4.3 Block body — 8 substreams

Each substream is prefixed with a 4-byte LE length (of the body that
follows the mode byte) + 1-byte mode + body bytes.

```
+--------+------+----------+
| bdy_l  | mode | body     |
+--------+------+----------+
   4       1      bdy_l
```

Mode byte values:

| Mode | Meaning |
|------|---------|
| `0x00` | raw passthrough (body = uncompressed bytes) |
| `0x01` | rANS-O0 (body = `ttio_rans_o0_encode(...)` output of the uncompressed bytes; decoder must call `ttio_rans_o0_decode`) |

Encoder picks the smaller-output mode per substream. If both produce
identical sizes, pick `0x00`.

Substream order is **fixed**:

| # | Name | Uncompressed body |
|---|------|-------------------|
| 1 | FLAG | 2 bits per read, bit-packed, MSB-first within each byte → ⌈n_reads/4⌉ bytes |
| 2 | POOL_IDX | 3 bits per row where FLAG ∈ {DUP, MATCH-K}, bit-packed, MSB-first → ⌈n_pool_rows × 3 / 8⌉ bytes |
| 3 | MATCH_K | varint K per MATCH-K row, in read order |
| 4 | COL_TYPES | emitted only if any COL or MATCH-K row exists in block: `u8 n_columns (1..255) + ⌈n_columns/8⌉ bytes column-type bitmap (bit = 0 numeric, 1 string, MSB-first within each byte)`. Empty body if block has no COL/MATCH-K rows. |
| 5 | NUM_DELTA | row-major: for each COL row in block order, emit values for numeric cols 0..n_cols-1 in order; for each MATCH-K row, emit values for numeric cols K..n_cols-1 in order (matched cols [0,K) come from pool entry; nothing written to NUM_DELTA for matched cols). First emission per column j across the block is an unsigned varint (seed); subsequent are zigzag-then-unsigned-varint deltas. After a MATCH-K row, col_num_prev[j] for j ∈ [0,K) is set to pool entry's col j value (used to compute deltas for any later emission of col j). |
| 6 | DICT_CODE | row-major (same walk order as NUM_DELTA), all string-column codes for COL + MATCH-K-suffix emissions. Each is an unsigned varint. |
| 7 | DICT_LIT | for each new literal added to any string column dictionary, in the order the literal was added (which is the order the row appeared in the block × column index): `varint(byte_len) + bytes`. |
| 8 | VERB_LIT | for each VERB row in read order: `varint(byte_len) + bytes`. |

### 4.4 Decoder invariants

The decoder MUST reject (clean error, no crash):

- Stream length < 12 (header truncation).
- magic ≠ `"NTK2"`, version ≠ `0x01`, flags has any reserved bit set.
- n_blocks · 4 + 12 > stream length (offsets table truncation).
- Any block_offset that points past the end of the stream.
- block_n_reads = 0 OR > 4096.
- pool_idx ≥ current pool length at decode time.
- MATCH-K K = 0 OR K ≥ current row's column count (K must be a strict
  prefix shorter than the row's columns, since K = full match would be
  encoded as DUP).
- COL/MATCH-K row whose column count or column-type bitmap differs
  from the block's COL_TYPES.
- Substream mode ∉ {0x00, 0x01}.
- Sum of substream sizes ≠ block_body_len.
- DICT_CODE > current dict size (dict overflow).

Each rejection: Python `ValueError`, ObjC `NSError**` with `nil`
return, Java `IllegalArgumentException`.

### 4.5 Forward-compat reservation

Reserved bits in `flags` (bits 1-7) and reserved mode values (`0x02..
0xFF`) MUST be rejected by v1.x decoders. A future v2.1 may use them
but will increment the version byte first.

## 5. C API

```c
// native/include/ttio_rans.h additions

typedef struct {
    int reserved;  // must be 0; future flags
} ttio_name_tok_v2_options;

// Encode N read names. names is an array of N C-strings (NUL-terminated,
// 7-bit ASCII; non-ASCII or NUL-in-middle returns TTIO_ERR_INVALID).
// Returns 0 on success, sets *output (caller frees with free()) and
// *output_len. Non-zero on error, sets *error.
int ttio_name_tok_v2_encode(
    const char * const *names, size_t n_reads,
    const ttio_name_tok_v2_options *options,
    uint8_t **output, size_t *output_len,
    char **error);

// Decode a v2 stream. Returns 0 on success, allocates *names array
// (caller frees each entry + the array with free()). Sets *n_reads.
int ttio_name_tok_v2_decode(
    const uint8_t *input, size_t input_len,
    char ***names, size_t *n_reads,
    char **error);
```

## 6. Python API

```python
# python/src/ttio/codecs/name_tokenizer_v2.py

def encode(names: list[str], *, prefer_native: bool | None = None) -> bytes:
    """Encode names to NAME_TOKENIZED v2 wire format.
    
    prefer_native: None (auto, native if libttio_rans loaded), True (force
    native, raise if not loaded), False (force pure-Python).
    """

def decode(blob: bytes) -> list[str]:
    """Decode a NAME_TOKENIZED v2 wire format blob."""

def get_backend_name() -> str:
    """Returns 'native' or 'pure-python'."""
```

The pure-Python implementation is the spec of record (mirroring v1
and ch1/ch2). The native path delegates to `ttio_name_tok_v2_encode/
_decode` via ctypes and is byte-equal.

## 7. Java API

```java
// java/src/main/java/global/thalion/ttio/codecs/NameTokenizerV2.java

public final class NameTokenizerV2 {
    public static byte[] encode(List<String> names);
    public static List<String> decode(byte[] blob);
    public static String getBackendName();  // "native-jni" or "pure-java"
}
```

JNI binding at `native/src/ttio_name_tok_v2_jni.c` calls the C entries.
A pure-Java fallback exists for environments without the native library.

## 8. ObjC API

```objc
// objc/Source/Codecs/TTIONameTokenizerV2.h

@interface TTIONameTokenizerV2 : NSObject
+ (NSData *)encodeNames:(NSArray<NSString *> *)names;
+ (NSArray<NSString *> *)decodeData:(NSData *)blob error:(NSError **)error;
+ (NSString *)backendName;  // @"native" (always — direct C link)
@end
```

ObjC links the C library directly (per `feedback_libttio_rans_api_layers`).

## 9. Cross-language byte-exact contract

Python's pure-Python implementation is the spec of record. All four
language paths (Python pure / Python native / Java native / ObjC native
/ Java pure-Java fallback) MUST produce byte-identical output for the
same input.

**Conformance fixtures** (extending v1's four):

| Fixture | Input | Tests |
|---------|-------|-------|
| `name_tok_v2_a.bin` | 5 Illumina-style names with shared prefix | All COL, no DUP/MATCH; baseline |
| `name_tok_v2_b.bin` | 8 names where reads 4-7 are full duplicates of reads 0-3 | DUP path |
| `name_tok_v2_c.bin` | 6 names where reads 1-5 differ from read 0 only in the last numeric column | MATCH-K with K = n_cols - 1 |
| `name_tok_v2_d.bin` | empty list | Empty-stream container |
| `name_tok_v2_e.bin` | 4 names with mixed token shapes (forces VERB for some rows) | VERB fallback |
| `name_tok_v2_f.bin` | 4097 names (forces 2-block split) | Multi-block + block-reset |

**4-corpus integration gate** at
`python/tests/integration/test_name_tok_v2_cross_language.py`:

| Corpus | Expected |
|--------|----------|
| chr22 NA12878 lean+mapped | All 3 langs produce identical bytes |
| NA12878 WES chr22 | All 3 langs produce identical bytes |
| HG002 Illumina 2×250 chr22 | All 3 langs produce identical bytes |
| HG002 PacBio HiFi | SKIP if BAM lacks read names; else all 3 langs identical |

## 10. Compression gate

Hard gate at `python/tests/integration/test_name_tok_v2_compression_gate.py`:

```
v1 read_names size on chr22 NA12878 lean+mapped: 7,143,424 bytes (7.14 MB)
v2 read_names size on chr22 NA12878 lean+mapped: ≤ 4,000,000 bytes (≤ 3.81 MB)

Gate: (v1_size - v2_size) >= 3,000,000 bytes (3 MB savings).
```

The gate measures the actual encoded read_names dataset size in both
files (HDF5 framing included for fairness). Test fails CI if savings <
3 MB.

## 11. Default + opt-out

- v1.9 writers default `read_names` codec to NAME_TOKENIZED_V2 (codec
  id 15).
- Opt-out flag:
  - Python: `WrittenGenomicRun.opt_disable_name_tokenized_v2`
  - Java: `WrittenGenomicRun.optDisableNameTokenizedV2`
  - ObjC: `TTIOWrittenGenomicRun.optDisableNameTokenizedV2`
- When opt-out flag is True, writer emits codec id 8 (v1) instead.
- Reader auto-detects codec id from `@compression` attr (codec id 8 →
  v1 path, codec id 15 → v2 path).
- v1.x readers (pre-v1.9) cannot read codec id 15 streams; they raise
  "unknown codec id" at read time. v1.x → v1.9 forward-compat is
  read-only via the opt-out flag (writer can downgrade to v1).

## 12. Forever-frozen wire constants

| Constant | Value | Rationale |
|----------|------:|-----------|
| Pool size N | 8 | 3-bit index. Catches paired reads within typical insert-size window in position-sorted BAM. Sweep validated in Phase 0 prototype. |
| Block size | 4096 reads | Matches existing HDF5 chunk size; no new boundary concept. |
| MATCH granularity | token column | Natural given v1 tokeniser; simpler than byte-level. |
| Magic | `NTK2` | Parallel to ch1/ch2 magic conventions. |
| Codec id | 15 | Next free after ch1=13, ch2=14. |

## 13. Out of scope

- Bonfield 2022 / CRAM 3.1 byte-equality (separate "v3" cycle if
  pursued).
- Eight-token-type model (DIGIT0/MATCH/DUP/ALPHA-CHAR distinction at
  the token level).
- `cigars` channel adoption (RANS_ORDER1 stays default per WORKPLAN).
- `mate_info_chrom` (already obsolete via ch1's MATE_INLINE_V2).
- Sub-block random-access (would need per-read offset table — too
  costly for the tiny use case).
- UTF-8 / non-ASCII names (v1 limitation preserved).

## 14. Risk & mitigation

| Risk | Mitigation |
|------|------------|
| Forever-frozen N=8 wrong for some corpus | Phase 0 sweep validates {4, 8, 16, 32} on chr22 + WES + HG002 Illumina before committing |
| Block-boundary modeling loss (~1.8% of reads start with empty pool) | Within 3-4 MB target by design; verified in Phase 0 |
| MATCH-K spec ambiguity (column-vs-byte) | Spec §3.4 fixes "MATCH-K = K full token columns from start", not bytes |
| PacBio HiFi corpus may have `*` for QNAME | Probe before encoding; SKIP gate if so (per `feedback_pacbio_hifi_qual_stripped` pattern) |
| Cross-language tokeniser drift | v2 reuses v1's tokeniser; v1 cross-language byte-exact gate already covers the tokeniser |

## 15. Phase 0 prototype (proof phase per `feedback_phase_0_spec_proof`)

Before the multi-language implementation, a Python-only prototype at
`tools/perf/name_tok_v2_prototype/` runs end-to-end on the available
benchmark corpora that have read names (chr22 NA12878, WES NA12878,
HG002 Illumina; PacBio HiFi probed and SKIP'd if BAM has no names):

1. Implements the algorithm end-to-end (encode + decode roundtrip).
2. Measures actual chr22 savings vs v1.
3. Sweeps pool size N ∈ {4, 8, 16, 32} on the 3 Illumina corpora.
4. Sweeps block size B ∈ {1024, 4096, 16384} on chr22.
5. Validates: chr22 savings ≥ 3 MB at the chosen (N=8, B=4096) settings.

If Phase 0 shows the gate isn't reachable, the design is revisited
before any C/Java/ObjC code. Same protocol that caught M94.X's
invariant break.

Phase 0 deliverables:
- `tools/perf/name_tok_v2_prototype/encode.py` + `decode.py`
- `tools/perf/name_tok_v2_prototype/benchmark.py`
- `docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md`

## 16. File map

| Layer | File |
|-------|------|
| C kernel | `native/src/name_tok_v2.{c,h}` |
| C headers (public) | `native/include/ttio_rans.h` (extended) |
| C tests | `native/tests/test_name_tok_v2_*.c` |
| Python wrapper | `python/src/ttio/codecs/name_tokenizer_v2.py` |
| Python tests | `python/tests/test_name_tok_v2_*.py` |
| Python integration | `python/tests/integration/test_name_tok_v2_cross_language.py`, `test_name_tok_v2_compression_gate.py` |
| Java JNI | `native/src/ttio_name_tok_v2_jni.c` |
| Java codec | `java/src/main/java/global/thalion/ttio/codecs/NameTokenizerV2.java` |
| Java tests | `java/src/test/java/global/thalion/ttio/codecs/NameTokenizerV2Test.java` |
| Java CLI | `java/src/main/java/global/thalion/ttio/tools/NameTokenizedV2Cli.java` |
| ObjC codec | `objc/Source/Codecs/TTIONameTokenizerV2.{h,m}` |
| ObjC tests | `objc/Tests/Codecs/TestNameTokenizerV2*.m` |
| ObjC CLI | `objc/Tools/TtioNameTokV2Cli.m` |
| Phase 0 prototype | `tools/perf/name_tok_v2_prototype/` |
| Phase 0 results | `docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md` |
| Final results | `docs/benchmarks/2026-05-04-name-tokenized-v2-results.md` |
| Format spec ref | `docs/format-spec.md` §10.6b |
| Codec doc | `docs/codecs/name_tokenizer_v2.md` |
| Spec (this doc) | `docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md` |
| Plan | `docs/superpowers/plans/2026-05-04-name-tokenized-v2.md` |

## 17. Implementation pattern

Mirrors ch1 (mate_info v2) and ch2 (REF_DIFF v2) exactly:

1. Phase 0: Python-only prototype + corpus sweep, gate-validate.
2. T1-T4: C kernel + ctests (encoder + decoder + invariants + stress).
3. T5-T6: Python ctypes wrapper + v1↔v2 oracle test.
4. T7-T8: Java JNI binding + Java CLI tool.
5. T9-T10: ObjC direct-link binding + ObjC CLI tool.
6. T11: Cross-language byte-exact gate.
7. T12-T14: Python/Java/ObjC writer-reader dispatch.
8. T15: chr22 ratio gate + docs (CHANGELOG + version-history + format-spec
   + codec doc + benchmark results).

Each task ships as a separate commit, build+test cycle per task.
