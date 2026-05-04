# NAME_TOKENIZED v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `NAME_TOKENIZED_V2 = 15` codec implementing CRAM-inspired multi-substream + DUP-pool + PREFIX-MATCH encoding for the `read_names` channel across native C + Python + Java + ObjC; soft wire-format addition defaulting on at v1.9 with opt-out flag. Hard chr22 gate ≥ 3 MB savings (target 3-4 MB) vs NAME_TOKENIZED v1.

**Architecture:** Shared C kernel in `native/src/name_tok_v2.{c,h}` mirrors mate_info v2 / ref_diff v2 pattern. Each language wraps the C entry points (Python ctypes / Java JNI / ObjC direct link). Substreams use the existing `ttio_rans_o0_encode/decode`; no new entropy coder. New on-disk path: `read_names` dataset stays at the same HDF5 location but `@compression = 15` flags v2 codec output. Reader dispatches on `@compression`; writer dispatches on `opt_disable_name_tokenized_v2: bool = False` flag.

**Tech Stack:** C11 (kernel), CMake (build), pytest (Python), JUnit + Maven (Java), GNUstep + GNU Make (ObjC), ctypes (Python), JNI (Java).

**Spec:** `docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md` (HEAD `d9e76e1`).

**Reference cycle:** This plan mirrors `docs/superpowers/plans/2026-05-03-ref-diff-v2.md` (15 tasks) plus a Phase 0 prototype (Task 0). Where the engineering pattern is identical (e.g. JNI binding shape, ObjC GNUstep test wiring, dispatch test structure), this plan refers to ref_diff v2 commits as templates: `e08bb31` (Python ctypes), `94d8be4` (Java JNI), `12ac82e` (ObjC direct link), `eb4ba51` (Python dispatch), `40f552c` (Java dispatch), `f4f0c38` (ObjC dispatch), `d2ce103` (ratio gate + docs).

---

## Build/test environment notes

Per memory feedbacks `feedback_pwd_mangling_in_nested_wsl`, `feedback_msys_wsl_tmp_path_mangling`, `feedback_git_push_via_windows`, `feedback_path_form_variants`:

- All commands run inside WSL Ubuntu: `wsl -d Ubuntu -- bash -c '...'`.
- Use absolute paths like `/home/toddw/TTI-O/...` — `$PWD` mangled inside nested wsl bash -c.
- Native lib path for Python tests: `TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so`.
- Java surefire needs `-Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:/home/toddw/TTI-O/native/_build`.
- Java direct invocation for JNI CLIs: `java -Djava.library.path=/home/toddw/TTI-O/native/_build -cp <jar>` — NOT `mvn exec:java` (sets the property too late for JNI loading).
- Push from Windows git after final task: `'/c/Program Files/Git/bin/git.exe' -C //wsl.localhost/Ubuntu/home/toddw/TTI-O push`.
- Git commit identity (per `feedback_git_commit_identity_msys`): `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`.

---

## Phase 0 — Python prototype + corpus sweep (Task 0)

### Task 0: Phase 0 prototype validates the gate before C/Java/ObjC code

Per `feedback_phase_0_spec_proof`, wire-format-breaking codec rewrites need a math/spec proof phase before implementation. Phase 0 is a Python-only prototype that runs end-to-end, sweeps the forever-frozen wire constants on real corpora, and validates the chr22 ≥ 3 MB gate. If the gate doesn't reach, the design is revised before ANY C work.

**Files:**
- Create: `tools/perf/name_tok_v2_prototype/__init__.py`
- Create: `tools/perf/name_tok_v2_prototype/encode.py` (pure-Python encoder)
- Create: `tools/perf/name_tok_v2_prototype/decode.py` (pure-Python decoder)
- Create: `tools/perf/name_tok_v2_prototype/benchmark.py` (corpus runner)
- Create: `tools/perf/name_tok_v2_prototype/test_roundtrip.py` (small roundtrip tests)
- Create: `docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md` (results)

- [ ] **Step 1: Implement pure-Python tokeniser reuse**

The tokeniser is reused verbatim from v1. Add `__init__.py`:

```python
# tools/perf/name_tok_v2_prototype/__init__.py
"""Phase 0 prototype for NAME_TOKENIZED v2.

Validates the multi-substream + DUP-pool + PREFIX-MATCH design on real
corpora before committing to the C kernel implementation.

Per feedback_phase_0_spec_proof: this is a pure-Python end-to-end
validation. If chr22 savings < 3 MB at the chosen wire constants
(N=8, B=4096), the design is revised before any C/Java/ObjC code.
"""
```

- [ ] **Step 2: Implement the encoder**

```python
# tools/perf/name_tok_v2_prototype/encode.py
"""Pure-Python NAME_TOKENIZED v2 encoder (Phase 0 prototype)."""
from __future__ import annotations

import struct
from typing import Iterable

# Reuse v1's tokeniser
from ttio.codecs.name_tokenizer import _tokenize  # type: ignore


# Wire constants
MAGIC = b"NTK2"
VERSION = 0x01
POOL_SIZE_DEFAULT = 8
BLOCK_SIZE_DEFAULT = 4096

FLAG_DUP = 0b00
FLAG_MATCH = 0b01
FLAG_COL = 0b10
FLAG_VERB = 0b11


def _zig(n: int) -> int:
    return (n << 1) ^ (n >> 63)


def _uvarint(n: int) -> bytes:
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _svarint(n: int) -> bytes:
    return _uvarint(_zig(n))


def _pack_2bits(values: list[int]) -> bytes:
    """MSB-first within each byte. values are 0..3."""
    out = bytearray()
    cur = 0
    bits = 0
    for v in values:
        cur = (cur << 2) | (v & 3)
        bits += 2
        if bits == 8:
            out.append(cur & 0xFF)
            cur = 0
            bits = 0
    if bits:
        cur <<= (8 - bits)
        out.append(cur & 0xFF)
    return bytes(out)


def _pack_3bits(values: list[int]) -> bytes:
    """MSB-first within each byte. values are 0..7."""
    out = bytearray()
    cur = 0
    bits = 0
    for v in values:
        cur = (cur << 3) | (v & 7)
        bits += 3
        while bits >= 8:
            out.append((cur >> (bits - 8)) & 0xFF)
            bits -= 8
            cur &= (1 << bits) - 1
    if bits:
        cur <<= (8 - bits)
        out.append(cur & 0xFF)
    return bytes(out)


def _tokens_for(name: str) -> list[tuple[str, object]]:
    """Wrap v1 tokeniser. Returns list of ('num', int) or ('str', str)."""
    raw = _tokenize(name)
    out: list[tuple[str, object]] = []
    for tok in raw:
        if isinstance(tok, int):
            out.append(("num", tok))
        else:
            out.append(("str", tok))
    return out


def _col_types(tokens: list[tuple[str, object]]) -> list[int]:
    """Returns 0=num/1=str per column."""
    return [0 if t[0] == "num" else 1 for t in tokens]


def _try_match(read_tokens: list[tuple[str, object]],
               pool_tokens: list[list[tuple[str, object]]],
               block_col_types: list[int] | None) -> tuple[int, int] | None:
    """Find best (pool_idx, K) for MATCH-K. Returns None if none qualifies.

    K must be in [1, n_cols-1) — full match would be DUP, K=0 = COL.
    Pool entry first K columns must have types matching block_col_types[:K].
    Read tokens shape must match block_col_types (n_cols + per-col types).
    """
    if block_col_types is None:
        return None  # MATCH-K requires block COL_TYPES set first
    n_cols = len(read_tokens)
    if n_cols != len(block_col_types):
        return None
    if [0 if t[0] == "num" else 1 for t in read_tokens] != block_col_types:
        return None

    best_k = 0
    best_idx = -1
    for idx, p in enumerate(pool_tokens):
        if len(p) < 1:
            continue
        # Check pool entry's first K columns can have type-aligned compare
        k = 0
        max_k = min(len(p), n_cols)
        for j in range(max_k):
            pt = p[j]
            rt = read_tokens[j]
            # Type must match block COL_TYPES
            if j < len(block_col_types):
                want = block_col_types[j]
                if (0 if pt[0] == "num" else 1) != want:
                    break
            if pt[0] != rt[0] or pt[1] != rt[1]:
                break
            k += 1
        # k now = leading matched cols
        # Reject if k == 0 (no MATCH-K) or k == n_cols (would be DUP, but DUP
        # is only triggered if FULL byte-equal — which requires n_cols match
        # AND identical token list). MATCH-K legal iff 0 < k < n_cols.
        if 0 < k < n_cols and k > best_k:
            best_k = k
            best_idx = idx
    if best_idx < 0:
        return None
    return (best_idx, best_k)


def _encode_block(
    names: list[str],
    pool_size: int,
) -> bytes:
    """Encode one block (≤ B reads). Returns block body bytes."""
    flags: list[int] = []
    pool_idx_vals: list[int] = []
    match_k_vals: list[int] = []
    block_col_types: list[int] | None = None

    # Per-column delta state for COL+MATCH-K rows
    col_num_prev: dict[int, int] = {}
    col_dict: dict[int, dict[str, int]] = {}
    dict_lit_blob = bytearray()

    num_delta_per_col: dict[int, list[bytes]] = {}  # col -> list of varint bytes
    dict_code_per_col: dict[int, list[bytes]] = {}

    verb_lit_blob = bytearray()

    pool: list[list[tuple[str, object]]] = []  # tokenised pool entries
    pool_names: list[str] = []                  # raw byte-equal pool

    for name in names:
        tokens = _tokens_for(name)

        # Strategy 1: DUP (full byte match against any pool entry)
        if name in pool_names:
            pool_idx = pool_names.index(name)  # smallest such idx
            flags.append(FLAG_DUP)
            pool_idx_vals.append(pool_idx)
            # Update pool
            pool_names.append(name)
            pool.append(tokens)
            if len(pool_names) > pool_size:
                pool_names.pop(0)
                pool.pop(0)
            continue

        # Strategy 2: MATCH-K
        match = _try_match(tokens, pool, block_col_types)
        if match is not None:
            pool_idx, K = match
            flags.append(FLAG_MATCH)
            pool_idx_vals.append(pool_idx)
            match_k_vals.append(K)
            # Initialise block_col_types if not yet set (MATCH-K requires it,
            # so block_col_types should already be set from a prior COL row;
            # this branch is reachable only if block_col_types is set)
            assert block_col_types is not None
            # For columns [K, n_cols): emit deltas/codes
            for j in range(K, len(tokens)):
                ttype, tval = tokens[j]
                if ttype == "num":
                    if j not in col_num_prev:
                        # First emission of this column → seed
                        num_delta_per_col.setdefault(j, []).append(_uvarint(tval))
                    else:
                        delta = tval - col_num_prev[j]
                        num_delta_per_col.setdefault(j, []).append(_svarint(delta))
                    col_num_prev[j] = tval
                else:  # str
                    d = col_dict.setdefault(j, {})
                    if tval in d:
                        code = d[tval]
                        dict_code_per_col.setdefault(j, []).append(_uvarint(code))
                    else:
                        code = len(d)
                        dict_code_per_col.setdefault(j, []).append(_uvarint(code))
                        d[tval] = code
                        lit_bytes = tval.encode("ascii")
                        dict_lit_blob.extend(_uvarint(len(lit_bytes)))
                        dict_lit_blob.extend(lit_bytes)
            # Update delta state for matched cols [0, K) using pool entry values
            pool_entry = pool[pool_idx]
            for j in range(K):
                if pool_entry[j][0] == "num":
                    col_num_prev[j] = pool_entry[j][1]  # type: ignore
            # Update pool with this read
            pool_names.append(name)
            pool.append(tokens)
            if len(pool_names) > pool_size:
                pool_names.pop(0)
                pool.pop(0)
            continue

        # Strategy 3: COL — check shape compat against block_col_types
        col_types = _col_types(tokens)
        if block_col_types is None:
            block_col_types = col_types  # first COL/MATCH-K row sets it
        if col_types == block_col_types:
            flags.append(FLAG_COL)
            for j, (ttype, tval) in enumerate(tokens):
                if ttype == "num":
                    if j not in col_num_prev:
                        num_delta_per_col.setdefault(j, []).append(_uvarint(tval))
                    else:
                        delta = tval - col_num_prev[j]
                        num_delta_per_col.setdefault(j, []).append(_svarint(delta))
                    col_num_prev[j] = tval
                else:
                    d = col_dict.setdefault(j, {})
                    if tval in d:
                        code = d[tval]
                        dict_code_per_col.setdefault(j, []).append(_uvarint(code))
                    else:
                        code = len(d)
                        dict_code_per_col.setdefault(j, []).append(_uvarint(code))
                        d[tval] = code
                        lit_bytes = tval.encode("ascii")
                        dict_lit_blob.extend(_uvarint(len(lit_bytes)))
                        dict_lit_blob.extend(lit_bytes)
            pool_names.append(name)
            pool.append(tokens)
            if len(pool_names) > pool_size:
                pool_names.pop(0)
                pool.pop(0)
            continue

        # Strategy 4: VERB
        flags.append(FLAG_VERB)
        b = name.encode("ascii")
        verb_lit_blob.extend(_uvarint(len(b)))
        verb_lit_blob.extend(b)
        pool_names.append(name)
        pool.append(tokens)
        if len(pool_names) > pool_size:
            pool_names.pop(0)
            pool.pop(0)

    # Assemble substreams
    flag_substream = _pack_2bits(flags)
    pool_idx_substream = _pack_3bits(pool_idx_vals)
    match_k_substream = b"".join(_uvarint(k) for k in match_k_vals)

    if block_col_types is not None:
        n_cols = len(block_col_types)
        # bitmap: bit=0 num, bit=1 str, MSB-first within each byte
        bitmap = bytearray((n_cols + 7) // 8)
        for j, t in enumerate(block_col_types):
            byte_idx = j // 8
            bit_idx = 7 - (j % 8)
            if t == 1:
                bitmap[byte_idx] |= (1 << bit_idx)
        col_types_substream = bytes([n_cols]) + bytes(bitmap)
    else:
        col_types_substream = b""

    # NUM_DELTA / DICT_CODE: column-major
    num_delta_substream = b""
    dict_code_substream = b""
    if block_col_types is not None:
        for j in range(len(block_col_types)):
            for chunk in num_delta_per_col.get(j, []):
                num_delta_substream += chunk
            for chunk in dict_code_per_col.get(j, []):
                dict_code_substream += chunk

    dict_lit_substream = bytes(dict_lit_blob)
    verb_lit_substream = bytes(verb_lit_blob)

    substreams = [
        flag_substream,
        pool_idx_substream,
        match_k_substream,
        col_types_substream,
        num_delta_substream,
        dict_code_substream,
        dict_lit_substream,
        verb_lit_substream,
    ]

    # Each substream emit: [4-byte LE body_len][1-byte mode][body]
    # Phase 0 prototype always uses mode=0x00 (raw); native impl will
    # auto-pick rANS-O0 vs raw. Phase 0 measures raw bytes — gate must
    # still hit savings even before rANS-O0 wraps.
    # OPTIONAL: also measure with deflate as a proxy for rANS-O0 to predict
    # the production codec's savings.
    body = bytearray()
    for s in substreams:
        body.extend(struct.pack("<I", len(s)))
        body.append(0x00)
        body.extend(s)

    block_body = struct.pack("<I", len(names)) + struct.pack("<I", len(body)) + bytes(body)
    return block_body


def encode(names: list[str], *, pool_size: int = POOL_SIZE_DEFAULT,
           block_size: int = BLOCK_SIZE_DEFAULT,
           use_rans_o0_proxy: bool = True) -> bytes:
    """Encode names to NAME_TOKENIZED v2 wire format (Phase 0 prototype).

    use_rans_o0_proxy: when True, wraps each substream body in zlib.compress
    (level 6) when smaller than raw. This is the Phase 0 stand-in for
    rANS-O0; the production codec uses ttio_rans_o0_encode. The two should
    be roughly comparable in size on the same input.
    """
    n_reads = len(names)
    if n_reads == 0:
        # Empty stream
        return MAGIC + bytes([VERSION, 0x01]) + struct.pack("<I", 0) + struct.pack("<H", 0)

    # Block partitioning
    n_blocks = (n_reads + block_size - 1) // block_size
    if n_blocks > 65535:
        raise ValueError(f"too many blocks: {n_blocks} > 65535")

    blocks: list[bytes] = []
    for b in range(n_blocks):
        start = b * block_size
        end = min(start + block_size, n_reads)
        block_body = _encode_block(names[start:end], pool_size)
        if use_rans_o0_proxy:
            block_body = _maybe_compress_substreams(block_body)
        blocks.append(block_body)

    # Container header
    block_offsets: list[int] = []
    cur = 0
    for blk in blocks:
        block_offsets.append(cur)
        cur += len(blk)

    header = MAGIC + bytes([VERSION, 0x00]) + struct.pack("<I", n_reads) + struct.pack("<H", n_blocks)
    header += b"".join(struct.pack("<I", off) for off in block_offsets)

    return header + b"".join(blocks)


def _maybe_compress_substreams(block_body: bytes) -> bytes:
    """Walk each substream in a block body, replace mode=0x00 with mode=0x01
    + zlib-compressed body when smaller. Phase 0 proxy for rANS-O0."""
    import zlib
    # Block body: 4-byte n_reads + 4-byte body_len + body
    # body: sequence of [4-byte len][1-byte mode][body]
    n_reads_bytes = block_body[:4]
    out = bytearray(n_reads_bytes)
    body_start = 8
    body = block_body[body_start:]
    new_body = bytearray()
    pos = 0
    while pos < len(body):
        body_len = struct.unpack("<I", body[pos:pos+4])[0]
        mode = body[pos+4]
        sub_body = body[pos+5:pos+5+body_len]
        pos += 5 + body_len
        if mode == 0x00 and body_len > 0:
            compressed = zlib.compress(sub_body, level=6)
            if len(compressed) < body_len:
                new_body.extend(struct.pack("<I", len(compressed)))
                new_body.append(0x01)
                new_body.extend(compressed)
                continue
        new_body.extend(struct.pack("<I", body_len))
        new_body.append(mode)
        new_body.extend(sub_body)
    out.extend(struct.pack("<I", len(new_body)))
    out.extend(new_body)
    return bytes(out)
```

