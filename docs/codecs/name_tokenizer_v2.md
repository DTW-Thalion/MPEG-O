# NAME_TOKENIZED v2 codec (codec id 15)

> **Status:** shipped v1.9, 2026-05-04. Reference implementation in C
> (`native/src/name_tok_v2.{c,h}`); language wrappers in Python
> (ctypes), Java (JNI), Objective-C (direct link). All three produce
> byte-identical encoded streams across the four canonical corpora
> (chr22, WES, HG002 Illumina, HG002 PacBio HiFi).

This document specifies the NAME_TOKENIZED v2 codec used by TTI-O for
the genomic `read_names` channel, the default in v1.9+. v1
NAME_TOKENIZED (codec id 8) remains supported for read-compat
indefinitely.

## 1. Algorithm

The codec splits a list of read names into independently-decodable
**blocks** of up to 4096 reads (matching the HDF5 chunk size for
`read_names`). Within each block:

- Each read is tokenised into numeric/string tokens using the
  v1-compatible tokeniser (two token types, leading-zero absorption,
  numeric-overflow demotion to string).
- A rolling **DUP-pool** of the last N=8 fully-decoded names is
  maintained. The pool resets at block start.
- Each read encodes via one of four strategies, selected by the
  encoder in priority order:
  1. **DUP** (FLAG=00): full byte-equal to a pool entry → emit the
     3-bit pool index.
  2. **MATCH-K** (FLAG=01): first K token columns match a pool entry,
     suffix differs → emit pool index + K + suffix tokens.
  3. **COL** (FLAG=10): full columnar tokens with shape compatible
     with the block's COL_TYPES → emit per-column delta-coded numerics
     and dictionary-coded strings.
  4. **VERB** (FLAG=11): verbatim length-prefixed bytes (fallback for
     heterogeneous shapes).

The encoder produces eight substreams per block (FLAG, POOL_IDX,
MATCH_K, COL_TYPES, NUM_DELTA, DICT_CODE, DICT_LIT, VERB_LIT). Each
substream is independently auto-picked between rANS-O0 (codec id 1)
and raw passthrough (codec id 0), smaller wins.

For full algorithm specification including per-strategy semantics,
column-type-table rules, and per-column delta state, see
`docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md` §3.

## 2. Wire format

Magic `NTK2`, container version `0x01`. See spec §4 for the
authoritative format. Summary:

```
Container:
  4 bytes "NTK2" + 1 byte version + 1 byte flags +
  4 bytes n_reads u32 LE + 2 bytes n_blocks u16 LE +
  n_blocks × 4 bytes block_offset[i] u32 LE

Block:
  4 bytes block_n_reads u32 LE + 4 bytes block_body_len u32 LE +
  body (8 substreams, each: 4 bytes len + 1 byte mode + body)
```

Modes: `0x00` raw passthrough, `0x01` rANS-O0 (uses
`ttio_rans_o0_encode/_decode`).

## 3. Compression on chr22

NAME_TOKENIZED v1 (M85 Phase B / M86 Phase E) achieves ~3-7:1 on
typical Illumina names. NAME_TOKENIZED v2 hits **~26.5:1** on chr22
(7.14 MB → 2.67 MB read_names channel). End-to-end file size drops
67.76 MB (-34.7%) when v2 is enabled vs the pre-v1.9 default (which
used M82 VL_STRING-in-compound for read_names, paying ~63 MB of
fractal-heap overhead in addition to the larger codec output).

See `docs/benchmarks/2026-05-04-name-tokenized-v2-results.md` for full
per-corpus numbers.

## 4. API

### Python

```python
from ttio.codecs import name_tokenizer_v2 as nt2
encoded = nt2.encode(["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1234"])
recovered = nt2.decode(encoded)
```

Requires `TTIO_RANS_LIB_PATH` to point at `libttio_rans.so`.
`nt2.HAVE_NATIVE_LIB` is True iff the native lib loaded.

### Java

```java
import global.thalion.ttio.codecs.NameTokenizerV2;
import java.util.List;

byte[] encoded = NameTokenizerV2.encode(List.of("EAS:1:1", "EAS:1:1"));
List<String> recovered = NameTokenizerV2.decode(encoded);
```

Requires `-Djava.library.path=...` at JVM startup with both
`libttio_rans.so` and `libttio_rans_jni.so` on the path.

### Objective-C

```objc
#import "Codecs/TTIONameTokenizerV2.h"

NSData *encoded = [TTIONameTokenizerV2 encodeNames:@[@"EAS:1:1"]];
NSError *err = nil;
NSArray<NSString *> *recovered = [TTIONameTokenizerV2 decodeData:encoded error:&err];
```

Direct-link to libttio_rans (per `feedback_libttio_rans_api_layers`).

### C

```c
#include "ttio_rans.h"

const char *names[] = {"EAS:1:1", "EAS:1:1"};
size_t cap = ttio_name_tok_v2_max_encoded_size(2, 16);
uint8_t *out = malloc(cap);
size_t out_len = cap;
ttio_name_tok_v2_encode(names, 2, out, &out_len);

char **recovered = NULL;
uint64_t n = 0;
ttio_name_tok_v2_decode(out, out_len, &recovered, &n);
/* caller frees recovered[i] for each i, then recovered itself */
```

## 5. Channel routing

In v1.9+, NAME_TOKENIZED v2 is automatically applied to the
`read_names` signal channel. Three writer paths:

| Caller setup | Layout |
|--------------|--------|
| Default (no override, no opt-out, native lib loaded) | codec id 15 |
| `signal_codec_overrides[read_names] = Compression.NAME_TOKENIZED` | codec id 8 (v1) |
| `opt_disable_name_tokenized_v2 = True` AND no override | M82 compound (pre-v1.9) |

Readers dispatch on `@compression` attribute on the dataset.

## 6. Out of scope

- Application to channels other than `read_names`. The `cigars`
  channel default stays RANS_ORDER1 per WORKPLAN; `mate_info_chrom` is
  obsolete after v1.7's mate_info v2.
- Bonfield 2022 / CRAM 3.1 byte-compatibility (separate "v3" cycle if
  pursued).
- UTF-8 / non-ASCII names. v2 inherits v1's 7-bit ASCII restriction.
- Sub-block random-access. The block_offsets index supports
  block-granularity seek; per-read random access requires decoding the
  containing block.

## 7. Forward references

- Spec: `docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md`
- Plan: `docs/superpowers/plans/2026-05-04-name-tokenized-v2.md`
- Format spec: `docs/format-spec.md` §10.6b
- v1 codec: `docs/codecs/name_tokenizer.md`
- Phase 0 prototype: `tools/perf/name_tok_v2_prototype/`
- chr22 benchmark: `docs/benchmarks/2026-05-04-name-tokenized-v2-results.md`
