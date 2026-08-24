# REF_DIFF_V2 codec (codec id 14)

> **Status:** current / live. The only supported reference-aligned
> encoding for the genomic `sequences` channel (it replaced the
> removed REF_DIFF v1, codec id 9 — see
> [`ref_diff.md`](ref_diff.md)). Normative kernel in C
> (`native/src/ref_diff_v2.{c,h}`); the Python wrapper
> (`python/src/ttio/codecs/ref_diff_v2.py`, ctypes) drives it. The
> codec is **context-aware** and **needs an embedded reference**:
> the registry adapter sets `is_context_aware = True` and
> `needs_embedded_reference = True`
> (`python/src/ttio/codecs/_registry.py`, `_RefDiffV2Codec`).

This document specifies the REF_DIFF_V2 codec used by TTI-O to encode
the genomic `sequences` channel as a per-read diff against an embedded
reference. Where this document and the design spec disagree,
the code is authoritative.

## 1. What it does

REF_DIFF_V2 stores aligned reads not as raw bases but as a diff
against a reference sequence. For each `M`/`=`/`X` cigar operation the
codec emits a 1-bit flag (base equals reference → 0, mismatch → 1);
mismatching bases, inserted bases (`I`), and soft-clipped bases (`S`)
are 2-bit-packed (ACGT) into separate substreams. Non-ACGT bases
(e.g. `N`, IUPAC ambiguity codes) are carried verbatim in an **escape
(ESC)** substream. Each substream is then compressed with rANS
order-0.

The codec operates on a single chromosome's worth of reads at a time.
Its decode adapter rejects multi-chromosome runs (`_RefDiffV2Codec.decode`
raises *"REF_DIFF_V2 supports single-chromosome runs only"* when the
run carries more than one distinct chromosome).

**Embedded reference.** The reference bytes are *not* stored inside
the codec blob; only the `reference_uri` and a 16-byte `reference_md5`
are. The reference itself is embedded elsewhere in the file at
`/study/references/<reference_uri>/` (see `docs/format-spec.md`
§10.10). On decode, the registry adapter resolves the reference via
`CodecContext.reference_resolver.resolve(uri, expected_md5, chromosome)`.

**Fallback without a reference (write side).** REF_DIFF_V2 is the
default `sequences` codec, but it can only run when a reference is
available at write time. Under the default `blocks_v1` layout a run
without a reference codes sequences with RANS_ORDER1, and fully
unmapped blocks fall back to BASE_PACK (`format-spec.md` §10.12.3);
on the legacy whole-channel path the no-reference fallback is
BASE_PACK (`python/src/ttio/written_genomic_run.py`, "Q5b = C").
Likewise, the codec functions require the native library: if
`TTIO_RANS_LIB_PATH` does not point at a built `libttio_rans.so` then
`HAVE_NATIVE_LIB` is False and `encode`/`decode` raise `RuntimeError`.

## 2. Per-base classification

The encoder walks each read's cigar (`rdv2_encode_slice` in
`native/src/ref_diff_v2.c`). Cigar lengths are parsed as decimal
ASCII; positions are 1-based on input and converted to 0-based
(`ref_pos = positions[gid] - 1`). Operation handling:

| Cigar op      | Consumes read | Advances ref | Substream                         |
|---------------|---------------|--------------|-----------------------------------|
| `M` `=` `X`   | yes           | yes          | FLAG (+ BS on mismatch)           |
| `I`           | yes           | no           | IN                                |
| `S`           | yes           | no           | SC                                |
| `D` `N`       | no            | yes (`+len`) | — (reference skip)                |
| `H` `P`       | no            | no           | — (no-op)                         |
| any other     | —             | —            | error (`TTIO_RANS_ERR_PARAM`)     |

