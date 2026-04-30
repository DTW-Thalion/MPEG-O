"""NAME_TOKENIZED genomic read-name codec — lean two-token-type columnar.

Clean-room implementation. The two-token-type tokenisation (numeric
digit-runs vs string non-digit-runs) is the simplest possible
structural split of an ASCII string; per-column type detection,
delta encoding for monotonic integer columns, and inline-dictionary
encoding for repeat-heavy string columns are all standard
data-compression techniques. **No htslib, no CRAM tools-Java, no
SRA toolkit, no samtools, no Bonfield 2022 reference source
consulted at any point.** This codec is *inspired by* CRAM 3.1's
name tokenisation algorithm in spirit but does NOT aim for CRAM-3.1
wire compatibility (HANDOFF.md M85B §10).

Cross-language equivalents:
    Objective-C: TTIONameTokenizer (objc/Source/Codecs/TTIONameTokenizer.{h,m})
    Java:        global.thalion.ttio.codecs.NameTokenizer

Wire format (big-endian throughout, self-contained):

    Header (7 bytes):
        Offset  Size  Field
        ──────  ────  ──────────────────────────────────────────
        0       1     version            (0x00)
        1       1     scheme_id          (0x00 = "lean-columnar")
        2       1     mode               (0x00 = columnar, 0x01 = verbatim)
        3       4     n_reads            (uint32 BE)

    Columnar body (mode = 0x00):
        n_columns          (uint8; 0..255)
        column_type_table  (n_columns × uint8: 0 = numeric, 1 = string)
        per-column streams (in column order):
            Numeric: varint(first_value) + (n_reads-1) × svarint(delta_i)
            String:  n_reads × code_or_literal
                where each entry is varint(code), and if
                code == current_dict_size, immediately followed by
                varint(literal_byte_length) + literal_bytes.

    Verbatim body (mode = 0x01):
        n_reads × { varint(byte_length), literal_bytes }

Varints are unsigned LEB128 (low 7 bits of value first; top bit =
continuation flag). Signed deltas use zigzag-then-LEB128:
``encode(n) = (n << 1) ^ (n >> 63)`` (two's-complement arithmetic
shift on int64).

Tokenisation rules (HANDOFF.md M85B §2.1; binding decisions §103,
§104):

    A numeric token is a maximal contiguous run of ASCII digits 0..9
    that is either (a) the single character "0", or (b) a digit-run
    of length ≥ 1 whose first character is NOT "0", AND whose
    integer value fits in int64 (< 2^63). All other digit-runs are
    absorbed into the surrounding string token. A string token is a
    maximal run of bytes such that no valid numeric token appears
    inside it. Tokens alternate types after parsing. The empty name
    "" yields zero tokens.

    Worked examples:
        "READ:1:2"  → ["READ:", 1, ":", 2]
        "r0"        → ["r", 0]
        "r007"      → ["r007"]            (007 invalid numeric)
        "r007:1"    → ["r007:", 1]
        "0"         → [0]                 (single "0" valid)
        "0042"      → ["0042"]            (leading-zero run)
        "123abc"    → [123, "abc"]
        ""          → []

The codec uses columnar mode IFF (a) all reads have exactly the same
number of tokens, AND (b) per-column token type matches across all
reads. Otherwise verbatim mode is used. The encoder picks
automatically (no caller-facing flag in v0).

Names must be 7-bit ASCII (binding decision §10 / §10 non-goals);
non-ASCII strings raise on encode.
"""
from __future__ import annotations

import re
import struct

# ─── Optional Cython acceleration ──────────────────────────────────
#
# When the compiled extension at ``ttio.codecs._name_tokenizer._name_tokenizer``
# is available, the hot tokeniser + columnar/verbatim encode+decode kernels
# transparently route through it. Output is byte-identical either way —
# the Python implementations below remain the spec contract.

try:  # pragma: no cover — extension may be absent in source-only installs
    from ttio.codecs._name_tokenizer import _name_tokenizer as _ext  # type: ignore[import-not-found]
    _HAVE_C_EXTENSION = True
except ImportError:  # pragma: no cover
    _HAVE_C_EXTENSION = False
    _ext = None  # type: ignore[assignment]


# ── Internal compiled regex (tokeniser fast-path) ──────────────────

#: Splits on maximal digit-runs. Each match is either a digit-run
#: (group 1 non-empty) or a non-digit run (group 1 empty / use group 2).
#: ``re.finditer`` runs in C and is several×faster than Python char
#: loops on long names.
_TOKEN_RE = re.compile(r"(\d+)|([^\d]+)")

