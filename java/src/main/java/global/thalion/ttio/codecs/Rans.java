/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * rANS entropy codec — order-0 and order-1.
 *
 * <p>Clean-room implementation from Jarek Duda, "Asymmetric numeral
 * systems: entropy coding combining speed of Huffman coding with
 * compression rate of arithmetic coding", arXiv:1311.2540, 2014.
 * Public domain algorithm. No htslib (or other third-party rANS)
 * source code consulted.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.rans}</li>
 *   <li>Objective-C: {@code TTIORans}</li>
 * </ul>
 *
 * <p>Wire format (big-endian, self-contained):
 * <pre>
 *   Offset  Size   Field
 *   ──────  ─────  ─────────────────────────────
 *   0       1      order (0x00 or 0x01)
 *   1       4      original_length      (uint32 BE)
 *   5       4      payload_length       (uint32 BE)
 *   9       var    frequency_table
 *                    order-0: 256 × uint32 BE = 1024 bytes
 *                    order-1: for each context 0..255:
 *                               uint16 BE  n_nonzero
 *                               n_nonzero × (uint8 sym, uint16 BE freq)
 *   9+ft    var    payload (rANS encoded bytes)
 * </pre>
 *
 * <p>The payload itself is laid out as
 * <pre>
 *   [4 bytes: final encoder state, big-endian uint32]
 *   [renormalisation byte stream — read forward by the decoder]
 * </pre>
 *
 * <p>Algorithm parameters (Binding Decisions §75-§78): state width
 * 64-bit signed long (used as if 32-bit unsigned), L = 2^23,
 * b = 2^8, M = 2^12 = 4096, initial x = L, encode order = reverse,
 * initial ctx = 0.
 */
public final class Rans {

    // ── Algorithm constants ─────────────────────────────────────────

    /** Total of normalised frequency table. */
    private static final int M = 1 << 12; // 4096

    /** Bits to shift for modulo / divide by M. */
    private static final int M_BITS = 12;

    /** Lower bound of encoder state range. */
    private static final long L = 1L << 23;

    /** I/O width — encoder emits 8 bits at a time. */
    private static final int B_BITS = 8;

    /** Mask for {@code x % M}. */
    private static final int M_MASK = M - 1;

    /** Header bytes: 1 + 4 + 4. */
    private static final int HEADER_LEN = 9;

    /** Order-0 freq table size in bytes: 256 * 4. */
    private static final int FREQ_TABLE_O0_LEN = 1024;

    private Rans() {
        // Utility class — non-instantiable.
    }

    // ── Public API ──────────────────────────────────────────────────

    /**
     * Encode {@code data} using rANS with the given context order.
     *
     * @param data  input bytes (may be empty); {@code null} not allowed.
     * @param order 0 (marginal) or 1 (conditioned on previous byte).
     * @return self-contained encoded stream.
     * @throws IllegalArgumentException if {@code order} is not 0 or 1
     *         or {@code data} is null.
     */
    public static byte[] encode(byte[] data, int order) {
        if (data == null) {
            throw new IllegalArgumentException("rANS encode: data must not be null");
        }
        if (order != 0 && order != 1) {
            throw new IllegalArgumentException("rANS: unsupported order " + order);
        }

        byte[] payload;
        byte[] freqTable;

        if (order == 0) {
            int[] freq = new int[256];
            payload = encodeOrder0(data, freq);
            freqTable = serialiseFreqsO0(freq);
        } else {
            int[][] freqs = new int[256][256];
            payload = encodeOrder1(data, freqs);
            freqTable = serialiseFreqsO1(freqs);
        }

        byte[] out = new byte[HEADER_LEN + freqTable.length + payload.length];
        out[0] = (byte) order;
        writeUInt32BE(out, 1, data.length);
        writeUInt32BE(out, 5, payload.length);
        System.arraycopy(freqTable, 0, out, HEADER_LEN, freqTable.length);
        System.arraycopy(payload, 0, out, HEADER_LEN + freqTable.length, payload.length);
        return out;
    }

