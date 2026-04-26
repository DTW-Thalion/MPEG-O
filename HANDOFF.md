# HANDOFF — M84: Clean-Room BASE_PACK Codec + Sidecar Mask

**Scope:** Clean-room implementation of the BASE_PACK genomic
sequence codec — 2-bit packing for canonical ACGT bases plus a
sidecar mask dataset that losslessly preserves any non-ACGT byte at
its original position. Three languages (Python reference, ObjC
normative, Java parity), wire-byte conformance fixtures shared
across all three.

**Branch from:** `main` after M83 + format-spec slot 4/5 flip
(`7b20ac9`).

**IP provenance:** Clean-room implementation. The 2-bit-per-base
packing convention is decades-old prior art, fundamental and
ungatewayed by IP. **No htslib, no jbzip, no CRAM tools-Java source
consulted.** The sidecar mask layout is a TTI-O-specific design
choice (sparse position+byte list, see §3 binding decision §80).
Correctness is validated via round-trip property and independently
computed test vectors.

---

## 1. Algorithm Summary

BASE_PACK reduces canonical genomic-sequence storage by 4× (one
byte per base → two bits per base) while remaining lossless on the
full 256-byte alphabet via a sidecar mask.

The encoder partitions the input into two streams:

- **Packed body.** Bases that are `A`, `C`, `G`, `T` (uppercase
  only) get encoded into 2-bit slots, four bases per output byte.
  Their positions in the packed body **shift down**: position `i` in
  the input maps to byte `i // 4`, slot `i % 4`. Bases that are
  *not* canonical ACGT still occupy a slot in the packed body — the
  encoder writes a placeholder (`0b00`, i.e., `A`) to keep the bit
  geometry simple — and their original byte is recorded in the
  mask so the decoder restores them.
- **Sidecar mask.** A sorted list of `(position: uint32,
  original_byte: uint8)` pairs, one entry per non-ACGT input byte.
  Position is the *input* index (not the packed-body byte index).
  Encoded inline in the same self-contained byte stream produced
  by `encode()`.

### Pack mapping (case-sensitive)

```
'A' (0x41) → 0b00
'C' (0x43) → 0b01
'G' (0x47) → 0b10
'T' (0x54) → 0b11
anything else → mask entry (placeholder 0b00 written to body)
```

**Case is significant.** Lowercase `a`/`c`/`g`/`t` go to the mask.
This is intentional: many genomic pipelines use lowercase as
*soft-masking* (e.g., to mark repeat regions), and a codec that
silently uppercased would destroy that signal. BASE_PACK
round-trips soft-masking for free at the cost of one mask entry
per soft-masked base.

### Bit order within a byte

**Big-endian within byte** — first base in the input occupies the
two highest-order bits.

```
input "ACGT"  →  packed = 0b00_01_10_11 = 0x1B
input "TGCA"  →  packed = 0b11_10_01_00 = 0xE4
input "AC"    →  packed = 0b00_01_00_00 = 0x10  (low 4 bits = padding zeros)
```

The padding bits in the final byte (when `len(input) % 4 != 0`) are
unused and **must** be written as zero. The decoder ignores them
(it knows the original length from the header).

### Decode

1. Read header, allocate output of size `original_length`.
2. Unpack body bytes left-to-right: for each byte, extract the
   four 2-bit slots high-to-low and write `"ACGT"[slot]` to the
   next four output positions. Stop after `original_length` slots
   are emitted (the last byte may be partial).
3. Walk mask in order: for each `(position, byte)` entry, overwrite
   `output[position]` with `byte`.

The mask MUST be sorted ascending by position; the decoder rejects
unsorted or duplicate-position masks.

### Edge cases

- Empty input → header only (13 bytes), `packed_length = 0`,
  `mask_count = 0`.
- All non-ACGT (e.g., 1 MB of `N`) → packed body is full of
  placeholder zeros, mask carries every position. Total wire size
  ≈ ⌈orig/4⌉ + 5·orig + 13. (Worse than the input — but lossless;
  the codec is meant for ACGT-dominant data.)
