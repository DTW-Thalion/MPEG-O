# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
"""TTI-O M94 — FQZCOMP_NX16 Cython accelerator (fixed-M=4096 form).

Implements the byte-exact context-hash + adaptive count update +
per-symbol M-normalisation + 4-way interleaved rANS inner state machine.
Output is byte-identical to the pure-Python reference at
:mod:`ttio.codecs.fqzcomp_nx16`.

The functions exported here are called by the Python wrapper when
available; otherwise the wrapper falls back to pure Python.

ObjC and Java implementations port the ALGORITHM (this .pyx is an
optional accelerator for Python only).
"""
from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t, int32_t, int64_t
from libc.stdlib cimport malloc, free, calloc
from libc.string cimport memset


# ── Constants (must match fqzcomp_nx16.py / rans.py) ────────────────


cdef uint64_t SPLITMIX_C1 = 0xff51afd7ed558ccdULL
cdef uint64_t SPLITMIX_C2 = 0xc4ceb9fe1a85ec53ULL
cdef uint64_t MASK64      = 0xFFFFFFFFFFFFFFFFULL

cdef uint32_t RANS_L = 1 << 23
cdef uint32_t RANS_B = 256
cdef uint32_t RANS_B_BITS = 8
cdef uint32_t RANS_M = 1 << 12          # 4096
cdef uint32_t RANS_M_BITS = 12
cdef uint32_t RANS_M_MASK = (1 << 12) - 1


# ── Symbol lookup helper for decoder ────────────────────────────────


cdef inline int32_t _find_symbol_for_slot(
    uint32_t* cum_buf, uint32_t slot,
) noexcept nogil:
    """Find sym such that cum_buf[sym] <= slot < cum_buf[sym+1].

    Binary search over cum_buf[0..256] (which is monotonically
    non-decreasing). Replaces a 4096-entry sym_lookup table that was
    rebuilt every symbol.
    """
    cdef int32_t lo = 0
    cdef int32_t hi = 256
    cdef int32_t mid
    while lo < hi - 1:
        mid = (lo + hi) >> 1
        if cum_buf[mid] <= slot:
            lo = mid
        else:
            hi = mid
    return lo


# ── M-normalisation helper (mirrors rans._normalise_freqs in C) ─────


cdef void _rebuild_sorted_desc(
    uint16_t* count, uint8_t* sorted_desc, uint8_t* inv_sort,
) noexcept nogil:
    """Rebuild the sorted_desc / inv_sort indices from scratch.

    Sort key: (-count[s], s) — descending count, ascending sym
    tie-break. Insertion sort suffices (called only on halve events).
    """
    cdef int32_t i, j
    cdef uint8_t tmp_sym, prev_sym
    cdef uint16_t tmp_cnt, prev_cnt

    for i in range(256):
        sorted_desc[i] = <uint8_t>i

    # Insertion sort sorted_desc on key (-count, sym).
    for i in range(1, 256):
        tmp_sym = sorted_desc[i]
        tmp_cnt = count[tmp_sym]
        j = i - 1
        while j >= 0:
            prev_sym = sorted_desc[j]
            prev_cnt = count[prev_sym]
            # tmp belongs BEFORE prev iff
            #   tmp_cnt > prev_cnt OR (tmp_cnt == prev_cnt AND tmp_sym < prev_sym).
            if tmp_cnt > prev_cnt or (tmp_cnt == prev_cnt and tmp_sym < prev_sym):
                sorted_desc[j + 1] = sorted_desc[j]
                j -= 1
            else:
                break
        sorted_desc[j + 1] = tmp_sym

    for i in range(256):
        inv_sort[sorted_desc[i]] = <uint8_t>i


cdef inline void _bubble_up(
    uint16_t* count, uint8_t* sorted_desc, uint8_t* inv_sort, int32_t sym,
) noexcept nogil:
    """Bubble ``sym`` up sorted_desc after its count was just incremented.

    Sort key: (-count[s], s). After incrementing count[sym], sym may
    belong further left (i.e. ranked higher) than its current position.
    Move it left until it's in the correct slot.
    """
    cdef int32_t pos = <int32_t>inv_sort[sym]
    cdef uint16_t cnt_sym = count[sym]
    cdef int32_t prev
    cdef uint16_t cnt_prev
    while pos > 0:
        prev = <int32_t>sorted_desc[pos - 1]
        cnt_prev = count[prev]
        # sym belongs BEFORE prev iff cnt_sym > cnt_prev OR (== AND sym < prev).
        if cnt_sym > cnt_prev or (cnt_sym == cnt_prev and sym < prev):
            sorted_desc[pos] = <uint8_t>prev
            sorted_desc[pos - 1] = <uint8_t>sym
            inv_sort[prev] = <uint8_t>pos
            inv_sort[sym] = <uint8_t>(pos - 1)
            pos -= 1
        else:
            break