# ── Wire-format constants ──────────────────────────────────────────

#: Version byte — first byte of every NAME_TOKENIZED stream.
VERSION: int = 0x00

#: Scheme id for the lean-columnar scheme — second byte of every
#: stream. v0 of this codec defines this single scheme; future
#: schemes (Bonfield-style 8-token-type, etc.) would get distinct
#: scheme_ids.
SCHEME_LEAN_COLUMNAR: int = 0x00

#: Mode byte values.
MODE_COLUMNAR: int = 0x00
MODE_VERBATIM: int = 0x01

#: Header bytes: 1 (version) + 1 (scheme) + 1 (mode) + 4 (n_reads) = 7.
HEADER_LEN: int = 7

#: Numeric-token magnitude limit (exclusive). Tokens whose integer
#: value is ≥ this bound are demoted to string tokens (binding
#: decision §104; delta arithmetic uses int64 for cross-language
#: portability).
_NUMERIC_MAX: int = 1 << 63

#: Column type tags.
_TYPE_NUMERIC: int = 0
_TYPE_STRING: int = 1


# ── Varint and zigzag helpers ──────────────────────────────────────


#: Pre-computed single-byte varints for 0..127 (the hot path —
#: small dict codes and small zigzag deltas dominate in real data).
#: Each value is its own LEB128 since 0..127 has no continuation bit.
_VARINT_SMALL: tuple[bytes, ...] = tuple(bytes([i]) for i in range(128))


def _varint_encode(n: int) -> bytes:
    """Encode a non-negative integer as unsigned LEB128 (varint).

    Raises ValueError if n is negative; non-negative values of any
    magnitude are accepted (Python ints are unbounded).
    """
    if 0 <= n < 128:
        return _VARINT_SMALL[n]
    if n < 0:
        raise ValueError(f"_varint_encode: negative value {n}")
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n & 0x7F)
    return bytes(out)


