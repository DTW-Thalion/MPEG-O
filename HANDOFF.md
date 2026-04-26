# HANDOFF — M85 Phase A: Clean-Room QUALITY_BINNED Codec (Illumina-8)

**Scope:** Clean-room implementation of the QUALITY_BINNED genomic
quality-score codec — fixed 8-bin Phred quantisation (CRUMBLE-derived
Illumina mapping) with 4-bit-packed bin indices. Lossy by
construction. Three languages (Python reference, ObjC normative,
Java parity), wire-byte conformance fixtures shared across all
three.

**Branch from:** `main` after M86 Phase A docs (`0de6fde`).

**IP provenance:** Clean-room implementation. Phred-score bin
tables in this rough shape have been published in many places —
Illumina's reduced-representation guidance, James Bonfield's
CRUMBLE paper (Bioinformatics 2019), HTSlib's `qual_quants` field,
NCBI SRA's `lossy.sra` quality binning. The exact 8-bin table this
codec uses is documented inline (§3) and is the public-domain
"Illumina-8 / CRUMBLE-style" mapping. **No htslib, no CRUMBLE, no
SRA toolkit source consulted at any point.** The 4-bit packing
geometry is the natural choice for an 8-bin index alphabet and is
not derived from any reference.

---

## 1. Background

M84 in the original WORKPLAN sketch was scoped as
`Base-Packing + Quality Quantiser Codecs`, but the milestone we
shipped on 2026-04-26 covered only BASE_PACK. Quality quantisation
slipped to M85.

The current M85 in WORKPLAN (line 120) lists name-tokenizer as the
sole scope. M85 is now restructured into two phases — same shape
as M86:

- **M85 Phase A (THIS milestone)** — `quality_binned` codec.
  Catches up on the missed M84 piece. Comparable in scope to
  BASE_PACK. Lossy by construction; round-trip via fixed
  bin-centre mapping.
- **M85 Phase B (DEFERRED)** — `name_tokenizer` codec
  (CRAM 3.1-style, Bonfield 2022). Substantially larger;
  separate future milestone after Phase A ships.

M79 reserved `Compression.QUALITY_BINNED = 7`. Phase A ships the
encoder, decoder, and cross-language fixtures for that slot. A
future M86 Phase D will wire it into the `qualities` channel of
`signal_channels/`.

---

## 2. Algorithm

QUALITY_BINNED reduces a stream of Phred scores (typically 0–40,
occasionally 0–93) to 4-bit bin indices. The 8-bin scheme means
each input byte maps to a 3-bit number, but the wire stores 4 bits
per index for trivial unpacking — see §3 binding decision §94 for
the rationale.

### Pack mapping

Each input byte (Phred score in 0..255, though typical genomic
data is 0..93) maps to one of 8 bin indices via a fixed table. The
decoder maps each bin index to a fixed bin centre — round-trip is
NOT byte-exact for arbitrary Phred input. Round-trip semantics:
`decode(encode(x)) == bin_centre[bin_of[x]]`. So Phred 7 round-trips
through bin 1 to Phred 5 (its bin centre). This is intended; quality
binning is a lossy compression scheme.

### Bin table (Illumina-8 / CRUMBLE-derived)

```
Bin  Phred range   Centre  Notes
───  ───────────   ──────  ─────────────────────────────
 0       0..1         0    "no information"
 1       2..9         5    low-confidence
 2      10..19       15    standard low / older platforms
 3      20..24       22    standard medium-low
 4      25..29       27    standard medium
 5      30..34       32    standard medium-high
 6      35..39       37    high
 7     40..255       40    capped at Phred 40 — saturates here
```

Bin index for Phred p:
```
if p <= 1:       0
elif p <= 9:     1
elif p <= 19:    2
elif p <= 24:    3
elif p <= 29:    4
elif p <= 34:    5
elif p <= 39:    6
else:            7
```

Bin centre for index b: `[0, 5, 15, 22, 27, 32, 37, 40][b]`.

The encoder emits the bin index for each input byte, then 4-bit-
packs the indices (two per byte, big-endian within byte — first
input quality occupies the high nibble).

### Bit order within a byte

**Big-endian within byte.** The first input quality score occupies
the high nibble; the second occupies the low nibble. Worked
examples:

