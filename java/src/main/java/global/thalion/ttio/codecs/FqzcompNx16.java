/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * FQZCOMP_NX16 — lossless quality codec (M94 v1.2).
 *
 * <p>Clean-room Java port of the Python reference implementation
 * ({@code python/src/ttio/codecs/fqzcomp_nx16.py}). Wire format and
 * algorithm documented in
 * {@code docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md}
 * §3 (M94) and {@code docs/codecs/fqzcomp_nx16.md}. Codec id is
 * {@link global.thalion.ttio.Enums.Compression#FQZCOMP_NX16} = 10.
 *
 * <p>Algorithm: 4-way interleaved rANS over per-context adaptive
 * frequency tables. Each Phred byte's context vector is
 * {@code (prev_q[0], prev_q[1], prev_q[2], pos_bucket, revcomp_flag,
 * len_bucket)} hashed into a 12-bit context index via SplitMix64.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.fqzcomp_nx16}</li>
 *   <li>Objective-C: {@code TTIOFqzcompNx16}</li>
 * </ul>
 */
public final class FqzcompNx16 {

    // ── Wire-format constants ───────────────────────────────────────

    /** Magic prefix on every FQZCOMP_NX16 stream. */
    public static final byte[] MAGIC = new byte[]{'F', 'Q', 'Z', 'N'};

    /** Codec wire-format version. */
    public static final int VERSION = 1;

    /** Header fixed prefix:
     *  magic(4) + version(1) + flags(1) + num_qualities(8)
     *  + num_reads(4) + rlt_compressed_len(4) = 22 bytes. */
    public static final int HEADER_FIXED_PREFIX = 22;

    /** context_model_params(16) + state_init[4](16) = 32 bytes. */
    public static final int HEADER_TRAILING_FIXED = 32;

    /** Size of context_model_params block in bytes. */
    public static final int CONTEXT_MODEL_PARAMS_SIZE = 16;

    /** Trailer = state_final[4] (4 × uint32 LE). */
    public static final int TRAILER_SIZE = 16;

    // ── Algorithm constants ─────────────────────────────────────────

    /** 4096 contexts (12 bits). */
    public static final int DEFAULT_CONTEXT_TABLE_SIZE_LOG2 = 12;

    /** Adaptive count step per symbol. */
    public static final int DEFAULT_LEARNING_RATE = 16;

    /** Trigger halve-with-floor-1 renorm above this count. */
    public static final int DEFAULT_MAX_COUNT = 4096;

    /** Default freq table init (0 = uniform). */
    public static final int DEFAULT_FREQ_TABLE_INIT = 0;

    /** SplitMix64 seed. */
    public static final long DEFAULT_CONTEXT_HASH_SEED = 0xC0FFEEL;

    /** Number of rANS substreams (round-robin). */
    public static final int NUM_STREAMS = 4;

    /** rANS lower-state bound (matches {@link Rans#L}). */
    public static final long RANS_L = 1L << 23;

    /** rANS modulus exponent (matches {@link Rans} M_BITS). */
    public static final int RANS_M_BITS = 12;

    /** rANS modulus = 1 << M_BITS = 4096. */
    public static final int RANS_M = 1 << RANS_M_BITS;

    /** Mask for {@code x % M}. */
    public static final int RANS_M_MASK = RANS_M - 1;

    /** Bytes emitted per renorm step. */
    public static final int RANS_B_BITS = 8;

    /** Length-bucket boundaries (3 bits, 0..7). */
    private static final int[] LENGTH_BUCKET_BOUNDS = {
        50, 100, 150, 200, 300, 1000, 10000
    };

    private FqzcompNx16() {
        // Utility class — non-instantiable.
    }

    // ── Records ──────────────────────────────────────────────────────

    /** 16-byte per-codec parameter block (uint8 size + uint8 lr +
     *  uint16 max_count + uint8 ftInit + uint32 seed + 7 bytes reserved). */
    public record ContextModelParams(
        int contextTableSizeLog2,
        int learningRate,
        int maxCount,
        int freqTableInit,
        long contextHashSeed
    ) {
        public static ContextModelParams defaults() {
            return new ContextModelParams(
                DEFAULT_CONTEXT_TABLE_SIZE_LOG2,
                DEFAULT_LEARNING_RATE,
                DEFAULT_MAX_COUNT,
                DEFAULT_FREQ_TABLE_INIT,
                DEFAULT_CONTEXT_HASH_SEED);
        }
    }

    /** FQZCOMP_NX16 wire-format header (54 + L bytes total). */
    public record CodecHeader(
        int flags,
        long numQualities,
        int numReads,
        int rltCompressedLen,
        byte[] readLengthTable,
        ContextModelParams params,
        long[] stateInit
    ) {
        public CodecHeader {
            if (readLengthTable == null
                || readLengthTable.length != rltCompressedLen) {
                throw new IllegalArgumentException(
                    "rltCompressedLen (" + rltCompressedLen
                    + ") != len(readLengthTable) ("
                    + (readLengthTable == null ? "null"
                        : readLengthTable.length) + ")");
            }
            if (stateInit == null || stateInit.length != NUM_STREAMS) {
                throw new IllegalArgumentException(
                    "stateInit must be a uint32[" + NUM_STREAMS
                    + "], got "
                    + (stateInit == null ? "null" : stateInit.length));
            }
        }
    }

