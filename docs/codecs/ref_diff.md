# TTI-O M93 — REF_DIFF Codec

> **Status:** shipping in v1.2.0 (M93). Reference implementation in
> Python, normative implementation in Objective-C, parity implementation
> in Java. All three produce byte-identical encoded streams for the
> four canonical conformance vectors and round-trip every input
> exactly. Applies to genomic-`sequences` channels; codec id `9`.

This document specifies the REF_DIFF codec used by TTI-O for
reference-based compression of aligned genomic sequence channels.
It defines the algorithm, the slice-based wire format, the reference
storage convention, the cross-language conformance contract, and
the per-language performance targets.

REF_DIFF is the v1.5 default codec for the `signal_channels/sequences`
channel of any `WrittenGenomicRun` whose reads are reference-aligned
(non-`*` CIGARs) and for which a reference is available at write
time. When the reference is unavailable, the writer falls back to
[BASE_PACK](base_pack.md) per-channel (Q5b in the design spec).

---

## 1. Algorithm

REF_DIFF replaces the per-base storage of read sequences with the
*differences* between each read and the reference sequence at the
read's aligned position. CIGAR operations supply the alignment
structure; only the deviations are encoded.

For each cigar `M` / `=` / `X` op base, a single bit records
"matches reference" (`0`) or "substitution" (`1`). When the bit is
`1`, the actual read base follows as eight bits (MSB-first). For
each cigar `I` (insertion) or `S` (soft-clip) op, the inserted
bases follow verbatim as whole bytes. CIGAR `D` / `N` / `H` / `P`
ops carry no per-read payload — their lengths come from the
sibling `cigars` channel at decode time.

The resulting bitstream is then rANS-encoded (codec id `4`,
order-0). Real Illumina data at >99% mapping accuracy gives a flag
stream that's ~99% zero bits, which rANS compresses heavily by
entropy.

### Worked example

Reference at position 1: `ACGTACGTAC`.
Read sequence: `ACCTACGTAC` with cigar `10M` aligning at position 1.

| Op base | Read | Ref  | Flag | Sub byte |
|---------|------|------|------|----------|
| 0       | A    | A    | 0    |          |
| 1       | C    | C    | 0    |          |
| 2       | C    | G    | 1    | C (0x43) |
| 3       | T    | T    | 0    |          |
| 4       | A    | A    | 0    |          |
| 5       | C    | C    | 0    |          |
| 6       | G    | G    | 0    |          |
| 7       | T    | T    | 0    |          |
| 8       | A    | A    | 0    |          |
| 9       | C    | C    | 0    |          |

Bitstream MSB-first: `0 0 1 [0 1 0 0 0 0 1 1] 0 0 0 0 0 0 0` (13 bits +
3 zero pad to byte boundary). Two bytes: `0x28 0x60`. The slice
body for this single-read slice is then `rans_encode(b"\x28\x60")`.

### CIGAR op handling summary

| Op | Read advances | Ref advances | Payload |
|----|---------------|--------------|---------|
| `M` / `=` / `X` | +1 each | +1 each | 1 flag bit per base; 8 sub bits per `1` flag |
| `I` | +N | 0 | N bytes verbatim (insertion bases) |
| `S` | +N | 0 | N bytes verbatim (soft-clipped bases) |
| `D` / `N` | 0 | +N | none |
| `H` / `P` | 0 | 0 | none |

Unmapped reads (`cigar = "*"`) cannot be encoded — REF_DIFF requires
alignment context. The pipeline routes unmapped reads through
BASE_PACK on a separate sub-channel (`sequences_unmapped`,
deferred to a future M93.X).

---

## 2. Wire format

```
[Codec header, 38 + N bytes total]
  magic                : 4 bytes  "RDIF"
  version              : uint8    = 1
  reserved             : uint8[3] = 0
  num_slices           : uint32   little-endian
  total_reads          : uint64   little-endian
  reference_md5        : 16 bytes
  reference_uri_len    : uint16   little-endian
  reference_uri        : N bytes  UTF-8

[Slice index, num_slices × 32 bytes]
  for each slice:
    body_offset      : uint64    LE — offset relative to slice-bodies block
    body_length      : uint32    LE
    first_position   : int64     LE — first read's 1-based reference position
    last_position    : int64     LE — last read's 1-based reference position
    num_reads        : uint32    LE

[Slice bodies, concatenated]
  for each slice (independently rANS_ORDER0-encoded):
    For each read in slice (in order):
      bit-packed: M-op flags interleaved with substitution bytes
      I-op bases verbatim (whole bytes)
      S-op bases verbatim (whole bytes)
```

