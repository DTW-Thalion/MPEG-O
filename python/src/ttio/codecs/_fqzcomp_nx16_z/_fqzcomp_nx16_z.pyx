# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
"""TTI-O M94.Z — CRAM-mimic FQZCOMP_NX16 Cython accelerator.

Implements the byte-exact static-per-block freq table + bit-pack
context + 4-way interleaved 16-bit-renorm rANS state machine for
M94.Z. Output is byte-identical to the pure-Python reference at
:mod:`ttio.codecs.fqzcomp_nx16_z`.

The functions exported here are called by the Python wrapper when
available; otherwise the wrapper falls back to pure Python.

Two-pass encode: pass 1 walks forward to gather counts AND records the
context sequence; per-context counts are normalised once to T=4096.
Pass 2 walks reverse, encoding each symbol with its context's static
(freq, cum). Decode walks forward, mirroring the encoder's context
ring evolution, with binary search for slot lookup.
"""
from libc.stdint cimport (
    uint8_t, uint16_t, uint32_t, uint64_t, int8_t, int32_t, int64_t,
)
from libc.stdlib cimport malloc, free, calloc
from libc.string cimport memset, memcpy


# ── Algorithm constants (must match fqzcomp_nx16_z.py) ──────────────


cdef uint32_t Z_L = 1 << 15            # 32 768
cdef uint32_t Z_B_BITS = 16
cdef uint32_t Z_B = 1 << 16            # 65 536
cdef uint32_t Z_B_MASK = (1 << 16) - 1
cdef uint32_t Z_T = 1 << 12            # 4096
cdef uint32_t Z_T_BITS = 12
cdef uint32_t Z_T_MASK = (1 << 12) - 1
cdef uint32_t Z_X_MAX_PREFACTOR = (Z_L >> Z_T_BITS) << Z_B_BITS  # 524288


# ── Context bit-pack inline helpers (per spec §4.2) ─────────────────


cdef inline uint32_t _z_pos_bucket(
    int32_t position, int32_t read_length, int32_t pbits,
) noexcept nogil:
    cdef int32_t n_buckets
    if pbits <= 0:
        return 0
    n_buckets = 1 << pbits
    if read_length <= 0 or position <= 0:
        return 0
    if position >= read_length:
        return <uint32_t>(n_buckets - 1)
    cdef int32_t b = (position * n_buckets) // read_length
    if b > n_buckets - 1:
        b = n_buckets - 1
    return <uint32_t>b


cdef inline uint32_t _z_context(
    uint32_t prev_q, uint32_t pos_bucket, uint32_t revcomp,
    int32_t qbits, int32_t pbits, int32_t sloc,
) noexcept nogil:
    cdef uint32_t qmask = (<uint32_t>1 << qbits) - 1
    cdef uint32_t pmask = (<uint32_t>1 << pbits) - 1
    cdef uint32_t smask = (<uint32_t>1 << sloc) - 1
    cdef uint32_t ctx = prev_q & qmask
    ctx |= (pos_bucket & pmask) << qbits
    ctx |= (revcomp & 1) << (qbits + pbits)
    return ctx & smask


# ── Frequency-table normalisation (per spec §3.3) ───────────────────


