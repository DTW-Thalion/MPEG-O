# TTI-O M85 Phase B — NAME_TOKENIZED Codec

> **Status:** shipped (M85 Phase B, 2026-04-26). Reference
> implementation in Python, normative implementation in
> Objective-C, parity implementation in Java. All three produce
> byte-identical encoded streams for the four canonical
> conformance vectors.

This document specifies the NAME_TOKENIZED codec used by TTI-O
for compressed genomic read-name channels. It defines the
tokenisation rules, the columnar-vs-verbatim mode selection, the
wire format, the cross-language conformance contract, and the
per-language performance targets.

The codec ships as a standalone primitive in M85 Phase B. Wiring
into the genomic signal-channel pipeline (interpreting
`@compression == 8` on a `signal_channels/read_names` dataset to
call `name_tokenizer.decode()`) is a future M86 phase, separate
from M86 Phase A which already wired rANS and BASE_PACK.

---

## 1. Algorithm

NAME_TOKENIZED splits each read name into a sequence of two
token types — **numeric** (digit-runs without leading zeros) and
**string** (everything else, with leading-zero digit-runs
absorbed into surrounding strings) — then exploits structural
regularity across the batch of names by encoding each "column"
(token position) separately. Numeric columns delta-encode against
the previous read; string columns use an inline dictionary.

If the batch lacks columnar structure (varying token counts or
varying per-column types), the encoder falls back to verbatim
mode (each name length-prefixed).

### IP provenance

Clean-room implementation. Two-token-type tokenisation is the
simplest possible structural split of an ASCII string and is
decades-old prior art. Per-column type detection, delta encoding,
and inline dictionaries are standard data-compression techniques.
**No htslib, no CRAM tools-Java, no SRA toolkit, no samtools, no
Bonfield 2022 reference source consulted at any point.** This
codec is *inspired by* CRAM 3.1's name tokenisation algorithm in
spirit but does NOT aim for CRAM-3.1 wire compatibility — see §7
for the explicit non-goals.

### 1.1 Tokenisation rules

A **numeric token** is a maximal contiguous run of ASCII digits
`0`..`9` that is either (a) the single character `"0"`, or (b) a
digit-run of length ≥ 1 whose first character is NOT `"0"`. So
`"0"` is numeric, `"1"`, `"42"`, `"123"` are numeric, but
`"01"`, `"007"`, `"0042"` are NOT numeric — they're absorbed
into surrounding string tokens.

A **string token** is a maximal contiguous run of bytes such that
no valid numeric token appears inside it. Adjacent string +
not-valid-numeric digit-runs MERGE into one string token.

Tokens alternate types after parsing. The first token may be
either type. An empty name (`""`) yields an empty token list.

**Tokenisation algorithm (operational):** walk the input
character-by-character. Maintain two states: "in string token"
and "in numeric token". In the string state, accumulate bytes
into the current string buffer; when you encounter a digit, peek
ahead to find the maximal digit-run; if that digit-run is a
valid numeric token (per the criterion above), close the current
string token and emit, then enter the numeric state for the
digit-run; otherwise, append the digit-run to the current string
buffer and continue. In the numeric state, the current numeric
token ends at the first non-digit; close it.

Worked examples:

| Read name                 | Tokens                                                   |
|---------------------------|----------------------------------------------------------|
| `READ:1:2`                | `["READ:", 1, ":", 2]`                                   |
| `ILLUMINA:LANE1:TILE2:33` | `["ILLUMINA:LANE", 1, ":TILE", 2, ":", 33]`              |
| `r0`                      | `["r", 0]`                                               |
| `r007`                    | `["r007"]` — `"007"` invalid numeric, absorbed into string |
| `r007:1`                  | `["r007:", 1]` — `"007"` joins surrounding string, `"1"` valid numeric |
| `r010:4`                  | `["r010:", 4]` — `"010"` invalid numeric, `"4"` valid    |
| `123abc`                  | `[123, "abc"]`                                           |
| `0`                       | `[0]` — single `"0"` is a valid numeric token (value 0)  |
| `0042`                    | `["0042"]` — leading-zero run of length 4 is a string token |
| `""` (empty name)         | `[]`                                                     |

