# TTI-O M84 — BASE_PACK Codec

> **Status:** shipped (M84). Reference implementation in Python,
> normative implementation in Objective-C, parity implementation in
> Java. All three produce byte-identical encoded streams for the
> four canonical conformance vectors and round-trip every input
> exactly.

This document specifies the BASE_PACK codec used by TTI-O for
compressed genomic-sequence channels. It defines the algorithm,
the sparse sidecar mask layout, the wire format, the
cross-language conformance contract, and the per-language
performance targets.

The codec ships as a standalone primitive in M84. Wiring into the
genomic signal-channel pipeline (interpreting `@compression == 6`
on a `signal_channels/sequences` dataset to call
`base_pack.decode()` on the raw bytes) is deferred to M86.

---

## 1. Algorithm

BASE_PACK reduces canonical genomic-sequence storage by 4× — one
byte per base in the input becomes two bits per base in the body,
four bases packed per output byte. Bytes that are *not* canonical
ACGT (`N`, IUPAC ambiguity codes, soft-masking lowercase, gap
characters, anything else) round-trip losslessly through a sparse
sidecar mask that records each non-ACGT byte alongside its input
position.

### Pack mapping (case-sensitive)

| Input byte    | Code | Body slot |
|---------------|------|-----------|
| `'A'` (0x41)  | 0    | 0b00      |
| `'C'` (0x43)  | 1    | 0b01      |
| `'G'` (0x47)  | 2    | 0b10      |
| `'T'` (0x54)  | 3    | 0b11      |
| anything else | —    | mask entry; body slot gets placeholder 0b00 |

**Case is significant** (Binding Decision §81). Lowercase `a`, `c`,
`g`, `t` go through the mask. This is intentional: many genomic
pipelines use lowercase as *soft-masking* (e.g., to mark repeat
regions identified by RepeatMasker, dustmasker, etc.). A codec
that silently uppercased would destroy that signal. BASE_PACK
round-trips soft-masking for free at the cost of one mask entry
per soft-masked base.

### Bit order within a byte

**Big-endian within byte** (Binding Decision §82). The first input
base occupies the two highest-order bits of its body byte. Worked
examples:

| Input  | Packed body                         | Hex  |
|--------|-------------------------------------|------|
| `ACGT` | `0b 00 01 10 11`                    | 0x1B |
| `TGCA` | `0b 11 10 01 00`                    | 0xE4 |
| `AAAA` | `0b 00 00 00 00`                    | 0x00 |
| `TTTT` | `0b 11 11 11 11`                    | 0xFF |
| `AC`   | `0b 00 01 00 00` (low 4 = padding)  | 0x10 |
| `ACG`  | `0b 00 01 10 00` (low 2 = padding)  | 0x18 |
| `A`    | `0b 00 00 00 00` (low 6 = padding)  | 0x00 |

Padding bits in the final body byte (when `len(input) % 4 != 0`)
are unused and **must** be written as zero (Binding Decision §83).
The decoder uses `original_length` from the header to know how
many slots to consume — it ignores the padding regardless.

### Sidecar mask

A sorted list of `(position: uint32, original_byte: uint8)` pairs,
one entry per non-ACGT input byte. Position is the *input* index
(not the packed-body byte index). Mask entries are emitted in
strictly ascending position order (the natural left-to-right scan
emits them sorted; see Binding Decision §84). The decoder
validates sortedness and rejects unsorted or duplicate-position
masks.

### Decode

1. Read the 13-byte header. Validate `version == 0`,
   `packed_length == (original_length + 3) / 4`, and that the
   total stream length matches `13 + packed_length + 5 *
   mask_count`. Reject mismatches.
2. Allocate output of size `original_length`. Walk the body
   left-to-right: for each byte, extract the four 2-bit slots
   high-to-low and write `"ACGT"[slot]` to the next four output
   positions. Stop after `original_length` slots are emitted (the
   last byte may be partial).
3. Walk the mask in order. For each `(position, byte)` entry:
   verify `position < original_length` and that it is strictly
   greater than the previous entry's position; overwrite
   `output[position]` with `byte`.

### Edge cases

- **Empty input** → header only, total wire size = 13 bytes.
- **All-non-ACGT input** (e.g., 1 MiB of `N`) → packed body is
  full of placeholder zeros, mask carries every position. Total
  wire size ≈ ⌈orig/4⌉ + 5·orig + 13 — *worse* than the original
  by ~25%. BASE_PACK is meant for ACGT-dominant data; pure-N
  input is a worst-case scenario.
