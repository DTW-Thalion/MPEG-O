# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False
"""TTI-O M93 — REF_DIFF Cython accelerator.

C-accelerated kernels for the four hot REF_DIFF functions identified in
the chr22 profile (`docs/benchmarks/m94z-pipeline-profile.md`):

  * ``walk_read_against_reference_c`` — CIGAR-walk an aligned read.
  * ``pack_read_diff_bitstream_c``    — pack the walk result to bytes.
  * ``walk_and_pack_c``               — fused walk+pack (encoder hot path).
  * ``unpack_and_reconstruct_c``      — fused unpack+reconstruct (decode hot path).

Output is byte-identical to the pure-Python reference at
:mod:`ttio.codecs.ref_diff`. The wrapper module routes hot calls through
this extension when present and silently falls back to pure Python
otherwise.

The fused encode/decode entry points avoid materialising the intermediate
``ReadWalkResult.m_op_flag_bits`` Python list (1.7M reads × ~100 flags
each on chr22 = 170M list slots), which is where most of the wall time
went on the profile baseline.
"""
from libc.stdint cimport uint8_t, uint32_t, int32_t, int64_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy, memset


# ── CIGAR scanner constants (op-letter byte values) ─────────────────
# 'M'=77, 'I'=73, 'D'=68, 'N'=78, 'S'=83, 'H'=72, 'P'=80, 'X'=88, '='=61


# ── Walk-only kernel (returns ReadWalkResult-shaped tuple) ──────────


def walk_read_against_reference_c(
    bytes sequence,
    str cigar,
    int position,
    bytes reference_chrom_seq,
):
    """C-accelerated walk_read_against_reference.

    Returns a 4-tuple ``(m_op_flag_bits_list, sub_bytes, ins_bytes, soft_bytes)``.
    The Python wrapper assembles a ``ReadWalkResult`` from this tuple.
    """
    if cigar == "*" or cigar == "":
        raise ValueError(
            "REF_DIFF cannot encode unmapped reads (cigar='*' or empty); "
            "route through BASE_PACK on a separate sub-channel"
        )

    cdef bytes cigar_bytes = cigar.encode("ascii")
    cdef const uint8_t* cig = <const uint8_t*>cigar_bytes
    cdef Py_ssize_t cig_len = len(cigar_bytes)
    cdef const uint8_t* seqp = <const uint8_t*>sequence
    cdef const uint8_t* refp = <const uint8_t*>reference_chrom_seq

    cdef Py_ssize_t seq_i = 0
    cdef Py_ssize_t ref_i = position - 1

    cdef bytearray sub_buf = bytearray()
    cdef bytearray ins_buf = bytearray()
    cdef bytearray soft_buf = bytearray()

    flag_list = []  # Python list of ints (0/1)

    cdef Py_ssize_t i = 0
    cdef int32_t length
    cdef uint8_t op
    cdef Py_ssize_t k
    cdef uint8_t read_base, ref_base

    while i < cig_len:
        length = 0
        if cig[i] < 48 or cig[i] > 57:
            raise ValueError(f"unsupported CIGAR op: {chr(cig[i])!r}")
        while i < cig_len and cig[i] >= 48 and cig[i] <= 57:
            length = length * 10 + (cig[i] - 48)
            i += 1
        if i >= cig_len:
            raise ValueError("CIGAR ended in digits without an op letter")
        op = cig[i]
        i += 1

        if op == 77 or op == 61 or op == 88:  # M / = / X
            for k in range(length):
                read_base = seqp[seq_i + k]
                ref_base = refp[ref_i + k]
                if read_base == ref_base:
                    flag_list.append(0)
                else:
                    flag_list.append(1)
                    sub_buf.append(read_base)
            seq_i += length
            ref_i += length
        elif op == 73:  # I
            for k in range(length):
                ins_buf.append(seqp[seq_i + k])
            seq_i += length
        elif op == 83:  # S
            for k in range(length):
                soft_buf.append(seqp[seq_i + k])
            seq_i += length
        elif op == 68 or op == 78:  # D / N
            ref_i += length
        elif op == 72 or op == 80:  # H / P
            pass
        else:
            raise ValueError(f"unsupported CIGAR op: {chr(op)!r}")

    return (
        flag_list,
        bytes(sub_buf),
        bytes(ins_buf),
        bytes(soft_buf),
    )


