"""Pure-Python NAME_TOKENIZED v2 encoder (Phase 0 prototype).

Wire constants per spec docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md.
Row-major emission within NUM_DELTA / DICT_CODE substreams (Phase 0 simplification —
spec will be updated to match if Phase 0 passes the gate).
"""
from __future__ import annotations

import struct
import zlib

# Reuse v1's tokeniser. Returns [(type_str, value), ...].
from ttio.codecs.name_tokenizer import _tokenize  # type: ignore


MAGIC = b"NTK2"
VERSION = 0x01
POOL_SIZE_DEFAULT = 8
BLOCK_SIZE_DEFAULT = 4096

FLAG_DUP = 0b00
FLAG_MATCH = 0b01
FLAG_COL = 0b10
FLAG_VERB = 0b11


def _uvarint(n: int) -> bytes:
    if n < 0:
        raise ValueError(f"uvarint needs non-negative, got {n}")
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _svarint(n: int) -> bytes:
    if n >= 0:
        z = n << 1
    else:
        z = ((-n) << 1) - 1
    return _uvarint(z)


def _pack_2bits(values: list[int]) -> bytes:
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


def _try_match(read_tokens, pool_tokens, block_col_types):
    """Find best (pool_idx, K) for MATCH-K. None if no candidate."""
    if block_col_types is None:
        return None
    n_cols = len(read_tokens)
    if n_cols != len(block_col_types):
        return None
    if [0 if t[0] == "num" else 1 for t in read_tokens] != block_col_types:
        return None

    best_k = 0
    best_idx = -1
    for idx, p in enumerate(pool_tokens):
        if not p:
            continue
        max_k = min(len(p), n_cols)
        k = 0
        for j in range(max_k):
            pt = p[j]
            rt = read_tokens[j]
            want = block_col_types[j]
            if (0 if pt[0] == "num" else 1) != want:
                break
            if pt[0] != rt[0] or pt[1] != rt[1]:
                break
            k += 1
        if 0 < k < n_cols and k > best_k:
            best_k = k
            best_idx = idx
    if best_idx < 0:
        return None
    return (best_idx, best_k)


def _encode_block_raw(names: list[str], pool_size: int) -> bytes:
    """Encode one block (≤ B reads) with substreams in raw mode (0x00).

    Row-major emission within NUM_DELTA / DICT_CODE.
    """
    flags: list[int] = []
    pool_idx_vals: list[int] = []
    match_k_vals: list[int] = []
    block_col_types: list[int] | None = None

    col_num_prev: dict[int, int] = {}
    col_dict: dict[int, dict[str, int]] = {}
    dict_lit_blob = bytearray()

    num_delta_blob = bytearray()
    dict_code_blob = bytearray()
    verb_lit_blob = bytearray()

    pool_tokens: list[list] = []
    pool_names: list[str] = []

    def push_pool(name, tokens):
        pool_names.append(name)
        pool_tokens.append(tokens)
        if len(pool_names) > pool_size:
            pool_names.pop(0)
            pool_tokens.pop(0)

    def emit_col_value(j, ttype, tval):
        nonlocal num_delta_blob, dict_code_blob, dict_lit_blob
        if ttype == "num":
            if j not in col_num_prev:
                num_delta_blob.extend(_uvarint(tval))
            else:
                delta = tval - col_num_prev[j]
                num_delta_blob.extend(_svarint(delta))
            col_num_prev[j] = tval
        else:  # str
            d = col_dict.setdefault(j, {})
            if tval in d:
                code = d[tval]
                dict_code_blob.extend(_uvarint(code))
            else:
                code = len(d)
                dict_code_blob.extend(_uvarint(code))
                d[tval] = code
                lit_bytes = tval.encode("ascii")
                dict_lit_blob.extend(_uvarint(len(lit_bytes)))
                dict_lit_blob.extend(lit_bytes)

    for name in names:
        tokens = _tokenize(name)

        # 1. DUP
        if name in pool_names:
            pool_idx = pool_names.index(name)
            flags.append(FLAG_DUP)
            pool_idx_vals.append(pool_idx)
            push_pool(name, tokens)
            continue

        # 2. MATCH-K
        match = _try_match(tokens, pool_tokens, block_col_types)
        if match is not None:
            pool_idx, K = match
            flags.append(FLAG_MATCH)
            pool_idx_vals.append(pool_idx)
            match_k_vals.append(K)
            assert block_col_types is not None
            # Update num delta state for matched cols [0, K) using pool entry values
            pool_entry = pool_tokens[pool_idx]
            for j in range(K):
                if pool_entry[j][0] == "num":
                    col_num_prev[j] = pool_entry[j][1]  # type: ignore
            # Emit suffix tokens [K, n_cols) — row-major
            for j in range(K, len(tokens)):
                ttype, tval = tokens[j]
                emit_col_value(j, ttype, tval)
            push_pool(name, tokens)
            continue

        # 3. COL — only if shape compat
        col_types = [0 if t[0] == "num" else 1 for t in tokens]
        if block_col_types is None:
            block_col_types = col_types
        if col_types == block_col_types:
            flags.append(FLAG_COL)
            for j, (ttype, tval) in enumerate(tokens):
                emit_col_value(j, ttype, tval)
            push_pool(name, tokens)
            continue

        # 4. VERB
        flags.append(FLAG_VERB)
        b = name.encode("ascii")
        verb_lit_blob.extend(_uvarint(len(b)))
        verb_lit_blob.extend(b)
        push_pool(name, tokens)

    flag_substream = _pack_2bits(flags)
    pool_idx_substream = _pack_3bits(pool_idx_vals)
    match_k_substream = b"".join(_uvarint(k) for k in match_k_vals)

    if block_col_types is not None:
        n_cols = len(block_col_types)
        bitmap_len = (n_cols + 7) // 8
        bitmap = bytearray(bitmap_len)
        for j, t in enumerate(block_col_types):
            if t == 1:
                byte_idx = j // 8
                bit_idx = 7 - (j % 8)
                bitmap[byte_idx] |= (1 << bit_idx)
        col_types_substream = bytes([n_cols]) + bytes(bitmap)
    else:
        col_types_substream = b""

    substreams = [
        flag_substream,
        pool_idx_substream,
        match_k_substream,
        col_types_substream,
        bytes(num_delta_blob),
        bytes(dict_code_blob),
        bytes(dict_lit_blob),
        bytes(verb_lit_blob),
    ]

    body = bytearray()
    for s in substreams:
        body.extend(struct.pack("<I", len(s)))
        body.append(0x00)
        body.extend(s)

    return struct.pack("<I", len(names)) + struct.pack("<I", len(body)) + bytes(body)


