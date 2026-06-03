# Codec Registry + CodecContext (Python) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Python's scattered codec dispatch (decode/encode ladders + four bespoke side-paths + the `_codec_meta` set) with a single `Codec` registry keyed by `Compression` id, fronted by a uniform `Codec` interface, a `CodecContext` value object, and closed `DecodedChannel`/`EncodedChannel` unions — with **zero wire/format change** and no perf regression.

**Architecture:** New value objects in `codecs/_context.py`; a `Codec` protocol + `CODEC_REGISTRY` + thin per-codec adapters in `codecs/_registry.py`. Plain codecs (rans O0/O1, base_pack, quality, delta_rans) are thin wrappers; context-aware codecs (fqzcomp, name_tok, mate_info, ref_diff) pull from `CodecContext`. The genomic decode/encode call sites collapse to one registry lookup per direction; per-channel decode caches and the whole-channel-decode strategy are preserved.

**Tech Stack:** Python 3.12, numpy, pytest, h5py; native `libttio_rans` (set `TTIO_RANS_LIB_PATH`). Build/test in WSL Ubuntu at `~/TTI-O`; push from Windows git. Spec: `docs/superpowers/specs/2026-06-02-codec-registry-design.md`.

**Branch:** `feat/codec-registry` (already created off `main`; the spec is committed on it).

**Invariant for every task:** the existing genomic/codec/transport byte-equality suites stay green. Standard test command:
```
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/python && . .venv/bin/activate && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so python -m pytest <args>'
```

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `python/src/ttio/codecs/_context.py` | Create | `CodecContext`, `ChannelPayload`, `DecodedChannel`, `EncodedChannel` |
| `python/src/ttio/codecs/_registry.py` | Create | `Codec` protocol, per-codec adapters, `CODEC_REGISTRY` |
| `python/tests/test_codec_registry.py` | Create | value-object + registry round-trip + completeness tests |
| `python/src/ttio/genomic_run.py` | Modify | `_codec_context()` builder; decode sites → registry |
| `python/src/ttio/_hdf5_io.py` | Modify | byte + integer/delta encode sites → registry |
| `python/src/ttio/spectral_dataset.py` | Modify | bespoke ref_diff/name_tok/mate_info encode → registry |
| `python/src/ttio/codecs/_codec_meta.py` | Remove/fold | `_CONTEXT_AWARE` → `is_context_aware` on codec objects |
| `python/src/ttio/codecs/{rans,base_pack,quality,delta_rans,fqzcomp_nx16_z,name_tokenizer_v2,mate_info_v2,ref_diff_v2}.py` | Unchanged bodies | only referenced by adapters |
| `CHANGELOG.md` | Modify | `[Unreleased]` entry |

Codec ids (`enums.py:81-108`): `RANS_ORDER0=4`, `RANS_ORDER1=5`, `BASE_PACK=6`, `QUALITY_BINNED=7`, `DELTA_RANS_ORDER0=11`, `FQZCOMP_NX16_Z=12`, `MATE_INLINE_V2=13`, `REF_DIFF_V2=14`, `NAME_TOKENIZED_V2=15`.

---

## Task 1: Value objects (`codecs/_context.py`)

**Files:** Create `python/src/ttio/codecs/_context.py`; Test `python/tests/test_codec_registry.py`.

- [ ] **Step 1: Write the failing test** — create `python/tests/test_codec_registry.py`:

```python
"""Codec registry + value-object tests (codec-registry refactor)."""
from __future__ import annotations

import numpy as np
import pytest

from ttio.codecs._context import (
    CodecContext, ChannelPayload, DecodedChannel, EncodedChannel,
)


def test_decoded_channel_bytes_roundtrip():
    d = DecodedChannel.of_bytes(b"abc")
    assert d.as_bytes() == b"abc"
    with pytest.raises(TypeError):
        d.as_str_list()


def test_decoded_channel_str_list():
    d = DecodedChannel.of_str_list(["r1", "r2"])
    assert d.as_str_list() == ["r1", "r2"]
    with pytest.raises(TypeError):
        d.as_bytes()


def test_decoded_channel_mate_info():
    d = DecodedChannel.of_mate_info({"x": 1})
    assert d.as_mate_info() == {"x": 1}
    with pytest.raises(TypeError):
        d.as_bytes()


def test_encoded_channel_variants():
    a = EncodedChannel.of_dataset(b"xy")
    assert a.is_group is False and a.dataset_bytes == b"xy"
    b = EncodedChannel.of_group({"refdiff_v2": b"zz"}, {"k": 1})
    assert b.is_group is True and b.group_children["refdiff_v2"] == b"zz"


def test_channel_payload_bytes_vs_group():
    p = ChannelPayload.of_bytes(b"q")
    assert p.as_bytes() == b"q"
    with pytest.raises(TypeError):
        p.group()


def test_codec_context_empty_is_all_none():
    ctx = CodecContext.empty()
    assert ctx.read_lengths is None and ctx.element_size is None
    assert ctx.reference_resolver is None and ctx.cigars_provider is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... python -m pytest tests/test_codec_registry.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'ttio.codecs._context'`.

