# TTI-O M83 — rANS Entropy Codec

> **Status:** shipped (M83). Reference implementation in Python, normative
> implementation in Objective-C, parity implementation in Java. All three
> produce byte-identical encoded streams for the canonical conformance
> vectors and round-trip every input exactly.

This document specifies the rANS entropy codec used by TTI-O for
compressed genomic signal channels. It defines the algorithm, the
deterministic frequency-table normalisation, the wire format, the
cross-language conformance contract, and the per-language performance
targets.

The codec ships as a standalone primitive in M83. Wiring it into the
genomic signal-channel pipeline (replacing zlib on `signal_channels/*`
datasets when `@compression == 4` or `5`) is deferred to M86.

---

## 1. Algorithm summary

rANS — range Asymmetric Numeral Systems — is an entropy coder
introduced by Jarek Duda in 2014 ([arXiv:1311.2540][duda]). It
achieves compression rates close to arithmetic coding with throughput
close to Huffman coding. The TTI-O implementation supports two
context orders:

- **Order-0** — each symbol coded against its marginal frequency.
  Suited to data with one global symbol distribution (flag bytes,
  packed-base streams, length fields).
- **Order-1** — each symbol coded against its frequency conditioned
  on the previous symbol. Suited to locally-correlated data
  (Phred quality scores, delta-encoded positions, repetitive
  patterns).

[duda]: https://arxiv.org/abs/1311.2540

### IP provenance

All three implementations are clean-room ports from the Duda 2014
paper — a public-domain algorithm. **No htslib (or any third-party
codec library) source code was consulted.** Correctness is validated
by:

1. Round-trip property tests on random and pathological inputs.
2. Byte-exact match against an independent reference (Python encodes,
   ObjC and Java decode that exact byte stream and re-encode).
3. The six canonical conformance fixtures committed under
   `python/tests/fixtures/codecs/`.

### Core operations (order-0)

State `x` is a 64-bit unsigned integer constrained to the range
`[L, b·L)` where `L = 2²³` and `b = 2⁸ = 256` (so `[2²³, 2³¹)`).
Frequencies sum to a fixed total `M = 4096 = 2¹²`.

```
Encode symbol s with frequency f, cumulative-freq c, total M:
  # Renormalise BEFORE encoding so the result stays in range
  while x >= ((L >> 12) << 8) * f:
      output_byte(x & 0xFF)
      x >>= 8
  x = (x // f) * M + (x % f) + c

Decode (one symbol):
  slot = x & (M - 1)              # x % M, M is a power of two
  s = symbol_for_slot(slot)       # find s such that c[s] <= slot < c[s] + f[s]
  x = f[s] * (x >> 12) + slot - c[s]
  while x < L:
      x = (x << 8) | read_byte()
  emit s
```

The encoder runs symbols in **reverse order** (last input symbol
first) and emits output bytes in forward order. The decoder reads
bytes forward and recovers symbols in original order. The initial
state on encode is `x = L`. After the last symbol is encoded, the
final state is serialised as 4 big-endian bytes prepended to the
renormalisation stream, giving the decoder a known bootstrap value.

### Order-1 extension

Maintain 256 frequency tables, one per predecessor-symbol context.
The first symbol in the stream uses context `0x00` (the null-byte
context). Encode/decode uses the table indexed by the previous
symbol; everything else (state range, renormalisation, M) is
identical to order-0.

When building order-1 tables from input, count transitions
`tables[prev][data[i]]` where `prev = data[i-1] if i > 0 else 0`.
Normalise each non-empty row independently; serialise empty rows
as a 16-bit zero count.

---

## 2. Wire format

Big-endian throughout. Self-contained — no external metadata
needed for decode.

```
Offset  Size   Field
──────  ─────  ─────────────────────────────────────────
0       1      order            (0x00 or 0x01)
1       4      original_length  (uint32 BE — input byte count)
5       4      payload_length   (uint32 BE — encoded payload size)
9       var    frequency_table  (see below)
9+ft    var    payload          (rANS encoded byte stream)
```

Total stream length is exactly `9 + ft_length + payload_length`.

### Frequency table — order-0

256 entries × `uint32` BE = **1024 bytes** fixed. Entry `s` is the
frequency of symbol `s` in the normalised distribution. Frequencies
sum to `M = 4096`.