- [ ] **Step 3: Implement the decoder**

```python
# tools/perf/name_tok_v2_prototype/decode.py
"""Pure-Python NAME_TOKENIZED v2 decoder (Phase 0 prototype)."""
from __future__ import annotations

import struct
import zlib

MAGIC = b"NTK2"
FLAG_DUP, FLAG_MATCH, FLAG_COL, FLAG_VERB = 0b00, 0b01, 0b10, 0b11


def _read_uvarint(data: bytes, pos: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        b = data[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return value, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint overflow")


def _read_svarint(data: bytes, pos: int) -> tuple[int, int]:
    u, pos = _read_uvarint(data, pos)
    return ((u >> 1) ^ -(u & 1)), pos


def _unpack_2bits(data: bytes, n: int) -> list[int]:
    out: list[int] = []
    for i in range(n):
        byte_idx = (i * 2) // 8
        bit_idx = 6 - ((i * 2) % 8)
        out.append((data[byte_idx] >> bit_idx) & 3)
    return out


def _unpack_3bits(data: bytes, n: int) -> list[int]:
    out: list[int] = []
    bit_pos = 0
    for _ in range(n):
        byte_idx = bit_pos // 8
        in_byte = bit_pos % 8
        # Extract 3 bits possibly across two bytes, MSB-first
        if in_byte + 3 <= 8:
            shift = 8 - in_byte - 3
            out.append((data[byte_idx] >> shift) & 7)
        else:
            high_bits = 8 - in_byte
            low_bits = 3 - high_bits
            high = data[byte_idx] & ((1 << high_bits) - 1)
            low = (data[byte_idx + 1] >> (8 - low_bits)) & ((1 << low_bits) - 1)
            out.append((high << low_bits) | low)
        bit_pos += 3
    return out


def _decompress_substreams(block_body: bytes) -> bytes:
    """Inverse of _maybe_compress_substreams."""
    n_reads_bytes = block_body[:4]
    body_len = struct.unpack("<I", block_body[4:8])[0]
    body = block_body[8:8+body_len]
    new_body = bytearray()
    pos = 0
    while pos < len(body):
        sub_body_len = struct.unpack("<I", body[pos:pos+4])[0]
        mode = body[pos+4]
        sub_body = body[pos+5:pos+5+sub_body_len]
        pos += 5 + sub_body_len
        if mode == 0x01:
            decompressed = zlib.decompress(sub_body)
            new_body.extend(struct.pack("<I", len(decompressed)))
            new_body.append(0x00)
            new_body.extend(decompressed)
        else:
            new_body.extend(struct.pack("<I", sub_body_len))
            new_body.append(mode)
            new_body.extend(sub_body)
    out = bytearray(n_reads_bytes)
    out.extend(struct.pack("<I", len(new_body)))
    out.extend(new_body)
    return bytes(out)


def _decode_block(block_body: bytes, pool_size: int) -> list[str]:
    block_body = _decompress_substreams(block_body)
    n_reads = struct.unpack("<I", block_body[:4])[0]
    body_len = struct.unpack("<I", block_body[4:8])[0]
    body = block_body[8:8+body_len]

    # Parse 8 substreams
    pos = 0
    subs = []
    for _ in range(8):
        slen = struct.unpack("<I", body[pos:pos+4])[0]
        mode = body[pos+4]
        sb = body[pos+5:pos+5+slen]
        pos += 5 + slen
        assert mode == 0x00, "decompressed should be raw"
        subs.append(sb)

    flag_sub, pool_sub, match_k_sub, col_types_sub, num_delta_sub, dict_code_sub, dict_lit_sub, verb_lit_sub = subs

    flags = _unpack_2bits(flag_sub, n_reads)

    # Count DUP+MATCH for pool_idx
    n_pool = sum(1 for f in flags if f in (FLAG_DUP, FLAG_MATCH))
    pool_idx_vals = _unpack_3bits(pool_sub, n_pool)

    # Parse MATCH_K varints (one per MATCH row)
    match_k_vals: list[int] = []
    p = 0
    n_match = sum(1 for f in flags if f == FLAG_MATCH)
    for _ in range(n_match):
        k, p = _read_uvarint(match_k_sub, p)
        match_k_vals.append(k)

    # Parse COL_TYPES
    block_col_types: list[int] | None = None
    if col_types_sub:
        n_cols = col_types_sub[0]
        bitmap = col_types_sub[1:1 + (n_cols + 7) // 8]
        block_col_types = []
        for j in range(n_cols):
            byte_idx = j // 8
            bit_idx = 7 - (j % 8)
            block_col_types.append((bitmap[byte_idx] >> bit_idx) & 1)

    # Parse DICT_LIT into per-column streams (column-major across rows)
    # We need to interleave with DICT_CODE consumption — easier to consume
    # all literal bytes flat and pop in order as new codes appear.
    dict_lit_pos = 0

    # Pre-flatten NUM_DELTA + DICT_CODE per-column: but we need column-major
    # consumption order matching encoder. Encoder emits per-column j: walks
    # all rows that emit a value for column j. Each column j has its own
    # sub-stream within NUM_DELTA / DICT_CODE.
    # We need to know, per column j, the COUNT of rows emitting values to
    # know where each column's sub-bytes start. Simpler approach: pre-compute
    # the row order per column by walking flags + match_k.

    # Build per-column row list (which rows contribute to col j's values)
    col_rows: dict[int, list[int]] = {}
    if block_col_types is not None:
        match_k_iter = iter(match_k_vals)
        for r, f in enumerate(flags):
            if f == FLAG_COL:
                for j in range(len(block_col_types)):
                    col_rows.setdefault(j, []).append(r)
            elif f == FLAG_MATCH:
                K = next(match_k_iter)
                for j in range(K, len(block_col_types)):
                    col_rows.setdefault(j, []).append(r)

    # Now consume NUM_DELTA / DICT_CODE per column
    nd_pos = 0
    dc_pos = 0
    col_num_state: dict[int, int] = {}  # prev value per col
    col_dict_state: dict[int, list[str]] = {}  # dict per col
    col_values_per_row_per_col: dict[int, dict[int, object]] = {}  # row → col → value

    if block_col_types is not None:
        for j, ctype in enumerate(block_col_types):
            rows = col_rows.get(j, [])
            for ri, r in enumerate(rows):
                if ctype == 0:  # num
                    if ri == 0 and j not in col_num_state:
                        v, nd_pos = _read_uvarint(num_delta_sub, nd_pos)
                    else:
                        d, nd_pos = _read_svarint(num_delta_sub, nd_pos)
                        v = col_num_state[j] + d
                    col_num_state[j] = v
                    col_values_per_row_per_col.setdefault(r, {})[j] = v
                else:  # str
                    code, dc_pos = _read_uvarint(dict_code_sub, dc_pos)
                    d = col_dict_state.setdefault(j, [])
                    if code < len(d):
                        col_values_per_row_per_col.setdefault(r, {})[j] = d[code]
                    elif code == len(d):
                        lit_len, dict_lit_pos = _read_uvarint(dict_lit_sub, dict_lit_pos)
                        lit = dict_lit_sub[dict_lit_pos:dict_lit_pos + lit_len].decode("ascii")
                        dict_lit_pos += lit_len
                        d.append(lit)
                        col_values_per_row_per_col.setdefault(r, {})[j] = lit
                    else:
                        raise ValueError(f"dict code {code} > dict size {len(d)}")

    # Replay rows
    pool: list[str] = []
    out_names: list[str] = []
    pool_idx_iter = iter(pool_idx_vals)
    match_k_iter = iter(match_k_vals)
    verb_pos = 0

    for r, f in enumerate(flags):
        if f == FLAG_DUP:
            pi = next(pool_idx_iter)
            name = pool[pi]
        elif f == FLAG_MATCH:
            pi = next(pool_idx_iter)
            K = next(match_k_iter)
            assert block_col_types is not None
            pool_entry_tokens = _retokenise(pool[pi])
            tokens: list = list(pool_entry_tokens[:K])
            row_vals = col_values_per_row_per_col.get(r, {})
            for j in range(K, len(block_col_types)):
                v = row_vals[j]
                tokens.append(v)
            name = _detokenise(tokens, block_col_types)
            # Update num state for matched cols [0, K)
            for j in range(K):
                if pool_entry_tokens[j].__class__ is int:
                    col_num_state[j] = pool_entry_tokens[j]  # type: ignore
        elif f == FLAG_COL:
            assert block_col_types is not None
            row_vals = col_values_per_row_per_col.get(r, {})
            tokens = [row_vals[j] for j in range(len(block_col_types))]
            name = _detokenise(tokens, block_col_types)
        elif f == FLAG_VERB:
            ll, verb_pos = _read_uvarint(verb_lit_sub, verb_pos)
            name = verb_lit_sub[verb_pos:verb_pos + ll].decode("ascii")
            verb_pos += ll
        else:
            raise ValueError(f"unknown flag {f}")
        out_names.append(name)
        pool.append(name)
        if len(pool) > pool_size:
            pool.pop(0)

    return out_names


def _retokenise(name: str) -> list:
    """Re-run v1 tokeniser to recover the token list of a pool entry."""
    from ttio.codecs.name_tokenizer import _tokenize  # type: ignore
    return _tokenize(name)


def _detokenise(tokens: list, col_types: list[int]) -> str:
    """Concatenate tokens into a name string."""
    parts: list[str] = []
    for j, t in enumerate(tokens):
        if isinstance(t, int):
            parts.append(str(t))
        else:
            parts.append(t)
    return "".join(parts)


def decode(blob: bytes, pool_size: int = 8) -> list[str]:
    if blob[:4] != MAGIC:
        raise ValueError(f"bad magic: {blob[:4]!r}")
    if blob[4] != 0x01:
        raise ValueError(f"unsupported version: {blob[4]}")
    flags_byte = blob[5]
    n_reads = struct.unpack("<I", blob[6:10])[0]
    n_blocks = struct.unpack("<H", blob[10:12])[0]
    if flags_byte & 0x01:
        assert n_reads == 0
        return []
    block_offsets = []
    for i in range(n_blocks):
        off = struct.unpack("<I", blob[12 + i*4:16 + i*4])[0]
        block_offsets.append(off)
    body_start = 12 + n_blocks * 4

    out_names: list[str] = []
    for i in range(n_blocks):
        start = body_start + block_offsets[i]
        end = body_start + block_offsets[i+1] if i + 1 < n_blocks else len(blob)
        block_body = blob[start:end]
        out_names.extend(_decode_block(block_body, pool_size))

    if len(out_names) != n_reads:
        raise ValueError(f"decoded {len(out_names)} names, header said {n_reads}")
    return out_names
```

