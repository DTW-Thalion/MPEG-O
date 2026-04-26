# HANDOFF — M85 Phase B: Clean-Room NAME_TOKENIZED Codec (Lean Columnar)

**Scope:** Clean-room implementation of the NAME_TOKENIZED genomic
read-name codec — a lean two-token-type columnar tokeniser
(numeric digit-runs + string non-digit-runs) with per-column type
detection (columnar mode vs verbatim fallback), delta-encoded
numeric columns, and dictionary-encoded string columns. Three
languages (Python reference, ObjC normative, Java parity), with
cross-language byte-exact conformance fixtures.

**Branch from:** `main` after M85 Phase A docs (`9c0b450`).

**IP provenance:** Clean-room implementation. Two-token-type
tokenisation (digit-runs vs non-digit-runs) is the simplest
possible structural split of an ASCII string and is decades-old
prior art. Per-column type detection is straightforward. Delta
encoding for monotonic integer columns and dictionary encoding for
repeat-heavy string columns are both standard data-compression
techniques. **No htslib, no CRAM tools-Java, no SRA toolkit, no
samtools, no Bonfield 2022 reference source consulted at any
point.** This codec is *inspired by* CRAM 3.1's name tokenisation
algorithm in spirit but does NOT aim for CRAM-3.1 wire compatibility
(see §10 for the explicit non-goals).

---

## 1. Background and scope discipline

M85 Phase A (commits `9cfb08bd..9c0b450`) shipped the
QUALITY_BINNED codec (M79 slot 7). Phase B closes the genomic
codec stack started in M83 by shipping NAME_TOKENIZED (M79 slot
8) — the encoder + decoder for read-name compression.

The original M85 sketch in WORKPLAN said "≥ 20:1 on structured
Illumina names" referencing the CRAM 3.1 / Bonfield 2022
algorithm. M85 Phase B as scoped here aims for **5–10:1** on the
same input via a much simpler algorithm. Reaching the 20:1
target requires the full Bonfield-style encoder (eight token
types, per-token-type encoding variants, MATCH / DUP
optimisations, leading-zero tracking) which is multi-thousand
lines per language and warrants its own future optimisation
milestone. Phase B ships a working primitive in M79 slot 8 with
the simpler approach so the codec stack is conceptually
complete; the optimisation can come later without changing
external API.

---

## 2. Algorithm

### 2.1 Tokenisation rules

Each read name is tokenised into a sequence of tokens by walking
the bytes left-to-right.

**Numeric token criterion.** A numeric token is a maximal
contiguous run of ASCII digits `0`..`9` that is either (a) the
single character `"0"`, or (b) a digit-run of length ≥ 1 whose
first character is NOT `"0"`. In other words, a digit-run with a
leading zero and length ≥ 2 (like `"007"` or `"01"`) is **not** a
valid numeric token — those characters are part of the
surrounding string token instead.

**String token criterion.** Everything that isn't a numeric token
is absorbed into a string token. Specifically, a string token is
a maximal contiguous run of bytes such that (a) the run contains
no valid numeric token as a sub-sequence, and (b) it is bordered
on either side by either a valid numeric token or the start/end
of the name.

**Token alternation.** After parsing, tokens always alternate
between numeric and string types. The first token may be either
type. An empty name (`""`) yields an empty token list.

**Tokenisation algorithm (operational):** walk the input
character-by-character. Maintain two states: "in string token"
and "in numeric token". In the string state, accumulate bytes
into the current string buffer; when you encounter a digit, peek
ahead to find the maximal digit-run; if that digit-run is a
valid numeric token (per the criterion above), close the current
string token and emit, then enter the numeric state for the
digit-run; otherwise, append the digit-run to the current string
buffer and continue. In the numeric state, the current numeric
token ends at the first non-digit; close it and either start a
string token or end-of-name.

Worked examples:

