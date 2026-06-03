# Codec Registry + CodecContext — Design

**Date:** 2026-06-02
**Status:** Approved (brainstorm), pending implementation plan
**Scope owner:** genomic/codec subsystem, cross-language SDK
**Origin:** P1.1 recommendation of `docs/architecture/2026-06-02-oo-design-assessment.md` (codec dispatch graded **D** — no codec interface in any language; 6–8 switch-ladders per language).

## Background

TTI-O's custom codecs (`python/src/ttio/codecs/*` — the genomic codecs plus `delta_rans`) are dispatched by integer-id `if`/`switch` ladders with codec bodies inlined or called as free functions, and the four context-aware codecs have **bespoke side-paths** that bypass the main ladder. In Python alone:

- byte-channel **decode** ladder — `genomic_run.py:359-378`
- ref_diff group special-case before the ladder — `genomic_run.py:348`
- fqzcomp branch calling `_decode_fqzcomp_nx16_z_qualities` — `genomic_run.py:373-378`
- byte-channel **encode** ladder — `_hdf5_io.py:646-666`
- integer-channel (delta) encode — `_hdf5_io.py:798`
- bespoke encode paths for ref_diff / fqzcomp / name_tok / mate_info
- a parallel context-aware metadata set — `codecs/_codec_meta.py:30`

Adding one codec ripples through ~3 enums + 6 ladders + 3 meta sets + the blob-packet machinery across the three languages. The codecs are also genuinely heterogeneous, which is *why* the side-paths exist:

| Codec | id (`Compression`) | Domain | Context needed | On-disk |
|---|---|---|---|---|
| RANS_ORDER0 / ORDER1 | 4 / 5 | bytes→bytes | none | dataset |
| BASE_PACK | 6 | bytes→bytes | none | dataset |
| QUALITY_BINNED | 7 | bytes→bytes | none | dataset |
| DELTA_RANS_ORDER0 | 11 | bytes→bytes | `element_size` (encode) | dataset |
| FQZCOMP_NX16_Z | 12 | bytes | `read_lengths`, `revcomp_flags` | dataset |
| MATE_INLINE_V2 | 13 | **structured triple** | `own_chrom_ids`, `own_positions`, `n_records` | dataset |
| REF_DIFF_V2 | 14 | bytes | `reference` (resolved via blob header), `positions`, `cigars`, `total_bases` | **group** (`sequences/refdiff_v2`) |
| NAME_TOKENIZED_V2 | 15 | **`list[str]`** | none | dataset |

(ids verified against `python/src/ttio/enums.py:81-108`.)

## Goals

1. Replace the scattered per-language codec dispatch with a single **codec registry** keyed by `Compression` id, fronted by a uniform **`Codec`** interface and a **`CodecContext`** value object — the full "all codecs via CodecContext" unification.
2. Eliminate the four bespoke side-paths and the parallel `_codec_meta` set; the codec object becomes the single source of truth for *which* codec handles an id, whether it is context-aware (`is_context_aware`), whether it needs an embedded reference (`needs_embedded_reference`, == legacy `_CONTEXT_AWARE`), and what domain it produces.
3. Make "add a codec" a one-place change (a registry entry + a thin adapter) per language.
4. **Python-first as the reference proof**, then Java and ObjC as follow-on plans reusing this exact interface shape.

## Non-goals / hard invariants

- **No wire-format or on-disk-format change.** Codec id integers, byte streams, and group layouts are byte-identical before/after. Codec *algorithm* bodies are reused verbatim behind thin adapters.
- **No performance regression.** The whole-channel decode-and-cache strategy is preserved; the registry replaces only *selection*.
- Out of scope: the HDF5-native filters (zlib / lz4 / numpress), which h5py handles and are not TTI-O custom codecs.
- Out of scope (this spec): the Java and ObjC implementations — they get their own plans; this spec only constrains their interface shape.

## Architecture (Approach 1)

Five small new units under `python/src/ttio/codecs/_registry.py` (split into `_context.py` if it grows), plus a thin adapter per existing codec.

