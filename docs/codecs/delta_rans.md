# TTI-O M95 — DELTA_RANS_ORDER0 Codec

> **Status:** shipping in v1.2.0 (M95). Reference implementation in
> Python, normative implementation in Objective-C, parity
> implementation in Java. All three produce byte-identical encoded
> streams for the four canonical conformance vectors. Applies to
> sorted-ascending integer channels (primarily `positions`); codec id `11`.

This document specifies the DELTA_RANS_ORDER0 codec used by TTI-O for
lossless integer-channel compression starting with v1.2.0. It is a
delta + zigzag + varint + rANS order-0 wrapper designed for
sorted-ascending integer channels, built to the design spec at
`docs/superpowers/specs/2026-04-30-m95-delta-rans-design.md`.

M95 runs alongside M83 (`RANS_ORDER0`, codec id `4`) and M94.Z
(`FQZCOMP_NX16_Z`, codec id `12`); all three codecs coexist in the
codebase. The v1.5 default codec stack assigns DELTA_RANS_ORDER0 to
the `positions` channel and RANS_ORDER0 to other integer channels.

---

## 1. Algorithm

The encode pipeline transforms raw little-endian integer bytes into a
compact rANS order-0 encoded byte stream via four stages:

1. **Parse.** Interpret the input as a flat array of little-endian
   integers of `element_size` bytes (1, 4, or 8 bytes per element).
2. **Delta.** Compute successive differences: `d[i] = v[i] - v[i-1]`
   (with `v[-1] = 0`). For sorted-ascending input (e.g. genomic
   positions) the deltas are small non-negative integers.
3. **Zigzag.** Map signed deltas to unsigned integers via zigzag
   encoding: `z = (d << 1) ^ (d >> (bits-1))`. This keeps small
   magnitudes (positive or negative) as small unsigned values,
   which is important for non-monotonic input where deltas may be
   negative.
4. **Unsigned LEB128 varint.** Encode each zigzag-mapped unsigned
   integer as a variable-length byte sequence (7 payload bits per
   byte, high bit = continuation). Small values use 1 byte; large
   values expand as needed.
5. **rANS order-0.** Feed the concatenated varint byte stream to the
   existing M83 rANS order-0 encoder (`rans.encode(data, order=0)`),
   producing the final compressed body.

The decode pipeline reverses the stages: rANS order-0 decode, varint
parse, zigzag decode, cumulative sum, pack to little-endian integers.

### Edge cases

- **Empty input** (0 bytes): the codec emits only the 8-byte header
  with no body. The rANS encoder is not invoked.
- **Single element**: delta from implicit `v[-1] = 0` produces one
  delta equal to the element value; zigzag + varint + rANS proceeds
  normally.
- **Non-monotonic input**: fully supported. Negative deltas produce
  large zigzag values, which expand to multi-byte varints. The codec
  is correct but less efficient than on sorted-ascending input (the
  varint bytes have higher entropy, so rANS compresses less).

---

## 2. Wire format (codec id 11)

All multi-byte integers little-endian.

```
[Header, 8 bytes]
  magic           : 4 bytes  "DRA0" (0x44 0x52 0x41 0x30)
  version         : uint8    = 1
  element_size    : uint8    (1 = int8, 4 = int32, 8 = int64)
  reserved        : uint8[2] = 0x00 0x00

[Body]
  body            : rANS order-0 encoded varint byte stream
```

The header is a fixed 8 bytes. The body immediately follows and
extends to the end of the codec blob. There is no trailer.

A reader rejects any blob shorter than 8 bytes, any blob with magic
other than `DRA0`, any blob with `version != 1`, and any blob with
`element_size` not in `{1, 4, 8}`.

---

## 3. Cross-language conformance contract

The Python implementation in
`python/src/ttio/codecs/delta_rans.py` is the spec of record.
Four fixtures under `python/tests/fixtures/codecs/delta_rans_*.bin`
are the wire-level conformance test vectors; each is committed
verbatim into ObjC and Java fixture trees and the three decoded
outputs must match.

| Fixture            | Description                                                                 | Decoded size |
|--------------------|-----------------------------------------------------------------------------|-------------:|
| `delta_rans_a.bin` | 1000 sorted ascending int64 positions (LCG seed 0xBEEF, deltas 100-500)    |    8000 bytes |
| `delta_rans_b.bin` | 100 uint32 flags from 5 dominant values {0, 16, 83, 99, 163}               |     400 bytes |
| `delta_rans_c.bin` | Empty input (0 elements)                                                    |       0 bytes |
| `delta_rans_d.bin` | Single int64 element (1234567890)                                           |       8 bytes |

Each implementation:

- Loads the fixtures from a known location relative to its tests.
- Encodes the same input data and verifies bytes-equal to the fixture
  (encoder conformance).
- Decodes the fixture and verifies bytes-equal to the original input
  (decoder conformance).

Fixture locations:

- Python — `python/tests/fixtures/codecs/`
- Objective-C — `objc/Tests/Fixtures/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

Fixtures (c) and (d) are degenerate by design; (c) is the empty-input
edge case (header only, no rANS body) and (d) exercises the
single-element path.

---

## 4. Public API

### Python

```python
from ttio.codecs.delta_rans import encode, decode

encoded: bytes = encode(
    data=b"...",          # raw little-endian integer bytes
    element_size=8,       # 1, 4, or 8
)

decoded: bytes = decode(encoded)
```

`encode(data: bytes, element_size: int) -> bytes` — compresses raw LE
integer bytes via delta + zigzag + varint + rANS order-0.

`decode(encoded: bytes) -> bytes` — decompresses a DELTA_RANS_ORDER0
blob back to raw LE integer bytes.

### Objective-C

```objc
NSError *error = nil;

NSData *encoded = TTIODeltaRansEncode(data, elementSize, &error);
NSData *decoded = TTIODeltaRansDecode(encoded, &error);
```

`TTIODeltaRansEncode(NSData *data, uint8_t elementSize, NSError **)`
— returns the encoded blob or `nil` with error.

`TTIODeltaRansDecode(NSData *encoded, NSError **)` — returns the
decoded raw bytes or `nil` with error.

### Java

```java
byte[] encoded = DeltaRans.encode(data, elementSize);
byte[] decoded = DeltaRans.decode(encoded);
```

`DeltaRans.encode(byte[] data, int elementSize)` — returns the
encoded blob. Throws on invalid input.

`DeltaRans.decode(byte[] encoded)` — returns the decoded raw bytes.
Throws on invalid or corrupt input.

---

## 5. Auto-default channel assignments (v1.5)

When a `WrittenGenomicRun` meets v1.5 candidacy, the following
integer-channel codec defaults apply:

| Channel            | Default codec       | Id  |
|--------------------|---------------------|-----|
| positions          | DELTA_RANS_ORDER0   | 11  |
| flags              | RANS_ORDER0         | 4   |
| mapping_qualities  | RANS_ORDER0         | 4   |
| template_lengths   | RANS_ORDER0         | 4   |
| mate_info_pos      | RANS_ORDER0         | 4   |
| mate_info_tlen     | RANS_ORDER0         | 4   |
| mate_info_chrom    | NAME_TOKENIZED      | 8   |

`positions` is the only channel that gets DELTA_RANS_ORDER0 by
default. Other integer channels use RANS_ORDER0 because their values
are not sorted-ascending (e.g. `mate_info_pos` is non-monotonic, so
delta encoding would produce high-entropy deltas and compress poorly).
`mate_info_chrom` is string-valued and uses NAME_TOKENIZED.

---

## 6. Binding decisions

The decisions below extend the M94.Z series (§90a-§90e) and are
numbered §95a-§95c to keep the codec-spec section sequence contiguous.

| #     | Decision                                                                                                                                                                              | Rationale                                                                                                                                                                                |
|-------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| §95a  | DELTA_RANS_ORDER0 uses **delta + zigzag + unsigned LEB128 varint + rANS order-0** (not raw delta + rANS).                                                                              | Zigzag keeps small-magnitude signed deltas as small unsigned values. Varint concentrates entropy into fewer bytes for the rANS stage. Raw delta + rANS would waste rANS capacity on the high zero bytes of multi-byte integers. |
| §95b  | Integer-channel auto-defaults are **gated on v1.5 candidacy** (same gate as M94.Z).                                                                                                    | Preserves M82 byte-parity for files that do not opt into the v1.5 codec stack. The gate is the same condition used to select M94.Z on `qualities`.                                       |
| §95c  | `positions` gets DELTA_RANS_ORDER0 by default; **other integer channels get RANS_ORDER0**. `mate_info_pos` is non-monotonic, so delta is unhelpful.                                     | Only sorted-ascending channels benefit from delta encoding. Applying delta to non-monotonic channels (flags, mapping qualities, mate positions) increases entropy and hurts compression.    |

See `docs/superpowers/specs/2026-04-30-m95-delta-rans-design.md`
for the full design discussion.

---

## 7. Limitations

- **No Cython acceleration.** The codec wraps the existing M83 rANS
  order-0 path (which does have Cython acceleration). The
  delta/zigzag/varint stages are pure Python but are not the pipeline
  bottleneck — the rANS encode/decode dominates and is already
  Cython-accelerated.
- **Not the pipeline bottleneck.** Integer channels (positions, flags,
  etc.) are small relative to quality scores. The codec compute for
  DELTA_RANS_ORDER0 is a negligible fraction of the full-pipeline
  wall-clock.

---

References:

- Duda 2014, arXiv:1311.2540 — base rANS algorithm (M83 dependency).
- Google Protocol Buffers encoding spec — unsigned LEB128 varint
  format reference.
- Design spec:
  `docs/superpowers/specs/2026-04-30-m95-delta-rans-design.md`.