cdef int32_t _normalise_to_total_c(
    int32_t* raw_count, uint16_t* freq_out,
) noexcept nogil:
    """Normalise ``raw_count[256]`` to ``freq_out[256]`` summing to T=4096.

    Byte-exact port of :func:`normalise_to_total` in fqzcomp_nx16_z.py:
      1. If sum is 0, set freq[0] = T (degenerate).
      2. For each c > 0: freq[i] = max(1, (c * T + s/2) // s).
      3. If delta > 0: round-robin over symbols ordered by
         (-freq[i], i), only those with raw_count > 0, +1 each.
      4. If delta < 0: repeatedly decrement the largest freq among
         those still > 1, ties by smallest sym.

    Returns 0 on success, -1 on the "cannot reduce below floor=1" path.
    """
    cdef int32_t i, j, k, n, delta, deficit, scaled
    cdef int32_t tmp_i, tmp_f
    cdef int64_t s = 0
    cdef int32_t fsum = 0
    cdef int32_t best_i, best_v
    cdef int32_t order_buf[256]

    for i in range(256):
        s += raw_count[i]
        freq_out[i] = 0

    if s == 0:
        freq_out[0] = <uint16_t>Z_T
        return 0

    # Step 1: scale-and-floor.
    for i in range(256):
        if raw_count[i] == 0:
            continue
        # (c * T + s/2) // s  — integer round-half-up.
        scaled = <int32_t>(((<int64_t>raw_count[i] * <int64_t>Z_T) + (s >> 1)) // s)
        if scaled < 1:
            scaled = 1
        freq_out[i] = <uint16_t>scaled
        fsum += scaled

    delta = <int32_t>Z_T - fsum
    if delta == 0:
        return 0

    # We need an `order` array (only present symbols) sorted by
    # (-freq[i], i). The Python reference uses `sorted(...)` once.
    # Insertion-sort is fine here since the active alphabet is <= 256.
    if delta > 0:
        # Build present-symbols list.
        n = 0
        for i in range(256):
            if raw_count[i] > 0:
                order_buf[n] = i
                n += 1
        if n == 0:
            # Pathological: s > 0 ought to imply at least one nonzero.
            freq_out[0] = <uint16_t>Z_T
            return 0

        # Insertion sort by (-freq, sym ascending).
        for i in range(1, n):
            tmp_i = order_buf[i]
            tmp_f = <int32_t>freq_out[tmp_i]
            j = i - 1
            while j >= 0:
                if (<int32_t>freq_out[order_buf[j]] < tmp_f) or (
                    <int32_t>freq_out[order_buf[j]] == tmp_f
                    and order_buf[j] > tmp_i
                ):
                    order_buf[j + 1] = order_buf[j]
                    j -= 1
                else:
                    break
            order_buf[j + 1] = tmp_i

        k = 0
        while delta > 0:
            freq_out[order_buf[k % n]] = <uint16_t>(
                freq_out[order_buf[k % n]] + 1
            )
            k += 1
            delta -= 1
        return 0

    # delta < 0: decrement-largest loop.
    deficit = -delta
    while deficit > 0:
        best_i = -1
        best_v = -1
        for i in range(256):
            if freq_out[i] > 1 and <int32_t>freq_out[i] > best_v:
                best_v = <int32_t>freq_out[i]
                best_i = i
        if best_i < 0:
            return -1  # caller raises
        freq_out[best_i] = <uint16_t>(freq_out[best_i] - 1)
        deficit -= 1
    return 0


# ── Build the per-symbol context sequence (encoder pass 1) ──────────


cdef void _build_context_seq_c(
    const uint8_t* qualities, int32_t n_qualities,
    int32_t n_padded,
    const int32_t* read_lengths, int32_t n_reads,
    const int8_t* revcomp_flags,
    int32_t qbits, int32_t pbits, int32_t sloc,
    uint32_t* contexts_out,
) noexcept nogil:
    """Compute contexts[i] for i in [0, n_padded). Padding positions
    use ctx = m94z_context(0, 0, 0, ...).
    """
    cdef uint32_t pad_ctx = _z_context(0, 0, 0, qbits, pbits, sloc)
    cdef int32_t i, sym
    cdef int32_t read_idx = 0
    cdef int32_t pos_in_read = 0
    cdef int32_t cur_read_len = read_lengths[0] if n_reads > 0 else 0
    cdef uint32_t cur_revcomp = <uint32_t>(revcomp_flags[0]) if n_reads > 0 else 0
    cdef int32_t cumulative_read_end = cur_read_len
    cdef uint32_t prev_q = 0
    cdef int32_t shift = qbits // 3
    if shift < 1:
        shift = 1
    cdef uint32_t qmask_local = (<uint32_t>1 << qbits) - 1
    cdef uint32_t shift_mask = (<uint32_t>1 << shift) - 1
    cdef uint32_t pb

    for i in range(n_padded):
        if i < n_qualities:
            if i >= cumulative_read_end and read_idx < n_reads - 1:
                read_idx += 1
                pos_in_read = 0
                cur_read_len = read_lengths[read_idx]
                cur_revcomp = <uint32_t>(revcomp_flags[read_idx])
                cumulative_read_end += cur_read_len
                prev_q = 0
            pb = _z_pos_bucket(pos_in_read, cur_read_len, pbits)
            contexts_out[i] = _z_context(
                prev_q, pb, cur_revcomp & 1, qbits, pbits, sloc,
            )
            sym = <int32_t>qualities[i]
            prev_q = ((prev_q << shift) | (<uint32_t>sym & shift_mask)) & qmask_local
            pos_in_read += 1
        else:
            contexts_out[i] = pad_ctx


# ── Encoder full pipeline (pass 1 + pass 2 + lane reverse) ──────────


def encode_full_c(
    bytes qualities,
    list read_lengths,
    list revcomp_flags,
    int qbits,
    int pbits,
    int sloc,
):
    """Full M94.Z encode pipeline minus wire format pack.

    Returns:
        tuple ``(streams: list[bytes],
                 state_init: tuple[int,int,int,int],
                 state_final: tuple[int,int,int,int],
                 active_ctxs: list[int],   # sorted ascending
                 freq_arrays: list[bytes]) # 256 LE uint16 per active ctx``
    """
    cdef Py_ssize_t n = len(qualities)
    cdef int32_t n_qualities = <int32_t>n
    cdef int32_t pad_count = (-n_qualities) & 3
    cdef int32_t n_padded = n_qualities + pad_count
    cdef int32_t n_reads = <int32_t>len(read_lengths)
    cdef int32_t n_contexts = 1 << sloc
    cdef int32_t i, j, k, ctx
    cdef int32_t s_idx
    cdef int32_t sym
    cdef uint32_t state[4]
    cdef uint32_t x, x_max, f, c
    cdef const uint8_t* qbuf = <const uint8_t*>qualities
    cdef int32_t* rl_buf = NULL
    cdef int8_t* rf_buf = NULL
    cdef uint32_t* contexts = NULL
    cdef uint8_t* symbols = NULL
    cdef int32_t** ctx_counts = NULL
    cdef uint16_t** ctx_freq = NULL
    cdef uint32_t** ctx_cum = NULL
    cdef int32_t mem_err = 0
    cdef int32_t norm_err = 0
    cdef int32_t cap_per_stream
    cdef uint16_t* lane_chunks0 = NULL
    cdef uint16_t* lane_chunks1 = NULL
    cdef uint16_t* lane_chunks2 = NULL
    cdef uint16_t* lane_chunks3 = NULL
    cdef uint16_t* lane_chunks[4]
    cdef int32_t lane_n[4]
    cdef bytearray ba
    cdef uint8_t* bap
    cdef int32_t lane_idx
    cdef int32_t n_chunks
    cdef uint16_t chunk
    cdef bytearray fb
    cdef uint8_t* fbp

    # ── 1. Allocate per-read scratch ────────────────────────────────
    rl_buf = <int32_t*>malloc(
        (n_reads if n_reads > 0 else 1) * sizeof(int32_t)
    )
    rf_buf = <int8_t*>malloc(
        (n_reads if n_reads > 0 else 1) * sizeof(int8_t)
    )
    if rl_buf == NULL or rf_buf == NULL:
        if rl_buf != NULL: free(rl_buf)
        if rf_buf != NULL: free(rf_buf)
        raise MemoryError()
    for i in range(n_reads):
        rl_buf[i] = <int32_t>(<int>read_lengths[i])
        rf_buf[i] = <int8_t>(<int>revcomp_flags[i])

    # ── 2. Allocate the contexts array, walked symbol stream ────────
    contexts = <uint32_t*>malloc(
        (n_padded if n_padded > 0 else 1) * sizeof(uint32_t)
    )
    symbols = <uint8_t*>malloc(
        n_padded if n_padded > 0 else 1
    )
    if contexts == NULL or symbols == NULL:
        if contexts != NULL: free(contexts)
        if symbols != NULL: free(symbols)
        free(rl_buf); free(rf_buf)
        raise MemoryError()
    if n_padded > 0:
        memset(symbols, 0, n_padded)
    for i in range(n_qualities):
        symbols[i] = qbuf[i]

    # ── 3. Build context sequence ───────────────────────────────────
    _build_context_seq_c(
        qbuf, n_qualities, n_padded, rl_buf, n_reads, rf_buf,
        qbits, pbits, sloc, contexts,
    )

    # ── 4. Per-context tables: count[256] (int32), freq[256], cum[257]
    # We use parallel arrays indexed by ctx_id; allocate lazily.
    ctx_counts = <int32_t**>calloc(n_contexts, sizeof(int32_t*))
    ctx_freq = <uint16_t**>calloc(n_contexts, sizeof(uint16_t*))
    ctx_cum = <uint32_t**>calloc(n_contexts, sizeof(uint32_t*))
    if ctx_counts == NULL or ctx_freq == NULL or ctx_cum == NULL:
        if ctx_counts != NULL: free(ctx_counts)
        if ctx_freq != NULL: free(ctx_freq)
        if ctx_cum != NULL: free(ctx_cum)
        free(contexts); free(symbols); free(rl_buf); free(rf_buf)
        raise MemoryError()

    try:
        # Pass 1: gather counts.
        for i in range(n_padded):
            ctx = <int32_t>contexts[i]
            if ctx_counts[ctx] == NULL:
                ctx_counts[ctx] = <int32_t*>calloc(256, sizeof(int32_t))
                if ctx_counts[ctx] == NULL:
                    mem_err = 1
                    break
            ctx_counts[ctx][symbols[i]] += 1

        if mem_err:
            raise MemoryError()

        # Normalise each active context once.
        for ctx in range(n_contexts):
            if ctx_counts[ctx] == NULL:
                continue
            ctx_freq[ctx] = <uint16_t*>malloc(256 * sizeof(uint16_t))
            ctx_cum[ctx] = <uint32_t*>malloc(257 * sizeof(uint32_t))
            if ctx_freq[ctx] == NULL or ctx_cum[ctx] == NULL:
                mem_err = 1
                break
            if _normalise_to_total_c(ctx_counts[ctx], ctx_freq[ctx]) != 0:
                norm_err = 1
                break
            # Build cum[257].
            ctx_cum[ctx][0] = 0
            for k in range(256):
                ctx_cum[ctx][k + 1] = ctx_cum[ctx][k] + <uint32_t>ctx_freq[ctx][k]

        if mem_err:
            raise MemoryError()
        if norm_err:
            raise ValueError(
                "M94Z: normalise_to_total cannot reduce below floor=1"
            )

        # ── 5. Pass 2: rANS encode in reverse ────────────────────────
        # Scratch buffer per stream — generous upper bound: 2 bytes per
        # symbol max (each 16-bit chunk emit ≤ once per encode step,
        # plus a small safety margin).
        cap_per_stream = (n_padded // 4 + 16) * 2 + 32
        lane_chunks0 = <uint16_t*>malloc(cap_per_stream * sizeof(uint16_t))
        lane_chunks1 = <uint16_t*>malloc(cap_per_stream * sizeof(uint16_t))
        lane_chunks2 = <uint16_t*>malloc(cap_per_stream * sizeof(uint16_t))
        lane_chunks3 = <uint16_t*>malloc(cap_per_stream * sizeof(uint16_t))
        if (lane_chunks0 == NULL or lane_chunks1 == NULL
                or lane_chunks2 == NULL or lane_chunks3 == NULL):
            if lane_chunks0 != NULL: free(lane_chunks0)
            if lane_chunks1 != NULL: free(lane_chunks1)
            if lane_chunks2 != NULL: free(lane_chunks2)
            if lane_chunks3 != NULL: free(lane_chunks3)
            raise MemoryError()

        lane_chunks[0] = lane_chunks0
        lane_chunks[1] = lane_chunks1
        lane_chunks[2] = lane_chunks2
        lane_chunks[3] = lane_chunks3
        lane_n[0] = 0; lane_n[1] = 0; lane_n[2] = 0; lane_n[3] = 0

        state[0] = Z_L; state[1] = Z_L; state[2] = Z_L; state[3] = Z_L

        try:
            i = n_padded - 1
            while i >= 0:
                s_idx = i & 3
                ctx = <int32_t>contexts[i]
                sym = <int32_t>symbols[i]
                f = <uint32_t>ctx_freq[ctx][sym]
                c = ctx_cum[ctx][sym]
                # Note: spec's invariant guarantees pass 1 counted this
                # symbol, so freq>0. (Defensive check elided.)
                x = state[s_idx]
                x_max = Z_X_MAX_PREFACTOR * f
                while x >= x_max:
                    lane_chunks[s_idx][lane_n[s_idx]] = <uint16_t>(x & Z_B_MASK)
                    lane_n[s_idx] += 1
                    x = x >> Z_B_BITS
                # rANS encode step:  x' = (x // f) * T + (x % f) + c
                state[s_idx] = (x // f) * Z_T + (x % f) + c
                i -= 1

            # ── 6. Build the per-stream byte buffers ─────────────────
            # Each lane's chunks were appended LIFO; reverse and emit
            # as 16-bit LE pairs.
            stream_lanes_py = []
            for lane_idx in range(4):
                n_chunks = lane_n[lane_idx]
                ba = bytearray(2 * n_chunks)
                if n_chunks > 0:
                    bap = ba
                    for k in range(n_chunks):
                        # Reverse order: chunk at lane_chunks[k] goes to
                        # output position (n_chunks - 1 - k).
                        chunk = lane_chunks[lane_idx][k]
                        bap[2 * (n_chunks - 1 - k)]     = <uint8_t>(chunk & 0xFF)
                        bap[2 * (n_chunks - 1 - k) + 1] = <uint8_t>((chunk >> 8) & 0xFF)
                stream_lanes_py.append(bytes(ba))
        finally:
            free(lane_chunks0); free(lane_chunks1)
            free(lane_chunks2); free(lane_chunks3)

        state_init = (Z_L, Z_L, Z_L, Z_L)
        state_final = (
            <int>state[0], <int>state[1], <int>state[2], <int>state[3],
        )

        # ── 7. Build active_ctxs list and freq arrays ────────────────
        active_ctxs = []
        freq_arrays = []
        for ctx in range(n_contexts):
            if ctx_counts[ctx] == NULL:
                continue
            active_ctxs.append(<int>ctx)
            fb = bytearray(512)
            fbp = fb
            for k in range(256):
                fbp[2 * k]     = <uint8_t>(ctx_freq[ctx][k] & 0xFF)
                fbp[2 * k + 1] = <uint8_t>((ctx_freq[ctx][k] >> 8) & 0xFF)
            freq_arrays.append(bytes(fb))

        return (stream_lanes_py, state_init, state_final, active_ctxs, freq_arrays)

    finally:
        for ctx in range(n_contexts):
            if ctx_counts[ctx] != NULL:
                free(ctx_counts[ctx])
            if ctx_freq[ctx] != NULL:
                free(ctx_freq[ctx])
            if ctx_cum[ctx] != NULL:
                free(ctx_cum[ctx])
        free(ctx_counts); free(ctx_freq); free(ctx_cum)
        free(contexts); free(symbols)
        free(rl_buf); free(rf_buf)


# ── Decoder body (forward decode + context evolve inline) ────────────


cdef inline int32_t _find_symbol_for_slot_z(
    const uint32_t* cum_buf, uint32_t slot,
) noexcept nogil:
    """Find sym such that cum_buf[sym] <= slot < cum_buf[sym+1].
    Binary search over cum_buf[0..256] (monotonically non-decreasing).
    Mirrors :func:`_decode_one_step` in the Python reference.
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


def decode_body_c(
    list streams_py,
    tuple state_final,
    tuple state_init,
    int n_qualities,
    int n_padded,
    list read_lengths,
    list revcomp_flags,
    list active_ctxs,        # sorted ascending
    list freq_arrays,        # bytes per active ctx, 512 bytes (256 LE uint16)
    int qbits,
    int pbits,
    int sloc,
):
    """M94.Z body decode + context-evolve inline.

    Returns: bytes of length n_padded (caller truncates to n_qualities).
    """
    cdef int32_t n_reads = <int32_t>len(read_lengths)
    cdef int32_t n_active = <int32_t>len(active_ctxs)
    cdef int32_t n_contexts = 1 << sloc
    cdef int32_t i, k, ctx
    cdef int32_t sym
    cdef int32_t s_idx
    cdef uint32_t state[4]
    cdef uint32_t x, slot, f, c
    cdef int32_t init_states[4]
    cdef bytes stream0, stream1, stream2, stream3
    cdef const uint8_t* sb[4]
    cdef int32_t lens[4]
    cdef int32_t pos[4]
    cdef uint16_t** ctx_freq = NULL
    cdef uint32_t** ctx_cum = NULL
    cdef uint8_t* ctx_present = NULL
    cdef int32_t* rl_buf = NULL
    cdef int8_t* rf_buf = NULL
    cdef bytearray out
    cdef uint8_t* outp
    cdef int32_t read_idx = 0
    cdef int32_t pos_in_read = 0
    cdef int32_t cur_read_len = 0
    cdef uint32_t cur_revcomp = 0
    cdef int32_t cumulative_read_end = 0
    cdef uint32_t prev_q = 0
    cdef int32_t shift
    cdef uint32_t qmask_local
    cdef uint32_t shift_mask
    cdef uint32_t pad_ctx
    cdef uint32_t pb
    cdef int32_t mem_err = 0
    cdef bytes farr_bytes
    cdef const uint8_t* farr_p
    cdef uint16_t freq_val

    if len(streams_py) != 4:
        raise ValueError("M94Z: expected 4 substreams")

    # ── Materialise substream pointers ───────────────────────────────
    stream0 = streams_py[0]
    stream1 = streams_py[1]
    stream2 = streams_py[2]
    stream3 = streams_py[3]
    sb[0] = <const uint8_t*>stream0
    sb[1] = <const uint8_t*>stream1
    sb[2] = <const uint8_t*>stream2
    sb[3] = <const uint8_t*>stream3
    lens[0] = <int32_t>len(stream0)
    lens[1] = <int32_t>len(stream1)
    lens[2] = <int32_t>len(stream2)
    lens[3] = <int32_t>len(stream3)
    pos[0] = 0; pos[1] = 0; pos[2] = 0; pos[3] = 0

    state[0] = <uint32_t>state_final[0]
    state[1] = <uint32_t>state_final[1]
    state[2] = <uint32_t>state_final[2]
    state[3] = <uint32_t>state_final[3]
    init_states[0] = <int32_t>state_init[0]
    init_states[1] = <int32_t>state_init[1]
    init_states[2] = <int32_t>state_init[2]
    init_states[3] = <int32_t>state_init[3]

    # ── Allocate sparse freq/cum tables indexed by ctx_id ────────────
    ctx_freq = <uint16_t**>calloc(n_contexts, sizeof(uint16_t*))
    ctx_cum = <uint32_t**>calloc(n_contexts, sizeof(uint32_t*))
    ctx_present = <uint8_t*>calloc(n_contexts, 1)
    if ctx_freq == NULL or ctx_cum == NULL or ctx_present == NULL:
        if ctx_freq != NULL: free(ctx_freq)
        if ctx_cum != NULL: free(ctx_cum)
        if ctx_present != NULL: free(ctx_present)
        raise MemoryError()

    # ── Per-read scratch ────────────────────────────────────────────
    rl_buf = <int32_t*>malloc(
        (n_reads if n_reads > 0 else 1) * sizeof(int32_t)
    )
    rf_buf = <int8_t*>malloc(
        (n_reads if n_reads > 0 else 1) * sizeof(int8_t)
    )
    if rl_buf == NULL or rf_buf == NULL:
        if rl_buf != NULL: free(rl_buf)
        if rf_buf != NULL: free(rf_buf)
        free(ctx_freq); free(ctx_cum); free(ctx_present)
        raise MemoryError()
    for i in range(n_reads):
        rl_buf[i] = <int32_t>(<int>read_lengths[i])
        rf_buf[i] = <int8_t>(<int>revcomp_flags[i])

    out = bytearray(n_padded)
    outp = out

    # Context evolution state
    if n_reads > 0:
        cur_read_len = rl_buf[0]
        cur_revcomp = <uint32_t>(rf_buf[0])
        cumulative_read_end = cur_read_len
    shift = qbits // 3
    if shift < 1:
        shift = 1
    qmask_local = (<uint32_t>1 << qbits) - 1
    shift_mask = (<uint32_t>1 << shift) - 1
    pad_ctx = _z_context(0, 0, 0, qbits, pbits, sloc)

    try:
        # Materialise per-context freq/cum from active_ctxs + freq_arrays.
        for k in range(n_active):
            ctx = <int32_t>(<int>active_ctxs[k])
            if ctx < 0 or ctx >= n_contexts:
                raise ValueError(f"M94Z: ctx {ctx} out of range")
            ctx_freq[ctx] = <uint16_t*>malloc(256 * sizeof(uint16_t))
            ctx_cum[ctx] = <uint32_t*>malloc(257 * sizeof(uint32_t))
            if ctx_freq[ctx] == NULL or ctx_cum[ctx] == NULL:
                mem_err = 1
                break
            farr_bytes = freq_arrays[k]
            if len(farr_bytes) != 512:
                raise ValueError("M94Z: freq_array must be 512 bytes")
            farr_p = <const uint8_t*>farr_bytes
            ctx_cum[ctx][0] = 0
            for i in range(256):
                freq_val = <uint16_t>(
                    farr_p[2 * i] | (<uint16_t>farr_p[2 * i + 1] << 8)
                )
                ctx_freq[ctx][i] = freq_val
                ctx_cum[ctx][i + 1] = ctx_cum[ctx][i] + <uint32_t>freq_val
            ctx_present[ctx] = 1

        if mem_err:
            raise MemoryError()

        # Forward decode loop.
        for i in range(n_padded):
            s_idx = i & 3
            if i < n_qualities:
                if i >= cumulative_read_end and read_idx < n_reads - 1:
                    read_idx += 1
                    pos_in_read = 0
                    cur_read_len = rl_buf[read_idx]
                    cur_revcomp = <uint32_t>(rf_buf[read_idx])
                    cumulative_read_end += cur_read_len
                    prev_q = 0
                pb = _z_pos_bucket(pos_in_read, cur_read_len, pbits)
                ctx = <int32_t>_z_context(
                    prev_q, pb, cur_revcomp & 1, qbits, pbits, sloc,
                )
            else:
                ctx = <int32_t>pad_ctx

            if not ctx_present[ctx]:
                raise ValueError(
                    f"M94Z decoder: ctx {ctx} not in freq_tables (corrupt blob)"
                )

            x = state[s_idx]
            slot = x & Z_T_MASK
            sym = _find_symbol_for_slot_z(ctx_cum[ctx], slot)
            outp[i] = <uint8_t>sym
            f = <uint32_t>ctx_freq[ctx][sym]
            c = ctx_cum[ctx][sym]
            x = (x >> Z_T_BITS) * f + slot - c
            while x < Z_L:
                if pos[s_idx] + 1 >= lens[s_idx]:
                    if pos[s_idx] + 2 > lens[s_idx]:
                        raise ValueError(
                            f"M94Z: substream {s_idx} exhausted "
                            f"(pos={pos[s_idx]}, len={lens[s_idx]})"
                        )
                # Read 16-bit LE chunk.
                x = (x << Z_B_BITS) | (
                    <uint32_t>sb[s_idx][pos[s_idx]]
                    | (<uint32_t>sb[s_idx][pos[s_idx] + 1] << 8)
                )
                pos[s_idx] += 2
            state[s_idx] = x

            if i < n_qualities:
                prev_q = ((prev_q << shift) | (<uint32_t>sym & shift_mask)) & qmask_local
                pos_in_read += 1

        for k in range(4):
            if <int32_t>state[k] != init_states[k]:
                raise ValueError(
                    f"M94Z: post-decode state {state[k]} != "
                    f"state_init {init_states[k]} at substream {k}"
                )

        return bytes(out)
    finally:
        for ctx in range(n_contexts):
            if ctx_freq[ctx] != NULL:
                free(ctx_freq[ctx])
            if ctx_cum[ctx] != NULL:
                free(ctx_cum[ctx])
        free(ctx_freq); free(ctx_cum); free(ctx_present)
        free(rl_buf); free(rf_buf)
