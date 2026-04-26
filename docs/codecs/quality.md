# TTI-O M85 Phase A — QUALITY_BINNED Codec

> **Status:** shipped (M85 Phase A, 2026-04-26). Reference
> implementation in Python, normative implementation in
> Objective-C, parity implementation in Java. All three produce
> byte-identical encoded streams for the four canonical
> conformance vectors.

This document specifies the QUALITY_BINNED codec used by TTI-O for
compressed genomic-quality channels. It defines the algorithm
(fixed Illumina-8 Phred quantisation + 4-bit-packed bin indices),
the wire format, the cross-language conformance contract, and the
per-language performance targets.

The codec ships as a standalone primitive in M85 Phase A. Wiring
into the genomic signal-channel pipeline (interpreting
`@compression == 7` on a `signal_channels/qualities` dataset to
call `quality.decode()` on the raw bytes) is a future M86 phase,
separate from M86 Phase A which already wired rANS and BASE_PACK.

---

## 1. Algorithm

QUALITY_BINNED reduces a stream of Phred quality scores to one of
8 bins via a fixed table, then packs the resulting bin indices
4-bits-per-index (two indices per output byte). Standalone size
win is ~50% (one input byte → half a body byte, plus 6-byte
header overhead). Lossy by construction: the decoder maps each bin
back to its bin centre, so quality information beyond bin
granularity is discarded.

### Pack mapping

Each input byte (Phred score in 0..255) maps to one of 8 bin
indices. The decoder maps each bin index back to a fixed bin
centre. **Round-trip is NOT byte-exact for arbitrary input** —
`decode(encode(x)) == bin_centre[bin_of[x]]`. For input bytes
that are already at a bin centre (0/5/15/22/27/32/37/40),
round-trip IS byte-exact; other Phred values round-trip to the
nearest bin centre.

### Bin table (Illumina-8 / CRUMBLE-derived)

| Bin | Phred range  | Centre | Notes                          |
|-----|--------------|--------|--------------------------------|
| 0   | 0..1         | 0      | "no information"               |
| 1   | 2..9         | 5      | low-confidence                 |
| 2   | 10..19       | 15     | standard low / older platforms |
| 3   | 20..24       | 22     | standard medium-low            |
| 4   | 25..29       | 27     | standard medium                |
| 5   | 30..34       | 32     | standard medium-high           |
| 6   | 35..39       | 37     | high                           |
| 7   | 40..255      | 40     | saturates here                 |

Phred values > 40 (e.g., PacBio HiFi Q60+, certain instrument
calibrations) clamp to bin 7 / centre 40. Documented behaviour;
future scheme_ids may extend the upper range, but v0 of scheme
0x00 saturates at Q40.

### Bit order within a byte

**Big-endian within byte** (Binding Decision §95). The first
input quality occupies the **high nibble** of its body byte; the
second occupies the low nibble. Worked examples:

| Input bytes (Phred) | Bin indices | Packed body  | Hex   |
|---------------------|-------------|--------------|-------|
| `0 5`               | `0 1`       | `0b 0000 0001` | 0x01  |
| `40 30`             | `7 5`       | `0b 0111 0101` | 0x75  |
| `0 0 5 5`           | `0 0 1 1`   | `0x00 0x11`  | —     |
| `40` (single byte)  | `7` + 0     | `0b 0111 0000` | 0x70  |
| `5` (single byte)   | `1` + 0     | `0b 0001 0000` | 0x10  |

When the input has odd length, the final body byte's low nibble
is zero padding (Binding Decision §96). The decoder uses
`original_length` to know how many indices to consume; the
padding bits are ignored.

### Decode

1. Read the 6-byte header. Validate `version == 0`,
   `scheme_id == 0`, total stream length == `6 + ceil(original_length / 2)`.
   Reject mismatches.
2. Allocate output of size `original_length`. Walk the body
   left-to-right: for each byte, extract `byte >> 4` as the bin
   index for output position `2*i`, and `byte & 0x0F` as the bin
   index for output position `2*i + 1`. Stop after
   `original_length` indices are emitted.
3. Map each bin index through the bin-centre table to produce
   the output Phred bytes.

---

## 2. Wire format

Big-endian throughout. Self-contained — the decoder needs no
external metadata.

```
Offset  Size  Field
──────  ────  ───────────────────────────────────────────
0       1     version            (0x00)
1       1     scheme_id          (0x00 = "illumina-8")
2       4     original_length    (uint32 BE)
6       var   packed_indices     (ceil(original_length / 2) bytes)
```

Total length = `6 + ceil(original_length / 2)` bytes.

Empty input → exactly 6 bytes (header only,
`original_length = 0`, body absent).