- All-ACGT (no mask entries) → `mask_count = 0`, mask section is
  zero bytes. Total wire size = 13 + ⌈orig/4⌉.

---

## 2. Wire Format (cross-language contract)

Big-endian throughout. Self-contained — the decoder needs no
external metadata. The first byte is a version tag, currently
always `0x00` — future BASE_PACK variants (e.g., a 4-bit IUPAC
mode, a different mask layout) would bump this and let old decoders
reject new streams cleanly.

```
Offset      Size  Field
──────      ────  ───────────────────────────────────────────
0           1     version            (0x00)
1           4     original_length    (uint32 BE — input byte count)
5           4     packed_length      (uint32 BE — = ceil(original_length / 4))
9           4     mask_count         (uint32 BE — number of mask entries)
13          var   packed_body        (packed_length bytes)
13+pl       var   mask               (mask_count × 5 bytes:
                                       uint32 BE position, uint8 original_byte)
```

Total length = `13 + packed_length + 5 * mask_count` bytes.

Invariant: `packed_length == (original_length + 3) // 4`. The
decoder MUST validate this and reject mismatched streams.

Invariant: every position in the mask is in
`[0, original_length)` and positions are strictly ascending. The
decoder MUST reject a stream that violates either condition.

---

## 3. Binding Decisions (continued from M83 §75–§79)