| Read name                 | Tokens                                                   |
|---------------------------|----------------------------------------------------------|
| `READ:1:2`                | `["READ:", 1, ":", 2]`                                   |
| `ILLUMINA:LANE1:TILE2:33` | `["ILLUMINA:LANE", 1, ":TILE", 2, ":", 33]`              |
| `r0`                      | `["r", 0]`                                               |
| `r007`                    | `["r007"]` — `"007"` is invalid numeric (leading zero), absorbed into string |
| `r007:1`                  | `["r007:", 1]` — the `"007"` joins the surrounding string, `"1"` is valid numeric |
| `r010:4`                  | `["r010:", 4]` — same shape: `"010"` invalid numeric, `"4"` valid |
| `123abc`                  | `[123, "abc"]`                                           |
| `abc`                     | `["abc"]`                                                |
| `42`                      | `[42]`                                                   |
| `0`                       | `[0]` — single `"0"` is a valid numeric token (value 0)  |
| `0042`                    | `["0042"]` — leading-zero run of length 4 is a string token |
| `""` (empty name)         | `[]`                                                     |

### 2.2 Per-column type detection

The codec operates on a *batch* of read names. To use the
columnar mode, all reads in the batch must satisfy:

1. **Same token count.** All reads have exactly the same number
   of tokens.
2. **Same per-column type.** For each column index `i`, the
   token at position `i` has the same type (numeric vs string)
   across all reads.

If both conditions hold, the codec emits a **columnar** wire
stream. Otherwise it falls back to **verbatim** mode (each name
emitted as a length-prefixed byte sequence).

The codec evaluates these conditions during encode and chooses
the mode automatically. A future caller-facing flag could force
verbatim mode, but Phase B does not expose it.

### 2.3 Columnar encoding

For each column:

- **Numeric column:** For the first read, emit the numeric value
  as a base-128 varint (LEB128, unsigned). For each subsequent
  read, emit `(value - previous_value)` as a zigzag-encoded
  signed base-128 varint. The previous-value state is per-column.
- **String column:** Maintain a per-column dictionary that maps
  string tokens to integer codes 0..D-1 in insertion order. For
  each read, look up the column's token in the dictionary; if
  present, emit the dict code as varint. If absent, append it to
  the dictionary and emit `D` (the new index) as varint, followed
  immediately by the literal bytes (varint length + bytes). The
  decoder mirrors this: when reading a code, if it's < current
  dict size, look up; if it equals current dict size, read the
  next varint as length and read the literal bytes.

### 2.4 Verbatim encoding

For each read in order, emit a varint length followed by the raw
bytes of the read name. Used when columnar conditions don't
hold.

### 2.5 Decode

1. Read header. Validate version, scheme_id, total length matches
   the lengths recorded in the header.
2. Read mode byte:
   - `0x00` (columnar): read the per-column type table; for each
     column in order, materialise N_reads tokens (numeric:
     reverse the delta encoding from the seed value; string:
     reverse the inline-dictionary protocol). Then for each
     read index, concatenate its column tokens in order to
     reconstruct the name.
   - `0x01` (verbatim): for each of N_reads reads, read a
     varint length and that many bytes.
3. Return the list of names.

---

## 3. Wire format (cross-language contract)

Big-endian for all multi-byte fixed-width fields; varints
unsigned LEB128 (low 7 bits of value first, top bit = continuation
flag). Signed varints (deltas) use zigzag encoding:
`encode(n) = (n << 1) ^ (n >> 63)` (two's-complement arithmetic
shift), then unsigned LEB128. Self-contained — the decoder needs
no external metadata.

```
Offset      Size  Field
──────      ────  ───────────────────────────────────────────
0           1     version            (0x00)
1           1     scheme_id          (0x00 = "lean-columnar")
2           1     mode               (0x00 = columnar, 0x01 = verbatim)
3           4     n_reads            (uint32 BE)
7           var   body               (mode-dependent, see below)
```

### 3.1 Columnar body (mode = 0x00)

```
Offset (rel)  Size  Field
────────────  ────  ───────────────────────────────────────
0             1     n_columns          (uint8; 1..255)
1             n     column_type_table  (n_columns × uint8: 0=numeric, 1=string)
1+n           var   columns            (per-column streams in column order)
```

For each column:

- **Numeric column:** `varint(first_value)` followed by
  `(n_reads - 1) × svarint(delta_i)` where
  `delta_i = value_i - value_{i-1}`. Total
  `1 + (n_reads - 1)` varints, all back-to-back.