    /** Result returned from {@link #decode}: decoded qualities + the
     *  {@code read_lengths} array carried in the header sidecar +
     *  the {@code revcomp_flags} the caller supplied (or all-zero). */
    public record DecodeResult(
        byte[] qualities,
        int[] readLengths,
        int[] revcompFlags
    ) { }

    /** Result of {@link #unpackCodecHeader}: header + total bytes consumed. */
    public record HeaderUnpack(CodecHeader header, int bytesConsumed) { }

    // ── Context bucketing ───────────────────────────────────────────

    /** 4-bit bucket of position-within-read, 0..15. */
    public static int positionBucket(int position, int readLength) {
        if (readLength <= 0) return 0;
        if (position <= 0) return 0;
        if (position >= readLength) return 15;
        return Math.min(15, (position * 16) / readLength);
    }

    /** 3-bit bucket of read length, 0..7. */
    public static int lengthBucket(int readLength) {
        if (readLength <= 0) return 0;
        for (int i = 0; i < LENGTH_BUCKET_BOUNDS.length; i++) {
            if (readLength < LENGTH_BUCKET_BOUNDS[i]) return i;
        }
        return 7;
    }

    /** SplitMix64-finalised hash of a context vector to {@code [0, 1<<tableSizeLog2)}.
     *
     *  <p><b>Cross-language byte-exact contract.</b> Java uses {@code long}
     *  multiplication, which naturally wraps modulo 2^64. The {@code >>>}
     *  operator is unsigned right shift. */
    public static int fqznContextHash(
            int prevQ0, int prevQ1, int prevQ2,
            int posBucket, int revcomp, int lenBucket,
            long seed, int tableSizeLog2) {
        long key = (prevQ0 & 0xFFL);
        key |= (prevQ1 & 0xFFL) << 8;
        key |= (prevQ2 & 0xFFL) << 16;
        key |= ((long) (posBucket & 0xF)) << 24;
        key |= ((long) (revcomp & 0x1)) << 28;
        key |= ((long) (lenBucket & 0x7)) << 29;
        key |= (seed & 0xFFFFFFFFL) << 32;

        key ^= key >>> 33;
        key *= 0xff51afd7ed558ccdL;   // wraps mod 2^64 in long arithmetic
        key ^= key >>> 33;
        key *= 0xc4ceb9fe1a85ec53L;
        key ^= key >>> 33;

        return (int) (key & ((1L << tableSizeLog2) - 1L));
    }

    // ── Adaptive count update ───────────────────────────────────────

    private static int[] newCountTable() {
        int[] c = new int[256];
        Arrays.fill(c, 1);
        return c;
    }

    /** Allocate sorted_desc[256] = [0, 1, ..., 255] (the descending-count
     *  ordering for the all-tied count=[1,1,...,1] init state, with
     *  ascending sym tiebreak). */
    private static int[] newSortedDescTable() {
        int[] t = new int[256];
        for (int i = 0; i < 256; i++) t[i] = i;
        return t;
    }

    /** Allocate inv_sort[256] = [0, 1, ..., 255] (identity, matches the
     *  identity sorted_desc init). */
    private static int[] newInvSortTable() {
        int[] t = new int[256];
        for (int i = 0; i < 256; i++) t[i] = i;
        return t;
    }

    /** Bubble {@code sym} up {@code sortedDesc} after its count was just
     *  incremented. Sort key is (-count[s], s): descending count, ascending
     *  sym tiebreak. Mirrors Python's {@code _bubble_up}. */
    private static void bubbleUp(int[] sortedDesc, int[] invSort,
                                  int[] count, int sym) {
        int pos = invSort[sym];
        int cntSym = count[sym];
        while (pos > 0) {
            int prev = sortedDesc[pos - 1];
            int cntPrev = count[prev];
            if (cntSym > cntPrev || (cntSym == cntPrev && sym < prev)) {
                sortedDesc[pos] = prev;
                sortedDesc[pos - 1] = sym;
                invSort[prev] = pos;
                invSort[sym] = pos - 1;
                pos--;
            } else {
                break;
            }
        }
    }

    /** Bubble {@code sym} DOWN {@code sortedAsc} after its count was just
     *  incremented. Sort key is (count[s], s): ascending count, ascending
     *  sym tiebreak. Mirror image of {@link #bubbleUp} for the ascending
     *  order needed by the delta&lt;0 normalise branch (byte-exact with
     *  {@link Rans#normaliseFreqsInto}'s ascending-key sort). */
    private static void bubbleDown(int[] sortedAsc, int[] invSortAsc,
                                    int[] count, int sym) {
        int pos = invSortAsc[sym];
        int cntSym = count[sym];
        while (pos < 255) {
            int next = sortedAsc[pos + 1];
            int cntNext = count[next];
            // sym belongs AFTER next iff sym's key > next's key:
            //   (cntSym > cntNext) OR (cntSym == cntNext AND sym > next).
            if (cntSym > cntNext || (cntSym == cntNext && sym > next)) {
                sortedAsc[pos] = next;
                sortedAsc[pos + 1] = sym;
                invSortAsc[next] = pos;
                invSortAsc[sym] = pos + 1;
                pos++;
            } else {
                break;
            }
        }
    }