1. **`CodecContext`** — frozen dataclass built once per `GenomicRun` (and per encode call), carrying everything any codec might need; plain codecs ignore it. The context-aware genomic codecs need a rich, but bounded, field set sourced from the run's index + storage:
   - `read_lengths: np.ndarray | None` (fqzcomp, == index.lengths), `revcomp_flags: np.ndarray | None` (fqzcomp, derived `(flags & 16) != 0`), `element_size: int | None` (delta encode), `read_count: int | None` (== index.count).
   - `positions: np.ndarray | None`, `cigars: list[str] | None`, `total_bases: int | None`, `chromosomes: list[str] | None` (ref_diff).
   - `own_chrom_ids: np.ndarray | None`, `own_positions: np.ndarray | None`, `n_records: int | None` (mate_info).
   - `reference_resolver: ReferenceResolver | None` (ref_diff resolves its reference from the *blob header* `reference_uri`/`reference_md5`, so the resolver — not a pre-resolved sequence — is what the context carries; this couples `CodecContext` to the HDF5-backed run for ref_diff, matching today's `_decode_ref_diff_v2_sequences` which requires HDF5).

   Built lazily and cached on `GenomicRun._codec_context()`. Plain codecs receive it and read nothing.

2. **`ChannelPayload`** — abstracts *where encoded bytes live*, hiding the dataset-vs-group difference so codecs never touch the storage protocol directly:
   `as_bytes() -> bytes` (dataset-stored), `group() -> StorageGroup` (ref_diff). Constructed by the channel layer from the storage node via `ChannelPayload.from_node(node)`.

3. **`DecodedChannel`** — a **closed tagged union** so a single `decode` signature yields heterogeneous values portably: holds one of `bytes` / `list[str]` / `dict` (mate-info), with typed accessors `as_bytes()`, `as_str_list()`, `as_mate_info()`, and constructors `of_bytes()`, `of_str_list()`, `of_mate_info()`.

4. **`EncodedChannel`** — mirror union for encode output: `DatasetBytes(bytes)` or `GroupLayout(children: dict[str, bytes], attrs: dict)` (ref_diff). The writer applies it; codecs never write storage themselves.

5. **`Codec` protocol** + **`CODEC_REGISTRY: dict[Compression, Codec]`** — maps each id to a `Codec` instance. Existing free functions stay; each codec gets a tiny adapter class.

### Interface contract

```python
class Codec(Protocol):
    id: Compression
    is_context_aware: bool          # needs sibling-channel context via CodecContext
    needs_embedded_reference: bool  # the reference-embed predicate (== legacy _CONTEXT_AWARE)

    def decode(self, payload: ChannelPayload, ctx: CodecContext) -> DecodedChannel: ...
    def encode(self, value: DecodedChannel, ctx: CodecContext) -> EncodedChannel: ...
```

> **Two distinct flags (do not conflate).** `is_context_aware` means the codec
> needs run-derived sibling context (`CodecContext`) to encode/decode — True for
> REF_DIFF_V2, FQZCOMP_NX16_Z, MATE_INLINE_V2. `needs_embedded_reference` means
> the codec requires a reference resource embedded at `/study/references/...` —
> True **only** for REF_DIFF_V2. The legacy `_codec_meta._CONTEXT_AWARE` frozenset
> (`{REF_DIFF_V2}`) is the *reference-embed* predicate despite its name, consumed
> by `spectral_dataset._embed_references_for_runs` to decide whether to embed a
> reference; it maps to `needs_embedded_reference`, **not** `is_context_aware`.
> Conflating them would embed references for FQZCOMP/MATE runs and change on-disk
> output.

- **Plain codecs** (rans O0/O1, base_pack, quality, delta_rans): `is_context_aware = False`; `decode` = `payload.as_bytes()` → existing `decode()` → `DecodedChannel.of_bytes(...)`; `encode` consults `ctx.element_size` only where needed (delta).
- **Context-aware** (ref_diff, fqzcomp, name_tok, mate_info): pull `reference` / `read_lengths` / `revcomp_flags` from `ctx`; ref_diff uses `payload.group()` and returns `EncodedChannel.group_layout(...)`.

## Dispatch-site collapse

**Decode** — the ladder, the ref_diff special-case, the fqzcomp branch, and the separate `read_names`/`mate_info` paths converge to:

```python
codec   = CODEC_REGISTRY[Compression(codec_id)]
payload = ChannelPayload.from_node(storage_node)
ctx     = self._codec_context()            # built once per run, cached
decoded = codec.decode(payload, ctx)
# channel method picks the accessor it expects:
#   byte channels → decoded.as_bytes()     (still cached in _decoded_byte_channels)
#   read_names    → decoded.as_str_list()
#   mate_info     → decoded.as_mate_info()
```

Existing per-channel caches (`_decoded_byte_channels`, `_decoded_ref_diff_v2`, `_decoded_read_names`, `_decoded_mate_info`) are preserved — the registry replaces selection, not the amortization that keeps perf flat.

**Encode** — the byte-channel ladder (`_hdf5_io.py:646`), the integer/delta path (`:798`), and the bespoke encoders collapse to:

```python
codec = CODEC_REGISTRY[codec_override or default_for(channel)]
enc   = codec.encode(DecodedChannel.of_bytes(raw) | of_str_list(names), ctx)
# DatasetBytes(b)            → write dataset, @compression = codec.id
# GroupLayout(children,attrs)→ create group, write children + attrs   (ref_diff)
```

**`_codec_context()`** is built once per run and cached: `reference` (existing resolver), `read_lengths` (from the index), `revcomp_flags` (`(flags & 16) != 0` — vectorized, folding in the perf nit from the assessment), `element_size` (per-channel precision width). Plain codecs receive it and ignore it.

## Portability constraints (so the Python proof de-risks Java/ObjC)

- `DecodedChannel` / `EncodedChannel` are **closed** unions — exactly 3 decode variants (`bytes`, `str-list`, `mate-info`) and 2 encode variants (`dataset-bytes`, `group-layout`). They map to **Java sealed interfaces / ObjC class clusters** with typed accessors — **no `Any`-typed returns**. The proof must confirm these 3+2 variants cover every current codec; a new domain later means a new variant in all three languages (so keep them minimal — YAGNI).
- `CodecContext` → Java `record` / ObjC value object with nullable fields; no Python-specific types leak (`reference` is the already-shared `ReferenceImport`).
- `Codec` → Java `interface` / ObjC `@protocol`; `CODEC_REGISTRY` → `Map<Compression, Codec>` / `NSDictionary<NSNumber*, id<TTIOCodec>>`. `is_context_aware` and `needs_embedded_reference` are properties on the codec; `needs_embedded_reference` replaces the parallel `_codec_meta._CONTEXT_AWARE` / `CodecMeta` / `TTIOCodecMeta` reference-embed sets.
- The codec algorithm modules are unchanged; only thin adapters + dispatch are added.

## Testing strategy

- **Byte-equality is the guardrail.** Existing genomic / codec-wiring / transport / cross-language byte-equality suites must stay green with zero changes — they prove the refactor is wire-invisible. Run with `TTIO_RANS_LIB_PATH` set.
- **New registry unit tests** (`python/tests/test_codec_registry.py`):
  - Round-trip per codec *through the registry* (`encode` → `decode` → original) for each `Compression` id, asserting byte-identity with the pre-refactor direct-function path (golden bytes captured from current code).
  - **Completeness guard:** every `Compression` id that names a real TTI-O codec has a `CODEC_REGISTRY` entry, and every entry's `id` matches its key.
  - `DecodedChannel`/`EncodedChannel` accessor-mismatch raises a clear error (e.g. calling `as_str_list()` on a bytes variant).
  - `CodecContext`-None / missing-field safety for plain codecs.
  - `needs_embedded_reference` on each codec matches the old `_codec_meta._CONTEXT_AWARE` membership (`{REF_DIFF_V2}`); `is_context_aware` is the broader "needs CodecContext" flag (REF_DIFF/FQZCOMP/MATE).
- TDD: write the registry + round-trip test first; watch fail; implement adapters; collapse dispatch sites one at a time keeping the suite green.

## File structure

| File | Change | Responsibility |
|---|---|---|
| `python/src/ttio/codecs/_registry.py` | Create | `Codec` protocol, `CODEC_REGISTRY`, per-codec adapters |
| `python/src/ttio/codecs/_context.py` | Create | `CodecContext`, `ChannelPayload`, `DecodedChannel`, `EncodedChannel` |
| `python/src/ttio/genomic_run.py` | Modify | decode sites → registry; add cached `_codec_context()` |
| `python/src/ttio/_hdf5_io.py` | Modify | encode sites (byte + integer/delta) → registry |
| `python/src/ttio/spectral_dataset.py` | Modify | bespoke ref_diff/name_tok/mate_info encode → registry |
| `python/src/ttio/codecs/_codec_meta.py` | Remove/fold | `_CONTEXT_AWARE` moves onto codec objects |
| `python/src/ttio/codecs/*.py` (rans, base_pack, quality, delta_rans, ref_diff_v2, fqzcomp_nx16_z, name_tokenizer_v2, mate_info_v2) | Unchanged bodies | only thin adapter classes reference them |
| `python/tests/test_codec_registry.py` | Create | registry unit + round-trip + completeness tests |

## Risks

- **ref_diff group layout** and the **integer/delta encode path** are the trickiest dispatch sites; their cache interactions (`_decoded_ref_diff_v2`, `_sequences_is_v2_cached`) must be preserved exactly.
- **Cache-key correctness**: the registry must not change *when* a channel is decoded/cached, only *how it is selected* — a subtle move of a cache write could change laziness.
- **Closed-union completeness**: if any current codec needs a domain outside the 3+2 variants, the union (and later all three languages) must absorb it — the proof must surface this before Java/ObjC start.
- Mitigation for all: the byte-equality suites + the per-codec golden round-trip test catch any behavioral drift; collapse dispatch sites incrementally.

## Follow-on (separate plans)

- **Java** — port `Codec`/`CodecContext`/registry (interface + sealed unions), collapse `GenomicRun.java:436` ladder and bespoke paths; remove `CodecMeta` set.
- **ObjC** — port to `@protocol`/`NSDictionary` registry, collapse `TTIOGenomicRun.m:346` switch; remove `TTIOCodecMeta`.
Both reuse this interface shape verbatim and are gated by the same cross-language byte-equality suites.