| Input bytes (Phred)    | Bin indices    | Packed         | Hex  |
|------------------------|----------------|----------------|------|
| `0 5`                  | `0 1`          | `0b 0000 0001` | 0x01 |
| `40 30`                | `7 5`          | `0b 0111 0101` | 0x75 |
| `0 0 5 5`              | `0 0 1 1`      | `0x00 0x11`    | —    |
| `40` (single)          | `7` + padding  | `0b 0111 0000` | 0x70 |

The padding bits (low nibble of the final byte when the input has
odd length) are zero.

### Decode

1. Read the header. Validate `version == 0`, `scheme_id == 0`,
   total stream length == `6 + ceil(original_length / 2)`. Reject
   mismatches.
2. Allocate output of size `original_length`. Walk the packed
   body left-to-right: for each byte, extract the high nibble as
   bin index for output position `2*i`, and the low nibble as bin
   index for output position `2*i + 1`. Stop after
   `original_length` indices are emitted (the last byte may be
   half-used).
3. Map each bin index through the bin-centre table to produce the
   output Phred bytes.

### Edge cases

- **Empty input** → 6-byte header only.
- **Odd-length input** → final body byte has its low nibble
  padded to zero. Decoder ignores the padding because it knows
  `original_length`.
- **Phred values > 40** → clamped to bin 7 (output Phred = 40).
  Lossy but well-defined.
- **All identical** → wire size = 6 + ceil(orig / 2). For 1 MB of
  identical Phred scores, that's roughly 0.5 MB. (Compression on
  identical data isn't the use case; rANS afterwards in the M86
  pipeline does that.)

---

## 3. Wire Format (cross-language contract)

Big-endian throughout. Self-contained — the decoder needs no
external metadata.

```
Offset  Size  Field
──────  ────  ───────────────────────────────────────────
0       1     version            (0x00)
1       1     scheme_id          (0x00 = "illumina-8")
2       4     original_length    (uint32 BE — input byte count)
6       var   packed_indices     (ceil(original_length / 2) bytes)
```

Total length = `6 + ceil(original_length / 2)` bytes.

Empty input → exactly 6 bytes (header only).

Invariant: total stream length must equal
`6 + ((original_length + 1) >> 1)`. The decoder MUST validate this
and reject mismatched streams.

---

## 4. Binding Decisions (continued from M86 §86–§90)

| #  | Decision | Rationale |
|----|----------|-----------|
| 91 | Single fixed bin scheme in v0: scheme_id `0x00` = "Illumina-8" with the bin ranges and centres documented in §2. | Simpler than parameterised binning. Future schemes (NCBI 4-bin, Bonfield variable-width, etc.) get distinct scheme_ids. The wire format permits up to 256 schemes; only one is defined now. |
| 92 | Bin table is **NOT** included in the wire stream — it's implicit from the scheme_id. | Saves 16 bytes per stream and prevents accidental encode/decode mismatches across implementations. Each language hardcodes the table for scheme 0x00 and verifies it on first use of the codec. |
| 93 | Phred values > 40 clamp to bin 7 (centre = 40). | Most genomic data uses Phred 0–40. Q41+ is uncommon (PacBio/HiFi can produce Q60+ but those usually pre-quantise). Losing the saturation precision is the documented lossy semantics. |
| 94 | **4-bit-packed indices, not 3-bit-packed**, even though only 8 bins are used. | 4-bit aligns to nibble boundaries, two indices per byte, no bit-juggling across byte boundaries. 3-bit would save 25% more space but require complex bit math. The 4-bit choice trades 25% of the standalone size win for trivial pack/unpack code; the M86 pipeline composes rANS afterwards which recovers most of the difference. |
| 95 | First input quality occupies the **high nibble** of its body byte (big-endian within byte). | Matches BASE_PACK's bit-order convention (Binding Decision §82) — left-to-right reading order maps to high-to-low bits. Cross-codec consistency makes hex dumps less surprising. |
| 96 | Padding bits in the final body byte (when input has odd length) are zero. | Deterministic encoder output without recording the padding state. Decoder uses `original_length` to know how many indices to consume. |
| 97 | Lossy round-trip: `decode(encode(x)) == bin_centre[bin_of[x]]`, NOT `x`. | Quality binning is fundamentally lossy. Tests must use bin-centre inputs OR assert against the known lossy mapping, not byte-exact round-trip on arbitrary input. |