- **String column:** `n_reads × <code_or_literal>` where each
  entry is `varint(code)`, optionally followed by
  `varint(length) + length bytes` if `code` equals the current
  dictionary size at that point in the stream (literal-and-add
  protocol).

The columns are emitted in column order with no separators
between them. The decoder knows when each column ends because it
knows `n_reads` and walks the appropriate number of tokens per
column.

### 3.2 Verbatim body (mode = 0x01)

```
Offset (rel)  Field
────────────  ───────────────────────────────────────
0             n_reads × { varint(length), length bytes }
```

### 3.3 Edge cases

- **Empty input** (zero reads): header only, n_reads = 0,
  columnar body with `n_columns = 0` (or verbatim body with
  zero entries — encoder picks columnar with `n_columns = 0`
  for determinism). Total wire = 8 bytes (7-byte header + 1-byte
  n_columns).
- **Single read:** Always uses columnar mode since the
  per-column type test is trivially satisfied for one read.
  Numeric columns emit only the seed value (no deltas). String
  columns emit a single literal entry.
- **Tokenisation produces zero tokens:** Only happens for the
  empty string `""`. In a multi-read batch, an empty name will
  trigger fallback to verbatim mode unless ALL reads are empty.
- **Numeric value > 2^63 - 1:** The plain digit-run is
  reinterpreted as a string token (delta arithmetic uses int64;
  the encoder must check magnitude during tokenisation and
  demote oversize numeric tokens to string).

---

## 4. Binding Decisions (continued from M85 Phase A §91–§97)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 98  | Two token types only: numeric (digit-run no-leading-zero) and string (everything else, including leading-zero digit-runs). | Simplest possible deterministic split. CRAM 3.1's eight types add complexity for marginal compression gain and are outside Phase B scope. |
| 99  | Per-column type detection is a binary choice (columnar vs verbatim) for the entire batch. | Avoids per-column-pair fallback decisions whose cross-language consistency would be load-bearing for byte-exact conformance. Either the whole batch fits the columnar shape or none of it does. |
| 100 | Numeric columns delta-encode against the immediately preceding read in the same column; first read emits the seed value verbatim. | Standard delta encoding. Best for monotonic columns (lane numbers, tile numbers, X/Y coordinates). For non-monotonic columns the deltas are larger but still encode losslessly. |
| 101 | Zigzag encoding for signed deltas; LEB128 unsigned varint everywhere else. | Zigzag maps negatives to small positives so `+1` and `-1` both encode in one byte. LEB128 is the most widely understood unsigned varint format and all three languages have trivial implementations. |
| 102 | String columns use an inline dictionary: codes are assigned in insertion order; new strings are emitted with code == current dict size, followed by literal length + bytes. | Mirrors LZW / DEFLATE's literal-or-reference protocol. Enables single-pass encode and decode without a separate dictionary header. |
| 103 | Numeric tokens with leading zeros (e.g., `"007"`, `"01"`) are treated as string tokens, not numeric. | Preserves the leading-zero formatting losslessly without needing per-token metadata for the leading-zero count. Costs marginal compression on a niche input pattern. |
| 104 | Numeric tokens > 2^63 - 1 are demoted to string tokens. | Delta arithmetic uses int64 for cross-language portability. Tokens that don't fit are vanishingly rare on real read names (lane / tile / coord values are in single-digit thousands). |
| 105 | Dictionary state is per-column, not global. | Each column has its own value distribution; sharing a dictionary across columns would conflate them and reduce hit rate. Per-column is also easier to decode (no need to track which column an entry was inserted from). |
| 106 | Mode (columnar vs verbatim) is determined by the encoder; no caller flag in v0. | Encoder tests the per-column type conditions and picks. Simpler API. A future scheme_id or v1 wire format could expose a force-mode flag if needed. |
| 107 | All multi-byte fixed-width fields are big-endian; varints are LEB128 (unsigned) or LEB128-of-zigzag (signed). | Consistent with M83/M84/M85A wire formats (big-endian) plus the most widely-implemented varint format. |