- [ ] **Step 3: Create `python/src/ttio/codecs/_context.py`**

```python
"""Value objects for the codec registry (codec-registry refactor).

CodecContext carries everything any TTI-O codec might need; ChannelPayload
hides dataset-vs-group storage; DecodedChannel/EncodedChannel are closed
tagged unions so one Codec.decode/encode signature covers heterogeneous
codecs portably. No wire/format change — these only restructure dispatch.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np
    from ..genomic.reference_resolver import ReferenceResolver
    from ..providers.base import StorageGroup


@dataclass(frozen=True)
class CodecContext:
    """Run-derived context for codecs. All fields optional; plain codecs ignore it."""
    read_lengths: "np.ndarray | None" = None        # fqzcomp; == index.lengths
    revcomp_flags: "np.ndarray | None" = None        # fqzcomp; (flags & 16) != 0
    element_size: "int | None" = None                # delta_rans encode
    read_count: "int | None" = None                  # == index.count
    positions: "np.ndarray | None" = None            # ref_diff
    cigars_provider: "Callable[[], list[str]] | None" = None  # ref_diff (lazy)
    total_bases: "int | None" = None                 # ref_diff
    chromosomes: "list[str] | None" = None           # ref_diff
    own_chrom_ids: "np.ndarray | None" = None         # mate_info
    own_positions: "np.ndarray | None" = None         # mate_info
    n_records: "int | None" = None                    # mate_info
    reference_resolver: "ReferenceResolver | None" = None  # ref_diff

    @staticmethod
    def empty() -> "CodecContext":
        return CodecContext()


@dataclass(frozen=True)
class ChannelPayload:
    """Encoded payload: either flat dataset bytes or a storage group (ref_diff)."""
    _bytes: "bytes | None" = None
    _group: "StorageGroup | None" = None

    @classmethod
    def of_bytes(cls, b: bytes) -> "ChannelPayload":
        return cls(_bytes=b)

    @classmethod
    def of_group(cls, g: "StorageGroup") -> "ChannelPayload":
        return cls(_group=g)

    def as_bytes(self) -> bytes:
        if self._bytes is None:
            raise TypeError("ChannelPayload holds a group, not bytes")
        return self._bytes

    def group(self) -> "StorageGroup":
        if self._group is None:
            raise TypeError("ChannelPayload holds bytes, not a group")
        return self._group


@dataclass(frozen=True)
class DecodedChannel:
    """Closed union of a decoded channel value: bytes | list[str] | mate-info dict."""
    _bytes: "bytes | None" = None
    _str_list: "list[str] | None" = None
    _mate_info: "dict[str, Any] | None" = None
    _kind: str = ""

    @classmethod
    def of_bytes(cls, b: bytes) -> "DecodedChannel":
        return cls(_bytes=b, _kind="bytes")

    @classmethod
    def of_str_list(cls, s: "list[str]") -> "DecodedChannel":
        return cls(_str_list=s, _kind="str_list")

    @classmethod
    def of_mate_info(cls, d: "dict[str, Any]") -> "DecodedChannel":
        return cls(_mate_info=d, _kind="mate_info")

    def as_bytes(self) -> bytes:
        if self._kind != "bytes":
            raise TypeError(f"DecodedChannel is {self._kind!r}, not bytes")
        return self._bytes  # type: ignore[return-value]

    def as_str_list(self) -> "list[str]":
        if self._kind != "str_list":
            raise TypeError(f"DecodedChannel is {self._kind!r}, not str_list")
        return self._str_list  # type: ignore[return-value]

    def as_mate_info(self) -> "dict[str, Any]":
        if self._kind != "mate_info":
            raise TypeError(f"DecodedChannel is {self._kind!r}, not mate_info")
        return self._mate_info  # type: ignore[return-value]


@dataclass(frozen=True)
class EncodedChannel:
    """Closed union of encode output: a dataset byte blob or a group layout (ref_diff)."""
    dataset_bytes: "bytes | None" = None
    group_children: "dict[str, bytes] | None" = None
    group_attrs: "dict[str, Any] | None" = None
    is_group: bool = False

    @classmethod
    def of_dataset(cls, b: bytes) -> "EncodedChannel":
        return cls(dataset_bytes=b, is_group=False)

    @classmethod
    def of_group(cls, children: "dict[str, bytes]", attrs: "dict[str, Any]") -> "EncodedChannel":
        return cls(group_children=children, group_attrs=attrs, is_group=True)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... python -m pytest tests/test_codec_registry.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add python/src/ttio/codecs/_context.py python/tests/test_codec_registry.py
git -C ~/TTI-O commit -m "feat(codecs): codec-registry value objects (CodecContext/payload/unions)"
```

---

## Task 2: Registry + plain-codec adapters (`codecs/_registry.py`)

**Files:** Create `python/src/ttio/codecs/_registry.py`; extend `python/tests/test_codec_registry.py`.

