# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
"""TTI-O M85B — NAME_TOKENIZED Cython accelerator.

C-accelerated kernels for the hot NAME_TOKENIZED functions identified in
the chr22 profile (`docs/benchmarks/m94z-pipeline-profile.md`):

  * ``tokenize_c``         — byte-level tokeniser (replaces regex iter +
    Python list build per name).
  * ``encode_columnar_c``  — emit the columnar body, internalising the
    per-column varint loops.
  * ``decode_columnar_c``  — decode the columnar body, internalising the
    per-column varint loops + dictionary lookups.
  * ``encode_verbatim_c``  — emit the verbatim body.
  * ``decode_verbatim_c``  — decode the verbatim body.

Output is byte-identical to the pure-Python reference at
:mod:`ttio.codecs.name_tokenizer`. The wrapper module routes hot calls
through this extension when present and silently falls back to pure
Python otherwise.

Tokens are exposed back to Python as ``(type_str, value)`` tuples where
``type_str`` is the interned string ``"num"`` or ``"str"`` and ``value``
is a Python ``int`` (numeric) or ``str`` (string). This matches the
contract of :func:`ttio.codecs.name_tokenizer._tokenize`.
"""
from libc.stdint cimport uint8_t, uint32_t, int32_t, int64_t, uint64_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy

from cpython.bytes cimport PyBytes_FromStringAndSize


# ── Constants (must match name_tokenizer.py) ────────────────────────


cdef int _TYPE_NUMERIC = 0
cdef int _TYPE_STRING = 1

# 2^63 = 9223372036854775808 — 19 decimal digits. Any digit-run of length
# < 19 fits in int64 unsigned-positive interpretation. A 19-digit run may
# or may not fit. A run of 20+ digits always overflows.
cdef int _NUMERIC_MAX_DIGITS_DEFINITELY_FIT = 18
cdef int _NUMERIC_MAX_DIGITS = 19
cdef uint64_t _NUMERIC_MAX = <uint64_t>1 << 63


# ── Internal helpers ────────────────────────────────────────────────


cdef inline bint _digit_run_fits_int63(const uint8_t* dp, Py_ssize_t length) noexcept nogil:
    """Return True iff the digit-run ``dp[:length]`` represents a value < 2^63.

    Caller has already verified that ``length >= 1`` and ``dp[0] != '0'``.
    For length <= 18 the answer is always True; for length == 19 we must
    compare against the literal "9223372036854775808" prefix; for length
    >= 20 the answer is always False.
    """
    cdef Py_ssize_t k
    cdef uint8_t cmp_byte
    # Threshold digits of 2^63 (19 chars).
    cdef const char* _LIMIT = "9223372036854775808"
    if length < _NUMERIC_MAX_DIGITS:
        return True
    if length > _NUMERIC_MAX_DIGITS:
        return False
    # length == 19 — lexicographic compare; first char that differs decides.
    for k in range(_NUMERIC_MAX_DIGITS):
        cmp_byte = <uint8_t>_LIMIT[k]
        if dp[k] < cmp_byte:
            return True
        if dp[k] > cmp_byte:
            return False
    # All equal => exactly 2^63, which is NOT strictly less than 2^63.
    return False


cdef inline int _varint_encode_into(uint64_t n, uint8_t* out) noexcept nogil:
    """Write LEB128 encoding of ``n`` to ``out``; return number of bytes used.

    ``out`` must have at least 10 bytes of headroom (max LEB128 length for
    a 64-bit value).
    """
    cdef int i = 0
    while n >= 0x80:
        out[i] = <uint8_t>((n & 0x7F) | 0x80)
        n >>= 7
        i += 1
    out[i] = <uint8_t>(n & 0x7F)
    return i + 1


cdef inline int _svarint_encode_into(int64_t n, uint8_t* out) noexcept nogil:
    """Zigzag + LEB128. Returns bytes written."""
    cdef uint64_t zz = (<uint64_t>(n << 1)) ^ <uint64_t>(n >> 63)
    return _varint_encode_into(zz, out)


# ── Tokeniser (byte-level, replaces regex iter) ─────────────────────


