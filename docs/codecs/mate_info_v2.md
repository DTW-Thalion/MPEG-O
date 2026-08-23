# MATE_INLINE_V2 codec (codec id 13)

> **Status:** current / live. Default codec for the `mate_info`
> channel. Reference kernel in C (`native/src/mate_info_v2.{c,h}`);
> language wrappers in Python (ctypes — `mate_info_v2.py`), Java (JNI
> — `MateInfoV2.java`), and Objective-C (direct link —
> `TTIOMateInfoV2.{h,m}`). All three call the same C entry points
> (`ttio_mate_info_v2_encode` / `ttio_mate_info_v2_decode`), so the
> encoded byte stream is byte-identical regardless of which language
> wrote the file.

This document specifies the MATE_INLINE_V2 codec used by TTI-O for the
genomic `mate_info` channel. It encodes the full per-record mate
triple — mate chromosome id, mate position, and template length — as a
single CRAM-style inline blob that exploits SAM mate-pair invariants
(a mate is usually on the same chromosome, near the read's own
position). It replaces the M82 compound + per-field subgroup
decomposition of the v1 `mate_info` layout.

The codec is **context-aware**: both encode and decode require the
record's own chromosome id and own position (from
`genomic_index/chromosome_ids` and `genomic_index/positions`) as side
input. The blob itself does not store own-read coordinates.

---

## 1. Algorithm

For each of the `N` records the encoder is given five parallel arrays:

| Input              | dtype    | Meaning                                          |
|--------------------|----------|--------------------------------------------------|
| `mate_chrom_ids`   | int32    | mate chromosome id; `-1` for `RNEXT='*'` (no mate) |
| `mate_positions`   | int64    | 0-based mate position (`PNEXT`)                  |
| `template_lengths` | int32    | signed template length (`TLEN`)                  |
| `own_chrom_ids`    | uint16   | own chromosome id; `0xFFFF` is the sentinel for `-1` (unmapped) |
| `own_positions`    | int64    | own 0-based position                             |

`mate_chrom_ids < -1` is rejected (`TTIO_RANS_ERR_PARAM`); the Python
wrapper pre-validates this in `_check_input_validity`.

### 1.1 MF taxonomy

Every record is classified into a 2-bit **mate-flag (MF)** by
`miv2_classify_mf`, comparing the mate chrom against the own chrom
(where `own = -1` if `own_chrom_id == 0xFFFF`):

| MF value | Name             | Condition                              |
|---------:|------------------|----------------------------------------|
| `0`      | `SAME_CHROM`     | `mate_chrom_id == own`                  |
| `1`      | `CROSS_CHROM`    | `mate_chrom_id != own` and `!= -1`      |
| `2`      | `NO_MATE`        | `mate_chrom_id == -1`                   |
| `3`      | `RESERVED`       | never emitted; rejected on decode (`TTIO_RANS_ERR_RESERVED_MF`) |

### 1.2 Substreams

The MF classification drives what each record contributes to four
substreams:

- **MF** — the 2-bit mate-flag for every record.
- **NS** (chrom substream) — one `varint(mate_chrom_id)` **only for
  `CROSS_CHROM` records**. `SAME_CHROM` and `NO_MATE` contribute
  nothing (their chrom is recovered from own / set to `-1`).
- **NP** (position substream) — one `zigzag-varint` value **per
  record**: for `SAME_CHROM`, the delta `mate_position - own_position`;
  otherwise the absolute `mate_position`.
- **TS** (template-length substream) — one `zigzag-varint(template_length)`
  **per record**.

Encoding primitives:

- **varint** — unsigned LEB128, little-endian base-128, 7 payload bits
  per byte with the high bit as continuation (`miv2_varint_encode`).
- **zigzag** — 64-bit zigzag mapping `(v << 1) ^ (v >> 63)` so
  small-magnitude signed values stay small unsigned
  (`miv2_zigzag_encode_64`).

### 1.3 Per-substream entropy coding

- **MF** is auto-picked between two representations, smaller wins:
  - **raw-pack** (`0x00`): 2 bits/record, 4 records/byte, LSB-first
    (`miv2_encode_mf_raw_pack`). Size `(N+3)/4` bytes.
  - **rANS-O0** (`0x01`): `ttio_rans_o0_encode` over the 1-byte-per-record
    MF array.
  The selected representation is prefixed with a 1-byte selector
  (`0x00` raw-pack / `0x01` rANS-O0) inside the MF substream.
- **NS / NP / TS** are each rANS order-0 encoded
  (`ttio_rans_o0_encode`) over their concatenated varint bytes. A
  substream with zero bytes (e.g. NS when there are no `CROSS_CHROM`
  records) is omitted entirely (length 0).

### 1.4 Decode

Decode reads own_chrom_ids / own_positions / n_records as side input,
decodes the four substreams, then walks all records in order:

- `mate_chrom_id`: `-1` for `NO_MATE`; `own` for `SAME_CHROM`; next
  `varint` from NS for `CROSS_CHROM`.