### 1.2 Per-column type detection (mode selection)

The codec operates on a *batch* of read names. To use the
**columnar** mode, all reads in the batch must satisfy:

1. **Same token count.** All reads have exactly the same number
   of tokens.
2. **Same per-column type.** For each column index, the token at
   that position has the same type (numeric vs string) across
   all reads.

If both conditions hold, the codec emits a columnar wire stream.
Otherwise it falls back to **verbatim** mode (each name emitted
as a length-prefixed byte sequence). The encoder picks the mode
automatically; v0 doesn't expose a force-mode flag.

### 1.3 Columnar encoding

For each column:

- **Numeric column:** For the first read, emit the numeric value
  as an unsigned LEB128 varint. For each subsequent read, emit
  `(value - previous_value)` as a zigzag-then-LEB128 signed
  varint. The previous-value state is per-column.
- **String column:** Maintain a per-column dictionary that maps
  string tokens to integer codes 0..D-1 in insertion order. For
  each read, look up the column's token in the dictionary; if
  present, emit the dict code as varint. If absent, append it to
  the dictionary and emit `D` (the new index = current dict
  size) as varint, followed immediately by `varint(byte_len) +
  bytes` (the literal). The decoder mirrors this protocol.

### 1.4 Verbatim encoding

For each read in order, emit a varint length followed by the raw
bytes of the read name.

### 1.5 Decode

1. Read header. Validate version, scheme_id, mode, n_reads.
2. For columnar mode: read n_columns + the per-column type
   table. For each column in order, materialise n_reads tokens
   (numeric: reverse the delta encoding from the seed value;
   string: reverse the inline-dictionary protocol). Then for
   each read index, concatenate its column tokens in order to
   reconstruct the name.
3. For verbatim mode: for each of n_reads reads, read a varint
   length and that many bytes.
4. Return the list of names.

---

## 2. Wire format

Big-endian for fixed-width fields; varints unsigned LEB128 (low
7 bits first, top bit = continuation flag); signed varints use
zigzag encoding (`(n << 1) ^ (n >> 63)`) then unsigned LEB128.
Self-contained — the decoder needs no external metadata.

```
Header (7 bytes):
  byte 0:    version    (0x00)
  byte 1:    scheme_id  (0x00 = "lean-columnar")
  byte 2:    mode       (0x00 = columnar, 0x01 = verbatim)
  bytes 3-6: n_reads    (uint32 BE)

Columnar body (mode=0x00):
  byte 0:                n_columns (uint8; 0..255)
  bytes 1..n_columns:    column_type_table (uint8 each: 0=numeric, 1=string)
  per-column streams (in column order):
    Numeric column:  varint(first_value) + (n_reads-1) × svarint(delta)
    String column:   n_reads × code_or_literal
                     (code as varint; if code == current_dict_size then
                      varint(byte_len) + bytes literal follows and is added to dict)

Verbatim body (mode=0x01):
  n_reads × { varint(length), length bytes }
```

### Edge cases

- **Empty input** (zero reads): header only, n_reads = 0,
  columnar body with `n_columns = 0`. Total wire = 8 bytes.
- **Single read:** Always columnar (per-column type test trivially
  satisfied for one read). Numeric columns emit only the seed value
  (no deltas). String columns emit a single literal entry.
- **Numeric overflow:** Tokens > `2^63 - 1` are demoted to string
  tokens during tokenisation.

### Invariants enforced by the decoder

- Stream length ≥ 7 (header).
- `version == 0x00`, `scheme_id == 0x00`, `mode ∈ {0x00, 0x01}`.
- Total stream length matches what the body parse consumes
  (no leftover bytes; no truncation).
- String column: `code <= current_dict_size` at every step
  (`>` is malformed).
- Varint shifts ≤ 63 (otherwise oversize value).

Each rejection is a clean error (Python `ValueError`, ObjC
`NSError**` with `nil` return, Java `IllegalArgumentException`),
not a crash.

---

## 3. Design choices (Binding Decisions §98–§107)

See `HANDOFF.md` (M85 Phase B plan) §4 for the full table.
Summary:

- **§98** Two token types only (numeric / string). CRAM 3.1's
  eight types add complexity for marginal gain.
- **§99** Per-column type detection is binary (whole batch
  columnar OR whole batch verbatim). Avoids per-column-pair
  fallback whose cross-language consistency is load-bearing.
- **§100** Numeric columns delta-encode against the immediately
  preceding read; first read is a seed.
- **§101** Zigzag for signed deltas; LEB128 for everything else.
- **§102** String columns use inline dictionary
  (literal-and-add protocol).
- **§103** Leading-zero digit-runs absorb into surrounding
  string tokens. Preserves leading-zero formatting losslessly
  without per-token metadata.
- **§104** Numeric tokens > 2^63-1 demote to string. Delta
  arithmetic uses int64 for cross-language portability.
- **§105** Dictionary state is per-column, not global.
- **§106** Mode selection is automatic; no caller flag in v0.
- **§107** Big-endian for fixed-width fields; LEB128/zigzag for
  varints.

---

## 4. Cross-language conformance contract

The Python implementation in
`python/src/ttio/codecs/name_tokenizer.py` is the spec of record.
The four fixtures under `python/tests/fixtures/codecs/` are the
wire-level conformance test vectors:

| Fixture            | Input                                                 | Wire size | Notes |
|--------------------|-------------------------------------------------------|-----------|-------|
| `name_tok_a.bin`   | 5 Illumina-style names with shared `INSTR:RUN:1:` prefix | 75 B   | Columnar, 6 columns (3 string + 3 numeric); deltas mostly 0 or 1 |
| `name_tok_b.bin`   | 4 names with no digits (`A`, `AB`, `AB:C`, `AB:C:D`)   | 30 B   | Columnar with 1 string column (the colon is non-digit, so each name is one string token); 4 dict literals |
| `name_tok_c.bin`   | 6 names with leading-zero prefix (`r007:1`..`r012:6`) | 58 B   | Columnar, 2 columns; leading zeros absorb into string column 0 |
| `name_tok_d.bin`   | empty list                                             | 8 B    | Header only, n_columns = 0 |

Each implementation:
- Loads the fixtures from a known location relative to its tests.
- Constructs the same input data deterministically and verifies
  encoder output is bytes-equal to the fixture.
- Decodes the fixture and verifies the result equals the
  original input list.

Implementations:
- Python — `python/tests/fixtures/codecs/`
- ObjC — `objc/Tests/Fixtures/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

---

## 5. Performance

Per-language soft targets, measured on the M85 Phase B reference
host (100 000 deterministic Illumina-style names, 2.18 MB raw):

| Language     | Encode      | Decode      | Compression on 1000-name batch |
|--------------|-------------|-------------|--------------------------------|
| Python       | 5.4 MB/s    | 16.5 MB/s   | 3.31:1                         |
| Objective-C  | 37.0 MB/s   | 310.7 MB/s  | 6.63:1                         |
| Java         | ~14 MB/s    | ~63 MB/s    | 3.31:1                         |

The original WORKPLAN target was ≥ 20:1 on structured Illumina
names, achievable only with the full Bonfield 2022 / CRAM 3.1
algorithm (eight token types, per-token-type encoding variants,
MATCH / DUP / leading-zero tracking). The lean Phase B
implementation achieves **~3-7:1** on the same input — solid but
short of the original target. Closing that gap is a future
optimisation milestone if/when needed.

The ObjC encode rate (37 MB/s) is below the 50 MB/s soft target
but above the 25 MB/s hard floor; the decode rate (310 MB/s) is
well above the 100 MB/s soft target. The asymmetry reflects an
encode-side optimisation opportunity that wasn't pursued in
Phase B (encode does several allocator round-trips for the
per-column buffers; a pre-allocated arena would help).

---

## 6. API summary

### Python

```python
from ttio.codecs.name_tokenizer import encode, decode

encoded = encode(["INSTR:RUN:1:101:1000:2000",
                  "INSTR:RUN:1:101:1000:2001"])
recovered = decode(encoded)
assert recovered == ["INSTR:RUN:1:101:1000:2000",
                     "INSTR:RUN:1:101:1000:2001"]