def _maybe_compress_substreams(block_body: bytes) -> bytes:
    """Walk substreams; replace mode=0x00 with mode=0x01 (zlib) when smaller."""
    n_reads_bytes = block_body[:4]
    body_len_orig = struct.unpack("<I", block_body[4:8])[0]
    body = block_body[8:8 + body_len_orig]
    new_body = bytearray()
    pos = 0
    while pos < len(body):
        sub_body_len = struct.unpack("<I", body[pos:pos+4])[0]
        mode = body[pos+4]
        sub_body = body[pos+5:pos+5+sub_body_len]
        pos += 5 + sub_body_len
        if mode == 0x00 and sub_body_len > 16:
            compressed = zlib.compress(sub_body, level=6)
            if len(compressed) < sub_body_len:
                new_body.extend(struct.pack("<I", len(compressed)))
                new_body.append(0x01)
                new_body.extend(compressed)
                continue
        new_body.extend(struct.pack("<I", sub_body_len))
        new_body.append(mode)
        new_body.extend(sub_body)
    out = bytearray(n_reads_bytes)
    out.extend(struct.pack("<I", len(new_body)))
    out.extend(new_body)
    return bytes(out)


def encode(names: list[str], *, pool_size: int = POOL_SIZE_DEFAULT,
           block_size: int = BLOCK_SIZE_DEFAULT,
           use_rans_o0_proxy: bool = True) -> bytes:
    n_reads = len(names)
    if n_reads == 0:
        return MAGIC + bytes([VERSION, 0x01]) + struct.pack("<I", 0) + struct.pack("<H", 0)

    n_blocks = (n_reads + block_size - 1) // block_size
    if n_blocks > 65535:
        raise ValueError(f"too many blocks: {n_blocks} > 65535")

    blocks: list[bytes] = []
    for b in range(n_blocks):
        start = b * block_size
        end = min(start + block_size, n_reads)
        block_body = _encode_block_raw(names[start:end], pool_size)
        if use_rans_o0_proxy:
            block_body = _maybe_compress_substreams(block_body)
        blocks.append(block_body)

    block_offsets: list[int] = []
    cur = 0
    for blk in blocks:
        block_offsets.append(cur)
        cur += len(blk)

    header = MAGIC + bytes([VERSION, 0x00]) + struct.pack("<I", n_reads) + struct.pack("<H", n_blocks)
    header += b"".join(struct.pack("<I", off) for off in block_offsets)

    return header + b"".join(blocks)