Plain codec signatures (verified): `rans.encode(data, order=0)` / `rans.decode(encoded)`; `base_pack.encode(data)` / `decode(encoded)`; `quality.encode(data)` / `decode(encoded)`; `delta_rans.encode(data, element_size)` / `decode(encoded)`.

- [ ] **Step 1: Add failing tests** — append to `python/tests/test_codec_registry.py`:

```python
from ttio.codecs._registry import CODEC_REGISTRY, Codec
from ttio.enums import Compression


@pytest.mark.parametrize("cid", [
    Compression.RANS_ORDER0, Compression.RANS_ORDER1, Compression.BASE_PACK,
])
def test_plain_codec_registry_roundtrip(cid):
    # NOTE: QUALITY_BINNED is excluded — it is lossy by design (Phred binning),
    # so a byte-exact round-trip with arbitrary data is impossible. It gets its
    # own idempotency test below.
    codec = CODEC_REGISTRY[cid]
    assert codec.id == cid
    assert codec.is_context_aware is False
    data = bytes(range(64)) * 4
    enc = codec.encode(DecodedChannel.of_bytes(data), CodecContext.empty())
    assert enc.is_group is False
    dec = codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty())
    assert dec.as_bytes() == data


def _qb_roundtrip(codec, data: bytes) -> bytes:
    enc = codec.encode(DecodedChannel.of_bytes(data), CodecContext.empty())
    return codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty()).as_bytes()


def test_quality_binned_registry_idempotent_and_length_preserving():
    # QUALITY_BINNED is lossy (bins → bin centres). Assert the registry path is
    # length-preserving and idempotent (re-encoding bin centres is stable),
    # rather than byte-lossless.
    codec = CODEC_REGISTRY[Compression.QUALITY_BINNED]
    assert codec.id == Compression.QUALITY_BINNED
    assert codec.is_context_aware is False
    data = bytes(range(64)) * 4
    once = _qb_roundtrip(codec, data)
    twice = _qb_roundtrip(codec, once)
    assert len(once) == len(data)
    assert once == twice


def test_delta_rans_registry_roundtrip_needs_element_size():
    codec = CODEC_REGISTRY[Compression.DELTA_RANS_ORDER0]
    data = np.arange(100, dtype="<u4").tobytes()
    enc = codec.encode(DecodedChannel.of_bytes(data), CodecContext(element_size=4))
    dec = codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty())
    assert dec.as_bytes() == data
    with pytest.raises(ValueError):
        codec.encode(DecodedChannel.of_bytes(data), CodecContext.empty())


def test_registry_entry_id_matches_key():
    for cid, codec in CODEC_REGISTRY.items():
        assert codec.id == cid
```

- [ ] **Step 2: Run to verify fail**

Run: `... python -m pytest tests/test_codec_registry.py -v`
Expected: FAIL — `No module named 'ttio.codecs._registry'`.

- [ ] **Step 3: Create `python/src/ttio/codecs/_registry.py`** (plain codecs only for now)

```python
"""Codec registry: maps Compression ids to Codec adapters (codec-registry refactor).

Context-aware codecs are added in Task 3. No wire change — adapters wrap the
existing codec functions verbatim.
"""
from __future__ import annotations

from typing import Protocol

from ..enums import Compression
from . import base_pack, delta_rans, quality, rans
from ._context import ChannelPayload, CodecContext, DecodedChannel, EncodedChannel


class Codec(Protocol):
    id: Compression
    is_context_aware: bool

    def decode(self, payload: ChannelPayload, ctx: CodecContext) -> DecodedChannel: ...
    def encode(self, value: DecodedChannel, ctx: CodecContext) -> EncodedChannel: ...


class _RansCodec:
    """rANS O0/O1. decode() is order-agnostic (order is in the stream)."""
    def __init__(self, cid: Compression, order: int) -> None:
        self.id = cid
        self._order = order
        self.is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(rans.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(rans.encode(value.as_bytes(), order=self._order))


class _BasePackCodec:
    id = Compression.BASE_PACK
    is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(base_pack.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(base_pack.encode(value.as_bytes()))


class _QualityBinnedCodec:
    id = Compression.QUALITY_BINNED
    is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(quality.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(quality.encode(value.as_bytes()))


class _DeltaRansCodec:
    id = Compression.DELTA_RANS_ORDER0
    is_context_aware = False

    def decode(self, payload, ctx):
        return DecodedChannel.of_bytes(delta_rans.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        if ctx.element_size is None:
            raise ValueError("DELTA_RANS encode requires CodecContext.element_size")
        return EncodedChannel.of_dataset(
            delta_rans.encode(value.as_bytes(), ctx.element_size)
        )


CODEC_REGISTRY: "dict[Compression, Codec]" = {
    Compression.RANS_ORDER0: _RansCodec(Compression.RANS_ORDER0, 0),
    Compression.RANS_ORDER1: _RansCodec(Compression.RANS_ORDER1, 1),
    Compression.BASE_PACK: _BasePackCodec(),
    Compression.QUALITY_BINNED: _QualityBinnedCodec(),
    Compression.DELTA_RANS_ORDER0: _DeltaRansCodec(),
}
```