    /** Rebuild {@code sortedDesc} / {@code invSort} from scratch using
     *  insertion sort by (descending count, ascending sym). Called only on
     *  halve events. Mirrors Python's {@code _rebuild_sorted_desc}. */
    private static void rebuildSortedDesc(int[] sortedDesc, int[] invSort,
                                           int[] count) {
        for (int i = 0; i < 256; i++) sortedDesc[i] = i;
        for (int i = 1; i < 256; i++) {
            int s = sortedDesc[i];
            int cntS = count[s];
            int j = i - 1;
            while (j >= 0) {
                int prev = sortedDesc[j];
                int cntPrev = count[prev];
                if (cntS > cntPrev || (cntS == cntPrev && s < prev)) {
                    sortedDesc[j + 1] = prev;
                    j--;
                } else {
                    break;
                }
            }
            sortedDesc[j + 1] = s;
        }
        for (int i = 0; i < 256; i++) invSort[sortedDesc[i]] = i;
    }

    /** Rebuild {@code sortedAsc} / {@code invSortAsc} from scratch by
     *  insertion sort on (ascending count, ascending sym). Called only on
     *  halve events. Companion to {@link #rebuildSortedDesc}. */
    private static void rebuildSortedAsc(int[] sortedAsc, int[] invSortAsc,
                                          int[] count) {
        for (int i = 0; i < 256; i++) sortedAsc[i] = i;
        for (int i = 1; i < 256; i++) {
            int s = sortedAsc[i];
            int cntS = count[s];
            int j = i - 1;
            while (j >= 0) {
                int prev = sortedAsc[j];
                int cntPrev = count[prev];
                // s belongs BEFORE prev iff s's key < prev's key.
                if (cntS < cntPrev || (cntS == cntPrev && s < prev)) {
                    sortedAsc[j + 1] = prev;
                    j--;
                } else {
                    break;
                }
            }
            sortedAsc[j + 1] = s;
        }
        for (int i = 0; i < 256; i++) invSortAsc[sortedAsc[i]] = i;
    }

    /** Adaptive count update + sort-order maintenance after encoding /
     *  decoding {@code sym}. On halve, rebuilds both sortedDesc and
     *  sortedAsc from scratch; on a normal increment, bubbles up sortedDesc
     *  and bubbles down sortedAsc. Returns the new total (sum of count[]). */
    private static int adaptWithSort(int[] count, int[] sortedDesc,
                                      int[] invSort, int[] sortedAsc,
                                      int[] invSortAsc, int sym,
                                      int learningRate, int maxCount,
                                      int total) {
        count[sym] += learningRate;
        total += learningRate;
        if (count[sym] > maxCount) {
            int newTotal = 0;
            for (int k = 0; k < 256; k++) {
                int v = count[k] >> 1;
                if (v < 1) v = 1;
                count[k] = v;
                newTotal += v;
            }
            rebuildSortedDesc(sortedDesc, invSort, count);
            rebuildSortedAsc(sortedAsc, invSortAsc, count);
            return newTotal;
        }
        bubbleUp(sortedDesc, invSort, count, sym);
        bubbleDown(sortedAsc, invSortAsc, count, sym);
        return total;
    }

    /** Byte-exact equivalent of {@link Rans#normaliseFreqsInto} for the
     *  delta&gt;=0 case using a maintained {@code sortedDesc} order to
     *  avoid the per-call sort, and a caller-supplied {@code total} to
     *  avoid re-summing 256 entries every call. Falls back to the
     *  canonical normaliser for the rare delta&lt;0 case.
     *
     *  <p>Invariant: with the [1]*256 init and floor-1 halve, every
     *  count is &gt;=1 for the codec's lifetime, so the cnt==0 branch
     *  is dead and {@code sortedDesc} spans the full alphabet. */
    private static void normaliseFreqsIncremental(int[] count,
                                                   int[] sortedDesc,
                                                   int[] sortedAsc,
                                                   int[] freqOut,
                                                   int total) {
        if (total <= 0) {
            throw new IllegalStateException(
                "cannot normalise empty count vector");
        }

        // Codec invariant: count[s] >= 1 always — skip the cnt==0 branch
        // for a tighter inner loop. Use int math: count[s] <= maxCount
        // (4096) and RANS_M = 4096 means count[s]*RANS_M <= 2^24, total
        // <= 256*4096 = 2^20, both fit comfortably in 32 bits with no
        // overflow on the product. Avoids a long-multiply per iteration.
        int sum = 0;
        for (int s = 0; s < 256; s++) {
            int scaled = (count[s] * RANS_M) / total;
            int f = (scaled >= 1) ? scaled : 1;
            freqOut[s] = f;
            sum += f;
        }
        int delta = RANS_M - sum;
        if (delta == 0) return;
        if (delta > 0) {
            // Distribute +1 round-robin walking sortedDesc, all 256
            // entries eligible (count >= 1 invariant), wraps mod 256.
            // Decompose into full passes (each adds 1 to every freqOut)
            // + a partial pass over the first ``rem`` sortedDesc entries.
            // Byte-exact with the round-robin walk: each full pass hits
            // every symbol once, each partial pass hits sortedDesc[0..rem-1].
            int full = delta >>> 8;       // delta / 256
            int rem = delta & 0xFF;       // delta % 256
            if (full > 0) {
                for (int s = 0; s < 256; s++) freqOut[s] += full;
            }
            for (int k = 0; k < rem; k++) {
                freqOut[sortedDesc[k]] += 1;
            }
            return;
        }
        // delta < 0: walk sortedAsc round-robin, subtract 1 (skip if
        // freq==1) until delta == 0. sortedAsc is maintained byte-exact
        // with Rans.normaliseFreqsInto's ascending (cnt, sym) sort
        // result — so no per-call sort needed. Codec invariant:
        // count[s] >= 1, so all 256 symbols are eligible.
        int idx = 0;
        int guard = 0;
        while (delta < 0) {
            int sym = sortedAsc[idx & 0xFF];
            if (freqOut[sym] > 1) {
                freqOut[sym] -= 1;
                delta += 1;
                guard = 0;
            } else {
                guard += 1;
                if (guard > 256) {
                    throw new IllegalStateException(
                        "FQZCOMP_NX16: cannot reduce freq below M");
                }
            }
            idx++;
        }
    }