- **Pure ACGT input** (no mask entries) → `mask_count = 0`, mask
  section is zero bytes. Total wire size = 13 + ⌈orig/4⌉ ≈ 25%
  of original.
- **Soft-masked region** (e.g., `acgtacgt`) → 8 mask entries, each
  preserving the lowercase byte at its position.

---

## 2. Wire format

Big-endian throughout. Self-contained — the decoder needs no
external metadata.

```
Offset      Size  Field
──────      ────  ───────────────────────────────────────────
0           1     version            (0x00)
1           4     original_length    (uint32 BE)
5           4     packed_length      (uint32 BE; = ceil(original_length / 4))
9           4     mask_count         (uint32 BE)
13          var   packed_body        (packed_length bytes)
13+pl       var   mask               (mask_count × 5 bytes:
                                       uint32 BE position,
                                       uint8 original_byte)
```

Total length = `13 + packed_length + 5 * mask_count` bytes.

The first byte is a **version tag**, currently always `0x00`
(Binding Decision §85). Future BASE_PACK variants — for example a
4-bit IUPAC mode that packs the 16 IUPAC codes into 4-bit slots
without a mask, or a different mask layout — would bump this and
let old decoders reject new streams cleanly. Note that the version
byte is *internal* to the codec format; the M79 codec id (`6`)
that identifies the codec to the dataset's `@compression`
attribute lives outside the BASE_PACK stream.

### Invariants enforced by the decoder

The decoder MUST reject a stream that violates any of:

- `version != 0x00`
- `packed_length != (original_length + 3) / 4`
- Total stream length `!= 13 + packed_length + 5 * mask_count`
- Any mask `position >= original_length`
- Mask positions not in strictly ascending order

Each rejection is a clean error (Python `ValueError`, ObjC
`NSError**` with `nil` return, Java `IllegalArgumentException`),
not a crash.

---

## 3. Design choices (Binding Decisions §80–§85)

### §80 — Sparse mask, not dense bitmap

The mask is a sorted `(position, byte)` list, not a per-base
bitmap with a separate stream of original bytes for set bits.

**Rationale.** Real genomic data has <1% non-ACGT — typical
Illumina reads have N rates around 0.1–0.5%, soft-masked
references have <30% non-canonical even on heavily-masked
genomes. The crossover where dense bitmap beats sparse list on
total size is around 40% non-ACGT density, which never occurs on
real reads. A dense-bitmap implementation would also need an
extra stream of original bytes for the masked positions, so the
size win at low densities is moot.

### §81 — Case-sensitive packing

Only uppercase `A`/`C`/`G`/`T` get packed. Lowercase `a`/`c`/`g`/`t`
go to the mask.

**Rationale.** Soft-masking convention (lowercase = repeat or
low-complexity) is widely used by RepeatMasker, dustmasker, BWA
indexing, and many downstream tools. A codec that silently
uppercased would destroy that signal during a routine
write/read round-trip — an unacceptable lossy behaviour for a
codec advertised as lossless. The cost of preserving case (one
mask entry per soft-masked base, ≈ 5 bytes overhead per
soft-masked base) is a fair trade.

### §82 — Big-endian bit packing within byte

First input base occupies the two highest-order bits of its body
byte.

**Rationale.** Matches the convention CRAM uses for its
external-data block packing, matches reading convention (a
left-to-right hex dump shows the first base on the left), and is
the natural choice when the body byte is treated as a sequence
of nibbles rather than a little-endian integer.

### §83 — Zero padding bits in final body byte

When `len(input) % 4 != 0`, the unused low-order bits of the
final body byte are zero.

**Rationale.** Deterministic encoder output without needing to
record the padding count. The decoder uses `original_length` to
know how many slots to consume regardless of what the padding
bits contain.

### §84 — Mask sorted ascending by position; decoder validates

**Rationale.** Cross-language byte-exact fixture conformance
demands a canonical mask order. The natural left-to-right scan
emits sorted output for free. Decoder validation catches both
malformed/truncated streams and would-be encoder bugs cheaply
with a single comparison per entry.

### §85 — Version byte distinct from M79 codec id

Byte 0 of the stream is `version = 0x00`, *not* `0x06` (the M79
enum slot for BASE_PACK).

**Rationale.** The codec id is external dispatch context — it
lives in the dataset's `@compression` attribute when M86 wires
this in, and M86's read path uses it to dispatch to
`base_pack.decode()`. A version byte inside the stream is
internal to the codec format and lets future BASE_PACK variants
(see §2 note above) ship without exhausting M79 enum slots.

---

## 4. Cross-language conformance contract