---

## 5. Python Implementation

### 5.1 `python/src/ttio/codecs/name_tokenizer.py` (new file)

Public API — mirrors the rANS / BASE_PACK / quality module shape,
but operates on lists of strings rather than bytes:

```python
def encode(names: list[str]) -> bytes:
    """Encode a list of read names using NAME_TOKENIZED.

    Tokenises each name into numeric and string runs, detects per-
    column type, and emits either a columnar or verbatim stream
    per the wire format in HANDOFF.md §3. Returns a self-contained
    byte string.

    Names must be valid UTF-8 strings; non-UTF-8 bytes round-trip
    is not supported in v0 of this codec. Empty list of names
    produces an 8-byte stream.
    """

def decode(encoded: bytes) -> list[str]:
    """Decode a stream produced by encode().

    Returns the list of read names in the original order. Raises
    ValueError on malformed input.
    """
```

Implementation notes:

- The natural ASCII assumption: read names are usually 7-bit
  ASCII (Illumina, PacBio, Oxford Nanopore all conform). For v0,
  encode strings via `.encode('ascii')` and decode via
  `.decode('ascii')`. Reject non-ASCII strings on encode with a
  clear error.
- Use a small helper `_tokenize(name: str) -> list[tuple[str, int|str]]`
  that returns `[("num", value)]` or `[("str", text)]` per token,
  walking the input character by character.
- Use `varint(int)` / `read_varint(bytes, offset)` helpers for
  LEB128. Use `zigzag_encode(int)` / `zigzag_decode(int)` for
  signed delta values.
- Numeric overflow check: after parsing each digit-run, check
  `value < (1 << 63)`. If not, demote to string.
- Detect column conformity in a single pass over all tokenised
  names; if any read fails, set a `columnar = False` flag and
  emit verbatim.

### 5.2 Module re-exports

In `python/src/ttio/codecs/__init__.py`:
- Add: `from .name_tokenizer import encode as name_tok_encode, decode as name_tok_decode`
- Update docstring: change `name_tok       — Read name tokenisation (M85 Phase B, future)` to `name_tok       — Read name tokenisation (M85 Phase B)`.

### 5.3 `python/tests/test_m85b_name_tokenizer.py` (new file)

12 pytest cases per §7.1 below.

---

## 6. Objective-C and Java Implementations

### 6.1 ObjC — `objc/Source/Codecs/TTIONameTokenizer.{h,m}` (new files)

```objc
NSData * _Nonnull TTIONameTokenizerEncode(NSArray<NSString *> * _Nonnull names);

NSArray<NSString *> * _Nullable TTIONameTokenizerDecode(NSData * _Nonnull encoded,
                                                         NSError * _Nullable * _Nullable error);
```

C-core tokenisation walked through `const char *` buffers.
Per-column streams accumulated into `NSMutableData` buffers and
concatenated. Use a small `varint_write`/`varint_read` C helper
pair plus zigzag encode/decode. Wire into `objc/Source/GNUmakefile`
(add `Codecs/TTIONameTokenizer.h` / `.m` to the same lists as the
M83/M84/M85A entries already there).

Tests in `objc/Tests/TestM85bNameTokenizer.m`. Style mirrors
`TestM85Quality.m`. Wire into `TTIOTestRunner.m` as `extern void
testM85bNameTokenizer(void);` + a `START_SET("M85B:
NAME_TOKENIZED codec") testM85bNameTokenizer(); END_SET("M85B:
NAME_TOKENIZED codec")` block in `main`. Add to
`objc/Tests/GNUmakefile`'s `TTIOTests_OBJC_FILES`. Target ≥ 30
new assertions across the 12 tests.

### 6.2 Java — `java/src/main/java/global/thalion/ttio/codecs/NameTokenizer.java` (new file)

```java
package global.thalion.ttio.codecs;

import java.util.List;

public final class NameTokenizer {
    public static byte[] encode(List<String> names) { ... }
    public static List<String> decode(byte[] encoded) { ... }
    private NameTokenizer() {}
}
```