    /** Build the cumulative-frequency table {@code cumOut[0..256]}
     *  from {@code freq[0..255]} in place. */
    private static void cumulativeInto(int[] freq, int[] cumOut) {
        int s = 0;
        for (int i = 0; i < 256; i++) {
            cumOut[i] = s;
            s += freq[i];
        }
        cumOut[256] = s;
    }

    // ── 4-way rANS encode ───────────────────────────────────────────

    /** Encoder body output: body bytes (incl. 16-byte length prefix) +
     *  state_init[4] + state_final[4] + pad_count. */
    private record EncoderResult(
        byte[] body, long[] stateInit, long[] stateFinal, int padCount) { }

    private static EncoderResult ransFourWayEncode(
            byte[] qualities, int[] readLengths, int[] revcompFlags,
            int tableSizeLog2, int learningRate, int maxCount, long seed) {
        int n = qualities.length;
        int padCount = (-n) & 3;
        int nPadded = n + padCount;

        int nContexts = 1 << tableSizeLog2;
        int[][] ctxCounts = new int[nContexts][];
        int[][] ctxSortedDesc = new int[nContexts][];
        int[][] ctxInvSort = new int[nContexts][];
        int[][] ctxSortedAsc = new int[nContexts][];
        int[][] ctxInvSortAsc = new int[nContexts][];
        int[] ctxTotal = new int[nContexts];
        int[] snapF = new int[nPadded];
        int[] snapC = new int[nPadded];
        byte[] symbols = new byte[nPadded];
        System.arraycopy(qualities, 0, symbols, 0, n);
        // padding symbols stay 0

        int padCtx = fqznContextHash(0, 0, 0, 0, 0, 0, seed, tableSizeLog2);

        int readIdx = 0;
        int posInRead = 0;
        int curReadLen = readLengths.length > 0 ? readLengths[0] : 0;
        int curRevcomp = revcompFlags.length > 0 ? revcompFlags[0] : 0;
        int cumulativeReadEnd = curReadLen;
        int prevQ0 = 0, prevQ1 = 0, prevQ2 = 0;

        // Scratch buffers reused across the per-symbol normalise loop.
        int[] freqScratch = new int[256];
        int[] cumScratch = new int[257];

        for (int i = 0; i < nPadded; i++) {
            int ctx;
            if (i < n) {
                if (i >= cumulativeReadEnd
                        && readIdx < readLengths.length - 1) {
                    readIdx++;
                    posInRead = 0;
                    curReadLen = readLengths[readIdx];
                    curRevcomp = revcompFlags[readIdx];
                    cumulativeReadEnd += curReadLen;
                    prevQ0 = 0;
                    prevQ1 = 0;
                    prevQ2 = 0;
                }
                int pb = positionBucket(posInRead, curReadLen);
                int lb = lengthBucket(curReadLen);
                ctx = fqznContextHash(
                    prevQ0, prevQ1, prevQ2, pb,
                    curRevcomp & 1, lb, seed, tableSizeLog2);
            } else {
                ctx = padCtx;
            }

            if (ctxCounts[ctx] == null) {
                ctxCounts[ctx] = newCountTable();
                ctxSortedDesc[ctx] = newSortedDescTable();
                ctxInvSort[ctx] = newInvSortTable();
                ctxSortedAsc[ctx] = newSortedDescTable();   // [0..255] also init for ascending
                ctxInvSortAsc[ctx] = newInvSortTable();
                ctxTotal[ctx] = 256;  // sum of [1]*256
            }
            int[] count = ctxCounts[ctx];
            int[] sortedDesc = ctxSortedDesc[ctx];
            int[] invSort = ctxInvSort[ctx];
            int[] sortedAsc = ctxSortedAsc[ctx];
            int[] invSortAsc = ctxInvSortAsc[ctx];

            int sym = Byte.toUnsignedInt(symbols[i]);
            normaliseFreqsIncremental(count, sortedDesc, sortedAsc,
                freqScratch, ctxTotal[ctx]);
            // Build cumulative table once and read cum[sym] (avg-case wins
            // over the prior partial-sum loop, and matches the decoder's
            // shape so JIT inlines both consistently).
            cumulativeInto(freqScratch, cumScratch);
            snapF[i] = freqScratch[sym];
            snapC[i] = cumScratch[sym];

            ctxTotal[ctx] = adaptWithSort(count, sortedDesc, invSort,
                sortedAsc, invSortAsc, sym,
                learningRate, maxCount, ctxTotal[ctx]);

            if (i < n) {
                prevQ2 = prevQ1;
                prevQ1 = prevQ0;
                prevQ0 = sym;
                posInRead++;
            }
        }

        // Reverse rANS pass over each substream.
        long[] state = new long[NUM_STREAMS];
        for (int k = 0; k < NUM_STREAMS; k++) state[k] = RANS_L;
        long[] stateInit = state.clone();

        // Use raw byte[] buffers + position counters instead of
        // ByteArrayOutputStream — its write(int) is synchronized, which
        // adds a monitor enter/exit on every renorm byte (massive hot-loop
        // hit: ~one byte per symbol per substream). Pre-size at the
        // theoretical max of 5 bytes per symbol per stream (rANS state is
        // < 2^32, renorm emits at most 4 bytes per encode step in the
        // M=2^12 / b=2^8 / L=2^23 regime; round to 5 for safety). Then
        // shrink at the end.
        int perStreamCap = (nPadded / NUM_STREAMS + 1) * 5 + 8;
        byte[][] outBufs = new byte[NUM_STREAMS][];
        int[] outPos = new int[NUM_STREAMS];
        for (int k = 0; k < NUM_STREAMS; k++) {
            outBufs[k] = new byte[perStreamCap];
        }

        long base = (RANS_L >>> RANS_M_BITS) << RANS_B_BITS; // 524288
        for (int i = nPadded - 1; i >= 0; i--) {
            int sIdx = i & 3;
            long f = snapF[i];
            long c = snapC[i];
            long x = state[sIdx];
            long xm = base * f;
            byte[] buf = outBufs[sIdx];
            int p = outPos[sIdx];
            // Renorm BEFORE encoding.
            while (x >= xm) {
                if (p >= buf.length) {
                    byte[] grown = new byte[buf.length * 2];
                    System.arraycopy(buf, 0, grown, 0, p);
                    buf = grown;
                    outBufs[sIdx] = buf;
                }
                buf[p++] = (byte) (x & 0xFFL);
                x >>>= 8;
            }
            outPos[sIdx] = p;
            // Encode the symbol.
            x = (x / f) * RANS_M + (x % f) + c;
            state[sIdx] = x;
        }
        long[] stateFinal = state.clone();

        // Reverse each substream's output (LIFO during encode → emit-order).
        byte[][] streams = new byte[NUM_STREAMS][];
        int maxLen = 0;
        for (int k = 0; k < NUM_STREAMS; k++) {
            int len = outPos[k];
            byte[] arr = new byte[len];
            byte[] src = outBufs[k];
            // Copy + reverse in one pass.
            for (int i = 0; i < len; i++) {
                arr[i] = src[len - 1 - i];
            }
            streams[k] = arr;
            if (len > maxLen) maxLen = len;
        }

        // Body layout: 16-byte length prefix (4 × uint32 LE) +
        // round-robin interleaved bytes (zero-padded).
        int bodyLen = 16 + 4 * maxLen;
        ByteBuffer bb = ByteBuffer.allocate(bodyLen).order(ByteOrder.LITTLE_ENDIAN);
        for (int k = 0; k < NUM_STREAMS; k++) {
            bb.putInt(streams[k].length);
        }
        for (int j = 0; j < maxLen; j++) {
            for (int k = 0; k < NUM_STREAMS; k++) {
                byte[] s = streams[k];
                bb.put((j < s.length) ? s[j] : 0);
            }
        }
        return new EncoderResult(bb.array(), stateInit, stateFinal, padCount);
    }