    /**
     * Decode a stream produced by {@link #encode}.
     *
     * @throws IllegalArgumentException on any malformed input.
     */
    public static byte[] decode(byte[] encoded) {
        if (encoded == null) {
            throw new IllegalArgumentException("rANS decode: input must not be null");
        }
        if (encoded.length < HEADER_LEN) {
            throw new IllegalArgumentException("rANS: stream shorter than header");
        }

        int order = Byte.toUnsignedInt(encoded[0]);
        if (order != 0 && order != 1) {
            throw new IllegalArgumentException("rANS: unsupported order byte " + order);
        }
        long origLenU = readUInt32BE(encoded, 1);
        long payloadLenU = readUInt32BE(encoded, 5);
        if (origLenU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("rANS: declared original length too large");
        }
        if (payloadLenU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("rANS: declared payload length too large");
        }
        int origLen = (int) origLenU;
        int payloadLen = (int) payloadLenU;

        int off = HEADER_LEN;
        if (order == 0) {
            int[] freq = new int[256];
            off = deserialiseFreqsO0(encoded, off, freq);

            if ((long) off + payloadLen != encoded.length) {
                throw new IllegalArgumentException(
                    "rANS: declared total length " + ((long) off + payloadLen)
                        + " != actual " + encoded.length);
            }
            return decodeOrder0(encoded, off, payloadLen, origLen, freq);
        } else {
            int[][] freqs = new int[256][256];
            off = deserialiseFreqsO1(encoded, off, freqs);

            if ((long) off + payloadLen != encoded.length) {
                throw new IllegalArgumentException(
                    "rANS: declared total length " + ((long) off + payloadLen)
                        + " != actual " + encoded.length);
            }
            return decodeOrder1(encoded, off, payloadLen, origLen, freqs);
        }
    }

    // ── Frequency normalisation ─────────────────────────────────────

    /**
     * Normalise a 256-element count vector to sum exactly to {@code M}.
     *
     * <p>Deterministic across languages (Binding Decision §78):
     * <ol>
     *   <li>Proportional scale {@code f[s] = max(1, cnt[s] * M / total)}
     *       when {@code cnt[s] > 0}, else 0.</li>
     *   <li>{@code delta = M - sum(f)}.</li>
     *   <li>If {@code delta > 0}: distribute +1 to symbols sorted by
     *       descending count, ascending symbol tiebreaker.</li>
     *   <li>If {@code delta < 0}: subtract 1 from symbols sorted by
     *       ascending count, ascending symbol tiebreaker, never below 1.</li>
     * </ol>
     *
     * <p>The cnt array is not modified. Allocates a fresh 256-element
     * result array per call. Hot callers should prefer
     * {@link #normaliseFreqsInto(int[], int[], int[])} with reusable
     * scratch buffers.
     */
    static int[] normaliseFreqs(int[] cnt) {
        int[] freq = new int[256];
        int[] order = new int[256];
        normaliseFreqsInto(cnt, freq, order);
        return freq;
    }