- [ ] **Step 4: Run to verify pass**

Run: `... python -m pytest tests/test_codec_registry.py -v`
Expected: PASS (all value-object + plain-codec tests).

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add python/src/ttio/codecs/_registry.py python/tests/test_codec_registry.py
git -C ~/TTI-O commit -m "feat(codecs): registry + plain-codec adapters"
```

---

## Task 3: Context-aware codec adapters

**Files:** Modify `python/src/ttio/codecs/_registry.py`; extend `python/tests/test_codec_registry.py`.

Signatures (verified):
- `fqzcomp_nx16_z.encode(qualities: bytes, read_lengths: list[int], revcomp_flags: list[int], *, v4_strategy_hint=-1)` ; `decode_with_metadata(encoded: bytes, revcomp_flags: list[int] | None) -> (qualities, read_lengths, revcomp_flags)`.
- `name_tokenizer_v2.encode(names: list[str]) -> bytes` ; `decode(blob) -> list[str]`.
- `mate_info_v2.encode(mate_chrom_ids, mate_positions, template_lengths, own_chrom_ids, own_positions) -> bytes` ; `decode(encoded, own_chrom_ids, own_positions, n_records) -> (mate_chrom_ids, mate_positions, template_lengths)`.
- `ref_diff_v2.encode(sequences, offsets, positions, cigar_strings, reference, reference_md5, reference_uri, reads_per_slice=10000) -> bytes` ; `decode(encoded, positions, cigar_strings, reference, n_reads, total_bases) -> (sequences, offsets)`. Plus `ref_diff_v2.parse_blob_header(blob)` → object with `.reference_uri`, `.reference_md5`.

- [ ] **Step 1: Add failing tests** — append to `python/tests/test_codec_registry.py`:

```python
def test_name_tokenized_registry_roundtrip():
    codec = CODEC_REGISTRY[Compression.NAME_TOKENIZED_V2]
    assert codec.is_context_aware is False
    names = [f"read{i}" for i in range(200)]
    enc = codec.encode(DecodedChannel.of_str_list(names), CodecContext.empty())
    dec = codec.decode(ChannelPayload.of_bytes(enc.dataset_bytes), CodecContext.empty())
    assert dec.as_str_list() == names


def test_context_aware_codecs_registered():
    for cid in (Compression.FQZCOMP_NX16_Z, Compression.MATE_INLINE_V2,
                Compression.REF_DIFF_V2, Compression.NAME_TOKENIZED_V2):
        assert cid in CODEC_REGISTRY
    assert CODEC_REGISTRY[Compression.REF_DIFF_V2].is_context_aware is True
    assert CODEC_REGISTRY[Compression.FQZCOMP_NX16_Z].is_context_aware is True
    assert CODEC_REGISTRY[Compression.MATE_INLINE_V2].is_context_aware is True
```

(Note: `NAME_TOKENIZED_V2` is *not* context-aware — it needs no run context, only the `list[str]` domain. `FQZCOMP`, `MATE_INLINE_V2`, `REF_DIFF_V2` are context-aware. This matches `_codec_meta._CONTEXT_AWARE`, which the test in Task 6 will pin.)

- [ ] **Step 2: Run to verify fail**

Run: `... python -m pytest tests/test_codec_registry.py::test_name_tokenized_registry_roundtrip tests/test_codec_registry.py::test_context_aware_codecs_registered -v`
Expected: FAIL — `KeyError: Compression.NAME_TOKENIZED_V2`.

- [ ] **Step 3: Add the context-aware adapters** to `_registry.py` (above `CODEC_REGISTRY`):

```python
from . import fqzcomp_nx16_z, mate_info_v2, name_tokenizer_v2, ref_diff_v2

_SAM_REVERSE = 16


class _NameTokenizedV2Codec:
    id = Compression.NAME_TOKENIZED_V2
    is_context_aware = False  # str-list domain, but no run context needed

    def decode(self, payload, ctx):
        return DecodedChannel.of_str_list(name_tokenizer_v2.decode(payload.as_bytes()))

    def encode(self, value, ctx):
        return EncodedChannel.of_dataset(name_tokenizer_v2.encode(value.as_str_list()))


class _FqzcompNx16ZCodec:
    id = Compression.FQZCOMP_NX16_Z
    is_context_aware = True

    def decode(self, payload, ctx):
        flags = None
        if ctx.revcomp_flags is not None:
            flags = [int(x) for x in ctx.revcomp_flags]
        qualities, _read_lengths, _rc = fqzcomp_nx16_z.decode_with_metadata(
            payload.as_bytes(), flags
        )
        return DecodedChannel.of_bytes(qualities)

    def encode(self, value, ctx):
        if ctx.read_lengths is None or ctx.revcomp_flags is None:
            raise ValueError(
                "FQZCOMP_NX16_Z encode requires CodecContext.read_lengths + revcomp_flags"
            )
        blob = fqzcomp_nx16_z.encode(
            value.as_bytes(),
            [int(x) for x in ctx.read_lengths],
            [int(x) for x in ctx.revcomp_flags],
        )
        return EncodedChannel.of_dataset(blob)