- `mate_position`: `own_position + zigzag_delta` for `SAME_CHROM`;
  absolute `zigzag` value otherwise (NP, one per record).
- `template_length`: `zigzag` value from TS, one per record.

Two integrity checks are enforced on decode: any MF slot equal to `3`
(`RESERVED`) → `TTIO_RANS_ERR_RESERVED_MF`; and an **NS length
conservation check** — the number of NS varints consumed must equal
`num_cross` and exactly exhaust the NS buffer, else
`TTIO_RANS_ERR_NS_LENGTH_MISMATCH`.

---

## 2. Wire format (codec id 13)

All multi-byte integers little-endian. Magic `MIv2`, version `0x01`.

### 2.1 Container header — fixed 34 bytes

| Offset | Size | Field            | Value / meaning                          |
|-------:|-----:|------------------|------------------------------------------|
| 0      | 4    | magic            | `"MIv2"` (`0x4D 0x49 0x76 0x32`)          |
| 4      | 1    | version          | `0x01`                                   |
| 5      | 1    | flags / reserved | `0x00`                                   |
| 6      | 8    | n_records        | uint64 LE                                |
| 14     | 4    | num_cross        | uint32 LE — count of `CROSS_CHROM` records |
| 18     | 4    | mf_len           | uint32 LE — MF substream byte length (incl. 1-byte selector) |
| 22     | 4    | ns_len           | uint32 LE — NS substream byte length     |
| 26     | 4    | np_len           | uint32 LE — NP substream byte length     |
| 30     | 4    | ts_len           | uint32 LE — TS substream byte length     |

### 2.2 Body

Immediately after the 34-byte header, the four substreams are
concatenated in order, each spanning the length declared in the header:

```
[MF substream]  mf_len bytes
    byte 0      : selector  0x00 = raw-pack, 0x01 = rANS-O0
    bytes 1..   : raw-packed 2-bit MF, or rANS-O0-encoded MF bytes
[NS substream]  ns_len bytes : rANS-O0(varint(mate_chrom_id) ...)   (omitted if 0)
[NP substream]  np_len bytes : rANS-O0(zigzag-varint position ...)  (omitted if 0)
[TS substream]  ts_len bytes : rANS-O0(zigzag-varint tlen ...)      (omitted if 0)
```

There is no trailer. The total blob size is
`34 + mf_len + ns_len + np_len + ts_len`.

A reader rejects: any blob shorter than 34 bytes
(`TTIO_RANS_ERR_CORRUPT`); magic other than `MIv2`; `version != 0x01`;
a non-zero flags byte; `n_records` in the header not matching the
caller's `n_records` (`TTIO_RANS_ERR_PARAM`); and a declared substream
span exceeding `encoded_size` (`TTIO_RANS_ERR_CORRUPT`).

The rANS-O0 sub-blocks carry their own framing (order byte, original
length, payload length, 256-entry frequency table, final state) per
`ttio_rans_o0_encode` — `M=4096`, `L=2^23`, byte renormalisation, 64-bit
state. See `native/include/ttio_rans.h`.

> **Note on the on-disk schema (§10.9b).** The blob above is stored as
> `signal_channels/mate_info/inline_v2` (uint8 1-D dataset,
> `@compression = 13`). A sibling `chrom_names` compound dataset maps
> chrom ids to chromosome names and is required because mate
> chromosomes can reference chroms that no own-read uses. The
> `chrom_names` sidecar is **not** part of the codec blob and is not
> produced by `ttio_mate_info_v2_encode`. See `docs/format-spec.md`
> §10.9b for the container schema.

---

## 3. Native-lib requirement and fallback

The codec is implemented only in native C — there is no pure-Python
path. The Python wrappers reuse the `libttio_rans.so` loader from
`fqzcomp_nx16_z.py` (env var `TTIO_RANS_LIB_PATH`). `HAVE_NATIVE_LIB`
is `True` iff the library loaded.

- When the native lib is **absent**, `mate_info_v2.encode` /
  `.decode` raise `RuntimeError`. The **writer** does not fail: it
  falls back to the v1 M82 compound `mate_info` layout (per the module
  docstring and §10.9).
- The `opt_disable_inline_mate_info_v2 = True` writer option also
  forces the v1 layout even when the native lib is present (see
  §10.9b.3 / §10.9b.4).

### Capacity / constants

- `ttio_mate_info_v2_max_encoded_size(n)` returns the encode buffer
  capacity: `34 + n*(1+10+10+10) + 4*1040` (header + worst-case raw
  bytes per substream + per-stream rANS-O0 overhead).
- Sentinel: `own_chrom_id == 0xFFFF` (`MIV2_OWN_UNMAPPED`) decodes as
  own chrom `-1`.
- Error codes (`native/include/ttio_rans.h`): `-1` PARAM, `-2` ALLOC,
  `-3` CORRUPT, `-4` RESERVED_MF, `-5` NS_LENGTH_MISMATCH. The Python
  wrapper maps these to messages in `_ERR_MESSAGES`.