Within `M`/`=`/`X`: read and reference bases are upper-cased before
comparison. Equal → FLAG bit `0`. Unequal → FLAG bit `1`, and the read
base is appended to the BS (base-substitution) stream. ACGT bases are
2-bit-encoded; any non-ACGT base writes a `0` placeholder code and is
recorded in the ESC stream instead (`rdv2_base_to_2bit` returns
`RDV2_BASE_INVALID = 0xFF` for non-ACGT).

## 3. Constants

From `native/src/ref_diff_v2.h`:

| Symbol                   | Value     | Meaning                                          |
|--------------------------|-----------|--------------------------------------------------|
| `RDV2_MAGIC`             | `"RDF2"`  | outer container magic (4 bytes)                  |
| `RDV2_VERSION`           | `0x01`    | container version                                |
| `RDV2_OUTER_FIXED`       | `38`      | outer fixed header length (before URI payload)   |
| `RDV2_SLICE_INDEX_ENTRY` | `32`      | bytes per slice-index entry                      |
| `RDV2_SLICE_SUBHDR`      | `24`      | slice body sub-header length (6 × u32 LE)        |
| `RDV2_ESC_BS`            | `0`       | ESC stream id for the BS substream               |
| `RDV2_ESC_IN`            | `1`       | ESC stream id for the IN substream               |
| `RDV2_ESC_SC`            | `2`       | ESC stream id for the SC substream               |
| `RDV2_BASE_A/C/G/T`      | `0/1/2/3` | 2-bit ACGT codes                                 |
| `RDV2_BASE_INVALID`      | `0xFF`    | sentinel for non-ACGT base                       |

Default `reads_per_slice` is **10000** (Python `encode` default and
the C default when `in->reads_per_slice == 0`). The `reference_md5`
must be exactly 16 bytes; `reference_uri` length must be ≤ `0xFFFF`.

Since M97 the encoder also takes a `slice_bytes` byte budget
(`in->slice_bytes`; Python `slice_bytes`; Java/ObjC `sliceBytes`).
With a budget > 0 a slice closes before the read that would push it
past that many bases; `reads_per_slice` still caps the read count and
every slice keeps at least one read. This is writer policy only: the
wire format and decoder are unchanged (the decoder walks the slice
index and carries no assumption about boundary placement), and 0
reproduces the fixed-count output byte for byte. The writers surface
it as `WrittenGenomicRun.ref_diff_slice_bytes` / `refDiffSliceBytes`.

## 4. Wire format

All multi-byte integers are little-endian.

### 4.1 Outer container header (`RDV2_OUTER_FIXED = 38` + URI)

| Offset  | Size | Field           | Notes                                |
|---------|------|-----------------|--------------------------------------|
| `0`     | 4    | magic           | `"RDF2"`                             |
| `4`     | 1    | version         | `0x01`                               |
| `5`     | 3    | reserved        | zero                                 |
| `8`     | 4    | n_slices        | u32                                  |
| `12`    | 8    | n_reads         | u64                                  |
| `20`    | 16   | reference_md5   | 16 raw bytes                         |
| `36`    | 2    | uri_len         | u16, length of the URI in bytes      |
| `38`    | `uri_len` | reference_uri | UTF-8, not NUL-terminated          |

`parse_blob_header` in `ref_diff_v2.py` reads `reference_md5` from
`[20:36]`, `uri_len` from `[36:38]`, and `reference_uri` from
`[38:38+uri_len]`. The full header length is `38 + uri_len`.

### 4.2 Slice index

Immediately after the header come `n_slices` entries of
`RDV2_SLICE_INDEX_ENTRY = 32` bytes each:

| Offset | Size | Field                                                    |
|--------|------|----------------------------------------------------------|
| `0`    | 8    | body_offset (u64, relative to the slice-bodies region)   |
| `8`    | 4    | body_len (u32)                                           |
| `12`   | 8    | first read position (u64, 1-based, from `positions[first_read]`) |
| `20`   | 8    | last read position (u64, from `positions[first_read+n-1]`) |
| `28`   | 4    | num_reads in slice (u32)                                 |

