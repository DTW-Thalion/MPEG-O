# HANDOFF — M83: Clean-Room rANS Entropy Codec

**Scope:** Clean-room implementation of the range Asymmetric Numeral
Systems (rANS) entropy codec — order-0 and order-1 — across all three
languages (Python reference, ObjC normative, Java). This is the
foundational compression codec that all subsequent genomic signal
channel codecs (base-pack, quality quantiser, name tokeniser) feed
into. Also fixes the stale `MPGOInstrumentConfig.h` remnant from the
M80 rebrand and verifies zero MPGO references remain in the ObjC
codebase.

**Branch from:** `main` after M82.5.

**IP provenance:** Clean-room implementation from Jarek Duda,
"Asymmetric numeral systems: entropy coding combining speed of
Huffman coding with compression rate of arithmetic coding",
arXiv:1311.2540, 2014. Public domain algorithm. **No htslib source
code is consulted.** The implementation follows the mathematical
specification and pseudocode from the paper. Correctness is validated
via round-trip property and independently computed test vectors.

---

## 1. Algorithm Summary

rANS is an entropy coder that achieves compression rates close to
arithmetic coding with throughput close to Huffman coding. The key
properties for TTI-O:

- **Order-0:** Each symbol is coded using its marginal frequency.
  Good for data with varying symbol distributions (flags, packed
  bases).
- **Order-1:** Each symbol is coded using its frequency conditioned
  on the previous symbol. Better for data with local correlations
  (quality scores, delta-encoded positions).
- **Round-trip exact:** `decode(encode(data)) == data` for all inputs.
- **Byte-aligned output:** The compressed stream is a byte array.

### Core operations (order-0)

```
State: a single integer `x` in [L, b*L)  where L = 2^23, b = 2^8

Encode symbol s with frequency f_s, cumulative frequency c_s, total M:
  x_new = (x / f_s) * M + (x % f_s) + c_s
  while x_new >= b*L: output x_new & 0xFF; x_new >>= 8

Decode:
  slot = x % M
  find s such that c_s <= slot < c_s + f_s
  x_new = f_s * (x / M) + slot - c_s
  while x_new < L: x_new = (x_new << 8) | read_byte()
```

### Order-1 extension

Maintain 256 separate frequency tables, one per context (previous
symbol). Encode/decode uses the table selected by the previous
symbol. First symbol uses context 0.

---

## 2. Python Implementation

### 2.1 `python/src/ttio/codecs/__init__.py`

Create the `codecs/` subpackage under `ttio/`. Empty `__init__.py`
with docstring:

```python
"""TTI-O compression codecs — clean-room implementations.

All codecs in this package are implemented from published academic
literature. No third-party codec library source code is consulted.

Codecs:
    rans       — rANS order-0 and order-1 entropy coding (Duda 2014)
    base_pack  — 2-bit nucleotide packing (M84, future)
    quality    — Phred score quantisation (M84, future)
    name_tok   — Read name tokenisation (M85, future)
"""
```

### 2.2 `python/src/ttio/codecs/rans.py`

Public API:

```python
def encode(data: bytes, order: int = 0) -> bytes:
    """Encode `data` using rANS with the given context order (0 or 1).

    Returns a self-contained byte string: header + frequency table(s) +
    compressed payload. The header encodes order and original length so
    that `decode()` is parameter-free.

    Wire format:
      byte 0:      order (0 or 1)
      bytes 1-4:   original length (uint32 big-endian)
      bytes 5-8:   compressed payload length (uint32 big-endian)
      bytes 9-...: frequency table (order-0: 256 x uint32 = 1024 bytes;
                    order-1: 256 x 256 x uint16 = 131072 bytes,
                    but zero-rows are run-length compressed)
      remainder:   compressed payload (byte-aligned rANS bitstream)
    """

def decode(encoded: bytes) -> bytes:
    """Decode a byte string produced by `encode()`.

    Reads order and length from the header; returns the original data.
    Raises ValueError on malformed input.
    """
```

Implementation details:

- **Frequency table construction:** Scan input, count symbol
  frequencies. Normalise to sum = 4096 (M = 2^12). Symbols with
  count > 0 get at least frequency 1. Normalisation uses the
  method: scale proportionally, then distribute rounding remainder
  to the most-frequent symbols.
- **State width:** L = 2^23, b = 2^8. State is a Python int (no
  overflow risk in Python). For the C/Java ports, state is uint64.
- **Encoding direction:** Encode in reverse order (last symbol
  first), output bytes in forward order. This is standard rANS:
  the decoder reads forward and recovers symbols in the original
  order.
- **Frequency table serialisation (order-0):** 256 × uint32
  (4 bytes each) = 1024 bytes. Even for small alphabets this is
  acceptable; the overhead is constant and amortised over any
  non-trivial input.
- **Frequency table serialisation (order-1):** 256 context rows ×
  256 × uint16 would be 128 KB uncompressed. Instead, use run-
  length encoding: for each context row, write (count_of_nonzero,
  then for each nonzero: symbol_byte, freq_uint16). Prefix each
  row with uint16 count_of_nonzero; skip rows where count is 0
  (write just 0x0000). This compresses typical genomic data tables
  to a few KB.
- **Edge cases:**
  - Empty input → header only (length = 0), no payload.
  - Single-symbol input → header + freq table + minimal payload.
  - Input with only one distinct symbol → all frequency assigned
    to that symbol; payload is essentially just the state.

### 2.3 Module registration

In `python/src/ttio/codecs/__init__.py`:

```python
from .rans import encode as rans_encode, decode as rans_decode
```

In `python/src/ttio/__init__.py`, add `codecs` to the package but
do NOT add `rans_encode`/`rans_decode` to `__all__` — these are
internal compression primitives, not part of the public data-model
API. Access via `from ttio.codecs.rans import encode, decode`.

---

## 3. Objective-C Implementation

### 3.1 `objc/Source/Codecs/TTIORans.h`

```objc
/**
 * rANS entropy codec — order-0 and order-1.
 *
 * Clean-room implementation from Duda 2014. No htslib source code
 * consulted.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.rans
 *   Java:   global.thalion.ttio.codecs.Rans
 */

/** Encode `data` using rANS with the given order (0 or 1).
 *  Returns an autoreleased NSData containing the self-contained
 *  compressed stream (header + freq table + payload). */
NSData * _Nonnull TTIORansEncode(NSData * _Nonnull data, int order);

/** Decode a stream produced by TTIORansEncode.
 *  Returns the original data. Sets *error on malformed input. */
NSData * _Nullable TTIORansDecode(NSData * _Nonnull encoded,
                                  NSError * _Nullable * _Nullable error);
```

### 3.2 `objc/Source/Codecs/TTIORans.m`

C implementation wrapped in ObjC entry points. Use `uint64_t` for
the rANS state. The encode/decode core is pure C functions
(`rans_encode_order0`, `rans_decode_order0`, `rans_encode_order1`,
`rans_decode_order1`) called by the ObjC wrappers.

Performance target: ≥ 50 MB/s encode, ≥ 200 MB/s decode on a single
core (C code, no SIMD). This is 10× faster than the Python pure
implementation and matches the ballpark of htslib's rANS throughput.

### 3.3 Add to GNUmakefile

Add `Source/Codecs/TTIORans.m` to `OBJC_SOURCES`. No new library
dependencies.

---

## 4. Java Implementation

### 4.1 `java/src/main/java/global/thalion/ttio/codecs/Rans.java`

```java
package global.thalion.ttio.codecs;

/**
 * rANS entropy codec — order-0 and order-1.
 *
 * Clean-room implementation from Duda 2014. No htslib source code
 * consulted.
 */
public final class Rans {

    /** Encode data using rANS with the given order (0 or 1). */
    public static byte[] encode(byte[] data, int order) { ... }

    /** Decode a stream produced by encode(). */
    public static byte[] decode(byte[] encoded) { ... }

    private Rans() {} // utility class
}
```