---

## 5. Python Implementation

### 5.1 `python/src/ttio/codecs/quality.py` (new file)

Public API — mirrors the rANS / BASE_PACK module shape:

```python
def encode(data: bytes) -> bytes:
    """Encode `data` (Phred score bytes) using QUALITY_BINNED.

    Maps each input byte through the Illumina-8 bin table, packs
    bin indices 4-bits-per-index (big-endian within byte). Returns
    a self-contained byte string per the wire format in
    HANDOFF.md §3.

    Lossy: round-trip via bin centres. ``decode(encode(x)) ==
    bin_centre[bin_of[x]]`` for each byte x.
    """

def decode(encoded: bytes) -> bytes:
    """Decode a stream produced by encode().

    Reads the header, unpacks the 4-bit bin indices, maps each
    through the bin-centre table. Raises ValueError on malformed
    input (bad version, bad scheme_id, length mismatch, truncated
    stream).
    """
```

Implementation notes:

- Use `bytes.translate` with a 256-entry lookup table for the
  byte→bin-index mapping. That's the same pattern the M84
  base_pack.py uses for ACGT.
- For the 4-bit pack: iterate two indices at a time; pack
  `(idx0 << 4) | idx1`. For odd input, last byte is `(last_idx
  << 4)`.
- For the unpack: iterate body bytes; emit `[byte >> 4, byte &
  0x0F]` per byte. Stop after `original_length` emissions.
- Bin-centre map for decode: `bytes([0, 5, 15, 22, 27, 32, 37,
  40])` then `output.translate(centre_map)`.
- Header: `struct.pack(">BBI", 0, 0, orig_len)` — 6 bytes.
- Decode validation: check first two bytes; check
  `len(encoded) == 6 + (orig_len + 1) // 2`; raise `ValueError`
  with a clear message on any failure.

### 5.2 Module re-exports

In `python/src/ttio/codecs/__init__.py`:
- Add: `from .quality import encode as quality_encode, decode as quality_decode`
- Update docstring: change `quality       — Phred score quantisation (M84, future)` to `quality       — Phred score quantisation (M85 Phase A)`.

### 5.3 `python/tests/test_m85_quality.py` (new file)

13 pytest cases per §7.1 below.

---

## 6. Objective-C and Java Implementations

### 6.1 ObjC — `objc/Source/Codecs/TTIOQuality.{h,m}` (new files)

Same shape as `TTIOBasePack.{h,m}`:

```objc
NSData * _Nonnull TTIOQualityEncode(NSData * _Nonnull data);

NSData * _Nullable TTIOQualityDecode(NSData * _Nonnull encoded,
                                     NSError * _Nullable * _Nullable error);
```

C-core encoder/decoder wrapped by ObjC entry points. Static
256-entry pack lookup table; 8-entry centre lookup table. Wire into
`objc/Source/GNUmakefile` (add `Codecs/TTIOQuality.h` to
`libTTIO_HEADER_FILES`, `Codecs/TTIOQuality.m` to
`libTTIO_OBJC_FILES`).

Tests in `objc/Tests/TestM85Quality.m`. Style mirrors
`TestM84BasePack.m`. Wire into `TTIOTestRunner.m` as `extern void
testM85Quality(void);` + `START_SET("M85: QUALITY_BINNED codec")
testM85Quality(); END_SET("M85: QUALITY_BINNED codec")` block in
`main`. Add `TestM85Quality.m` to `objc/Tests/GNUmakefile`'s
`TTIOTests_OBJC_FILES`. Target ≥ 30 new assertions across the 13
tests.

### 6.2 Java — `java/src/main/java/global/thalion/ttio/codecs/Quality.java` (new file)

```java
package global.thalion.ttio.codecs;

public final class Quality {
    public static byte[] encode(byte[] data) { ... }
    public static byte[] decode(byte[] encoded) { ... }
    private Quality() {}
}
```