    // ── 4-way rANS decode ───────────────────────────────────────────

    /** Decoder-side per-symbol context-vector mirror — produces the same
     *  context-index sequence the encoder used. */
    private static final class StatefulContextEvolver {
        final int nQualities;
        final int[] readLengths;
        final int[] revcompFlags;
        final long seed;
        final int tableSizeLog2;
        final int padCtx;

        int readIdx;
        int posInRead;
        int curReadLen;
        int curRevcomp;
        int cumulativeReadEnd;
        int prevQ0, prevQ1, prevQ2;

        StatefulContextEvolver(int nQualities, int[] readLengths,
                int[] revcompFlags, long seed, int tableSizeLog2) {
            this.nQualities = nQualities;
            this.readLengths = readLengths;
            this.revcompFlags = revcompFlags;
            this.seed = seed;
            this.tableSizeLog2 = tableSizeLog2;
            this.padCtx = fqznContextHash(0, 0, 0, 0, 0, 0, seed, tableSizeLog2);
            this.curReadLen = readLengths.length > 0 ? readLengths[0] : 0;
            this.curRevcomp = revcompFlags.length > 0 ? revcompFlags[0] : 0;
            this.cumulativeReadEnd = this.curReadLen;
        }

        int contextFor(int i) {
            if (i >= nQualities) return padCtx;
            if (i >= cumulativeReadEnd
                    && readIdx < readLengths.length - 1) {
                readIdx++;
                posInRead = 0;
                curReadLen = readLengths[readIdx];
                curRevcomp = revcompFlags[readIdx];
                cumulativeReadEnd += curReadLen;
                prevQ0 = 0;
                prevQ1 = 0;
                prevQ2 = 0;
            }
            int pb = positionBucket(posInRead, curReadLen);
            int lb = lengthBucket(curReadLen);
            return fqznContextHash(
                prevQ0, prevQ1, prevQ2, pb,
                curRevcomp & 1, lb, seed, tableSizeLog2);
        }