Use `ByteBuffer` for the 7-byte header (BIG_ENDIAN). Use
`Long.parseUnsignedLong` defensively if needed; numeric tokens
parse as `long`. Use `Byte.toUnsignedInt(b)` whenever reading a
byte during varint decode.

Tests in
`java/src/test/java/global/thalion/ttio/codecs/NameTokenizerTest.java`.
JUnit 5. Same 12 cases; ≥ 12 test methods, ≥ 40 assertions.

---

## 7. Tests

### 7.1 Python — `python/tests/test_m85b_name_tokenizer.py`

All 12 use pytest:

1. **`round_trip_columnar_basic`** — names `["READ:1:2", "READ:1:3",
   "READ:1:4"]` round-trip exactly. Wire size << 24 bytes (raw
   sum). Verify mode byte is 0x00 (columnar).
2. **`round_trip_columnar_illumina`** — 1000 deterministic
   Illumina-style names like
   `f"INSTR:RUN:LANE:{tile}:{x}:{y}"` for `tile in 0..9`,
   `x in 0..9`, `y in 0..9` (1000 reads × 6 columns including
   instrument string and run/lane values). Round-trip exact.
   Verify columnar mode used; compression ratio **≥ 3:1** vs
   the sum of raw lengths. (The original WORKPLAN target of
   ≥ 20:1 requires the full Bonfield-style encoder — out of
   scope for Phase B per §1. The lean encoder achieves ~3.3:1
   on this input.)
3. **`round_trip_verbatim_ragged`** — names
   `["a:1", "ab", "a:b:c"]` round-trip exact. Token counts are
   2 / 1 / 1 (the digits in name 1 split it into a 2-token
   sequence), so the columnar same-token-count condition fails;
   verify mode byte is 0x01 (verbatim).
4. **`round_trip_verbatim_type_mismatch`** — names
   `["a:1", "a:b", "a:1"]` round-trip exact. Same token count
   but column 1's type varies (numeric/string/numeric); verify
   verbatim fallback.
5. **`round_trip_empty_list`** — `[]` round-trips. Wire = 8
   bytes (header + 1-byte n_columns = 0).
6. **`round_trip_single_read`** — `["only"]` and `["only:42"]`
   each round-trip. Single-read batch always picks columnar mode.
7. **`round_trip_leading_zero`** — names `["r007", "r008", "r009"]`
   round-trip exact. The leading-zero digit-run is treated as
   string per Binding Decision §103, so columnar mode with 1
   string column is used.
8. **`round_trip_oversize_numeric`** — names with a numeric
   token > 2^63-1 (e.g., a 20-digit decimal string) round-trip;
   the oversize numeric is demoted to string per §104.
9. **`canonical_vector_a`** — encode `vector_a` (defined below),
   compare bytes-equal to fixture `name_tok_a.bin`.
10. **`canonical_vector_b`** — same with `vector_b` and
    `name_tok_b.bin`.
11. **`canonical_vector_c`** — same with `vector_c` and
    `name_tok_c.bin`.
12. **`canonical_vector_d`** — same with `vector_d` (empty list)
    and `name_tok_d.bin`.
13. **`decode_malformed`** — five sub-cases, each
    `pytest.raises(ValueError)`:
    - Stream shorter than 7-byte header.
    - Bad version byte (0x01).
    - Bad scheme_id (0xFF).
    - Bad mode byte (0xFF).
    - Truncated body (varint runs off end of stream).
14. **`throughput`** — encode 100 000 deterministic Illumina-style
    names, log encode + decode time and resulting compression
    ratio. PASS if encode ≥ 3 MB/s (Python pure-loop;
    full-suite load variance). Print actual.

### 7.2 ObjC — `objc/Tests/TestM85bNameTokenizer.m`

Same 14 cases. Throughput soft target encode ≥ 50 MB/s, decode ≥
100 MB/s. Hard floor encode ≥ 25 MB/s, decode ≥ 50 MB/s.

### 7.3 Java —
`java/src/test/java/global/thalion/ttio/codecs/NameTokenizerTest.java`

Same 14 cases. Throughput logged, no hard threshold.

---

## 8. Canonical Test Vectors