cdef void _normalise_inplace_incremental(
    uint16_t* count_in, uint16_t* freq_out, uint8_t* sorted_desc,
    int32_t total,
) noexcept nogil:
    """Byte-exact equivalent of :func:`_normalise_inplace` for delta>=0.

    Uses the maintained ``sorted_desc`` (descending count, ascending
    sym tie-break) to skip the per-call insertion sort, and a caller-
    supplied ``total`` (= sum of count_in) so we don't have to re-sum
    256 entries. For the rare delta<0 case, falls back to the original
    :func:`_normalise_inplace`.

    Invariant: with the [1]*256 init and floor-1 halve, every entry of
    count_in is >= 1 for the codec's lifetime, so all 256 symbols are
    "eligible" (cnt > 0) and sorted_desc spans the full alphabet.
    Therefore the cnt==0 branch in the rescale loop is dead code and
    can be elided.
    """
    cdef int32_t i
    cdef int32_t delta
    cdef int32_t scaled
    cdef int32_t sum_after = 0

    if total <= 0:
        for i in range(256):
            freq_out[i] = 16
        return

    # Step 1: proportional scale with floor-1.
    # cnt==0 branch is unreachable under the codec's invariants
    # (init=1, halve floors at 1) — remove the branch to give the
    # compiler a tight inner loop.
    for i in range(256):
        scaled = (<int32_t>count_in[i] * <int32_t>RANS_M) // total
        if scaled < 1:
            scaled = 1
        freq_out[i] = <uint16_t>scaled
        sum_after += scaled

    delta = <int32_t>RANS_M - sum_after
    if delta == 0:
        return
    if delta > 0:
        # Distribute +1 round-robin walking sorted_desc.
        # All 256 entries are eligible (count >= 1 always), so wrap mod 256.
        i = 0
        while delta > 0:
            freq_out[sorted_desc[i & 0xFF]] = <uint16_t>(
                freq_out[sorted_desc[i & 0xFF]] + 1
            )
            i += 1
            delta -= 1
        return

    # delta < 0: rare path — fall back to canonical sort-from-scratch
    # normaliser. We re-call the original _normalise_inplace to ensure
    # byte-exact behaviour with rans._normalise_freqs.
    _normalise_inplace(count_in, freq_out)


cdef void _normalise_inplace(uint16_t* count_in, uint16_t* freq_out) noexcept nogil:
    """Normalise a 256-entry count table to sum exactly to ``M=4096``.

    Mirrors :func:`ttio.codecs.rans._normalise_freqs` deterministically.

    Algorithm:
      1. ``f[s] = max(1, cnt[s] * M // total)`` for cnt[s]>0, else 0.
      2. ``delta = M - sum(f)``.
      3. delta > 0: walk eligible symbols in order
         ``(-cnt[s], s)`` (descending count, ascending symbol),
         round-robin, +1 each visit until delta == 0.
      4. delta < 0: walk eligible symbols in order
         ``(cnt[s], s)`` (ascending count, ascending symbol),
         round-robin, -1 each visit (skip if freq == 1) until delta == 0.

    Implementation notes:
      - We materialise the sort order explicitly with a 256-entry index
        buffer + insertion sort. n_eligible is small for typical FQZCOMP
        workloads.
      - **Fast path: all counts equal.** When min_cnt == max_cnt every
        sort key is identical, so the (key, sym) tie-break collapses to
        ascending-symbol order — which is exactly what the eligibility
        scan already produces. Skip insertion sort entirely. This kills
        the O(N²) worst case for uniform/startup contexts where
        insertion sort would do the most pointless work.
      - The round-robin walk wraps modulo the sort length.
    """
    cdef int32_t total = 0
    cdef int32_t i, j
    cdef int32_t delta
    cdef int32_t scaled
    cdef int32_t sum_after = 0
    cdef int32_t order[256]
    cdef int32_t n_eligible = 0
    cdef int32_t key_a, key_b, sym_a, sym_b, tmp_idx
    cdef int32_t idx, guard
    cdef int32_t s
    cdef int32_t c
    cdef int32_t min_cnt, max_cnt

    for i in range(256):
        total += <int32_t>count_in[i]

    if total <= 0:
        # Degenerate — should never happen with floor-1 invariant.
        # Fall back to uniform 16-per-symbol (16 * 256 = 4096).
        for i in range(256):
            freq_out[i] = 16
        return

    # Step 1: proportional scale with floor-1 for non-zero.
    for i in range(256):
        if count_in[i] == 0:
            freq_out[i] = 0
        else:
            scaled = (<int32_t>count_in[i] * <int32_t>RANS_M) // total
            if scaled < 1:
                scaled = 1
            freq_out[i] = <uint16_t>scaled

    sum_after = 0
    for i in range(256):
        sum_after += <int32_t>freq_out[i]

    delta = <int32_t>RANS_M - sum_after
    if delta == 0:
        return

    # Build order list of eligible symbols (cnt > 0), tracking range
    # to enable the all-counts-equal shortcut.
    n_eligible = 0
    min_cnt = 0x7FFFFFFF
    max_cnt = 0
    for i in range(256):
        if count_in[i] > 0:
            order[n_eligible] = i
            n_eligible += 1
            c = <int32_t>count_in[i]
            if c < min_cnt:
                min_cnt = c
            if c > max_cnt:
                max_cnt = c

    # Fast path: all eligible counts equal => order[] is already sorted
    # by ascending symbol, which IS the (key, sym) tie-break for both
    # delta>0 and delta<0 cases when all keys are equal.
    if min_cnt != max_cnt:
        # Insertion sort `order`. Sort key:
        #   delta > 0: (-cnt[s], s)  — biggest count first, then ascending sym.
        #   delta < 0: ( cnt[s], s)  — smallest count first, then ascending sym.
        for i in range(1, n_eligible):
            tmp_idx = order[i]
            sym_a = tmp_idx
            if delta > 0:
                key_a = -<int32_t>count_in[sym_a]
            else:
                key_a = <int32_t>count_in[sym_a]
            j = i - 1
            while j >= 0:
                sym_b = order[j]
                if delta > 0:
                    key_b = -<int32_t>count_in[sym_b]
                else:
                    key_b = <int32_t>count_in[sym_b]
                # Sort ascending on (key, sym): swap if (key_b, sym_b) > (key_a, sym_a).
                if key_b > key_a or (key_b == key_a and sym_b > sym_a):
                    order[j + 1] = order[j]
                    j -= 1
                else:
                    break
            order[j + 1] = tmp_idx

    if delta > 0:
        idx = 0
        while delta > 0:
            freq_out[order[idx % n_eligible]] = <uint16_t>(
                freq_out[order[idx % n_eligible]] + 1
            )
            idx += 1
            delta -= 1
    else:
        idx = 0
        guard = 0
        while delta < 0:
            s = order[idx % n_eligible]
            if freq_out[s] > 1:
                freq_out[s] = <uint16_t>(freq_out[s] - 1)
                delta += 1
                guard = 0
            else:
                guard += 1
                if guard > n_eligible:
                    # Cannot reduce — caller's contract violated. Bail.
                    return
            idx += 1