# ── Pack-only kernel (takes walk result components, returns bytes) ──


def pack_read_diff_bitstream_c(
    object m_op_flag_bits,
    bytes substitution_bases,
    bytes insertion_bases,
    bytes softclip_bases,
):
    """C-accelerated pack_read_diff_bitstream.

    Layout per spec §3 M93 (matches the pure-Python ref byte-for-byte):
      1. Bit-packed sequence: for each M-op flag bit, append the bit
         (MSB-first within each byte). After a ``1`` flag, append the
         corresponding substitution byte's 8 bits MSB-first.
      2. Pad to byte boundary with zeros.
      3. Then I-op bases verbatim, then S-op bases verbatim.
    """
    cdef Py_ssize_t n_flags = len(m_op_flag_bits)
    cdef Py_ssize_t n_subs = len(substitution_bases)
    cdef const uint8_t* sub_p = <const uint8_t*>substitution_bases
    cdef const uint8_t* ins_p = <const uint8_t*>insertion_bases
    cdef const uint8_t* soft_p = <const uint8_t*>softclip_bases
    cdef Py_ssize_t ins_n = len(insertion_bases)
    cdef Py_ssize_t soft_n = len(softclip_bases)

    # Worst-case bits = n_flags + 8*n_subs.
    cdef Py_ssize_t max_bits = n_flags + 8 * n_subs
    cdef Py_ssize_t bit_section_bytes = (max_bits + 7) >> 3
    cdef Py_ssize_t total_cap = bit_section_bytes + ins_n + soft_n
    cdef bytearray out = bytearray(total_cap)
    cdef uint8_t* outp = out

    cdef Py_ssize_t bit_pos = 0
    cdef Py_ssize_t byte_idx
    cdef int32_t bit_off
    cdef int32_t shift
    cdef Py_ssize_t i, j
    cdef int flag
    cdef uint8_t sub_byte
    cdef Py_ssize_t sub_cursor = 0
    cdef Py_ssize_t actual_bit_bytes
    cdef bytearray new_out
    cdef uint8_t* newp

    for i in range(n_flags):
        flag = <int>m_op_flag_bits[i]
        if flag:
            byte_idx = bit_pos >> 3
            bit_off = <int32_t>(bit_pos & 7)
            outp[byte_idx] |= <uint8_t>(1 << (7 - bit_off))
        bit_pos += 1
        if flag:
            sub_byte = sub_p[sub_cursor]
            sub_cursor += 1
            for j in range(8):
                shift = 7 - <int32_t>j
                if (sub_byte >> shift) & 1:
                    byte_idx = bit_pos >> 3
                    bit_off = <int32_t>(bit_pos & 7)
                    outp[byte_idx] |= <uint8_t>(1 << (7 - bit_off))
                bit_pos += 1

    actual_bit_bytes = (bit_pos + 7) >> 3

    # Move ins/soft into place after the actual bit section.
    if actual_bit_bytes != bit_section_bytes:
        # Re-pack: the bit section ended up shorter than worst case.
        new_out = bytearray(actual_bit_bytes + ins_n + soft_n)
        newp = new_out
        memcpy(newp, outp, actual_bit_bytes)
        if ins_n > 0:
            memcpy(newp + actual_bit_bytes, ins_p, ins_n)
        if soft_n > 0:
            memcpy(newp + actual_bit_bytes + ins_n, soft_p, soft_n)
        return bytes(new_out)
    else:
        if ins_n > 0:
            memcpy(outp + actual_bit_bytes, ins_p, ins_n)
        if soft_n > 0:
            memcpy(outp + actual_bit_bytes + ins_n, soft_p, soft_n)
        return bytes(out)