| #  | Decision                                                                                                                             | Rationale |
|----|--------------------------------------------------------------------------------------------------------------------------------------|-----------|
| 80 | Sidecar mask layout is **sparse position+byte pairs**, not a dense bitmap.                                                          | Real genomic data has <1% non-ACGT; sparse list dominates bitmap on size and is simpler to round-trip. Bitmap would only win at >40% non-ACGT density, which never occurs on real reads. |
| 81 | **Case-sensitive packing**: only uppercase `A`/`C`/`G`/`T` get packed; lowercase `a`/`c`/`g`/`t` go to the mask.                    | Preserves soft-masking convention used by many genomic pipelines. Round-trip lossless on input that distinguishes case. The cost (one mask entry per soft-masked base) is acceptable. |
| 82 | **Big-endian bit packing within byte**: first input base occupies the two highest-order bits.                                       | Matches reading convention (left-to-right hex dumps of genomic data show first base on the left). Matches CRAM's external-data block convention. |
| 83 | **Padding bits in the final body byte are zero.** Decoder uses `original_length` to know how many slots to consume; padding ignored. | Deterministic encoder output (all three languages emit byte-identical streams) without needing to record the padding count. |
| 84 | **Mask entries sorted ascending by position.** Encoder MUST emit sorted; decoder validates (rejects unsorted).                       | Cross-language byte-exact fixture conformance. Decoder validation also catches malformed/truncated streams cheaply. |
| 85 | **First byte is `version = 0x00`**, not the M79 codec id (`0x06`).                                                                  | The codec id is external dispatch context (lives in the dataset's `@compression` attribute when M86 wires this in). Version is internal to the codec format, lets future BASE_PACK variants ship without a new codec id. |

---

## 4. Python Implementation

### 4.1 `python/src/ttio/codecs/base_pack.py` (new file)

Public API — mirrors the rANS module shape:

```python
def encode(data: bytes) -> bytes:
    """Encode `data` using BASE_PACK + sidecar mask.

    Returns a self-contained byte string per the wire format
    in HANDOFF.md §2. Pure ACGT input compresses to ~25% of
    original size; non-ACGT bytes round-trip via the mask.
    """

def decode(encoded: bytes) -> bytes:
    """Decode a stream produced by encode().

    Reads the header, unpacks the 2-bit body, applies the
    sidecar mask. Raises ValueError on malformed input
    (bad version, wrong packed_length, out-of-range or
    unsorted mask positions, truncated stream).
    """
```

Implementation notes:

- Pack loop: iterate input in chunks of 4 bytes; emit one body
  byte per chunk via `(slot0 << 6) | (slot1 << 4) | (slot2 << 2)
  | slot3`.
- Mask collection: build a list of `(i, b)` pairs as you scan; the
  natural left-to-right scan emits them already sorted.
- Header serialisation: use `struct.pack(">BIII", 0, orig_len,
  packed_len, mask_count)` — 13 bytes exactly.
- Mask serialisation: `b"".join(struct.pack(">IB", p, b) for p, b
  in mask)` — 5 bytes per entry.
- Decode: validate `version == 0`, `packed_length == (orig + 3) //
  4`, total length matches `13 + packed_length + 5 * mask_count`.
  Walk the mask once and verify monotonicity and `0 <= position <
  orig_len`.

### 4.2 Module re-exports

In `python/src/ttio/codecs/__init__.py`, add the public names to
the existing module:

```python
from .base_pack import encode as base_pack_encode, decode as base_pack_decode
```

Update the docstring to remove `(M84, future)` from the
`base_pack` line.

### 4.3 `python/tests/test_m84_base_pack.py` (new file)

14 pytest cases. Use `os.urandom` only for the realistic mixed
test; the canonical vectors are deterministic.

---

## 5. Objective-C Implementation

### 5.1 `objc/Source/Codecs/TTIOBasePack.h` (new file)

```objc
/**
 * BASE_PACK genomic-sequence codec — 2-bit ACGT + sidecar mask.
 *
 * Clean-room implementation. No htslib / CRAM tools-Java / jbzip
 * source consulted. Wire format matches the Python reference
 * implementation byte-for-byte; see docs/codecs/base_pack.md
 * (M84) for the format specification.
 *
 * Cross-language equivalents:
 *   Python: ttio.codecs.base_pack
 *   Java:   global.thalion.ttio.codecs.BasePack
 */

NSData * _Nonnull TTIOBasePackEncode(NSData * _Nonnull data);

NSData * _Nullable TTIOBasePackDecode(NSData * _Nonnull encoded,
                                      NSError * _Nullable * _Nullable error);
```

### 5.2 `objc/Source/Codecs/TTIOBasePack.m` (new file)

C core wrapped by ObjC entry points. Use a single-pass encoder
that appends to two `NSMutableData` buffers (one for body, one for
mask) then concatenates them after the header. Or build directly
into one buffer — body length is known up front (`(orig + 3) /
4`), mask length depends on input.

Performance target: encode ≥ 200 MB/s, decode ≥ 500 MB/s on a
single core. BASE_PACK is dominated by a tight shift-and-mask
loop; this is much faster than rANS.

### 5.3 `objc/Source/GNUmakefile`

Add `Codecs/TTIOBasePack.h` to `libTTIO_HEADER_FILES`,
`Codecs/TTIOBasePack.m` to `libTTIO_OBJC_FILES`. Same pattern as
the M83 entry already in place for `Codecs/TTIORans.{h,m}`.

### 5.4 `objc/Tests/TestM84BasePack.m` (new file)

Style mirrors `TestM83Rans.m` — inline `PASS()` macros, static
helpers, no wrapper class, no `@try`/`@catch`. Target ≥ 30 new
assertions across 13–14 test cases.

### 5.5 `objc/Tests/Fixtures/`

Copy the Python-generated canonical fixtures verbatim:
`base_pack_a.bin`, `base_pack_b.bin`, `base_pack_c.bin`,
`base_pack_d.bin`. These are the cross-language byte-exact
contract.

### 5.6 `objc/Tests/GNUmakefile` and `objc/Tests/TTIOTestRunner.m`

Add `TestM84BasePack.m` to `TTIOTests_OBJC_FILES`. Add `extern
void testM84BasePack(void);` declaration in the runner and a
`START_SET("M84: BASE_PACK codec") testM84BasePack();
END_SET("M84: BASE_PACK codec")` block in `main`.

---

## 6. Java Implementation

### 6.1 `java/src/main/java/global/thalion/ttio/codecs/BasePack.java` (new file)

```java
package global.thalion.ttio.codecs;

/**
 * BASE_PACK codec — 2-bit ACGT packing + sidecar mask.
 *
 * Clean-room implementation matching the Python reference
 * (python/src/ttio/codecs/base_pack.py) byte-for-byte.
 */
public final class BasePack {

    public static byte[] encode(byte[] data) { ... }

    public static byte[] decode(byte[] encoded) { ... }

    private BasePack() {} // utility class
}
```

Use `ByteBuffer` with `ByteOrder.BIG_ENDIAN` for header
serialisation. Use `Byte.toUnsignedInt(b)` whenever reading a byte
as a symbol value or position byte.

### 6.2 `java/src/test/resources/ttio/codecs/`

Copy the Python-generated fixtures: `base_pack_a.bin`,
`base_pack_b.bin`, `base_pack_c.bin`, `base_pack_d.bin`.

### 6.3 `java/src/test/java/global/thalion/ttio/codecs/BasePackTest.java`

JUnit 5. Same coverage as the ObjC suite. Target ≥ 12 test
methods, ≥ 40 assertions.

---

## 7. Canonical Test Vectors

Four vectors. All four serialised by Python, ObjC and Java must
produce byte-identical output to the committed fixtures.

### Vector A — pure ACGT, deterministic 256 bytes

```python
import hashlib
seed = hashlib.sha256(b"ttio-base-pack-vector-a").digest()  # 32 bytes
acgt = b"ACGT"
data_a = bytes(acgt[b & 0b11] for b in seed * 8)  # 256 bytes pure ACGT
```

Expected: `mask_count = 0`, `packed_length = 64`, total wire
length = 13 + 64 = 77 bytes.

### Vector B — realistic read-ish, 1024 bytes, ~1% non-ACGT

```python
import hashlib
seed = hashlib.sha256(b"ttio-base-pack-vector-b").digest()
acgt = b"ACGT"
data_b_chars = bytearray()
for i in range(1024):
    if i % 100 == 0:                      # N's at positions 0, 100, ..., 1000
        data_b_chars.append(ord('N'))
    else:
        # deterministic ACGT from seed
        bit_pair = (seed[i % 32] >> ((i // 32) % 4 * 2)) & 0b11
        data_b_chars.append(acgt[bit_pair])
data_b = bytes(data_b_chars)
```

Expected: `mask_count = 11` (positions 0, 100, …, 1000 — eleven
multiples of 100 in `[0, 1024)`), `packed_length = 256`, total =
13 + 256 + 55 = 324 bytes.

### Vector C — IUPAC + soft-mask stress, 64 bytes

Hand-constructed to exercise every meaningful non-ACGT case:

```python
data_c = (
    b"ACGT"           # 0-3   plain ACGT (packed)
    b"acgt"           # 4-7   soft-mask (lowercase) — 4 mask entries
    b"NNNN"           # 8-11  all-N — 4 mask entries
    b"RYSW"           # 12-15 IUPAC ambiguity — 4 mask entries
    b"KMBD"           # 16-19 more IUPAC — 4 mask entries
    b"HVN-"           # 20-23 IUPAC + N + gap — 4 mask entries
    b"....AC..GT.."   # 24-35 gaps + ACGT (positions 28,29,32,33 packed;
                      #       positions 24-27, 30-31, 34-35 are 8 mask entries)
    b"ACGT" * 7       # 36-63 plain ACGT padding (28 bytes)
)
assert len(data_c) == 64
```

Expected: `mask_count = 28` (4 lowercase + 4 N + 4 IUPAC + 4 IUPAC
+ 4 mixed + 8 gap-region non-ACGT). `packed_length = 16`. Total
wire = 13 + 16 + 5×28 = 169 bytes.

### Vector D — empty input

```python
data_d = b""
```

Expected: header only, `packed_length = 0`, `mask_count = 0`,
`original_length = 0`. Total wire length = 13 bytes.

### Reference output generation

```bash
cd python && python3 -c "
import hashlib
from ttio.codecs.base_pack import encode, decode

seed_a = hashlib.sha256(b'ttio-base-pack-vector-a').digest()
acgt = b'ACGT'
data_a = bytes(acgt[b & 0b11] for b in seed_a * 8)

seed_b = hashlib.sha256(b'ttio-base-pack-vector-b').digest()
data_b_chars = bytearray()
for i in range(1024):
    if i % 100 == 0:
        data_b_chars.append(ord('N'))
    else:
        bit_pair = (seed_b[i % 32] >> ((i // 32) % 4 * 2)) & 0b11
        data_b_chars.append(acgt[bit_pair])
data_b = bytes(data_b_chars)

data_c = (b'ACGT' b'acgt' b'NNNN' b'RYSW' b'KMBD' b'HVN-'
          b'....AC..GT..' b'ACGT' b'ACGT')
assert len(data_c) == 64

data_d = b''

for name, data in [('a', data_a), ('b', data_b), ('c', data_c), ('d', data_d)]:
    enc = encode(data)
    assert decode(enc) == data, f'{name}: round-trip failed'
    open(f'tests/fixtures/codecs/base_pack_{name}.bin', 'wb').write(enc)
    print(f'{name}: {len(data)} -> {len(enc)} bytes')
"
```

Commit the four `.bin` fixtures.

---

## 8. Tests

### 8.1 Python — `python/tests/test_m84_base_pack.py`

All 14 use pytest:

1. **Round-trip pure ACGT.** Build 1 MB by tiling `b"ACGT" *
   262144`. Encode, decode, byte-exact; total wire size =
   13 + 262144 = 262157 bytes (no mask).
2. **Round-trip realistic.** 1 MB with N's at deterministic
   positions (every 100th byte). Byte-exact; mask_count =
   10 000.
3. **Round-trip all-N.** 1 MB of `N`. Byte-exact; mask_count =
   1 048 576; total wire size = 13 + 262144 + 5 * 1048576 =
   5 504 941 bytes.
4. **Round-trip empty.** `b""`. Byte-exact; total wire size = 13
   bytes.
5. **Round-trip single ACGT.** `b"A"`, `b"C"`, `b"G"`, `b"T"` —
   four sub-cases, each byte-exact, each total wire size = 14
   bytes (13 header + 1 body byte = 0x00, 0x40, 0x80, 0xC0
   respectively in the high two bits).
6. **Round-trip single N.** `b"N"`. Byte-exact; total wire size
   = 13 + 1 + 5 = 19 bytes.
7. **IUPAC stress.** Full alphabet `b"ACGTacgtNRYSWKMBDHV-."`
   (21 bytes). Byte-exact; mask_count = 17 (positions 4 through
   20 — everything except the leading `ACGT`).
8. **Canonical vector A.** Encode `data_a`, compare to
   `base_pack_a.bin`. Byte-exact.
9. **Canonical vector B.** Encode `data_b`, compare to
   `base_pack_b.bin`. Byte-exact.
10. **Canonical vector C.** Encode `data_c`, compare to
    `base_pack_c.bin`. Byte-exact.
11. **Canonical vector D.** Encode `data_d`, compare to
    `base_pack_d.bin`. Byte-exact (= 13 bytes).
12. **Decode malformed.** Five sub-cases, each
    `pytest.raises(ValueError)`:
    - Truncated stream (header only when mask_count > 0).
    - Bad version byte (`0x01`).
    - `packed_length` mismatch (write `packed_length = 999` over
      a real header).
    - Mask position out of range (`position >= original_length`).
    - Mask positions out of order (swap two entries' positions).
13. **Soft-masking round-trip.** `b"ACGTacgtACGT"`. Byte-exact;
    mask_count = 4 (positions 4, 5, 6, 7).
14. **Throughput.** Encode 10 MB of pure ACGT, log MB/s. PASS if
    encode ≥ 20 MB/s, decode ≥ 50 MB/s. Print actual.

### 8.2 ObjC — `objc/Tests/TestM84BasePack.m`

Same coverage. Register in `TTIOTestRunner.m` under `M84:
BASE_PACK codec`. Throughput target: encode ≥ 200 MB/s, decode ≥
500 MB/s (soft); hard floor encode ≥ 100 MB/s, decode ≥ 250 MB/s.
Target ≥ 30 new assertions.

### 8.3 Java — `java/src/test/java/global/thalion/ttio/codecs/BasePackTest.java`

JUnit 5. Same coverage. Throughput logged, no hard threshold (JIT
variance). Target ≥ 12 test methods, ≥ 40 assertions.

### 8.4 Cross-language byte-exact conformance

The four canonical fixtures are the contract. All three encoders
must produce byte-identical output for vectors A–D.

---

## 9. Integration Point (Forward Reference)

M84 does NOT wire BASE_PACK into the genomic signal-channel
pipeline — that's M86's scope (which also wires rANS slots 4 and
5). M84 delivers BASE_PACK as a standalone, tested,
cross-language-conformant primitive.

When M86 lands, a genomic dataset's `@compression == 6` will route
the raw bytes through `base_pack.decode()`. The current M82
storage (one ASCII byte per base in `signal_channels/sequences`)
becomes the `@compression == 0` (NONE) case; opting in to
BASE_PACK shrinks it ~4×.

---

## 10. Documentation

### 10.1 `docs/codecs/base_pack.md` (new)

Codec specification document, parallel structure to
`docs/codecs/rans.md`:

- Algorithm summary (2-bit pack + sparse mask)
- Pack mapping table (ACGT → 0/1/2/3)
- Bit-order-within-byte explanation with worked example
- Wire format diagram
- Sparse-mask vs dense-bitmap rationale (Binding Decision §80)
- Case-sensitivity and soft-masking note (Binding Decision §81)
- IP provenance statement
- Cross-language conformance contract
- Performance targets per language
- Public API in each of the three languages

### 10.2 `CHANGELOG.md`

Add M84 entry under `[Unreleased]`. Update the header to mention
M84. Format mirrors the M83 entry (Added — Verification — Notes).

### 10.3 `docs/format-spec.md` §10.4

Flip the **base-pack** row from "Reserved enum slot … NOT YET
IMPLEMENTED" to "Implemented in M84 …" with a pointer to
`docs/codecs/base_pack.md`. Update the trailing paragraph to note
that ids `4`, `5`, `6` now ship as standalone primitives; ids `7`
and `8` remain reserved.

### 10.4 `python/src/ttio/codecs/__init__.py`

Update the docstring listing to remove `(M84, future)` from
`base_pack`.

---

## 11. Gotchas (continued from M83 §82–§88)

89. **Position width = uint32.** A single mask position is uint32
    BE. Maximum supported `original_length` is 2^32 - 1 ≈ 4.3 GB
    per encoded sequence. Real genomic reads are kilobytes at
    most; this is comfortable. Document the limit, but don't add
    a length cap (let the natural overflow be caught by the `0 <=
    position < original_length` validation in decode).

90. **Soft-masking interaction with downstream callers.** Anyone
    calling `encode(read.upper())` will lose soft-masking. The
    codec doesn't case-fold; that's a binding decision (§81).
    When M86 wires this into the pipeline, the M86 docs must call
    out that BASE_PACK is case-sensitive — not the responsibility
    of M84 docs.

91. **Empty input vs all-non-ACGT input.** Both produce
    mask_count = 0 in the all-ACGT case but differ wildly in
    mask_count for all-non-ACGT. The decoder distinguishes them
    via the original_length field — don't confuse "no mask
    entries" with "empty input."

92. **Mask sortedness validation.** Decoder MUST reject unsorted
    or duplicate-position masks. This catches both corruption and
    encoder bugs. Add explicit tests for both error cases.

93. **Body length invariant.** `packed_length == (original_length
    + 3) // 4`. Decoder rejects mismatches. This catches
    truncated streams and stream-collision bugs early.

94. **Padding-bit determinism.** The final body byte's unused
    low-order bits MUST be zero. If they're non-zero (e.g., a
    buggy encoder leaves stack garbage), cross-language fixture
    comparison will fail. Tests must include a 1-base, 2-base,
    and 3-base input to exercise all three padding-tail patterns.
    (Test #5 above covers the 1-base case for each ACGT; a
    deliberate 2-base and 3-base sub-test should be added.)

95. **No MPGO remnants to clean.** M83 already audited the ObjC
    tree; nothing to do this milestone.

---

## Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `7b20ac9`).
- [ ] BASE_PACK round-trip: 1 MB pure ACGT, byte-exact, wire size
      = 13 + 262144 = 262157 bytes.
- [ ] BASE_PACK round-trip: 1 MB realistic (~1% N), byte-exact.
- [ ] BASE_PACK round-trip: empty, single byte, IUPAC stress, all
      pass byte-exact.
- [ ] Soft-masking round-trip preserves case.
- [ ] All four canonical vectors A/B/C/D produce expected fixture
      bytes.
- [ ] Decode malformed (5 cases) raises ValueError.
- [ ] Throughput logged (encode ≥ 20 MB/s, decode ≥ 50 MB/s).

### Objective-C
- [ ] All existing tests pass (zero regressions; 1981 baseline +
      ≥ 30 new = ≥ 2011, with 2 pre-existing M38 Thermo failures
      preserved).
- [ ] Round-trip 1 MB pure ACGT byte-exact.
- [ ] Round-trip 1 MB realistic byte-exact.
- [ ] All four canonical vectors A/B/C/D match Python fixtures
      byte-exact.
- [ ] Malformed input → NSError, no crash, all 5 sub-cases.
- [ ] Throughput: encode ≥ 100 MB/s hard floor (soft ≥ 200);
      decode ≥ 250 MB/s hard floor (soft ≥ 500).
- [ ] ≥ 30 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs 416/0/0/0
      baseline → ≥ 428/0/0/0 after M84).
