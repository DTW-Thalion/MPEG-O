# TTI-O — FLOAT_DELTA_ZSTD Codec

> **Status:** shipped. Applies to spectral float64 signal channels;
> codec id `17`, magic `FDZ1`. Default for float64 channels of
> mass-spectrometry runs (writers opt out per run with
> `opt_disable_float_delta` / `optDisableFloatDelta`); other spectral
> classes opt in via `signal_compression="float_delta_zstd"`. Also
> carried on the transport AU wire (`transport-spec.md` §4.3), where
> it is the default when compression is enabled.

Lossless float64 channel codec: per block of 2²⁰ values, the encoder
views the float64 bit patterns as uint64, applies whichever of four
transforms yields the smaller stream, and compresses the result as
one zstd (RFC 8878) frame per block. Values round-trip bit-exactly —
NaN payloads, signed zeros, and infinities are preserved, because the
codec never interprets the values as numbers, only as 64-bit
patterns.

Blocks are independent, so a reader can decode one block without
touching the rest of the stream; the per-block reader path is what
the spectral block consumer (`for_each_block` / `iterBlocks`) and the
unit-column accessor decode through.

---

## 1. Transforms

Each block records a one-byte transform, a bitmask of two independent
choices, each made per block by exact output-size comparison:

| Bit | Set | Clear |
|-----|-----|-------|
| 0 (`0x01`) | prefix delta mod 2⁶⁴ on the uint64 bit view | values as-is |
| 1 (`0x02`) | plain little-endian uint64 stream | byte-plane transpose (8 planes, plane 0 = LSBs) |

The byte-plane transpose pays on smooth channels (intensity) and
costs on others (m/z), so neither choice is global. Bits above
`0x03` are reserved and must be zero.

## 2. Wire format (codec id 17)

All multi-byte integers little-endian.

```
Offset  Size  Field
0       4     magic         "FDZ1"
4       1     version       0x01
5       1     flags         0x00 (reserved)
6       8     n_values      u64
14      4     block_size    u32  (values per block; encoder uses 2^20)
18      4     n_blocks      u32
22      var   per block:
                1  transform    (section 1)
                4  body_length  u32
                body: one zstd frame of the transformed block
```

Every block holds `block_size` values except the last, which holds
the remainder. A block body must inflate to exactly `8 × block
values`; anything else is a corrupt-stream error, as is a stream
whose byte length disagrees with its block table.

## 3. On-disk and on-wire shape

On disk the channel dataset becomes a flat 1-D `uint8` stream tagged
`@compression = 17` with no HDF5 filter (`format-spec.md` §10.4). On
the transport stream, AU channels carry the same self-contained FDZ1
stream when the DatasetHeader names codec 17 (`transport-spec.md`
§4.3); `complex128` packs Re/Im as two float64 halves.

## 4. Cross-language conformance contract

Unlike the entropy codecs, FLOAT_DELTA_ZSTD does **not** promise
byte-identical encoder output across languages: zstd builds differ,
and the frame bytes are the zstd library's. The contract is
decode-side:

- Encoders MAY differ byte-wise across languages and zstd versions.
  The zstd level (this encoder uses 9) is wire-invisible.
- Decoders MUST accept any spec-conforming stream and reproduce the
  input bit-exactly.
- A shared golden fixture
  (`python/tests/fixtures/float_delta_zstd_golden.bin`) pins the
  decode side in all three languages.

## 5. Public API

Python — `ttio.codecs.float_delta_zstd`: `encode(values)` /
`decode(stream)` for whole channels; `encode_block` / `block_bytes` /
`header_bytes` for streaming writers; `read_block_table` /
`decode_block` for random access to one block of a stream addressed
by a `read_bytes(offset, length)` callable.

Objective-C — `TTIOFloatDeltaZstd` (`objc/Source/Codecs/`).

Java — `global.thalion.ttio.codecs.FloatDeltaZstd`.

## 6. Limitations

- float64 (and the float64 halves of complex128) only; the codec is
  not defined for other element types.
- The transform choice is per block, by exact size — encoders that
  pick differently are conforming, so stream size is reproducible
  only within one encoder build.