    /**
     * Scratch-buffer variant of {@link #normaliseFreqs}: writes the
     * normalised frequency table into {@code freqOut} (length 256) using
     * {@code orderScratch} (length ≥ 256) for the eligible-symbol sort
     * buffer. Both buffers are overwritten.
     *
     * <p>{@code freqOut} is zeroed by this method on entry, so callers
     * may reuse the same buffer across invocations without manual reset.
     *
     * <p>Byte-exact equivalent of the allocating overload — callable from
     * any codec (RANS_ORDER0/1, FQZCOMP_NX16_Z, NameTokenizer, etc.).
     */
    static void normaliseFreqsInto(int[] cnt, int[] freqOut, int[] orderScratch) {
        if (cnt.length != 256) {
            throw new IllegalArgumentException("count vector must have length 256");
        }
        if (freqOut.length != 256) {
            throw new IllegalArgumentException("freqOut must have length 256");
        }
        if (orderScratch.length < 256) {
            throw new IllegalArgumentException("orderScratch must have length >= 256");
        }

        // Single fused pass: sum, scale to freq, build eligible-symbol list.
        // Saves three 256-loops + a separate allocation versus the previous
        // implementation, and keeps cnt[s] in cache while we read it.
        long total = 0L;
        for (int s = 0; s < 256; s++) {
            total += cnt[s];
        }
        if (total <= 0L) {
            throw new IllegalArgumentException("cannot normalise empty count vector");
        }

        // Zero out freqOut so callers don't have to (they'd just memset).
        java.util.Arrays.fill(freqOut, 0);

        int sum = 0;
        int n = 0;
        for (int s = 0; s < 256; s++) {
            int c = cnt[s];
            if (c > 0) {
                long scaled = ((long) c * M) / total;
                int f = (scaled >= 1L) ? (int) scaled : 1;
                freqOut[s] = f;
                sum += f;
                orderScratch[n++] = s;
            }
        }
        int delta = M - sum;

        if (delta == 0) {
            return;  // Hot fast path: nothing to redistribute, skip sort.
        }

        // Pack (cnt, sym) into a single int per slot so the sort's inner
        // loop reads sequentially from one array (better cache behaviour
        // than chasing cnt[orderScratch[j]] random indirection per cmp).
        //
        //   - For delta > 0 we want sort key DESCENDING.
        //     Pack as ((cnt[s] << 8) | (255 - s)) so descending packed
        //     means descending cnt, then ascending s when cnts tie.
        //   - For delta < 0 we want ASCENDING (cnt, sym).
        //     Pack as ((cnt[s] << 8) | s).
        //
        // cnt[s] safely fits in 24 bits for any sane callsite (FqzcompNx16's
        // maxCount is 1024; rANS-O0/1 over 4 GiB inputs would overflow but
        // wire format constrains us long before then).
        for (int i = 0; i < n; i++) {
            int sym = orderScratch[i];
            int c = cnt[sym];
            orderScratch[i] = (delta > 0)
                ? ((c << 8) | (255 - sym))
                : ((c << 8) | sym);
        }

        if (delta > 0) {
            // Insertion sort: descending packed key.
            for (int i = 1; i < n; i++) {
                int kIns = orderScratch[i];
                int j = i - 1;
                while (j >= 0 && orderScratch[j] < kIns) {
                    orderScratch[j + 1] = orderScratch[j];
                    j--;
                }
                orderScratch[j + 1] = kIns;
            }
            // Distribute +1 round-robin in sorted order.
            int i = 0;
            while (delta > 0) {
                int packed = orderScratch[i % n];
                int sym = 255 - (packed & 0xFF);
                freqOut[sym]++;
                i++;
                delta--;
            }
        } else {
            // Insertion sort: ascending packed key.
            for (int i = 1; i < n; i++) {
                int kIns = orderScratch[i];
                int j = i - 1;
                while (j >= 0 && orderScratch[j] > kIns) {
                    orderScratch[j + 1] = orderScratch[j];
                    j--;
                }
                orderScratch[j + 1] = kIns;
            }
            // Subtract 1 round-robin in sorted order, skipping pinned-to-1.
            int idx = 0;
            int guard = 0;
            while (delta < 0) {
                int packed = orderScratch[idx % n];
                int sym = packed & 0xFF;
                if (freqOut[sym] > 1) {
                    freqOut[sym]--;
                    delta++;
                    guard = 0;
                } else {
                    guard++;
                    if (guard > n) {
                        throw new IllegalArgumentException(
                            "normalise: cannot reduce freq table below M; "
                                + "input alphabet too large for M=4096");
                    }
                }
                idx++;
            }
        }
    }

    private static int[] cumulative(int[] freq) {
        int[] cum = new int[257];
        int s = 0;
        for (int i = 0; i < 256; i++) {
            cum[i] = s;
            s += freq[i];
        }
        cum[256] = s;
        return cum;
    }

    private static int[] slotToSymbol(int[] freq) {
        int[] table = new int[M];
        int pos = 0;
        for (int s = 0; s < 256; s++) {
            int f = freq[s];
            for (int j = 0; j < f; j++) {
                table[pos + j] = s;
            }
            pos += f;
        }
        return table;
    }

    // ── Order-0 core ────────────────────────────────────────────────