def tokenize_c(bytes name):
    """Byte-level tokeniser. Returns list of (str, int|str) tuples.

    Mirrors :func:`ttio.codecs.name_tokenizer._tokenize` semantics:
      - Empty input → empty list.
      - Maximal digit-run that is "0" alone, or non-zero-leading with
        value < 2^63 → numeric token.
      - All other digit-runs absorbed into the surrounding string token.
    """
    cdef Py_ssize_t n = len(name)
    if n == 0:
        return []

    cdef const uint8_t* p = <const uint8_t*>name
    cdef list tokens = []
    cdef Py_ssize_t i = 0
    cdef Py_ssize_t str_start = -1  # -1 == no pending string buffer
    cdef Py_ssize_t digit_start
    cdef Py_ssize_t digit_len
    cdef uint8_t b
    cdef bint is_numeric
    cdef uint64_t value
    cdef Py_ssize_t k
    cdef Py_ssize_t merge_end

    while i < n:
        b = p[i]
        if b >= 48 and b <= 57:  # '0'..'9'
            digit_start = i
            while i < n and p[i] >= 48 and p[i] <= 57:
                i += 1
            digit_len = i - digit_start

            # Validate as numeric.
            is_numeric = False
            if digit_len == 1:
                is_numeric = True  # any single digit incl. '0'
            elif p[digit_start] != 48:  # first char != '0'
                if _digit_run_fits_int63(p + digit_start, digit_len):
                    is_numeric = True

            if is_numeric:
                # Flush any pending string buffer.
                if str_start >= 0:
                    tokens.append(("str", PyBytes_FromStringAndSize(
                        <const char*>(p + str_start), digit_start - str_start
                    ).decode("ascii")))
                    str_start = -1
                # Parse value (digit_len <= 19 by validation).
                value = 0
                for k in range(digit_len):
                    value = value * 10 + (p[digit_start + k] - 48)
                tokens.append(("num", <object>value))
            else:
                # Absorb into surrounding string buffer.
                if str_start < 0:
                    str_start = digit_start
                # Else: digits extend the current string buffer; nothing to do.
        else:
            # Non-digit byte: extend / start string buffer.
            if str_start < 0:
                str_start = i
            i += 1

    # Flush trailing string buffer.
    if str_start >= 0:
        tokens.append(("str", PyBytes_FromStringAndSize(
            <const char*>(p + str_start), n - str_start
        ).decode("ascii")))

    return tokens


# ── Columnar encoder ────────────────────────────────────────────────


def encode_columnar_c(list tokenised, list type_table):
    """Emit the columnar body bytes.

    Args:
        tokenised: list of per-read token lists; each entry is a list of
            ``(type_str, value)`` tuples already validated to be
            uniformly typed across reads.
        type_table: list of ints (0 = numeric, 1 = string), length =
            n_columns.

    Returns:
        ``bytes`` — the columnar body (including the n_columns byte +
        type table prefix).
    """
    cdef Py_ssize_t n_reads = len(tokenised)
    cdef Py_ssize_t n_columns = len(type_table)
    if n_columns > 0xFF:
        raise ValueError(
            f"NAME_TOKENIZED n_columns {n_columns} exceeds uint8 limit"
        )

    out = bytearray()
    cdef bytearray out_ba = out
    out_ba.append(<uint8_t>n_columns)
    cdef Py_ssize_t c
    for c in range(n_columns):
        out_ba.append(<uint8_t>(<int>type_table[c]))

    cdef uint8_t scratch[16]  # 10 is max for LEB128 of 64-bit
    cdef int nb
    cdef int col_type
    cdef Py_ssize_t col_idx, read_idx
    cdef int64_t prev_int, cur_int
    cdef object col0_obj
    cdef list row
    cdef tuple tok
    cdef object token_value
    cdef dict dict_idx
    cdef object code_obj
    cdef Py_ssize_t new_code
    cdef bytes payload

    for col_idx in range(n_columns):
        col_type = <int>type_table[col_idx]
        if col_type == _TYPE_NUMERIC:
            # First read: varint seed; subsequent reads: zigzag delta.
            row = <list>tokenised[0]
            tok = <tuple>row[col_idx]
            prev_int = <int64_t>tok[1]
            nb = _varint_encode_into(<uint64_t>prev_int, scratch)
            out_ba.extend(scratch[:nb])
            for read_idx in range(1, n_reads):
                row = <list>tokenised[read_idx]
                tok = <tuple>row[col_idx]
                cur_int = <int64_t>tok[1]
                nb = _svarint_encode_into(cur_int - prev_int, scratch)
                out_ba.extend(scratch[:nb])
                prev_int = cur_int
        else:
            dict_idx = {}
            for read_idx in range(n_reads):
                row = <list>tokenised[read_idx]
                tok = <tuple>row[col_idx]
                token_value = tok[1]
                code_obj = dict_idx.get(token_value)
                if code_obj is None:
                    new_code = len(dict_idx)
                    dict_idx[token_value] = new_code
                    nb = _varint_encode_into(<uint64_t>new_code, scratch)
                    out_ba.extend(scratch[:nb])
                    payload = (<str>token_value).encode("ascii")
                    nb = _varint_encode_into(<uint64_t>len(payload), scratch)
                    out_ba.extend(scratch[:nb])
                    out_ba.extend(payload)
                else:
                    nb = _varint_encode_into(<uint64_t>(<Py_ssize_t>code_obj), scratch)
                    out_ba.extend(scratch[:nb])
    return bytes(out_ba)