Use `ByteBuffer` with `ByteOrder.BIG_ENDIAN` for header
serialisation. Use `Byte.toUnsignedInt(b)` whenever reading a byte
as a Phred score (since Java `byte` is signed and Phred 128+ would
otherwise sign-extend negative).

Tests in
`java/src/test/java/global/thalion/ttio/codecs/QualityTest.java`.
JUnit 5. Same 13 test cases as Python; ≥ 12 test methods, ≥ 40
assertions.

---

## 7. Tests

### 7.1 Python — `python/tests/test_m85_quality.py`

All 13 use pytest:

1. **`round_trip_pure_centre_bytes`** — input is `bytes([0, 5, 15,
   22, 27, 32, 37, 40] * 32)` (256 bytes of pure bin centres).
   `decode(encode(data)) == data` byte-exact (no information lost
   on bin-centre input).
2. **`round_trip_arbitrary_phred`** — input is `bytes(range(50))`
   (50 bytes 0..49). Compute the expected lossy round-trip
   manually: each byte x maps to its bin index then to its bin
   centre. Assert `decode(encode(data)) == expected_centres`.
3. **`round_trip_clamped`** — input includes Phred 50, 60, 93,
   100, 200, 255. All map to bin 7, centre 40. Verify.
4. **`round_trip_empty`** — `b""` → 6-byte header → `b""`.
5. **`round_trip_single_byte`** — each Phred value at a bin centre
   round-trips: 0→0, 5→5, 15→15, 22→22, 27→27, 32→32, 37→37,
   40→40. All produce 7-byte streams (6 header + 1 body, low
   nibble = 0 padding).
6. **`padding_tail_patterns`** — 1, 2, 3, 4 byte inputs verify
   the padding behaviour. Specifically: `b"\x00"` → body byte
   `0x00`; `b"\x05"` → body byte `0x10` (bin 1 in high nibble,
   padding zero in low nibble); `b"\x05\x05"` → body byte `0x11`
   (no padding); `b"\x05\x05\x05"` → body bytes `0x11 0x10`
   (padding zero in low nibble of second body byte).
7. **`compression_ratio`** — generate 1 MiB of arbitrary Phred
   bytes (via `os.urandom` mod 41 to keep them in range). Verify
   `len(encode(data))` equals `6 + (len(data) + 1) // 2` exactly.
   Should be slightly over 50% of the input.
8. **`canonical_vector_a`** — encode `data_a`, compare bytes-equal
   to fixture `quality_a.bin`.
9. **`canonical_vector_b`** — same with `quality_b.bin`.
10. **`canonical_vector_c`** — same with `quality_c.bin`.
11. **`canonical_vector_d`** — same with `quality_d.bin` (= 6
    bytes total).
12. **`decode_malformed`** — five sub-cases, each
    `pytest.raises(ValueError)`:
    - Stream shorter than the 6-byte header.
    - Bad version byte (0x01 instead of 0x00).
    - Bad scheme_id (0xFF instead of 0x00).
    - `original_length` says 4 but actual body is 5 bytes
      (mismatch with `ceil(orig/2)`).
    - Original_length 5 but body is only 2 bytes (truncation).
13. **`throughput`** — encode 10 MiB of arbitrary Phred bytes,
    log MB/s. Soft target encode ≥ 50 MB/s, decode ≥ 100 MB/s.
    Print actual.

### 7.2 ObjC — `objc/Tests/TestM85Quality.m`

Same 13 cases. Throughput soft target encode ≥ 300 MB/s, decode ≥
500 MB/s. Hard floor encode ≥ 150 MB/s, decode ≥ 250 MB/s.

### 7.3 Java — `java/src/test/java/global/thalion/ttio/codecs/QualityTest.java`

Same 13 cases. Throughput logged, no hard threshold.

### 7.4 Cross-language byte-exact conformance

The four canonical fixtures are the contract.

---

## 8. Canonical Test Vectors

All four fixtures are generated by the Python encoder and committed
under `python/tests/fixtures/codecs/`. ObjC and Java each get
verbatim copies under their fixture directories.

### Vector A — pure bin centres, 256 bytes

```python
data_a = bytes([0, 5, 15, 22, 27, 32, 37, 40]) * 32
```

Expected wire size: `6 + 128 = 134 bytes`. Body bytes are all
`0x01 0x23 0x45 0x67 ...` patterns from packed bin pairs.

