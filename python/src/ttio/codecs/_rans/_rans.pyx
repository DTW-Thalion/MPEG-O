# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
"""TTI-O rANS Cython accelerator — order-0 and order-1.

Byte-exact port of the pure-Python reference at
:mod:`ttio.codecs.rans`. Public API:

* :func:`encode_order0_c(data)` -> ``(payload, freq)``
* :func:`decode_order0_c(payload, orig_len, freq)`` -> ``bytes``
* :func:`encode_order1_c(data)`` -> ``(payload, freqs)``
* :func:`decode_order1_c(payload, orig_len, freqs)`` -> ``bytes``

The wrapper in :mod:`ttio.codecs.rans` handles wire-format
serialisation (header, frequency-table layout) and dispatches to
these functions when this extension is loadable.

Algorithm parameters (must match rans.py):

* L           = 1 << 23
* M           = 1 << 12 = 4096
* B (renorm)  = 1 << 8  = 256
* state width = 64-bit, but we hold ``x`` in a ``uint64_t``.
"""

from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t, int32_t, int64_t
from libc.stdlib cimport malloc, free, calloc
from libc.string cimport memset


# ── Algorithm constants (must match rans.py) ───────────────────────────

cdef uint32_t R_M_BITS  = 12
cdef uint32_t R_M       = 1u << 12          # 4096
cdef uint32_t R_M_MASK  = (1u << 12) - 1
cdef uint32_t R_B_BITS  = 8
cdef uint64_t R_L       = <uint64_t>1 << 23  # 2**23
cdef uint64_t R_BASE    = <uint64_t>1 << 11  # L >> M_BITS
# x_max(f) = (L >> M_BITS) << B_BITS) * f = R_BASE * 256 * f


# ── Frequency-table normalisation ──────────────────────────────────────

cdef int32_t _normalise_freqs_c(
    int32_t* cnt, int32_t* freq_out
) noexcept nogil:
    """Normalise raw count[256] to freq_out[256] summing to M.

    Byte-exact port of :func:`rans._normalise_freqs`:

      1. ``f[s] = max(1, cnt[s] * M // total)`` for cnt[s] > 0,
         otherwise 0.
      2. ``delta = M - sum(f)``.
      3. delta > 0: round-robin +1 over symbols sorted by
         (-cnt, +s), only those with cnt > 0.
      4. delta < 0: round-robin -1 over symbols sorted by
         (cnt, +s), skipping any already at freq == 1. Returns
         -1 if all eligible reach 1 before delta hits 0.

    Returns 0 on success, -1 on under-flow.
    """
    cdef int64_t total = 0
    cdef int32_t i, s, j, n_eligible, delta, idx, guard
    cdef int32_t order_buf[256]
    cdef int32_t key_buf[256]

    for s in range(256):
        total += cnt[s]
    if total <= 0:
        return -1

    # Step 1: proportional scale + clamp to >=1 for any cnt > 0.
    for s in range(256):
        if cnt[s] > 0:
            scaled = (<int64_t>cnt[s] * <int64_t>R_M) // total
            freq_out[s] = <int32_t>scaled if scaled >= 1 else 1
        else:
            freq_out[s] = 0

    # delta = M - sum(freq).
    delta = R_M
    for s in range(256):
        delta -= freq_out[s]

    if delta == 0:
        return 0

    # Build the eligible-symbol order. Tie-break key depends on
    # which direction we're nudging.
    n_eligible = 0
    if delta > 0:
        # Sort by (-cnt[s], +s).  We use a simple selection-style
        # comparator over a stable insertion sort since 256 is tiny
        # and we want byte-exact match with Python's stable sort.
        for s in range(256):
            if cnt[s] > 0:
                order_buf[n_eligible] = s
                n_eligible += 1
        # Insertion sort by descending cnt, ascending s.
        for i in range(1, n_eligible):
            tmp_s = order_buf[i]
            j = i
            while j > 0:
                if cnt[order_buf[j - 1]] < cnt[tmp_s]:
                    order_buf[j] = order_buf[j - 1]
                    j -= 1
                elif (cnt[order_buf[j - 1]] == cnt[tmp_s]
                      and order_buf[j - 1] > tmp_s):
                    order_buf[j] = order_buf[j - 1]
                    j -= 1
                else:
                    break
            order_buf[j] = tmp_s
        # Round-robin +1.
        idx = 0
        while delta > 0:
            freq_out[order_buf[idx % n_eligible]] += 1
            idx += 1
            delta -= 1
    else:
        # Sort by (+cnt[s], +s).
        for s in range(256):
            if cnt[s] > 0:
                order_buf[n_eligible] = s
                n_eligible += 1
        for i in range(1, n_eligible):
            tmp_s = order_buf[i]
            j = i
            while j > 0:
                if cnt[order_buf[j - 1]] > cnt[tmp_s]:
                    order_buf[j] = order_buf[j - 1]
                    j -= 1
                elif (cnt[order_buf[j - 1]] == cnt[tmp_s]
                      and order_buf[j - 1] > tmp_s):
                    order_buf[j] = order_buf[j - 1]
                    j -= 1
                else:
                    break
            order_buf[j] = tmp_s
        # Round-robin -1, skipping freq==1.
        idx = 0
        guard = 0
        while delta < 0:
            s = order_buf[idx % n_eligible]
            if freq_out[s] > 1:
                freq_out[s] -= 1
                delta += 1
                guard = 0
            else:
                guard += 1
                if guard > n_eligible:
                    return -1
            idx += 1

    return 0