The fixed 1024-byte overhead is amortised over any non-trivial
input; it is not a problem for typical genomic signal channels
(megabytes per channel) but does dominate sub-kilobyte payloads.

### Frequency table — order-1

For each of the 256 contexts in order `0..255`:

```
uint16 BE   n_nonzero
n_nonzero × { uint8 symbol, uint16 BE freq }
```

Empty contexts (rows with no observed transitions) take exactly 2
bytes (the zero count). Densely-populated contexts take up to
`2 + 256·3 = 770` bytes. Typical genomic data tables compress to a
few KB.

### Payload

```
4 bytes    final_state    (uint32 BE — encoder's final x value)
remainder  renorm_bytes   (in emit order — decoder reads forward)
```

For empty input, the payload is exactly 4 bytes (the initial state
`L = 2²³ = 0x00800000`), so `payload_length = 4` and
`original_length = 0`.

---

## 3. Frequency normalisation (deterministic)

Cross-language byte-exact conformance hinges on this step producing
identical output across all three implementations for the same
input. The algorithm is fully specified — no ties may be broken by
language-defined ordering.

**Input:** 256-element non-negative count vector `cnt`, with
`sum(cnt) > 0`.
**Output:** 256-element `freq` vector with `sum(freq) == M = 4096`,
satisfying `freq[s] >= 1` if and only if `cnt[s] > 0`.

```
1. total = sum(cnt)
2. For each s in 0..255:
     if cnt[s] > 0:
         freq[s] = max(1, (cnt[s] * M) // total)    # integer division
     else:
         freq[s] = 0
3. delta = M - sum(freq)
4. If delta > 0:
     order = sort symbols where cnt[s] > 0 by:
              primary key   = -cnt[s]   (descending count)
              secondary key =  s         (ascending symbol value)
     i = 0
     while delta > 0:
         freq[order[i % len(order)]] += 1
         i += 1
         delta -= 1
5. If delta < 0:
     while delta < 0:
         order = sort symbols where freq[s] > 1 by:
                  primary key   =  cnt[s]    (ascending count)
                  secondary key =  s          (ascending symbol value)
         freq[order[0]] -= 1
         delta += 1
```

The "round-robin skipping pinned-to-1" rule in step 5 is critical:
no frequency may ever drop below 1 (otherwise the symbol becomes
unencodable), so the candidate set is recomputed each iteration.

### Order-1 tables

Each non-empty context row is normalised independently with the
same algorithm. The order-0 normalisation of the unconditional
marginal distribution is unrelated to the per-context order-1
tables.

---

## 4. Cross-language conformance contract

The Python implementation in `python/src/ttio/codecs/rans.py` is the
spec of record. The six fixtures under `python/tests/fixtures/codecs/`
are the wire-level conformance test vectors:

| Fixture            | Input                                        | Order | Notes |
|--------------------|----------------------------------------------|-------|-------|
| `rans_a_o0.bin`    | SHA-256("ttio-rans-test-vector-a") × 8       | 0     | 256 B uniform-ish |
| `rans_a_o1.bin`    | (same)                                       | 1     | |
| `rans_b_o0.bin`    | `bytes([0]*800 + [1]*100 + [2]*80 + [3]*44)` | 0     | 1024 B heavily skewed; payload < 300 B |
| `rans_b_o1.bin`    | (same)                                       | 1     | |
| `rans_c_o0.bin`    | `bytes([i % 4 for i in 0..511])`             | 0     | 512 B perfectly cyclic |
| `rans_c_o1.bin`    | (same)                                       | 1     | order-1 wire size strictly < order-0 |

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

## 5. Performance targets

Per-language soft targets, measured single-core on a developer
laptop:

| Language | Encode (order-0) | Decode (order-0) | Notes |
|----------|------------------|------------------|-------|
| Python   | ≥ 2 MB/s         | ≥ 5 MB/s         | Pure Python — Cython acceleration deferred |
| Objective-C / C | ≥ 50 MB/s | ≥ 200 MB/s | Hard floors: 25 / 100 MB/s |
| Java     | (logged, no threshold) | (logged, no threshold) | JIT warm-up variance |

Measured on the M83 reference host:

| Language | Encode | Decode |
|----------|--------|--------|
| Python   | 7.25 MB/s | 6.79 MB/s |
| Objective-C | 181.6 MB/s | 229.4 MB/s |
| Java     | 86.12 MB/s | 167.61 MB/s |