        void feed(int symbol, int i) {
            if (i >= nQualities) return;
            prevQ2 = prevQ1;
            prevQ1 = prevQ0;
            prevQ0 = symbol;
            posInRead++;
        }
    }

    private static byte[] ransFourWayDecode(
            byte[] body, long[] stateInit, long[] stateFinal,
            int nPadded, StatefulContextEvolver evolver,
            int tableSizeLog2, int learningRate, int maxCount) {
        if (body.length < 16) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16: body too short for substream lengths");
        }
        ByteBuffer bb = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN);
        int[] subLens = new int[NUM_STREAMS];
        for (int k = 0; k < NUM_STREAMS; k++) {
            subLens[k] = bb.getInt(4 * k);
        }
        int payloadOff = 16;
        int payloadLen = body.length - payloadOff;
        int maxLen = 0;
        for (int v : subLens) if (v > maxLen) maxLen = v;

        // De-interleave.
        byte[][] streams = new byte[NUM_STREAMS][];
        for (int k = 0; k < NUM_STREAMS; k++) streams[k] = new byte[subLens[k]];
        int cursor = 0;
        for (int j = 0; j < maxLen; j++) {
            for (int sIdx = 0; sIdx < NUM_STREAMS; sIdx++) {
                if (cursor >= payloadLen) {
                    throw new IllegalArgumentException(
                        "FQZCOMP_NX16: truncated body");
                }
                byte b = body[payloadOff + cursor];
                cursor++;
                if (j < subLens[sIdx]) {
                    streams[sIdx][j] = b;
                }
            }
        }

        // Decoder runs forward starting from stateFinal.
        long[] state = stateFinal.clone();
        int[] subPos = new int[NUM_STREAMS];

        int nContexts = 1 << tableSizeLog2;
        int[][] ctxCounts = new int[nContexts][];
        int[][] ctxSortedDesc = new int[nContexts][];
        int[][] ctxInvSort = new int[nContexts][];
        int[][] ctxSortedAsc = new int[nContexts][];
        int[][] ctxInvSortAsc = new int[nContexts][];
        int[] ctxTotal = new int[nContexts];

        byte[] out = new byte[nPadded];

        // Scratch buffers reused across the per-symbol normalise loop.
        int[] freqScratch = new int[256];
        int[] cumScratch = new int[257];

        for (int i = 0; i < nPadded; i++) {
            int sIdx = i & 3;
            int ctx = evolver.contextFor(i);
            if (ctxCounts[ctx] == null) {
                ctxCounts[ctx] = newCountTable();
                ctxSortedDesc[ctx] = newSortedDescTable();
                ctxInvSort[ctx] = newInvSortTable();
                ctxSortedAsc[ctx] = newSortedDescTable();
                ctxInvSortAsc[ctx] = newInvSortTable();
                ctxTotal[ctx] = 256;
            }
            int[] count = ctxCounts[ctx];
            int[] sortedDesc = ctxSortedDesc[ctx];
            int[] invSort = ctxInvSort[ctx];
            int[] sortedAsc = ctxSortedAsc[ctx];
            int[] invSortAsc = ctxInvSortAsc[ctx];
            normaliseFreqsIncremental(count, sortedDesc, sortedAsc,
                freqScratch, ctxTotal[ctx]);
            cumulativeInto(freqScratch, cumScratch);

            long x = state[sIdx];
            int slot = (int) (x & RANS_M_MASK);
            // Binary search for largest sym in [0, 256) such that cum[sym] <= slot.
            int lo = 0;
            int hi = 256;
            while (lo < hi) {
                int mid = (lo + hi) >>> 1;
                if (cumScratch[mid + 1] <= slot) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            int sym = lo;
            out[i] = (byte) sym;
            long f = freqScratch[sym];
            long c = cumScratch[sym];
            x = f * (x >>> RANS_M_BITS) + slot - c;
            // Renorm — pull bytes in until x is back in [L, b*L).
            while (x < RANS_L) {
                if (subPos[sIdx] >= streams[sIdx].length) {
                    throw new IllegalArgumentException(
                        "FQZCOMP_NX16: substream " + sIdx
                        + " exhausted while decoding symbol " + i);
                }
                x = (x << 8) | (Byte.toUnsignedInt(streams[sIdx][subPos[sIdx]]));
                subPos[sIdx]++;
            }
            state[sIdx] = x;

            ctxTotal[ctx] = adaptWithSort(count, sortedDesc, invSort,
                sortedAsc, invSortAsc, sym,
                learningRate, maxCount, ctxTotal[ctx]);
            evolver.feed(sym, i);
        }

        for (int k = 0; k < NUM_STREAMS; k++) {
            if (state[k] != stateInit[k]) {
                throw new IllegalArgumentException(
                    "FQZCOMP_NX16: post-decode state[" + k + "]=" + state[k]
                    + " != stateInit[" + k + "]=" + stateInit[k]
                    + "; stream is corrupt");
            }
        }
        return out;
    }

    // ── Header pack / unpack ────────────────────────────────────────

    /** Serialise the 16-byte context_model_params block. */
    public static byte[] packContextModelParams(ContextModelParams p) {
        ByteBuffer bb = ByteBuffer.allocate(CONTEXT_MODEL_PARAMS_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN);
        bb.put((byte) (p.contextTableSizeLog2() & 0xFF));
        bb.put((byte) (p.learningRate() & 0xFF));
        bb.putShort((short) (p.maxCount() & 0xFFFF));
        bb.put((byte) (p.freqTableInit() & 0xFF));
        bb.putInt((int) (p.contextHashSeed() & 0xFFFFFFFFL));
        // 7 reserved bytes (zero).
        bb.put(new byte[7]);
        return bb.array();
    }

    /** Inverse of {@link #packContextModelParams}. */
    public static ContextModelParams unpackContextModelParams(
            byte[] blob, int off) {
        if (blob == null || blob.length - off < CONTEXT_MODEL_PARAMS_SIZE) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16: context_model_params truncated");
        }
        ByteBuffer bb = ByteBuffer.wrap(blob, off, CONTEXT_MODEL_PARAMS_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN);
        int tableLog2 = Byte.toUnsignedInt(bb.get());
        int lr        = Byte.toUnsignedInt(bb.get());
        int maxCount  = Short.toUnsignedInt(bb.getShort());
        int ftInit    = Byte.toUnsignedInt(bb.get());
        long seed     = Integer.toUnsignedLong(bb.getInt());
        // 7 reserved bytes ignored.
        return new ContextModelParams(tableLog2, lr, maxCount, ftInit, seed);
    }

    /** Serialise a {@link CodecHeader} to {@code 54 + L} bytes. */
    public static byte[] packCodecHeader(CodecHeader h) {
        int totalLen = HEADER_FIXED_PREFIX + h.rltCompressedLen()
            + HEADER_TRAILING_FIXED;
        ByteBuffer bb = ByteBuffer.allocate(totalLen)
            .order(ByteOrder.LITTLE_ENDIAN);
        bb.put(MAGIC);
        bb.put((byte) VERSION);
        bb.put((byte) (h.flags() & 0xFF));
        bb.putLong(h.numQualities());
        bb.putInt(h.numReads());
        bb.putInt(h.rltCompressedLen());
        bb.put(h.readLengthTable());
        bb.put(packContextModelParams(h.params()));
        for (int k = 0; k < NUM_STREAMS; k++) {
            bb.putInt((int) (h.stateInit()[k] & 0xFFFFFFFFL));
        }
        return bb.array();
    }

    /** Inverse of {@link #packCodecHeader}. */
    public static HeaderUnpack unpackCodecHeader(byte[] blob) {
        if (blob == null) {
            throw new IllegalArgumentException("blob must not be null");
        }
        if (blob.length < HEADER_FIXED_PREFIX) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16 header too short: " + blob.length + " bytes");
        }
        for (int i = 0; i < 4; i++) {
            if (blob[i] != MAGIC[i]) {
                throw new IllegalArgumentException(
                    "FQZCOMP_NX16 bad magic, expected 'FQZN'");
            }
        }
        int version = Byte.toUnsignedInt(blob[4]);
        if (version != VERSION) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16 unsupported version: " + version);
        }
        int flags = Byte.toUnsignedInt(blob[5]);
        if (((flags >> 6) & 0x3) != 0) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16 reserved flag bits 6-7 must be 0, got 0x"
                + String.format("%02x", flags));
        }
        ByteBuffer bb = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN);
        long numQualities = bb.getLong(6);
        int numReads = bb.getInt(14);
        int rltLen = bb.getInt(18);
        int cursor = HEADER_FIXED_PREFIX;
        int endRlt = cursor + rltLen;
        if (blob.length < endRlt + CONTEXT_MODEL_PARAMS_SIZE + 16) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16 header truncated");
        }
        byte[] rlt = new byte[rltLen];
        System.arraycopy(blob, cursor, rlt, 0, rltLen);
        cursor = endRlt;
        ContextModelParams params = unpackContextModelParams(blob, cursor);
        cursor += CONTEXT_MODEL_PARAMS_SIZE;
        long[] stateInit = new long[NUM_STREAMS];
        for (int k = 0; k < NUM_STREAMS; k++) {
            stateInit[k] = Integer.toUnsignedLong(bb.getInt(cursor));
            cursor += 4;
        }
        return new HeaderUnpack(
            new CodecHeader(flags, numQualities, numReads, rltLen, rlt,
                params, stateInit),
            cursor);
    }

    // ── Read-length sidecar ─────────────────────────────────────────

    /** Encode {@code readLengths} as rANS-order-0 over LE uint32 bytes. */
    public static byte[] encodeReadLengths(int[] readLengths) {
        if (readLengths.length == 0) {
            return Rans.encode(new byte[0], 0);
        }
        ByteBuffer bb = ByteBuffer.allocate(4 * readLengths.length)
            .order(ByteOrder.LITTLE_ENDIAN);
        for (int v : readLengths) bb.putInt(v);
        return Rans.encode(bb.array(), 0);
    }

    /** Inverse of {@link #encodeReadLengths}. */
    public static int[] decodeReadLengths(byte[] encoded, int numReads) {
        byte[] raw = Rans.decode(encoded);
        if (numReads == 0) return new int[0];
        if (raw.length != 4 * numReads) {
            throw new IllegalArgumentException(
                "decodeReadLengths: expected " + (4 * numReads)
                + " raw bytes, got " + raw.length);
        }
        int[] out = new int[numReads];
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < numReads; i++) out[i] = bb.getInt();
        return out;
    }

    // ── Top-level encode/decode ────────────────────────────────────

    private static int buildFlags(int padCount) {
        if (padCount < 0 || padCount > 3) {
            throw new IllegalArgumentException(
                "padCount must be 0..3, got " + padCount);
        }
        // bits 0-3 = context flags (revcomp/pos/length/prev_q all on),
        // bits 4-5 = pad_count, bits 6-7 reserved (0).
        return 0x0F | ((padCount & 0x3) << 4);
    }

    /** Top-level FQZCOMP_NX16 encoder. */
    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags) {
        return encode(qualities, readLengths, revcompFlags,
            ContextModelParams.defaults());
    }

    /** Top-level FQZCOMP_NX16 encoder with explicit params. */
    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags,
                                ContextModelParams params) {
        if (qualities == null) {
            throw new IllegalArgumentException("qualities must not be null");
        }
        if (readLengths.length != revcompFlags.length) {
            throw new IllegalArgumentException(
                "readLengths (" + readLengths.length
                + ") != revcompFlags (" + revcompFlags.length + ")");
        }
        long total = 0;
        for (int v : readLengths) total += v;
        if (total != qualities.length) {
            throw new IllegalArgumentException(
                "sum(readLengths) (" + total + ") != qualities.length ("
                + qualities.length + ")");
        }
        if (params == null) params = ContextModelParams.defaults();

        EncoderResult enc = ransFourWayEncode(
            qualities, readLengths, revcompFlags,
            params.contextTableSizeLog2(),
            params.learningRate(),
            params.maxCount(),
            params.contextHashSeed());

        byte[] rlt = encodeReadLengths(readLengths);
        int flags = buildFlags(enc.padCount());

        byte[] header = packCodecHeader(new CodecHeader(
            flags, qualities.length, readLengths.length, rlt.length, rlt,
            params, enc.stateInit()));
        byte[] body = enc.body();
        ByteBuffer trailer = ByteBuffer.allocate(TRAILER_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN);
        for (int k = 0; k < NUM_STREAMS; k++) {
            trailer.putInt((int) (enc.stateFinal()[k] & 0xFFFFFFFFL));
        }

        byte[] out = new byte[header.length + body.length + TRAILER_SIZE];
        System.arraycopy(header, 0, out, 0, header.length);
        System.arraycopy(body, 0, out, header.length, body.length);
        System.arraycopy(trailer.array(), 0, out,
            header.length + body.length, TRAILER_SIZE);
        return out;
    }

    /** Decode using all-zero {@code revcompFlags}. The wire format does
     *  NOT carry revcomp; M86 callers should use {@link #decodeWithMetadata}. */
    public static DecodeResult decode(byte[] encoded) {
        return decodeWithMetadata(encoded, null);
    }

    /** Decode {@code encoded} using the supplied {@code revcompFlags}.
     *  When {@code revcompFlags} is null, all-zero is used. */
    public static DecodeResult decodeWithMetadata(byte[] encoded,
                                                   int[] revcompFlags) {
        HeaderUnpack hu = unpackCodecHeader(encoded);
        CodecHeader header = hu.header();
        int headerSize = hu.bytesConsumed();
        long n = header.numQualities();
        int nReads = header.numReads();
        int padCount = (header.flags() >> 4) & 0x3;

        int[] readLengths = decodeReadLengths(
            header.readLengthTable(), nReads);

        if (revcompFlags == null) {
            revcompFlags = new int[nReads];
        } else if (revcompFlags.length != nReads) {
            throw new IllegalArgumentException(
                "revcompFlags length " + revcompFlags.length
                + " != numReads " + nReads);
        }

        int trailerOff = encoded.length - TRAILER_SIZE;
        if (trailerOff < headerSize) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16: encoded too short for body + trailer");
        }
        byte[] body = new byte[trailerOff - headerSize];
        System.arraycopy(encoded, headerSize, body, 0, body.length);

        long[] stateFinal = new long[NUM_STREAMS];
        ByteBuffer tbb = ByteBuffer.wrap(encoded, trailerOff, TRAILER_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN);
        for (int k = 0; k < NUM_STREAMS; k++) {
            stateFinal[k] = Integer.toUnsignedLong(tbb.getInt());
        }

        long nPaddedL = n + padCount;
        if ((nPaddedL & 3L) != 0) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16: nPadded " + nPaddedL
                + " not a multiple of 4 (numQualities=" + n
                + ", padCount=" + padCount + ")");
        }
        if (nPaddedL > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "FQZCOMP_NX16: nPadded too large for Java int: " + nPaddedL);
        }
        int nPadded = (int) nPaddedL;

        StatefulContextEvolver evolver = new StatefulContextEvolver(
            (int) n, readLengths, revcompFlags,
            header.params().contextHashSeed(),
            header.params().contextTableSizeLog2());

        byte[] out = ransFourWayDecode(body,
            header.stateInit(), stateFinal, nPadded, evolver,
            header.params().contextTableSizeLog2(),
            header.params().learningRate(),
            header.params().maxCount());

        byte[] qualities = new byte[(int) n];
        System.arraycopy(out, 0, qualities, 0, (int) n);
        int[] rcOut = revcompFlags.clone();
        return new DecodeResult(qualities, readLengths, rcOut);
    }
}