# ── Fused walk + pack (encoder hot path) ────────────────────────────


def walk_and_pack_c(
    bytes sequence,
    str cigar,
    int position,
    bytes reference_chrom_seq,
):
    """Fused walk + pack — produces the per-read wire bytes directly.

    Equivalent to ``pack_read_diff_bitstream(walk_read_against_reference(
    sequence, cigar, position, reference_chrom_seq))`` byte-for-byte,
    without materialising the intermediate ``m_op_flag_bits`` Python list.
    """
    if cigar == "*" or cigar == "":
        raise ValueError(
            "REF_DIFF cannot encode unmapped reads (cigar='*' or empty); "
            "route through BASE_PACK on a separate sub-channel"
        )

    cdef bytes cigar_bytes = cigar.encode("ascii")
    cdef const uint8_t* cig = <const uint8_t*>cigar_bytes
    cdef Py_ssize_t cig_len = len(cigar_bytes)
    cdef const uint8_t* seqp = <const uint8_t*>sequence
    cdef Py_ssize_t seq_n = len(sequence)
    cdef const uint8_t* refp = <const uint8_t*>reference_chrom_seq

    cdef Py_ssize_t seq_i = 0
    cdef Py_ssize_t ref_i = position - 1

    # Worst-case bit-section bytes: ⌈9*seq_n/8⌉.
    cdef Py_ssize_t bit_buf_max = (9 * seq_n + 7) >> 3
    if bit_buf_max < 1:
        bit_buf_max = 1
    cdef uint8_t* buf = <uint8_t*>malloc(bit_buf_max)
    cdef uint8_t* ins_tmp = <uint8_t*>malloc(seq_n + 1)
    cdef uint8_t* soft_tmp = <uint8_t*>malloc(seq_n + 1)
    if buf == NULL or ins_tmp == NULL or soft_tmp == NULL:
        if buf != NULL: free(buf)
        if ins_tmp != NULL: free(ins_tmp)
        if soft_tmp != NULL: free(soft_tmp)
        raise MemoryError()
    memset(buf, 0, bit_buf_max)

    cdef Py_ssize_t bit_pos = 0
    cdef Py_ssize_t ins_n = 0, soft_n = 0
    cdef Py_ssize_t i = 0
    cdef int32_t length
    cdef uint8_t op
    cdef Py_ssize_t kk
    cdef Py_ssize_t byte_idx
    cdef int32_t bit_off
    cdef int32_t jj
    cdef uint8_t read_base, ref_base, sub_byte
    cdef Py_ssize_t actual_bit_bytes
    cdef bytearray result
    cdef uint8_t* rp

    try:
        while i < cig_len:
            length = 0
            if cig[i] < 48 or cig[i] > 57:
                raise ValueError(f"unsupported CIGAR op: {chr(cig[i])!r}")
            while i < cig_len and cig[i] >= 48 and cig[i] <= 57:
                length = length * 10 + (cig[i] - 48)
                i += 1
            if i >= cig_len:
                raise ValueError("CIGAR ended in digits without an op letter")
            op = cig[i]
            i += 1

            if op == 77 or op == 61 or op == 88:  # M = X
                for kk in range(length):
                    read_base = seqp[seq_i + kk]
                    ref_base = refp[ref_i + kk]
                    if read_base == ref_base:
                        bit_pos += 1
                    else:
                        byte_idx = bit_pos >> 3
                        bit_off = <int32_t>(bit_pos & 7)
                        buf[byte_idx] |= <uint8_t>(1 << (7 - bit_off))
                        bit_pos += 1
                        sub_byte = read_base
                        for jj in range(8):
                            if (sub_byte >> (7 - jj)) & 1:
                                byte_idx = bit_pos >> 3
                                bit_off = <int32_t>(bit_pos & 7)
                                buf[byte_idx] |= <uint8_t>(1 << (7 - bit_off))
                            bit_pos += 1
                seq_i += length
                ref_i += length
            elif op == 73:  # I
                for kk in range(length):
                    ins_tmp[ins_n] = seqp[seq_i + kk]
                    ins_n += 1
                seq_i += length
            elif op == 83:  # S
                for kk in range(length):
                    soft_tmp[soft_n] = seqp[seq_i + kk]
                    soft_n += 1
                seq_i += length
            elif op == 68 or op == 78:  # D / N
                ref_i += length
            elif op == 72 or op == 80:  # H / P
                pass
            else:
                raise ValueError(f"unsupported CIGAR op: {chr(op)!r}")

        actual_bit_bytes = (bit_pos + 7) >> 3

        # Build single output bytearray of the right size.
        result = bytearray(actual_bit_bytes + ins_n + soft_n)
        rp = result
        if actual_bit_bytes > 0:
            memcpy(rp, buf, actual_bit_bytes)
        if ins_n > 0:
            memcpy(rp + actual_bit_bytes, ins_tmp, ins_n)
        if soft_n > 0:
            memcpy(rp + actual_bit_bytes + ins_n, soft_tmp, soft_n)
        return bytes(result)
    finally:
        free(buf)
        free(ins_tmp)
        free(soft_tmp)