    private static byte[] encodeOrder0(byte[] data, int[] freqOut) {
        if (data.length == 0) {
            // Flat default freq table — sums to exactly M (16 * 256).
            for (int s = 0; s < 256; s++) {
                freqOut[s] = M / 256;
            }
            byte[] payload = new byte[4];
            writeUInt32BE(payload, 0, (int) L);
            return payload;
        }

        int[] cnt = new int[256];
        for (byte b : data) {
            cnt[Byte.toUnsignedInt(b)]++;
        }
        int[] freq = normaliseFreqs(cnt);
        System.arraycopy(freq, 0, freqOut, 0, 256);
        int[] cum = cumulative(freq);

        // Pre-compute per-symbol renormalisation thresholds:
        // x_max[s] = (L >> M_BITS) << B_BITS) * freq[s]  ==  524288 * freq[s].
        long[] xMax = new long[256];
        long base = (L >>> M_BITS) << B_BITS; // 524288
        for (int s = 0; s < 256; s++) {
            xMax[s] = base * freq[s];
        }

        // Worst-case renorm bytes per symbol = 3 (state shrinks 24 bits to L).
        // Pre-allocate an upper-bound buffer to avoid reallocs.
        byte[] tmp = new byte[data.length * 3 + 16];
        int outLen = 0;
        long x = L;

        // Encode in REVERSE: last byte of input first.
        for (int i = data.length - 1; i >= 0; i--) {
            int s = Byte.toUnsignedInt(data[i]);
            int f = freq[s];
            int c = cum[s];
            long xm = xMax[s];
            // Renormalise BEFORE encoding (canonical rANS).
            while (x >= xm) {
                tmp[outLen++] = (byte) (x & 0xFFL);
                x >>>= 8;
            }
            // Encode the symbol.
            x = (x / f) * M + (x % f) + c;
        }

        // Write final state (4 BE bytes) followed by reversed renorm stream.
        byte[] payload = new byte[4 + outLen];
        writeUInt32BE(payload, 0, (int) x);
        for (int i = 0; i < outLen; i++) {
            payload[4 + i] = tmp[outLen - 1 - i];
        }
        return payload;
    }

    private static byte[] decodeOrder0(
        byte[] enc, int payloadOff, int payloadLen, int origLen, int[] freq) {
        if (origLen == 0) {
            return new byte[0];
        }
        if (payloadLen < 4) {
            throw new IllegalArgumentException("rANS: payload too short to contain bootstrap state");
        }
        // Validate freq table sums to M.
        int sum = 0;
        for (int f : freq) {
            sum += f;
        }
        if (sum != M) {
            throw new IllegalArgumentException(
                "rANS: order-0 freq table sum " + sum + " != M=" + M);
        }
        int[] cum = cumulative(freq);
        int[] symForSlot = slotToSymbol(freq);

        long x = readUInt32BE(enc, payloadOff);
        int pos = payloadOff + 4;
        int end = payloadOff + payloadLen;

        byte[] out = new byte[origLen];
        for (int i = 0; i < origLen; i++) {
            int slot = (int) (x & M_MASK);
            int s = symForSlot[slot];
            out[i] = (byte) s;
            int f = freq[s];
            int c = cum[s];
            x = (long) f * (x >>> M_BITS) + slot - c;
            while (x < L) {
                if (pos >= end) {
                    throw new IllegalArgumentException("rANS: unexpected end of payload");
                }
                x = (x << 8) | Byte.toUnsignedInt(enc[pos]);
                pos++;
            }
        }
        return out;
    }

    // ── Order-1 core ────────────────────────────────────────────────

