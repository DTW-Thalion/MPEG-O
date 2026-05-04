"""Pure-Python NAME_TOKENIZED v2 decoder (Phase 0 prototype).

Row-major within NUM_DELTA / DICT_CODE substreams (matches encoder).
"""
from __future__ import annotations

import struct
import zlib

from ttio.codecs.name_tokenizer import _tokenize  # type: ignore

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
        bit_pos = i * 2
        byte_idx = bit_pos // 8
        shift = 6 - (bit_pos % 8)
        out.append((data[byte_idx] >> shift) & 3)
    return out


def _unpack_3bits(data: bytes, n: int) -> list[int]:
    out: list[int] = []
    bit_pos = 0
    for _ in range(n):
        byte_idx = bit_pos // 8
        in_byte = bit_pos % 8
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

    pos = 0
    subs = []
    for _ in range(8):
        slen = struct.unpack("<I", body[pos:pos+4])[0]
        mode = body[pos+4]
        sb = body[pos+5:pos+5+slen]
        pos += 5 + slen
        assert mode == 0x00, f"decompressed should be raw, got mode={mode}"
        subs.append(sb)

    flag_sub, pool_sub, match_k_sub, col_types_sub, num_delta_sub, dict_code_sub, dict_lit_sub, verb_lit_sub = subs

    flags = _unpack_2bits(flag_sub, n_reads)
    n_pool = sum(1 for f in flags if f in (FLAG_DUP, FLAG_MATCH))
    pool_idx_vals = _unpack_3bits(pool_sub, n_pool)

    # Parse MATCH_K varints
    n_match = sum(1 for f in flags if f == FLAG_MATCH)
    match_k_vals: list[int] = []
    p = 0
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

    # Replay rows in order, consuming substreams as we go
    pool: list[str] = []
    out_names: list[str] = []
    pool_idx_iter = iter(pool_idx_vals)
    match_k_iter = iter(match_k_vals)

    nd_pos = 0
    dc_pos = 0
    dict_lit_pos = 0
    verb_pos = 0
    col_num_prev: dict[int, int] = {}
    col_dict: dict[int, list[str]] = {}

    def read_col_value(j, ctype):
        nonlocal nd_pos, dc_pos, dict_lit_pos
        if ctype == 0:  # num
            if j not in col_num_prev:
                v, nd_pos = _read_uvarint(num_delta_sub, nd_pos)
                col_num_prev[j] = v
                return v
            else:
                d, nd_pos = _read_svarint(num_delta_sub, nd_pos)
                v = col_num_prev[j] + d
                col_num_prev[j] = v
                return v
        else:  # str
            code, dc_pos = _read_uvarint(dict_code_sub, dc_pos)
            d = col_dict.setdefault(j, [])
            if code < len(d):
                return d[code]
            elif code == len(d):
                lit_len, dict_lit_pos = _read_uvarint(dict_lit_sub, dict_lit_pos)
                lit = dict_lit_sub[dict_lit_pos:dict_lit_pos + lit_len].decode("ascii")
                dict_lit_pos += lit_len
                d.append(lit)
                return lit
            else:
                raise ValueError(f"dict code {code} > dict size {len(d)}")

    for r, f in enumerate(flags):
        if f == FLAG_DUP:
            pi = next(pool_idx_iter)
            if pi >= len(pool):
                raise ValueError(f"pool_idx {pi} >= pool len {len(pool)}")
            name = pool[pi]
        elif f == FLAG_MATCH:
            pi = next(pool_idx_iter)
            K = next(match_k_iter)
            if pi >= len(pool):
                raise ValueError(f"pool_idx {pi} >= pool len {len(pool)}")
            assert block_col_types is not None
            pool_entry_tokens = _tokenize(pool[pi])
            if K <= 0 or K >= len(pool_entry_tokens):
                raise ValueError(f"bad K={K} for n_cols={len(pool_entry_tokens)}")
            # Update num prev for matched cols [0, K) from pool entry
            for j in range(K):
                if pool_entry_tokens[j][0] == "num":
                    col_num_prev[j] = pool_entry_tokens[j][1]
            # Build name = matched prefix + decoded suffix
            parts: list[str] = []
            for j in range(K):
                t = pool_entry_tokens[j]
                parts.append(str(t[1]) if t[0] == "num" else t[1])
            for j in range(K, len(block_col_types)):
                v = read_col_value(j, block_col_types[j])
                parts.append(str(v) if block_col_types[j] == 0 else v)
            name = "".join(parts)
        elif f == FLAG_COL:
            assert block_col_types is not None
            parts = []
            for j, ctype in enumerate(block_col_types):
                v = read_col_value(j, ctype)
                parts.append(str(v) if ctype == 0 else v)
            name = "".join(parts)
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


def decode(blob: bytes, pool_size: int = 8) -> list[str]:
    if len(blob) < 12:
        raise ValueError(f"blob too short: {len(blob)}")
    if blob[:4] != MAGIC:
        raise ValueError(f"bad magic: {blob[:4]!r}")
    if blob[4] != 0x01:
        raise ValueError(f"unsupported version: {blob[4]}")
    flags_byte = blob[5]
    if flags_byte & 0xFE:
        raise ValueError(f"reserved flags bits set: 0x{flags_byte:02x}")
    n_reads = struct.unpack("<I", blob[6:10])[0]
    n_blocks = struct.unpack("<H", blob[10:12])[0]
    if flags_byte & 0x01:
        if n_reads != 0:
            raise ValueError("empty flag set but n_reads != 0")
        return []
    block_offsets = []
    expected_offsets_len = n_blocks * 4
    if 12 + expected_offsets_len > len(blob):
        raise ValueError("offsets table truncated")
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