Use `long` (64-bit signed) for the rANS state. Java's lack of
unsigned types means careful masking: `state & 0xFFFFFFFFFFFFFFFFL`
for comparisons, `Byte.toUnsignedInt(b)` for symbol values.

---

## 5. Wire Format (Cross-Language Contract)

The encoded byte stream must be identical across all three languages
for the same input. This is the cross-language wire contract.

```
Offset  Size   Field
──────  ─────  ─────────────────────────────
0       1      order (0x00 or 0x01)
1       4      original_length (uint32 BE)
5       4      payload_length (uint32 BE)
9       var    frequency_table
                 order-0: 256 × uint32 BE = 1024 bytes
                 order-1: RLE-compressed context tables
                   for each context 0..255:
                     uint16 BE: n_nonzero
                     n_nonzero × (uint8 symbol + uint16 BE freq)
9+ft    var    payload (rANS encoded bytes)
```

The `payload_length` field allows the decoder to know exactly how
many bytes to read for the payload, enabling the encoded stream to
be embedded in a larger container (e.g., an HDF5 dataset attribute
or a `.tis` transport packet).

---

## 6. Test Vectors

### 6.1 Canonical test vectors

Define three canonical test vectors that all three languages must
produce identical output for:

**Vector A — uniform random (256 bytes):**
```python
import hashlib
data_a = hashlib.sha256(b"ttio-rans-test-vector-a").digest() * 8  # 256 bytes
```
SHA-256 of `b"ttio-rans-test-vector-a"` repeated 8 times. Roughly
uniform distribution. Expected: compressed size ≈ input size (low
compressibility).

**Vector B — biased (1024 bytes):**
```python
data_b = bytes([0]*800 + [1]*100 + [2]*80 + [3]*44)  # 1024 bytes
```
Heavily skewed distribution. Expected: compressed size < 300 bytes
(order-0).

**Vector C — correlated (512 bytes):**
```python
data_c = bytes([i % 4 for i in range(512)])  # 0,1,2,3,0,1,2,3,...
```
Perfectly predictable with order-1. Expected: order-1 compressed
size < order-0 compressed size.

Store these vectors and their expected encoded outputs in test
fixtures. Generate the reference outputs from the Python
implementation first, then verify ObjC and Java produce identical
bytes.

### 6.2 Reference output generation

```bash
cd python && python -c "
from ttio.codecs.rans import encode
import hashlib

data_a = hashlib.sha256(b'ttio-rans-test-vector-a').digest() * 8
data_b = bytes([0]*800 + [1]*100 + [2]*80 + [3]*44)
data_c = bytes([i % 4 for i in range(512)])

for name, data, order in [
    ('a_o0', data_a, 0), ('a_o1', data_a, 1),
    ('b_o0', data_b, 0), ('b_o1', data_b, 1),
    ('c_o0', data_c, 0), ('c_o1', data_c, 1),
]:
    enc = encode(data, order)
    path = f'tests/fixtures/codecs/rans_{name}.bin'
    open(path, 'wb').write(enc)
    print(f'{name}: {len(data)} -> {len(enc)} bytes')
"
```

Commit the `.bin` fixtures. ObjC and Java tests load these fixtures
and verify their encoders produce identical bytes, and their decoders
recover the original data.

---

## 7. Tests

### 7.1 Python — `python/tests/test_m83_rans.py`

1. **Round-trip order-0 — random bytes.** Generate 1 MB of
   `os.urandom()`. Encode order-0, decode, assert byte-exact match.
2. **Round-trip order-1 — random bytes.** Same with order-1.
3. **Round-trip order-0 — biased data.** 1 MB of 90% 0x00, 5% 0x01,
   3% 0x02, 2% 0x03. Compressed size < 0.5 MB. Round-trip exact.
4. **Round-trip order-1 — biased data.** Same. Compressed size ≤
   order-0 compressed size.
5. **Round-trip — all-identical bytes.** 1 MB of 0x41. Compressed
   size < 10 KB. Round-trip exact.