    private static byte[] encodeOrder1(byte[] data, int[][] freqsOut) {
        if (data.length == 0) {
            // No transitions seen — every row is empty (already zero-init).
            byte[] payload = new byte[4];
            writeUInt32BE(payload, 0, (int) L);
            return payload;
        }

        // Build transition counts: tables[prev][cur].
        int[][] counts = new int[256][256];
        int prev = 0;
        for (byte b : data) {
            int cur = Byte.toUnsignedInt(b);
            counts[prev][cur]++;
            prev = cur;
        }

        // Normalise each non-empty row.
        for (int ctx = 0; ctx < 256; ctx++) {
            int rowSum = 0;
            for (int v : counts[ctx]) {
                rowSum += v;
            }
            if (rowSum > 0) {
                freqsOut[ctx] = normaliseFreqs(counts[ctx]);
            } else {
                freqsOut[ctx] = new int[256];
            }
        }

        // Pre-compute cumulative tables and renorm thresholds for non-empty rows.
        int[][] cums = new int[256][];
        long[][] xMaxes = new long[256][];
        long base = (L >>> M_BITS) << B_BITS; // 524288
        for (int ctx = 0; ctx < 256; ctx++) {
            int rowSum = 0;
            for (int v : freqsOut[ctx]) {
                rowSum += v;
            }
            if (rowSum == 0) {
                continue;
            }
            cums[ctx] = cumulative(freqsOut[ctx]);
            long[] xm = new long[256];
            for (int s = 0; s < 256; s++) {
                xm[s] = base * freqsOut[ctx][s];
            }
            xMaxes[ctx] = xm;
        }

        byte[] tmp = new byte[data.length * 3 + 16];
        int outLen = 0;
        long x = L;
        int n = data.length;

        // Encode in REVERSE.
        for (int i = n - 1; i >= 0; i--) {
            int s = Byte.toUnsignedInt(data[i]);
            int ctx = (i > 0) ? Byte.toUnsignedInt(data[i - 1]) : 0;
            int[] row = freqsOut[ctx];
            int f = row[s];
            if (f == 0) {
                throw new IllegalStateException(
                    "order-1 encode: zero freq for ctx=" + ctx + " sym=" + s);
            }
            int c = cums[ctx][s];
            long xm = xMaxes[ctx][s];
            while (x >= xm) {
                tmp[outLen++] = (byte) (x & 0xFFL);
                x >>>= 8;
            }
            x = (x / f) * M + (x % f) + c;
        }

        byte[] payload = new byte[4 + outLen];
        writeUInt32BE(payload, 0, (int) x);
        for (int i = 0; i < outLen; i++) {
            payload[4 + i] = tmp[outLen - 1 - i];
        }
        return payload;
    }

    private static byte[] decodeOrder1(
        byte[] enc, int payloadOff, int payloadLen, int origLen, int[][] freqs) {
        if (origLen == 0) {
            return new byte[0];
        }
        if (payloadLen < 4) {
            throw new IllegalArgumentException("rANS: payload too short to contain bootstrap state");
        }

        int[][] cums = new int[256][];
        int[][] slotTables = new int[256][];
        for (int ctx = 0; ctx < 256; ctx++) {
            int rowSum = 0;
            for (int v : freqs[ctx]) {
                rowSum += v;
            }
            if (rowSum > 0) {
                cums[ctx] = cumulative(freqs[ctx]);
                slotTables[ctx] = slotToSymbol(freqs[ctx]);
            }
        }

        long x = readUInt32BE(enc, payloadOff);
        int pos = payloadOff + 4;
        int end = payloadOff + payloadLen;

        byte[] out = new byte[origLen];
        int prev = 0;
        for (int i = 0; i < origLen; i++) {
            int[] slotTable = slotTables[prev];
            int[] cum = cums[prev];
            if (slotTable == null || cum == null) {
                throw new IllegalArgumentException(
                    "rANS: order-1 context " + prev + " has empty frequency table");
            }
            int slot = (int) (x & M_MASK);
            int s = slotTable[slot];
            out[i] = (byte) s;
            int f = freqs[prev][s];
            int c = cum[s];
            x = (long) f * (x >>> M_BITS) + slot - c;
            while (x < L) {
                if (pos >= end) {
                    throw new IllegalArgumentException("rANS: unexpected end of payload");
                }
                x = (x << 8) | Byte.toUnsignedInt(enc[pos]);
                pos++;
            }
            prev = s;
        }
        return out;
    }

    // ── Frequency table (de)serialisation ───────────────────────────

    private static byte[] serialiseFreqsO0(int[] freq) {
        ByteBuffer bb = ByteBuffer.allocate(FREQ_TABLE_O0_LEN).order(ByteOrder.BIG_ENDIAN);
        for (int s = 0; s < 256; s++) {
            bb.putInt(freq[s]);
        }
        return bb.array();
    }