cdef inline void _cumulative_c(int32_t* freq, int32_t* cum) noexcept nogil:
    """cum[s] = sum(freq[0..s)).  cum has length 257."""
    cdef int32_t s, running = 0
    for s in range(256):
        cum[s] = running
        running += freq[s]
    cum[256] = running


cdef inline void _slot_to_symbol_c(int32_t* freq, uint8_t* table) noexcept nogil:
    """Build the M-element slot->symbol table for decode."""
    cdef int32_t s, j, pos = 0
    cdef int32_t f
    for s in range(256):
        f = freq[s]
        for j in range(f):
            table[pos + j] = <uint8_t>s
        pos += f


# ── Order-0 encode ────────────────────────────────────────────────────

def encode_order0_c(bytes data):
    """Order-0 encode. Returns ``(payload_bytes, freq_list)``.

    Empty input returns the canonical flat freq table + 4-byte L bootstrap.
    """
    cdef Py_ssize_t n = len(data)
    cdef int32_t cnt[256]
    cdef int32_t freq[256]
    cdef int32_t cum[257]
    cdef int32_t s, i
    cdef Py_ssize_t pos
    cdef const uint8_t* dbuf

    if n == 0:
        # Flat default freq: 4096 / 256 = 16 each.
        flat = [16] * 256
        return R_L.to_bytes(4, "big"), flat

    # Pass 1: count.
    for s in range(256):
        cnt[s] = 0
    dbuf = <const uint8_t*>(<bytes>data)
    for i in range(n):
        cnt[dbuf[i]] += 1

    if _normalise_freqs_c(cnt, freq) != 0:
        raise ValueError(
            "rANS: cannot reduce freq table below M; "
            "input alphabet too large for M=4096"
        )
    _cumulative_c(freq, cum)

    # Pre-compute per-symbol x_max (renorm threshold).
    cdef uint64_t x_max[256]
    for s in range(256):
        x_max[s] = R_BASE * <uint64_t>(1u << R_B_BITS) * <uint64_t>freq[s]
    # Equivalent to: ((L >> M_BITS) << B_BITS) * f = (1<<19) * f.

    # Pass 2: encode in REVERSE.  The output bytes accumulate LIFO;
    # we'll reverse them at the end so the decoder reads forward.
    # Worst case: every symbol triggers <= 1 renorm byte, plus the
    # 4-byte final state — bound at n + 16.
    cdef Py_ssize_t cap = n + 16
    cdef uint8_t* out = <uint8_t*>malloc(cap)
    if out == NULL:
        raise MemoryError()
    cdef Py_ssize_t out_len = 0
    cdef uint64_t x = R_L
    cdef uint64_t xm
    cdef int32_t f, c
    cdef uint8_t sym

    try:
        for i in range(n - 1, -1, -1):
            sym = dbuf[i]
            f = freq[sym]
            c = cum[sym]
            xm = x_max[sym]
            while x >= xm:
                if out_len >= cap:
                    cap = cap * 2
                    out = <uint8_t*>_realloc_or_fail(out, cap)
                out[out_len] = <uint8_t>(x & 0xFFu)
                out_len += 1
                x >>= 8
            x = (x // <uint64_t>f) * <uint64_t>R_M + (x % <uint64_t>f) + <uint64_t>c

        # Build final payload: 4-byte BE state, then renorm bytes
        # in reverse-of-emission order (LIFO -> FIFO).
        payload = bytearray(4 + out_len)
        payload[0] = <uint8_t>((x >> 24) & 0xFFu)
        payload[1] = <uint8_t>((x >> 16) & 0xFFu)
        payload[2] = <uint8_t>((x >>  8) & 0xFFu)
        payload[3] = <uint8_t>( x        & 0xFFu)
        # Reverse copy.
        for pos in range(out_len):
            payload[4 + pos] = out[out_len - 1 - pos]
    finally:
        free(out)

    freq_list = [0] * 256
    for s in range(256):
        freq_list[s] = freq[s]
    return bytes(payload), freq_list


# ── Order-0 decode ────────────────────────────────────────────────────

def decode_order0_c(bytes payload, Py_ssize_t orig_len, freq_list):
    """Order-0 decode.  ``freq_list`` is the 256-entry frequency table."""
    if orig_len == 0:
        return b""
    if len(payload) < 4:
        raise ValueError("rANS: payload too short to contain bootstrap state")
    if len(freq_list) != 256:
        raise ValueError("rANS: freq table length must be 256")

    cdef int32_t freq[256]
    cdef int32_t cum[257]
    cdef int32_t s
    for s in range(256):
        freq[s] = <int32_t>freq_list[s]
    _cumulative_c(freq, cum)

    cdef uint8_t slot_table[4096]   # M = 4096
    _slot_to_symbol_c(freq, slot_table)

    cdef const uint8_t* pbuf = <const uint8_t*>(<bytes>payload)
    cdef Py_ssize_t plen = len(payload)
    cdef uint64_t x
    cdef Py_ssize_t pos = 4
    cdef uint8_t sym
    cdef uint32_t slot
    cdef int32_t f, c
    cdef Py_ssize_t i
    cdef uint8_t* obuf

    x = (<uint64_t>pbuf[0] << 24) \
      | (<uint64_t>pbuf[1] << 16) \
      | (<uint64_t>pbuf[2] <<  8) \
      |  <uint64_t>pbuf[3]

    out = bytearray(orig_len)
    obuf = out
    for i in range(orig_len):
        slot = <uint32_t>(x & R_M_MASK)
        sym = slot_table[slot]
        obuf[i] = sym
        f = freq[sym]
        c = cum[sym]
        x = <uint64_t>f * (x >> R_M_BITS) + <uint64_t>slot - <uint64_t>c
        while x < R_L:
            if pos >= plen:
                raise ValueError("rANS: unexpected end of payload")
            x = (x << 8) | <uint64_t>pbuf[pos]
            pos += 1
    return bytes(out)


# ── Order-1 encode ────────────────────────────────────────────────────

def encode_order1_c(bytes data):
    """Order-1 encode. Returns ``(payload_bytes, freqs_list_of_lists)``.

    Empty input returns the canonical 4-byte L bootstrap and 256
    all-zero rows (no transitions to model).
    """
    cdef Py_ssize_t n = len(data)
    cdef int32_t* counts = NULL
    cdef int32_t* freqs  = NULL
    cdef int32_t* cums   = NULL
    cdef uint64_t* x_maxes = NULL
    cdef int32_t row_sum, ctx, s, i
    cdef int32_t prev
    cdef const uint8_t* dbuf
    cdef Py_ssize_t cap = 0
    cdef Py_ssize_t out_len = 0
    cdef Py_ssize_t k = 0
    cdef uint8_t* out = NULL
    cdef uint64_t x = 0
    cdef uint64_t xm = 0
    cdef int32_t f = 0
    cdef int32_t c = 0
    cdef uint8_t sym = 0
    cdef int err = 0

    if n == 0:
        zeros = [[0] * 256 for _ in range(256)]
        return R_L.to_bytes(4, "big"), zeros

    # Allocate flat row-major buffers: 256 contexts × 256 slots
    counts = <int32_t*>calloc(256 * 256, sizeof(int32_t))
    freqs  = <int32_t*>calloc(256 * 256, sizeof(int32_t))
    cums   = <int32_t*>calloc(256 * 257, sizeof(int32_t))
    x_maxes = <uint64_t*>calloc(256 * 256, sizeof(uint64_t))
    if counts == NULL or freqs == NULL or cums == NULL or x_maxes == NULL:
        if counts: free(counts)
        if freqs: free(freqs)
        if cums: free(cums)
        if x_maxes: free(x_maxes)
        raise MemoryError()

    try:
        # Pass 1: count transitions.
        dbuf = <const uint8_t*>(<bytes>data)
        prev = 0
        for i in range(n):
            counts[prev * 256 + dbuf[i]] += 1
            prev = dbuf[i]

        # Per-context normalise + cum + x_max.
        for ctx in range(256):
            row_sum = 0
            for s in range(256):
                row_sum += counts[ctx * 256 + s]
            if row_sum == 0:
                continue
            if _normalise_freqs_c(&counts[ctx * 256], &freqs[ctx * 256]) != 0:
                err = 1
                break
            _cumulative_c(&freqs[ctx * 256], &cums[ctx * 257])
            for s in range(256):
                x_maxes[ctx * 256 + s] = (
                    R_BASE * <uint64_t>(1u << R_B_BITS)
                    * <uint64_t>freqs[ctx * 256 + s]
                )

        if err:
            raise ValueError(
                "rANS: cannot reduce freq table below M; "
                "input alphabet too large for M=4096"
            )

        # Pass 2: encode reverse.
        cap = n + 16
        out = <uint8_t*>malloc(cap)
        if out == NULL:
            raise MemoryError()
        out_len = 0
        x = R_L

        for i in range(n - 1, -1, -1):
            sym = dbuf[i]
            prev = dbuf[i - 1] if i > 0 else 0
            f = freqs[prev * 256 + sym]
            if f == 0:
                raise AssertionError(
                    f"order-1 encode: zero freq for ctx={prev} sym={sym}"
                )
            c = cums[prev * 257 + sym]
            xm = x_maxes[prev * 256 + sym]
            while x >= xm:
                if out_len >= cap:
                    cap = cap * 2
                    out = <uint8_t*>_realloc_or_fail(out, cap)
                out[out_len] = <uint8_t>(x & 0xFFu)
                out_len += 1
                x >>= 8
            x = (x // <uint64_t>f) * <uint64_t>R_M + (x % <uint64_t>f) + <uint64_t>c

        payload = bytearray(4 + out_len)
        payload[0] = <uint8_t>((x >> 24) & 0xFFu)
        payload[1] = <uint8_t>((x >> 16) & 0xFFu)
        payload[2] = <uint8_t>((x >>  8) & 0xFFu)
        payload[3] = <uint8_t>( x        & 0xFFu)
        for k in range(out_len):
            payload[4 + k] = out[out_len - 1 - k]

        # Convert flat freqs back to list-of-lists for the wrapper.
        freqs_out = [[0] * 256 for _ in range(256)]
        for ctx in range(256):
            row = freqs_out[ctx]
            for s in range(256):
                row[s] = freqs[ctx * 256 + s]
    finally:
        if out is not NULL:
            free(out)
        free(x_maxes)
        free(cums)
        free(freqs)
        free(counts)

    return bytes(payload), freqs_out


# ── Order-1 decode ────────────────────────────────────────────────────

def decode_order1_c(bytes payload, Py_ssize_t orig_len, freqs_list):
    cdef int32_t* freqs = NULL
    cdef int32_t* cums  = NULL
    cdef uint8_t* slot_tables = NULL  # 256 contexts × M = 256*4096
    cdef bint* ctx_active = NULL
    cdef int32_t row_sum
    cdef int32_t ctx, s
    cdef Py_ssize_t pos = 0
    cdef uint64_t x = 0
    cdef int32_t prev = 0
    cdef Py_ssize_t i
    cdef Py_ssize_t plen
    cdef const uint8_t* pbuf
    cdef uint32_t slot
    cdef uint8_t sym
    cdef int32_t f, c
    cdef uint8_t* obuf = NULL

    if orig_len == 0:
        return b""
    if len(payload) < 4:
        raise ValueError("rANS: payload too short to contain bootstrap state")
    if len(freqs_list) != 256:
        raise ValueError("rANS: freqs must have 256 rows")

    plen = len(payload)
    pbuf = <const uint8_t*>(<bytes>payload)

    freqs = <int32_t*>calloc(256 * 256, sizeof(int32_t))
    cums  = <int32_t*>calloc(256 * 257, sizeof(int32_t))
    slot_tables = <uint8_t*>calloc(256 * 4096, sizeof(uint8_t))
    if freqs == NULL or cums == NULL or slot_tables == NULL:
        if freqs: free(freqs)
        if cums: free(cums)
        if slot_tables: free(slot_tables)
        raise MemoryError()

    ctx_active = <bint*>calloc(256, sizeof(bint))
    if ctx_active == NULL:
        free(freqs); free(cums); free(slot_tables)
        raise MemoryError()

    out = bytearray(orig_len)
    obuf = out

    try:
        # Load freqs from Python and build cum/slot tables for active rows.
        for ctx in range(256):
            row = freqs_list[ctx]
            if len(row) != 256:
                raise ValueError(f"rANS: order-1 row {ctx} length != 256")
            row_sum = 0
            for s in range(256):
                freqs[ctx * 256 + s] = <int32_t>row[s]
                row_sum += freqs[ctx * 256 + s]
            if row_sum > 0:
                ctx_active[ctx] = True
                _cumulative_c(&freqs[ctx * 256], &cums[ctx * 257])
                _slot_to_symbol_c(&freqs[ctx * 256],
                                   &slot_tables[ctx * 4096])

        x = (<uint64_t>pbuf[0] << 24) \
          | (<uint64_t>pbuf[1] << 16) \
          | (<uint64_t>pbuf[2] <<  8) \
          |  <uint64_t>pbuf[3]
        pos = 4
        prev = 0
        for i in range(orig_len):
            if not ctx_active[prev]:
                raise ValueError(
                    f"rANS: order-1 context {prev} has empty frequency table"
                )
            slot = <uint32_t>(x & R_M_MASK)
            sym = slot_tables[prev * 4096 + slot]
            obuf[i] = sym
            f = freqs[prev * 256 + sym]
            c = cums[prev * 257 + sym]
            x = <uint64_t>f * (x >> R_M_BITS) + <uint64_t>slot - <uint64_t>c
            while x < R_L:
                if pos >= plen:
                    raise ValueError("rANS: unexpected end of payload")
                x = (x << 8) | <uint64_t>pbuf[pos]
                pos += 1
            prev = sym
    finally:
        free(ctx_active)
        free(slot_tables)
        free(cums)
        free(freqs)

    return bytes(out)


# ── small helpers ─────────────────────────────────────────────────────

from libc.stdlib cimport realloc as _crealloc

cdef uint8_t* _realloc_or_fail(uint8_t* p, Py_ssize_t new_cap) except NULL:
    """Realloc with explicit failure on NULL — Cython idiom."""
    cdef void* np
    np = _crealloc(p, new_cap)
    if np == NULL:
        free(p)
        raise MemoryError()
    return <uint8_t*>np