6. **Round-trip — single byte.** Input `b"\x42"`. Round-trip exact.
7. **Round-trip — empty input.** Input `b""`. Round-trip exact.
8. **Canonical vector A (order-0).** Encode, compare to fixture
   `rans_a_o0.bin`. Byte-exact match.
9. **Canonical vector A (order-1).** Same with `rans_a_o1.bin`.
10. **Canonical vector B (order-0).** Encode, compare to fixture.
    Compressed size < 300 bytes.
11. **Canonical vector B (order-1).** Encode, compare to fixture.
12. **Canonical vector C (order-0 vs order-1).** Verify order-1
    compressed size < order-0 compressed size.
13. **Decode malformed input.** Truncated stream → `ValueError`.
    Wrong magic → `ValueError`.
14. **Throughput benchmark.** Encode 10 MB order-0, log time. Decode,
    log time. PASS if encode ≥ 2 MB/s, decode ≥ 5 MB/s (Python
    pure — relaxed targets). Print actual throughput.

### 7.2 ObjC — `objc/Tests/TestM83Rans.m`

Register in `TTIOTestRunner.m` under `M83: rANS codec`.

1. Round-trip order-0 — 1 MB random. Byte-exact.
2. Round-trip order-1 — 1 MB random. Byte-exact.
3. Round-trip order-0 — 1 MB biased. Size < 0.5 MB.
4. Round-trip — all-identical 1 MB. Size < 10 KB.
5. Round-trip — empty.
6. Round-trip — single byte.
7. Canonical vector A order-0 — matches Python fixture.
8. Canonical vector B order-0 — matches Python fixture.
9. Canonical vector C order-0 — matches Python fixture.
10. Canonical vector C order-1 — matches Python fixture.
11. Decode malformed → error, no crash.
12. Throughput: encode ≥ 50 MB/s, decode ≥ 200 MB/s. Logged.

Target: ≥ 30 new assertions.

### 7.3 Java — `java/src/test/java/global/thalion/ttio/codecs/RansTest.java`

JUnit 5. Same coverage as ObjC:

1. Round-trip order-0/1 random 1 MB.
2. Round-trip biased.
3. Round-trip all-identical.
4. Round-trip empty + single byte.
5. Canonical vectors vs Python fixtures (byte-exact).
6. Decode malformed → exception.
7. Throughput logged.

Target: ≥ 12 test methods, ≥ 40 assertions.

### 7.4 Cross-language byte-exact conformance

The canonical vector fixtures are the conformance contract. All three
languages must produce identical encoded bytes for vectors A, B, C
at both orders. This is validated by each language loading the
Python-generated fixture and comparing its own encoder output.

---

## 8. Integration Point (Forward Reference)

M83 does NOT wire the rANS codec into the genomic signal channel
pipeline — that's M86 (codec integration). M83 delivers the codec
as a standalone, tested, cross-language-conformant compression
primitive. The wiring (replacing zlib on genomic channels with rANS)
is a separate milestone to keep scope tight.

However, the `Compression.RANS_ORDER0` and `RANS_ORDER1` enum values
from M79 are the eventual targets. When M86 wires it up, a genomic
signal channel's `@compression` attribute will hold `4` or `5`,
and the read path will call `rans.decode()` on the raw dataset bytes.

---

## 9. Documentation

### 9.1 `docs/codecs/rans.md` (new)

Codec specification document:
- Algorithm summary (order-0 and order-1)
- Wire format diagram
- Frequency table normalisation rules
- State width and renormalisation thresholds
- IP provenance statement (Duda 2014, public domain)
- Cross-language conformance requirement
- Performance targets per language

### 9.2 `CHANGELOG.md`

Add M83 entry under `[Unreleased]`.

---

## 10. Gotchas

82. **Python performance.** Pure-Python rANS will be slow (2–5 MB/s
    encode). This is acceptable for M83 — the optional Cython/C
    extension is deferred to a performance milestone. The ObjC and
    Java implementations will be much faster (C and JIT respectively).
    Tests use relaxed throughput thresholds for Python.