- [ ] Round-trip 1 MB pure ACGT and 1 MB realistic byte-exact.
- [ ] All four canonical vectors match Python fixtures byte-exact.
- [ ] Malformed input → IllegalArgumentException, all 5
      sub-cases.
- [ ] ≥ 12 test methods, ≥ 40 assertions.

### Cross-Language
- [ ] Python, ObjC, and Java produce identical encoded bytes for
      vectors A, B, C, D.
- [ ] Fixture files committed under
      `python/tests/fixtures/codecs/base_pack_*.bin` and copied
      verbatim to `objc/Tests/Fixtures/` and
      `java/src/test/resources/ttio/codecs/`.
- [ ] `docs/codecs/base_pack.md` committed and complete.
- [ ] `CHANGELOG.md` M84 entry committed under `[Unreleased]`.
- [ ] `docs/format-spec.md` §10.4 base-pack row flipped to
      "implemented".
- [ ] `python/src/ttio/codecs/__init__.py` docstring updated.

---

## Out of Scope

- **CRAM 3.1 base codecs.** WORKPLAN's "Genomic codec milestone
  Phase 2" is a separate future milestone.
- **M85 codecs** (quality-binned, name-tokenized) are separate
  milestones.
- **M86 wiring** into the genomic signal-channel pipeline. M84
  delivers BASE_PACK as a primitive only.
- **Performance optimisation beyond the targets.** SIMD,
  vectorised packing tables, GPU offload — none of these are M84
  scope. The shift-and-mask reference implementation is fast
  enough for the M86 wiring to be useful.