class _MateInlineV2Codec:
    id = Compression.MATE_INLINE_V2
    is_context_aware = True

    def decode(self, payload, ctx):
        if ctx.own_chrom_ids is None or ctx.own_positions is None or ctx.n_records is None:
            raise ValueError(
                "MATE_INLINE_V2 decode requires CodecContext.own_chrom_ids/own_positions/n_records"
            )
        mc, mp, tl = mate_info_v2.decode(
            payload.as_bytes(), ctx.own_chrom_ids, ctx.own_positions, ctx.n_records
        )
        return DecodedChannel.of_mate_info(
            {"mate_chrom_ids": mc, "mate_positions": mp, "template_lengths": tl}
        )

    def encode(self, value, ctx):
        if ctx.own_chrom_ids is None or ctx.own_positions is None:
            raise ValueError(
                "MATE_INLINE_V2 encode requires CodecContext.own_chrom_ids/own_positions"
            )
        d = value.as_mate_info()
        blob = mate_info_v2.encode(
            d["mate_chrom_ids"], d["mate_positions"], d["template_lengths"],
            ctx.own_chrom_ids, ctx.own_positions,
        )
        return EncodedChannel.of_dataset(blob)


class _RefDiffV2Codec:
    id = Compression.REF_DIFF_V2
    is_context_aware = True

    def decode(self, payload, ctx):
        # Relocated from GenomicRun._decode_ref_diff_v2_sequences (genomic_run.py:410-487):
        # parse the blob header, resolve the reference via ctx, then decode.
        blob = bytes(payload.group().open_dataset("refdiff_v2").read(
            offset=0, count=int(payload.group().open_dataset("refdiff_v2").length)))
        header = ref_diff_v2.parse_blob_header(blob)
        if ctx.reference_resolver is None or ctx.chromosomes is None:
            raise ValueError("REF_DIFF_V2 decode requires CodecContext.reference_resolver + chromosomes")
        unique = set(ctx.chromosomes)
        if len(unique) == 0:
            chrom = ""
        elif len(unique) > 1:
            raise RuntimeError(
                "REF_DIFF_V2 supports single-chromosome runs only; "
                f"this run carries {sorted(unique)}.")
        else:
            chrom = next(iter(unique))
        chrom_seq = ctx.reference_resolver.resolve(
            uri=header.reference_uri, expected_md5=header.reference_md5, chromosome=chrom)
        cigars = ctx.cigars_provider() if ctx.cigars_provider else []
        out_seq, _off = ref_diff_v2.decode(
            blob, ctx.positions, cigars, chrom_seq, ctx.read_count, ctx.total_bases)
        return DecodedChannel.of_bytes(bytes(out_seq))

    def encode(self, value, ctx):
        # ref_diff encode is driven by the writer (spectral_dataset) which already holds
        # sequences/offsets/positions/cigars/reference; Task 5 routes it here. Until the
        # writer passes a full encode context, this adapter is decode-only.
        raise NotImplementedError(
            "REF_DIFF_V2 encode is performed by the writer path (see Task 5); "
            "the registry adapter currently supports decode only.")
```

Then add to `CODEC_REGISTRY`:

```python
    Compression.NAME_TOKENIZED_V2: _NameTokenizedV2Codec(),
    Compression.FQZCOMP_NX16_Z: _FqzcompNx16ZCodec(),
    Compression.MATE_INLINE_V2: _MateInlineV2Codec(),
    Compression.REF_DIFF_V2: _RefDiffV2Codec(),
```

> **Note on REF_DIFF_V2 encode:** ref_diff encoding is a writer-side, multi-read, slice-oriented operation that already lives in `spectral_dataset.py` and needs sequences+offsets+positions+cigars+reference for the *whole run*. Folding it cleanly requires the writer to assemble an encode-time `CodecContext`; Task 5 wires the writer to call the registry where that context is naturally available, and at that point the `_RefDiffV2Codec.encode` body is filled in by relocating the existing writer encode block. Keeping it `NotImplementedError` until Task 5 keeps this task's scope to decode + the byte/dataset encoders.

- [ ] **Step 4: Run to verify pass**

Run: `... python -m pytest tests/test_codec_registry.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add python/src/ttio/codecs/_registry.py python/tests/test_codec_registry.py
git -C ~/TTI-O commit -m "feat(codecs): context-aware codec adapters (fqzcomp/name_tok/mate_info/ref_diff decode)"
```

---

## Task 4: `_codec_context()` builder + route DECODE sites

**Files:** Modify `python/src/ttio/genomic_run.py`.

- [ ] **Step 1: Add a failing test** — append to `python/tests/test_codec_registry.py`:

```python
def test_genomic_run_has_codec_context():
    """GenomicRun exposes a _codec_context() builder (decode routing depends on it)."""
    from ttio.genomic_run import GenomicRun
    assert hasattr(GenomicRun, "_codec_context")