### Vector B — Illumina-realistic Phred profile, 1024 bytes

A typical Phred-quality profile drops at the read end. Construct
deterministically:

```python
import hashlib
seed = hashlib.sha256(b"ttio-quality-vector-b").digest()  # 32 bytes
data_b_bytes = bytearray()
for i in range(1024):
    # First half: Phred 30..40 (mostly bin 5, 6, 7)
    # Second half: Phred 15..30 (mostly bin 2, 3, 4, 5)
    if i < 512:
        base = 30 + (seed[i % 32] % 11)   # 30..40
    else:
        base = 15 + (seed[i % 32] % 16)   # 15..30
    data_b_bytes.append(base)
data_b = bytes(data_b_bytes)
```

Expected wire size: `6 + 512 = 518 bytes`. mask_count style metric
n/a (no mask in QUALITY_BINNED).

### Vector C — edge-case Phred values, 64 bytes

Hand-constructed to exercise every bin transition and saturation,
exactly 64 bytes:

```python
data_c = bytes([
    # 24 bytes covering every bin boundary (low + high edge of each bin)
    0,  1,         # bin 0 edges
    2,  5,  9,     # bin 1 low/centre/high
    10, 15, 19,    # bin 2 low/centre/high
    20, 22, 24,    # bin 3 low/centre/high
    25, 27, 29,    # bin 4 low/centre/high
    30, 32, 34,    # bin 5 low/centre/high
    35, 37, 39,    # bin 6 low/centre/high
    40, 41, 50, 60, 93, 100, 200, 255,  # bin 7 + saturation (8 bytes)
    # 32 bytes of bin centres (4 cycles of the 8 centres)
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
])
assert len(data_c) == 64
```

Count check: 2 + 3 + 3 + 3 + 3 + 3 + 3 + 8 = 28 bytes for the
boundary-coverage section. (Bin 0 contributes only the two values
0 and 1, since `1` is both the centre and the high edge — the
table above lists each bin distinctly.) Then 32 bytes of bin
centres = 28 + 32 = **60**. Need 4 more bytes — append four more
centres `0, 5, 15, 22`. Final input:

```python
data_c = bytes([
    0,  1,
    2,  5,  9,
    10, 15, 19,
    20, 22, 24,
    25, 27, 29,
    30, 32, 34,
    35, 37, 39,
    40, 41, 50, 60, 93, 100, 200, 255,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22,
])
assert len(data_c) == 64, f"expected 64, got {len(data_c)}"
```

Expected wire size: `6 + 32 = 38 bytes` (64 input bytes → 32
packed body bytes).

### Vector D — empty

```python
data_d = b""
```

Expected wire size: 6 bytes (header only).

### Reference output generation

```python
import hashlib
from ttio.codecs.quality import encode, decode

# Bin and centre tables for the lossy round-trip check.
_BIN_OF = [0]*2 + [1]*8 + [2]*10 + [3]*5 + [4]*5 + [5]*5 + [6]*5 + [7]*(256-40)
_CENTRE = [0, 5, 15, 22, 27, 32, 37, 40]

def lossy_expected(data):
    return bytes(_CENTRE[_BIN_OF[b]] for b in data)

# Vector A — pure bin centres
data_a = bytes([0, 5, 15, 22, 27, 32, 37, 40]) * 32
assert len(data_a) == 256

# Vector B — Illumina-realistic Phred profile
seed = hashlib.sha256(b"ttio-quality-vector-b").digest()
data_b_bytes = bytearray()
for i in range(1024):
    if i < 512:
        base = 30 + (seed[i % 32] % 11)
    else:
        base = 15 + (seed[i % 32] % 16)
    data_b_bytes.append(base)
data_b = bytes(data_b_bytes)

# Vector C — exact 64-byte sequence per HANDOFF.md §8
data_c = bytes([
    0,  1,
    2,  5,  9,
    10, 15, 19,
    20, 22, 24,
    25, 27, 29,
    30, 32, 34,
    35, 37, 39,
    40, 41, 50, 60, 93, 100, 200, 255,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 5, 15, 22,
])
assert len(data_c) == 64

# Vector D — empty
data_d = b""

for name, data in [("a", data_a), ("b", data_b), ("c", data_c), ("d", data_d)]:
    enc = encode(data)
    assert decode(enc) == lossy_expected(data), f"{name}: lossy round-trip failed"
    open(f"tests/fixtures/codecs/quality_{name}.bin", "wb").write(enc)
    print(f"{name}: {len(data)} -> {len(enc)} bytes")
```