- [ ] **Step 4: Round-trip test on a small synthetic batch**

```python
# tools/perf/name_tok_v2_prototype/test_roundtrip.py
"""Round-trip smoke tests for the prototype."""
from __future__ import annotations

import pytest

from .encode import encode
from .decode import decode


def test_empty():
    assert decode(encode([])) == []


def test_single():
    names = ["EAS220_R1:8:1:0:1234"]
    assert decode(encode(names)) == names


def test_paired_dup():
    # Same name appears twice (paired-end mate) — should DUP
    names = ["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1234"]
    blob = encode(names)
    assert decode(blob) == names


def test_match_k():
    # Names that share a common prefix differing only in last column
    names = [
        "EAS220_R1:8:1:0:1234",
        "EAS220_R1:8:1:0:1235",
        "EAS220_R1:8:1:0:1236",
    ]
    assert decode(encode(names)) == names


def test_columnar_batch():
    names = [f"EAS220_R1:8:1:0:{1000+i}" for i in range(50)]
    assert decode(encode(names)) == names


def test_mixed_shapes_falls_to_verb():
    names = [
        "EAS220_R1:8:1:0:1234",
        "weirdname",
        "EAS220_R1:8:1:0:1235",
    ]
    assert decode(encode(names)) == names


def test_two_blocks():
    # Force a second block boundary
    names = [f"R:1:{i}" for i in range(4097)]
    assert decode(encode(names)) == names
```