```

> This is an existence smoke test. The real behavioral coverage for decode routing is the **unchanged** `test_m82_genomic_run.py` suite (and `test_codec_registry.py` round-trips), which must stay green in Step 4 — that is what proves the registry-routed decode is byte-identical.

- [ ] **Step 2: Run to verify fail**

Run: `... python -m pytest tests/test_codec_registry.py::test_codec_context_built_from_run -v`
Expected: FAIL — `AttributeError: ... has no attribute '_codec_context'`.

- [ ] **Step 3: Add `_codec_context()` to `GenomicRun`** (in `genomic_run.py`, near the other private helpers). It is built lazily and cached on a new instance field:

```python
    def _codec_context(self) -> "CodecContext":
        from .codecs._context import CodecContext
        cached = getattr(self, "_codec_ctx_cache", None)
        if cached is not None:
            return cached
        import numpy as np
        idx = self.index
        flags = np.asarray(idx.flags, dtype=np.uint32)
        revcomp = ((flags & 16) != 0).astype(np.uint8)  # vectorized; was a list-comp
        resolver = None
        try:
            from .acquisition_run import _native_h5py
            from .genomic.reference_resolver import ReferenceResolver
            resolver = ReferenceResolver(_native_h5py(self.group).file)
        except (TypeError, Exception):
            resolver = None  # non-HDF5 backend: ref_diff decode will raise clearly
        ctx = CodecContext(
            read_lengths=np.asarray(idx.lengths, dtype=np.uint32),
            revcomp_flags=revcomp,
            read_count=int(idx.count),
            positions=np.asarray(idx.positions, dtype=np.int64),
            cigars_provider=self._all_cigars,
            total_bases=int(sum(idx.lengths)),
            chromosomes=list(idx.chromosomes),
            reference_resolver=resolver,
        )
        self._codec_ctx_cache = ctx   # field declared default=None (see gotchas)
        return ctx
```

> Declare `_codec_ctx_cache` in the dataclass field block (default `None`, `field(default=None, repr=False, compare=False)`) alongside the other `_decoded_*` caches so the assignment is valid on the (non-frozen) `GenomicRun` dataclass. The `mate_info` fields (`own_chrom_ids`/`own_positions`/`n_records`) are populated where the mate_info decode path builds them — see Step 3b.

- [ ] **Step 3b: Route the byte-channel decode ladder through the registry.** In `genomic_run.py` `_decode_byte_channel` (the ladder at `:359-383`), replace the `if codec_id == ... elif ...` chain (which selects `_dec` and calls `_decode_fqzcomp_nx16_z_qualities`) with:

```python
        from .enums import Compression
        from .codecs._registry import CODEC_REGISTRY
        from .codecs._context import ChannelPayload
        try:
            codec = CODEC_REGISTRY[Compression(codec_id)]
        except (KeyError, ValueError):
            raise ValueError(
                f"signal_channel '{name}': @compression={codec_id} "
                "is not a supported TTIO codec id")
        decoded = codec.decode(ChannelPayload.of_bytes(all_bytes), self._codec_context()).as_bytes()
```

Leave the surrounding logic unchanged: the `codec_id == 0` raw return (`:354-355`), the `all_bytes = ...` read (`:357`), and the cache write + slice (`self._decoded_byte_channels[name] = decoded; return decoded[offset:offset+count]`).

- [ ] **Step 3c: Route the ref_diff special-case** (`genomic_run.py:348`) through the registry. Replace the `self._decode_ref_diff_v2_sequences()` call with a registry call that uses the group payload:

```python
            from .enums import Compression
            from .codecs._registry import CODEC_REGISTRY
            from .codecs._context import ChannelPayload
            sig = self.group.open_group("signal_channels")
            decoded = CODEC_REGISTRY[Compression.REF_DIFF_V2].decode(
                ChannelPayload.of_group(sig.open_group("sequences")),
                self._codec_context(),
            ).as_bytes()
            self._decoded_byte_channels[name] = decoded
            self._decoded_ref_diff_v2 = decoded
            return decoded[offset:offset + count]
```

Keep `_decode_ref_diff_v2_sequences` as a now-unused private method for one commit, or delete it and rely on the registry adapter (the adapter is a verbatim relocation of its body). Prefer deletion once the suite is green.

- [ ] **Step 3d: Route read_names + mate_info decode** through the registry similarly: where read_names is decoded (the `_decoded_read_names` path) call `CODEC_REGISTRY[Compression.NAME_TOKENIZED_V2].decode(ChannelPayload.of_bytes(blob), ctx).as_str_list()`; where mate_info is decoded, build `CodecContext` with `own_chrom_ids`/`own_positions`/`n_records` populated (from the index — `own_chrom_ids` are the interned chromosome ids, `own_positions = index.positions`, `n_records = index.count`) and call `CODEC_REGISTRY[Compression.MATE_INLINE_V2].decode(...).as_mate_info()`. Preserve the existing caches (`_decoded_read_names`, `_decoded_mate_info`).

> The implementer must read the current read_names and mate_info decode methods first and replace only their codec-call lines, preserving caching and surrounding parsing. The byte-equality suite is the guard.

- [ ] **Step 4: Run the genomic suites — must stay green**

Run:
```
... python -m pytest tests/test_m82_genomic_run.py tests/test_codec_registry.py tests/test_offsets_cumsum.py -q
```
Expected: all pass (decode now routed through the registry, behavior byte-identical).

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add python/src/ttio/genomic_run.py python/tests/test_codec_registry.py
git -C ~/TTI-O commit -m "refactor(codecs): route genomic decode through codec registry"
```