The four input vectors A/B/C/D are deterministic and pinned by
this script. ObjC and Java tests must construct the same input
bytes (using the same SHA-256 salt for B and the same literal
sequences for A, C, D) and compare encoder output against the
committed `.bin` fixtures.

---

## 9. Integration Point (Forward Reference)

M85 Phase A does NOT wire QUALITY_BINNED into the genomic
signal-channel pipeline — that's a future M86 phase (call it
M86 Phase D, separate from Phase A which wired rANS + BASE_PACK).
M85 Phase A delivers QUALITY_BINNED as a standalone primitive.

When M86 Phase D lands, a `signal_channels/qualities` dataset's
`@compression == 7` will route the raw bytes through
`quality.decode()`. The current M82 storage (raw Phred bytes)
remains the `@compression == 0` (NONE) case.

---

## 10. Documentation

### 10.1 `docs/codecs/quality.md` (new)

Codec specification document, parallel structure to
`docs/codecs/rans.md` and `docs/codecs/base_pack.md`:

- Algorithm summary (8-bin Illumina-style + 4-bit packing)
- Bin table (Phred ranges → bin index → bin centre)
- Lossy round-trip explanation with worked examples
- Wire format diagram
- 4-bit-vs-3-bit rationale (Binding Decision §94)
- IP provenance statement
- Cross-language conformance contract
- Performance targets per language
- Public API in each of the three languages

### 10.2 `CHANGELOG.md`

Add M85 Phase A entry under `[Unreleased]`. Update the Unreleased
header to mention M85 Phase A. Format mirrors the M83/M84/M86
entries.

### 10.3 `docs/format-spec.md` §10.4

Flip the **quality-binned** row from "Reserved enum slot … NOT
YET IMPLEMENTED" to "Implemented in M85 Phase A …" with a pointer
to `docs/codecs/quality.md`. Update the trailing summary
paragraph: ids `4`, `5`, `6`, `7` now ship as standalone
primitives; id `8` (name-tokenized) remains reserved-only and is
deferred to M85 Phase B.

### 10.4 `python/src/ttio/codecs/__init__.py`

Update the docstring listing: change
`quality       — Phred score quantisation (M84, future)` to
`quality       — Phred score quantisation (M85 Phase A)`.

### 10.5 `WORKPLAN.md`

The M85 section needs restructuring to reflect Phase A shipping
and Phase B (name-tokenizer) deferring. Format mirrors the M86
restructure landed in `0de6fde`:

```
### M85 — Quality Quantiser + Name Tokeniser Codecs

**Status: Phase A shipped (2026-04-26). Phase B deferred.**

#### Phase A — quality_binned codec (SHIPPED)
- [x] ttio.codecs.quality — fixed Illumina-8 bin table (CRUMBLE-
      derived), 4-bit-packed indices, lossy by construction.
- [x] All three languages, cross-language byte-exact fixtures.
- (commit refs)

#### Phase B — name_tokenizer codec (DEFERRED)
- ttio.codecs.name_tokenizer: CRAM 3.1-style read name compression.
  ... (existing wishlist preserved)
```

Also: update the M84 acceptance-criteria text in WORKPLAN if the
M84 entry's "Quality Quantiser" half was acknowledged anywhere.
(Spot-check during the docs phase; if no concrete claim was made,
no edit needed.)

---

## 11. Gotchas (continued from M86 §96–§102)

103. **Lossy round-trip is a feature.** Tests must NOT assert
     `decode(encode(arbitrary)) == arbitrary`. Use bin-centre
     inputs for byte-exact round-trips, or assert against the
     expected lossy output. Mistaken assertions will produce
     "test passes for trivial inputs but fails for real Phred
     data" bugs.

104. **Phred 41+ saturates to bin 7 / centre 40.** PacBio HiFi
     produces Phred 60+ scores; those will round-trip to 40 with
     this codec. Document. Future scheme_ids may add wider
     ranges; for v0 of scheme 0x00, saturation is the spec.