Run:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && PYTHONPATH=python/src .venv/bin/python -m pytest tools/perf/name_tok_v2_prototype/test_roundtrip.py -v 2>&1 | tail -15'
```

Expected: 7 PASS.

- [ ] **Step 5: Build the corpus benchmark harness**

```python
# tools/perf/name_tok_v2_prototype/benchmark.py
"""Run the v2 prototype on real corpora, sweep N and B, validate the gate."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .encode import encode

CORPORA = {
    "chr22": "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam",
    "wes": "/home/toddw/TTI-O/data/genomic/na12878/wes/na12878.wes.chr22.lean.mapped.bam",
    "hg002_illumina": "/home/toddw/TTI-O/data/genomic/hg002/hg002.illumina.2x250.chr22.lean.mapped.bam",
    "hg002_pacbio": "/home/toddw/TTI-O/data/genomic/hg002/hg002.pacbio.hifi.lean.mapped.bam",
}


def extract_names(bam_path: str, max_reads: int | None = None) -> list[str]:
    """Use samtools to extract QNAMEs."""
    cmd = ["samtools", "view", bam_path]
    proc = subprocess.run(cmd, capture_output=True, check=True, text=False)
    names: list[str] = []
    for line in proc.stdout.split(b"\n"):
        if not line:
            continue
        qname = line.split(b"\t", 1)[0].decode("ascii", errors="replace")
        if qname == "*":
            return []  # PacBio HiFi sentinel — skip
        names.append(qname)
        if max_reads is not None and len(names) >= max_reads:
            break
    return names


def measure_v1(names: list[str]) -> int:
    """Encode via v1 NAME_TOKENIZED for baseline."""
    sys.path.insert(0, "/home/toddw/TTI-O/python/src")
    from ttio.codecs.name_tokenizer import encode as v1_encode  # type: ignore
    return len(v1_encode(names))


def measure_v2(names: list[str], pool_size: int, block_size: int) -> int:
    return len(encode(names, pool_size=pool_size, block_size=block_size))


def main():
    print(f"Corpus | n_reads | v1 size | v2 (N=8,B=4096) | savings | best (N,B)")
    print("-" * 80)
    for name, path in CORPORA.items():
        if not os.path.exists(path):
            print(f"{name}: SKIP (BAM not found)")
            continue
        all_names = extract_names(path)
        if not all_names:
            print(f"{name}: SKIP (BAM has * QNAMEs)")
            continue
        n = len(all_names)
        v1 = measure_v1(all_names)
        v2_default = measure_v2(all_names, 8, 4096)
        savings = v1 - v2_default
        # Sweep
        best = (8, 4096, v2_default)
        if name == "chr22":
            for B in [1024, 4096, 16384]:
                for N in [4, 8, 16, 32]:
                    sz = measure_v2(all_names, N, B)
                    if sz < best[2]:
                        best = (N, B, sz)
        print(f"{name:20s} | {n:>7d} | {v1:>9,} | {v2_default:>9,} | {savings:>+9,} | N={best[0]}, B={best[1]}, sz={best[2]:,}")

    # Hard gate check on chr22
    print()
    chr22_names = extract_names(CORPORA["chr22"])
    v1_chr22 = measure_v1(chr22_names)
    v2_chr22 = measure_v2(chr22_names, 8, 4096)
    savings = v1_chr22 - v2_chr22
    print(f"Phase 0 GATE: chr22 savings = {savings:,} bytes ({savings / 1024 / 1024:.2f} MB)")
    if savings >= 3_000_000:
        print("✅ Phase 0 GATE PASS")
        return 0
    else:
        print("❌ Phase 0 GATE FAIL — design must be revised before C work")
        return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Run the benchmark + record results**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && PYTHONPATH=python/src .venv/bin/python -m tools.perf.name_tok_v2_prototype.benchmark 2>&1 | tee docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md.tmp'
```

Expected: Phase 0 GATE PASS with chr22 savings ≥ 3 MB. If FAIL, stop and revise design.

- [ ] **Step 7: Write up Phase 0 results**

Convert the `.tmp` output into a proper Markdown report at `docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md`. Include:
- Methodology (zlib proxy for rANS-O0).
- Per-corpus encoded sizes.
- (N, B) sweep table on chr22.
- Decision: confirm N=8, B=4096 OR justify alternate.
- Decision: GATE PASS / FAIL.

If GATE FAIL: STOP. Revise design before any C work.

- [ ] **Step 8: Commit Phase 0**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add tools/perf/name_tok_v2_prototype/ docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 0): Phase 0 prototype validates chr22 ≥ 3 MB gate

Pure-Python encoder + decoder for NAME_TOKENIZED v2 with multi-substream
+ DUP-pool (N=8) + PREFIX-MATCH ladder + block reset (B=4096). zlib used
as a Phase 0 proxy for rANS-O0 in the production codec.

Validates wire constants on chr22 + WES + HG002 Illumina before any
C/Java/ObjC code per feedback_phase_0_spec_proof.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 1 — Native C kernel (Tasks 1-4)

### Task 1: Add C header + new error codes

**Files:**
- Create: `native/src/name_tok_v2.h`
- Modify: `native/include/ttio_rans.h`

- [ ] **Step 1: Extend error codes in `native/include/ttio_rans.h`**

Find the `TTIO_RANS_ERR_*` block (after ref_diff v2's -6 and -7):

```c
#define TTIO_RANS_ERR_RESERVED_MF        -4
#define TTIO_RANS_ERR_NS_LENGTH_MISMATCH -5
#define TTIO_RANS_ERR_ESC_LENGTH_MISMATCH -6
#define TTIO_RANS_ERR_RESERVED_ESC_STREAM -7
#define TTIO_RANS_ERR_NTV2_BAD_FLAG       -8   /* name_tok_v2: invalid 2-bit FLAG */
#define TTIO_RANS_ERR_NTV2_POOL_OOB       -9   /* name_tok_v2: pool_idx out of range */
#define TTIO_RANS_ERR_NTV2_BAD_K          -10  /* name_tok_v2: K=0 or K>=n_cols */
#define TTIO_RANS_ERR_NTV2_DICT_OVERFLOW  -11  /* name_tok_v2: dict code > dict size */
#define TTIO_RANS_ERR_NTV2_BAD_VERSION    -12  /* name_tok_v2: bad container version */
#define TTIO_RANS_ERR_NTV2_BAD_MAGIC      -13  /* name_tok_v2: magic != "NTK2" */
```

- [ ] **Step 2: Add public entry points to `native/include/ttio_rans.h`**

Append:

```c
/* ──────────────────────────────────────────────────────────────────────
 * NAME_TOKENIZED v2 — multi-substream + DUP-pool + PREFIX-MATCH codec
 * (codec id 15). Spec: docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md
 *
 * Encoded blob written to read_names HDF5 dataset with @compression = 15.
 * Wire magic "NTK2", version 0x01.
 *
 * Returns 0 on success; negative TTIO_RANS_ERR_* on framing or value
 * violations.
 * ────────────────────────────────────────────────────────────────────── */

size_t ttio_name_tok_v2_max_encoded_size(uint64_t n_reads, uint64_t total_name_bytes);

/* Encodes n_reads names. names is an array of n_reads pointers to
 * NUL-terminated 7-bit-ASCII strings. Caller must allocate `out` of at
 * least max_encoded_size bytes; *out_len is set to the actual size. */
int ttio_name_tok_v2_encode(
    const char * const *names,
    uint64_t n_reads,
    uint8_t *out,
    size_t  *out_len);

/* Decodes a v2 stream. *out_names is malloc'd as an array of n_reads
 * c-string pointers (each entry malloc'd separately). Caller frees
 * each entry + the array. *out_n_reads is set. */
int ttio_name_tok_v2_decode(
    const uint8_t *encoded,
    size_t         encoded_size,
    char         ***out_names,
    uint64_t      *out_n_reads);
```

- [ ] **Step 3: Create internal header `native/src/name_tok_v2.h`**

```c
#ifndef TTIO_NAME_TOK_V2_INTERNAL_H
#define TTIO_NAME_TOK_V2_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* Wire constants per spec §3, §4.1 */
#define NTV2_MAGIC         "NTK2"
#define NTV2_MAGIC_LEN     4
#define NTV2_VERSION       0x01
#define NTV2_POOL_SIZE     8
#define NTV2_BLOCK_SIZE    4096
#define NTV2_HEADER_FIXED  12  /* magic + version + flags + n_reads + n_blocks */

/* FLAG values (2-bit) */
#define NTV2_FLAG_DUP   0
#define NTV2_FLAG_MATCH 1
#define NTV2_FLAG_COL   2
#define NTV2_FLAG_VERB  3

/* Substream IDs (order matches spec §4.3) */
#define NTV2_SUB_FLAG       0
#define NTV2_SUB_POOL_IDX   1
#define NTV2_SUB_MATCH_K    2
#define NTV2_SUB_COL_TYPES  3
#define NTV2_SUB_NUM_DELTA  4
#define NTV2_SUB_DICT_CODE  5
#define NTV2_SUB_DICT_LIT   6
#define NTV2_SUB_VERB_LIT   7
#define NTV2_SUB_COUNT      8

/* Substream encoding mode */
#define NTV2_MODE_RAW    0x00
#define NTV2_MODE_RANS_O0 0x01

/* Token type */
#define NTV2_TOK_NUM 0
#define NTV2_TOK_STR 1

/* Internal helpers exposed for tests only. */

/* Tokenises a NUL-terminated ASCII name. Returns -1 on non-ASCII / empty.
 * `tokens_out` must hold at least 256 entries. Each token is one
 * (type, start_offset, length) triple stored as three parallel arrays. */
int ntv2_tokenise(
    const char *name,
    uint8_t  *types_out,    /* 0=num, 1=str */
    uint16_t *starts_out,   /* offset within name */
    uint16_t *lens_out,
    uint8_t  *n_tokens_out, /* up to 255 */
    uint64_t *num_values_out /* parsed numeric value for num tokens */);

/* 2-bit MSB-first pack/unpack. */
size_t ntv2_pack_2bits(const uint8_t *vals, size_t n, uint8_t *out);
void   ntv2_unpack_2bits(const uint8_t *in, size_t n, uint8_t *out);

/* 3-bit MSB-first pack/unpack. */
size_t ntv2_pack_3bits(const uint8_t *vals, size_t n, uint8_t *out);
void   ntv2_unpack_3bits(const uint8_t *in, size_t n, uint8_t *out);

/* LEB128 varints. Return # bytes written / read. */
size_t ntv2_uvarint_encode(uint64_t v, uint8_t *out);
size_t ntv2_uvarint_decode(const uint8_t *in, uint64_t *v);
size_t ntv2_svarint_encode(int64_t v, uint8_t *out);
size_t ntv2_svarint_decode(const uint8_t *in, int64_t *v);

#endif /* TTIO_NAME_TOK_V2_INTERNAL_H */
```

- [ ] **Step 4: Verify headers parse (no impl yet)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null 2>&1 && make ttio_rans 2>&1 | tail -5'
```

Expected: build succeeds; declarations are unreferenced (no link errors yet).

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/include/ttio_rans.h native/src/name_tok_v2.h && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 1): C header + error codes

ttio_name_tok_v2_encode/decode public entry points + internal header
with container constants (NTV2_MAGIC, FLAG values, substream IDs).
New error codes TTIO_RANS_ERR_NTV2_BAD_FLAG (-8) through _BAD_MAGIC (-13).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

### Task 2: Tokeniser + bit-packing helpers + tests (TDD)

**Files:**
- Create: `native/src/name_tok_v2.c` (helpers only — encoder/decoder stubs return -1)
- Create: `native/tests/test_name_tok_v2_helpers.c`
- Modify: `native/CMakeLists.txt`

- [ ] **Step 1: Write the failing helper tests**

```c
// native/tests/test_name_tok_v2_helpers.c
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "name_tok_v2.h"

static void test_tokenise_basic(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("READ:1:2", types, starts, lens, &n, nums);
    assert(rc == 0);
    assert(n == 4);
    assert(types[0] == NTV2_TOK_STR);  // "READ:"
    assert(types[1] == NTV2_TOK_NUM);  // 1
    assert(types[2] == NTV2_TOK_STR);  // ":"
    assert(types[3] == NTV2_TOK_NUM);  // 2
    assert(nums[1] == 1);
    assert(nums[3] == 2);
    assert(starts[0] == 0 && lens[0] == 5);
    assert(starts[1] == 5 && lens[1] == 1);
    printf("tokenise basic: PASS\n");
}

static void test_tokenise_leading_zero(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("r007:1", types, starts, lens, &n, nums);
    assert(rc == 0);
    assert(n == 2);
    assert(types[0] == NTV2_TOK_STR);  // "r007:" (007 invalid num)
    assert(types[1] == NTV2_TOK_NUM);  // 1
    assert(lens[0] == 5);
    printf("tokenise leading-zero: PASS\n");
}

static void test_pack_2bits(void) {
    uint8_t vals[8] = {0, 1, 2, 3, 0, 1, 2, 3};
    uint8_t out[2];
    size_t n = ntv2_pack_2bits(vals, 8, out);
    assert(n == 2);
    assert(out[0] == 0b00011011);  // 0,1,2,3 MSB first
    assert(out[1] == 0b00011011);
    uint8_t round[8];
    ntv2_unpack_2bits(out, 8, round);
    assert(memcmp(round, vals, 8) == 0);
    printf("pack 2bits roundtrip: PASS\n");
}

static void test_pack_3bits(void) {
    uint8_t vals[8] = {7, 0, 1, 2, 3, 4, 5, 6};
    uint8_t out[3];  // 8 * 3 / 8 = 3 bytes
    size_t n = ntv2_pack_3bits(vals, 8, out);
    assert(n == 3);
    uint8_t round[8];
    ntv2_unpack_3bits(out, 8, round);
    assert(memcmp(round, vals, 8) == 0);
    printf("pack 3bits roundtrip: PASS\n");
}

static void test_varint(void) {
    uint8_t buf[16];
    uint64_t v;
    int64_t s;
    /* Unsigned */
    size_t n = ntv2_uvarint_encode(127, buf);
    assert(n == 1 && buf[0] == 127);
    n = ntv2_uvarint_encode(128, buf);
    assert(n == 2);
    n = ntv2_uvarint_decode(buf, &v);
    assert(n == 2 && v == 128);
    /* Signed */
    n = ntv2_svarint_encode(-1, buf);
    n = ntv2_svarint_decode(buf, &s);
    assert(s == -1);
    n = ntv2_svarint_encode(63, buf);
    n = ntv2_svarint_decode(buf, &s);
    assert(s == 63);
    printf("varint roundtrip: PASS\n");
}

int main(void) {
    test_tokenise_basic();
    test_tokenise_leading_zero();
    test_pack_2bits();
    test_pack_3bits();
    test_varint();
    return 0;
}
```

Add to `native/CMakeLists.txt` test section:

```cmake
add_executable(test_name_tok_v2_helpers tests/test_name_tok_v2_helpers.c src/name_tok_v2.c)
target_link_libraries(test_name_tok_v2_helpers ttio_rans)
target_include_directories(test_name_tok_v2_helpers PRIVATE src include)
add_test(NAME test_name_tok_v2_helpers COMMAND test_name_tok_v2_helpers)
```

- [ ] **Step 2: Run to verify FAIL (no impl yet)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null 2>&1 && make test_name_tok_v2_helpers 2>&1 | tail -10'
```

Expected: link error (`ntv2_tokenise` etc undefined).

- [ ] **Step 3: Implement helpers**

```c
// native/src/name_tok_v2.c
#include "name_tok_v2.h"
#include "ttio_rans.h"
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int is_valid_num_run(const char *s, uint16_t len) {
    if (len == 1 && s[0] == '0') return 1;
    if (len >= 1 && s[0] == '0') return 0;
    return 1;
}

int ntv2_tokenise(const char *name,
                  uint8_t *types, uint16_t *starts, uint16_t *lens,
                  uint8_t *n_tokens, uint64_t *num_values) {
    if (name == NULL) return -1;
    size_t L = strlen(name);
    if (L == 0) { *n_tokens = 0; return 0; }
    if (L > 0xFFFF) return -1;
    /* Validate ASCII */
    for (size_t i = 0; i < L; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c > 0x7F) return -1;
    }
    uint8_t n = 0;
    size_t i = 0;
    while (i < L) {
        if (n >= 255) return -1;
        if (isdigit((unsigned char)name[i])) {
            /* Find run end */
            size_t j = i;
            while (j < L && isdigit((unsigned char)name[j])) j++;
            uint16_t run_len = (uint16_t)(j - i);
            if (is_valid_num_run(name + i, run_len)) {
                /* Numeric token */
                uint64_t v = 0;
                int overflow = 0;
                for (size_t k = i; k < j; k++) {
                    if (v > (UINT64_MAX - 9) / 10) { overflow = 1; break; }
                    v = v * 10 + (uint64_t)(name[k] - '0');
                }
                if (overflow) {
                    /* Demote to string token; merge with surrounding */
                    if (n > 0 && types[n-1] == NTV2_TOK_STR) {
                        lens[n-1] += run_len;
                    } else {
                        types[n] = NTV2_TOK_STR;
                        starts[n] = (uint16_t)i;
                        lens[n] = run_len;
                        n++;
                    }
                } else {
                    types[n] = NTV2_TOK_NUM;
                    starts[n] = (uint16_t)i;
                    lens[n] = run_len;
                    num_values[n] = v;
                    n++;
                }
            } else {
                /* Invalid num — absorb into surrounding string */
                if (n > 0 && types[n-1] == NTV2_TOK_STR) {
                    lens[n-1] += run_len;
                } else {
                    types[n] = NTV2_TOK_STR;
                    starts[n] = (uint16_t)i;
                    lens[n] = run_len;
                    n++;
                }
            }
            i = j;
        } else {
            /* String run until next valid-num-run boundary */
            size_t j = i;
            while (j < L) {
                if (isdigit((unsigned char)name[j])) {
                    size_t k = j;
                    while (k < L && isdigit((unsigned char)name[k])) k++;
                    if (is_valid_num_run(name + j, (uint16_t)(k - j))) {
                        break;  // valid num next — close current str
                    }
                    j = k;  // absorb invalid num
                } else {
                    j++;
                }
            }
            uint16_t run_len = (uint16_t)(j - i);
            if (n > 0 && types[n-1] == NTV2_TOK_STR) {
                lens[n-1] += run_len;
            } else {
                types[n] = NTV2_TOK_STR;
                starts[n] = (uint16_t)i;
                lens[n] = run_len;
                n++;
            }
            i = j;
        }
    }
    *n_tokens = n;
    return 0;
}

size_t ntv2_pack_2bits(const uint8_t *vals, size_t n, uint8_t *out) {
    size_t out_bytes = (n * 2 + 7) / 8;
    memset(out, 0, out_bytes);
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 2;
        size_t byte_idx = bit_pos / 8;
        size_t shift = 6 - (bit_pos % 8);
        out[byte_idx] |= (uint8_t)((vals[i] & 3) << shift);
    }
    return out_bytes;
}

void ntv2_unpack_2bits(const uint8_t *in, size_t n, uint8_t *out) {
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 2;
        size_t byte_idx = bit_pos / 8;
        size_t shift = 6 - (bit_pos % 8);
        out[i] = (uint8_t)((in[byte_idx] >> shift) & 3);
    }
}

size_t ntv2_pack_3bits(const uint8_t *vals, size_t n, uint8_t *out) {
    size_t out_bytes = (n * 3 + 7) / 8;
    memset(out, 0, out_bytes);
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 3;
        size_t byte_idx = bit_pos / 8;
        size_t in_byte = bit_pos % 8;
        if (in_byte + 3 <= 8) {
            size_t shift = 8 - in_byte - 3;
            out[byte_idx] |= (uint8_t)((vals[i] & 7) << shift);
        } else {
            size_t high_bits = 8 - in_byte;
            size_t low_bits = 3 - high_bits;
            uint8_t v = vals[i] & 7;
            out[byte_idx] |= (uint8_t)(v >> low_bits);
            out[byte_idx + 1] |= (uint8_t)((v & ((1U << low_bits) - 1)) << (8 - low_bits));
        }
    }
    return out_bytes;
}

void ntv2_unpack_3bits(const uint8_t *in, size_t n, uint8_t *out) {
    for (size_t i = 0; i < n; i++) {
        size_t bit_pos = i * 3;
        size_t byte_idx = bit_pos / 8;
        size_t in_byte = bit_pos % 8;
        if (in_byte + 3 <= 8) {
            size_t shift = 8 - in_byte - 3;
            out[i] = (uint8_t)((in[byte_idx] >> shift) & 7);
        } else {
            size_t high_bits = 8 - in_byte;
            size_t low_bits = 3 - high_bits;
            uint8_t high = in[byte_idx] & ((1U << high_bits) - 1);
            uint8_t low = (in[byte_idx + 1] >> (8 - low_bits)) & ((1U << low_bits) - 1);
            out[i] = (uint8_t)((high << low_bits) | low);
        }
    }
}

size_t ntv2_uvarint_encode(uint64_t v, uint8_t *out) {
    size_t n = 0;
    while (v >= 0x80) { out[n++] = (uint8_t)((v & 0x7F) | 0x80); v >>= 7; }
    out[n++] = (uint8_t)v;
    return n;
}

size_t ntv2_uvarint_decode(const uint8_t *in, uint64_t *v) {
    uint64_t r = 0;
    size_t shift = 0, n = 0;
    while (1) {
        uint8_t b = in[n++];
        r |= ((uint64_t)(b & 0x7F)) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) { *v = 0; return 0; }
    }
    *v = r;
    return n;
}

size_t ntv2_svarint_encode(int64_t v, uint8_t *out) {
    uint64_t z = ((uint64_t)v << 1) ^ (uint64_t)(v >> 63);
    return ntv2_uvarint_encode(z, out);
}

size_t ntv2_svarint_decode(const uint8_t *in, int64_t *v) {
    uint64_t u;
    size_t n = ntv2_uvarint_decode(in, &u);
    *v = (int64_t)((u >> 1) ^ -(u & 1));
    return n;
}

/* Stubs for full encoder/decoder — implemented in Task 3 */
size_t ttio_name_tok_v2_max_encoded_size(uint64_t n_reads, uint64_t total_name_bytes) {
    /* Worst case: header + per-read overhead + verbatim copy. */
    size_t hdr = NTV2_HEADER_FIXED + ((n_reads + NTV2_BLOCK_SIZE - 1) / NTV2_BLOCK_SIZE) * 4;
    size_t per_read_overhead = 32;  /* generous */
    return hdr + n_reads * per_read_overhead + total_name_bytes + 1024;
}

int ttio_name_tok_v2_encode(const char * const *names, uint64_t n_reads,
                            uint8_t *out, size_t *out_len) {
    (void)names; (void)n_reads; (void)out; (void)out_len;
    return -1;  /* stub */
}

int ttio_name_tok_v2_decode(const uint8_t *encoded, size_t encoded_size,
                            char ***out_names, uint64_t *out_n_reads) {
    (void)encoded; (void)encoded_size; (void)out_names; (void)out_n_reads;
    return -1;  /* stub */
}
```

- [ ] **Step 4: Verify tests PASS**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null 2>&1 && make test_name_tok_v2_helpers 2>&1 | tail -3 && ctest -R name_tok_v2_helpers --output-on-failure 2>&1 | tail -10'
```

Expected: 5 PASS lines + ctest pass.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/name_tok_v2.c native/tests/test_name_tok_v2_helpers.c native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 2): tokeniser + bit-pack helpers + tests

ntv2_tokenise (v1-compatible: 2 token types, leading-zero absorption,
overflow-as-string), ntv2_pack/unpack_2bits, ntv2_pack/unpack_3bits,
ntv2_uvarint/svarint codec. 5/5 ctest assertions pass.

Encode/decode entries are stubs; Task 3 fills them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

### Task 3: Full encoder + decoder + invariants

**Files:**
- Modify: `native/src/name_tok_v2.c` (replace stubs)
- Create: `native/tests/test_name_tok_v2_invariants.c`
- Modify: `native/CMakeLists.txt`

**Algorithm summary — exactly per spec §3 + §4:**

Encoder:
1. Tokenise all names (n_tokens, types, starts, lens, num_values per read).
2. Partition into blocks of ≤ 4096 reads.
3. Per block: scan reads; pick strategy (DUP > MATCH-K > COL > VERB) per spec §3.4.
4. Build 8 substreams in column-major order for NUM_DELTA / DICT_CODE.
5. For each substream auto-pick rANS-O0 (`ttio_rans_o0_encode`) vs raw (smallest wins).
6. Concatenate blocks; prepend container header with block-offset table.

Decoder: parse header → for each requested block (or all) → parse substreams (rANS-O0 decode if mode=01) → replay FLAG ladder per spec §3.8.

This is a substantial implementation (~1500-2000 LoC). Reference structure: `native/src/ref_diff_v2.c` (similar substream + auto-pick layout); `native/src/mate_info_v2.c` (rANS-O0 wiring pattern).

- [ ] **Step 1: Write the failing invariant tests**

```c
// native/tests/test_name_tok_v2_invariants.c
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ttio_rans.h"
#include "name_tok_v2.h"

static int round_trip(const char * const *names, uint64_t n) {
    size_t cap = ttio_name_tok_v2_max_encoded_size(n, 200 * n);
    uint8_t *enc = malloc(cap);
    size_t enc_len = cap;
    int rc = ttio_name_tok_v2_encode(names, n, enc, &enc_len);
    if (rc != 0) { free(enc); return rc; }
    if (memcmp(enc, "NTK2", 4) != 0) { free(enc); return -100; }

    char **dec = NULL;
    uint64_t dec_n = 0;
    rc = ttio_name_tok_v2_decode(enc, enc_len, &dec, &dec_n);
    if (rc != 0) { free(enc); return rc; }
    if (dec_n != n) { free(enc); free(dec); return -101; }
    for (uint64_t i = 0; i < n; i++) {
        if (strcmp(names[i], dec[i]) != 0) {
            fprintf(stderr, "mismatch at %llu: '%s' vs '%s'\n",
                    (unsigned long long)i, names[i], dec[i]);
            for (uint64_t j = 0; j < dec_n; j++) free(dec[j]);
            free(dec); free(enc);
            return -102;
        }
    }
    for (uint64_t i = 0; i < dec_n; i++) free(dec[i]);
    free(dec); free(enc);
    return 0;
}

static void test_empty(void) {
    int rc = round_trip(NULL, 0);
    assert(rc == 0);
    printf("I-empty: PASS\n");
}

static void test_single(void) {
    const char *n[] = {"EAS220_R1:8:1:0:1234"};
    assert(round_trip(n, 1) == 0);
    printf("I-single: PASS\n");
}

static void test_dup(void) {
    const char *n[] = {"X:1", "X:1"};
    assert(round_trip(n, 2) == 0);
    printf("I-dup: PASS\n");
}

static void test_match(void) {
    const char *n[] = {"X:1", "X:2", "X:3"};
    assert(round_trip(n, 3) == 0);
    printf("I-match: PASS\n");
}

static void test_columnar(void) {
    char *names[50];
    for (int i = 0; i < 50; i++) {
        names[i] = malloc(64);
        snprintf(names[i], 64, "EAS:R1:8:1:0:%d", 1000 + i);
    }
    assert(round_trip((const char * const *)names, 50) == 0);
    for (int i = 0; i < 50; i++) free(names[i]);
    printf("I-columnar50: PASS\n");
}

static void test_two_blocks(void) {
    /* 4097 reads — forces 2-block split */
    char **names = malloc(sizeof(char*) * 4097);
    for (int i = 0; i < 4097; i++) {
        names[i] = malloc(32);
        snprintf(names[i], 32, "R:1:%d", i);
    }
    assert(round_trip((const char * const *)names, 4097) == 0);
    for (int i = 0; i < 4097; i++) free(names[i]);
    free(names);
    printf("I-2blocks: PASS\n");
}

static void test_mixed_shapes(void) {
    const char *n[] = {"R:1", "weirdname", "R:2"};
    assert(round_trip(n, 3) == 0);
    printf("I-mixed-shapes: PASS\n");
}

int main(void) {
    test_empty();
    test_single();
    test_dup();
    test_match();
    test_columnar();
    test_two_blocks();
    test_mixed_shapes();
    return 0;
}
```

Add to `native/CMakeLists.txt`:

```cmake
add_executable(test_name_tok_v2_invariants tests/test_name_tok_v2_invariants.c src/name_tok_v2.c)
target_link_libraries(test_name_tok_v2_invariants ttio_rans)
target_include_directories(test_name_tok_v2_invariants PRIVATE src include)
add_test(NAME test_name_tok_v2_invariants COMMAND test_name_tok_v2_invariants)
```

- [ ] **Step 2: Run to verify FAIL (encode/decode are stubs)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null 2>&1 && make test_name_tok_v2_invariants 2>&1 | tail -3 && ctest -R name_tok_v2_invariants --output-on-failure 2>&1 | tail -5'
```

Expected: ctest fails (encode returns -1).

- [ ] **Step 3: Implement encoder + decoder**

Replace the stubs in `native/src/name_tok_v2.c`. The implementation is substantial — follow this structure (mirroring ref_diff_v2.c's style):

```c
/* Forward declarations */
static int encode_block(const char * const *names, size_t block_n,
                        size_t pool_size,
                        uint8_t *out, size_t *out_len);
static int decode_block(const uint8_t *in, size_t in_len,
                        size_t pool_size,
                        char ***out_names, size_t *out_n);
static int auto_pick_substream(const uint8_t *raw, size_t raw_len,
                               uint8_t *out, size_t *out_len);
static int decode_substream(const uint8_t *in, size_t in_len,
                            uint8_t **out_raw, size_t *out_raw_len,
                            size_t *consumed);

/* Per-block scratch state */
typedef struct {
    /* Tokenised reads */
    uint8_t **types_per_read;     /* [n_reads][n_tokens_i] */
    uint16_t **starts_per_read;
    uint16_t **lens_per_read;
    uint64_t **nums_per_read;
    uint8_t  *n_tokens_per_read;
    /* Pool */
    char    **pool_names;          /* string pool */
    uint8_t **pool_types;
    uint64_t **pool_nums;
    uint16_t **pool_starts;
    uint16_t **pool_lens;
    uint8_t  *pool_n_tokens;
    size_t    pool_len;
    /* Strategy outcomes */
    uint8_t  *flags;               /* [n_reads] */
    uint8_t  *pool_indices;        /* [n_reads] (only valid for DUP/MATCH) */
    uint64_t *match_ks;            /* [n_reads] (only valid for MATCH) */
    /* Block COL_TYPES */
    int       block_col_types_set;
    uint8_t   block_n_cols;
    uint8_t   block_col_types[256];
    /* Per-column delta state */
    uint64_t  col_num_prev[256];
    int       col_num_seeded[256];
    /* Per-column dict state */
    char    ***col_dict_entries;   /* [n_cols][dict_size] of strings */
    size_t   *col_dict_sizes;
    /* Substream builders */
    /* ... */
} block_ctx_t;
```

Implementation details (continued in Step 3 — write the full encoder + decoder following the spec §3 + §4 exactly. Reference: `native/src/ref_diff_v2.c` for the substream auto-pick + container header builder pattern; `native/src/mate_info_v2.c` for the rANS-O0 wrapping). Total expected: ~1500 LoC.

Key invariants the implementer MUST maintain:

1. Encoder strategy priority: DUP > MATCH-K (largest K, then smallest pool_idx) > COL > VERB.
2. MATCH-K legal only if row's tokenisation matches block COL_TYPES AND pool entry's first K cols match block COL_TYPES first K col types.
3. Pool FIFO: push at end, pop from front when len > N=8.
4. Per-column delta state updates for matched cols [0,K) on MATCH-K (use pool entry's value).
5. NUM_DELTA / DICT_CODE column-major: walk col 0 across all contributing rows, then col 1, etc.
6. Dict literals appended in append-order across all string columns × rows.
7. rANS-O0 auto-pick: smaller of `ttio_rans_o0_encode(raw)` vs raw; equal sizes → mode 0x00.

Decoder must validate ALL §4.4 invariants (stream length, magic, version, reserved bits, n_blocks bound, pool_idx bound, K bound, col-type match, mode validity, substream length sum, dict-code overflow).

- [ ] **Step 4: Run to verify all PASS**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null 2>&1 && make test_name_tok_v2_invariants 2>&1 | tail -3 && ctest -R name_tok_v2_invariants --output-on-failure 2>&1 | tail -10'
```

Expected: 7 PASS lines + ctest pass.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/name_tok_v2.c native/tests/test_name_tok_v2_invariants.c native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 3): C encoder + decoder + invariants

ttio_name_tok_v2_encode/decode full impl: DUP-pool (N=8), PREFIX-MATCH,
COL, VERB strategies; 8 substreams with rANS-O0 auto-pick; block reset
at 4096 reads. 7/7 invariant tests pass (empty, single, dup, match,
columnar50, 2blocks, mixed-shapes).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

### Task 4: Stress test + edge invariants

**Files:**
- Create: `native/tests/test_name_tok_v2_stress.c`
- Modify: `native/CMakeLists.txt`

- [ ] **Step 1: Stress test**

```c
// native/tests/test_name_tok_v2_stress.c
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ttio_rans.h"
#include "name_tok_v2.h"

static char *random_name(unsigned *seed) {
    /* Generate Illumina-style structured names with variation */
    char *out = malloc(64);
    int run = rand_r(seed) % 8;
    int lane = rand_r(seed) % 8 + 1;
    int tile = rand_r(seed) % 100;
    int x = rand_r(seed) % 5000;
    int y = rand_r(seed) % 5000;
    snprintf(out, 64, "EAS%d_R1:%d:%d:%d:%d", run, lane, tile, x, y);
    return out;
}

static void test_random_corpus(uint64_t n) {
    unsigned seed = 42;
    char **names = malloc(sizeof(char*) * n);
    for (uint64_t i = 0; i < n; i++) {
        names[i] = random_name(&seed);
    }

    size_t cap = ttio_name_tok_v2_max_encoded_size(n, n * 64);
    uint8_t *enc = malloc(cap);
    size_t enc_len = cap;
    int rc = ttio_name_tok_v2_encode((const char * const *)names, n, enc, &enc_len);
    assert(rc == 0);

    char **dec = NULL;
    uint64_t dec_n = 0;
    rc = ttio_name_tok_v2_decode(enc, enc_len, &dec, &dec_n);
    assert(rc == 0);
    assert(dec_n == n);
    for (uint64_t i = 0; i < n; i++) {
        assert(strcmp(names[i], dec[i]) == 0);
        free(names[i]);
        free(dec[i]);
    }
    free(names); free(dec); free(enc);
    printf("stress n=%llu: PASS\n", (unsigned long long)n);
}

static void test_malformed_inputs(void) {
    /* Bad magic */
    uint8_t bad_magic[12] = {'X','X','X','X', 0x01, 0x00, 0,0,0,0, 0,0};
    char **dec = NULL;
    uint64_t dec_n = 0;
    int rc = ttio_name_tok_v2_decode(bad_magic, 12, &dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_NTV2_BAD_MAGIC);

    /* Bad version */
    uint8_t bad_version[12] = {'N','T','K','2', 0x99, 0x00, 0,0,0,0, 0,0};
    rc = ttio_name_tok_v2_decode(bad_version, 12, &dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_NTV2_BAD_VERSION);

    /* Truncated header */
    rc = ttio_name_tok_v2_decode(bad_magic, 5, &dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_PARAM || rc == TTIO_RANS_ERR_CORRUPT);

    printf("malformed inputs: PASS\n");
}

int main(void) {
    test_random_corpus(100);
    test_random_corpus(10000);
    test_random_corpus(50000);
    test_malformed_inputs();
    return 0;
}
```

Wire into `native/CMakeLists.txt`:

```cmake
add_executable(test_name_tok_v2_stress tests/test_name_tok_v2_stress.c src/name_tok_v2.c)
target_link_libraries(test_name_tok_v2_stress ttio_rans)
target_include_directories(test_name_tok_v2_stress PRIVATE src include)
add_test(NAME test_name_tok_v2_stress COMMAND test_name_tok_v2_stress)
```

- [ ] **Step 2: Run + verify**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake .. > /dev/null 2>&1 && make test_name_tok_v2_stress 2>&1 | tail -3 && ctest -R name_tok_v2 --output-on-failure 2>&1 | tail -10'
```

Expected: 4 PASS lines + all 3 v2 ctests pass.

- [ ] **Step 3: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/tests/test_name_tok_v2_stress.c native/CMakeLists.txt && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 4): stress + malformed-input tests

100 / 10000 / 50000 random Illumina-style names round-trip cleanly.
Malformed inputs (bad magic, bad version, truncated header) reject
with the spec'd TTIO_RANS_ERR_NTV2_BAD_* codes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 2 — Python ctypes binding (Tasks 5-6)

### Task 5: Python ctypes wrapper

**Files:**
- Create: `python/src/ttio/codecs/name_tokenizer_v2.py`
- Create: `python/tests/test_name_tokenizer_v2_native.py`

Pattern: mirror `python/src/ttio/codecs/ref_diff_v2.py` (commit `e08bb31`). ctypes loader reused from `fqzcomp_nx16_z._native_lib`.

- [ ] **Step 1: Implement the wrapper**

```python
# python/src/ttio/codecs/name_tokenizer_v2.py
"""Python ctypes wrapper for NAME_TOKENIZED v2."""
from __future__ import annotations

import ctypes

from .fqzcomp_nx16_z import _native_lib, _HAVE_NATIVE_LIB

HAVE_NATIVE_LIB: bool = _HAVE_NATIVE_LIB

ERR_PARAM = -1
ERR_CORRUPT = -3
ERR_NTV2_BAD_FLAG = -8
ERR_NTV2_POOL_OOB = -9
ERR_NTV2_BAD_K = -10
ERR_NTV2_DICT_OVERFLOW = -11
ERR_NTV2_BAD_VERSION = -12
ERR_NTV2_BAD_MAGIC = -13

_ERR_MESSAGES = {
    ERR_PARAM: "invalid parameters",
    ERR_CORRUPT: "corrupt encoded blob",
    ERR_NTV2_BAD_FLAG: "name_tok_v2: invalid 2-bit FLAG",
    ERR_NTV2_POOL_OOB: "name_tok_v2: pool_idx out of range",
    ERR_NTV2_BAD_K: "name_tok_v2: K=0 or K>=n_cols",
    ERR_NTV2_DICT_OVERFLOW: "name_tok_v2: dict code > dict size",
    ERR_NTV2_BAD_VERSION: "name_tok_v2: bad container version",
    ERR_NTV2_BAD_MAGIC: "name_tok_v2: magic != NTK2",
}


if HAVE_NATIVE_LIB:
    _lib = _native_lib

    _lib.ttio_name_tok_v2_max_encoded_size.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    _lib.ttio_name_tok_v2_max_encoded_size.restype = ctypes.c_size_t

    _lib.ttio_name_tok_v2_encode.argtypes = [
        ctypes.POINTER(ctypes.c_char_p),  # names
        ctypes.c_uint64,                   # n_reads
        ctypes.POINTER(ctypes.c_uint8),    # out
        ctypes.POINTER(ctypes.c_size_t),   # out_len
    ]
    _lib.ttio_name_tok_v2_encode.restype = ctypes.c_int

    _lib.ttio_name_tok_v2_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),         # encoded
        ctypes.c_size_t,                         # encoded_size
        ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)),  # out_names
        ctypes.POINTER(ctypes.c_uint64),         # out_n_reads
    ]
    _lib.ttio_name_tok_v2_decode.restype = ctypes.c_int


def encode(names: list[str]) -> bytes:
    if not HAVE_NATIVE_LIB:
        raise RuntimeError("name_tokenizer_v2.encode requires libttio_rans (set TTIO_RANS_LIB_PATH)")
    n = len(names)
    if n == 0:
        # Encode empty in one call still — let C handle
        pass
    encoded_names = [name.encode("ascii") for name in names]
    name_arr = (ctypes.c_char_p * n)(*encoded_names) if n > 0 else (ctypes.c_char_p * 1)()
    total_bytes = sum(len(n) for n in encoded_names)
    cap = _lib.ttio_name_tok_v2_max_encoded_size(n, total_bytes)
    out = (ctypes.c_uint8 * cap)()
    out_len = ctypes.c_size_t(cap)
    rc = _lib.ttio_name_tok_v2_encode(name_arr, n, out, ctypes.byref(out_len))
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    return bytes(out[:out_len.value])


def decode(blob: bytes) -> list[str]:
    if not HAVE_NATIVE_LIB:
        raise RuntimeError("name_tokenizer_v2.decode requires libttio_rans")
    enc_arr = (ctypes.c_uint8 * len(blob)).from_buffer_copy(blob)
    out_names_ptr = ctypes.POINTER(ctypes.c_char_p)()
    out_n = ctypes.c_uint64(0)
    rc = _lib.ttio_name_tok_v2_decode(enc_arr, len(blob),
                                       ctypes.byref(out_names_ptr),
                                       ctypes.byref(out_n))
    if rc != 0:
        raise RuntimeError(_ERR_MESSAGES.get(rc, f"native error {rc}"))
    n = out_n.value
    result: list[str] = []
    libc = ctypes.CDLL("libc.so.6")
    libc.free.argtypes = [ctypes.c_void_p]
    for i in range(n):
        s = out_names_ptr[i]
        result.append(s.decode("ascii") if s else "")
        libc.free(s)
    libc.free(ctypes.cast(out_names_ptr, ctypes.c_void_p))
    return result


def get_backend_name() -> str:
    return "native" if HAVE_NATIVE_LIB else "pure-python"
```

- [ ] **Step 2: Native round-trip test**

```python
# python/tests/test_name_tokenizer_v2_native.py
from __future__ import annotations
import pytest

from ttio.codecs import name_tokenizer_v2 as nt2

if not nt2.HAVE_NATIVE_LIB:
    pytest.skip("requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
                allow_module_level=True)


def test_empty():
    assert nt2.decode(nt2.encode([])) == []


@pytest.mark.parametrize("names", [
    ["EAS220_R1:8:1:0:1234"],
    ["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1234"],  # DUP
    ["EAS220_R1:8:1:0:1234", "EAS220_R1:8:1:0:1235"],  # MATCH-K
    [f"EAS:1:{i}" for i in range(50)],                  # COL
    ["weird1", "weird2"],                                # may fall to VERB
])
def test_round_trip(names):
    assert nt2.decode(nt2.encode(names)) == names


def test_two_blocks():
    names = [f"R:1:{i}" for i in range(4097)]
    assert nt2.decode(nt2.encode(names)) == names


def test_bad_magic_raises():
    with pytest.raises(RuntimeError, match="magic"):
        nt2.decode(b"XXXX" + b"\x01\x00" + b"\x00" * 6)


def test_backend():
    assert nt2.get_backend_name() == "native"
```

- [ ] **Step 3: Run + commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/test_name_tokenizer_v2_native.py -v 2>&1 | tail -15'
```

Expected: 8 PASS.

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/src/ttio/codecs/name_tokenizer_v2.py python/tests/test_name_tokenizer_v2_native.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 5): Python ctypes wrapper

encode(names) -> bytes, decode(blob) -> list[str], backend introspection.
Reuses fqzcomp_nx16_z _native_lib loader. Magic check b'NTK2'. C-malloc
output strings freed via libc.free.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

### Task 6: v1↔v2 oracle test (chr22)

Per spec §15 layer 2 + Phase 0 baseline measurement. Extract chr22 read names from BAM, encode via both v1 and v2, assert v2 round-trips and measure savings.

**Files:**
- Create: `python/tests/integration/test_name_tok_v2_v1_oracle.py`

- [ ] **Step 1: Implement test**

```python
# python/tests/integration/test_name_tok_v2_v1_oracle.py
from __future__ import annotations
import os
import subprocess
import pytest

from ttio.codecs import name_tokenizer as nt1
from ttio.codecs import name_tokenizer_v2 as nt2

CHR22_BAM = "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam"


@pytest.mark.integration
def test_chr22_v2_round_trip_and_baseline():
    if not nt2.HAVE_NATIVE_LIB:
        pytest.skip("native lib not loaded")
    if not os.path.exists(CHR22_BAM):
        pytest.skip(f"BAM not found: {CHR22_BAM}")

    proc = subprocess.run(["samtools", "view", CHR22_BAM],
                          capture_output=True, check=True)
    names = []
    for line in proc.stdout.split(b"\n"):
        if not line:
            continue
        qname = line.split(b"\t", 1)[0].decode("ascii")
        names.append(qname)

    v1_blob = nt1.encode(names)
    v2_blob = nt2.encode(names)

    # Round-trip
    decoded = nt2.decode(v2_blob)
    assert decoded == names

    # Baseline measurement
    v1_size = len(v1_blob)
    v2_size = len(v2_blob)
    savings = v1_size - v2_size
    print(f"\nchr22 read_names sizes:")
    print(f"  v1 NAME_TOKENIZED: {v1_size:>10,} bytes ({v1_size / 1024 / 1024:.2f} MB)")
    print(f"  v2 NAME_TOKENIZED: {v2_size:>10,} bytes ({v2_size / 1024 / 1024:.2f} MB)")
    print(f"  Savings:            {savings:>10,} bytes ({savings / 1024 / 1024:.2f} MB)")
    # Soft assertion at this stage — Phase 0 already validated the gate
    assert savings >= 2_500_000, f"v2 savings {savings} below floor — expected ≥ 3 MB at this stage"
```

- [ ] **Step 2: Run + commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_name_tok_v2_v1_oracle.py -m integration -v -s 2>&1 | tail -10'
```

Expected: PASS with savings printed.

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/tests/integration/test_name_tok_v2_v1_oracle.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(#11 ch3 task 6): v1<->v2 oracle on chr22

Extract 1.77M chr22 read names; encode via both v1 NAME_TOKENIZED and
v2 NAME_TOKENIZED_V2 wrappers; assert round-trip + savings >= 2.5 MB
(soft floor; Phase 0 + Task 15 enforce the 3 MB hard gate).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 3 — Java JNI binding (Tasks 7-8)

### Task 7: Java JNI binding + NameTokenizerV2 codec class

Mirrors ref_diff v2 T7 (commit `94d8be4`). Add JNI bridge functions to `native/src/ttio_rans_jni.c`, native method declarations + public wrappers to `TtioRansNative.java`, new `NameTokenizerV2.java` codec class with `List<String>` round-trip API, `NameTokenizerV2Test.java` round-trip test.

JNI marshalling: Java `String[]` → C `const char **`. Pattern: extract to `byte[][]` of UTF-8/ASCII, allocate `(char *) malloc` array, copy each, free after C call.

- [ ] **Step 1: Add JNI bridge functions**

In `native/src/ttio_rans_jni.c`, add (after the ref_diff v2 JNI functions):

```c
JNIEXPORT jbyteArray JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_encodeNameTokV2Native(
    JNIEnv *env, jclass cls, jobjectArray names_jarr) {
    jsize n = (*env)->GetArrayLength(env, names_jarr);
    const char **c_names = malloc(sizeof(char*) * (n > 0 ? n : 1));
    if (!c_names) {
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/OutOfMemoryError"), "JNI alloc");
        return NULL;
    }
    /* Hold jstrings for release */
    jstring *jstrs = malloc(sizeof(jstring) * (n > 0 ? n : 1));
    for (jsize i = 0; i < n; i++) {
        jstrs[i] = (jstring)(*env)->GetObjectArrayElement(env, names_jarr, i);
        c_names[i] = (*env)->GetStringUTFChars(env, jstrs[i], NULL);
    }
    /* Estimate total bytes */
    size_t total = 0;
    for (jsize i = 0; i < n; i++) total += strlen(c_names[i]);
    size_t cap = ttio_name_tok_v2_max_encoded_size((uint64_t)n, (uint64_t)total);
    uint8_t *out = malloc(cap);
    size_t out_len = cap;
    int rc = ttio_name_tok_v2_encode(c_names, (uint64_t)n, out, &out_len);
    /* Release strings */
    for (jsize i = 0; i < n; i++) {
        (*env)->ReleaseStringUTFChars(env, jstrs[i], c_names[i]);
    }
    free(c_names); free(jstrs);
    if (rc != 0) {
        free(out);
        char msg[64];
        snprintf(msg, sizeof(msg), "name_tok_v2 encode rc=%d", rc);
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/RuntimeException"), msg);
        return NULL;
    }
    jbyteArray jout = (*env)->NewByteArray(env, (jsize)out_len);
    (*env)->SetByteArrayRegion(env, jout, 0, (jsize)out_len, (const jbyte*)out);
    free(out);
    return jout;
}

JNIEXPORT jobjectArray JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_decodeNameTokV2Native(
    JNIEnv *env, jclass cls, jbyteArray blob_jarr) {
    jsize blob_len = (*env)->GetArrayLength(env, blob_jarr);
    jbyte *blob = (*env)->GetByteArrayElements(env, blob_jarr, NULL);
    char **out_names = NULL;
    uint64_t out_n = 0;
    int rc = ttio_name_tok_v2_decode((const uint8_t*)blob, (size_t)blob_len, &out_names, &out_n);
    (*env)->ReleaseByteArrayElements(env, blob_jarr, blob, JNI_ABORT);
    if (rc != 0) {
        char msg[64];
        snprintf(msg, sizeof(msg), "name_tok_v2 decode rc=%d", rc);
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/RuntimeException"), msg);
        return NULL;
    }
    jclass strcls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray jout = (*env)->NewObjectArray(env, (jsize)out_n, strcls, NULL);
    for (uint64_t i = 0; i < out_n; i++) {
        jstring js = (*env)->NewStringUTF(env, out_names[i]);
        (*env)->SetObjectArrayElement(env, jout, (jsize)i, js);
        (*env)->DeleteLocalRef(env, js);
        free(out_names[i]);
    }
    free(out_names);
    return jout;
}
```

- [ ] **Step 2: Add Java native declarations**

In `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java`, after ref_diff v2 entries:

```java
public static native byte[] encodeNameTokV2Native(String[] names);
public static native String[] decodeNameTokV2Native(byte[] blob);
```

- [ ] **Step 3: Implement codec class**

```java
// java/src/main/java/global/thalion/ttio/codecs/NameTokenizerV2.java
package global.thalion.ttio.codecs;

import java.util.Arrays;
import java.util.List;

public final class NameTokenizerV2 {
    private NameTokenizerV2() {}

    public static byte[] encode(List<String> names) {
        if (names == null) throw new IllegalArgumentException("names null");
        return TtioRansNative.encodeNameTokV2Native(names.toArray(new String[0]));
    }

    public static List<String> decode(byte[] blob) {
        if (blob == null || blob.length < 12) throw new IllegalArgumentException("blob too short");
        return Arrays.asList(TtioRansNative.decodeNameTokV2Native(blob));
    }

    public static String getBackendName() {
        return "native-jni";
    }
}
```

- [ ] **Step 4: Test**

```java
// java/src/test/java/global/thalion/ttio/codecs/NameTokenizerV2Test.java
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

public class NameTokenizerV2Test {
    @Test
    public void emptyRoundTrip() {
        assertEquals(0, NameTokenizerV2.decode(NameTokenizerV2.encode(List.of())).size());
    }

    @Test
    public void singleRoundTrip() {
        var names = List.of("EAS220_R1:8:1:0:1234");
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }

    @Test
    public void columnarBatchRoundTrip() {
        var names = new java.util.ArrayList<String>();
        for (int i = 0; i < 100; i++) names.add("EAS:1:" + i);
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }

    @Test
    public void twoBlockRoundTrip() {
        var names = new java.util.ArrayList<String>();
        for (int i = 0; i < 4097; i++) names.add("R:1:" + i);
        assertEquals(names, NameTokenizerV2.decode(NameTokenizerV2.encode(names)));
    }
}
```

- [ ] **Step 5: Build + run**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/native/_build && cmake -DTTIO_RANS_BUILD_JNI=ON .. > /dev/null 2>&1 && make ttio_rans 2>&1 | tail -3'
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/java && mvn -Dhdf5.native.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial:/home/toddw/TTI-O/native/_build test -Dtest=NameTokenizerV2Test 2>&1 | tail -20'
```

Expected: 4 PASS in mvn output.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add native/src/ttio_rans_jni.c java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java java/src/main/java/global/thalion/ttio/codecs/NameTokenizerV2.java java/src/test/java/global/thalion/ttio/codecs/NameTokenizerV2Test.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 7): Java JNI binding

JNI bridges encodeNameTokV2Native / decodeNameTokV2Native marshal
String[]<->const char**. NameTokenizerV2 codec class with List<String>
API. 4/4 mvn tests pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

### Task 8: Java CLI tool NameTokenizedV2Cli

Mirror ref_diff v2 T8 (commit `c526ea3`). Reads pre-extracted names from a text file (one name per line), encodes via `NameTokenizerV2.encode`, writes blob.

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/tools/NameTokenizedV2Cli.java`

- [ ] **Step 1: Implement CLI**

```java
// java/src/main/java/global/thalion/ttio/tools/NameTokenizedV2Cli.java
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.NameTokenizerV2;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

public class NameTokenizedV2Cli {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("Usage: NameTokenizedV2Cli <names.txt> <out.bin>");
            System.exit(1);
        }
        List<String> names = new ArrayList<>();
        for (String line : Files.readAllLines(Path.of(args[0]))) {
            names.add(line);
        }
        byte[] blob = NameTokenizerV2.encode(names);
        Files.write(Path.of(args[1]), blob);
        System.out.printf("encoded %d names -> %d bytes%n", names.size(), blob.length);
    }
}
```

- [ ] **Step 2: Smoke-run**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/java && mvn package -DskipTests 2>&1 | tail -3'
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && printf "X:1\nX:2\nX:3\n" > /tmp/n.txt && java -Djava.library.path=/home/toddw/TTI-O/native/_build -cp java/target/ttio-*.jar global.thalion.ttio.tools.NameTokenizedV2Cli /tmp/n.txt /tmp/n.bin && head -c 4 /tmp/n.bin | xxd'
```

Expected: encoded blob's first 4 bytes are `4e 54 4b 32` ("NTK2").

- [ ] **Step 3: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add java/src/main/java/global/thalion/ttio/tools/NameTokenizedV2Cli.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 8): Java CLI for cross-lang gate

Reads names (one per line) from arg[0], encodes via NameTokenizerV2,
writes blob to arg[1]. Used by Task 11 cross-lang byte-exact gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 4 — ObjC direct link (Tasks 9-10)

### Task 9: ObjC TTIONameTokenizerV2 codec + round-trip test

Mirror ref_diff v2 T9 (commit `12ac82e`). `objc/Source/Codecs/TTIONameTokenizerV2.{h,m}` direct-link to libttio_rans, NSError plumbing, `objc/Tests/TestNameTokenizerV2.m` with round-trip + invalid-input tests, wire into `Source/GNUmakefile` + `Tests/GNUmakefile` + `TTIOTestRunner.m`.

- [ ] **Step 1: Implement codec class**

```objc
// objc/Source/Codecs/TTIONameTokenizerV2.h
#import <Foundation/Foundation.h>

@interface TTIONameTokenizerV2 : NSObject
+ (NSData *)encodeNames:(NSArray<NSString *> *)names;
+ (NSArray<NSString *> *)decodeData:(NSData *)blob error:(NSError **)error;
+ (NSString *)backendName;
@end
```

```objc
// objc/Source/Codecs/TTIONameTokenizerV2.m
#import "Codecs/TTIONameTokenizerV2.h"
#import "ttio_rans.h"
#import <stdlib.h>
#import <string.h>

@implementation TTIONameTokenizerV2

+ (NSData *)encodeNames:(NSArray<NSString *> *)names {
    NSUInteger n = names.count;
    const char **c_names = (const char **)malloc(sizeof(char*) * (n > 0 ? n : 1));
    NSMutableArray *holders = [NSMutableArray arrayWithCapacity:n];
    NSUInteger total_bytes = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *s = names[i];
        const char *cs = [s cStringUsingEncoding:NSASCIIStringEncoding];
        if (cs == NULL) {
            free(c_names);
            [NSException raise:NSInvalidArgumentException
                        format:@"non-ASCII name at index %lu", (unsigned long)i];
        }
        size_t L = strlen(cs);
        char *copy = malloc(L + 1);
        memcpy(copy, cs, L + 1);
        c_names[i] = copy;
        total_bytes += L;
        [holders addObject:[NSValue valueWithPointer:copy]];
    }
    size_t cap = ttio_name_tok_v2_max_encoded_size((uint64_t)n, (uint64_t)total_bytes);
    uint8_t *out = malloc(cap);
    size_t out_len = cap;
    int rc = ttio_name_tok_v2_encode(c_names, (uint64_t)n, out, &out_len);
    for (NSValue *v in holders) free([v pointerValue]);
    free(c_names);
    if (rc != 0) {
        free(out);
        [NSException raise:NSInvalidArgumentException format:@"name_tok_v2 encode rc=%d", rc];
    }
    NSData *result = [NSData dataWithBytes:out length:out_len];
    free(out);
    return result;
}

+ (NSArray<NSString *> *)decodeData:(NSData *)blob error:(NSError **)error {
    char **out_names = NULL;
    uint64_t out_n = 0;
    int rc = ttio_name_tok_v2_decode((const uint8_t*)blob.bytes, blob.length, &out_names, &out_n);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TTIONameTokenizerV2"
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"decode rc=%d", rc]}];
        }
        return nil;
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:(NSUInteger)out_n];
    for (uint64_t i = 0; i < out_n; i++) {
        [result addObject:[NSString stringWithCString:out_names[i] encoding:NSASCIIStringEncoding] ?: @""];
        free(out_names[i]);
    }
    free(out_names);
    return result;
}

+ (NSString *)backendName { return @"native"; }

@end
```

- [ ] **Step 2: Tests**

```objc
// objc/Tests/Codecs/TestNameTokenizerV2.m
#import <Foundation/Foundation.h>
#import "TTIOTestUtilities.h"
#import "Codecs/TTIONameTokenizerV2.h"

void TestNameTokenizerV2_RoundTrip(void) {
    NSArray *names = @[@"EAS220_R1:8:1:0:1234",
                       @"EAS220_R1:8:1:0:1234",
                       @"EAS220_R1:8:1:0:1235"];
    NSData *blob = [TTIONameTokenizerV2 encodeNames:names];
    TTIOAssertNotNil(blob, @"encode produced data");
    TTIOAssertTrue(blob.length >= 12, @"at least header bytes");

    NSError *err = nil;
    NSArray *decoded = [TTIONameTokenizerV2 decodeData:blob error:&err];
    TTIOAssertNil(err, @"no decode error");
    TTIOAssertEqualObjects(decoded, names, @"round-trip");
}

void TestNameTokenizerV2_TwoBlocks(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (int i = 0; i < 4097; i++) {
        [names addObject:[NSString stringWithFormat:@"R:1:%d", i]];
    }
    NSData *blob = [TTIONameTokenizerV2 encodeNames:names];
    NSError *err = nil;
    NSArray *decoded = [TTIONameTokenizerV2 decodeData:blob error:&err];
    TTIOAssertNil(err, @"no error");
    TTIOAssertEqualObjects(decoded, names, @"4097-name round-trip");
}

void TestNameTokenizerV2_BadMagic(void) {
    uint8_t bad[12] = {'X','X','X','X', 0x01, 0x00, 0,0,0,0, 0,0};
    NSData *blob = [NSData dataWithBytes:bad length:12];
    NSError *err = nil;
    NSArray *decoded = [TTIONameTokenizerV2 decodeData:blob error:&err];
    TTIOAssertNil(decoded, @"nil on bad magic");
    TTIOAssertNotNil(err, @"error set");
}
```

- [ ] **Step 3: Wire into makefiles + test runner**

In `objc/Source/GNUmakefile` add `TTIONameTokenizerV2.m` to the codecs source list (mirroring TTIORefDiffV2.m); `objc/Source/Codecs/TTIONameTokenizerV2.h` to headers.

In `objc/Tests/GNUmakefile` add `Codecs/TestNameTokenizerV2.m`.

In `objc/Tests/TTIOTestRunner.m`, add 3 invocations:
```objc
RUN_TEST(TestNameTokenizerV2_RoundTrip);
RUN_TEST(TestNameTokenizerV2_TwoBlocks);
RUN_TEST(TestNameTokenizerV2_BadMagic);
```

- [ ] **Step 4: Build + run**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/objc && bash build.sh check 2>&1 | tail -15'
```

Expected: 3 new tests PASS (count goes up by 3).

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add objc/Source/Codecs/TTIONameTokenizerV2.h objc/Source/Codecs/TTIONameTokenizerV2.m objc/Tests/Codecs/TestNameTokenizerV2.m objc/Source/GNUmakefile objc/Tests/GNUmakefile objc/Tests/TTIOTestRunner.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 9): ObjC TTIONameTokenizerV2 + round-trip tests

Direct-link to libttio_rans (per feedback_libttio_rans_api_layers).
NSError plumbing on decode, NSException on encode bad-input. 3/3
new ctest cases pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

### Task 10: ObjC CLI tool TtioNameTokV2Cli

Mirror ref_diff v2 T10 (commit `960536b`). `objc/Tools/TtioNameTokV2Cli.m` reads names from text file, encodes, writes blob. Wire into `objc/Tools/GNUmakefile`.

- [ ] **Step 1: Implement CLI**

```objc
// objc/Tools/TtioNameTokV2Cli.m
#import <Foundation/Foundation.h>
#import "Codecs/TTIONameTokenizerV2.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s <names.txt> <out.bin>\n", argv[0]);
            return 1;
        }
        NSString *txt = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
                                                  encoding:NSUTF8StringEncoding error:NULL];
        NSArray *names = [txt componentsSeparatedByString:@"\n"];
        NSMutableArray *clean = [NSMutableArray array];
        for (NSString *s in names) if (s.length > 0) [clean addObject:s];
        NSData *blob = [TTIONameTokenizerV2 encodeNames:clean];
        [blob writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
        fprintf(stdout, "encoded %lu names -> %lu bytes\n",
                (unsigned long)clean.count, (unsigned long)blob.length);
    }
    return 0;
}
```

- [ ] **Step 2: Wire into `objc/Tools/GNUmakefile` (mirror TtioRefDiffV2Cli stanza)**

- [ ] **Step 3: Smoke-run**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/objc && make -C Tools 2>&1 | tail -3'
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && printf "X:1\nX:2\nX:3\n" > /tmp/n.txt && objc/Tools/_obj/TtioNameTokV2Cli /tmp/n.txt /tmp/n_objc.bin && head -c 4 /tmp/n_objc.bin | xxd'
```

Expected: `4e 54 4b 32` ("NTK2").

- [ ] **Step 4: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add objc/Tools/TtioNameTokV2Cli.m objc/Tools/GNUmakefile && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 10): ObjC CLI for cross-lang gate

Reads names (one per line), encodes via TTIONameTokenizerV2, writes blob.
Used by Task 11 cross-lang byte-exact gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 5 — Cross-language byte-exact gate (Task 11)

### Task 11: 4-corpus × 3-language byte-exact gate

Mirror ref_diff v2 T11 (commit `0409ae7`). Extract names from BAM via Python helper, write to .txt file, invoke Java + ObjC CLIs, assert SHA-256 match across all 3 languages on 4 corpora = 12 assertions (PacBio HiFi may SKIP cleanly).

**Files:**
- Create: `python/tests/integration/test_name_tok_v2_cross_language.py`

- [ ] **Step 1: Implement test**

```python
# python/tests/integration/test_name_tok_v2_cross_language.py
from __future__ import annotations
import hashlib
import os
import subprocess
import tempfile
from pathlib import Path
import pytest

from ttio.codecs import name_tokenizer_v2 as nt2

CORPORA = {
    "chr22": "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam",
    "wes": "/home/toddw/TTI-O/data/genomic/na12878/wes/na12878.wes.chr22.lean.mapped.bam",
    "hg002_illumina": "/home/toddw/TTI-O/data/genomic/hg002/hg002.illumina.2x250.chr22.lean.mapped.bam",
    "hg002_pacbio": "/home/toddw/TTI-O/data/genomic/hg002/hg002.pacbio.hifi.lean.mapped.bam",
}

JAVA_JAR_GLOB = "/home/toddw/TTI-O/java/target/ttio-*.jar"
OBJC_BIN = "/home/toddw/TTI-O/objc/Tools/_obj/TtioNameTokV2Cli"
NATIVE_LIB_PATH = "/home/toddw/TTI-O/native/_build"


def _extract_names(bam_path: str, out_txt: str) -> int:
    proc = subprocess.run(["samtools", "view", bam_path], capture_output=True, check=True)
    n = 0
    with open(out_txt, "w") as f:
        for line in proc.stdout.split(b"\n"):
            if not line:
                continue
            qname = line.split(b"\t", 1)[0].decode("ascii")
            if qname == "*":
                return 0  # skip
            f.write(qname + "\n")
            n += 1
    return n


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


@pytest.mark.integration
@pytest.mark.parametrize("corpus,bam_path", list(CORPORA.items()))
def test_three_lang_byte_equal(corpus, bam_path):
    if not nt2.HAVE_NATIVE_LIB:
        pytest.skip("native lib not loaded")
    if not os.path.exists(bam_path):
        pytest.skip(f"BAM not found: {bam_path}")

    with tempfile.TemporaryDirectory() as td:
        names_txt = f"{td}/names.txt"
        n = _extract_names(bam_path, names_txt)
        if n == 0:
            pytest.skip(f"{corpus}: BAM has * QNAMEs")

        # Python encode
        with open(names_txt) as f:
            names = [line.rstrip("\n") for line in f]
        py_blob = nt2.encode(names)
        py_path = f"{td}/py.bin"
        Path(py_path).write_bytes(py_blob)

        # Java encode
        jar = next(Path("/home/toddw/TTI-O/java/target").glob("ttio-*.jar"))
        java_path = f"{td}/java.bin"
        subprocess.run([
            "java",
            f"-Djava.library.path={NATIVE_LIB_PATH}",
            "-cp", str(jar),
            "global.thalion.ttio.tools.NameTokenizedV2Cli",
            names_txt, java_path,
        ], check=True)

        # ObjC encode
        objc_path = f"{td}/objc.bin"
        env = os.environ.copy()
        env.setdefault("LD_LIBRARY_PATH", NATIVE_LIB_PATH)
        subprocess.run([OBJC_BIN, names_txt, objc_path], check=True, env=env)

        py_hash = _sha256_file(py_path)
        java_hash = _sha256_file(java_path)
        objc_hash = _sha256_file(objc_path)

        print(f"\n{corpus}: n={n}")
        print(f"  Python: {py_hash}")
        print(f"  Java:   {java_hash}")
        print(f"  ObjC:   {objc_hash}")

        assert py_hash == java_hash, f"Python ↔ Java byte-equal failed for {corpus}"
        assert py_hash == objc_hash, f"Python ↔ ObjC byte-equal failed for {corpus}"
```

- [ ] **Step 2: Run + commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_name_tok_v2_cross_language.py -m integration -v -s 2>&1 | tail -20'
```

Expected: 3 PASS + 1 SKIP (or 4 PASS if PacBio has names).

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/tests/integration/test_name_tok_v2_cross_language.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(#11 ch3 task 11): cross-language byte-exact gate

4 corpora × 3 langs: Python ctypes, Java JNI, ObjC direct-link all
produce SHA-256 identical NTK2 blobs on chr22, WES, HG002 Illumina;
PacBio HiFi SKIP if BAM has * QNAMEs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 6 — Writer/reader dispatch (Tasks 12-14)

### Task 12: Python writer/reader dispatch + Compression.NAME_TOKENIZED_V2 = 15

Mirror ref_diff v2 T12 (commit `eb4ba51`):

1. Add `NAME_TOKENIZED_V2 = 15` to `python/src/ttio/enums.py` after `REF_DIFF_V2 = 14`.
2. Add `opt_disable_name_tokenized_v2: bool = False` to `WrittenGenomicRun`.
3. In `python/src/ttio/spectral_dataset.py`, find the `read_names` channel writer (grep for `NAME_TOKENIZED\|read_names`); branch on opt-out flag: when False AND `HAVE_NATIVE_LIB` → encode via `name_tokenizer_v2.encode`, write to dataset with `@compression = 15`; when True → existing v1 path with `@compression = 8`.
4. In the reader (`python/src/ttio/genomic_run.py` or wherever `@compression == 8` is currently handled), add codec id 15 dispatch → `name_tokenizer_v2.decode`.
5. Add 5 dispatch tests at `python/tests/test_name_tok_v2_dispatch.py`:
   - default writes v2 (HDF5 inspection: `@compression == 15`)
   - opt-out writes v1 layout (`@compression == 8`)
   - `signal_codec_overrides[read_names] = NAME_TOKENIZED` honoured (override beats v2 default)
   - v1 round-trip via opt-out
   - v2 round-trip default

Update pre-existing tests that hard-assert v1 NAME_TOKENIZED layout: `grep -rn "NAME_TOKENIZED\|name_tokenizer\|@compression.*8" python/tests/` and add `opt_disable_name_tokenized_v2 = True` where needed.

Cross-lang gate must still pass after this task.

- [ ] All 5 tests pass; existing test suite still green.
- [ ] Commit.

---

### Task 13: Java writer/reader dispatch

Mirror Python T12 in Java (ref_diff v2 T13 = commit `40f552c`):

1. `Enums.Compression.NAME_TOKENIZED_V2` ordinal 15 (after `REF_DIFF_V2 = 14`).
2. `WrittenGenomicRun.optDisableNameTokenizedV2` bool field.
3. SpectralDataset writer + reader dispatch (mirror Python).
4. 5 dispatch tests in `NameTokenizedV2DispatchTest.java`.
5. Update pre-existing M86 Java tests to opt out where needed.

- [ ] All 5 mvn tests pass; existing surefire suite still green.
- [ ] Commit.

---

### Task 14: ObjC writer/reader dispatch

Mirror Python T12 / Java T13 in ObjC (ref_diff v2 T14 = commit `f4f0c38`):

1. `TTIOCompressionNameTokenizedV2 = 15`.
2. `optDisableNameTokenizedV2` property on `TTIOWrittenGenomicRun`.
3. TTIOSpectralDataset writer + GenomicRun reader.
4. `TestNameTokenizedV2Dispatch.m`. Wire into TTIOTestRunner.m.
5. Update pre-existing M86 ObjC tests.

- [ ] All new tests pass; full ObjC suite still green.
- [ ] Commit.

---

## Phase 7 — Ratio gate + docs (Task 15)

### Task 15: chr22 ratio gate + format-spec + CHANGELOG

Mirror ref_diff v2 T15 (commit `d2ce103`):

**Files:**
- Create: `python/tests/integration/test_name_tok_v2_compression_gate.py`
- Create: `docs/benchmarks/2026-05-04-name-tokenized-v2-results.md`
- Create: `docs/codecs/name_tokenizer_v2.md`
- Modify: `docs/format-spec.md` — add §10.6b "NAME_TOKENIZED_V2 layout"
- Modify: `docs/codecs/name_tokenizer.md` — add deprecation note + link to v2
- Modify: `CHANGELOG.md` — v1.9 entry
- Modify: `WORKPLAN.md` — mark #11 channel 3 DONE
- Modify (memory): user's auto-memory after the work — but that's NOT in the repo, do separately if relevant

- [ ] **Step 1: Compression gate test**

```python
# python/tests/integration/test_name_tok_v2_compression_gate.py
from __future__ import annotations
import os
import pytest

from ttio.bam_reader import BamReader
from ttio.spectral_dataset import SpectralDataset
from ttio.spectral_dataset_options import WrittenGenomicRun

CHR22_BAM = "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam"
HS37_FA = "/home/toddw/TTI-O/data/genomic/reference/hs37.chr22.fa"


@pytest.mark.integration
def test_chr22_savings_ge_3mb(tmp_path):
    if not os.path.exists(CHR22_BAM):
        pytest.skip(f"BAM not found")
    reader = BamReader(CHR22_BAM)
    run = reader.to_genomic_run(reference_fasta=HS37_FA)

    # v1 baseline (opt-out v2)
    v1_path = tmp_path / "v1.tio"
    SpectralDataset.write_minimal(
        v1_path,
        runs=[run],
        written_run_options=WrittenGenomicRun(opt_disable_name_tokenized_v2=True),
    )

    # v2 default
    v2_path = tmp_path / "v2.tio"
    SpectralDataset.write_minimal(
        v2_path,
        runs=[run],
        written_run_options=WrittenGenomicRun(),
    )

    v1_size = os.path.getsize(v1_path)
    v2_size = os.path.getsize(v2_path)
    savings = v1_size - v2_size
    print(f"\nchr22 file sizes:")
    print(f"  v1 (opt-out): {v1_size:,} bytes")
    print(f"  v2 (default): {v2_size:,} bytes")
    print(f"  Savings:      {savings:,} bytes ({savings / 1024 / 1024:.2f} MB)")
    assert savings >= 3_000_000, f"savings {savings} < 3 MB hard gate"
```

- [ ] **Step 2: Run gate**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_name_tok_v2_compression_gate.py -m integration -v -s 2>&1 | tail -10'
```

Expected: PASS with savings ≥ 3 MB.

- [ ] **Step 3: Write `docs/benchmarks/2026-05-04-name-tokenized-v2-results.md`**

Mirror `docs/benchmarks/2026-05-03-ref-diff-v2-results.md` structure: summary, setup, ratio comparison vs v1, per-corpus B/name table, cross-lang gate status, conclusion.

- [ ] **Step 4: Write `docs/codecs/name_tokenizer_v2.md`**

Mirror `docs/codecs/name_tokenizer.md` structure: motivation, algorithm, wire format, design choices, cross-lang contract, performance, API per language, out-of-scope, forward references.

- [ ] **Step 5: Update format spec, CHANGELOG, WORKPLAN**

- `docs/format-spec.md` §10.6b: NAME_TOKENIZED_V2 wire layout (refer to spec doc for full details).
- `CHANGELOG.md` `[Unreleased]` → new v1.9 entry: "feat: NAME_TOKENIZED_V2 codec id 15 ships as default for read_names; opt-out via opt_disable_name_tokenized_v2; chr22 savings X MB".
- `WORKPLAN.md`: mark #11 channel 3 (NameTokenized v2) DONE; preserve #10 + #13 follow-ups.

- [ ] **Step 6: Commit + push**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add python/tests/integration/test_name_tok_v2_compression_gate.py docs/benchmarks/2026-05-04-name-tokenized-v2-results.md docs/codecs/name_tokenizer_v2.md docs/codecs/name_tokenizer.md docs/format-spec.md CHANGELOG.md WORKPLAN.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "feat(#11 ch3 task 15): chr22 ratio gate + docs

NAME_TOKENIZED v2 ships in v1.9 as default for read_names channel.
Hard gate: ≥ 3 MB chr22 savings vs v1. Documented in format-spec
§10.6b, codec doc, CHANGELOG, WORKPLAN. #11 channel 3 marked DONE.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

Push from Windows git per `feedback_git_push_via_windows`:

```bash
'/c/Program Files/Git/bin/git.exe' -C //wsl.localhost/Ubuntu/home/toddw/TTI-O push
```

---

## Plan self-review

**1. Spec coverage:**

| Spec section | Tasks | Coverage |
|--------------|-------|----------|
| §1-2 (motivation, what v2 adds) | 0, 3, 15 | Phase 0 validates; Task 3 implements; Task 15 ships |
| §3 (algorithm) | 0, 3 | Phase 0 prototype + C kernel impl |
| §4 (wire format) | 1, 2, 3 | Headers, helpers, full impl |
| §4.4 (decoder invariants) | 3, 4 | Embedded in decoder + stress malformed-input tests |
| §5 (C API) | 1, 3 | Header in T1, full impl in T3 |
| §6 (Python API) | 5 | Full wrapper + tests |
| §7 (Java API) | 7 | JNI bridge + Java class + tests |
| §8 (ObjC API) | 9 | Header, impl, tests |
| §9 (cross-language byte-exact) | 11 | 4-corpus 3-lang gate |
| §10 (compression gate) | 0 (Phase 0), 6 (oracle), 15 (final) | 3 layers of gate validation |
| §11 (default + opt-out) | 12, 13, 14 | One task per language |
| §12 (frozen wire constants) | All — N=8/B=4096/MATCH=col baked in spec, validated by Phase 0 |
| §13 (out of scope) | N/A | No tasks (correctly out of scope) |
| §14 (risk/mitigation) | 0, 4 | Phase 0 sweeps; stress test catches malformed inputs |
| §15 (Phase 0 prototype) | 0 | Whole Task 0 |
| §16 (file map) | 1-15 | Each task owns its files |
| §17 (implementation pattern) | All 16 | Mirrors ch1/ch2 |

**2. Placeholder scan:**

Tasks 12, 13, 14 reference Python/Java/ObjC ref_diff v2 templates rather than spelling out every step (the dispatch shape is byte-for-byte identical). The implementer must read the corresponding ref_diff v2 commits before starting (`eb4ba51` Python, `40f552c` Java, `f4f0c38` ObjC). No `<TBD>` markers in code-bearing steps.

Task 3 (the C encoder/decoder) is described at high-level + critical invariants because the full implementation is ~1500 LoC and writing it inline would dwarf the rest of the plan. The implementer follows the spec §3 + §4 precisely. The 7 invariant tests in Task 3 + the stress + malformed tests in Task 4 are the gates that catch implementation bugs.

**3. Type consistency:**

- `ttio_name_tok_v2_encode/_decode` C signatures match across C / Python ctypes / Java JNI / ObjC direct-link bindings.
- `NAME_TOKENIZED_V2 = 15` consistent across Python `Compression`, Java `Enums.Compression`, ObjC `TTIOCompressionNameTokenizedV2`.
- `opt_disable_name_tokenized_v2` (snake) / `optDisableNameTokenizedV2` (camel) field names match across languages.
- Magic `"NTK2"` consistent (constant `NTV2_MAGIC` in C; `b"NTK2"` in Python; `"NTK2"` literal in Java/ObjC tests).

**Total: 16 tasks (Task 0 + 15) across 8 phases.** Mirrors mate_info v2 / ref_diff v2 with Phase 0 prepend.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-04-name-tokenized-v2.md`.** Per user direction (auto-mode, bypass user review), execution proceeds immediately.

Will use **superpowers:executing-plans** for inline execution with checkpoints between phases.