---

## Task 5: Route ENCODE sites through the registry

**Files:** Modify `python/src/ttio/_hdf5_io.py`, `python/src/ttio/spectral_dataset.py`; complete `_RefDiffV2Codec.encode` in `codecs/_registry.py`.

- [ ] **Step 1: Add a failing test** — append to `python/tests/test_codec_registry.py`:

```python
def test_delta_rans_encode_via_registry_matches_direct():
    """Registry encode must be byte-identical to the direct codec function."""
    from ttio.codecs import delta_rans
    data = np.arange(256, dtype="<u4").tobytes()
    direct = delta_rans.encode(data, 4)
    via = CODEC_REGISTRY[Compression.DELTA_RANS_ORDER0].encode(
        DecodedChannel.of_bytes(data), CodecContext(element_size=4)).dataset_bytes
    assert via == direct
```

- [ ] **Step 2: Run to verify pass-or-fail** — this test passes already (registry exists); it pins the byte-identity invariant. Run it:
```
... python -m pytest tests/test_codec_registry.py::test_delta_rans_encode_via_registry_matches_direct -v
```
Expected: PASS (guards Step 3 against drift).

- [ ] **Step 3: Route the byte-channel encode ladder** (`_hdf5_io.py:646-666`). Replace the `if codec_override == ... elif ...` selection of the encode function with:

```python
    from .enums import Compression
    from .codecs._registry import CODEC_REGISTRY
    from .codecs._context import DecodedChannel, CodecContext
    codec = CODEC_REGISTRY[Compression(codec_id)]
    enc = codec.encode(DecodedChannel.of_bytes(raw_bytes), encode_ctx)
    out_bytes = enc.dataset_bytes
```

where `encode_ctx` is a `CodecContext` carrying `element_size` (for delta) and, for the genomic context-aware encoders, the run's `read_lengths`/`revcomp_flags`/etc. Preserve the surrounding dataset-creation + `@compression` attribute write. The plain/byte channels need only `element_size`.

- [ ] **Step 3b: Route the integer-channel/delta encode** (`_hdf5_io.py:798`) the same way, passing `CodecContext(element_size=<dtype width>)`.

- [ ] **Step 3c: Route the bespoke ref_diff/name_tok/mate_info writer encode** in `spectral_dataset.py` through the registry, and **fill in `_RefDiffV2Codec.encode`** by relocating the existing ref_diff writer encode block into the adapter: it returns `EncodedChannel.of_group({"refdiff_v2": blob}, attrs)` where `blob = ref_diff_v2.encode(sequences, offsets, positions, cigars, reference, reference_md5, reference_uri)` using an encode-time `CodecContext` that the writer assembles (sequences/offsets from the run, positions/cigars from the index, reference+md5+uri from the resolved reference). The writer then creates the `sequences` group and writes the `refdiff_v2` child + attrs from `EncodedChannel`.

> This is the most intricate edit. The implementer must read the current `spectral_dataset.py` ref_diff/name_tok/mate_info writer blocks, move the codec-call lines into the registry adapters, and keep the storage-write (group/dataset creation, `@compression`) in the writer driven by `EncodedChannel`. Byte-equality suites are the guard.

- [ ] **Step 4: Run the full codec/genomic/transport byte-equality suites**

Run:
```
... python -m pytest tests/test_m82_genomic_run.py tests/test_m86_genomic_codec_wiring.py tests/test_m90_10_genomic_wire_codec.py tests/test_transport_codec.py tests/test_codec_registry.py -q
```
Expected: all pass; on-disk bytes unchanged.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add python/src/ttio/_hdf5_io.py python/src/ttio/spectral_dataset.py python/src/ttio/codecs/_registry.py python/tests/test_codec_registry.py
git -C ~/TTI-O commit -m "refactor(codecs): route genomic encode through codec registry"
```

---

## Task 6: Remove `_codec_meta`; fold `is_context_aware` onto codecs

**Files:** Modify `python/src/ttio/codecs/_codec_meta.py` (remove or reduce), and its importers; extend `python/tests/test_codec_registry.py`.

- [ ] **Step 1: Add a parity test** — append:

```python
def test_is_context_aware_matches_legacy_meta():
    """Each codec's is_context_aware matches the legacy _CONTEXT_AWARE set."""
    import importlib
    try:
        meta = importlib.import_module("ttio.codecs._codec_meta")
        legacy = set(getattr(meta, "_CONTEXT_AWARE"))
    except (ModuleNotFoundError, AttributeError):
        legacy = {Compression.REF_DIFF_V2}  # documented legacy membership
    for cid, codec in CODEC_REGISTRY.items():
        assert codec.is_context_aware == (cid in legacy), cid