All multi-byte integers are little-endian. The bit-pack within a
byte is **MSB-first** — the first encoded bit occupies bit 7 of its
byte. The bit-stream pads to a byte boundary with zeros before the
verbatim I-op + S-op bytes; pad bits **must** be zero (binding
decision §80a, mirrored from §83).

The header's fixed prefix (38 bytes) is independent of
`reference_uri_len`, so a reader can parse the header in two reads
if streaming.

---

## 3. Slicing

Reads in coordinate order are partitioned into fixed-read-count
slices, default 10 000 reads per slice, mirroring CRAM 3.1's slice
strategy (binding decision §80a). A short tail slice is allowed at
end of run.

The slice index in the codec header lets a reader decode any
contiguous subset of reads without touching the others — a region
query (`indices_for_region(chrom, start, end)`) maps to the
slices whose `[first_position, last_position]` overlaps the
query, and only those slice bodies get rANS-decoded. For chr22
NA12878 (1.78M reads) at default slice size: ~178 slices, ~1.5 MB
body each.

---

## 4. Reference storage

REF_DIFF expects the reference chromosome sequences to be either
**embedded** in the same `.tio` file (the default) or **external**
via the `REF_PATH` env var. The file's
`@reference_uri` and `@reference_md5` codec-header fields are the
lookup key.

### Embedded layout (default `embed_reference=True`)

```
/study/references/<reference_uri>/
  @md5             = "<32-char hex>"
  @reference_uri   = "<the URI>"
  chromosomes/
    <chrom_name>/
      @length      = <int>
      data         : uint8 dataset of uppercase ACGTN bytes (zlib-compressed)
```

The MD5 is computed by concatenating the embedded chromosomes in
sorted name order and hashing the resulting bytes.

**Auto-deduplication** (binding decision §80b): when multiple
runs in the same file share a `reference_uri`, the writer embeds
the reference only once. A second run with the same URI but a
different MD5 raises `ValueError` immediately at write time.

### External fallback (opt-in `embed_reference=False`)

Only the `@reference_uri` and codec-header MD5 are written to the
file. The reader resolves via the lookup chain:

1. Embedded `/study/references/<uri>/` group (if present, MD5 verified)
2. `REF_PATH` env var pointing at a FASTA file (MD5 verified)
3. `RefMissingError` (binding decision §80c — hard error, no
   partial decode).

---

## 5. Cross-language conformance contract

The Python implementation in `python/src/ttio/codecs/ref_diff.py`
is the spec of record. The four fixtures under
`python/tests/fixtures/codecs/ref_diff_*.bin` are the wire-level
conformance test vectors:

| Fixture | Inputs | Wire size | Coverage |
|---------|--------|-----------|----------|
| `ref_diff_a.bin` | 100 reads × 100bp pure-match `ACGTACGTAC*10` against `ACGT*250` ref, all `100M` cigars at pos 1 | 3 866 B | All-match — exercises rANS on a near-zero-entropy flag stream |
| `ref_diff_b.bin` | 200 reads × 100bp with one substitution rotated through positions 0-99 | 6 899 B | Sparse subs — exercises mid-entropy flag stream + sub-byte interleaving |
| `ref_diff_c.bin` | 30 reads × 3 cigar shapes (`2S10M`, `4M2I6M`, `5M2D5M`) | 1 173 B | Heavy indels + soft-clips — exercises I/S/D op paths |
| `ref_diff_d.bin` | 1 read × `1M` | 1 120 B | Edge — single-read slice |

Each implementation:

- Loads the fixtures from a known location relative to its tests.
- Encodes the same input data and verifies bytes-equal to the
  fixture (encoder conformance).
- Decodes the fixture and verifies bytes-equal to the original
  input (decoder conformance).

Implementations:

- Python — `python/tests/fixtures/codecs/`
- Objective-C — `objc/Tests/Fixtures/codecs/` (verbatim copies)
- Java — `java/src/test/resources/ttio/codecs/` (verbatim copies)

`md5sum` of each fixture in all three locations must match.

---

## 6. Performance

Per-language soft targets, measured single-core on a developer
laptop:

| Language | Encode (target) | Decode (target) | Notes |
|----------|-----------------|-----------------|-------|
| Python   | ≥ 5 MB/s        | ≥ 5 MB/s        | Pure Python; the per-bit loop in `pack_read_diff_bitstream` is the hot path. Vectorising via numpy is a v1.3+ follow-up. |
| Objective-C | ≥ 50 MB/s    | ≥ 50 MB/s       | Hard floors |
| Java     | ≥ 30 MB/s       | ≥ 30 MB/s       | JIT warm-up variance |

