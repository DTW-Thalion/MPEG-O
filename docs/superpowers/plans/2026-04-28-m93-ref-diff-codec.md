# M93 — REF_DIFF Codec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `REF_DIFF` reference-based sequence-diff codec (codec id 9) to TTI-O across all three languages, matching CRAM 3.1's reference-based seq compression and closing ~40 MB of the v1.2.0 chr22 compression gap.

**Architecture:** Per-channel context-aware codec. Encoder receives `sequences` bytes plus `(positions, cigars, ref_resolver)` from sibling channels. It walks each read's CIGAR against the reference, emits a bit-packed M-op flag stream + raw I/S-op bases, then rANS-encodes that. Slice-based wire format (10K reads/slice, CRAM-aligned) for random-access decode. Embedded reference at `/study/references/<reference_uri>/` with auto-deduplication across runs in the same file.

**Tech Stack:** Python 3.11+ / NumPy / h5py for reference impl; ObjC + GNUstep + libhdf5 C API for normative impl; Java 17 + Maven + JHDF5 for parity. rANS dependency on existing M83 codec (`ttio.codecs.rans` / `TTIORans` / `Rans`). All wire formats are little-endian per the existing M83/M85 convention. Cross-language byte-exact via canonical fixtures.

**Spec reference:** `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md` (commit 61cd4db). All algorithm details, wire-format byte counts, and binding decisions live there. This plan provides the TDD-structured task sequence.

---

## File Structure

### Python (reference implementation)

| Path | Action | Responsibility |
|---|---|---|
| `python/src/ttio/enums.py` | modify | Add `Compression.REF_DIFF = 9` |
| `python/src/ttio/codecs/ref_diff.py` | create | Codec encode/decode + helpers (~600 lines) |
| `python/src/ttio/codecs/__init__.py` | modify | Re-export `ref_diff_encode`/`ref_diff_decode` |
| `python/src/ttio/codecs/_codec_meta.py` | create | `is_context_aware` registry; `ContextAwareCodec` protocol |
| `python/src/ttio/genomic/reference_resolver.py` | create | `ReferenceResolver` class (embedded → external → error) |
| `python/src/ttio/written_genomic_run.py` | modify | Add `embed_reference: bool = True`, `external_reference_path: Path \| None = None` fields |
| `python/src/ttio/spectral_dataset.py` | modify | M86 pipeline context-aware hook; reference embed at `/study/references/`; format-version 1.4→1.5; new defaults dict |
| `python/src/ttio/__init__.py` | modify | Bump `FORMAT_VERSION = "1.5"` |
| `python/tests/test_m93_ref_diff_unit.py` | create | Codec unit tests (header, slice, cigar walker) |
| `python/tests/test_m93_ref_diff_pipeline.py` | create | M86 integration tests |
| `python/tests/test_m93_reference_resolver.py` | create | Reference resolution tests |
| `python/tests/integration/test_m93_3x3_matrix.py` | create | 3×3 cross-language conformance |
| `python/tests/integration/test_m93_compression_gate.py` | create | chr22 compression-ratio gate |
| `python/tests/fixtures/codecs/ref_diff_a.bin` | create | All-matches canonical fixture |
| `python/tests/fixtures/codecs/ref_diff_b.bin` | create | Sparse substitutions canonical fixture |
| `python/tests/fixtures/codecs/ref_diff_c.bin` | create | Heavy indels + soft-clips canonical fixture |
| `python/tests/fixtures/codecs/ref_diff_d.bin` | create | Edge cases canonical fixture |
| `python/tests/fixtures/genomic/m93_*.tio` | create | 3×3 matrix fixtures (3-4 files) |

### Objective-C (normative)

| Path | Action | Responsibility |
|---|---|---|
| `objc/Source/HDF5/TTIOEnums.h` | modify | Add `TTIOCompressionRefDiff = 9` |
| `objc/Source/Codecs/TTIORefDiff.h` | create | Public API |
| `objc/Source/Codecs/TTIORefDiff.m` | create | Codec implementation (~700 lines) |
| `objc/Source/Codecs/TTIOReferenceResolver.h` | create | Reference resolution interface |
| `objc/Source/Codecs/TTIOReferenceResolver.m` | create | Embedded + external lookup |
| `objc/Source/Dataset/TTIOWrittenGenomicRun.h` | modify | Add `embedReference:` / `externalReferencePath:` |
| `objc/Source/Dataset/TTIOSpectralDataset.m` | modify | M86 pipeline context-aware hook; reference embed; format-version constant `kTTIOFormatVersionM93 = @"1.5"` |
| `objc/Tests/TestM93RefDiffUnit.m` | create | Codec unit tests |
| `objc/Tests/TestM93RefDiffPipeline.m` | create | M86 integration tests |
| `objc/Tests/Fixtures/codecs/ref_diff_*.bin` | create | Verbatim copies from Python fixtures |
| `objc/Tests/Fixtures/genomic/m93_*.tio` | create | Verbatim copies from Python |

### Java (parity)

| Path | Action | Responsibility |
|---|---|---|
| `java/src/main/java/global/thalion/ttio/Enums.java` | modify | Add `Compression.REF_DIFF` |
| `java/src/main/java/global/thalion/ttio/codecs/RefDiff.java` | create | Codec encode/decode (~600 lines) |
| `java/src/main/java/global/thalion/ttio/codecs/ReferenceResolver.java` | create | Reference resolution |
| `java/src/main/java/global/thalion/ttio/WrittenGenomicRun.java` | modify | Add `embedReference()` / `externalReferencePath()` builder fields |
| `java/src/main/java/global/thalion/ttio/SpectralDataset.java` | modify | M86 pipeline context-aware hook; reference embed; format-version constant |
| `java/src/test/java/global/thalion/ttio/codecs/RefDiffUnitTest.java` | create | Codec unit tests |
| `java/src/test/java/global/thalion/ttio/codecs/RefDiffPipelineTest.java` | create | M86 integration tests |
| `java/src/test/resources/ttio/codecs/ref_diff_*.bin` | create | Verbatim copies from Python fixtures |
| `java/src/test/resources/ttio/fixtures/genomic/m93_*.tio` | create | Verbatim copies |

### Documentation

| Path | Action | Responsibility |
|---|---|---|
| `docs/codecs/ref_diff.md` | create | Full M93 codec spec |
| `docs/format-spec.md` | modify | New §10.10 (REF_DIFF + reference storage); update §10.4 codec table; format-version table |
| `WORKPLAN.md` | modify | Add Phase 9 / M93 entry; move "rANS-Nx16/fqzcomp" out of "Deferred to v1.1+" |
| `CHANGELOG.md` | modify | Add M93 entry under `[Unreleased]` |
| `ARCHITECTURE.md` | modify | Update genomic codec stack section; add context-aware codec interface note |

---

## Phase 1 — Python reference implementation (Tasks 1–12)

The Python reference is the source of truth for all canonical fixtures. ObjC and Java decode the Python-written bytes byte-exact.

### Task 1: Add `Compression.REF_DIFF = 9` enum slot + codec metadata registry

**Files:**
- Modify: `python/src/ttio/enums.py:74-83`
- Create: `python/src/ttio/codecs/_codec_meta.py`
- Test: `python/tests/test_m93_ref_diff_unit.py`

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_m93_ref_diff_unit.py
"""Unit tests for the M93 REF_DIFF codec."""
from __future__ import annotations

from ttio.enums import Compression


def test_ref_diff_enum_value_is_9():
    assert int(Compression.REF_DIFF) == 9
    assert Compression.REF_DIFF.name == "REF_DIFF"


def test_ref_diff_is_registered_as_context_aware():
    from ttio.codecs._codec_meta import is_context_aware
    assert is_context_aware(Compression.REF_DIFF) is True
    # All previously-shipped codecs are NOT context-aware.
    for codec in (Compression.RANS_ORDER0, Compression.RANS_ORDER1,
                   Compression.BASE_PACK, Compression.QUALITY_BINNED,
                   Compression.NAME_TOKENIZED):
        assert is_context_aware(codec) is False
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd python && pytest tests/test_m93_ref_diff_unit.py -v
```
Expected: FAIL — `Compression.REF_DIFF` doesn't exist.

- [ ] **Step 3: Add the enum value**

```python
# python/src/ttio/enums.py — in class Compression
class Compression(IntEnum):
    NONE = 0
    ZLIB = 1
    LZ4 = 2
    NUMPRESS_DELTA = 3
    RANS_ORDER0 = 4
    RANS_ORDER1 = 5
    BASE_PACK = 6
    QUALITY_BINNED = 7
    NAME_TOKENIZED = 8
    REF_DIFF = 9       # v1.2 M93: reference-based sequence diff (context-aware)
```

- [ ] **Step 4: Create the codec-meta registry**

```python
# python/src/ttio/codecs/_codec_meta.py
"""Codec metadata registry — context-aware codecs (M93+) declare here.

A context-aware codec needs more than the channel's bytes to encode/decode:
it consumes sibling channels (e.g. positions, cigars) and external resources
(e.g. a reference resolver). The M86 pipeline checks this registry to decide
whether to plumb the extra context to the codec call.
"""
from __future__ import annotations

from ttio.enums import Compression

_CONTEXT_AWARE: frozenset[Compression] = frozenset({
    Compression.REF_DIFF,   # M93
})


def is_context_aware(codec: Compression) -> bool:
    """Return True if the codec needs sibling channels / external resources at encode/decode time."""
    return codec in _CONTEXT_AWARE
```

- [ ] **Step 5: Run tests, expect PASS**

```bash
pytest tests/test_m93_ref_diff_unit.py::test_ref_diff_enum_value_is_9 -v
pytest tests/test_m93_ref_diff_unit.py::test_ref_diff_is_registered_as_context_aware -v
```
Expected: PASS for both.

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/enums.py python/src/ttio/codecs/_codec_meta.py python/tests/test_m93_ref_diff_unit.py
git commit -m "M93: add Compression.REF_DIFF=9 + context-aware codec registry"
```

---

### Task 2: Wire-format header encoder/decoder (no body)

**Files:**
- Create: `python/src/ttio/codecs/ref_diff.py` (initial 200 lines for header only)
- Test: `python/tests/test_m93_ref_diff_unit.py` (add)

- [ ] **Step 1: Write failing tests for the wire-format header**

```python
# python/tests/test_m93_ref_diff_unit.py — append
import struct

from ttio.codecs.ref_diff import (
    pack_codec_header,
    unpack_codec_header,
    pack_slice_index_entry,
    unpack_slice_index_entry,
    CodecHeader,
    SliceIndexEntry,
)


def test_codec_header_round_trip():
    h = CodecHeader(
        num_slices=3,
        total_reads=12345,
        reference_md5=bytes.fromhex("a718acaa6135fdca8357d5bfe94211dd"),
        reference_uri="GRCh37.hs37d5",
    )
    blob = pack_codec_header(h)
    # Header size = 4 magic + 1 ver + 3 reserved + 4 num_slices + 8 total_reads
    #   + 16 md5 + 2 uri_len + N uri = 38 + N
    assert len(blob) == 38 + len(h.reference_uri.encode("utf-8"))
    assert blob[:4] == b"RDIF"
    assert blob[4] == 1  # version
    h2, consumed = unpack_codec_header(blob)
    assert consumed == len(blob)
    assert h2 == h


def test_slice_index_entry_is_32_bytes():
    e = SliceIndexEntry(
        body_offset=1000,
        body_length=500,
        first_position=16050000,
        last_position=16060000,
        num_reads=10000,
    )
    blob = pack_slice_index_entry(e)
    assert len(blob) == 32
    e2 = unpack_slice_index_entry(blob)
    assert e2 == e


def test_codec_header_rejects_bad_magic():
    blob = bytearray(pack_codec_header(CodecHeader(0, 0, b"\x00" * 16, "")))
    blob[0] = ord("X")
    with pytest.raises(ValueError, match="bad magic"):
        unpack_codec_header(bytes(blob))


def test_codec_header_rejects_unsupported_version():
    blob = bytearray(pack_codec_header(CodecHeader(0, 0, b"\x00" * 16, "")))
    blob[4] = 99
    with pytest.raises(ValueError, match="unsupported.*version"):
        unpack_codec_header(bytes(blob))
```