105. **Padding-bit determinism.** Final body byte's low nibble
     MUST be zero when input has odd length. Encoder bugs that
     leave stack garbage there will fail the cross-language
     fixture comparison. Tests must include a 1-byte input
     (which packs to a single high-nibble plus zero padding).

106. **Header is fixed size: 6 bytes.** No optional fields; no
     embedded bin table. Future scheme_ids may extend the
     header (in which case version bumps to 0x01); v0 is the
     6-byte header documented in §3.

107. **Java unsigned-byte gotcha.** Phred values must be read as
     unsigned bytes from `byte[]`. `Byte.toUnsignedInt(b)` is
     the canonical idiom. Without it, Phred 200+ would
     sign-extend to a negative int and crash the bin-table
     lookup.

108. **No MPGO remnants.** M83 audited the ObjC tree; nothing
     to clean.

---

## Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `0de6fde`).
- [ ] `quality.encode` / `quality.decode` ship in
      `python/src/ttio/codecs/quality.py` with the wire format
      from §3.
- [ ] All 13 tests in `python/tests/test_m85_quality.py` pass.
- [ ] All four canonical fixtures
      (`quality_{a,b,c,d}.bin`) committed and match the encoder
      output byte-exact.
- [ ] Decode malformed (5 sub-cases) raises ValueError.
- [ ] Throughput logged (encode ≥ 50 MB/s, decode ≥ 100 MB/s).
- [ ] Module re-export + docstring updated in
      `python/src/ttio/codecs/__init__.py`.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2119
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] `TTIOQualityEncode` / `TTIOQualityDecode` ship.
- [ ] All 13 tests in `TestM85Quality.m` pass byte-exact against
      the Python fixtures.
- [ ] Malformed input → NSError, no crash, all 5 sub-cases.
- [ ] Throughput: encode ≥ 150 MB/s hard floor (soft ≥ 300);
      decode ≥ 250 MB/s hard floor (soft ≥ 500).
- [ ] ≥ 30 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 441/0/0/0
      baseline → ≥ 454/0/0/0 after M85 Phase A).
- [ ] `Quality.encode` / `Quality.decode` ship.
- [ ] All four canonical vectors match Python fixtures byte-exact.
- [ ] Malformed input → IllegalArgumentException, all 5 sub-cases.
- [ ] ≥ 12 test methods, ≥ 40 assertions.

### Cross-Language
- [ ] Python, ObjC, and Java produce identical encoded bytes for
      vectors A, B, C, D.
- [ ] Fixture files committed under
      `python/tests/fixtures/codecs/quality_*.bin` and copied
      verbatim to `objc/Tests/Fixtures/` and
      `java/src/test/resources/ttio/codecs/`.
- [ ] `docs/codecs/quality.md` committed and complete.
- [ ] `CHANGELOG.md` M85 Phase A entry committed under
      `[Unreleased]`.
- [ ] `docs/format-spec.md` §10.4 quality-binned row flipped to
      "implemented".
- [ ] `python/src/ttio/codecs/__init__.py` docstring updated.
- [ ] `WORKPLAN.md` M85 section restructured into Phase A
      (shipped) and Phase B (deferred).

---

## Out of Scope

- **Name-tokenizer codec.** That's M85 Phase B, a separate future
  milestone. Bonfield 2022 is substantially larger than
  quality_binned and warrants its own plan.
- **Wiring quality_binned into the genomic pipeline.** That's a
  future M86 phase, not M85 Phase A.
- **Variable bin schemes.** Only scheme_id `0x00` (Illumina-8) is
  defined in v0. Future scheme_ids can add NCBI 4-bin, Bonfield
  variable-width, etc.
- **Quality scores > Phred 40.** Saturate to bin 7. Future codecs
  with wider Phred range support are out of scope.
- **rANS / Huffman composition inside the codec.** Standalone
  size win is the 4-bit packing alone (~50%). Further compression
  comes from M86 piping the output through rANS_order0; that's
  composition, not codec scope.
- **Performance optimisation beyond the targets.** SIMD,
  vectorised pack/unpack tables, GPU offload — all out of scope.