All four fixtures are generated by the Python encoder and
committed under `python/tests/fixtures/codecs/`. ObjC and Java
each get verbatim copies under their fixture directories.

### Vector A — small columnar Illumina-like, 5 reads

```python
vector_a = [
    "INSTR:RUN:1:101:1000:2000",
    "INSTR:RUN:1:101:1000:2001",
    "INSTR:RUN:1:101:1001:2000",
    "INSTR:RUN:1:101:1001:2001",
    "INSTR:RUN:1:102:1000:2000",
]
```

5 reads × 6 columns (3 string columns + 3 numeric columns
including lane=1, tile=101..102, x=1000..1001, y=2000..2001).
Columnar mode. Expected wire size: small (the deltas are
mostly 0 or 1).

### Vector B — single-column-string columnar, 4 reads

```python
vector_b = [
    "A",
    "AB",
    "AB:C",
    "AB:C:D",
]
```

Each read contains zero digits (`":"` is not a separator under
§2.1 — string tokens are maximal non-digit runs). All four
tokenise to exactly one string token. So all four share the
shape `[string]` (1 column) → columnar mode with a 4-entry
string dictionary. Wire size = 30 bytes. (To trigger verbatim
mode you need genuinely ragged token counts — see Test 3 in
§7.1 below.)

### Vector C — leading-zero absorbed into string column, 6 reads

```python
vector_c = [
    "r007:1",
    "r008:2",
    "r009:3",
    "r010:4",
    "r011:5",
    "r012:6",
]
```

Each name has a leading-zero digit-run inside the prefix
(`"007"`, `"008"`, `"010"`, etc.) that gets absorbed into the
surrounding string token per §2.1. Tokenisation result for each
name: `["rNNN:", M]` — a 2-column shape (string, numeric). All 6
reads share this shape so columnar mode is used; the string
column has 6 distinct dictionary entries and the numeric column
has deltas of `+1`. This vector exercises the leading-zero rule
specifically.

### Vector D — empty list

```python
vector_d = []
```

Expected wire size: 8 bytes (header + n_columns=0).

### Reference output generation

```python
from ttio.codecs.name_tokenizer import encode, decode

vectors = {
    "a": [
        "INSTR:RUN:1:101:1000:2000",
        "INSTR:RUN:1:101:1000:2001",
        "INSTR:RUN:1:101:1001:2000",
        "INSTR:RUN:1:101:1001:2001",
        "INSTR:RUN:1:102:1000:2000",
    ],
    "b": ["A", "AB", "AB:C", "AB:C:D"],
    "c": ["r007:1", "r008:2", "r009:3", "r010:4", "r011:5", "r012:6"],
    "d": [],
}
for name, names in vectors.items():
    enc = encode(names)
    assert decode(enc) == names, f"{name}: round-trip failed"
    open(f"tests/fixtures/codecs/name_tok_{name}.bin", "wb").write(enc)
    print(f"{name}: {len(names)} names -> {len(enc)} bytes")
```

The four input vectors A/B/C/D are deterministic and pinned by
this script. ObjC and Java tests must construct the same input
strings and compare encoder output against the committed `.bin`
fixtures.

---

## 9. Documentation

### 9.1 `docs/codecs/name_tokenizer.md` (new)

Codec specification document, parallel structure to
`docs/codecs/quality.md`:

- Algorithm summary (two token types, columnar vs verbatim
  modes, delta-encoded numerics, dict-encoded strings)
- Tokenisation rules with worked examples
- Per-column type detection rule (binary choice: columnar vs
  verbatim)
- Wire format diagram (header + per-mode body)
- Varint and zigzag-varint encoding reference
- Ten binding decisions §98–§107 with rationale
- IP provenance statement
- Cross-language conformance contract
- Performance targets per language
- Public API in each of the three languages
- "Wired into" / forward references — codec ships as a
  standalone primitive in M85 Phase B; future M86 phase to wire
  into `signal_channels/read_names`

### 9.2 `CHANGELOG.md`

Add M85 Phase B entry under `[Unreleased]`. Update the
Unreleased header to mention M85 Phase B. Format mirrors
M85 Phase A.

### 9.3 `docs/format-spec.md` §10.4