83. **Java unsigned arithmetic.** Java has no unsigned integer types.
    The rANS state must be `long` (int64), and all comparisons must
    mask correctly. `state >>> 8` (unsigned right shift) is critical
    — do NOT use `state >> 8` (arithmetic shift, sign-extends).
    Symbol bytes from `byte[]` must be widened with
    `Byte.toUnsignedInt(b)`.

84. **Frequency table normalisation determinism.** The normalisation
    step (distributing rounding remainder) must be deterministic
    across languages. Use this rule: after proportional scaling, sort
    symbols by descending original count (stable sort by symbol value
    for ties), then distribute +1 to each in order until the total
    reaches M. This guarantees identical frequency tables for
    identical input across Python, ObjC, and Java.

85. **Encoding direction.** rANS encodes symbols in reverse order
    (last symbol first) and emits output bytes forward. The decoder
    reads bytes forward and recovers symbols in original order.
    Getting this wrong produces valid-looking output that decodes to
    garbage. Verify with a 4-byte test case first.

86. **Order-1 first-symbol context.** The first symbol in the stream
    has no predecessor. Use context = 0 (the null byte) as the
    initial context for both encoder and decoder. This must be
    identical across all three languages.

87. **Wire format endianness.** All multi-byte integers in the wire
    format (header fields, frequency table entries) are big-endian.
    Python uses `int.to_bytes(..., 'big')`. ObjC uses manual byte
    packing or `htonl`/`htons`. Java uses `ByteBuffer` with
    `ByteOrder.BIG_ENDIAN` (the default).

88. **Stale MPGO remnant — mandatory cleanup.** The M80 rebrand
    missed `objc/Source/Run/MPGOInstrumentConfig.h`. The .m file
    (`TTIOInstrumentConfig.m`) was renamed correctly but the .h file
    still declares `@interface MPGOInstrumentConfig` with header
    guard `MPGO_INSTRUMENT_CONFIG_H` and references `MPGOHDF5Group`.
    This is not cosmetic — it's a stale pre-rebrand artifact that
    must be fixed in M83 before new code ships. See §11 below.

---

## 11. MPGO Remnant Cleanup (Mandatory)

The M80 rebrand missed one header file and potentially other
straggling references. M83 fixes them as a prerequisite before
new ObjC code ships.

### 11.1 `objc/Source/Run/MPGOInstrumentConfig.h`

Rename the file and fix all internal references:

```bash
mv objc/Source/Run/MPGOInstrumentConfig.h \
   objc/Source/Run/TTIOInstrumentConfig.h
```

Inside the renamed `TTIOInstrumentConfig.h`:

- Header guard: `MPGO_INSTRUMENT_CONFIG_H` → `TTIO_INSTRUMENT_CONFIG_H`
- Forward declaration: `@class MPGOHDF5Group` → `@class TTIOHDF5Group`
- Interface: `@interface MPGOInstrumentConfig` → `@interface TTIOInstrumentConfig`
- Method signatures: `MPGOHDF5Group` → `TTIOHDF5Group`

### 11.2 Fix all `#import` references

```bash
grep -rn "MPGOInstrumentConfig" objc/ --include='*.h' --include='*.m'
```

Every hit must change:
- `#import "Run/MPGOInstrumentConfig.h"` → `#import "Run/TTIOInstrumentConfig.h"`
- `#import "MPGOInstrumentConfig.h"` → `#import "TTIOInstrumentConfig.h"`
- Any `MPGOInstrumentConfig *` declarations → `TTIOInstrumentConfig *`

Known consumers: `TTIOAcquisitionRun.h`, `TTIOAcquisitionRun.m`,
`TTIOSpectralDataset.m`, `TTIOMzMLWriter.m`, possibly test files.

### 11.3 Full MPGO grep

After the rename, run:

```bash
grep -rn "MPGO\|Mpgo\|mpgo" objc/ --include='*.h' --include='*.m' \
  | grep -v "MPEG-G"
```