```

- [ ] **Step 2: Run** — Expected: PASS if the registry's `is_context_aware` flags match the legacy set. If the legacy set contains more than `{REF_DIFF_V2}` (e.g. it also lists FQZCOMP/MATE), align the registry flags to match exactly, then re-run.

Run: `... python -m pytest tests/test_codec_registry.py::test_is_context_aware_matches_legacy_meta -v`

- [ ] **Step 3: Replace `_codec_meta` consumers with the registry.** Find every importer of `_codec_meta` / `_CONTEXT_AWARE`:
```
wsl -d Ubuntu -- bash -c 'grep -rn "_codec_meta\|_CONTEXT_AWARE" ~/TTI-O/python/src'
```
Replace each `codec_id in _CONTEXT_AWARE` check with `CODEC_REGISTRY[Compression(codec_id)].is_context_aware`. Then delete `_codec_meta.py` (or reduce it to a thin re-export if external code imports it — grep tests too).

- [ ] **Step 4: Run** the codec/genomic suites again (Task 5 Step 4 command). Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add -A
git -C ~/TTI-O commit -m "refactor(codecs): fold context-aware metadata onto codec objects; drop _codec_meta"
```

---

## Task 7: Completeness guard, full regression, CHANGELOG

**Files:** extend `python/tests/test_codec_registry.py`; modify `CHANGELOG.md`.

- [ ] **Step 1: Add a completeness guard test** — every real TTI-O genomic/signal codec id has a registry entry:

```python
def test_registry_covers_all_real_codec_ids():
    expected = {
        Compression.RANS_ORDER0, Compression.RANS_ORDER1, Compression.BASE_PACK,
        Compression.QUALITY_BINNED, Compression.DELTA_RANS_ORDER0,
        Compression.FQZCOMP_NX16_Z, Compression.MATE_INLINE_V2,
        Compression.REF_DIFF_V2, Compression.NAME_TOKENIZED_V2,
    }
    assert expected.issubset(set(CODEC_REGISTRY.keys()))
```

- [ ] **Step 2: Run the test + the full Python suite** (with native lib):

Run:
```
... python -m pytest tests/test_codec_registry.py -q
... python -m pytest tests/ -q -k "genomic or codec or transport or offsets or m86 or m90"
```
Expected: all green. (No wire change → existing byte-equality + cross-language fixtures unchanged.)

- [ ] **Step 3: Add the CHANGELOG entry** — under `## [Unreleased]`:

```markdown
### Changed — Codec dispatch unified behind a registry (Python)

Python's genomic codec dispatch (the decode/encode `if`/`elif` ladders, the
four bespoke ref_diff/fqzcomp/name_tok/mate_info side-paths, and the
`_codec_meta` context-aware set) is replaced by a single `Codec` registry keyed
by `Compression` id, fronted by a uniform `Codec` interface, a `CodecContext`
value object, and closed `DecodedChannel`/`EncodedChannel` unions
(`ttio/codecs/_registry.py`, `_context.py`). Adding a codec is now one registry
entry. No wire/on-disk format change; all byte-equality and cross-language
fixtures unchanged. Java and ObjC parity ports are tracked as follow-on work.
```

- [ ] **Step 4: Commit**

```bash
git -C ~/TTI-O add python/tests/test_codec_registry.py CHANGELOG.md
git -C ~/TTI-O commit -m "test(codecs): registry completeness guard; changelog"
```

---

## Notes / gotchas

- **Native lib required:** ref_diff/fqzcomp/mate_info adapters call native code; always run pytest with `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so`.
- **Laziness preserved:** `cigars_provider` is a thunk (`self._all_cigars`) so building `CodecContext` does not eagerly decode the cigars channel; only ref_diff decode pulls it. `_codec_context()` is cached per run.
- **No wire change is the load-bearing invariant.** Every encode adapter must be byte-identical to the direct codec function it wraps (Task 5 Step 1 pins this for delta; the suite pins it for the rest). If any on-disk byte differs, stop and diff.
- **ref_diff is the hard case** (group layout + reference resolution from blob header + single-chromosome constraint). Its decode adapter is a verbatim relocation of `_decode_ref_diff_v2_sequences`; its encode is relocated in Task 5. Verify `ref_diff_v2.parse_blob_header` exists and exposes `.reference_uri`/`.reference_md5` before relying on it.
- **`GenomicRun` is a dataclass** — declare `_codec_ctx_cache` as a `field(default=None, repr=False, compare=False)` alongside the existing `_decoded_*` caches; do not rely on `object.__setattr__` unless the dataclass is frozen (it is not).
- **Follow-on:** Java (`GenomicRun.java:436` ladder) and ObjC (`TTIOGenomicRun.m:346` switch) get their own plans reusing this interface shape.