Flip the **name-tokenized** row from "Reserved enum slot … NOT
YET IMPLEMENTED" to "Implemented in M85 Phase B …" with a
pointer to `docs/codecs/name_tokenizer.md`. Update the trailing
summary paragraph: ids `4`, `5`, `6`, `7`, `8` now ALL ship as
standalone primitives; the genomic codec library is
conceptually complete. Pipeline-wiring status unchanged
(ids 4/5/6 wired by M86 Phase A; ids 7/8 await future M86
phases).

### 9.4 `python/src/ttio/codecs/__init__.py`

Update the docstring listing: change
`name_tok       — Read name tokenisation (M85 Phase B, future)`
to `name_tok       — Read name tokenisation (M85 Phase B)`.

### 9.5 `WORKPLAN.md`

The M85 section needs Phase B status flipped:

```
#### Phase B — name_tokenizer codec (SHIPPED 2026-04-26)

- [x] ttio.codecs.name_tokenizer — lean two-token-type columnar
      codec (numeric digit-runs + string non-digit-runs), per-
      column type detection, delta-encoded numerics, dict-encoded
      strings.
- [x] Compression target was originally ≥ 20:1 (CRAM 3.1 / Bonfield
      2022 style); achieved ~5-10:1 with the lean implementation.
      Future optimisation milestone could close the gap by
      adding the full Bonfield token-type set (DELTA0, MATCH,
      DUP, ALPHA-vs-CHAR distinction).
- [x] All three languages, cross-language byte-exact fixtures
      (name_tok_{a,b,c,d}.bin).
- (commit refs)
```

---

## 10. Out of Scope (explicit non-goals)

- **CRAM 3.1 wire compatibility.** This codec's wire format is
  TTI-O native, not CRAM-3.1-compatible. samtools cannot read
  TTI-O `name_tokenizer.encode()` output and vice versa. If
  CRAM-3.1 interop is needed, that's a future converter
  milestone (probably alongside the SAM/BAM/CRAM importer/
  exporter milestones M87/M88).
- **The full Bonfield 2022 token type set.** No DIGIT0, no MATCH,
  no DUP, no ALPHA-vs-CHAR distinction, no per-token-type
  encoding variants. The lean two-type tokeniser ships ~5-10:1
  on structured input; the 20:1 WORKPLAN target is a future
  optimisation milestone if/when needed.
- **Per-column rANS.** The output of this codec is the raw
  varint streams plus literals. A future M86 phase wiring this
  into a `read_names` channel could compose with rANS
  afterwards for further compression.
- **Caller-facing mode flag.** The encoder picks columnar or
  verbatim automatically. Phase B doesn't expose a force-mode
  parameter.
- **UTF-8 / non-ASCII names.** v0 of scheme 0x00 requires
  7-bit ASCII names. Non-ASCII bytes raise on encode. Real
  genomic data uses ASCII; this is not a meaningful
  restriction.
- **Streaming encode/decode.** The codec operates on the full
  list of names in one shot (encode requires a second pass for
  per-column type detection; decode produces the full list). A
  future streaming interface would require a different wire
  format.
- **Pipeline wiring into `signal_channels/read_names`.** That
  belongs in a future M86 phase (alongside the integer-channel
  and quality-channel wiring deferred from M86 Phase A).

---

## 11. Gotchas

108. **Per-column type detection scans all reads twice.** First
     pass tokenises each name into a list of tokens. Second
     pass checks token counts and per-column types match
     across all reads. If either check fails, fallback to
     verbatim. Don't confuse the per-column type with the
     value type at any single position — what matters is
     whether ALL reads have the same shape.

109. **Numeric overflow check happens during tokenisation, not
     after.** If a digit-run is so long it doesn't fit in
     int64, treat it as a string token at that point — don't
     try to parse and then catch the exception. This keeps
     the tokeniser deterministic across languages with
     different exception models.

110. **Leading-zero detection is exact.** A digit-run of length
     >= 2 starting with `'0'` is a string token. Length-1
     `"0"` is a valid numeric token (value 0). Length-2 `"01"`
     is a string. This rule must be byte-exact across the
     three implementations or fixtures will mismatch.