The slice-bodies region begins at `38 + uri_len + n_slices * 32`. The
decoder only reads `body_offset`, `body_len`, and `num_reads`; the two
position fields are an index for range queries.

### 4.3 Slice body sub-header (`RDV2_SLICE_SUBHDR = 24`)

Each slice body opens with six little-endian u32 lengths:

| Offset | Size | Field                                 |
|--------|------|---------------------------------------|
| `0`    | 4    | flag_rans_len (FLAG substream)        |
| `4`    | 4    | bs_rans_len (BS substream)            |
| `8`    | 4    | in_rans_len (IN substream)            |
| `12`   | 4    | sc_rans_len (SC substream)            |
| `16`   | 4    | esc_rans_len (ESC substream)          |
| `20`   | 4    | ul_rans_len (UL substream; 0 when the slice has no unmapped read) |

The rANS-encoded substreams follow the sub-header in exactly that
order (FLAG, BS, IN, SC, ESC, UL). The decoder rejects a body whose
`24 + flag + bs + in + sc + esc + ul` exceeds the slice body length.
Before v1.9 the word at offset 20 was reserved and had to be 0; a
slice without an unmapped read still writes 0 there, so every blob
written before v1.9 decodes unchanged, and a pre-1.9 decoder rejects
only the slices that carry a UL substream.

### 4.4 Substream contents

- **FLAG** — one byte (`0` or `1`) per `M`/`=`/`X` base, in read order.
- **BS** — 2-bit ACGT codes (LSB-first within each byte; 4 codes/byte)
  for each mismatching `M`/`=`/`X` base, packed by `rdv2_pack_2bit`.
- **IN** — 2-bit codes for each `I` base.
- **SC** — 2-bit codes for each `S` base.
- **ESC** — variable-length records for non-ACGT bases. Each record is:
  `stream_id` (1 byte: `0`=BS, `1`=IN, `2`=SC), then a LEB128 varint
  giving the index of the base within that substream, then the literal
  raw byte. The decoder errors with `TTIO_RANS_ERR_RESERVED_ESC_STREAM`
  on `stream_id > 2`, and with `TTIO_RANS_ERR_ESC_LENGTH_MISMATCH` if
  the ESC stream is not fully consumed after the walk.
- **UL** (v1.9) — one LEB128 varint per unmapped read in the slice, in
  read order: the read's length in bases. An unmapped read is one whose
  CIGAR is `*` (or empty); its bases all go to SC as if its CIGAR were
  `<length>S`, its position is not consulted, and non-ACGT bases escape
  through ESC with `stream_id 2` like any soft-clipped base. The
  decoder derives every other read's length from its CIGAR, so UL is
  what lets a read without an alignment sit in a reference-coded slice
  (a mate-placed unmapped read inside a mapped block, for example).

Each substream is independently compressed with rANS order-0
(`ttio_rans_o0_encode` / `ttio_rans_o0_decode` from `ttio_rans.h`).

## 5. Encode / decode flow

**Encode** (`ttio_ref_diff_v2_encode`):
1. Write the outer header, compute `n_slices` from
   `ceil(n_reads / reads_per_slice)`.
2. For each slice, `rdv2_encode_slice` does a counting pass over the
   cigars, then a second pass building the five raw substreams (FLAG /
   BS / IN / SC / ESC), 2-bit-packs BS/IN/SC, rANS-encodes all five,
   and assembles the slice body.
3. Fill the slice-index entry and advance.

The Python wrapper sizes the output buffer with
`ttio_ref_diff_v2_max_encoded_size(n_reads, total_bases)` and returns
the exact `*out_len` bytes.