The first byte is the **version tag** (currently always `0x00`).
Future variants — for example, a 16-bin scheme using all four
bits per index, or a 4-bin scheme using 2-bit packing — would
introduce new scheme_ids under the same version (or bump the
version if the wire layout itself needs to change). Note that
the version byte is *internal* to the codec format; the M79
codec id (`7`) that identifies the codec to the dataset's
`@compression` attribute lives outside the QUALITY_BINNED stream.

### Invariants enforced by the decoder

The decoder MUST reject a stream that violates any of:

- Stream length < 6 (too short for the header).
- `version != 0x00`
- `scheme_id != 0x00`
- Total stream length `!= 6 + ceil(original_length / 2)`

Each rejection is a clean error (Python `ValueError`, ObjC
`NSError**` with `nil` return, Java `IllegalArgumentException`),
not a crash.

---

## 3. Design choices (Binding Decisions §91–§97)

### §91 — Single fixed bin scheme in v0

scheme_id `0x00` = "Illumina-8" with the bin ranges and centres
documented in §1.

**Rationale.** Simpler than a parameterised scheme. The wire
format reserves a full byte for `scheme_id` so up to 256 schemes
can be added later (NCBI 4-bin, Bonfield variable-width, etc.).
v0 ships exactly one to keep the milestone focused.

### §92 — Bin table is NOT included in the wire stream

The 8-bin table is implicit from the scheme_id — each language
hardcodes the table for scheme 0x00.

**Rationale.** Saves 16 bytes per stream and prevents accidental
encode/decode mismatches across implementations. Cross-language
fixture conformance proves the tables match.

### §93 — Phred values > 40 clamp to bin 7 (centre = 40)

**Rationale.** Most genomic data uses Phred 0–40. Q41+ is
uncommon (PacBio HiFi can produce Q60+ but those usually
pre-quantise on the instrument). Saturating at Q40 is a
documented lossy behaviour; future scheme_ids can extend the
upper range without breaking v0.

### §94 — 4-bit-packed indices, not 3-bit-packed

**Rationale.** 4-bit aligns to nibble boundaries — two indices
per byte, no bit-juggling across byte boundaries. 3-bit packing
would save another 25% of standalone size but require complex
bit math. The 4-bit choice trades that 25% for trivial pack /
unpack code; the M86 pipeline composes rANS afterwards which
recovers most of the difference. Worst case (uniform Phred
distribution): rANS-on-bin-indices brings the wire down further
toward the 3-bit-packed limit anyway.

### §95 — Big-endian bit packing within byte

First input quality occupies the high nibble.

**Rationale.** Matches BASE_PACK's bit-order convention
(Binding Decision §82) — left-to-right reading order maps to
high-to-low bits. Cross-codec consistency makes hex dumps less
surprising.

### §96 — Zero padding bits in final body byte

When input has odd length, the unused low nibble of the final
body byte is zero.

**Rationale.** Deterministic encoder output without recording
the padding state. The decoder uses `original_length` to know
how many indices to consume regardless of what the padding bits
contain. (The decoder treats nibbles 8..15 as bin index 0 / centre
0 silently — a defensive choice that the encoder never reaches
but documented for robustness.)

### §97 — Lossy round-trip via bin centres

`decode(encode(x)) == bin_centre[bin_of[x]]`, NOT `x`.

**Rationale.** Quality binning is fundamentally lossy. Tests
must use bin-centre inputs OR assert against the known lossy
mapping, not byte-exact round-trip on arbitrary input. The
"crumble-style" lossy compression is the point of the codec.

---

## 4. Cross-language conformance contract

The Python implementation in `python/src/ttio/codecs/quality.py`
is the spec of record. The four fixtures under
`python/tests/fixtures/codecs/` are the wire-level conformance
test vectors:

| Fixture           | Input                                                       | Wire size | Notes |
|-------------------|-------------------------------------------------------------|-----------|-------|
| `quality_a.bin`   | `bytes([0,5,15,22,27,32,37,40]) * 32`                       | 134 B     | 256 B pure bin centres; round-trip is byte-exact |
| `quality_b.bin`   | SHA-256("ttio-quality-vector-b") cycled into 1024 B Phred 15..40 profile | 518 B | Realistic Illumina shape (early reads at Q30..40, late reads at Q15..30) |
| `quality_c.bin`   | 64-byte literal covering every bin boundary + saturation    | 38 B      | Includes Phred 0,1,2,9,10,19,20,24,25,29,30,34,35,39,40,41,50,93,100,200,255 |
| `quality_d.bin`   | empty                                                       | 6 B       | Header only |