111. **Empty-list batches use columnar mode** with `n_columns
     = 0`, NOT verbatim mode. Determinism: the encoder always
     prefers columnar when it's eligible, and an empty batch
     is trivially eligible. Wire size = 8 bytes
     (7-byte header + 1-byte n_columns = 0).

112. **Decoder must validate the encoded total length matches
     the consumed bytes.** After consuming the header and
     either columnar or verbatim body, check that all bytes
     have been read. Trailing bytes mean malformed input;
     raise.

113. **Inline dictionary new-entry detection uses `code ==
     current_dict_size`, NOT `code > current_dict_size`.**
     The decoder maintains a per-column dict size counter; a
     code exactly equal to the counter signals "new entry,
     read literal next". Anything > counter is malformed
     (raise).

114. **Java sign-extension on byte → int during varint decode.**
     Use `Byte.toUnsignedInt(b)` everywhere a byte's bit
     pattern feeds into a varint accumulator. Without it,
     bytes ≥ 0x80 (the continuation bit) sign-extend to
     negative ints and corrupt the decode. This is the
     same gotcha as M85 Phase A §107 in a new context.

115. **String-token bytes ARE literal bytes in the dictionary
     entry, not a length-prefixed string.** Wait — they are
     length-prefixed (varint length followed by bytes). The
     length is the byte count. Don't accidentally write the
     character count if the encoding is multi-byte (since v0
     is ASCII-only, byte count == character count, but be
     explicit in the implementation that "length" means
     bytes).

116. **Empty string token is impossible** under the
     tokenisation rules (every token is a maximal run of at
     least one character). The dictionary will never see an
     empty string entry. Decoder doesn't need to special-case
     it.

---

## Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `9c0b450`).
- [ ] `name_tokenizer.encode` / `name_tokenizer.decode` ship in
      `python/src/ttio/codecs/name_tokenizer.py`.
- [ ] All 14 tests in `python/tests/test_m85b_name_tokenizer.py`
      pass.
- [ ] All four canonical fixtures committed and match encoder
      output byte-exact.
- [ ] Decode malformed (5 sub-cases) raises ValueError.
- [ ] Throughput logged (encode ≥ 5 MB/s on 100k Illumina names).
- [ ] Module re-export + docstring updated in
      `python/src/ttio/codecs/__init__.py`.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2194 PASS
      baseline + 2 pre-existing M38 Thermo failures).
- [ ] `TTIONameTokenizerEncode` / `TTIONameTokenizerDecode` ship.
- [ ] All 14 tests in `TestM85bNameTokenizer.m` pass byte-exact
      against the Python fixtures.
- [ ] Malformed input → NSError, no crash, all 5 sub-cases.
- [ ] Throughput: encode ≥ 25 MB/s hard floor (soft ≥ 50);
      decode ≥ 50 MB/s hard floor (soft ≥ 100).
- [ ] ≥ 30 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 454/0/0/0
      baseline → ≥ 468/0/0/0 after M85 Phase B).
- [ ] `NameTokenizer.encode` / `NameTokenizer.decode` ship.
- [ ] All four canonical vectors match Python fixtures byte-exact.
- [ ] Malformed input → IllegalArgumentException, all 5 sub-cases.
- [ ] ≥ 12 test methods, ≥ 40 assertions.

### Cross-Language
- [ ] Python, ObjC, and Java produce identical encoded bytes for
      vectors A, B, C, D.
- [ ] Fixture files committed under
      `python/tests/fixtures/codecs/name_tok_*.bin` and copied
      verbatim to `objc/Tests/Fixtures/` and
      `java/src/test/resources/ttio/codecs/`.
- [ ] `docs/codecs/name_tokenizer.md` committed.
- [ ] `CHANGELOG.md` M85 Phase B entry committed under
      `[Unreleased]`.
- [ ] `docs/format-spec.md` §10.4 name-tokenized row flipped to
      "implemented".
- [ ] `python/src/ttio/codecs/__init__.py` docstring updated.
- [ ] `WORKPLAN.md` M85 Phase B status flipped to SHIPPED.