```

The `codecs` sub-package is internal — public users access it as
`from ttio.codecs.name_tokenizer import encode, decode`. No
order/scheme parameter (v0 hardcodes scheme `0x00` =
"lean-columnar").

### Objective-C

```objc
#import "Codecs/TTIONameTokenizer.h"

NSArray<NSString *> *names = @[@"INSTR:RUN:1:101:1000:2000",
                                @"INSTR:RUN:1:101:1000:2001"];
NSData *encoded = TTIONameTokenizerEncode(names);
NSError *err = nil;
NSArray<NSString *> *recovered = TTIONameTokenizerDecode(encoded, &err);
```

`TTIONameTokenizerEncode` raises `NSInvalidArgumentException` on
nil array, non-ASCII strings, or n_reads > 2^32.
`TTIONameTokenizerDecode` returns `nil` and sets `*error` on
malformed input; never crashes.

### Java

```java
import global.thalion.ttio.codecs.NameTokenizer;
import java.util.List;

List<String> names = List.of("INSTR:RUN:1:101:1000:2000",
                              "INSTR:RUN:1:101:1000:2001");
byte[] encoded = NameTokenizer.encode(names);
List<String> recovered = NameTokenizer.decode(encoded);
```

`NameTokenizer.decode(byte[])` throws `IllegalArgumentException`
on malformed input. `NameTokenizer.encode(List<String>)` throws
`IllegalArgumentException` on null input or non-ASCII strings.

---

## 7. Out of scope (explicit non-goals)

- **CRAM 3.1 wire compatibility.** This codec's wire format is
  TTI-O native, not CRAM-3.1-compatible. samtools cannot read
  TTI-O `name_tokenizer.encode()` output and vice versa.
- **The full Bonfield 2022 token type set.** No DIGIT0, MATCH,
  DUP, ALPHA-vs-CHAR distinction, no per-token-type encoding
  variants. The lean two-type tokeniser ships ~3-7:1; the 20:1
  WORKPLAN target requires a future optimisation milestone.
- **Per-column rANS.** The output is raw varint streams plus
  literals. A future M86 phase wiring this into a `read_names`
  channel could compose with rANS afterwards.
- **Caller-facing mode flag.** Encoder picks columnar or verbatim
  automatically.
- **UTF-8 / non-ASCII names.** v0 of scheme `0x00` requires
  7-bit ASCII names. Non-ASCII raises on encode.
- **Streaming encode/decode.** Codec operates on the full list
  in one shot.

---

## 8. Wired into / forward references

- **M86 Phase E (shipped 2026-04-26)** — NAME_TOKENIZED is now
  wired into the genomic signal-channel write/read path for the
  `read_names` channel via a **schema lift**: when the override
  is set, the writer replaces the M82 compound `read_names`
  dataset with a flat 1-D uint8 dataset of the same name
  containing the codec output, and sets `@compression == 8` on
  it. The reader dispatches on dataset shape (compound → M82
  path; 1-D uint8 → codec dispatch). Use
  `WrittenGenomicRun.signal_codec_overrides={"read_names":
  Compression.NAME_TOKENIZED}` at write time. The codec is
  **rejected on the `sequences` and `qualities` channels**
  (Binding Decision §113): NAME_TOKENIZED tokenises UTF-8
  strings, not binary byte streams. Compression on 1000
  structured Illumina names: NAME_TOKENIZED dataset is roughly
  20–50% of the M82 compound footprint depending on baseline
  methodology (H5 storage-size vs file-size delta — see
  `docs/format-spec.md` §10.6 for the schema-lift on-disk
  contract).
- **Future optimisation milestone (deferred)** — full Bonfield
  2022 / CRAM 3.1 token type set for ≥ 20:1 compression on
  structured Illumina names. Multi-thousand lines per language
  with substantial cross-language byte-exact conformance work.

The `codecs/` sub-package layout established in M83 (rANS),
extended in M84 (BASE_PACK), M85 Phase A (QUALITY_BINNED), and
now M85 Phase B (NAME_TOKENIZED) is the home for all genomic
compression primitives going forward.