# ── Fused unpack + reconstruct (decoder hot path) ───────────────────


def unpack_and_reconstruct_c(
    bytes blob,
    Py_ssize_t blob_off,
    int num_m_ops,
    int ins_length,
    int softclip_length,
    str cigar,
    int position,
    bytes reference_chrom_seq,
):
    """Fused unpack + reconstruct — produces the read sequence directly.

    Args:
        blob: full slice raw byte stream.
        blob_off: offset within ``blob`` where this read's bytes begin.
        num_m_ops: M-op count (recovered from CIGAR by caller).
        ins_length: I-op total (recovered from CIGAR by caller).
        softclip_length: S-op total (recovered from CIGAR by caller).
        cigar: this read's CIGAR string.
        position: 1-based reference position.
        reference_chrom_seq: full reference chromosome sequence.

    Returns:
        ``(read_sequence: bytes, total_consumed: int)``.

    Approach: pre-walk the bit section of `blob` to extract the M-op
    flags and substitution bytes into temp arrays. Then walk the CIGAR
    once to assemble the output, drawing from refp / sub_tmp / ins_p /
    soft_p as appropriate. Mirrors the pure-Python ref's two-step
    `(walk, reconstruct)` flow but without Python list overhead.
    """
    if cigar == "*" or cigar == "":
        raise ValueError("cannot reconstruct unmapped read")

    cdef bytes cigar_bytes = cigar.encode("ascii")
    cdef const uint8_t* cig = <const uint8_t*>cigar_bytes
    cdef Py_ssize_t cig_len = len(cigar_bytes)
    cdef const uint8_t* blobp = <const uint8_t*>blob
    cdef const uint8_t* refp = <const uint8_t*>reference_chrom_seq

    # ── Pass A: extract flag bits + substitution bytes from blob ──────
    cdef uint8_t* flags_tmp = <uint8_t*>malloc(num_m_ops if num_m_ops > 0 else 1)
    cdef uint8_t* sub_tmp = <uint8_t*>malloc(num_m_ops if num_m_ops > 0 else 1)
    if flags_tmp == NULL or sub_tmp == NULL:
        if flags_tmp != NULL: free(flags_tmp)
        if sub_tmp != NULL: free(sub_tmp)
        raise MemoryError()

    cdef Py_ssize_t bit_cursor = 0
    cdef Py_ssize_t byte_idx
    cdef int32_t bit_off
    cdef Py_ssize_t k
    cdef uint8_t flag, sub_byte, bit_val
    cdef Py_ssize_t jj
    cdef Py_ssize_t sub_count = 0

    cdef Py_ssize_t out_n = 0  # output read length (M+I+S total)
    cdef Py_ssize_t i = 0
    cdef int32_t length = 0
    cdef uint8_t op
    cdef Py_ssize_t bit_section_bytes
    cdef Py_ssize_t ins_start
    cdef Py_ssize_t soft_start
    cdef Py_ssize_t total_consumed
    cdef bytearray out
    cdef uint8_t* outp
    cdef Py_ssize_t flag_i = 0
    cdef Py_ssize_t sub_i = 0
    cdef Py_ssize_t ins_i = 0
    cdef Py_ssize_t soft_i = 0
    cdef Py_ssize_t out_cursor = 0
    cdef Py_ssize_t ref_i

    try:
        for k in range(num_m_ops):
            byte_idx = blob_off + (bit_cursor >> 3)
            bit_off = <int32_t>(bit_cursor & 7)
            flag = (blobp[byte_idx] >> (7 - bit_off)) & 1
            flags_tmp[k] = flag
            bit_cursor += 1
            if flag == 1:
                sub_byte = 0
                for jj in range(8):
                    byte_idx = blob_off + (bit_cursor >> 3)
                    bit_off = <int32_t>(bit_cursor & 7)
                    bit_val = (blobp[byte_idx] >> (7 - bit_off)) & 1
                    sub_byte = (sub_byte << 1) | bit_val
                    bit_cursor += 1
                sub_tmp[sub_count] = sub_byte
                sub_count += 1

        bit_section_bytes = (bit_cursor + 7) >> 3
        ins_start = blob_off + bit_section_bytes
        soft_start = ins_start + ins_length
        total_consumed = bit_section_bytes + ins_length + softclip_length

        # ── Pass B: compute output length ─────────────────────────────
        i = 0
        out_n = 0
        while i < cig_len:
            length = 0
            if cig[i] < 48 or cig[i] > 57:
                raise ValueError(f"unsupported CIGAR op: {chr(cig[i])!r}")
            while i < cig_len and cig[i] >= 48 and cig[i] <= 57:
                length = length * 10 + (cig[i] - 48)
                i += 1
            if i >= cig_len:
                raise ValueError("CIGAR ended in digits without an op letter")
            op = cig[i]
            i += 1
            if op == 77 or op == 61 or op == 88 or op == 73 or op == 83:
                out_n += length
            elif op == 68 or op == 78 or op == 72 or op == 80:
                pass
            else:
                raise ValueError(f"unsupported CIGAR op: {chr(op)!r}")

        out = bytearray(out_n)
        outp = out

        # ── Pass C: assemble output by walking CIGAR ──────────────────
        flag_i = 0
        sub_i = 0
        ins_i = 0
        soft_i = 0
        out_cursor = 0
        ref_i = position - 1

        i = 0
        while i < cig_len:
            length = 0
            while i < cig_len and cig[i] >= 48 and cig[i] <= 57:
                length = length * 10 + (cig[i] - 48)
                i += 1
            op = cig[i]
            i += 1
            if op == 77 or op == 61 or op == 88:  # M = X
                for k in range(length):
                    if flags_tmp[flag_i] == 0:
                        outp[out_cursor + k] = refp[ref_i + k]
                    else:
                        outp[out_cursor + k] = sub_tmp[sub_i]
                        sub_i += 1
                    flag_i += 1
                out_cursor += length
                ref_i += length
            elif op == 73:  # I
                for k in range(length):
                    outp[out_cursor + k] = blobp[ins_start + ins_i + k]
                out_cursor += length
                ins_i += length
            elif op == 83:  # S
                for k in range(length):
                    outp[out_cursor + k] = blobp[soft_start + soft_i + k]
                out_cursor += length
                soft_i += length
            elif op == 68 or op == 78:  # D / N
                ref_i += length
            elif op == 72 or op == 80:  # H / P
                pass

        return (bytes(out), <int>total_consumed)
    finally:
        free(flags_tmp)
        free(sub_tmp)