Measured on the M93 reference host (chr22 lean fixture, 1.78M
reads at 100bp): values land at the spec-driven gate established
by `python/tests/perf/test_m93_throughput.py`.

The Python perf gate is set conservatively at 3 MB/s (above the
observed 3.4 MB/s on the reference host) to detect regressions
without forcing premature optimisation. Native-language ObjC and
Java implementations easily exceed their respective targets.

---

## 7. Public API

### Python

```python
from ttio.codecs.ref_diff import encode, decode

encoded: bytes = encode(
    sequences=[b"ACGTACGTAC", ...],   # list[bytes], one per read
    cigars=["10M", ...],              # list[str], parallel
    positions=[1, ...],               # list[int], 1-based
    reference_chrom_seq=b"ACGT...",   # whole chromosome bytes
    reference_md5=b"\\x..." * 16,     # 16-byte MD5 of the ref
    reference_uri="GRCh37.hs37d5",    # URI matching the BAM @SQ M5 lookup
)

decoded: list[bytes] = decode(
    encoded,
    cigars=["10M", ...],
    positions=[1, ...],
    reference_chrom_seq=b"ACGT...",
)
```

The codec is exposed in M86's pipeline via
`Compression.REF_DIFF` (= 9) on the `signal_codec_overrides` dict
of `WrittenGenomicRun`.

### Objective-C

```objc
NSData *encoded = [TTIORefDiff encodeWithSequences:sequences
                                            cigars:cigars
                                         positions:positions
                                 referenceChromSeq:referenceChromSeq
                                      referenceMD5:referenceMD5
                                      referenceURI:referenceURI
                                             error:&error];

NSArray<NSData *> *decoded = [TTIORefDiff decodeData:encoded
                                              cigars:cigars
                                           positions:positions
                                   referenceChromSeq:referenceChromSeq
                                               error:&error];
```

### Java

```java
byte[] encoded = RefDiff.encode(sequences, cigars, positions,
                                referenceChromSeq, referenceMD5, referenceURI);
List<byte[]> decoded = RefDiff.decode(encoded, cigars, positions,
                                       referenceChromSeq);
```

---

## 8. Binding decisions

| # | Decision | Rationale |
|---|---|---|
| §80a | REF_DIFF wire format uses bit-packed M-op flags + raw I/S-op bases; D/H/N/P ops carry no payload. | The cigar channel already encodes structure; redundant payload would inflate. |
| §80b | Embedded references at `/study/references/<reference_uri>/`; auto-deduplicated within a single file by URI. | Multi-omics files (M91) frequently share a reference; per-run duplication wastes space. |
| §80c | REF_DIFF read-time fallback: hard error when reference not resolvable. No partial decode. | Genomic data integrity is non-negotiable. |
| §80g | v1.5 format-version is a clean break — no feature flag, no dual-read shim. v1.1.x readers reject via existing schema check. | Aligns with binding decision §74 (clean-break philosophy from M80 rebrand). |

See also: `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`
for the design discussion and Q1-Q6 decisions that produced these bindings.

---

## 9. Limitations and follow-ups (v1.2)

- **Single-chromosome runs only.** v1.2 first-pass implementations
  enforce that all reads in a `WrittenGenomicRun` share a single
  chromosome. Multi-chrom dispatch (per-chromosome subgroups + a
  dispatching wrapper) lands as a future M93.X.
- **No CRAM-style 4-way slice parallelism.** v1.2 slices are
  rANS-encoded sequentially. A future M93.Y can wrap the slice
  body in interleaved 4-way rANS (M94's FQZCOMP_NX16 will lay the
  groundwork).
- **Pure-Python encode at ~3.4 MB/s.** numpy-vectorised bit-pack
  raises the gate to 5 MB/s+ as a v1.3 follow-up.
- **Unmapped-read sub-channel** (`sequences_unmapped`) is not
  implemented in v1.2. Reads with `cigar = "*"` raise at write
  time; users must currently strip unmapped reads from the BAM
  before writing. Sub-channel routing is a future M93.X.

References:
- CRAM 3.1 spec (samtools.github.io/hts-specs/CRAMv3.1.pdf) — slice
  structure inspiration.
- Bonfield 2013, "Compression of FASTQ and SAM Format Sequencing
  Data", PLOS ONE — quality coding (used by M94, not REF_DIFF).