Each implementation:
- Loads the fixtures from a known location relative to its tests.
- Constructs the same input data deterministically and verifies
  encoder output is bytes-equal to the fixture (encoder
  conformance).
- Decodes the fixture and verifies the result equals the
  *expected lossy round-trip* (each input byte mapped through
  `bin_centre[bin_of[x]]`).

Implementations:
- Python — `python/tests/fixtures/codecs/`
- ObjC — `objc/Tests/Fixtures/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

### SHA-256 seed for vector B

```
seed = SHA-256("ttio-quality-vector-b")
     = 9d 5b ... [32 bytes]
```

Each implementation computes this hash itself (e.g., Python
`hashlib.sha256`, ObjC libgcrypt or embedded constant, Java
`MessageDigest.getInstance("SHA-256")`). The test suites verify
the hash matches before trusting the constructed input.

---

## 5. Performance

Per-language soft targets, measured single-core on a developer
laptop:

| Language | Encode (target) | Decode (target) | Notes |
|----------|-----------------|-----------------|-------|
| Python   | ≥ 50 MB/s       | ≥ 100 MB/s      | Pure Python; uses `bytes.translate` for the bin lookup |
| Objective-C / C | ≥ 300 MB/s | ≥ 500 MB/s | Hard floors: 150 / 250 MB/s |
| Java     | (logged, no threshold) | (logged) | JIT warm-up variance |

Measured on the M85 Phase A reference host:

| Language     | Encode      | Decode      |
|--------------|-------------|-------------|
| Python       | 61 MB/s     | 471 MB/s    |
| Objective-C  | 3203 MB/s   | 2196 MB/s   |
| Java         | 2001 MB/s   | 425 MB/s    |

QUALITY_BINNED is dominated by table lookups + byte-pair packing —
much simpler inner loop than rANS, and faster than BASE_PACK
because there's no mask-tracking overhead. The Python decode is
fast because it's a single `bytes.translate` over the unpacked
nibble stream; encode is slower because the bin-lookup happens
on each input byte separately.

---

## 6. API summary

### Python

```python
from ttio.codecs.quality import encode, decode

encoded = encode(phred_bytes)         # bytes → bytes (lossy, 50%)
recovered = decode(encoded)           # bytes → bytes (bin centres)
# decode(encode(x)) == bin_centre[bin_of[x]]  for each byte x
```

The `codecs` sub-package is internal — public users access it as
`from ttio.codecs.quality import encode, decode`. There is no
`scheme` parameter (v0 hardcodes scheme 0x00 = Illumina-8).

### Objective-C

```objc
#import "Codecs/TTIOQuality.h"

NSData *encoded = TTIOQualityEncode(phredData);
NSError *err = nil;
NSData *recovered = TTIOQualityDecode(encoded, &err);
```

`TTIOQualityDecode` returns `nil` and sets `*error` on malformed
input (header too short, bad version, bad scheme_id, length
mismatch). Never crashes on malformed input.

### Java

```java
import global.thalion.ttio.codecs.Quality;

byte[] encoded = Quality.encode(phredBytes);
byte[] recovered = Quality.decode(encoded);
```

`Quality.decode(byte[])` throws `IllegalArgumentException` on
malformed input. `Quality.encode(byte[])` throws
`IllegalArgumentException` on null input.

---

## 7. Wired into / forward references

- **M86 Phase D (deferred)** — wire QUALITY_BINNED into the
  genomic signal-channel write/read path for the `qualities`
  byte channel. A `signal_channels/qualities` dataset's
  `@compression == 7` will route the raw bytes through
  `quality.decode()`. The M86 wiring infrastructure (per-channel
  `signal_codec_overrides` dict, `@compression` attribute,
  lazy-decode cache) shipped in M86 Phase A; only the dispatch
  branch for codec id 7 needs to be added. Lifting it out of M86
  Phase A's scope and into a separate phase keeps each milestone
  bounded.
- **M85 Phase B (deferred)** — `name_tokenizer` codec (CRAM 3.1
  / Bonfield 2022 style read-name compression). Substantially
  larger than Phase A; warrants its own plan and milestone. M79
  slot 8 is reserved for it.
- **CRAM 3.1 codec set** (deferred to a future milestone) —
  rANS-Nx16 stripe variants, fqzcomp (a quality-specific
  arithmetic coder more sophisticated than QUALITY_BINNED + rANS
  composition), adaptive arithmetic. New M79-style enum slots
  required.

The `codecs/` sub-package layout established in M83 (rANS),
extended in M84 (BASE_PACK), and now in M85 Phase A
(QUALITY_BINNED) is the home for all genomic compression
primitives going forward.