---

## 4. Public API

### Python

```python
from ttio.codecs import mate_info_v2

blob = mate_info_v2.encode(
    mate_chrom_ids, mate_positions, template_lengths,  # mate triple
    own_chrom_ids, own_positions,                      # side context
)
mc, mp, tl = mate_info_v2.decode(blob, own_chrom_ids, own_positions, n_records)
```

All arrays are 1-D and same length; dtypes are coerced via
`np.ascontiguousarray` (int32 / int64 / int32 / uint16 / int64).
`mate_info_v2.HAVE_NATIVE_LIB` reports native availability.

### Java

```java
import global.thalion.ttio.codecs.MateInfoV2;

byte[] blob = MateInfoV2.encode(
    mateChromIds, matePositions, templateLengths, ownChromIds, ownPositions);
MateInfoV2.Triple t = MateInfoV2.decode(blob, ownChromIds, ownPositions, nRecords);
// t exposes mateChromIds / matePositions / templateLengths
```

`MateInfoV2.isAvailable()` reports native availability; delegates to
`TtioRansNative.encodeMateInfoV2` / `decodeMateInfoV2` (JNI).

### Objective-C

```objc
#import "Codecs/TTIOMateInfoV2.h"

NSData *blob = [TTIOMateInfoV2 encodeMateChromIds:mateChromIds ...];
NSError *err = nil;
BOOL ok = [TTIOMateInfoV2 decodeData:blob ...];
```

`+[TTIOMateInfoV2 nativeAvailable]` reports availability. Direct-links
to `libttio_rans` (per `feedback_libttio_rans_api_layers`).

### C

```c
#include "ttio_rans.h"

size_t cap = ttio_mate_info_v2_max_encoded_size(n);
uint8_t *out = malloc(cap);
size_t out_len = cap;
ttio_mate_info_v2_encode(mate_chrom_ids, mate_positions, template_lengths,
                         own_chrom_ids, own_positions, n, out, &out_len);

ttio_mate_info_v2_decode(out, out_len, own_chrom_ids, own_positions, n,
                         out_mate_chrom_ids, out_mate_positions,
                         out_template_lengths);
```

---

## 5. Channel routing

The codec registry entry (`python/src/ttio/codecs/_registry.py`,
`_MateInlineV2Codec`) is keyed on `Compression.MATE_INLINE_V2`
(`enums.py` — value `13`) with `is_context_aware = True`,
`needs_embedded_reference = False`. The decode/encode adapters require
`CodecContext.own_chrom_ids` / `own_positions` (and `n_records` for
decode); a missing field raises `ValueError`.

Decoding `inline_v2` requires `genomic_index/positions` and
`genomic_index/chromosome_ids` to be loaded first. The v1.7+
Python/Java/ObjC readers enforce this read order transparently.

---

## 6. Conformance / where implemented

| Layer        | Location |
|--------------|----------|
| C kernel     | `native/src/mate_info_v2.c`, `native/src/mate_info_v2.h` |
| C API decl   | `native/include/ttio_rans.h` (`ttio_mate_info_v2_*`) |
| Python       | `python/src/ttio/codecs/mate_info_v2.py`; registry `_registry.py` |
| Java         | `java/src/main/java/global/thalion/ttio/codecs/MateInfoV2.java` |
| Objective-C  | `objc/Source/Codecs/TTIOMateInfoV2.{h,m}` |
| CLIs         | `objc/Tools/TtioMateInfoV2Cli.m`, `java/.../tools/MateInfoV2Cli.java` |

Cross-language byte-exactness is verified by
`python/tests/integration/test_mate_info_v2_cross_language.py` (per
§10.9b.5). Unit/dispatch tests: `objc/Tests/TestMateInfoV2.m`,
`objc/Tests/TestMateInfoV2Dispatch.m`,
`java/.../codecs/MateInfoV2Test.java`,
`java/.../MateInfoV2DispatchTest.java`.

---

## 7. Out of scope / notes

- The encoder produces no NS substream when no record is
  `CROSS_CHROM`; the `chrom_names` sidecar (on-disk) is independent of
  the codec blob.
- Per-field `signal_codec_overrides[mate_info_chrom | mate_info_pos |
  mate_info_tlen]` (and the channel key `mate_info`) are rejected at
  write time unless `opt_disable_inline_mate_info_v2 = True` (§10.9b.4).
- No random access below whole-blob granularity — decode walks all
  records sequentially.

---

References:

  (starting point; where it disagrees with the code, the code wins).
- Format spec: `docs/format-spec.md` §10.9 / §10.9b (on-disk schema).
- rANS order-0 dependency: `native/include/ttio_rans.h`
  (`ttio_rans_o0_encode` / `_decode`).
- Sibling codecs: `docs/codecs/delta_rans.md`,
  `docs/codecs/name_tokenizer_v2.md`.