- [ ] **Step 2: Run tests, expect FAIL** (ImportError)

```bash
pytest tests/test_m93_ref_diff_unit.py -v -k "header or slice_index"
```

- [ ] **Step 3: Implement the header / slice index dataclasses + pack/unpack**

```python
# python/src/ttio/codecs/ref_diff.py
"""TTI-O M93 — REF_DIFF reference-based sequence-diff codec.

Wire format documented in
``docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`` §3 (M93)
and ``docs/codecs/ref_diff.md``. Codec id is ``Compression.REF_DIFF`` = 9.
Context-aware: encode/decode receives ``positions``, ``cigars``, and a
``ReferenceResolver`` alongside the ``sequences`` byte stream.

This module is the Python reference implementation. ObjC
(``TTIORefDiff.{h,m}``) and Java (``codecs.RefDiff``) decode the bytes
this module produces byte-for-byte; the four canonical conformance
fixtures under ``python/tests/fixtures/codecs/ref_diff_{a,b,c,d}.bin``
are the contract.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

MAGIC = b"RDIF"
VERSION = 1
HEADER_FIXED_SIZE = 38  # magic(4) + ver(1) + reserved(3) + num_slices(4)
                       # + total_reads(8) + md5(16) + uri_len(2) = 38
SLICE_INDEX_ENTRY_SIZE = 32


@dataclass(frozen=True)
class CodecHeader:
    """REF_DIFF wire-format header (38 + len(reference_uri) bytes)."""

    num_slices: int
    total_reads: int
    reference_md5: bytes  # 16 bytes
    reference_uri: str    # UTF-8

    def __post_init__(self):
        if len(self.reference_md5) != 16:
            raise ValueError(f"reference_md5 must be 16 bytes, got {len(self.reference_md5)}")
        if len(self.reference_uri.encode("utf-8")) > 0xFFFF:
            raise ValueError("reference_uri too long (> 65535 bytes UTF-8)")


@dataclass(frozen=True)
class SliceIndexEntry:
    """Slice-index entry (32 bytes per slice)."""

    body_offset: int        # uint64 — relative to slice bodies block
    body_length: int        # uint32
    first_position: int     # int64 (1-based on reference)
    last_position: int      # int64
    num_reads: int          # uint32


def pack_codec_header(h: CodecHeader) -> bytes:
    uri_bytes = h.reference_uri.encode("utf-8")
    return (
        MAGIC
        + struct.pack("<B3xIQ", VERSION, h.num_slices, h.total_reads)
        + h.reference_md5
        + struct.pack("<H", len(uri_bytes))
        + uri_bytes
    )


def unpack_codec_header(blob: bytes) -> tuple[CodecHeader, int]:
    if len(blob) < HEADER_FIXED_SIZE:
        raise ValueError(f"header too short: {len(blob)} bytes")
    if blob[:4] != MAGIC:
        raise ValueError(f"bad magic: {blob[:4]!r}, expected {MAGIC!r}")
    version = blob[4]
    if version != VERSION:
        raise ValueError(f"unsupported REF_DIFF version: {version}")
    num_slices, total_reads = struct.unpack_from("<IQ", blob, 8)
    md5 = blob[20:36]
    (uri_len,) = struct.unpack_from("<H", blob, 36)
    if len(blob) < HEADER_FIXED_SIZE + uri_len:
        raise ValueError("header truncated in reference_uri")
    uri = blob[HEADER_FIXED_SIZE:HEADER_FIXED_SIZE + uri_len].decode("utf-8")
    return (
        CodecHeader(num_slices, total_reads, md5, uri),
        HEADER_FIXED_SIZE + uri_len,
    )


def pack_slice_index_entry(e: SliceIndexEntry) -> bytes:
    return struct.pack(
        "<QIqqI",
        e.body_offset, e.body_length, e.first_position, e.last_position, e.num_reads,
    )


def unpack_slice_index_entry(blob: bytes) -> SliceIndexEntry:
    if len(blob) != SLICE_INDEX_ENTRY_SIZE:
        raise ValueError(f"slice index entry must be {SLICE_INDEX_ENTRY_SIZE} bytes, got {len(blob)}")
    return SliceIndexEntry(*struct.unpack("<QIqqI", blob))
```

- [ ] **Step 4: Run tests, expect PASS**

```bash
pytest tests/test_m93_ref_diff_unit.py -v -k "header or slice_index"
```

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/codecs/ref_diff.py python/tests/test_m93_ref_diff_unit.py
git commit -m "M93: REF_DIFF wire-format header + slice-index dataclasses"
```

---

### Task 3: CIGAR walker — extract diff records from a single read

**Files:**
- Modify: `python/src/ttio/codecs/ref_diff.py` (add `walk_read_against_reference`)
- Test: `python/tests/test_m93_ref_diff_unit.py` (add)

The CIGAR walker is the algorithmic heart of the codec. It takes a read's `(sequence, cigar, position, reference_chrom_seq)` and emits the M-op flag stream + I/S-op base bytes per spec §3 M93. D/H/N/P ops carry no payload.

- [ ] **Step 1: Write failing tests for known cigar walks**

```python
# python/tests/test_m93_ref_diff_unit.py — append
from ttio.codecs.ref_diff import walk_read_against_reference, ReadWalkResult


def test_walk_all_match_no_subs():
    # Read fully matches reference at position 1.
    ref = b"AAAAAAAAAA"
    seq = b"AAAAA"
    cigar = "5M"
    pos = 1  # 1-based, so seq[0] aligns to ref[0]
    r = walk_read_against_reference(seq, cigar, pos, ref)
    # 5 M-op bases, all match → 5 zero bits, no substitution bytes
    assert r.m_op_flag_bits == [0, 0, 0, 0, 0]
    assert r.substitution_bases == b""
    assert r.insertion_bases == b""
    assert r.softclip_bases == b""