This must return **zero results**. If any other stale references
surface, fix them in this pass.

### 11.4 WORKPLAN.md header

`WORKPLAN.md` still opens with `# MPEG-O Workplan`. The historical
milestone descriptions reference the old `MPGO` class names, which
is fine as documentation of what was built. But the document title
should be updated to `# TTI-O Workplan` for consistency. Do NOT
rename class names inside already-completed milestone descriptions
— they're historical records.

### 11.5 Verify

```bash
cd objc && make CC=clang OBJC=clang && make CC=clang OBJC=clang check
```

Same assertion count as before. No regressions from the rename.

---

## Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions).
- [ ] rANS order-0 round-trip: 1 MB random data, byte-exact.
- [ ] rANS order-1 round-trip: 1 MB random data, byte-exact.
- [ ] Biased data compressed to < 50% of original size (order-0).
- [ ] All-identical data compressed to < 1% of original size.
- [ ] Empty and single-byte inputs round-trip correctly.
- [ ] Canonical vectors A/B/C encode to expected fixture bytes.
- [ ] Malformed input raises ValueError.
- [ ] Throughput logged (encode ≥ 2 MB/s, decode ≥ 5 MB/s).

### Objective-C
- [ ] All existing tests pass (zero regressions).
- [ ] rANS order-0/1 round-trip: 1 MB random, byte-exact.
- [ ] Canonical vectors match Python fixtures (byte-exact encoded).
- [ ] Malformed input → NSError, no crash.
- [ ] Throughput: encode ≥ 50 MB/s, decode ≥ 200 MB/s.
- [ ] ≥ 30 new assertions.

### Java
- [ ] All existing tests pass (zero regressions).
- [ ] rANS order-0/1 round-trip: 1 MB random, byte-exact.
- [ ] Canonical vectors match Python fixtures (byte-exact encoded).
- [ ] Malformed input → exception.
- [ ] ≥ 12 test methods, ≥ 40 assertions.

### Cross-Language
- [ ] Python, ObjC, and Java produce identical encoded bytes for
      canonical vectors A, B, C at both order-0 and order-1.
- [ ] Fixture files committed under `python/tests/fixtures/codecs/`.
- [ ] `docs/codecs/rans.md` committed.
- [ ] CI green across all three languages.

### MPGO Cleanup
- [ ] `objc/Source/Run/MPGOInstrumentConfig.h` renamed to
      `TTIOInstrumentConfig.h` with all internal references fixed.
- [ ] `grep -rn "MPGO\|Mpgo\|mpgo" objc/ --include='*.h' --include='*.m' | grep -v "MPEG-G"` returns zero results.
- [ ] `WORKPLAN.md` title updated to `# TTI-O Workplan`.
- [ ] ObjC test suite passes with same assertion count (no regressions from rename).

---

## Binding Decisions

| # | Decision | Rationale |
|---|---|---|
| 75 | rANS state width: 64-bit unsigned (Python int, ObjC uint64_t, Java long with unsigned masking). L = 2^23, b = 2^8. | Matches the standard rANS parameterisation from Duda 2014. 32-bit state would limit alphabet size. |
| 76 | Frequency table normalisation total M = 4096 (2^12). | Power-of-two M enables fast modulo via bitmask. 4096 gives sufficient precision for 256-symbol alphabets while keeping table size small. |
| 77 | Wire format: big-endian, self-contained header with order + original_length + payload_length + freq table + payload. | Self-contained streams can be embedded in HDF5 datasets or .tis packets without external metadata. Big-endian matches network byte order convention. |
| 78 | Frequency table normalisation rounding: distribute remainder to symbols sorted by descending original count, stable by symbol value. | Deterministic across languages. Ensures cross-language byte-exact conformance. |
| 79 | MPGO remnant cleanup is mandatory in M83, not deferred. Zero tolerance for stale pre-rebrand identifiers in ObjC source. | Technical debt compounds. New code in `objc/Source/Codecs/` ships alongside `objc/Source/Run/` — stale MPGO prefixes in the same build tree are unacceptable. |