# ── Context-hash helpers ────────────────────────────────────────────


cdef inline uint32_t _ctx_hash(
    uint8_t prev_q0, uint8_t prev_q1, uint8_t prev_q2,
    uint8_t pos_bucket, uint8_t revcomp, uint8_t len_bucket,
    uint32_t seed, uint8_t table_size_log2,
) noexcept nogil:
    cdef uint64_t key = (<uint64_t>prev_q0)
    key |= (<uint64_t>prev_q1) << 8
    key |= (<uint64_t>prev_q2) << 16
    key |= (<uint64_t>(pos_bucket & 0xF)) << 24
    key |= (<uint64_t>(revcomp & 0x1)) << 28
    key |= (<uint64_t>(len_bucket & 0x7)) << 29
    key |= (<uint64_t>seed) << 32

    key ^= key >> 33
    key = (key * SPLITMIX_C1) & MASK64
    key ^= key >> 33
    key = (key * SPLITMIX_C2) & MASK64
    key ^= key >> 33

    return <uint32_t>(key & ((1ULL << table_size_log2) - 1))


cdef inline uint8_t _pos_bucket(int32_t pos, int32_t read_len) noexcept nogil:
    if read_len <= 0:
        return 0
    if pos <= 0:
        return 0
    if pos >= read_len:
        return 15
    cdef int32_t b = (pos * 16) // read_len
    if b > 15:
        b = 15
    return <uint8_t>b


cdef inline uint8_t _len_bucket(int32_t read_len) noexcept nogil:
    if read_len <= 0:
        return 0
    if read_len < 50:
        return 0
    if read_len < 100:
        return 1
    if read_len < 150:
        return 2
    if read_len < 200:
        return 3
    if read_len < 300:
        return 4
    if read_len < 1000:
        return 5
    if read_len < 10000:
        return 6
    return 7


def fqzn_context_hash_c(
    uint8_t prev_q0, uint8_t prev_q1, uint8_t prev_q2,
    uint8_t pos_bucket, uint8_t revcomp, uint8_t len_bucket,
    uint32_t seed, uint8_t table_size_log2,
):
    return _ctx_hash(prev_q0, prev_q1, prev_q2, pos_bucket,
                     revcomp, len_bucket, seed, table_size_log2)


def build_encoder_contexts_c(
    bytes qualities,
    list read_lengths,
    list revcomp_flags,
    int n_padded,
    uint32_t seed,
    int table_size_log2,
):
    """Build the per-symbol context-index list in Cython.

    Mirrors :func:`fqzcomp_nx16._build_encoder_contexts` exactly.
    Returns a Python list of ints (length n_padded).
    """
    cdef int32_t n = len(qualities)
    cdef const uint8_t* qbuf = qualities
    cdef int32_t i
    cdef int32_t read_idx = 0
    cdef int32_t pos_in_read = 0
    cdef int32_t cur_read_len = read_lengths[0] if read_lengths else 0
    cdef int32_t cur_revcomp = revcomp_flags[0] if revcomp_flags else 0
    cdef int32_t cumulative_read_end = cur_read_len
    cdef int32_t n_reads = len(read_lengths)
    cdef uint8_t prev_q0 = 0, prev_q1 = 0, prev_q2 = 0
    cdef uint32_t pad_ctx = _ctx_hash(0, 0, 0, 0, 0, 0, seed, <uint8_t>table_size_log2)
    cdef uint32_t ctx
    cdef uint8_t pb, lb, sym

    out = [0] * n_padded
    for i in range(n_padded):
        if i < n:
            if i >= cumulative_read_end and read_idx < n_reads - 1:
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = revcomp_flags[read_idx]
                cumulative_read_end += cur_read_len
                prev_q0 = 0; prev_q1 = 0; prev_q2 = 0
            pb = _pos_bucket(pos_in_read, cur_read_len)
            lb = _len_bucket(cur_read_len)
            ctx = _ctx_hash(prev_q0, prev_q1, prev_q2, pb,
                            <uint8_t>(cur_revcomp & 1), lb,
                            seed, <uint8_t>table_size_log2)
            out[i] = ctx
            sym = qbuf[i]
            prev_q2 = prev_q1
            prev_q1 = prev_q0
            prev_q0 = sym
            pos_in_read += 1
        else:
            out[i] = pad_ctx
    return out


# ── Adaptive count update (no Fenwick) ─────────────────────────────


cdef inline void _adapt(
    uint16_t* count, int32_t symbol, int32_t learning_rate, int32_t max_count,
) noexcept nogil:
    """Increment ``count[symbol]`` and halve-with-floor-1 if it exceeds
    ``max_count``. Mirrors :func:`fqzcomp_nx16._adaptive_update` byte-for-byte.
    """
    cdef int32_t k
    cdef int32_t v
    count[symbol] = <uint16_t>(count[symbol] + learning_rate)
    if <int32_t>count[symbol] > max_count:
        for k in range(256):
            v = <int32_t>count[k] >> 1
            if v < 1:
                v = 1
            count[k] = <uint16_t>v