The Python implementation in `python/src/ttio/codecs/base_pack.py`
is the spec of record. The four fixtures under
`python/tests/fixtures/codecs/base_pack_*.bin` are the wire-level
conformance test vectors:

| Fixture            | Input                                                        | Wire size | Notes |
|--------------------|--------------------------------------------------------------|-----------|-------|
| `base_pack_a.bin`  | SHA-256("ttio-base-pack-vector-a") mapped to ACGT, ×8        | 77 B      | 256 B pure ACGT, mask_count = 0 |
| `base_pack_b.bin`  | SHA-256("ttio-base-pack-vector-b") mapped to ACGT, N every 100th position | 324 B | 1024 B realistic, mask_count = 11 |
| `base_pack_c.bin`  | Hand-crafted IUPAC + soft-mask + gap stress vector           | 169 B     | 64 B, mask_count = 28 |
| `base_pack_d.bin`  | empty                                                        | 13 B      | header only |

Each implementation:
- Loads the fixtures from a known location relative to its tests.
- Encodes the same input data and verifies bytes-equal to the
  fixture (encoder conformance).
- Decodes the fixture and verifies bytes-equal to the original
  input (decoder conformance).

Implementations:
- Python — `python/tests/fixtures/codecs/`
- ObjC — `objc/Tests/Fixtures/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

---

## 5. Performance

Per-language soft targets, measured single-core on a developer
laptop:

| Language | Encode (target) | Decode (target) | Notes |
|----------|-----------------|-----------------|-------|
| Python   | ≥ 20 MB/s       | ≥ 50 MB/s       | Pure Python; uses `bytes.translate` for the body unpack hot path |
| Objective-C / C | ≥ 200 MB/s | ≥ 500 MB/s | Hard floors: 100 / 250 MB/s |
| Java     | (logged, no threshold) | (logged) | JIT warm-up variance |

Measured on the M84 reference host:

| Language | Encode | Decode |
|----------|--------|--------|
| Python   | 63 MB/s | 70 MB/s |
| Objective-C | 907 MB/s | 2093 MB/s |
| Java     | 110 MB/s | 232 MB/s |

The ObjC numbers are dominated by the inner shift-and-mask loop
plus the `memset` for the placeholder body bytes; they are
roughly 4–5× the rANS numbers because BASE_PACK doesn't carry the
arithmetic-coding state machinery. The Python numbers are
adequate for development-time round-trips and small-file work;
production-scale sequencing data should always go through the
ObjC or Java path (which is what M86 will do for HDF5-stored
genomic datasets regardless of caller language).

---

## 6. API summary

### Python

```python
from ttio.codecs.base_pack import encode, decode

encoded = encode(data)              # data: bytes
recovered = decode(encoded)
assert recovered == data
```

The `codecs` sub-package is internal — it is not re-exported from
`ttio.__all__`. Public users access it as
`from ttio.codecs.base_pack import encode, decode`. There is no
`order` parameter (BASE_PACK has no order variants).

### Objective-C

```objc
#import "Codecs/TTIOBasePack.h"

NSData *encoded = TTIOBasePackEncode(data);
NSError *err = nil;
NSData *recovered = TTIOBasePackDecode(encoded, &err);
```

`TTIOBasePackDecode` returns `nil` and sets `*error` on malformed
input (bad version, packed_length mismatch, mask out-of-range or
unsorted, truncated stream). It never crashes on malformed input.

### Java

```java
import global.thalion.ttio.codecs.BasePack;

byte[] encoded = BasePack.encode(data);
byte[] recovered = BasePack.decode(encoded);
```

`BasePack.decode(byte[])` throws `IllegalArgumentException` on
malformed input.

---

## 7. Forward references

- **M86** (deferred) — wire BASE_PACK into the genomic
  signal-channel write/read path. A `signal_channels/sequences`
  dataset's `@compression` attribute will hold `6` per the M79
  enum value; the read path will call `base_pack.decode()` on the
  raw dataset bytes. The current M82 storage (one ASCII byte per
  base) becomes the `@compression == 0` (NONE) case.
- **M85** (deferred) — `quality-binned` codec (M79 slot 7) for
  Phred-score quantisation, and `name-tokenized` codec (slot 8)
  for read-name prefix factoring. Same 3-language clean-room
  pattern.
- **CRAM 3.1 codec set** (deferred to a future milestone) —
  rANS-Nx16 stripe variants, fqzcomp, adaptive arithmetic. New
  M79-style enum slots required.

The `codecs/` sub-package layout established in M83 (rANS) and
extended in M84 (BASE_PACK) is the home for all genomic
compression primitives going forward.