# ── Columnar decoder ────────────────────────────────────────────────


cdef inline int _varint_decode_c(
    const uint8_t* buf, Py_ssize_t buf_len, Py_ssize_t* off,
    uint64_t* value_out,
) except -1:
    """Decode LEB128 at ``buf[off[0]:]``. On success, advances ``off``
    and writes ``value_out``; returns 0. On failure, raises ValueError
    and returns -1.
    """
    cdef uint64_t value = 0
    cdef int shift = 0
    cdef Py_ssize_t pos = off[0]
    cdef uint8_t b
    while True:
        if pos >= buf_len:
            raise ValueError(
                f"NAME_TOKENIZED varint runs off end of stream at offset {off[0]}"
            )
        b = buf[pos]
        pos += 1
        value |= (<uint64_t>(b & 0x7F)) << shift
        if (b & 0x80) == 0:
            off[0] = pos
            value_out[0] = value
            return 0
        shift += 7
        if shift >= 64:
            # Shouldn't happen for legitimate streams; guard against
            # malformed input causing UB.
            raise ValueError(
                f"NAME_TOKENIZED varint exceeds 64 bits at offset {off[0]}"
            )


def decode_columnar_c(bytes buf, Py_ssize_t offset, Py_ssize_t n_reads):
    """Decode a columnar body starting at ``buf[offset:]``.

    Returns ``(names_list, new_offset)``.
    """
    cdef Py_ssize_t buf_len = len(buf)
    cdef const uint8_t* bp = <const uint8_t*>buf
    if offset >= buf_len:
        raise ValueError(
            "NAME_TOKENIZED columnar body missing n_columns byte"
        )
    cdef int n_columns = bp[offset]
    offset += 1

    if offset + n_columns > buf_len:
        raise ValueError(
            f"NAME_TOKENIZED columnar type table truncated: need "
            f"{n_columns} bytes at offset {offset}"
        )

    cdef list type_table = []
    cdef int t
    cdef Py_ssize_t k
    for k in range(n_columns):
        t = bp[offset + k]
        if t != _TYPE_NUMERIC and t != _TYPE_STRING:
            raise ValueError(
                f"NAME_TOKENIZED unknown column type 0x{t:02x}"
            )
        type_table.append(t)
    offset += n_columns

    if n_reads == 0:
        return [], offset

    cdef list columns = []
    cdef list col_values
    cdef list dict_entries
    cdef Py_ssize_t cur_size, length, read_idx
    cdef uint64_t raw
    cdef int64_t seed_signed, prev_signed, delta_signed, cur_signed
    cdef int col_type
    cdef bytes payload_bytes
    cdef str text
    cdef Py_ssize_t code

    for k in range(n_columns):
        col_type = <int>type_table[k]
        col_values = []
        if col_type == _TYPE_NUMERIC:
            _varint_decode_c(bp, buf_len, &offset, &raw)
            seed_signed = <int64_t>raw  # caller stored it via varint of nonneg int per spec
            col_values.append(<object>seed_signed)
            prev_signed = seed_signed
            for read_idx in range(n_reads - 1):
                _varint_decode_c(bp, buf_len, &offset, &raw)
                # Zigzag decode.
                delta_signed = <int64_t>((raw >> 1) ^ (<uint64_t>0 - (raw & 1)))
                cur_signed = prev_signed + delta_signed
                col_values.append(<object>cur_signed)
                prev_signed = cur_signed
        else:
            dict_entries = []
            for read_idx in range(n_reads):
                _varint_decode_c(bp, buf_len, &offset, &raw)
                code = <Py_ssize_t>raw
                cur_size = len(dict_entries)
                if code < cur_size:
                    col_values.append(dict_entries[code])
                elif code == cur_size:
                    _varint_decode_c(bp, buf_len, &offset, &raw)
                    length = <Py_ssize_t>raw
                    if offset + length > buf_len:
                        raise ValueError(
                            "NAME_TOKENIZED string literal runs off end of stream"
                        )
                    payload_bytes = PyBytes_FromStringAndSize(
                        <const char*>(bp + offset), length
                    )
                    offset += length
                    try:
                        text = payload_bytes.decode("ascii")
                    except UnicodeDecodeError as exc:
                        raise ValueError(
                            "NAME_TOKENIZED string literal contains non-ASCII bytes"
                        ) from exc
                    dict_entries.append(text)
                    col_values.append(text)
                else:
                    raise ValueError(
                        f"NAME_TOKENIZED string code {code} > current "
                        f"dict size {cur_size} (malformed)"
                    )
        columns.append(col_values)

    # Reassemble names by concatenating column tokens row-by-row.
    cdef list names = []
    cdef list parts
    cdef object v
    cdef Py_ssize_t ri, ci
    for ri in range(n_reads):
        parts = []
        for ci in range(n_columns):
            col_type = <int>type_table[ci]
            v = (<list>columns[ci])[ri]
            if col_type == _TYPE_NUMERIC:
                parts.append(str(v))
            else:
                parts.append(v)
        names.append("".join(parts))
    return names, offset