cdef inline int32_t _adapt_with_sort(
    uint16_t* count, uint8_t* sorted_desc, uint8_t* inv_sort,
    int32_t symbol, int32_t learning_rate, int32_t max_count,
    int32_t total,
) noexcept nogil:
    """Increment ``count[symbol]`` and maintain sorted_desc / inv_sort.

    Returns the new total (sum of count[]). On halve, rebuilds
    sorted_desc from scratch. On normal increment, bubbles ``symbol``
    up the sort order. Equivalent in count[] state to :func:`_adapt`;
    additionally maintains the sort indices and the running total.
    """
    count[symbol] = <uint16_t>(count[symbol] + learning_rate)
    total += learning_rate
    cdef int32_t k
    cdef int32_t v
    cdef int32_t new_total
    if <int32_t>count[symbol] > max_count:
        new_total = 0
        for k in range(256):
            v = <int32_t>count[k] >> 1
            if v < 1:
                v = 1
            count[k] = <uint16_t>v
            new_total += v
        _rebuild_sorted_desc(count, sorted_desc, inv_sort)
        return new_total
    _bubble_up(count, sorted_desc, inv_sort, symbol)
    return total


def adaptive_update_c(
    object freq,
    int symbol,
    int learning_rate,
    int max_count,
):
    """Python-callable adaptive update (used by tests / smoke).

    ``freq`` may be any 256-element Python list of ints. The list is
    mutated in place to mirror :func:`fqzcomp_nx16._adaptive_update`.
    """
    cdef uint16_t buf[256]
    cdef int i
    for i in range(256):
        buf[i] = <uint16_t>(<int>freq[i])
    _adapt(buf, symbol, learning_rate, max_count)
    for i in range(256):
        freq[i] = <int>buf[i]