def _varint_decode(buf: bytes, offset: int) -> tuple[int, int]:
    """Decode an unsigned LEB128 varint at ``buf[offset:]``.

    Returns (value, new_offset). Raises ValueError if the varint
    runs off the end of ``buf`` before a byte with the continuation
    bit cleared is encountered.
    """
    value = 0
    shift = 0
    pos = offset
    n = len(buf)
    while True:
        if pos >= n:
            raise ValueError(
                f"NAME_TOKENIZED varint runs off end of stream at offset {offset}"
            )
        b = buf[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return value, pos
        shift += 7


def _zigzag_encode(n: int) -> int:
    """Map a signed int64 to a non-negative int via zigzag encoding."""
    # (n << 1) ^ (n >> 63) per HANDOFF.md §3 — arithmetic shift on
    # two's-complement int64. Python's >> is arithmetic, so for n in
    # [-2^63, 2^63), n >> 63 is 0 (n ≥ 0) or -1 (n < 0). The xor
    # with -1 flips bits to produce 2|n|-1 for negatives.
    return (n << 1) ^ (n >> 63)


def _zigzag_decode(n: int) -> int:
    """Reverse zigzag encoding back to a signed integer."""
    return (n >> 1) ^ -(n & 1)


def _svarint_encode(n: int) -> bytes:
    return _varint_encode(_zigzag_encode(n))


def _svarint_decode(buf: bytes, offset: int) -> tuple[int, int]:
    raw, new_off = _varint_decode(buf, offset)
    return _zigzag_decode(raw), new_off


# ── Tokeniser ──────────────────────────────────────────────────────


def _tokenize(name: str) -> list[tuple[str, object]]:
    """Tokenise an ASCII read name into [(type, value), ...] tokens.

    Returns a list of ("num", int) and ("str", str) tuples that
    alternate types per HANDOFF.md §2.1. The empty input yields an
    empty list.

    Numeric criterion: a maximal digit-run that is either the single
    character "0" or has length ≥ 1 with a non-"0" first character,
    and whose value < 2^63. Otherwise the digit-run is absorbed into
    the surrounding string token.
    """
    if _HAVE_C_EXTENSION:
        # Encode once to bytes; ASCII-only contract is enforced upstream
        # in :func:`encode`. For decode-side / direct callers, fall back
        # to the Python path on encoding errors.
        try:
            return _ext.tokenize_c(name.encode("ascii"))
        except UnicodeEncodeError:
            return _tokenize_py(name)
    return _tokenize_py(name)


def _tokenize_py(name: str) -> list[tuple[str, object]]:
    """Pure-Python reference implementation of :func:`_tokenize`.

    Kept as the byte-exact spec contract; called as a fallback when the
    C extension is absent.
    """
    if not name:
        return []

    tokens: list[tuple[str, object]] = []
    str_buf: list[str] = []

    # ``_TOKEN_RE.finditer`` walks the input in C, yielding each
    # maximal digit-run or non-digit-run as a single match.
    for m in _TOKEN_RE.finditer(name):
        digit_run = m.group(1)
        if digit_run is not None:
            # Validate as numeric:
            #  - "0" alone is valid (binding decision §103).
            #  - Run with non-'0' first char is valid.
            #  - Otherwise (length ≥ 2 with leading '0'), invalid.
            run_len = len(digit_run)
            if run_len == 1 or digit_run[0] != "0":
                # Also check int64 overflow (binding decision §104).
                value = int(digit_run)
                if value < _NUMERIC_MAX:
                    if str_buf:
                        tokens.append(("str", "".join(str_buf)))
                        str_buf.clear()
                    tokens.append(("num", value))
                    continue
            # Invalid (leading-zero or oversize): absorb into string.
            str_buf.append(digit_run)
        else:
            str_buf.append(m.group(2))

    if str_buf:
        tokens.append(("str", "".join(str_buf)))
    return tokens


# ── Mode selection ─────────────────────────────────────────────────


def _select_mode(
    tokenised: list[list[tuple[str, object]]],
) -> tuple[int, list[int] | None]:
    """Decide columnar vs verbatim and return (mode, type_table).

    Returns (MODE_COLUMNAR, [type, ...]) when all reads share the
    same token count AND per-column token type. Empty input list →
    (MODE_COLUMNAR, []) per HANDOFF.md §3.3 / gotcha §111. Otherwise
    returns (MODE_VERBATIM, None).
    """
    if not tokenised:
        return MODE_COLUMNAR, []

    first_count = len(tokenised[0])
    for tokens in tokenised[1:]:
        if len(tokens) != first_count:
            return MODE_VERBATIM, None

    # All reads have the same column count. Check per-column types.
    type_table = [
        _TYPE_NUMERIC if t == "num" else _TYPE_STRING
        for (t, _v) in tokenised[0]
    ]
    for tokens in tokenised[1:]:
        for col_idx, (t, _v) in enumerate(tokens):
            expected = _TYPE_NUMERIC if t == "num" else _TYPE_STRING
            if expected != type_table[col_idx]:
                return MODE_VERBATIM, None

    return MODE_COLUMNAR, type_table


# ── Public API ─────────────────────────────────────────────────────


def encode(names: list[str]) -> bytes:
    """Encode a list of read names using NAME_TOKENIZED.

    Tokenises each name into numeric and string runs, detects per-
    column type, and emits either a columnar or verbatim stream per
    the wire format in this module's docstring (HANDOFF.md M85B §3).
    Returns a self-contained byte string.

    Names must be 7-bit ASCII (binding decision §10 non-goals); non-
    ASCII strings raise ``ValueError`` on encode. An empty list
    produces an 8-byte stream (header + n_columns = 0).

    Parameters
    ----------
    names:
        List of read names (Python ``str``, ASCII only).

    Returns
    -------
    bytes
        Encoded stream.

    Raises
    ------
    ValueError
        On non-ASCII input, or if ``len(names)`` exceeds uint32
        range.
    """
    n_reads = len(names)
    if n_reads > 0xFFFFFFFF:
        raise ValueError(
            f"NAME_TOKENIZED n_reads {n_reads} exceeds uint32 limit"
        )

    # Validate ASCII early; .encode('ascii') raises UnicodeEncodeError
    # which we re-raise as ValueError for a uniform error contract.
    encoded_names: list[bytes] = []
    for idx, name in enumerate(names):
        try:
            encoded_names.append(name.encode("ascii"))
        except UnicodeEncodeError as exc:
            raise ValueError(
                f"NAME_TOKENIZED name at index {idx} contains non-ASCII bytes"
            ) from exc

    # Pass 1: tokenise.
    tokenised = [_tokenize(name) for name in names]

    # Pass 2: choose mode.
    mode, type_table = _select_mode(tokenised)

    header = struct.pack(">BBBI", VERSION, SCHEME_LEAN_COLUMNAR, mode, n_reads)

    if mode == MODE_COLUMNAR:
        body = _encode_columnar(tokenised, type_table or [])
    else:
        body = _encode_verbatim(encoded_names)

    return header + body


def decode(encoded: bytes) -> list[str]:
    """Decode a stream produced by :func:`encode`.

    Returns the list of read names in the original order.

    Raises
    ------
    ValueError
        If the stream is shorter than the 7-byte header, has a bad
        version byte, has a bad scheme_id, has a bad mode byte, or
        contains a malformed body (varint runs off the end, trailing
        bytes, an inline-dictionary code that exceeds the current
        dict size, etc.).
    """
    if len(encoded) < HEADER_LEN:
        raise ValueError(
            f"NAME_TOKENIZED stream too short for header: "
            f"{len(encoded)} < {HEADER_LEN}"
        )

    version, scheme_id, mode, n_reads = struct.unpack(
        ">BBBI", encoded[:HEADER_LEN]
    )

    if version != VERSION:
        raise ValueError(
            f"NAME_TOKENIZED bad version byte: 0x{version:02x} "
            f"(expected 0x{VERSION:02x})"
        )
    if scheme_id != SCHEME_LEAN_COLUMNAR:
        raise ValueError(
            f"NAME_TOKENIZED unknown scheme_id: 0x{scheme_id:02x} "
            f"(only 0x{SCHEME_LEAN_COLUMNAR:02x} = 'lean-columnar' is defined)"
        )
    if mode == MODE_COLUMNAR:
        names, consumed = _decode_columnar(encoded, HEADER_LEN, n_reads)
    elif mode == MODE_VERBATIM:
        names, consumed = _decode_verbatim(encoded, HEADER_LEN, n_reads)
    else:
        raise ValueError(
            f"NAME_TOKENIZED bad mode byte: 0x{mode:02x} "
            f"(expected 0x00 columnar or 0x01 verbatim)"
        )

    if consumed != len(encoded):
        raise ValueError(
            f"NAME_TOKENIZED trailing bytes: consumed {consumed} of "
            f"{len(encoded)}"
        )
    return names


# ── Columnar encode / decode ───────────────────────────────────────


def _encode_columnar(
    tokenised: list[list[tuple[str, object]]],
    type_table: list[int],
) -> bytes:
    """Emit the columnar body. Caller has already chosen this mode."""
    if _HAVE_C_EXTENSION:
        return _ext.encode_columnar_c(tokenised, type_table)
    return _encode_columnar_py(tokenised, type_table)


def _encode_columnar_py(
    tokenised: list[list[tuple[str, object]]],
    type_table: list[int],
) -> bytes:
    """Pure-Python reference implementation of :func:`_encode_columnar`."""
    n_reads = len(tokenised)
    n_columns = len(type_table)
    if n_columns > 0xFF:
        raise ValueError(
            f"NAME_TOKENIZED n_columns {n_columns} exceeds uint8 limit"
        )

    out = bytearray()
    out.append(n_columns)
    out.extend(type_table)

    # Local aliases for speed in the inner loops.
    varint_encode = _varint_encode
    svarint_encode = _svarint_encode
    extend = out.extend

    for col_idx in range(n_columns):
        col_type = type_table[col_idx]
        if col_type == _TYPE_NUMERIC:
            # First read: varint seed; subsequent reads: zigzag delta.
            col0 = tokenised[0][col_idx][1]
            assert isinstance(col0, int)
            prev: int = col0
            extend(varint_encode(prev))
            for read_idx in range(1, n_reads):
                cur = tokenised[read_idx][col_idx][1]
                # cur is int (validated by mode-selection pass).
                extend(svarint_encode(cur - prev))  # type: ignore[operator]
                prev = cur  # type: ignore[assignment]
        else:
            # Inline dictionary, codes assigned in insertion order.
            dict_idx: dict[str, int] = {}
            dict_get = dict_idx.get
            for read_idx in range(n_reads):
                token = tokenised[read_idx][col_idx][1]
                code = dict_get(token)
                if code is None:
                    new_code = len(dict_idx)
                    dict_idx[token] = new_code  # type: ignore[index]
                    extend(varint_encode(new_code))
                    payload = token.encode("ascii")  # type: ignore[union-attr]
                    extend(varint_encode(len(payload)))
                    extend(payload)
                else:
                    extend(varint_encode(code))
    return bytes(out)


def _decode_columnar(
    buf: bytes, offset: int, n_reads: int
) -> tuple[list[str], int]:
    """Decode a columnar body starting at ``buf[offset:]``.

    Returns (names, new_offset).
    """
    if _HAVE_C_EXTENSION:
        # The C path requires bytes input (not memoryview/bytearray).
        if not isinstance(buf, bytes):
            buf = bytes(buf)
        return _ext.decode_columnar_c(buf, offset, n_reads)
    return _decode_columnar_py(buf, offset, n_reads)


def _decode_columnar_py(
    buf: bytes, offset: int, n_reads: int
) -> tuple[list[str], int]:
    """Pure-Python reference implementation of :func:`_decode_columnar`."""
    if offset >= len(buf):
        raise ValueError(
            "NAME_TOKENIZED columnar body missing n_columns byte"
        )
    n_columns = buf[offset]
    offset += 1

    if offset + n_columns > len(buf):
        raise ValueError(
            f"NAME_TOKENIZED columnar type table truncated: need "
            f"{n_columns} bytes at offset {offset}"
        )
    type_table = list(buf[offset : offset + n_columns])
    offset += n_columns

    for t in type_table:
        if t not in (_TYPE_NUMERIC, _TYPE_STRING):
            raise ValueError(
                f"NAME_TOKENIZED unknown column type 0x{t:02x}"
            )

    if n_reads == 0:
        # Empty-batch contract: header + n_columns (typically 0)
        # only; no further bytes for columns.
        return [], offset

    # Per-column materialisation.
    columns: list[list[object]] = []
    for col_type in type_table:
        col_values: list[object] = []
        if col_type == _TYPE_NUMERIC:
            seed, offset = _varint_decode(buf, offset)
            col_values.append(seed)
            prev = seed
            for _ in range(n_reads - 1):
                delta, offset = _svarint_decode(buf, offset)
                cur = prev + delta
                col_values.append(cur)
                prev = cur
        else:
            dict_entries: list[str] = []
            for _ in range(n_reads):
                code, offset = _varint_decode(buf, offset)
                cur_size = len(dict_entries)
                if code < cur_size:
                    col_values.append(dict_entries[code])
                elif code == cur_size:
                    length, offset = _varint_decode(buf, offset)
                    if offset + length > len(buf):
                        raise ValueError(
                            "NAME_TOKENIZED string literal runs off end of stream"
                        )
                    payload = buf[offset : offset + length]
                    offset += length
                    try:
                        text = payload.decode("ascii")
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
    names: list[str] = []
    for read_idx in range(n_reads):
        parts: list[str] = []
        for col_idx, col_type in enumerate(type_table):
            v = columns[col_idx][read_idx]
            if col_type == _TYPE_NUMERIC:
                parts.append(str(v))
            else:
                assert isinstance(v, str)
                parts.append(v)
        names.append("".join(parts))
    return names, offset


# ── Verbatim encode / decode ───────────────────────────────────────


def _encode_verbatim(encoded_names: list[bytes]) -> bytes:
    if _HAVE_C_EXTENSION:
        return _ext.encode_verbatim_c(encoded_names)
    return _encode_verbatim_py(encoded_names)


def _encode_verbatim_py(encoded_names: list[bytes]) -> bytes:
    out = bytearray()
    for payload in encoded_names:
        out.extend(_varint_encode(len(payload)))
        out.extend(payload)
    return bytes(out)


def _decode_verbatim(
    buf: bytes, offset: int, n_reads: int
) -> tuple[list[str], int]:
    if _HAVE_C_EXTENSION:
        if not isinstance(buf, bytes):
            buf = bytes(buf)
        return _ext.decode_verbatim_c(buf, offset, n_reads)
    return _decode_verbatim_py(buf, offset, n_reads)


def _decode_verbatim_py(
    buf: bytes, offset: int, n_reads: int
) -> tuple[list[str], int]:
    names: list[str] = []
    for _ in range(n_reads):
        length, offset = _varint_decode(buf, offset)
        if offset + length > len(buf):
            raise ValueError(
                "NAME_TOKENIZED verbatim entry runs off end of stream"
            )
        payload = buf[offset : offset + length]
        offset += length
        try:
            names.append(payload.decode("ascii"))
        except UnicodeDecodeError as exc:
            raise ValueError(
                "NAME_TOKENIZED verbatim entry contains non-ASCII bytes"
            ) from exc
    return names, offset