def test_walk_with_substitution():
    ref = b"ACGTACGTAC"
    seq = b"ACCTACGTAC"
    #         ^ G→C substitution at read pos 2
    cigar = "10M"
    pos = 1
    r = walk_read_against_reference(seq, cigar, pos, ref)
    assert r.m_op_flag_bits == [0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
    assert r.substitution_bases == b"C"


def test_walk_with_insertion_and_softclip():
    # 2S2M2I2M: 2 soft-clips, 2 matches, 2 insertions, 2 matches
    ref = b"ACGT"
    seq = b"NNACTTGT"
    cigar = "2S2M2I2M"
    pos = 1
    r = walk_read_against_reference(seq, cigar, pos, ref)
    # M-op walks: ref[0..1] vs seq[2..3] = AC == AC → [0,0]
    #             ref[2..3] vs seq[6..7] = GT == GT → [0,0]
    assert r.m_op_flag_bits == [0, 0, 0, 0]
    assert r.softclip_bases == b"NN"
    # The inserted bases are at seq[4..5] = "TT"
    assert r.insertion_bases == b"TT"
    assert r.substitution_bases == b""


def test_walk_with_deletion():
    # 3M2D3M — read has 6 bases, ref-traversal is 8
    ref = b"ACGTACGTAC"
    seq = b"ACGCGT"
    cigar = "3M2D3M"
    pos = 1
    r = walk_read_against_reference(seq, cigar, pos, ref)
    # M-op walks: ref[0..2] vs seq[0..2] = ACG == ACG → [0,0,0]
    #             ref[5..7] vs seq[3..5] = CGT == CGT → [0,0,0]
    assert r.m_op_flag_bits == [0, 0, 0, 0, 0, 0]
    # D op carries no payload
    assert r.substitution_bases == b""
    assert r.insertion_bases == b""


def test_walk_rejects_unmapped_cigar_star():
    ref = b"AAAA"
    seq = b"NNNN"
    with pytest.raises(ValueError, match="unmapped"):
        walk_read_against_reference(seq, "*", 0, ref)
```

- [ ] **Step 2: Run tests, expect FAIL** (NotImplementedError or ImportError)

```bash
pytest tests/test_m93_ref_diff_unit.py -v -k "walk"
```

- [ ] **Step 3: Implement the walker**

```python
# python/src/ttio/codecs/ref_diff.py — append
import re
from dataclasses import dataclass, field

CIGAR_OP_RE = re.compile(r"(\d+)([MIDNSHPX=])")


@dataclass(frozen=True)
class ReadWalkResult:
    """Output of walking one read's CIGAR against the reference.

    Attributes:
        m_op_flag_bits: list of 0/1, one per M/=/X-op base. 0 = matches
            reference at this position, 1 = substitution.
        substitution_bases: concatenated substitution bytes, one per
            ``m_op_flag_bits == 1`` entry, in CIGAR-walk order.
        insertion_bases: concatenated I-op bases, in CIGAR-walk order.
        softclip_bases: concatenated S-op bases, in CIGAR-walk order.
    """

    m_op_flag_bits: list[int]
    substitution_bases: bytes
    insertion_bases: bytes
    softclip_bases: bytes


def walk_read_against_reference(
    sequence: bytes,
    cigar: str,
    position: int,
    reference_chrom_seq: bytes,
) -> ReadWalkResult:
    """Walk one read's CIGAR against the reference and emit a diff record.

    See spec §3 M93 algorithm.

    Args:
        sequence: read's full sequence (uppercase ACGT… bytes).
        cigar: CIGAR string ("100M", "2S98M", "3M2D5M", etc.). "*" rejects.
        position: 1-based reference position where the M-walk starts.
        reference_chrom_seq: full chromosome sequence (uppercase ACGTN…).

    Returns:
        ReadWalkResult.
    """
    if cigar == "*" or cigar == "":
        raise ValueError("REF_DIFF cannot encode unmapped reads (cigar='*'); route through BASE_PACK")

    m_op_flag_bits: list[int] = []
    sub_buf = bytearray()
    ins_buf = bytearray()
    soft_buf = bytearray()

    seq_i = 0
    ref_i = position - 1  # 0-based

    for length_str, op in CIGAR_OP_RE.findall(cigar):
        length = int(length_str)
        if op in ("M", "=", "X"):
            for k in range(length):
                read_base = sequence[seq_i + k]
                ref_base = reference_chrom_seq[ref_i + k]
                if read_base == ref_base:
                    m_op_flag_bits.append(0)
                else:
                    m_op_flag_bits.append(1)
                    sub_buf.append(read_base)
            seq_i += length
            ref_i += length
        elif op == "I":
            ins_buf.extend(sequence[seq_i:seq_i + length])
            seq_i += length
            # ref_i unchanged
        elif op == "S":
            soft_buf.extend(sequence[seq_i:seq_i + length])
            seq_i += length
            # ref_i unchanged
        elif op in ("D", "N"):
            ref_i += length
            # seq_i unchanged
        elif op == "H" or op == "P":
            pass  # neither advances
        else:
            raise ValueError(f"unsupported CIGAR op: {op!r}")

    return ReadWalkResult(
        m_op_flag_bits=m_op_flag_bits,
        substitution_bases=bytes(sub_buf),
        insertion_bases=bytes(ins_buf),
        softclip_bases=bytes(soft_buf),
    )
```

- [ ] **Step 4: Run tests, expect PASS**

```bash
pytest tests/test_m93_ref_diff_unit.py -v -k "walk"
```

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/codecs/ref_diff.py python/tests/test_m93_ref_diff_unit.py
git commit -m "M93: CIGAR walker extracting M-op flags + I/S-op bases per read"
```

---

### Task 4: Reverse walker — reconstruct sequence from diff record + cigar + reference

**Files:**
- Modify: `python/src/ttio/codecs/ref_diff.py` (add `reconstruct_read_from_walk`)
- Test: `python/tests/test_m93_ref_diff_unit.py` (add)

This is the decode-side counterpart of the walker. Round-trip with Task 3 confirms reconstruction correctness.

- [ ] **Step 1: Write failing tests — round-trip on the Task 3 test cases**

```python
# python/tests/test_m93_ref_diff_unit.py — append
from ttio.codecs.ref_diff import reconstruct_read_from_walk


@pytest.mark.parametrize("ref,seq,cigar,pos", [
    (b"AAAAAAAAAA", b"AAAAA", "5M", 1),
    (b"ACGTACGTAC", b"ACCTACGTAC", "10M", 1),
    (b"ACGT", b"NNACTTGT", "2S2M2I2M", 1),
    (b"ACGTACGTAC", b"ACGCGT", "3M2D3M", 1),
])
def test_walk_then_reconstruct_round_trip(ref, seq, cigar, pos):
    walk = walk_read_against_reference(seq, cigar, pos, ref)
    rebuilt = reconstruct_read_from_walk(walk, cigar, pos, ref)
    assert rebuilt == seq
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement reverse walker**

```python
# python/src/ttio/codecs/ref_diff.py — append
def reconstruct_read_from_walk(
    walk: ReadWalkResult,
    cigar: str,
    position: int,
    reference_chrom_seq: bytes,
) -> bytes:
    """Reconstruct a read sequence from its diff record + CIGAR + reference.

    Inverse of :func:`walk_read_against_reference`.
    """
    if cigar == "*" or cigar == "":
        raise ValueError("cannot reconstruct unmapped read")

    out = bytearray()
    flag_i = 0
    sub_i = 0
    ins_i = 0
    soft_i = 0
    ref_i = position - 1

    for length_str, op in CIGAR_OP_RE.findall(cigar):
        length = int(length_str)
        if op in ("M", "=", "X"):
            for k in range(length):
                if walk.m_op_flag_bits[flag_i] == 0:
                    out.append(reference_chrom_seq[ref_i + k])
                else:
                    out.append(walk.substitution_bases[sub_i])
                    sub_i += 1
                flag_i += 1
            ref_i += length
        elif op == "I":
            out.extend(walk.insertion_bases[ins_i:ins_i + length])
            ins_i += length
        elif op == "S":
            out.extend(walk.softclip_bases[soft_i:soft_i + length])
            soft_i += length
        elif op in ("D", "N", "H", "P"):
            if op in ("D", "N"):
                ref_i += length
            # H/P: nothing
        else:
            raise ValueError(f"unsupported CIGAR op: {op!r}")

    # Sanity asserts catch off-by-ones early.
    assert flag_i == len(walk.m_op_flag_bits)
    assert sub_i == len(walk.substitution_bases)
    assert ins_i == len(walk.insertion_bases)
    assert soft_i == len(walk.softclip_bases)
    return bytes(out)
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -am "M93: reverse-walker reconstructs read sequence from diff + cigar + ref"
```

---

### Task 5: Bit-packed flag stream encoder/decoder

**Files:**
- Modify: `python/src/ttio/codecs/ref_diff.py` (add `pack_flag_stream`/`unpack_flag_stream`)
- Test: `python/tests/test_m93_ref_diff_unit.py` (add)

The flag stream is the sequence of all M-op flags across all reads in a slice, bit-packed MSB-first within each byte (matching the BASE_PACK §82 convention). Substitution bytes are interleaved: after each `1` bit, the next 8 bits form a substitution byte. The packed output is what gets rANS-encoded.

Wait — re-reading the spec §3 M93: the flag bits and substitution bytes are NOT interleaved bit-level; the flag bitstream and the substitution byte stream are separate. The "1 bit, then 8 bits if sub" is one logical byte stream where after each `1` bit you read 8 bits before the next flag. Let me clarify in the test.

Per spec §3 wire format:
```
For each read in slice:
  for each cigar M-op base:
    1 bit: match-ref (0) vs substitution (1)
    if substitution: 8 bits: actual base
  for each cigar I-op or S-op:
    op_length × 8 bits: inserted/soft-clipped bases
  // D, H, N, P ops: no payload
```

So the flag bits and substitution bytes ARE interleaved into one bitstream, with substitution bytes following the `1` bits. Then I/S-op bases follow per read.

- [ ] **Step 1: Write failing tests for the packer**

```python
# python/tests/test_m93_ref_diff_unit.py — append
from ttio.codecs.ref_diff import (
    pack_read_diff_bitstream,
    unpack_read_diff_bitstream,
)


def test_pack_simple_all_match():
    # 5 zero bits, no subs, no I/S — 1 byte of header bits
    walk = ReadWalkResult(
        m_op_flag_bits=[0, 0, 0, 0, 0],
        substitution_bases=b"",
        insertion_bases=b"",
        softclip_bases=b"",
    )
    blob = pack_read_diff_bitstream(walk)
    # 5 zero bits + 3 padding zero bits = 1 byte 0x00
    assert blob == b"\x00"


def test_pack_one_substitution():
    walk = ReadWalkResult(
        m_op_flag_bits=[0, 0, 1, 0, 0],
        substitution_bases=b"C",
        insertion_bases=b"",
        softclip_bases=b"",
    )
    blob = pack_read_diff_bitstream(walk)
    # 5 flag bits + 8 sub bits + 3 pad bits = 16 bits = 2 bytes
    # Bits: 0 0 1 0 0 [01000011] 0 0 0 → 0b001001000011_000_  (MSB-first)
    # Wait: 5 flag bits MSB-first = 00100, then 'C' = 0x43 = 01000011, then 3 pad zeros
    # First byte: 0010 0010 = 0x22, second byte: 0001 1000 = 0x18
    expected_bits = "0010001000011000"  # 16 bits
    expected = int(expected_bits, 2).to_bytes(2, "big")
    assert blob == expected


def test_round_trip_with_ins_softclip():
    walk = ReadWalkResult(
        m_op_flag_bits=[0, 1, 0],
        substitution_bases=b"T",
        insertion_bases=b"AA",
        softclip_bases=b"NN",
    )
    blob = pack_read_diff_bitstream(walk)
    # ins/softclip bases are appended verbatim AFTER the bit-packed flags+subs
    walk2 = unpack_read_diff_bitstream(
        blob,
        num_m_ops=3,
        ins_length=2,
        softclip_length=2,
    )
    assert walk2 == walk
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement pack/unpack**

```python
# python/src/ttio/codecs/ref_diff.py — append
def pack_read_diff_bitstream(walk: ReadWalkResult) -> bytes:
    """Pack one read's diff record into the wire bitstream.

    Layout per spec §3 M93:
      - Bit-packed sequence: for each M-op flag bit, append the bit
        (MSB-first within each byte). After a `1` flag, append the
        corresponding substitution byte's 8 bits MSB-first.
      - Then I-op bases verbatim (whole bytes).
      - Then S-op bases verbatim.
    """
    bits: list[int] = []
    sub_iter = iter(walk.substitution_bases)
    for flag in walk.m_op_flag_bits:
        bits.append(flag)
        if flag == 1:
            sub_byte = next(sub_iter)
            for shift in range(7, -1, -1):
                bits.append((sub_byte >> shift) & 1)

    # Pad to byte boundary
    while len(bits) % 8:
        bits.append(0)

    # Pack bits MSB-first into bytes
    out = bytearray()
    for i in range(0, len(bits), 8):
        byte = 0
        for j in range(8):
            byte = (byte << 1) | bits[i + j]
        out.append(byte)

    out.extend(walk.insertion_bases)
    out.extend(walk.softclip_bases)
    return bytes(out)


def unpack_read_diff_bitstream(
    blob: bytes,
    num_m_ops: int,
    ins_length: int,
    softclip_length: int,
) -> ReadWalkResult:
    """Inverse of :func:`pack_read_diff_bitstream`.

    Caller supplies the M-op count + I/S-op lengths (recovered from the
    cigar channel at decode time).
    """
    flag_bits: list[int] = []
    sub_buf = bytearray()

    bit_cursor = 0  # bit-index into blob's prefix
    for _ in range(num_m_ops):
        flag = (blob[bit_cursor // 8] >> (7 - bit_cursor % 8)) & 1
        flag_bits.append(flag)
        bit_cursor += 1
        if flag == 1:
            sub_byte = 0
            for _ in range(8):
                bit = (blob[bit_cursor // 8] >> (7 - bit_cursor % 8)) & 1
                sub_byte = (sub_byte << 1) | bit
                bit_cursor += 1
            sub_buf.append(sub_byte)

    # Skip to byte boundary
    bytes_consumed = (bit_cursor + 7) // 8
    ins = blob[bytes_consumed:bytes_consumed + ins_length]
    soft = blob[bytes_consumed + ins_length:bytes_consumed + ins_length + softclip_length]
    return ReadWalkResult(flag_bits, bytes(sub_buf), bytes(ins), bytes(soft))
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -am "M93: bit-packed read-diff bitstream encoder/decoder"
```

---

### Task 6: Slice encoder — combine walker + packer + rANS for 10K-read slices

**Files:**
- Modify: `python/src/ttio/codecs/ref_diff.py` (add `encode_slice`/`decode_slice`)
- Test: `python/tests/test_m93_ref_diff_unit.py` (add)

A slice is up to 10K reads. The slice body is the concatenation of all reads' bitstreams, then rANS-encoded with M83's existing `rans.encode`.

- [ ] **Step 1: Write failing test for round-trip on a 5-read slice**

```python
# python/tests/test_m93_ref_diff_unit.py — append
from ttio.codecs.ref_diff import encode_slice, decode_slice


def test_slice_round_trip_5_reads():
    ref = b"ACGTACGTAC" * 100  # 1000bp ref
    reads = [
        # (sequence, cigar, position)
        (b"ACGTACGTAC", "10M", 1),
        (b"AAGTACGTAC", "10M", 1),    # one substitution at index 1
        (b"ACGTNCGTAC", "5M1I4M", 1), # 1bp insertion 'N' at index 5 (cigar I op skips ref)
        (b"GTACGTACGT", "10M", 3),    # offset position
        (b"NNACGTACGT", "2S8M", 1),   # 2bp soft-clip at start
    ]
    sequences = [r[0] for r in reads]
    cigars = [r[1] for r in reads]
    positions = [r[2] for r in reads]

    encoded = encode_slice(sequences, cigars, positions, ref)
    sequences_out = decode_slice(encoded, cigars, positions, ref, num_reads=5)
    assert sequences_out == sequences
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement slice encode/decode**

```python
# python/src/ttio/codecs/ref_diff.py — append
import struct

from ttio.codecs.rans import encode as rans_encode, decode as rans_decode


def encode_slice(
    sequences: list[bytes],
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
) -> bytes:
    """Encode a slice of up to 10K reads into a rANS-compressed byte blob.

    The slice body layout, per spec §3 M93:
      For each read in slice (in order):
        bit-packed M-op flags (interleaved with substitution bytes)
        I-op bases verbatim
        S-op bases verbatim

    The concatenated raw bitstream is then rANS_ORDER0-encoded.
    """
    raw = bytearray()
    for seq, cigar, pos in zip(sequences, cigars, positions):
        walk = walk_read_against_reference(seq, cigar, pos, reference_chrom_seq)
        raw.extend(pack_read_diff_bitstream(walk))
    return rans_encode(bytes(raw), order=0)


def decode_slice(
    encoded: bytes,
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
    num_reads: int,
) -> list[bytes]:
    """Inverse of :func:`encode_slice`."""
    if num_reads != len(cigars) or num_reads != len(positions):
        raise ValueError("cigars/positions count must equal num_reads")

    raw = rans_decode(encoded)
    sequences: list[bytes] = []
    cursor = 0
    for cigar, pos in zip(cigars, positions):
        # Decode this read's bitstream from the raw blob starting at cursor.
        m_op_count = sum(int(n) for n, op in CIGAR_OP_RE.findall(cigar) if op in ("M", "=", "X"))
        ins_len = sum(int(n) for n, op in CIGAR_OP_RE.findall(cigar) if op == "I")
        soft_len = sum(int(n) for n, op in CIGAR_OP_RE.findall(cigar) if op == "S")
        walk, consumed = _unpack_one_read_with_consumed(
            raw[cursor:], m_op_count, ins_len, soft_len,
        )
        cursor += consumed
        sequences.append(reconstruct_read_from_walk(walk, cigar, pos, reference_chrom_seq))
    return sequences


def _unpack_one_read_with_consumed(
    blob: bytes,
    num_m_ops: int,
    ins_length: int,
    softclip_length: int,
) -> tuple[ReadWalkResult, int]:
    """Like unpack_read_diff_bitstream but also returns total bytes consumed."""
    flag_bits: list[int] = []
    sub_buf = bytearray()
    bit_cursor = 0
    for _ in range(num_m_ops):
        flag = (blob[bit_cursor // 8] >> (7 - bit_cursor % 8)) & 1
        flag_bits.append(flag)
        bit_cursor += 1
        if flag == 1:
            sub_byte = 0
            for _ in range(8):
                bit = (blob[bit_cursor // 8] >> (7 - bit_cursor % 8)) & 1
                sub_byte = (sub_byte << 1) | bit
                bit_cursor += 1
            sub_buf.append(sub_byte)
    bytes_consumed = (bit_cursor + 7) // 8
    ins = blob[bytes_consumed:bytes_consumed + ins_length]
    soft = blob[bytes_consumed + ins_length:bytes_consumed + ins_length + softclip_length]
    walk = ReadWalkResult(flag_bits, bytes(sub_buf), bytes(ins), bytes(soft))
    return walk, bytes_consumed + ins_length + softclip_length
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -am "M93: per-slice encoder/decoder (CIGAR walk + bit-pack + rANS)"
```

---

### Task 7: Top-level `encode`/`decode` — slicing 10K reads + assembling wire format

**Files:**
- Modify: `python/src/ttio/codecs/ref_diff.py` (add `encode`/`decode`)
- Test: `python/tests/test_m93_ref_diff_unit.py` (add)

This puts together: CodecHeader + slice index + concatenated slice bodies. Slicing strategy is fixed-read-count (10K/slice).

- [ ] **Step 1: Write failing test for round-trip on 25K reads (3 slices)**

```python
# python/tests/test_m93_ref_diff_unit.py — append
import hashlib

from ttio.codecs.ref_diff import encode, decode, SLICE_SIZE_DEFAULT


def test_top_level_round_trip_three_slices():
    # 25000 reads → 3 slices of [10000, 10000, 5000]
    n_reads = 25000
    ref = b"ACGT" * 50000
    sequences = [b"ACGTACGTAC"] * n_reads
    cigars = ["10M"] * n_reads
    positions = [1 + (i % 100) for i in range(n_reads)]
    reference_md5 = hashlib.md5(ref).digest()
    reference_uri = "synthetic-test-ref"

    encoded = encode(
        sequences=sequences,
        cigars=cigars,
        positions=positions,
        reference_chrom_seq=ref,
        reference_md5=reference_md5,
        reference_uri=reference_uri,
    )
    decoded = decode(
        encoded=encoded,
        cigars=cigars,
        positions=positions,
        reference_chrom_seq=ref,
    )
    assert decoded == sequences

    # Also verify the wire-format header carries the correct counts.
    h, _ = unpack_codec_header(encoded)
    assert h.num_slices == 3
    assert h.total_reads == n_reads
    assert h.reference_md5 == reference_md5
    assert h.reference_uri == reference_uri
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement top-level encode/decode**

```python
# python/src/ttio/codecs/ref_diff.py — append
SLICE_SIZE_DEFAULT = 10_000


def encode(
    sequences: list[bytes],
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
    reference_md5: bytes,
    reference_uri: str,
    slice_size: int = SLICE_SIZE_DEFAULT,
) -> bytes:
    """Top-level REF_DIFF encoder. See module docstring for wire format.

    Args:
        sequences: list of read sequences (uppercase ACGT… bytes).
        cigars: parallel list of CIGAR strings.
        positions: parallel list of 1-based reference positions.
        reference_chrom_seq: full chromosome sequence (or covering span).
        reference_md5: 16-byte md5 of the canonical reference.
        reference_uri: URI matching the BAM header's @SQ M5 lookup key.
        slice_size: reads per slice; default 10_000 (CRAM-aligned).
    """
    if not (len(sequences) == len(cigars) == len(positions)):
        raise ValueError("sequences/cigars/positions length mismatch")

    n_reads = len(sequences)
    n_slices = (n_reads + slice_size - 1) // slice_size
    slice_blobs: list[bytes] = []
    slice_index: list[SliceIndexEntry] = []
    body_offset = 0
    for s in range(n_slices):
        lo = s * slice_size
        hi = min(lo + slice_size, n_reads)
        body = encode_slice(
            sequences[lo:hi], cigars[lo:hi], positions[lo:hi], reference_chrom_seq,
        )
        slice_index.append(SliceIndexEntry(
            body_offset=body_offset,
            body_length=len(body),
            first_position=positions[lo],
            last_position=positions[hi - 1],
            num_reads=hi - lo,
        ))
        slice_blobs.append(body)
        body_offset += len(body)

    header = pack_codec_header(CodecHeader(
        num_slices=n_slices,
        total_reads=n_reads,
        reference_md5=reference_md5,
        reference_uri=reference_uri,
    ))
    index_blob = b"".join(pack_slice_index_entry(e) for e in slice_index)
    return header + index_blob + b"".join(slice_blobs)


def decode(
    encoded: bytes,
    cigars: list[str],
    positions: list[int],
    reference_chrom_seq: bytes,
) -> list[bytes]:
    """Top-level REF_DIFF decoder."""
    h, header_size = unpack_codec_header(encoded)
    index_size = h.num_slices * SLICE_INDEX_ENTRY_SIZE
    cursor = header_size
    slice_entries = [
        unpack_slice_index_entry(encoded[cursor + i * SLICE_INDEX_ENTRY_SIZE:
                                          cursor + (i + 1) * SLICE_INDEX_ENTRY_SIZE])
        for i in range(h.num_slices)
    ]
    bodies_start = cursor + index_size
    out: list[bytes] = []
    read_cursor = 0
    for e in slice_entries:
        body = encoded[bodies_start + e.body_offset:bodies_start + e.body_offset + e.body_length]
        slice_seqs = decode_slice(
            body,
            cigars[read_cursor:read_cursor + e.num_reads],
            positions[read_cursor:read_cursor + e.num_reads],
            reference_chrom_seq,
            num_reads=e.num_reads,
        )
        out.extend(slice_seqs)
        read_cursor += e.num_reads
    return out
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Run full unit-test file as a smoke**

```bash
pytest tests/test_m93_ref_diff_unit.py -v
```

- [ ] **Step 6: Commit**

```bash
git commit -am "M93: top-level encode/decode with slice index + wire format"
```

---

### Task 8: Generate the four canonical conformance fixtures

**Files:**
- Create: `python/tests/fixtures/codecs/ref_diff_a.bin`, `_b.bin`, `_c.bin`, `_d.bin`
- Create: `python/tests/test_m93_canonical_fixtures.py`

The fixtures are byte-exact contracts for ObjC + Java to match.

- [ ] **Step 1: Write the fixture-generation script** as a fixture-fixture test

```python
# python/tests/test_m93_canonical_fixtures.py
"""Generate-and-validate the M93 REF_DIFF canonical conformance fixtures.

This test serves a dual purpose:
  - On first run (or when fixtures are absent), it WRITES the fixtures.
  - On subsequent runs, it VALIDATES that ``encode(...)`` still produces
    byte-identical fixtures — guarding against accidental wire-format
    drift in the Python reference implementation.

ObjC and Java tests then ``decode(read_fixture("ref_diff_a.bin"))`` and
verify byte-exact reconstruction.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from ttio.codecs.ref_diff import encode, decode

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "codecs"


def _ref_diff_fixture_a():
    """All matches — 100 reads of 100bp pure-ACGT against same ref."""
    ref = b"ACGT" * 250  # 1000bp
    sequences = [b"ACGTACGTAC" * 10] * 100
    cigars = ["100M"] * 100
    positions = [1] * 100
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_a_uri"


def _ref_diff_fixture_b():
    """Sparse substitutions — 1% mismatch rate over 200 reads."""
    ref = b"ACGT" * 250
    sequences = []
    cigars = ["100M"] * 200
    positions = [1] * 200
    base = bytearray(b"ACGTACGTAC" * 10)
    for i in range(200):
        s = bytearray(base)
        if i % 100 == 0:
            s[i % 100] = ord("C") if base[i % 100] != ord("C") else ord("G")
        sequences.append(bytes(s))
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_b_uri"


def _ref_diff_fixture_c():
    """Heavy indels + soft-clips."""
    ref = b"ACGTACGTAC" * 100
    sequences = [
        b"NNACGTACGTAC",       # 2S10M
        b"ACGTNNACGTAC",       # 4M2I6M
        b"ACGTACGTAC",         # 5M2D5M
    ] * 10
    cigars = ["2S10M", "4M2I6M", "5M2D5M"] * 10
    positions = [1] * 30
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_c_uri"


def _ref_diff_fixture_d():
    """Edge cases: single read, max-length cigar."""
    ref = b"ACGT" * 1000
    sequences = [b"A"]
    cigars = ["1M"]
    positions = [1]
    return sequences, cigars, positions, ref, hashlib.md5(ref).digest(), "fixture_d_uri"


FIXTURE_GENERATORS = [
    ("ref_diff_a.bin", _ref_diff_fixture_a),
    ("ref_diff_b.bin", _ref_diff_fixture_b),
    ("ref_diff_c.bin", _ref_diff_fixture_c),
    ("ref_diff_d.bin", _ref_diff_fixture_d),
]


@pytest.mark.parametrize("fname,gen", FIXTURE_GENERATORS)
def test_fixture_round_trips_and_matches_committed_bytes(fname, gen):
    sequences, cigars, positions, ref, md5, uri = gen()
    encoded = encode(sequences, cigars, positions, ref, md5, uri)

    fpath = FIXTURES_DIR / fname
    if not fpath.exists():
        FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
        fpath.write_bytes(encoded)
        pytest.skip(f"wrote new fixture {fname} (re-run to validate)")
    else:
        committed = fpath.read_bytes()
        assert encoded == committed, (
            f"{fname} drift: encode() produces different bytes than the "
            f"committed fixture. If this is intentional (wire-format change), "
            f"delete the fixture and re-run; otherwise investigate."
        )

    # Always verify round-trip
    decoded = decode(encoded, cigars, positions, ref)
    assert decoded == sequences
```

- [ ] **Step 2: Run once to write fixtures**

```bash
pytest tests/test_m93_canonical_fixtures.py -v
```
Expected: 4 SKIPPED ("wrote new fixture …").

- [ ] **Step 3: Run again to verify byte-stability**

```bash
pytest tests/test_m93_canonical_fixtures.py -v
```
Expected: 4 PASSED.

- [ ] **Step 4: Commit fixtures**

```bash
git add python/tests/fixtures/codecs/ref_diff_*.bin python/tests/test_m93_canonical_fixtures.py
git commit -m "M93: canonical conformance fixtures (a/b/c/d)"
```

---

### Task 9: Reference resolver — embedded-then-external lookup

**Files:**
- Create: `python/src/ttio/genomic/reference_resolver.py`
- Create: `python/tests/test_m93_reference_resolver.py`

- [ ] **Step 1: Write failing tests**

```python
# python/tests/test_m93_reference_resolver.py
"""Unit tests for the M93 ReferenceResolver."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path

import h5py
import pytest

from ttio.genomic.reference_resolver import (
    ReferenceResolver,
    RefMissingError,
)


@pytest.fixture
def tmp_h5(tmp_path):
    return tmp_path / "with_ref.tio"


def _seed_embedded_ref(path: Path, uri: str, chrom: str, seq: bytes, md5: bytes):
    with h5py.File(path, "w") as f:
        grp = f.create_group(f"/study/references/{uri}")
        grp.attrs["md5"] = md5.hex()
        grp.attrs["reference_uri"] = uri
        chroms = grp.create_group("chromosomes")
        c = chroms.create_group(chrom)
        c.attrs["length"] = len(seq)
        c.create_dataset("data", data=list(seq), dtype="uint8")


def test_resolver_finds_embedded_reference(tmp_h5):
    seq = b"ACGTACGTAC"
    md5 = hashlib.md5(seq).digest()
    _seed_embedded_ref(tmp_h5, "test-uri", "22", seq, md5)
    with h5py.File(tmp_h5, "r") as f:
        r = ReferenceResolver(f)
        assert r.resolve(uri="test-uri", expected_md5=md5, chromosome="22") == seq


def test_resolver_md5_mismatch_raises(tmp_h5):
    seq = b"ACGT"
    bad_md5 = b"\x00" * 16
    _seed_embedded_ref(tmp_h5, "test-uri", "22", seq, hashlib.md5(seq).digest())
    with h5py.File(tmp_h5, "r") as f:
        r = ReferenceResolver(f)
        with pytest.raises(RefMissingError, match="MD5 mismatch"):
            r.resolve(uri="test-uri", expected_md5=bad_md5, chromosome="22")


def test_resolver_external_fallback(tmp_h5, tmp_path, monkeypatch):
    # Empty file (no embedded refs).
    tmp_h5.write_bytes(b"")
    with h5py.File(tmp_h5, "w"):
        pass

    fasta_seq = b"ACGTACGT"
    fasta = tmp_path / "ref.fa"
    fasta.write_bytes(b">22\n" + fasta_seq + b"\n")
    monkeypatch.setenv("REF_PATH", str(fasta))

    md5 = hashlib.md5(fasta_seq).digest()
    with h5py.File(tmp_h5, "r") as f:
        r = ReferenceResolver(f)
        result = r.resolve(uri="any", expected_md5=md5, chromosome="22")
        assert result == fasta_seq


def test_resolver_missing_everywhere_raises(tmp_h5, monkeypatch):
    monkeypatch.delenv("REF_PATH", raising=False)
    with h5py.File(tmp_h5, "w"):
        pass
    with h5py.File(tmp_h5, "r") as f:
        r = ReferenceResolver(f)
        with pytest.raises(RefMissingError, match="not found"):
            r.resolve(uri="missing", expected_md5=b"\x00" * 16, chromosome="22")
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement the resolver**

```python
# python/src/ttio/genomic/reference_resolver.py
"""Reference resolver for the M93 REF_DIFF codec.

Lookup chain (per Q5c = hard error):
    embedded /study/references/<uri>/ in the file
        → external REF_PATH env var or explicit external_reference= arg
        → RefMissingError (no partial decode).
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path

import h5py
import numpy as np


class RefMissingError(RuntimeError):
    """Raised when a reference required for REF_DIFF decode cannot be resolved."""


class ReferenceResolver:
    """Resolve a reference chromosome sequence for REF_DIFF decode.

    Args:
        h5_file: open ``h5py.File`` handle (read-mode).
        external_reference_path: optional explicit path to a FASTA file
            that overrides ``REF_PATH`` env var.
    """

    def __init__(
        self,
        h5_file: "h5py.File",
        external_reference_path: Path | None = None,
    ):
        self._h5 = h5_file
        self._external = external_reference_path or self._env_path()

    @staticmethod
    def _env_path() -> Path | None:
        ref_path = os.environ.get("REF_PATH")
        return Path(ref_path) if ref_path else None

    def resolve(self, uri: str, expected_md5: bytes, chromosome: str) -> bytes:
        # 1. Try embedded.
        ref_grp = self._h5.get(f"/study/references/{uri}")
        if ref_grp is not None:
            embedded_md5 = bytes.fromhex(ref_grp.attrs["md5"])
            if embedded_md5 != expected_md5:
                raise RefMissingError(
                    f"MD5 mismatch for embedded reference {uri!r}: "
                    f"expected {expected_md5.hex()}, got {embedded_md5.hex()}"
                )
            chrom_grp = ref_grp.get(f"chromosomes/{chromosome}")
            if chrom_grp is None:
                raise RefMissingError(
                    f"chromosome {chromosome!r} not in embedded reference {uri!r}"
                )
            return bytes(np.asarray(chrom_grp["data"]).tobytes())

        # 2. Try external FASTA via REF_PATH or constructor arg.
        if self._external is not None and self._external.exists():
            seq = _read_chrom_from_fasta(self._external, chromosome)
            if seq is not None:
                actual_md5 = hashlib.md5(seq).digest()
                if actual_md5 != expected_md5:
                    raise RefMissingError(
                        f"MD5 mismatch for external reference at {self._external}: "
                        f"expected {expected_md5.hex()}, got {actual_md5.hex()}"
                    )
                return seq

        # 3. Hard error per Q5c.
        raise RefMissingError(
            f"reference {uri!r} (chromosome {chromosome!r}) not found in file's "
            f"/study/references/ and not resolvable via REF_PATH "
            f"({os.environ.get('REF_PATH', '<unset>')}). Provide via "
            f"external_reference_path= or set REF_PATH."
        )


def _read_chrom_from_fasta(path: Path, chromosome: str) -> bytes | None:
    """Tiny FASTA reader — extracts a single chromosome's sequence as bytes."""
    target = chromosome.encode("ascii")
    with path.open("rb") as fh:
        out = bytearray()
        in_target = False
        for line in fh:
            if line.startswith(b">"):
                if in_target:
                    return bytes(out)
                # Header line: ">chrom_name optional comment"
                hdr = line[1:].split()[0] if len(line) > 1 else b""
                in_target = (hdr == target)
            elif in_target:
                out.extend(line.strip())
        if in_target:
            return bytes(out)
    return None
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/genomic/reference_resolver.py python/tests/test_m93_reference_resolver.py
git commit -m "M93: ReferenceResolver (embedded → external → RefMissingError)"
```

---

### Task 10: M86 pipeline integration — context-aware codec hook + reference embed

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py`
- Modify: `python/src/ttio/written_genomic_run.py`
- Modify: `python/src/ttio/__init__.py` (FORMAT_VERSION)
- Create: `python/tests/test_m93_ref_diff_pipeline.py`

This is the largest task — connects the codec to the real `SpectralDataset.write_minimal` / `open` paths.

- [ ] **Step 1: Write failing integration tests**

```python
# python/tests/test_m93_ref_diff_pipeline.py
"""End-to-end M93 pipeline tests via SpectralDataset.write_minimal + open."""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset, WrittenGenomicRun
from ttio.enums import AcquisitionMode, Compression


def _build_minimal_run(
    n_reads: int = 5,
    reference_chrom_seq: bytes = b"ACGTACGTAC" * 100,
    reference_uri: str = "test-ref-uri",
) -> tuple[WrittenGenomicRun, bytes]:
    seq = b"ACGTACGTAC"
    sequences = np.frombuffer(seq * n_reads, dtype=np.uint8)
    qualities = np.full(len(sequences), 30, dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri=reference_uri,
        platform="ILLUMINA",
        sample_name="test_sample",
        positions=np.array([1] * n_reads, dtype=np.int64),
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=np.zeros(n_reads, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * 10,
        lengths=np.full(n_reads, 10, dtype=np.uint32),
        cigars=["10M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=["*"] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["22"] * n_reads,
        signal_codec_overrides={"sequences": Compression.REF_DIFF},
        embed_reference=True,
        reference_chrom_seqs={"22": reference_chrom_seq},
    )
    return run, reference_chrom_seq


def test_write_then_read_round_trip_with_ref_diff(tmp_path):
    run, ref_seq = _build_minimal_run()
    path = tmp_path / "ref_diff_round_trip.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 round trip",
        isa_investigation_id="TTIO:m93:rt",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(path) as ds:
        out_run = ds.runs["run_0001"]
        assert len(out_run) == 5
        for i in range(5):
            assert out_run[i].sequence == b"ACGTACGTAC"


def test_format_version_is_1_5(tmp_path):
    run, _ = _build_minimal_run()
    path = tmp_path / "format_version.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 fv check",
        isa_investigation_id="TTIO:m93:fv",
        runs={"run_0001": run},
    )
    import h5py
    with h5py.File(path, "r") as f:
        assert f.attrs["ttio_format_version"] == "1.5"


def test_embedded_reference_present_at_canonical_path(tmp_path):
    run, ref_seq = _build_minimal_run()
    path = tmp_path / "embedded_ref.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 embed",
        isa_investigation_id="TTIO:m93:e",
        runs={"run_0001": run},
    )
    import h5py
    with h5py.File(path, "r") as f:
        ref_grp = f["/study/references/test-ref-uri"]
        assert ref_grp.attrs["md5"] == hashlib.md5(ref_seq).digest().hex()
        chrom_data = bytes(np.asarray(ref_grp["chromosomes/22/data"]).tobytes())
        assert chrom_data == ref_seq


def test_two_runs_sharing_reference_dedupe(tmp_path):
    """Q6 = C: auto-dedup. Two runs with the same reference_uri share storage."""
    run_a, ref = _build_minimal_run(reference_uri="shared-uri")
    run_b, _ = _build_minimal_run(reference_uri="shared-uri")
    path = tmp_path / "dedup.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 dedup",
        isa_investigation_id="TTIO:m93:d",
        runs={"run_a": run_a, "run_b": run_b},
    )
    import h5py
    with h5py.File(path, "r") as f:
        # Only ONE reference group should exist.
        ref_grps = list(f["/study/references"].keys())
        assert ref_grps == ["shared-uri"]


def test_ref_diff_falls_back_to_base_pack_when_no_ref(tmp_path):
    """Q5b = C: per-channel @compression reflects what was actually applied."""
    run, _ = _build_minimal_run()
    # Drop the reference so the writer can't apply REF_DIFF
    object.__setattr__(run, "reference_chrom_seqs", None)
    object.__setattr__(run, "embed_reference", False)
    path = tmp_path / "fallback.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 fallback",
        isa_investigation_id="TTIO:m93:f",
        runs={"run_0001": run},
    )
    import h5py
    with h5py.File(path, "r") as f:
        seqs_ds = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        assert int(seqs_ds.attrs["compression"]) == int(Compression.BASE_PACK)


def test_ref_missing_at_read_raises(tmp_path):
    """Q5c = A: hard error when ref unresolvable at read time."""
    run, _ = _build_minimal_run()
    path = tmp_path / "missing_at_read.tio"
    SpectralDataset.write_minimal(
        path, title="m93 missing", isa_investigation_id="TTIO:m93:m",
        runs={"run_0001": run},
    )
    # Surgically delete the embedded reference group
    import h5py
    with h5py.File(path, "r+") as f:
        del f["/study/references/test-ref-uri"]

    from ttio.genomic.reference_resolver import RefMissingError
    with SpectralDataset.open(path) as ds:
        with pytest.raises(RefMissingError, match="not found"):
            _ = ds.runs["run_0001"][0].sequence
```

- [ ] **Step 2: Run, expect FAIL** (multiple — `WrittenGenomicRun` doesn't have `embed_reference`/`reference_chrom_seqs`, M86 pipeline doesn't dispatch context-aware, format version still 1.4)

- [ ] **Step 3: Extend `WrittenGenomicRun`**

```python
# python/src/ttio/written_genomic_run.py — append to dataclass body
@dataclass(slots=True)
class WrittenGenomicRun:
    # ... existing fields above ...

    # M93 v1.2 — reference embed for REF_DIFF codec
    embed_reference: bool = True
    """When True (default), the writer embeds the covered chromosome
    sequences at /study/references/<reference_uri>/ and REF_DIFF can
    apply. When False, the writer skips embedding and REF_DIFF falls
    back per-channel to BASE_PACK."""

    reference_chrom_seqs: dict[str, bytes] | None = None
    """Mapping chromosome → uppercase ACGTN bytes. Required when
    embed_reference=True and signal_codec_overrides selects REF_DIFF."""

    external_reference_path: Path | None = None
    """When embed_reference=False, the user-side path to a FASTA file
    used at decode time. Stored only in @reference_uri and the BAM
    header lookup; not embedded in the .tio."""
```

- [ ] **Step 4: Bump format version**

```python
# python/src/ttio/__init__.py
__version__ = "1.2.0"
FORMAT_VERSION = "1.5"   # M93 v1.2
```

- [ ] **Step 5: Add the M86 pipeline context-aware hook + reference embed**

```python
# python/src/ttio/spectral_dataset.py — locate the existing
# write_genomic_run_subtree function (~line 1700) and add:

import hashlib
from ttio.codecs._codec_meta import is_context_aware
from ttio.codecs.ref_diff import encode as ref_diff_encode

def _embed_reference_if_needed(h5_root, run: "WrittenGenomicRun") -> bytes:
    """Embed (or dedupe) the run's reference and return the md5."""
    if not run.embed_reference or run.reference_chrom_seqs is None:
        return b""
    ref_grp_path = f"/study/references/{run.reference_uri}"
    md5 = hashlib.md5(
        b"".join(run.reference_chrom_seqs[c] for c in sorted(run.reference_chrom_seqs))
    ).digest()
    if ref_grp_path in h5_root:
        # Auto-dedup: the URI is already embedded by another run in this file.
        existing_md5 = bytes.fromhex(h5_root[ref_grp_path].attrs["md5"])
        if existing_md5 != md5:
            raise ValueError(
                f"reference_uri {run.reference_uri!r} already embedded with "
                f"different MD5 — cannot dedupe"
            )
        return md5
    grp = h5_root.create_group(ref_grp_path)
    grp.attrs["md5"] = md5.hex()
    grp.attrs["reference_uri"] = run.reference_uri
    chroms_grp = grp.create_group("chromosomes")
    for chrom_name, seq in sorted(run.reference_chrom_seqs.items()):
        c = chroms_grp.create_group(chrom_name)
        c.attrs["length"] = len(seq)
        c.create_dataset("data", data=np.frombuffer(seq, dtype=np.uint8))
    return md5


def _encode_sequences_channel(
    sequences_bytes: bytes,
    codec: Compression,
    run: "WrittenGenomicRun",
    reference_md5: bytes,
) -> tuple[bytes, Compression]:
    """Apply the codec; if REF_DIFF can't run (no ref), fall back to BASE_PACK
    and return the actual codec applied (for @compression attr)."""
    if codec != Compression.REF_DIFF:
        return _existing_codec_apply(sequences_bytes, codec), codec
    if run.reference_chrom_seqs is None:
        # Per Q5b = C: fall back to BASE_PACK on this channel.
        from ttio.codecs.base_pack import encode as base_pack_encode
        return base_pack_encode(sequences_bytes), Compression.BASE_PACK
    # Build per-read chromosome → seq map and encode
    encoded = ref_diff_encode(
        sequences=_split_by_offsets(sequences_bytes, run.offsets, run.lengths),
        cigars=run.cigars,
        positions=list(run.positions),
        reference_chrom_seq=_select_chrom_seq(run),
        reference_md5=reference_md5,
        reference_uri=run.reference_uri,
    )
    return encoded, Compression.REF_DIFF


# Wire into write_genomic_run_subtree:
#   1. call _embed_reference_if_needed → md5
#   2. for each codec-eligible channel, dispatch context-aware via
#      is_context_aware()
#   3. set @compression on the dataset to the actual codec applied
#   4. bump @ttio_format_version on root
```

(The skeleton above is illustrative — the implementer wires it into the existing `write_genomic_run_subtree` carefully, preserving all M82–M91 behaviour for non-REF_DIFF codecs. The detailed touch list:
- Wrap codec application in a `_dispatch_codec(channel_name, channel_data, codec, context)` helper that branches on `is_context_aware`.
- For REF_DIFF specifically: route through `ref_diff.encode(...)` with positions/cigars/ref.
- Update `@ttio_format_version` at root from `1.4` to `1.5`.
- For M86 default selection: when `signal_codec_overrides` is empty AND `signal_compression == "gzip"`, apply `DEFAULT_CODECS_V1_5`.)

- [ ] **Step 6: Add the read-side dispatch in `GenomicRun`**

In `python/src/ttio/genomic_run.py`, locate where the `sequences` channel is decoded; add:

```python
def _decode_sequences_channel(self) -> bytes:
    codec_id = int(self._signal_channels["sequences"].attrs.get("compression", 0))
    raw = self._signal_channels["sequences"][...].tobytes()
    if codec_id == int(Compression.REF_DIFF):
        from ttio.codecs.ref_diff import decode as ref_diff_decode
        from ttio.genomic.reference_resolver import ReferenceResolver
        resolver = ReferenceResolver(self._h5_file)
        # Resolve every chromosome touched
        ref_seq = resolver.resolve(
            uri=self._reference_uri,
            expected_md5=self._reference_md5,
            chromosome=self._chromosome_for_run(),  # for chr22-only runs; multi-chrom needs per-read dispatch
        )
        return b"".join(ref_diff_decode(
            encoded=raw,
            cigars=list(self._signal_channels["cigars"][...]),
            positions=list(self._signal_channels["positions"][...]),
            reference_chrom_seq=ref_seq,
        ))
    # ... existing codec dispatch for codecs 0-8 ...
```

- [ ] **Step 7: Run tests, expect PASS**

```bash
pytest tests/test_m93_ref_diff_pipeline.py -v
```

- [ ] **Step 8: Run the full Python test suite to catch regressions**

```bash
pytest 2>&1 | tail -20
```
Expected: same baseline + the new M93 tests passing. No regressions in M82–M91.

- [ ] **Step 9: Commit**

```bash
git add python/src/ttio/spectral_dataset.py python/src/ttio/written_genomic_run.py \
        python/src/ttio/__init__.py python/src/ttio/genomic_run.py \
        python/tests/test_m93_ref_diff_pipeline.py
git commit -m "M93: M86 pipeline integration + ref-embed + format-version 1.5"
```

---

### Task 11: M86 default-codec selection — `DEFAULT_CODECS_V1_5`

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py` (or a new `python/src/ttio/genomic/_default_codecs.py`)
- Test: `python/tests/test_m93_ref_diff_pipeline.py` (add)

Per Q5a = B: when user passes `signal_compression="gzip"` (or doesn't specify) AND `signal_codec_overrides` is empty, the writer applies the v1.5 default stack on every applicable channel. M93 only needs `sequences → REF_DIFF`; the rest of the defaults land in M94/M95.

- [ ] **Step 1: Write failing test**

```python
# python/tests/test_m93_ref_diff_pipeline.py — append
def test_default_v1_5_applies_ref_diff_on_sequences_when_ref_provided(tmp_path):
    run, _ = _build_minimal_run()
    # Drop the explicit override; rely on the default
    object.__setattr__(run, "signal_codec_overrides", {})
    path = tmp_path / "default.tio"
    SpectralDataset.write_minimal(
        path, title="defaults", isa_investigation_id="TTIO:def",
        runs={"run_0001": run},
    )
    import h5py
    with h5py.File(path, "r") as f:
        seqs_ds = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        assert int(seqs_ds.attrs["compression"]) == int(Compression.REF_DIFF)
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement `DEFAULT_CODECS_V1_5` lookup**

```python
# python/src/ttio/genomic/_default_codecs.py
"""v1.5 default codec stack per spec §6 (Q5a = B)."""
from __future__ import annotations

from ttio.enums import Compression

# M93 only — extended by M94/M95.
DEFAULT_CODECS_V1_5 = {
    "sequences": Compression.REF_DIFF,  # falls back to BASE_PACK if no ref
}


def default_codec_for(channel_name: str) -> Compression | None:
    return DEFAULT_CODECS_V1_5.get(channel_name)
```

In `spectral_dataset.py`, when iterating channels: if `signal_codec_overrides[channel_name]` not set AND `signal_compression == "gzip"`, look up `default_codec_for(channel_name)`. If found, use it. Else fall back to gzip (existing behaviour).

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -am "M93: DEFAULT_CODECS_V1_5 — sequences → REF_DIFF by default"
```

---

### Task 12: Performance smoke test

**Files:**
- Create: `python/tests/perf/test_m93_throughput.py`

- [ ] **Step 1: Write the perf smoke**

```python
# python/tests/perf/test_m93_throughput.py
"""M93 REF_DIFF throughput regression smoke."""
import time
import numpy as np
import pytest

from ttio.codecs.ref_diff import encode as ref_diff_encode

MIN_ENCODE_MBPS = 5.0  # Python lower bound per spec §10


@pytest.mark.perf
def test_ref_diff_encode_at_least_5_mbps_on_100k_reads():
    n = 100_000
    ref = b"ACGT" * 25_000
    sequences = [b"ACGTACGTAC"] * n
    cigars = ["10M"] * n
    positions = [1] * n

    t0 = time.perf_counter()
    encoded = ref_diff_encode(
        sequences, cigars, positions, ref, b"\x00" * 16, "perf-uri",
    )
    elapsed = time.perf_counter() - t0

    raw_mb = sum(len(s) for s in sequences) / 1e6
    mbps = raw_mb / elapsed
    print(f"\n[m93 perf] {n} reads, {raw_mb:.2f} MB raw → {len(encoded) / 1e6:.2f} MB encoded in {elapsed:.2f}s ({mbps:.1f} MB/s)")
    assert mbps >= MIN_ENCODE_MBPS, f"REF_DIFF encode at {mbps:.1f} MB/s, need ≥{MIN_ENCODE_MBPS}"
```

- [ ] **Step 2: Run with `-s` to see the throughput**

```bash
pytest tests/perf/test_m93_throughput.py -v -s -m perf
```
Expected: PASS with throughput printed.

- [ ] **Step 3: Commit**

```bash
git add python/tests/perf/test_m93_throughput.py
git commit -m "M93: throughput regression smoke (≥5 MB/s encode)"
```

---

## Phase 2 — Objective-C normative parity (Tasks 13–19)

ObjC is the **normative** implementation per `ARCHITECTURE.md`. The byte stream Python produced becomes the contract; ObjC must decode all four canonical fixtures (`ref_diff_a.bin..d.bin`) byte-exact and round-trip every input identically.

### Task 13: TTIORefDiff.h public API

**Files:**
- Modify: `objc/Source/HDF5/TTIOEnums.h` (add `TTIOCompressionRefDiff = 9`)
- Create: `objc/Source/Codecs/TTIORefDiff.h`
- Create: `objc/Tests/TestM93RefDiffUnit.m` (initial scaffold)

- [ ] **Step 1: Write failing test (the scaffold + enum check)**

```objc
// objc/Tests/TestM93RefDiffUnit.m
#import <Foundation/Foundation.h>
#import "TTIOEnums.h"
#import "TTIORefDiff.h"
#import "TestRunner.h"

void test_TTIOCompressionRefDiff_is_9(void) {
    TEST_ASSERT_EQ((NSInteger)TTIOCompressionRefDiff, (NSInteger)9);
}

void test_TTIORefDiff_class_exists(void) {
    Class c = NSClassFromString(@"TTIORefDiff");
    TEST_ASSERT_NOT_NIL(c);
}
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Add the enum + create the header**

```objc
// objc/Source/HDF5/TTIOEnums.h — extend TTIOCompression
typedef NS_ENUM(NSInteger, TTIOCompression) {
    TTIOCompressionNone = 0,
    TTIOCompressionZlib = 1,
    TTIOCompressionLZ4 = 2,
    TTIOCompressionNumpressDelta = 3,
    TTIOCompressionRansOrder0 = 4,
    TTIOCompressionRansOrder1 = 5,
    TTIOCompressionBasePack = 6,
    TTIOCompressionQualityBinned = 7,
    TTIOCompressionNameTokenized = 8,
    TTIOCompressionRefDiff = 9,           // M93
};
```

```objc
// objc/Source/Codecs/TTIORefDiff.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// REF_DIFF codec (M93) — reference-based sequence diff.
///
/// Wire format and algorithm in
/// `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md` §3.
/// This is the normative implementation; Python (`ttio.codecs.ref_diff`)
/// and Java (`global.thalion.ttio.codecs.RefDiff`) decode the bytes this
/// class produces byte-for-byte.
@interface TTIORefDiff : NSObject

/// Encode a slice of reads against a reference. See spec for arguments.
+ (NSData *)encodeWithSequences:(NSArray<NSData *> *)sequences
                         cigars:(NSArray<NSString *> *)cigars
                      positions:(NSArray<NSNumber *> *)positions
              referenceChromSeq:(NSData *)referenceChromSeq
                   referenceMD5:(NSData *)referenceMD5
                   referenceURI:(NSString *)referenceURI
                          error:(NSError **)error;

/// Decode the byte stream into per-read sequences.
+ (nullable NSArray<NSData *> *)decodeData:(NSData *)encoded
                                    cigars:(NSArray<NSString *> *)cigars
                                 positions:(NSArray<NSNumber *> *)positions
                         referenceChromSeq:(NSData *)referenceChromSeq
                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 4: Add `TTIORefDiff.m` skeleton**

```objc
// objc/Source/Codecs/TTIORefDiff.m
#import "TTIORefDiff.h"

@implementation TTIORefDiff

+ (NSData *)encodeWithSequences:(NSArray<NSData *> *)sequences
                         cigars:(NSArray<NSString *> *)cigars
                      positions:(NSArray<NSNumber *> *)positions
              referenceChromSeq:(NSData *)referenceChromSeq
                   referenceMD5:(NSData *)referenceMD5
                   referenceURI:(NSString *)referenceURI
                          error:(NSError **)error {
    [NSException raise:@"NotImplemented" format:@"M93 task 13 stub"];
    return nil;
}

+ (nullable NSArray<NSData *> *)decodeData:(NSData *)encoded
                                    cigars:(NSArray<NSString *> *)cigars
                                 positions:(NSArray<NSNumber *> *)positions
                         referenceChromSeq:(NSData *)referenceChromSeq
                                     error:(NSError **)error {
    [NSException raise:@"NotImplemented" format:@"M93 task 13 stub"];
    return nil;
}

@end
```

- [ ] **Step 5: Add to GNUmakefile + run tests**

```bash
cd objc && make CC=clang OBJC=clang check 2>&1 | grep -E "RefDiff|test_TTIOCompressionRefDiff|test_TTIORefDiff_class"
```
Expected: 2 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add objc/Source/HDF5/TTIOEnums.h objc/Source/Codecs/TTIORefDiff.h objc/Source/Codecs/TTIORefDiff.m objc/Tests/TestM93RefDiffUnit.m
git commit -m "M93/objc: TTIOCompressionRefDiff=9 enum + TTIORefDiff stub"
```

---

### Task 14: ObjC wire-format header pack/unpack

**Files:**
- Modify: `objc/Source/Codecs/TTIORefDiff.m`
- Modify: `objc/Tests/TestM93RefDiffUnit.m`

- [ ] **Step 1: Write failing test that decodes Python's `ref_diff_a.bin` header**

```objc
// objc/Tests/TestM93RefDiffUnit.m — add
void test_unpack_codec_header_from_python_fixture_a(void) {
    NSString *fpath = [[NSBundle bundleForClass:[TTIORefDiff class]]
        pathForResource:@"ref_diff_a" ofType:@"bin" inDirectory:@"codecs"];
    NSData *blob = [NSData dataWithContentsOfFile:fpath];
    TEST_ASSERT_NOT_NIL(blob);

    NSError *err = nil;
    TTIORefDiffCodecHeader *h = nil;
    NSUInteger consumed = 0;
    BOOL ok = [TTIORefDiff unpackCodecHeaderFromData:blob
                                              header:&h
                                            consumed:&consumed
                                               error:&err];
    TEST_ASSERT_TRUE(ok);
    TEST_ASSERT_EQ((NSInteger)h.numSlices, 1);
    TEST_ASSERT_EQ((NSInteger)h.totalReads, 100);
    TEST_ASSERT_EQ_STR([h.referenceURI UTF8String], "fixture_a_uri");
}
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement the header pack/unpack**

(Full code mirrors the Python implementation in Task 2. Wire format is identical: little-endian, 38 + N bytes. Use `OSReadLittleInt32` / `OSReadLittleInt64` from `<libkern/OSByteOrder.h>` for portability. Define `TTIORefDiffCodecHeader` and `TTIORefDiffSliceIndexEntry` as plain Objective-C classes with the corresponding properties.)

```objc
// In TTIORefDiff.m — define helper class
@interface TTIORefDiffCodecHeader : NSObject
@property (nonatomic) uint32_t numSlices;
@property (nonatomic) uint64_t totalReads;
@property (nonatomic, copy) NSData *referenceMD5;     // 16 bytes
@property (nonatomic, copy) NSString *referenceURI;
@end

// pack:
static NSData *PackCodecHeader(TTIORefDiffCodecHeader *h) {
    NSData *uriData = [h.referenceURI dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *out = [NSMutableData dataWithCapacity:38 + uriData.length];
    [out appendBytes:"RDIF" length:4];
    uint8_t version = 1;
    [out appendBytes:&version length:1];
    uint8_t reserved[3] = {0, 0, 0};
    [out appendBytes:reserved length:3];
    uint32_t numSlicesLE = OSSwapHostToLittleInt32(h.numSlices);
    [out appendBytes:&numSlicesLE length:4];
    uint64_t totalReadsLE = OSSwapHostToLittleInt64(h.totalReads);
    [out appendBytes:&totalReadsLE length:8];
    [out appendData:h.referenceMD5];
    uint16_t uriLen = OSSwapHostToLittleInt16((uint16_t)uriData.length);
    [out appendBytes:&uriLen length:2];
    [out appendData:uriData];
    return out;
}
// unpack: corresponding inverse using OSReadLittleInt*
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git commit -am "M93/objc: codec header pack/unpack matching Python wire format"
```

---

### Task 15: ObjC CIGAR walker + reverse walker

Mirrors Task 3 + 4. Same algorithm, NSData/NSString plumbing. Test against the same parametrised cases (`AAAAAAAAAA`/`AAAAA`/5M/1, etc.).

**Files:**
- Modify: `objc/Source/Codecs/TTIORefDiff.m`
- Modify: `objc/Tests/TestM93RefDiffUnit.m`

- [ ] **Step 1-3: Write failing tests, implement, verify**

(Code structure: a static C function `WalkReadAgainstRef(NSData *seq, NSString *cigar, int64_t pos, NSData *ref, OUT walkResult)` returning a small struct with NSData fields. Cigar parsing via `NSScanner` + `unichar` whitelist. NSScanner's character-by-character scan is straightforward.)

- [ ] **Step 4-5: Commit**

```bash
git commit -am "M93/objc: cigar walker + reverse walker (matches python a/b/c/d cases)"
```

---

### Task 16: ObjC slice encoder/decoder + bit-pack

**Files:**
- Modify: `objc/Source/Codecs/TTIORefDiff.m`
- Modify: `objc/Tests/TestM93RefDiffUnit.m`

Mirrors Tasks 5 + 6. Uses existing `TTIORans` for the rANS layer.

- [ ] **Step 1-3: Tests, implementation, verify**
- [ ] **Step 4: Commit** — `git commit -am "M93/objc: slice encoder/decoder via TTIORans"`

---

### Task 17: ObjC top-level encode/decode + canonical fixture validation

**Files:**
- Modify: `objc/Source/Codecs/TTIORefDiff.m`
- Modify: `objc/Tests/TestM93RefDiffUnit.m`
- Add: `objc/Tests/Fixtures/codecs/ref_diff_*.bin` (verbatim copies)

- [ ] **Step 1: Copy fixtures**

```bash
cp python/tests/fixtures/codecs/ref_diff_*.bin objc/Tests/Fixtures/codecs/
md5sum python/tests/fixtures/codecs/ref_diff_*.bin objc/Tests/Fixtures/codecs/ref_diff_*.bin
# All four md5s should match between python and objc directories
```

- [ ] **Step 2: Write failing test that decodes each Python fixture**

```objc
// TestM93RefDiffUnit.m
void test_decode_python_fixture_a_byte_exact_round_trip(void) {
    NSString *fpath = [[NSBundle bundleForClass:[TTIORefDiff class]]
        pathForResource:@"ref_diff_a" ofType:@"bin" inDirectory:@"codecs"];
    NSData *fixture = [NSData dataWithContentsOfFile:fpath];
    // Reproduce the Python fixture's input parameters
    NSData *ref = [...];  // b"ACGT" * 250
    NSArray *cigars = [...];  // ["100M"] * 100
    NSArray *positions = [...];  // [1] * 100
    NSArray<NSData *> *expectedSequences = [...];  // [b"ACGT"*25] * 100

    NSError *err = nil;
    NSArray<NSData *> *decoded = [TTIORefDiff decodeData:fixture
                                                 cigars:cigars
                                              positions:positions
                                      referenceChromSeq:ref
                                                  error:&err];
    TEST_ASSERT_NIL(err);
    TEST_ASSERT_EQ_INT(decoded.count, 100);
    for (NSUInteger i = 0; i < 100; i++) {
        TEST_ASSERT_TRUE([decoded[i] isEqualToData:expectedSequences[i]]);
    }
}
// repeat for b, c, d
```

- [ ] **Step 3: Implement top-level encode/decode + run tests**

- [ ] **Step 4: Cross-check ObjC encode produces byte-identical fixture**

Add a separate test that calls `[TTIORefDiff encode...]` with the same inputs and asserts `[encoded isEqualToData:fixture]`. This is the byte-exact cross-language guarantee.

- [ ] **Step 5: Commit**

```bash
git add objc/Source/Codecs/TTIORefDiff.{h,m} objc/Tests/TestM93RefDiffUnit.m objc/Tests/Fixtures/codecs/ref_diff_*.bin
git commit -m "M93/objc: top-level encode/decode + 4 canonical fixture round-trips byte-exact"
```

---

### Task 18: ObjC `TTIOReferenceResolver`

Mirrors Task 9. `TTIOReferenceResolver.{h,m}` wrapping the embedded HDF5 lookup + external FASTA fallback. NSError out-param on failure (`TTIORefMissingError` domain).

- [ ] **Step 1-4: Tests + impl + commit**

```bash
git commit -am "M93/objc: TTIOReferenceResolver embedded → external → NSError"
```

---

### Task 19: ObjC M86 pipeline integration

Mirrors Task 10 + 11. Wire REF_DIFF into `TTIOSpectralDataset.m`'s genomic-run write/read paths. Add `embedReference` and `referenceChromSeqs:(NSDictionary<NSString*, NSData*> *)` to `TTIOWrittenGenomicRun`. Bump `kTTIOFormatVersionM82 = @"1.4"` → add `kTTIOFormatVersionM93 = @"1.5"` and use it when REF_DIFF or any v1.5 default applies.

- [ ] **Step 1-4: Tests (round-trip via writeMinimalToPath:), impl, run, commit**

```bash
git commit -am "M93/objc: TTIOSpectralDataset M86 hook + reference embed + v1.5 format"
```

---

## Phase 3 — Java parity (Tasks 20–26)

Java mirrors the ObjC pattern. Key challenge: Java's lack of unsigned integers requires `long` + `& 0xFFFFFFFFL` discipline throughout the rANS path; M83's existing `Rans.java` already establishes the convention. Use `byte[]` over `NSData`; use `record` types over Objective-C classes for header/slice-index pure-data containers.

### Task 20: `Compression.REF_DIFF` enum + RefDiff class skeleton + header pack/unpack

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/Enums.java`
- Create: `java/src/main/java/global/thalion/ttio/codecs/RefDiff.java`
- Create: `java/src/test/java/global/thalion/ttio/codecs/RefDiffUnitTest.java`

- [ ] **Step 1-4: Tests for enum + header pack/unpack matching Python fixture**

(Header pack/unpack uses `java.nio.ByteBuffer` with `LITTLE_ENDIAN` order.)

- [ ] **Step 5: Commit**

```bash
git commit -am "M93/java: REF_DIFF=9 + header pack/unpack via ByteBuffer LE"
```

---

### Task 21: Java CIGAR walker + reverse walker

Mirrors Tasks 3 + 4 + 15. Same algorithm. CIGAR parsing: precompiled `Pattern.compile("(\\d+)([MIDNSHP=X])")`.

- [ ] **Step 1-4: Tests + impl + commit** — `git commit -am "M93/java: cigar walker + reverse walker"`

---

### Task 22: Java slice encode/decode + bit-pack

Mirrors Tasks 5 + 6 + 16. Uses existing `Rans.encode` / `decode`.

- [ ] **Step 1-4: Tests + impl + commit** — `git commit -am "M93/java: slice encoder/decoder + bit-pack"`

---

### Task 23: Java top-level encode/decode + canonical fixture validation

Mirrors Task 17. Copy `ref_diff_*.bin` to `java/src/test/resources/ttio/codecs/`. Validate `md5sum` matches Python + ObjC. Implement top-level encode/decode. Verify round-trip on all four fixtures.

- [ ] **Step 1: Copy + verify md5 across all three repos**

```bash
md5sum python/tests/fixtures/codecs/ref_diff_*.bin \
       objc/Tests/Fixtures/codecs/ref_diff_*.bin \
       java/src/test/resources/ttio/codecs/ref_diff_*.bin
```
Expected: identical md5s in groups of 3 per fixture name.

- [ ] **Step 2-5: Tests, impl, run, commit** — `git commit -am "M93/java: top-level encode/decode + 4 fixture round-trips"`

---

### Task 24: Java `ReferenceResolver`

Mirrors Tasks 9 + 18.

- [ ] **Step 1-4: Tests + impl + commit** — `git commit -am "M93/java: ReferenceResolver"`

---

### Task 25: Java M86 pipeline integration

Mirrors Tasks 10 + 11 + 19. `WrittenGenomicRun` record gains `embedReference` + `referenceChromSeqs` + `externalReferencePath` fields (with delegating builder). `SpectralDataset.write_minimal` + `open` paths plumb them.

- [ ] **Step 1-4: Tests + impl + run + commit** — `git commit -am "M93/java: SpectralDataset pipeline hook + ref embed + v1.5"`

---

### Task 26: Run full Java test suite for regression check

```bash
cd java && mvn test 2>&1 | tail -20
```
Expected: previous baseline (~755) + M93 tests passing. No regressions.

- [ ] **Step 1: Run + verify**

---

## Phase 4 — Cross-language conformance + integration (Tasks 27–30)

### Task 27: 3×3 cross-language conformance matrix

**Files:**
- Create: `python/tests/integration/test_m93_3x3_matrix.py`
- Create: `python/tests/fixtures/genomic/m93_simple.tio` (Python writes; ObjC + Java read)

The matrix exercises each (writer, reader) cell across {Python, ObjC, Java}. Mirrors `test_m82_3x3_matrix.py`.

- [ ] **Step 1: Write the test scaffold** (Python writes + ObjC subprocess decodes via `TtioBamDump` extended for M93; Java subprocess via `BamDump`)
- [ ] **Step 2: Run** → 9 cells PASS
- [ ] **Step 3: Commit** — `git commit -am "M93: 3×3 cross-language conformance matrix"`

---

### Task 28: M51 byte-parity harness extension

**Files:**
- Modify: `python/tests/test_compound_writer_parity.py`

Add `test_m93_ref_diff_byte_parity` — Python / Java / ObjC produce byte-identical `sequences` channel after REF_DIFF round-trip on the M93 reference fixtures. Calls each language's dumper subprocess and compares.

- [ ] **Step 1-3: Test + run + commit** — `git commit -am "M93: extend M51 harness with REF_DIFF byte-parity check"`

---

### Task 29: Compression-gate integration test

**Files:**
- Create: `python/tests/integration/test_m93_compression_gate.py`

Runs the actual chr22 fixture through TTI-O with REF_DIFF enabled and asserts the compressed `sequences` channel size is within expected bounds. **Skips** if `data/genomic/na12878/na12878.chr22.lean.bam` is absent.

- [ ] **Step 1: Test**

```python
# python/tests/integration/test_m93_compression_gate.py
"""M93 acceptance gate — REF_DIFF closes ~80% of the chr22 sequences gap."""
import pytest
from pathlib import Path

CHR22_BAM = Path("data/genomic/na12878/na12878.chr22.lean.bam")


@pytest.mark.skipif(not CHR22_BAM.exists(), reason="chr22 fixture not present")
def test_chr22_sequences_channel_under_15mb_with_ref_diff():
    # Build .tio with REF_DIFF and measure the sequences dataset size.
    # Pre-M93: sequences was ~45 MB (BASE_PACK).
    # Post-M93 expectation: ~5–10 MB.
    raise NotImplementedError(
        "Stub: implement once tools/benchmarks/cli.py supports per-channel measurement"
    )
```

(Initial form: stub. Post-M94/M95 the gate becomes the full ≤1.15× CRAM ratio test.)

- [ ] **Step 2: Run, expect SKIP if no fixture; else PASS**
- [ ] **Step 3: Commit** — `git commit -am "M93: compression-gate stub — chr22 sequences ≤15 MB"`

---

### Task 30: Full benchmark re-run on chr22 lean

**Files:**
- Run: `python -m tools.benchmarks.cli run --dataset chr22_na12878_lean --formats ttio --report docs/benchmarks/m93-after.md`

- [ ] **Step 1: Run + compare against pre-M93 baseline**

Expected change in TTI-O total size: ~217 MB → ~177 MB (drops by ~40 MB on the sequences channel as REF_DIFF replaces BASE_PACK).

If the actual result diverges by >5 MB from prediction, investigate before declaring M93 done.

- [ ] **Step 2: Commit the post-M93 report** — `git commit -am "docs: m93-after benchmark report (TTI-O sequences via REF_DIFF)"`

---

## Phase 5 — Documentation (Tasks 31–33)

### Task 31: `docs/codecs/ref_diff.md` — full M93 codec spec

**Files:**
- Create: `docs/codecs/ref_diff.md` (~300 lines, mirroring `base_pack.md` structure)

Sections: Status, Algorithm (with worked examples), Wire format diagrams, Slicing, Reference storage in HDF5, Cross-language conformance contract, Per-language performance numbers, Public API in each language, Binding decisions §80a-c.

- [ ] **Step 1: Write the doc**
- [ ] **Step 2: Cross-check against the spec doc and the implementation**
- [ ] **Step 3: Commit** — `git commit -am "docs: codecs/ref_diff.md (M93)"`

---

### Task 32: `docs/format-spec.md` §10.10 + codec table update

**Files:**
- Modify: `docs/format-spec.md`

Add §10.10 (REF_DIFF) describing the on-disk shape: `@compression == 9` on `signal_channels/sequences`, paired with `/study/references/<reference_uri>/`. Update §10.4 codec-id table. Bump format-version table to include 1.5.

- [ ] **Step 1: Modify** + **Step 2: Commit** — `git commit -am "docs: format-spec.md §10.10 REF_DIFF + format-version 1.5"`

---

### Task 33: `WORKPLAN.md`, `CHANGELOG.md`, `ARCHITECTURE.md` updates

**Files:**
- Modify: `WORKPLAN.md` (add Phase 9 / M93)
- Modify: `CHANGELOG.md` (M93 entry under `[Unreleased]`)
- Modify: `ARCHITECTURE.md` (genomic codec stack section + context-aware codec interface note)

- [ ] **Step 1: Modify all three** + **Step 2: Commit** — `git commit -am "docs: WORKPLAN/CHANGELOG/ARCHITECTURE for M93"`

---

## Self-review checklist (run after all tasks)

- [ ] **Spec coverage:** Every section of the M93 design (`docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md` §3) maps to at least one task. Re-read §3 + §6 + §11 (REF_DIFF rows) and confirm.
- [ ] **Cross-language byte-exactness:** All four canonical fixtures decode byte-exact in Python, ObjC, and Java; the 3×3 matrix is green.
- [ ] **Format-version bump:** `@ttio_format_version == "1.5"` on M93-written files.
- [ ] **Defaults:** Empty `signal_codec_overrides` + `signal_compression="gzip"` + reference provided → `sequences` gets `@compression = 9`.
- [ ] **Fallbacks:** Same scenario *without* reference → `sequences` gets `@compression = 6` (BASE_PACK), no error.
- [ ] **Read-time error:** Surgically removing `/study/references/<uri>/` from a written file → `RefMissingError` on first sequence access.
- [ ] **No regressions:** Full Python + ObjC + Java test suites pass at their pre-M93 baselines (1324 / 3070 / 755) + M93 additions.
- [ ] **Compression gate:** `tools/benchmarks/cli.py run --dataset chr22_na12878_lean --formats ttio` reports TTI-O total down by ~40 MB vs the pre-M93 baseline (sequences channel only — qualities and integer channels unchanged until M94/M95).

---

## Plan complete

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