**Decode** (`ttio_ref_diff_v2_decode`): validates magic/version,
checks the header `n_reads` equals the caller-supplied `n_reads`
(`TTIO_RANS_ERR_PARAM` on mismatch), then for each slice reads the
sub-header, rANS-decodes the five substreams, unpacks BS/IN/SC, and
walks the cigars to rebuild each read — copying the reference base for
FLAG=0, the BS/ESC base for FLAG=1, and the IN/SC/ESC bases for `I`/`S`
runs. It writes `out_sequences` and the per-read `out_offsets`
(`out_offsets[0] = 0`; `out_offsets[gid+1]` set per read). Decode
needs the caller to supply `positions`, `cigar_strings`, the resolved
`reference`, `n_reads`, and `total_bases` — the same per-read context
used at encode time.

## 6. Native-library requirement

Both `encode` and `decode` require `libttio_rans` (the C kernel plus
its rANS-O0 primitives). The Python wrapper loads it via
`fqzcomp_nx16_z._native_lib`, gated on `TTIO_RANS_LIB_PATH`. If the
library is unavailable, `HAVE_NATIVE_LIB` is False and both functions
raise `RuntimeError`. There is no pure-Python fallback path for the
codec itself; the writer-level fallback (to BASE_PACK) is a separate
decision made before this codec is reached (see §1).

### Error codes

`ttio_rans.h` / `ref_diff_v2.py`:

| Code | Symbol                            | Meaning                          |
|------|-----------------------------------|----------------------------------|
| `-1` | `ERR_PARAM`                       | invalid parameters / bad cigar   |
| `-2` | `ERR_ALLOC`                       | out of memory in native code     |
| `-3` | `ERR_CORRUPT`                     | corrupt encoded blob             |
| `-6` | `ERR_ESC_LENGTH_MISMATCH`         | ESC substream length mismatch    |
| `-7` | `ERR_RESERVED_ESC_STREAM`         | reserved ESC stream_id (> 2) seen |

## 7. Channel routing & storage layout

REF_DIFF_V2 applies only to the `sequences` channel. The encoded blob
is written as a `uint8` 1-D dataset `refdiff_v2` inside a `sequences`
**group** under `signal_channels`, carrying `@compression = 14`:

```
signal_channels/
  sequences/                (group)
    refdiff_v2              uint8 1-D blob, @compression = 14
```

The registry adapter `encode` returns a GROUP layout
(`EncodedChannel.of_group({"refdiff_v2": blob}, {})`); `decode` opens
the `refdiff_v2` child, parses the outer header, resolves the
reference, and decodes. See `docs/format-spec.md` §10.10b for the
full storage layout and the `/study/references/<reference_uri>/`
embedding (§10.10).

## 8. Conformance / where implemented

- **C kernel (normative):** `native/src/ref_diff_v2.c` +
  `native/src/ref_diff_v2.h`. Entry points
  `ttio_ref_diff_v2_encode` / `ttio_ref_diff_v2_decode` /
  `ttio_ref_diff_v2_max_encoded_size`.
- **Python wrapper:** `python/src/ttio/codecs/ref_diff_v2.py` (ctypes),
  registered as `_RefDiffV2Codec` (id 14) in
  `python/src/ttio/codecs/_registry.py` with
  `is_context_aware = True`, `needs_embedded_reference = True`.
- **Enum:** `Compression.REF_DIFF_V2 = 14`
  (`python/src/ttio/enums.py`).

The Python wrapper links directly against the C kernel, so the two
share one implementation rather than being independent reimplementations.
This document does not assert ObjC/Java parity for REF_DIFF_V2; consult
the cross-language conformance matrix for current status.

## 9. References

- Code (ground truth): `native/src/ref_diff_v2.c`,
  `native/src/ref_diff_v2.h`,
  `python/src/ttio/codecs/ref_diff_v2.py`,
  `python/src/ttio/codecs/_registry.py`.
- Format spec: `docs/format-spec.md` §10.10 (reference embedding) and
  §10.10b (REF_DIFF_V2 storage layout).
- Removed v1 codec: [`ref_diff.md`](ref_diff.md).
- Sibling delta integer codec: [`delta_rans.md`](delta_rans.md).