cdef _encode_body_from_ctx_arr(
    bytes qualities,
    uint32_t* ctx_arr,
    int32_t n_padded,
    int table_size_log2,
    int learning_rate,
    int max_count,
):
    """Internal: run the rANS pass given a C array of context indices."""
    cdef int32_t n = len(qualities)
    cdef int32_t pad_count = (-n) & 3
    cdef int32_t i, j, k, sym, ctx
    cdef int32_t n_contexts = 1 << table_size_log2
    cdef uint32_t state[4]
    cdef int32_t cap
    cdef int32_t len0 = 0, len1 = 0, len2 = 0, len3 = 0
    cdef uint32_t f, c, x, xm
    cdef int32_t s_idx
    cdef int32_t lo, hi
    cdef uint8_t tmp
    cdef int32_t max_len, off
    cdef bytearray body
    cdef uint8_t* bb
    cdef uint16_t** ctx_counts = NULL
    cdef uint8_t** ctx_sorted_desc = NULL
    cdef uint8_t** ctx_inv_sort = NULL
    cdef int32_t* ctx_total = NULL
    cdef uint16_t* snap_f = NULL
    cdef uint16_t* snap_c = NULL
    cdef uint8_t* out0 = NULL
    cdef uint8_t* out1 = NULL
    cdef uint8_t* out2 = NULL
    cdef uint8_t* out3 = NULL
    cdef const uint8_t* qbuf = qualities
    cdef uint16_t freq_buf[256]
    cdef uint32_t cum_buf[257]
    cdef uint32_t cum_partial
    cdef int32_t s

    ctx_counts = <uint16_t**>calloc(n_contexts, sizeof(uint16_t*))
    ctx_sorted_desc = <uint8_t**>calloc(n_contexts, sizeof(uint8_t*))
    ctx_inv_sort = <uint8_t**>calloc(n_contexts, sizeof(uint8_t*))
    ctx_total = <int32_t*>calloc(n_contexts, sizeof(int32_t))
    if (ctx_counts == NULL or ctx_sorted_desc == NULL
            or ctx_inv_sort == NULL or ctx_total == NULL):
        if ctx_counts != NULL: free(ctx_counts)
        if ctx_sorted_desc != NULL: free(ctx_sorted_desc)
        if ctx_inv_sort != NULL: free(ctx_inv_sort)
        if ctx_total != NULL: free(ctx_total)
        raise MemoryError()

    snap_f = <uint16_t*>malloc(n_padded * sizeof(uint16_t))
    snap_c = <uint16_t*>malloc(n_padded * sizeof(uint16_t))
    if snap_f == NULL or snap_c == NULL:
        if snap_f != NULL: free(snap_f)
        if snap_c != NULL: free(snap_c)
        free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort); free(ctx_total)
        raise MemoryError()

    try:
        for i in range(n_padded):
            ctx = <int32_t>ctx_arr[i]
            if ctx_counts[ctx] == NULL:
                ctx_counts[ctx] = <uint16_t*>malloc(256 * sizeof(uint16_t))
                ctx_sorted_desc[ctx] = <uint8_t*>malloc(256)
                ctx_inv_sort[ctx] = <uint8_t*>malloc(256)
                if (ctx_counts[ctx] == NULL or ctx_sorted_desc[ctx] == NULL
                        or ctx_inv_sort[ctx] == NULL):
                    raise MemoryError()
                for k in range(256):
                    ctx_counts[ctx][k] = 1
                    ctx_sorted_desc[ctx][k] = <uint8_t>k
                    ctx_inv_sort[ctx][k] = <uint8_t>k
                ctx_total[ctx] = 256  # sum([1]*256)
            sym = qbuf[i] if i < n else 0
            # M-normalise count -> freq using maintained sort order.
            _normalise_inplace_incremental(
                ctx_counts[ctx], freq_buf, ctx_sorted_desc[ctx],
                ctx_total[ctx],
            )
            # We only need cum_buf[sym] (partial sum over s<sym), not
            # the full table — compute it inline.
            cum_partial = 0
            for s in range(sym):
                cum_partial += <uint32_t>freq_buf[s]
            snap_f[i] = freq_buf[sym]
            snap_c[i] = <uint16_t>cum_partial
            # Adaptive update + sort maintenance + running total.
            ctx_total[ctx] = _adapt_with_sort(
                ctx_counts[ctx], ctx_sorted_desc[ctx], ctx_inv_sort[ctx],
                sym, learning_rate, max_count, ctx_total[ctx],
            )

        for k in range(4):
            state[k] = RANS_L

        cap = (n_padded // 4 + 64) * 2 + 1024
        out0 = <uint8_t*>malloc(cap)
        out1 = <uint8_t*>malloc(cap)
        out2 = <uint8_t*>malloc(cap)
        out3 = <uint8_t*>malloc(cap)

        if out0 == NULL or out1 == NULL or out2 == NULL or out3 == NULL:
            raise MemoryError()

        for i in range(n_padded - 1, -1, -1):
            s_idx = i & 3
            f = <uint32_t>snap_f[i]
            c = <uint32_t>snap_c[i]
            x = state[s_idx]
            xm = ((RANS_L >> RANS_M_BITS) << RANS_B_BITS) * f
            if s_idx == 0:
                while x >= xm:
                    out0[len0] = <uint8_t>(x & 0xFF)
                    len0 += 1
                    x >>= 8
            elif s_idx == 1:
                while x >= xm:
                    out1[len1] = <uint8_t>(x & 0xFF)
                    len1 += 1
                    x >>= 8
            elif s_idx == 2:
                while x >= xm:
                    out2[len2] = <uint8_t>(x & 0xFF)
                    len2 += 1
                    x >>= 8
            else:
                while x >= xm:
                    out3[len3] = <uint8_t>(x & 0xFF)
                    len3 += 1
                    x >>= 8
            x = (x // f) * RANS_M + (x % f) + c
            state[s_idx] = x

        state_final = (
            int(state[0]), int(state[1]), int(state[2]), int(state[3]),
        )
        state_init = (RANS_L, RANS_L, RANS_L, RANS_L)

        for k in range(4):
            if k == 0:
                lo = 0; hi = len0 - 1
                while lo < hi:
                    tmp = out0[lo]; out0[lo] = out0[hi]; out0[hi] = tmp
                    lo += 1; hi -= 1
            elif k == 1:
                lo = 0; hi = len1 - 1
                while lo < hi:
                    tmp = out1[lo]; out1[lo] = out1[hi]; out1[hi] = tmp
                    lo += 1; hi -= 1
            elif k == 2:
                lo = 0; hi = len2 - 1
                while lo < hi:
                    tmp = out2[lo]; out2[lo] = out2[hi]; out2[hi] = tmp
                    lo += 1; hi -= 1
            else:
                lo = 0; hi = len3 - 1
                while lo < hi:
                    tmp = out3[lo]; out3[lo] = out3[hi]; out3[hi] = tmp
                    lo += 1; hi -= 1

        max_len = len0
        if len1 > max_len: max_len = len1
        if len2 > max_len: max_len = len2
        if len3 > max_len: max_len = len3

        body = bytearray(16 + 4 * max_len)
        bb = body
        (<uint32_t*>bb)[0] = <uint32_t>len0
        (<uint32_t*>bb)[1] = <uint32_t>len1
        (<uint32_t*>bb)[2] = <uint32_t>len2
        (<uint32_t*>bb)[3] = <uint32_t>len3
        off = 16
        for j in range(max_len):
            bb[off + 0] = out0[j] if j < len0 else 0
            bb[off + 1] = out1[j] if j < len1 else 0
            bb[off + 2] = out2[j] if j < len2 else 0
            bb[off + 3] = out3[j] if j < len3 else 0
            off += 4

        return bytes(body), state_init, state_final, pad_count
    finally:
        if out0 != NULL: free(out0)
        if out1 != NULL: free(out1)
        if out2 != NULL: free(out2)
        if out3 != NULL: free(out3)
        if snap_f != NULL: free(snap_f)
        if snap_c != NULL: free(snap_c)
        if ctx_counts != NULL:
            for k in range(n_contexts):
                if ctx_counts[k] != NULL:
                    free(ctx_counts[k])
                if ctx_sorted_desc[k] != NULL:
                    free(ctx_sorted_desc[k])
                if ctx_inv_sort[k] != NULL:
                    free(ctx_inv_sort[k])
            free(ctx_counts)
            free(ctx_sorted_desc)
            free(ctx_inv_sort)
            if ctx_total != NULL: free(ctx_total)


def encode_body_c(
    bytes qualities,
    list contexts,         # list of int (precomputed in Python)
    int n_padded,
    int table_size_log2,
    int learning_rate,
    int max_count,
):
    """Run the forward snapshot pass + reverse rANS encoder (fixed-M).

    Caller pre-computes the per-symbol context indices (depends on
    read_lengths + revcomp_flags + prev_q ring); we only handle the
    inner state machine here.

    Returns (body_bytes, state_init_tuple, state_final_tuple, pad_count).
    """
    cdef int32_t i
    cdef uint32_t* ctx_arr = <uint32_t*>malloc(n_padded * sizeof(uint32_t))
    if ctx_arr == NULL:
        raise MemoryError()
    try:
        for i in range(n_padded):
            ctx_arr[i] = <uint32_t>(<int32_t>contexts[i])
        return _encode_body_from_ctx_arr(
            qualities, ctx_arr, n_padded,
            table_size_log2, learning_rate, max_count,
        )
    finally:
        free(ctx_arr)


def decode_body_c(
    bytes body,
    tuple state_init,
    tuple state_final,
    int n_padded,
    list contexts,
    int table_size_log2,
    int learning_rate,
    int max_count,
):
    """Inverse of :func:`encode_body_c` (fixed-M form).

    ``contexts`` is a precomputed list of context indices (length n_padded)
    that the decoder will use in lock-step.

    Returns: bytes of length n_padded (caller truncates to num_qualities).
    """
    cdef int32_t i, j, k, sym, ctx
    cdef int32_t s
    cdef int32_t n_contexts = 1 << table_size_log2
    cdef const uint8_t* bb
    cdef uint32_t len0, len1, len2, len3, max_len
    cdef uint8_t* sb0 = NULL
    cdef uint8_t* sb1 = NULL
    cdef uint8_t* sb2 = NULL
    cdef uint8_t* sb3 = NULL
    cdef int32_t off
    cdef uint16_t** ctx_counts = NULL
    cdef uint8_t** ctx_sorted_desc = NULL
    cdef uint8_t** ctx_inv_sort = NULL
    cdef int32_t* ctx_total = NULL
    cdef bytearray out = bytearray(n_padded)
    cdef uint8_t* outp = out
    cdef uint32_t state[4]
    cdef uint32_t pos[4]
    cdef uint32_t lens[4]
    cdef uint8_t* substream_ptrs[4]
    cdef int32_t s_idx
    cdef uint32_t x, slot, f, c
    cdef int32_t init_states[4]
    cdef uint16_t freq_buf[256]
    cdef uint32_t cum_buf[257]
    cdef uint8_t sym_lookup[4096]
    cdef uint32_t pos_in_lookup
    cdef uint32_t fj

    if len(body) < 16:
        raise ValueError("FQZCOMP_NX16: body too short")

    bb = body
    len0 = (<const uint32_t*>bb)[0]
    len1 = (<const uint32_t*>bb)[1]
    len2 = (<const uint32_t*>bb)[2]
    len3 = (<const uint32_t*>bb)[3]
    max_len = len0
    if len1 > max_len: max_len = len1
    if len2 > max_len: max_len = len2
    if len3 > max_len: max_len = len3

    if len(body) < 16 + 4 * <int32_t>max_len:
        raise ValueError("FQZCOMP_NX16: body truncated")

    sb0 = <uint8_t*>malloc(len0 if len0 > 0 else 1)
    sb1 = <uint8_t*>malloc(len1 if len1 > 0 else 1)
    sb2 = <uint8_t*>malloc(len2 if len2 > 0 else 1)
    sb3 = <uint8_t*>malloc(len3 if len3 > 0 else 1)
    if sb0 == NULL or sb1 == NULL or sb2 == NULL or sb3 == NULL:
        if sb0 != NULL: free(sb0)
        if sb1 != NULL: free(sb1)
        if sb2 != NULL: free(sb2)
        if sb3 != NULL: free(sb3)
        raise MemoryError()

    # De-interleave.
    off = 16
    for j in range(<int32_t>max_len):
        if j < <int32_t>len0:
            sb0[j] = bb[off + 0]
        if j < <int32_t>len1:
            sb1[j] = bb[off + 1]
        if j < <int32_t>len2:
            sb2[j] = bb[off + 2]
        if j < <int32_t>len3:
            sb3[j] = bb[off + 3]
        off += 4

    ctx_counts = <uint16_t**>calloc(n_contexts, sizeof(uint16_t*))
    ctx_sorted_desc = <uint8_t**>calloc(n_contexts, sizeof(uint8_t*))
    ctx_inv_sort = <uint8_t**>calloc(n_contexts, sizeof(uint8_t*))
    ctx_total = <int32_t*>calloc(n_contexts, sizeof(int32_t))
    if (ctx_counts == NULL or ctx_sorted_desc == NULL
            or ctx_inv_sort == NULL or ctx_total == NULL):
        if ctx_counts != NULL: free(ctx_counts)
        if ctx_sorted_desc != NULL: free(ctx_sorted_desc)
        if ctx_inv_sort != NULL: free(ctx_inv_sort)
        if ctx_total != NULL: free(ctx_total)
        free(sb0); free(sb1); free(sb2); free(sb3)
        raise MemoryError()

    state[0] = <uint32_t>state_final[0]
    state[1] = <uint32_t>state_final[1]
    state[2] = <uint32_t>state_final[2]
    state[3] = <uint32_t>state_final[3]
    pos[0] = 0; pos[1] = 0; pos[2] = 0; pos[3] = 0
    lens[0] = len0; lens[1] = len1; lens[2] = len2; lens[3] = len3
    substream_ptrs[0] = sb0
    substream_ptrs[1] = sb1
    substream_ptrs[2] = sb2
    substream_ptrs[3] = sb3
    init_states[0] = <int32_t>state_init[0]
    init_states[1] = <int32_t>state_init[1]
    init_states[2] = <int32_t>state_init[2]
    init_states[3] = <int32_t>state_init[3]

    try:
        for i in range(n_padded):
            s_idx = i & 3
            ctx = <int32_t>contexts[i]
            if ctx_counts[ctx] == NULL:
                ctx_counts[ctx] = <uint16_t*>malloc(256 * sizeof(uint16_t))
                ctx_sorted_desc[ctx] = <uint8_t*>malloc(256)
                ctx_inv_sort[ctx] = <uint8_t*>malloc(256)
                if (ctx_counts[ctx] == NULL or ctx_sorted_desc[ctx] == NULL
                        or ctx_inv_sort[ctx] == NULL):
                    raise MemoryError()
                for k in range(256):
                    ctx_counts[ctx][k] = 1
                    ctx_sorted_desc[ctx][k] = <uint8_t>k
                    ctx_inv_sort[ctx][k] = <uint8_t>k
                ctx_total[ctx] = 256

            # M-normalise count -> freq using maintained sort order.
            _normalise_inplace_incremental(
                ctx_counts[ctx], freq_buf, ctx_sorted_desc[ctx], ctx_total[ctx],
            )
            # Build cum.
            cum_buf[0] = 0
            for s in range(256):
                cum_buf[s + 1] = cum_buf[s] + <uint32_t>freq_buf[s]

            x = state[s_idx]
            slot = x & RANS_M_MASK
            # Binary search cum_buf for sym such that
            # cum_buf[sym] <= slot < cum_buf[sym+1].
            sym = _find_symbol_for_slot(cum_buf, slot)
            outp[i] = <uint8_t>sym
            f = <uint32_t>freq_buf[sym]
            c = cum_buf[sym]
            x = f * (x >> RANS_M_BITS) + slot - c
            while x < RANS_L:
                if pos[s_idx] >= lens[s_idx]:
                    raise ValueError("FQZCOMP_NX16: substream exhausted")
                x = (x << 8) | substream_ptrs[s_idx][pos[s_idx]]
                pos[s_idx] += 1
            state[s_idx] = x

            ctx_total[ctx] = _adapt_with_sort(
                ctx_counts[ctx], ctx_sorted_desc[ctx], ctx_inv_sort[ctx],
                sym, learning_rate, max_count, ctx_total[ctx],
            )

        for k in range(4):
            if <int32_t>state[k] != init_states[k]:
                raise ValueError(
                    f"FQZCOMP_NX16: post-decode state {state[k]} != "
                    f"state_init {init_states[k]} at substream {k}"
                )

        return bytes(out)
    finally:
        if ctx_counts != NULL:
            for k in range(n_contexts):
                if ctx_counts[k] != NULL:
                    free(ctx_counts[k])
                if ctx_sorted_desc[k] != NULL:
                    free(ctx_sorted_desc[k])
                if ctx_inv_sort[k] != NULL:
                    free(ctx_inv_sort[k])
            free(ctx_counts)
            free(ctx_sorted_desc)
            free(ctx_inv_sort)
            if ctx_total != NULL: free(ctx_total)
        free(sb0); free(sb1); free(sb2); free(sb3)


def decode_body_with_evolver_c(
    bytes body,
    tuple state_init,
    tuple state_final,
    int n_qualities,
    int n_padded,
    list read_lengths,
    list revcomp_flags,
    uint32_t seed,
    int table_size_log2,
    int learning_rate,
    int max_count,
):
    """Inverse of :func:`encode_body_c`, with embedded context evolution.

    Unlike :func:`decode_body_c` which requires a pre-computed context list
    (only possible when symbols are known up front, i.e. on the encoder side),
    this entry point evolves the context vector inline as symbols are decoded.

    Mirrors :class:`fqzcomp_nx16._StatefulContextEvolver` byte-for-byte:
      * ``context_for(i)`` runs BEFORE decoding symbol ``i``.
      * After decoding ``sym``, ``feed(sym, i)`` advances the prev_q ring
        and ``pos_in_read`` (only when ``i < n_qualities``).

    Returns: bytes of length n_padded (caller truncates to n_qualities).
    """
    cdef int32_t i, j, k, sym, ctx
    cdef int32_t s
    cdef int32_t n_contexts = 1 << table_size_log2
    cdef const uint8_t* bb
    cdef uint32_t len0, len1, len2, len3, max_len
    cdef uint8_t* sb0 = NULL
    cdef uint8_t* sb1 = NULL
    cdef uint8_t* sb2 = NULL
    cdef uint8_t* sb3 = NULL
    cdef int32_t off
    cdef uint16_t** ctx_counts = NULL
    cdef uint8_t** ctx_sorted_desc = NULL
    cdef uint8_t** ctx_inv_sort = NULL
    cdef int32_t* ctx_total = NULL
    cdef bytearray out = bytearray(n_padded)
    cdef uint8_t* outp = out
    cdef uint32_t state[4]
    cdef uint32_t pos[4]
    cdef uint32_t lens[4]
    cdef uint8_t* substream_ptrs[4]
    cdef int32_t s_idx
    cdef uint32_t x, slot, f, c
    cdef int32_t init_states[4]
    cdef uint16_t freq_buf[256]
    cdef uint32_t cum_buf[257]
    cdef uint8_t sym_lookup[4096]
    cdef uint32_t pos_in_lookup
    cdef uint32_t fj
    cdef int32_t n_reads = len(read_lengths)
    cdef int32_t read_idx = 0
    cdef int32_t pos_in_read = 0
    cdef int32_t cur_read_len = <int32_t>(<int>read_lengths[0]) if n_reads > 0 else 0
    cdef int32_t cur_revcomp = <int32_t>(<int>revcomp_flags[0]) if n_reads > 0 else 0
    cdef int32_t cumulative_read_end = cur_read_len
    cdef uint8_t prev_q0 = 0, prev_q1 = 0, prev_q2 = 0
    cdef uint32_t pad_ctx = _ctx_hash(
        0, 0, 0, 0, 0, 0, seed, <uint8_t>table_size_log2,
    )
    cdef uint8_t pb, lb

    if len(body) < 16:
        raise ValueError("FQZCOMP_NX16: body too short")

    bb = body
    len0 = (<const uint32_t*>bb)[0]
    len1 = (<const uint32_t*>bb)[1]
    len2 = (<const uint32_t*>bb)[2]
    len3 = (<const uint32_t*>bb)[3]
    max_len = len0
    if len1 > max_len: max_len = len1
    if len2 > max_len: max_len = len2
    if len3 > max_len: max_len = len3

    if len(body) < 16 + 4 * <int32_t>max_len:
        raise ValueError("FQZCOMP_NX16: body truncated")

    sb0 = <uint8_t*>malloc(len0 if len0 > 0 else 1)
    sb1 = <uint8_t*>malloc(len1 if len1 > 0 else 1)
    sb2 = <uint8_t*>malloc(len2 if len2 > 0 else 1)
    sb3 = <uint8_t*>malloc(len3 if len3 > 0 else 1)
    if sb0 == NULL or sb1 == NULL or sb2 == NULL or sb3 == NULL:
        if sb0 != NULL: free(sb0)
        if sb1 != NULL: free(sb1)
        if sb2 != NULL: free(sb2)
        if sb3 != NULL: free(sb3)
        raise MemoryError()

    # De-interleave.
    off = 16
    for j in range(<int32_t>max_len):
        if j < <int32_t>len0:
            sb0[j] = bb[off + 0]
        if j < <int32_t>len1:
            sb1[j] = bb[off + 1]
        if j < <int32_t>len2:
            sb2[j] = bb[off + 2]
        if j < <int32_t>len3:
            sb3[j] = bb[off + 3]
        off += 4

    ctx_counts = <uint16_t**>calloc(n_contexts, sizeof(uint16_t*))
    ctx_sorted_desc = <uint8_t**>calloc(n_contexts, sizeof(uint8_t*))
    ctx_inv_sort = <uint8_t**>calloc(n_contexts, sizeof(uint8_t*))
    ctx_total = <int32_t*>calloc(n_contexts, sizeof(int32_t))
    if (ctx_counts == NULL or ctx_sorted_desc == NULL
            or ctx_inv_sort == NULL or ctx_total == NULL):
        if ctx_counts != NULL: free(ctx_counts)
        if ctx_sorted_desc != NULL: free(ctx_sorted_desc)
        if ctx_inv_sort != NULL: free(ctx_inv_sort)
        if ctx_total != NULL: free(ctx_total)
        free(sb0); free(sb1); free(sb2); free(sb3)
        raise MemoryError()

    state[0] = <uint32_t>state_final[0]
    state[1] = <uint32_t>state_final[1]
    state[2] = <uint32_t>state_final[2]
    state[3] = <uint32_t>state_final[3]
    pos[0] = 0; pos[1] = 0; pos[2] = 0; pos[3] = 0
    lens[0] = len0; lens[1] = len1; lens[2] = len2; lens[3] = len3
    substream_ptrs[0] = sb0
    substream_ptrs[1] = sb1
    substream_ptrs[2] = sb2
    substream_ptrs[3] = sb3
    init_states[0] = <int32_t>state_init[0]
    init_states[1] = <int32_t>state_init[1]
    init_states[2] = <int32_t>state_init[2]
    init_states[3] = <int32_t>state_init[3]

    try:
        for i in range(n_padded):
            s_idx = i & 3
            # Evolve context inline (mirrors _StatefulContextEvolver.context_for).
            if i < n_qualities:
                if i >= cumulative_read_end and read_idx < n_reads - 1:
                    read_idx += 1
                    pos_in_read = 0
                    cur_read_len = <int32_t>(<int>read_lengths[read_idx])
                    cur_revcomp = <int32_t>(<int>revcomp_flags[read_idx])
                    cumulative_read_end += cur_read_len
                    prev_q0 = 0; prev_q1 = 0; prev_q2 = 0
                pb = _pos_bucket(pos_in_read, cur_read_len)
                lb = _len_bucket(cur_read_len)
                ctx = <int32_t>_ctx_hash(
                    prev_q0, prev_q1, prev_q2, pb,
                    <uint8_t>(cur_revcomp & 1), lb,
                    seed, <uint8_t>table_size_log2,
                )
            else:
                ctx = <int32_t>pad_ctx

            if ctx_counts[ctx] == NULL:
                ctx_counts[ctx] = <uint16_t*>malloc(256 * sizeof(uint16_t))
                ctx_sorted_desc[ctx] = <uint8_t*>malloc(256)
                ctx_inv_sort[ctx] = <uint8_t*>malloc(256)
                if (ctx_counts[ctx] == NULL or ctx_sorted_desc[ctx] == NULL
                        or ctx_inv_sort[ctx] == NULL):
                    raise MemoryError()
                for k in range(256):
                    ctx_counts[ctx][k] = 1
                    ctx_sorted_desc[ctx][k] = <uint8_t>k
                    ctx_inv_sort[ctx][k] = <uint8_t>k
                ctx_total[ctx] = 256

            # M-normalise count -> freq using maintained sort order.
            _normalise_inplace_incremental(
                ctx_counts[ctx], freq_buf, ctx_sorted_desc[ctx], ctx_total[ctx],
            )
            # Build cum.
            cum_buf[0] = 0
            for s in range(256):
                cum_buf[s + 1] = cum_buf[s] + <uint32_t>freq_buf[s]

            x = state[s_idx]
            slot = x & RANS_M_MASK
            # Binary search cum_buf for sym such that
            # cum_buf[sym] <= slot < cum_buf[sym+1].
            sym = _find_symbol_for_slot(cum_buf, slot)
            outp[i] = <uint8_t>sym
            f = <uint32_t>freq_buf[sym]
            c = cum_buf[sym]
            x = f * (x >> RANS_M_BITS) + slot - c
            while x < RANS_L:
                if pos[s_idx] >= lens[s_idx]:
                    raise ValueError("FQZCOMP_NX16: substream exhausted")
                x = (x << 8) | substream_ptrs[s_idx][pos[s_idx]]
                pos[s_idx] += 1
            state[s_idx] = x

            ctx_total[ctx] = _adapt_with_sort(
                ctx_counts[ctx], ctx_sorted_desc[ctx], ctx_inv_sort[ctx],
                sym, learning_rate, max_count, ctx_total[ctx],
            )

            # Advance evolver state (mirrors _StatefulContextEvolver.feed).
            if i < n_qualities:
                prev_q2 = prev_q1
                prev_q1 = prev_q0
                prev_q0 = <uint8_t>sym
                pos_in_read += 1

        for k in range(4):
            if <int32_t>state[k] != init_states[k]:
                raise ValueError(
                    f"FQZCOMP_NX16: post-decode state {state[k]} != "
                    f"state_init {init_states[k]} at substream {k}"
                )

        return bytes(out)
    finally:
        if ctx_counts != NULL:
            for k in range(n_contexts):
                if ctx_counts[k] != NULL:
                    free(ctx_counts[k])
                if ctx_sorted_desc[k] != NULL:
                    free(ctx_sorted_desc[k])
                if ctx_inv_sort[k] != NULL:
                    free(ctx_inv_sort[k])
            free(ctx_counts)
            free(ctx_sorted_desc)
            free(ctx_inv_sort)
            if ctx_total != NULL: free(ctx_total)
        free(sb0); free(sb1); free(sb2); free(sb3)