# ── Verbatim encoder ────────────────────────────────────────────────


def encode_verbatim_c(list encoded_names):
    """Emit the verbatim body. ``encoded_names`` is a list of bytes
    (per-read ASCII-encoded names)."""
    out = bytearray()
    cdef bytearray out_ba = out
    cdef uint8_t scratch[16]
    cdef int nb
    cdef Py_ssize_t i
    cdef bytes payload
    cdef Py_ssize_t n = len(encoded_names)
    for i in range(n):
        payload = <bytes>encoded_names[i]
        nb = _varint_encode_into(<uint64_t>len(payload), scratch)
        out_ba.extend(scratch[:nb])
        out_ba.extend(payload)
    return bytes(out_ba)


# ── Verbatim decoder ────────────────────────────────────────────────


def decode_verbatim_c(bytes buf, Py_ssize_t offset, Py_ssize_t n_reads):
    """Decode a verbatim body starting at ``buf[offset:]``.

    Returns ``(names_list, new_offset)``.
    """
    cdef Py_ssize_t buf_len = len(buf)
    cdef const uint8_t* bp = <const uint8_t*>buf
    cdef list names = []
    cdef Py_ssize_t i
    cdef uint64_t raw
    cdef Py_ssize_t length
    cdef bytes payload_bytes
    cdef str text
    for i in range(n_reads):
        _varint_decode_c(bp, buf_len, &offset, &raw)
        length = <Py_ssize_t>raw
        if offset + length > buf_len:
            raise ValueError(
                "NAME_TOKENIZED verbatim entry runs off end of stream"
            )
        payload_bytes = PyBytes_FromStringAndSize(
            <const char*>(bp + offset), length
        )
        offset += length
        try:
            text = payload_bytes.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError(
                "NAME_TOKENIZED verbatim entry contains non-ASCII bytes"
            ) from exc
        names.append(text)
    return names, offset