The ObjC and Java numbers are within the htslib rANS ballpark
without SIMD acceleration. The Python target is intentionally
relaxed; pure-Python rANS exists to anchor the reference, not to
serve as a production codec.

---

## 6. API summary

### Python

```python
from ttio.codecs.rans import encode, decode

encoded = encode(data, order=0)   # or order=1
recovered = decode(encoded)
assert recovered == data
```

The `codecs` sub-package is internal — it is not re-exported from
`ttio.__all__`. Public users access it as
`from ttio.codecs.rans import encode, decode`.

### Objective-C

```objc
#import "Codecs/TTIORans.h"

NSData *encoded = TTIORansEncode(data, 0);   // or 1
NSError *err = nil;
NSData *recovered = TTIORansDecode(encoded, &err);
```

`TTIORansDecode` returns `nil` and sets `*error` on malformed input
(short stream, invalid order byte, truncated payload, truncated
frequency table). It never crashes on malformed input.

### Java

```java
import global.thalion.ttio.codecs.Rans;

byte[] encoded = Rans.encode(data, 0);   // or 1
byte[] recovered = Rans.decode(encoded);
```

`Rans.decode(byte[])` throws `IllegalArgumentException` on malformed
input.

---

## 7. Wired into / forward references

- **M86 Phase A** (shipped) — rANS order-0 and order-1 are wired
  into the genomic signal-channel write/read path for the
  `sequences` and `qualities` byte channels. Use
  `WrittenGenomicRun.signal_codec_overrides={"sequences":
  Compression.RANS_ORDER0}` (or `RANS_ORDER1`) at write time; the
  reader dispatches on the per-dataset `@compression` attribute
  automatically. See `docs/format-spec.md` §10.5 for the on-disk
  attribute scheme.
- **M86 Phase B** (shipped 2026-04-26) — rANS order-0 and
  order-1 are also wired into the **integer channels**
  (`positions` int64, `flags` uint32, `mapping_qualities`
  uint8). Integer arrays are serialised to little-endian bytes
  per element before encoding; the reader looks up the
  channel's natural dtype by name. Integer channels accept
  ONLY rANS codecs (other codecs are wrong-content for
  integer fields). See `docs/format-spec.md` §10.7 for the
  int↔byte serialisation contract.
- **M86 Phase C** (shipped 2026-04-26) — rANS order-0 and
  order-1 are now also wired into the **cigars channel** (a
  list of CIGAR strings) via length-prefix-concat
  serialisation: each CIGAR is emitted as `varint(len) +
  bytes` and the concatenated stream is fed to rANS. **rANS is
  the recommended default for cigars on real WGS data**
  (mixed indels/clips break NAME_TOKENIZED's columnar mode
  back to verbatim/no-compression; rANS exploits byte-level
  repetition over the limited CIGAR alphabet for ~3-17×
  compression). NAME_TOKENIZED is the niche choice when
  CIGARs are known to be uniform (e.g. perfect-match-only
  synthetic data). See `docs/codecs/name_tokenizer.md` §8 for
  the full selection table, and `docs/format-spec.md` §10.8
  for the cigars schema-lift contract.
- **M86 Phase F** (shipped 2026-04-26) — rANS order-0 and
  order-1 are also wired into the per-field **mate_info**
  channels (`mate_info_chrom`, `mate_info_pos`,
  `mate_info_tlen`) under the new mate_info subgroup layout.
  The `mate_info_chrom` rANS path uses length-prefix-concat
  (same contract as cigars); `mate_info_pos` and
  `mate_info_tlen` use Phase B-style LE byte serialisation
  (`<i8` and `<i4` respectively). See
  `docs/format-spec.md` §10.9 for the mate_info subgroup
  pattern.
- **M84** (shipped) — base-pack codec (2-bit nucleotide packing
  + sidecar mask), see `docs/codecs/base_pack.md`.
- **M85** (shipped) — quality-quantiser
  (`docs/codecs/quality.md`) and read-name-tokeniser
  (`docs/codecs/name_tokenizer.md`) codecs in the same
  sub-package.

The `codecs/` sub-package layout (`python/src/ttio/codecs/`,
`objc/Source/Codecs/`, `java/src/main/java/global/thalion/ttio/codecs/`)
is the home for all genomic compression primitives going forward.