    private static int deserialiseFreqsO0(byte[] buf, int off, int[] freqOut) {
        if (off + FREQ_TABLE_O0_LEN > buf.length) {
            throw new IllegalArgumentException("rANS: order-0 freq table truncated");
        }
        ByteBuffer bb = ByteBuffer.wrap(buf, off, FREQ_TABLE_O0_LEN).order(ByteOrder.BIG_ENDIAN);
        long sum = 0L;
        for (int s = 0; s < 256; s++) {
            int f = bb.getInt();
            if (f < 0) {
                throw new IllegalArgumentException("rANS: order-0 freq entry negative");
            }
            freqOut[s] = f;
            sum += f;
        }
        if (sum != M) {
            throw new IllegalArgumentException("rANS: order-0 freq table sum " + sum + " != M=" + M);
        }
        return off + FREQ_TABLE_O0_LEN;
    }

    private static byte[] serialiseFreqsO1(int[][] freqs) {
        // Compute total length: sum over ctx of (2 + n_nonzero[ctx] * 3).
        int total = 0;
        int[] nonzeroCounts = new int[256];
        for (int ctx = 0; ctx < 256; ctx++) {
            int nz = 0;
            for (int v : freqs[ctx]) {
                if (v > 0) {
                    nz++;
                }
            }
            nonzeroCounts[ctx] = nz;
            total += 2 + nz * 3;
        }
        ByteBuffer bb = ByteBuffer.allocate(total).order(ByteOrder.BIG_ENDIAN);
        for (int ctx = 0; ctx < 256; ctx++) {
            bb.putShort((short) nonzeroCounts[ctx]);
            int[] row = freqs[ctx];
            for (int s = 0; s < 256; s++) {
                int f = row[s];
                if (f > 0) {
                    bb.put((byte) s);
                    bb.putShort((short) f);
                }
            }
        }
        return bb.array();
    }

    private static int deserialiseFreqsO1(byte[] buf, int off, int[][] freqsOut) {
        int n = buf.length;
        for (int ctx = 0; ctx < 256; ctx++) {
            if (off + 2 > n) {
                throw new IllegalArgumentException("rANS: order-1 freq table truncated (count)");
            }
            int nNonzero = ((Byte.toUnsignedInt(buf[off]) << 8)
                | Byte.toUnsignedInt(buf[off + 1]));
            off += 2;
            if (nNonzero == 0) {
                continue;
            }
            int rowSum = 0;
            for (int j = 0; j < nNonzero; j++) {
                if (off + 3 > n) {
                    throw new IllegalArgumentException("rANS: order-1 freq table truncated (entry)");
                }
                int s = Byte.toUnsignedInt(buf[off]);
                int f = ((Byte.toUnsignedInt(buf[off + 1]) << 8)
                    | Byte.toUnsignedInt(buf[off + 2]));
                if (f == 0) {
                    throw new IllegalArgumentException("rANS: order-1 nonzero entry has freq 0");
                }
                freqsOut[ctx][s] = f;
                rowSum += f;
                off += 3;
            }
            if (rowSum != M) {
                throw new IllegalArgumentException(
                    "rANS: order-1 row " + ctx + " sums to " + rowSum + " != M=" + M);
            }
        }
        return off;
    }

    // ── Big-endian helpers ──────────────────────────────────────────

    private static void writeUInt32BE(byte[] buf, int off, int val) {
        buf[off]     = (byte) ((val >>> 24) & 0xFF);
        buf[off + 1] = (byte) ((val >>> 16) & 0xFF);
        buf[off + 2] = (byte) ((val >>> 8) & 0xFF);
        buf[off + 3] = (byte) (val & 0xFF);
    }

    private static long readUInt32BE(byte[] buf, int off) {
        return ((long) Byte.toUnsignedInt(buf[off])     << 24)
             | ((long) Byte.toUnsignedInt(buf[off + 1]) << 16)
             | ((long) Byte.toUnsignedInt(buf[off + 2]) << 8)
             | ((long) Byte.toUnsignedInt(buf[off + 3]));
    }
}
