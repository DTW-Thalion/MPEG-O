/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.zip.Deflater;
import java.util.zip.DeflaterOutputStream;
import java.util.zip.Inflater;
import java.util.zip.InflaterOutputStream;

/**
 * FQZCOMP_NX16.Z — CRAM-mimic (rANS-Nx16) lossless quality codec (M94.Z).
 *
 * <p>Clean-room Java port of the Python reference at
 * {@code python/src/ttio/codecs/fqzcomp_nx16_z.py}. Spec at
 * {@code docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md}.
 *
 * <p>Algorithm summary:
 * <ul>
 *   <li>{@code L = 2^15 = 32 768} state lower bound.</li>
 *   <li>{@code B = 16}-bit renormalisation chunks
 *       ({@code b = 2^16 = 65 536}, {@code b·L = 2^31}).</li>
 *   <li>{@code N = 4} interleaved rANS states (round-robin by symbol index).</li>
 *   <li>{@code T = 4096 = 2^12} fixed total per-context (CRAM-Nx16 discipline:
 *       static-per-block freq tables, built once in pass 1, held constant in
 *       pass 2).</li>
 *   <li>Bit-packed CRAM-style context: 12-bit prev-q ring (3 × 4-bit window) |
 *       2-bit position bucket | 1-bit revcomp.</li>
 * </ul>
 *
 * <p>Wire format magic is {@code M94Z}, distinct from M94 v1's {@code FQZN}.
 * This is an independent codec. M94 v1 fixtures stay valid; M94.Z fixtures
 * are unrelated bytes. Both codecs exist side by side in the codebase.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.fqzcomp_nx16_z}</li>
 *   <li>Cython: {@code ttio.codecs._fqzcomp_nx16_z._fqzcomp_nx16_z}</li>
 * </ul>
 */
public final class FqzcompNx16Z {

    // ── rANS-Nx16 algorithm constants (per spec §1) ─────────────────

    public static final int L = 1 << 15;            // 32 768
    public static final int B_BITS = 16;
    public static final int B = 1 << B_BITS;        // 65 536
    public static final int B_MASK = B - 1;         // 0xFFFF
    public static final int T = 1 << 12;            // 4096
    public static final int T_BITS = 12;
    public static final int T_MASK = T - 1;
    public static final int NUM_STREAMS = 4;

    /** {@code (L >> T_BITS) << B_BITS} = 2^19 = 524 288 — exact since T | b·L. */
    public static final int X_MAX_PREFACTOR = (L >>> T_BITS) << B_BITS;

    // ── Wire-format constants ───────────────────────────────────────

    public static final byte[] MAGIC = new byte[]{'M', '9', '4', 'Z'};
    public static final int VERSION = 1;
    /** M94.Z V2 wire-format version: body produced by libttio_rans (Task 21/22). */
    public static final int VERSION_V2_NATIVE = 2;
    /** M94.Z V4 wire-format version: CRAM 3.1 fqzcomp port (Stage 2/3). */
    public static final int VERSION_V4_FQZCOMP = 4;
    /** Env var that overrides the default M94.Z dispatch version
     *  ("1"/"2"/"3" → force pre-V4 path; "4" → force V4). */
    public static final String ENV_VERSION_OVERRIDE = "TTIO_M94Z_VERSION";
    public static final int CONTEXT_PARAMS_SIZE = 8;

    // ── Default context parameters ──────────────────────────────────

    public static final int DEFAULT_QBITS = 12;
    public static final int DEFAULT_PBITS = 2;
    public static final int DEFAULT_DBITS = 0;
    public static final int DEFAULT_SLOC = 14;

    private FqzcompNx16Z() {
        // Utility class.
    }

    /**
     * Reports which rANS backend will service encode/decode calls in the
     * current JVM.
     *
     * <p>Returns one of:
     * <ul>
     *   <li>{@code "native-avx2"}, {@code "native-sse4.1"}, or
     *       {@code "native-scalar"} when libttio_rans_jni is loaded — the
     *       suffix is the kernel selected by CPUID dispatch.</li>
     *   <li>{@code "native"} as a defensive fallback if the library loaded
     *       but kernel introspection fails.</li>
     *   <li>{@code "pure-java"} when the JNI library is not on
     *       {@code java.library.path}; the Java codec uses its built-in
     *       {@link Rans} backend.</li>
     * </ul>
     *
     * <p>Backend selection only affects V2 (native-body) dispatch — see
     * {@link EncodeOptions#preferNative(boolean)} or the
     * {@code TTIO_M94Z_USE_NATIVE} environment variable. V1 encode/decode
     * always uses pure-Java for both paths.
     */
    public static String getBackendName() {
        if (TtioRansNative.isAvailable()) {
            try {
                return "native-" + TtioRansNative.kernelName();
            } catch (Throwable t) {
                return "native";
            }
        }
        return "pure-java";
    }

    // ── ContextParams ───────────────────────────────────────────────

    /** Bit-pack context parameters (defaults: qbits=12, pbits=2, dbits=0, sloc=14). */
    public static final class ContextParams {
        public final int qbits;
        public final int pbits;
        public final int dbits;
        public final int sloc;

        public ContextParams(int qbits, int pbits, int dbits, int sloc) {
            this.qbits = qbits;
            this.pbits = pbits;
            this.dbits = dbits;
            this.sloc = sloc;
        }

        public static ContextParams defaults() {
            return new ContextParams(DEFAULT_QBITS, DEFAULT_PBITS,
                                     DEFAULT_DBITS, DEFAULT_SLOC);
        }

        @Override public boolean equals(Object o) {
            if (!(o instanceof ContextParams)) return false;
            ContextParams p = (ContextParams) o;
            return p.qbits == qbits && p.pbits == pbits
                && p.dbits == dbits && p.sloc == sloc;
        }

        @Override public int hashCode() {
            return (qbits * 31 + pbits) * 31 * 31 + dbits * 31 + sloc;
        }

        @Override public String toString() {
            return "ContextParams(qbits=" + qbits + ", pbits=" + pbits
                + ", dbits=" + dbits + ", sloc=" + sloc + ")";
        }
    }

    // ── EncodeOptions ───────────────────────────────────────────────

    /**
     * Encoder options bag. Currently exposes a single knob:
     * {@link #preferNative(boolean)} — when {@code true} (and the
     * native library is available), {@link #encode} emits a V2 wire
     * format with body produced by libttio_rans's
     * {@code ttio_rans_encode_block}. When {@code false}, the V1 path
     * is forced (default behaviour, byte-identical to historical
     * encoders). When this method is never called (or the native
     * library is unavailable), the encoder consults the environment
     * variable {@code TTIO_M94Z_USE_NATIVE} — values {@code "1"},
     * {@code "true"}, {@code "yes"}, {@code "on"} (case-insensitive)
     * enable V2 dispatch.
     *
     * <p>V2 encode is fast (native rANS); V2 decode is pure-Java
     * because contexts are derived from previously-decoded symbols
     * (see Task 21/22 design notes — the C library's decode requires
     * a fully pre-computed contexts vector). V1 streams continue to
     * round-trip via the existing pure-Java path.
     */
    public static final class EncodeOptions {
        // null = consult env var; Boolean.TRUE/FALSE = explicit override.
        Boolean preferNative = null;

        // V4 (CRAM 3.1 fqzcomp) dispatch knobs:
        //   preferV4: null = follow env / default (V4 when JNI loaded);
        //             TRUE  = force V4 path (throws if JNI not loaded);
        //             FALSE = force pre-V4 (V1/V2) path.
        //   v4StrategyHint: null = -1 (auto-tune); 0..3 = explicit preset.
        Boolean preferV4 = null;
        Integer v4StrategyHint = null;

        public EncodeOptions preferNative(boolean v) {
            this.preferNative = v;
            return this;
        }

        public EncodeOptions preferV4(boolean v) {
            this.preferV4 = v;
            return this;
        }

        public EncodeOptions v4StrategyHint(int hint) {
            this.v4StrategyHint = hint;
            return this;
        }
    }

    public static byte[] packContextParams(ContextParams p) {
        byte[] out = new byte[CONTEXT_PARAMS_SIZE];
        out[0] = (byte) (p.qbits & 0xFF);
        out[1] = (byte) (p.pbits & 0xFF);
        out[2] = (byte) (p.dbits & 0xFF);
        out[3] = (byte) (p.sloc & 0xFF);
        // bytes 4..7 reserved (zero)
        return out;
    }

    public static ContextParams unpackContextParams(byte[] blob, int off) {
        if (blob.length - off < CONTEXT_PARAMS_SIZE) {
            throw new IllegalArgumentException("M94Z: context_params truncated");
        }
        int qb = blob[off] & 0xFF;
        int pb = blob[off + 1] & 0xFF;
        int db = blob[off + 2] & 0xFF;
        int sl = blob[off + 3] & 0xFF;
        return new ContextParams(qb, pb, db, sl);
    }

    // ── Context bit-pack (per spec §4.2) ────────────────────────────

    /** Position bucket per spec §4.2:
     *  {@code min(2^pbits - 1, (pos * 2^pbits) // read_length)}. */
    public static int positionBucketPbits(int position, int readLength, int pbits) {
        if (pbits <= 0) return 0;
        int nBuckets = 1 << pbits;
        if (readLength <= 0 || position <= 0) return 0;
        if (position >= readLength) return nBuckets - 1;
        // (position * nBuckets) / readLength — careful: position*nBuckets can
        // overflow int for very long reads. Use long arithmetic.
        long product = (long) position * (long) nBuckets;
        int v = (int) (product / readLength);
        return Math.min(nBuckets - 1, v);
    }

    /** Bit-pack context vector to {@code [0, 1<<sloc)}. */
    public static int m94zContext(int prevQ, int posBucket, int revcomp,
                                   int qbits, int pbits, int sloc) {
        int qmask = (1 << qbits) - 1;
        int pmask = (1 << pbits) - 1;
        int smask = (1 << sloc) - 1;
        int ctx = prevQ & qmask;
        ctx |= (posBucket & pmask) << qbits;
        ctx |= (revcomp & 1) << (qbits + pbits);
        return ctx & smask;
    }

    // ── Frequency-table normalisation (matches Python ref §3.3) ─────

    /**
     * Normalise raw_count[256] to freq[256] with sum == total. Mirrors the
     * Python {@code normalise_to_total} byte-for-byte:
     * <ol>
     *   <li>Empty input → freq[0] = total.</li>
     *   <li>Scale: {@code freq[s] = max(1, (cnt * total + S/2) // S)} for
     *       {@code cnt > 0} (rounded scaling, NOT floor).</li>
     *   <li>delta &gt; 0: cycle through symbols ordered by (-freq, +sym),
     *       only those with raw_count &gt; 0, adding 1 each pass.</li>
     *   <li>delta &lt; 0: repeatedly find the largest freq with freq &gt; 1
     *       (ties broken by smallest sym) and decrement.</li>
     * </ol>
     */
    static int[] normaliseToTotal(int[] rawCount, int total) {
        if (rawCount.length != 256) {
            throw new IllegalArgumentException("rawCount length must be 256");
        }
        int[] freq = new int[256];

        long s = 0L;
        for (int i = 0; i < 256; i++) s += rawCount[i] & 0xFFFFFFFFL;
        if (s == 0L) {
            freq[0] = total;
            return freq;
        }

        int fsum = 0;
        for (int i = 0; i < 256; i++) {
            int c = rawCount[i];
            if (c == 0) continue;
            // (c * total + s/2) // s — match Python integer rounding.
            long scaled = ((long) c * (long) total + (s / 2L)) / s;
            int f = (scaled < 1L) ? 1 : (int) scaled;
            freq[i] = f;
            fsum += f;
        }

        int delta = total - fsum;
        if (delta == 0) return freq;

        if (delta > 0) {
            // Build order: nonzero raw_count syms, sorted by (-freq, +sym).
            int n = 0;
            int[] syms = new int[256];
            for (int i = 0; i < 256; i++) {
                if (rawCount[i] > 0) syms[n++] = i;
            }
            if (n == 0) {
                // Pathological — degenerate to freq[0] = total.
                Arrays.fill(freq, 0);
                freq[0] = total;
                return freq;
            }
            // Sort: pack (descending freq, ascending sym) → use long key.
            long[] keys = new long[n];
            for (int k = 0; k < n; k++) {
                int sym = syms[k];
                // ((-freq) << 32) | sym  →  ascending sort gives desired order.
                keys[k] = ((long) (-freq[sym]) << 32) | (sym & 0xFFFFFFFFL);
            }
            Arrays.sort(keys, 0, n);
            int kIdx = 0;
            while (delta > 0) {
                int sym = (int) (keys[kIdx % n] & 0xFFFFFFFFL);
                freq[sym]++;
                kIdx++;
                delta--;
            }
            return freq;
        }

        // delta < 0
        int deficit = -delta;
        while (deficit > 0) {
            int bestI = -1;
            int bestV = -1;
            for (int i = 0; i < 256; i++) {
                if (freq[i] > 1 && freq[i] > bestV) {
                    bestV = freq[i];
                    bestI = i;
                }
            }
            if (bestI < 0) {
                throw new IllegalStateException(
                    "normaliseToTotal: cannot reduce below floor=1");
            }
            freq[bestI]--;
            deficit--;
        }
        return freq;
    }

    static int[] cumulative(int[] freq) {
        int[] cum = new int[257];
        int s = 0;
        for (int i = 0; i < 256; i++) {
            cum[i] = s;
            s += freq[i];
        }
        cum[256] = s;
        return cum;
    }

    // ── Per-symbol context evolution ───────────────────────────────

    /**
     * Compute the per-symbol context sequence — encoder & decoder must
     * produce identical sequences. The "shift" used in the prev_q ring
     * is {@code max(1, qbits/3)}; for qbits=12 this is 4, giving a
     * 3-symbol window of 4-bit quantised qualities.
     *
     * <p>Padding positions ({@code i >= n}) get the all-zero context.
     */
    private static int[] buildContextSeq(byte[] qualities, int[] readLengths,
                                          int[] revcompFlags, int nPadded,
                                          int qbits, int pbits, int sloc) {
        int n = qualities.length;
        int[] contexts = new int[nPadded];
        int padCtx = m94zContext(0, 0, 0, qbits, pbits, sloc);
        if (nPadded == 0) return contexts;

        int readIdx = 0;
        int posInRead = 0;
        int curReadLen = readLengths.length > 0 ? readLengths[0] : 0;
        int curRevcomp = revcompFlags.length > 0 ? revcompFlags[0] : 0;
        int cumulativeReadEnd = curReadLen;
        int prevQ = 0;
        int shift = Math.max(1, qbits / 3);
        int qmaskLocal = (1 << qbits) - 1;
        int symMask = (1 << shift) - 1;

        for (int i = 0; i < nPadded; i++) {
            if (i < n) {
                if (i >= cumulativeReadEnd
                    && readIdx < readLengths.length - 1) {
                    readIdx++;
                    posInRead = 0;
                    curReadLen = readLengths[readIdx];
                    curRevcomp = revcompFlags[readIdx];
                    cumulativeReadEnd += curReadLen;
                    prevQ = 0;
                }
                int pb = positionBucketPbits(posInRead, curReadLen, pbits);
                contexts[i] = m94zContext(prevQ, pb, curRevcomp & 1,
                                           qbits, pbits, sloc);
                int sym = qualities[i] & 0xFF;
                prevQ = ((prevQ << shift) | (sym & symMask)) & qmaskLocal;
                posInRead++;
            } else {
                contexts[i] = padCtx;
            }
        }
        return contexts;
    }

    // ── Read-length sidecar (deflate-compressed uint32 LE list) ─────

    public static byte[] encodeReadLengths(int[] readLengths) {
        if (readLengths.length == 0) {
            return deflate(new byte[0]);
        }
        ByteBuffer buf = ByteBuffer.allocate(4 * readLengths.length)
            .order(ByteOrder.LITTLE_ENDIAN);
        for (int v : readLengths) buf.putInt(v);
        return deflate(buf.array());
    }

    public static int[] decodeReadLengths(byte[] encoded, int numReads) {
        byte[] raw = inflate(encoded);
        if (numReads == 0) {
            if (raw.length != 0) {
                throw new IllegalArgumentException(
                    "M94Z: read_length_table non-empty but numReads=0");
            }
            return new int[0];
        }
        if (raw.length != 4 * numReads) {
            throw new IllegalArgumentException(
                "M94Z: read_length_table raw length " + raw.length
                + " != " + (4 * numReads));
        }
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        int[] lens = new int[numReads];
        for (int i = 0; i < numReads; i++) lens[i] = bb.getInt();
        return lens;
    }

    // ── Deflate helpers ─────────────────────────────────────────────

    private static byte[] deflate(byte[] data) {
        // zlib level 6 to match Python's zlib.compress default.
        Deflater d = new Deflater(6);
        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream(
                Math.max(64, data.length / 4));
            try (DeflaterOutputStream dos = new DeflaterOutputStream(baos, d)) {
                dos.write(data);
            } catch (java.io.IOException e) {
                throw new IllegalStateException("deflate failed", e);
            }
            return baos.toByteArray();
        } finally {
            d.end();
        }
    }

    private static byte[] inflate(byte[] data) {
        if (data.length == 0) return new byte[0];
        Inflater i = new Inflater();
        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream(
                Math.max(64, data.length * 4));
            try (InflaterOutputStream ios = new InflaterOutputStream(baos, i)) {
                ios.write(data);
            } catch (java.io.IOException e) {
                throw new IllegalArgumentException("inflate failed: "
                    + e.getMessage(), e);
            }
            return baos.toByteArray();
        } finally {
            i.end();
        }
    }

    // ── Freq-table sidecar (per-context, deflate-compressed) ────────

    /** Serialize freq tables as Python's {@code _serialize_freq_tables}:
     *  {@code uint32 LE n_active; for each: uint32 LE ctx_id, 256×uint16 LE freq}.
     *  Then deflate-compress. */
    private static byte[] serializeFreqTables(int[] activeCtxs,
                                                int[][] freqByCtx,
                                                int sloc) {
        int smask = (1 << sloc) - 1;
        int n = activeCtxs.length;
        int rawLen = 4 + n * (4 + 256 * 2);
        ByteBuffer bb = ByteBuffer.allocate(rawLen).order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(n);
        for (int k = 0; k < n; k++) {
            int ctx = activeCtxs[k];
            if ((ctx & ~smask) != 0) {
                throw new IllegalStateException(
                    "M94Z: ctx " + ctx + " out of range for sloc=" + sloc);
            }
            bb.putInt(ctx);
            int[] freq = freqByCtx[k];
            for (int s = 0; s < 256; s++) bb.putShort((short) freq[s]);
        }
        return deflate(bb.array());
    }

    /** Deserialize freq tables → (activeCtxs, freqArrays) parallel arrays. */
    private static FreqTables deserializeFreqTables(byte[] blob) {
        byte[] raw = inflate(blob);
        if (raw.length < 4) {
            throw new IllegalArgumentException("M94Z: freq_tables too short");
        }
        ByteBuffer bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        int nActive = bb.getInt();
        int expected = 4 + nActive * (4 + 256 * 2);
        if (raw.length != expected) {
            throw new IllegalArgumentException(
                "M94Z: freq_tables length " + raw.length
                + " != expected " + expected);
        }
        int[] active = new int[nActive];
        int[][] freqs = new int[nActive][];
        for (int i = 0; i < nActive; i++) {
            active[i] = bb.getInt();
            int[] freq = new int[256];
            for (int s = 0; s < 256; s++) {
                freq[s] = bb.getShort() & 0xFFFF;
            }
            freqs[i] = freq;
        }
        return new FreqTables(active, freqs);
    }

    private static final class FreqTables {
        final int[] activeCtxs;
        final int[][] freqArrays;
        FreqTables(int[] a, int[][] f) {
            this.activeCtxs = a; this.freqArrays = f;
        }
    }

    // ── Header pack/unpack ──────────────────────────────────────────

    /** Header field record (pack/unpack only — internal layout). */
    private static final class CodecHeader {
        final int flags;
        final long numQualities;
        final int numReads;
        final int rltCompressedLen;
        final byte[] readLengthTable;
        final ContextParams contextParams;
        final byte[] freqTablesCompressed;
        final long[] stateInit;  // uint32 each, stored as long

        CodecHeader(int flags, long numQualities, int numReads,
                    int rltCompressedLen, byte[] rlt,
                    ContextParams cp, byte[] freqBlob, long[] stateInit) {
            this.flags = flags;
            this.numQualities = numQualities;
            this.numReads = numReads;
            this.rltCompressedLen = rltCompressedLen;
            this.readLengthTable = rlt;
            this.contextParams = cp;
            this.freqTablesCompressed = freqBlob;
            this.stateInit = stateInit;
        }
    }

    /** Fixed prefix: magic(4) + ver(1) + flags(1) + numQ(8) + numR(4)
     *  + rltLen(4) + ctxParams(8) + freqTablesLen(4) = 34 bytes. */
    private static final int HEADER_FIXED_PREFIX =
        4 + 1 + 1 + 8 + 4 + 4 + CONTEXT_PARAMS_SIZE + 4;

    private static byte[] packCodecHeader(CodecHeader h) {
        if (h.readLengthTable.length != h.rltCompressedLen) {
            throw new IllegalArgumentException("rltCompressedLen mismatch");
        }
        // Total length: HEADER_FIXED_PREFIX + rltLen + ftLen + 16 (state_init).
        int totalLen = HEADER_FIXED_PREFIX + h.rltCompressedLen
            + h.freqTablesCompressed.length + 16;
        ByteBuffer bb = ByteBuffer.allocate(totalLen).order(ByteOrder.LITTLE_ENDIAN);
        bb.put(MAGIC);
        bb.put((byte) VERSION);
        bb.put((byte) (h.flags & 0xFF));
        bb.putLong(h.numQualities);
        bb.putInt(h.numReads);
        bb.putInt(h.rltCompressedLen);
        bb.put(packContextParams(h.contextParams));
        bb.putInt(h.freqTablesCompressed.length);
        bb.put(h.readLengthTable);
        bb.put(h.freqTablesCompressed);
        for (int k = 0; k < NUM_STREAMS; k++) {
            bb.putInt((int) (h.stateInit[k] & 0xFFFFFFFFL));
        }
        return bb.array();
    }

    /** Pack a V2 (native-body) header — same layout as V1 EXCEPT
     *  version byte = {@link #VERSION_V2_NATIVE} (=2) and no 16-byte
     *  state_init suffix (V2 body embeds final states at its own
     *  offset 0..15). The {@code stateInit} field on the input
     *  {@link CodecHeader} is ignored. */
    private static byte[] packCodecHeaderV2(CodecHeader h) {
        if (h.readLengthTable.length != h.rltCompressedLen) {
            throw new IllegalArgumentException("rltCompressedLen mismatch");
        }
        // Total length: HEADER_FIXED_PREFIX + rltLen + ftLen (no state_init).
        int totalLen = HEADER_FIXED_PREFIX + h.rltCompressedLen
            + h.freqTablesCompressed.length;
        ByteBuffer bb = ByteBuffer.allocate(totalLen).order(ByteOrder.LITTLE_ENDIAN);
        bb.put(MAGIC);
        bb.put((byte) VERSION_V2_NATIVE);
        bb.put((byte) (h.flags & 0xFF));
        bb.putLong(h.numQualities);
        bb.putInt(h.numReads);
        bb.putInt(h.rltCompressedLen);
        bb.put(packContextParams(h.contextParams));
        bb.putInt(h.freqTablesCompressed.length);
        bb.put(h.readLengthTable);
        bb.put(h.freqTablesCompressed);
        return bb.array();
    }

    private static final class HeaderUnpack {
        final CodecHeader header;
        final int bytesConsumed;
        HeaderUnpack(CodecHeader h, int b) { this.header = h; this.bytesConsumed = b; }
    }

    private static HeaderUnpack unpackCodecHeader(byte[] blob) {
        if (blob.length < HEADER_FIXED_PREFIX) {
            throw new IllegalArgumentException(
                "M94Z header too short: " + blob.length + " bytes");
        }
        for (int i = 0; i < 4; i++) {
            if (blob[i] != MAGIC[i]) {
                throw new IllegalArgumentException(
                    "M94Z bad magic: expected M94Z");
            }
        }
        int version = blob[4] & 0xFF;
        if (version == VERSION_V2_NATIVE) {
            throw new IllegalArgumentException(
                "M94Z V2 stream — call unpackCodecHeaderV2 instead");
        }
        if (version != VERSION) {
            throw new IllegalArgumentException(
                "M94Z unsupported version: " + version);
        }
        int flags = blob[5] & 0xFF;
        ByteBuffer bb = ByteBuffer.wrap(blob, 6, blob.length - 6)
            .order(ByteOrder.LITTLE_ENDIAN);
        long numQ = bb.getLong();
        int numR = bb.getInt();
        int rltLen = bb.getInt();
        int cursor = 6 + 8 + 4 + 4;  // = 22
        ContextParams cp = unpackContextParams(blob, cursor);
        cursor += CONTEXT_PARAMS_SIZE;
        ByteBuffer bb2 = ByteBuffer.wrap(blob, cursor, blob.length - cursor)
            .order(ByteOrder.LITTLE_ENDIAN);
        int ftLen = bb2.getInt();
        cursor += 4;
        if (blob.length < cursor + rltLen + ftLen + 16) {
            throw new IllegalArgumentException("M94Z header truncated");
        }
        byte[] rlt = Arrays.copyOfRange(blob, cursor, cursor + rltLen);
        cursor += rltLen;
        byte[] freqBlob = Arrays.copyOfRange(blob, cursor, cursor + ftLen);
        cursor += ftLen;
        ByteBuffer bb3 = ByteBuffer.wrap(blob, cursor, blob.length - cursor)
            .order(ByteOrder.LITTLE_ENDIAN);
        long[] stateInit = new long[NUM_STREAMS];
        for (int k = 0; k < NUM_STREAMS; k++) {
            stateInit[k] = bb3.getInt() & 0xFFFFFFFFL;
        }
        cursor += 16;
        return new HeaderUnpack(
            new CodecHeader(flags, numQ, numR, rltLen, rlt, cp, freqBlob, stateInit),
            cursor);
    }

    /** Parse a V2 (native-body) header. Returns {@code (header, bodyOffset)}.
     *  The returned {@link CodecHeader#stateInit} is all-zero (V2 stores
     *  states inside the body itself, not in the codec header). */
    private static HeaderUnpack unpackCodecHeaderV2(byte[] blob) {
        if (blob.length < HEADER_FIXED_PREFIX) {
            throw new IllegalArgumentException(
                "M94Z header too short: " + blob.length + " bytes");
        }
        for (int i = 0; i < 4; i++) {
            if (blob[i] != MAGIC[i]) {
                throw new IllegalArgumentException(
                    "M94Z bad magic: expected M94Z");
            }
        }
        int version = blob[4] & 0xFF;
        if (version != VERSION_V2_NATIVE) {
            throw new IllegalArgumentException(
                "unpackCodecHeaderV2: expected version "
                + VERSION_V2_NATIVE + ", got " + version);
        }
        int flags = blob[5] & 0xFF;
        ByteBuffer bb = ByteBuffer.wrap(blob, 6, blob.length - 6)
            .order(ByteOrder.LITTLE_ENDIAN);
        long numQ = bb.getLong();
        int numR = bb.getInt();
        int rltLen = bb.getInt();
        int cursor = 6 + 8 + 4 + 4;  // = 22
        ContextParams cp = unpackContextParams(blob, cursor);
        cursor += CONTEXT_PARAMS_SIZE;
        ByteBuffer bb2 = ByteBuffer.wrap(blob, cursor, blob.length - cursor)
            .order(ByteOrder.LITTLE_ENDIAN);
        int ftLen = bb2.getInt();
        cursor += 4;
        // V2: no 16-byte state_init suffix.
        if (blob.length < cursor + rltLen + ftLen) {
            throw new IllegalArgumentException("M94Z V2 header truncated");
        }
        byte[] rlt = Arrays.copyOfRange(blob, cursor, cursor + rltLen);
        cursor += rltLen;
        byte[] freqBlob = Arrays.copyOfRange(blob, cursor, cursor + ftLen);
        cursor += ftLen;
        long[] stateInit = new long[NUM_STREAMS];  // zeros — not used in V2
        return new HeaderUnpack(
            new CodecHeader(flags, numQ, numR, rltLen, rlt, cp, freqBlob, stateInit),
            cursor);
    }

    // ── DecodeResult ────────────────────────────────────────────────

    public static final class DecodeResult {
        private final byte[] qualities;
        private final int[] readLengths;
        public DecodeResult(byte[] q, int[] rl) {
            this.qualities = q;
            this.readLengths = rl;
        }
        public byte[] qualities() { return qualities; }
        public int[] readLengths() { return readLengths; }
    }

    // ── V4 (CRAM 3.1 fqzcomp) dispatch helpers ──────────────────────

    /**
     * Encode via the M94.Z V4 (CRAM 3.1 fqzcomp) path through JNI.
     * Throws {@link IllegalStateException} if libttio_rans_jni is not loaded.
     */
    private static byte[] encodeV4Internal(byte[] qualities, int[] readLengths,
                                            int[] revcompFlags, int strategyHint,
                                            int padCount) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "encodeV4Internal called but libttio_rans_jni not loaded");
        }
        // Convert revcompFlags 0/1 to SAM-flag byte (bit 4 = SAM_REVERSE).
        int[] samFlags = new int[revcompFlags.length];
        for (int i = 0; i < revcompFlags.length; i++) {
            samFlags[i] = (revcompFlags[i] & 1) != 0 ? 16 : 0;
        }
        return TtioRansNative.encodeV4(qualities, readLengths, samFlags,
                                        strategyHint, padCount);
    }

    /**
     * Decode an M94.Z V4 stream via JNI. Returns the recovered qualities
     * + read_lengths.
     *
     * <p>The V4 outer header carries num_qualities + num_reads + RLT; we
     * parse the first 22 bytes of the stream to extract them so we can
     * pre-allocate buffers.
     */
    private static DecodeResult decodeV4Internal(byte[] encoded, int[] revcompFlags) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "decodeV4Internal called but libttio_rans_jni not loaded");
        }
        // Minimum stream is the 26-byte empty-V4 header (Phase 2c
        // empty-run convention shared with Python + ObjC).
        if (encoded.length < 26 || encoded[0] != 'M' || encoded[1] != '9'
            || encoded[2] != '4' || encoded[3] != 'Z' || encoded[4] != 4) {
            throw new IllegalArgumentException("not an M94.Z V4 stream");
        }
        // Parse num_qualities (uint64 LE @ offset 6) and num_reads (@ offset 14).
        long numQual = 0L, numReads = 0L;
        for (int i = 0; i < 8; i++) numQual  |= ((long)(encoded[6 + i] & 0xFF)) << (8 * i);
        for (int i = 0; i < 8; i++) numReads |= ((long)(encoded[14 + i] & 0xFF)) << (8 * i);
        if (numQual > Integer.MAX_VALUE || numReads > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("V4 stream too large for Java int sizes");
        }
        int nQual  = (int) numQual;
        int nReads = (int) numReads;
        // Empty-run short-circuit (Phase 2c reconciliation): the 26-byte
        // minimal V4 header carries no body; return empty result without
        // dispatching to the native fqzcomp_qual core (which rejects
        // zero-length inputs).
        if (nQual == 0 && nReads == 0) {
            return new DecodeResult(new byte[0], new int[0]);
        }
        if (revcompFlags == null) revcompFlags = new int[nReads];
        if (revcompFlags.length != nReads) {
            throw new IllegalArgumentException(
                "revcompFlags length " + revcompFlags.length + " != numReads " + nReads);
        }
        int[] samFlags = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            samFlags[i] = (revcompFlags[i] & 1) != 0 ? 16 : 0;
        }
        Object[] result = TtioRansNative.decodeV4(encoded, nReads, nQual, samFlags);
        byte[] qual = (byte[]) result[0];
        int[]  lens = (int[])  result[1];
        return new DecodeResult(qual, lens);
    }

    // ── Top-level encoder ───────────────────────────────────────────

    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags) {
        return encode(qualities, readLengths, revcompFlags,
                      ContextParams.defaults(), null);
    }

    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags, EncodeOptions opts) {
        return encode(qualities, readLengths, revcompFlags,
                      ContextParams.defaults(), opts);
    }

    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags, ContextParams params) {
        return encode(qualities, readLengths, revcompFlags, params, null);
    }

    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags, ContextParams params,
                                EncodeOptions opts) {
        if (qualities == null) {
            throw new IllegalArgumentException("qualities must not be null");
        }
        if (readLengths.length != revcompFlags.length) {
            throw new IllegalArgumentException(
                "readLengths (" + readLengths.length + ") != revcompFlags ("
                + revcompFlags.length + ")");
        }
        long total = 0L;
        for (int v : readLengths) total += v;
        if (total != qualities.length) {
            throw new IllegalArgumentException(
                "sum(readLengths) (" + total + ") != qualities.length ("
                + qualities.length + ")");
        }
        if (params == null) params = ContextParams.defaults();

        int n = qualities.length;
        int padCount = (-n) & 3;

        // v1.0 reset Phase 2c: only V4 (CRAM 3.1 fqzcomp_qual) is
        // emitted now. The V1 (pure-Java) and V2 (libttio_rans body)
        // encoder dispatch paths were removed. The opts.preferV4 and
        // opts.preferNative knobs are accepted for API compatibility
        // but only the V4 path is exercised. Requires libttio_rans_jni
        // to be loaded; raises IllegalStateException otherwise.
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "FQZCOMP_NX16_Z encode requires the native libttio_rans "
                + "library to be linked. Build with -Dttio.native=true "
                + "or install the native package. (The V1 / V2 encoder "
                + "fallback paths were removed in Phase 2c — only V4 "
                + "(CRAM 3.1 fqzcomp_qual) is emitted in v1.0+.)");
        }
        // Empty-run short-circuit (Phase 2c reconciliation): the native
        // V4 fqzcomp_qual core rejects zero-length inputs. Synthesise a
        // minimal 26-byte V4 outer header so readers can still dispatch
        // by version byte. Layout per m94z_v4_wire.h: magic(4) +
        // version(1) + flags(1) + num_qualities(8) + num_reads(8) +
        // rlt_compressed_len(4) = 26 bytes total. Cross-language
        // convention shared with Python and ObjC.
        if (n == 0) {
            byte[] hdr = new byte[26];
            hdr[0] = 'M'; hdr[1] = '9'; hdr[2] = '4'; hdr[3] = 'Z';
            hdr[4] = 4;                       // VERSION_V4_FQZCOMP
            hdr[5] = (byte) ((padCount & 0x3) << 4);
            // num_qualities (LE uint64) at offset 6 — already zero
            // num_reads     (LE uint64) at offset 14 — already zero
            // rlt_compressed_len (LE uint32) at offset 22 — already zero
            return hdr;
        }
        int strategy = (opts != null && opts.v4StrategyHint != null)
            ? opts.v4StrategyHint : -1;
        return encodeV4Internal(qualities, readLengths, revcompFlags,
                                 strategy, padCount);
    }


    // ── V2 native dispatch (encode) ─────────────────────────────────

    /**
     * V2 (libttio_rans-format) encode dispatch.
     *
     * <p>Builds context sequence + per-context freq tables (same as V1),
     * remaps sparse context IDs to a dense [0, nActive) range so the
     * native encoder's freq table is compact, calls
     * {@link TtioRansNative#encodeBlock}, then packs a V2 wire-format
     * header plus the native body. The freq_tables blob still uses
     * ORIGINAL (sparse) context IDs so V2 decode can reconstruct
     * contexts using the unchanged M94.Z context model.
     */
    private static byte[] encodeV2Native(byte[] qualities, int[] readLengths,
                                          int[] revcompFlags,
                                          ContextParams params,
                                          int n, int nPadded, int padCount) {
        // Pass 1: build context sequence + per-context counts.
        int[] contexts = buildContextSeq(qualities, readLengths, revcompFlags,
                                          nPadded, params.qbits, params.pbits,
                                          params.sloc);
        int ctxCap = 1 << params.sloc;
        int[][] rawCounts = new int[ctxCap][];
        for (int i = 0; i < nPadded; i++) {
            int ctx = contexts[i];
            int[] arr = rawCounts[ctx];
            if (arr == null) {
                arr = new int[256];
                rawCounts[ctx] = arr;
            }
            int sym = (i < n) ? (qualities[i] & 0xFF) : 0;
            arr[sym]++;
        }

        // Normalise per-context, count active, pack into sorted-by-ctx arrays.
        int[][] freqByCtx = new int[ctxCap][];
        int active = 0;
        for (int c = 0; c < ctxCap; c++) {
            if (rawCounts[c] == null) continue;
            freqByCtx[c] = normaliseToTotal(rawCounts[c], T);
            active++;
        }

        // Build active-ctxs / freq-arrays sidecar AND remap ctx → dense index.
        int[] activeCtxs = new int[active];
        int[][] denseFreq = new int[active][];
        // ctxRemap maps sparse ctx id → dense index in [0, active).
        // Use a flat int[] indexed by sparse id, set to -1 for absent.
        int[] ctxRemap = new int[ctxCap];
        Arrays.fill(ctxRemap, -1);
        int j = 0;
        for (int c = 0; c < ctxCap; c++) {
            if (freqByCtx[c] != null) {
                activeCtxs[j] = c;
                denseFreq[j] = freqByCtx[c];
                ctxRemap[c] = j;
                j++;
            }
        }
        if (active == 0 || active > 0xFFFF) {
            throw new IllegalStateException(
                "M94Z V2: nActive (" + active + ") must be in [1, 65535]");
        }

        // Build dense (remapped) contexts + symbol buffer (with zero padding).
        short[] denseContexts = new short[nPadded];
        for (int i = 0; i < nPadded; i++) {
            int dense = ctxRemap[contexts[i]];
            // dense fits in uint16 since active <= 65535.
            denseContexts[i] = (short) (dense & 0xFFFF);
        }
        byte[] symbols = new byte[nPadded];
        System.arraycopy(qualities, 0, symbols, 0, n);
        // Padding bytes already 0.

        // Native encode (V2 byte format).
        // Worst case: header(32) + 4 bytes per padded symbol + slack.
        int outCap = Math.max(64, nPadded * 4 + 64);
        byte[] outBuf = new byte[outCap];
        int[] outLen = new int[]{outCap};
        int rc = TtioRansNative.encodeBlock(
            symbols, denseContexts, active, denseFreq, outBuf, outLen);
        if (rc != 0) {
            throw new IllegalStateException(
                "M94Z V2: ttio_rans_encode_block failed: rc=" + rc);
        }
        byte[] nativeBody = Arrays.copyOf(outBuf, outLen[0]);

        // Wire format: header (V2) + native body. No trailer.
        byte[] rlt = encodeReadLengths(readLengths);
        byte[] freqBlob = serializeFreqTables(activeCtxs, denseFreq, params.sloc);
        int flags = (padCount & 0x3) << 4;
        long[] zeroStateInit = new long[NUM_STREAMS];  // unused for V2

        CodecHeader header = new CodecHeader(
            flags, n, readLengths.length, rlt.length,
            rlt, params, freqBlob, zeroStateInit);
        byte[] headerBytes = packCodecHeaderV2(header);

        byte[] out = new byte[headerBytes.length + nativeBody.length];
        System.arraycopy(headerBytes, 0, out, 0, headerBytes.length);
        System.arraycopy(nativeBody, 0, out,
                         headerBytes.length, nativeBody.length);
        return out;
    }

    // ── Top-level decoder ───────────────────────────────────────────

    public static DecodeResult decode(byte[] encoded, int[] revcompFlags) {
        if (encoded == null) {
            throw new IllegalArgumentException("encoded must not be null");
        }
        if (encoded.length < 5) {
            throw new IllegalArgumentException(
                "M94Z: encoded too short to read magic+version");
        }
        for (int i = 0; i < 4; i++) {
            if (encoded[i] != MAGIC[i]) {
                throw new IllegalArgumentException(
                    "M94Z bad magic: expected M94Z");
            }
        }
        int versionByte = encoded[4] & 0xFF;
        if (versionByte == VERSION_V4_FQZCOMP) {
            return decodeV4Internal(encoded, revcompFlags);
        }
        // v1.0 reset Phase 2c: V1 (pure-Java rANS-Nx16) and V2
        // (libttio_rans body) decoder dispatch removed. Files written
        // with those internal flavours are no longer decodable; callers
        // must re-encode through V4 (CRAM 3.1 fqzcomp_qual).
        if (versionByte == VERSION || versionByte == VERSION_V2_NATIVE
                || versionByte == 3 /* V3 = adaptive Range Coder */) {
            throw new IllegalStateException(
                "FQZCOMP_NX16_Z V1/V2/V3 are no longer supported in "
                + "v1.0; only V4 (CRAM 3.1 fqzcomp_qual) is decoded. "
                + "Re-encode the file with v1.0+. (Got version byte "
                + versionByte + ".)");
        }
        throw new IllegalArgumentException(
            "M94Z unsupported version byte: " + versionByte
            + " (only V4 = 4 is recognised in v1.0+)");
    }


    // ── V2 native dispatch (decode) ─────────────────────────────────

    /**
     * Decode a V2 (libttio_rans-body) M94.Z blob.
     *
     * <p>The default path is pure-Java. When the env var
     * {@code TTIO_M94Z_USE_NATIVE_STREAMING=1} is set AND the
     * libttio_rans JNI library is available, dispatch first attempts
     * native streaming decode via {@link #decodeV2ViaNativeStreaming},
     * which routes the inner rANS loop through the C kernel using a
     * per-symbol Java {@link TtioRansNative.ContextResolver} callback
     * (Task 26c). On any error from the streaming path it falls back
     * to the pure-Java decoder.
     *
     * <p><b>Performance reality (Task 26c)</b>: per-symbol JNI dispatch
     * is much heavier than the pure-Java decode loop. The streaming path
     * is shipped as infrastructure proving the C streaming context API
     * works end-to-end across all bindings; for realistic blocks the
     * pure-Java path is faster. Mirrors the Task 26b finding in Python.
     * The streaming path is also less defensive about corrupt streams —
     * the C library does not validate the post-decode final state. So
     * the streaming path is opt-in and not the default.
     *
     * <p>The pure-Java path parses the V2 body byte format (per
     * {@code rans_encode_scalar.c}) and walks forward with on-the-fly
     * context derivation. V1 decode (above) remains the same pure-Java
     * path.
     */
    private static DecodeResult decodeV2(byte[] encoded, int[] revcompFlags) {
        if (preferNativeStreamingDecode() && TtioRansNative.isAvailable()) {
            try {
                DecodeResult r = decodeV2ViaNativeStreaming(encoded, revcompFlags);
                if (r != null) return r;
            } catch (Throwable t) {
                // Fall through to pure-Java decode.
            }
        }
        return decodeV2PureJava(encoded, revcompFlags);
    }

    /** Reads {@code TTIO_M94Z_USE_NATIVE_STREAMING} env var (truthy = enabled). */
    private static boolean preferNativeStreamingDecode() {
        String s = System.getenv("TTIO_M94Z_USE_NATIVE_STREAMING");
        if (s == null) return false;
        s = s.trim().toLowerCase();
        return s.equals("1") || s.equals("true") || s.equals("yes") || s.equals("on");
    }

    /**
     * Test-only entry point: force-decode a V2 blob via the native
     * streaming path, bypassing the env-var guard. Returns {@code null}
     * if the streaming path declines (unparseable blob, native lib
     * unavailable, or the resolver returns out-of-range ctx). Throws if
     * any underlying validation throws.
     *
     * <p>Visible to tests in the same package; not part of the public
     * API.
     */
    static DecodeResult decodeV2ForceNativeStreamingForTest(byte[] encoded, int[] revcompFlags) {
        if (!TtioRansNative.isAvailable()) return null;
        return decodeV2ViaNativeStreaming(encoded, revcompFlags);
    }

    /**
     * Decode a V2 body via the libttio_rans streaming context API.
     *
     * <p>Mirrors the Python {@code _decode_v2_via_native_streaming} helper
     * (Task 26b). Builds a dense ctx remap, flat freq/cum tables, then
     * invokes {@link TtioRansNative#decodeBlockStreaming} with a Java
     * lambda that derives the M94.Z context for each position from
     * read-tracking state and the just-decoded symbol.
     *
     * <p>Returns {@code null} on any unexpected internal condition; the
     * caller treats {@code null} or a thrown exception as a fallback
     * trigger.
     */
    private static DecodeResult decodeV2ViaNativeStreaming(
            byte[] encoded, int[] revcompFlags) {
        HeaderUnpack hu = unpackCodecHeaderV2(encoded);
        CodecHeader header = hu.header;
        int bodyOff = hu.bytesConsumed;

        long nQ64 = header.numQualities;
        if (nQ64 < 0 || nQ64 > Integer.MAX_VALUE) return null;
        int nQualities = (int) nQ64;
        int nReads = header.numReads;
        int padCount = (header.flags >>> 4) & 0x3;

        int[] readLengths = decodeReadLengths(header.readLengthTable, nReads);
        if (revcompFlags == null) revcompFlags = new int[nReads];
        else if (revcompFlags.length != nReads) return null;

        int nPadded = nQualities + padCount;
        if ((nPadded & 3) != 0) return null;

        int bodyLen = encoded.length - bodyOff;
        if (bodyLen < 32) return null;

        // Recover sparse freq tables (still keyed by ORIGINAL sparse ctx id).
        FreqTables ft = deserializeFreqTables(header.freqTablesCompressed);
        final int qbits = header.contextParams.qbits;
        final int pbits = header.contextParams.pbits;
        final int sloc  = header.contextParams.sloc;

        // Build dense (sorted-by-ctx) freq + cum tables for libttio_rans
        // and a sparse_ctx → dense_idx remap mirroring the encoder.
        int nContexts = ft.activeCtxs.length;
        if (nContexts == 0 || nContexts > 0xFFFF) return null;

        int ctxCap = 1 << sloc;
        int[] ctxRemap = new int[ctxCap];
        Arrays.fill(ctxRemap, -1);
        int[][] freqDense = new int[nContexts][];
        int[][] cumDense  = new int[nContexts][];
        for (int i = 0; i < nContexts; i++) {
            int sparse = ft.activeCtxs[i];
            int[] freq = ft.freqArrays[i];
            int[] cum  = new int[256];
            int running = 0;
            for (int s = 0; s < 256; s++) {
                cum[s] = running;
                running += freq[s];
            }
            freqDense[i] = freq;
            cumDense[i]  = cum;
            ctxRemap[sparse] = i;
        }

        // The encoder uses dense_pad_ctx for padding positions, but the C
        // streaming decoder hardcodes ctx=0 for those (matching the
        // pre-existing rans_decode_scalar contract). Both encoder and
        // decoder agree on padding bytes being sym=0, ctx=0, so no
        // resolver call is needed there.
        int padCtxSparse = m94zContext(0, 0, 0, qbits, pbits, sloc);
        final int padCtxDense = ctxRemap[padCtxSparse]; // unused, kept for parity

        // Slice out the body bytes; the streaming decode entry point
        // expects raw V2 body (4×state + 4×lane_size + lane data).
        byte[] body = Arrays.copyOfRange(encoded, bodyOff, encoded.length);

        byte[] out = new byte[nPadded];

        // Mutable resolver state.  Boxed in a length-1 array so the
        // lambda can mutate.  Layout: [readIdx, posInRead, curReadLen,
        // curRevcomp, cumulativeReadEnd, prevQ].
        final int[] state = new int[6];
        state[2] = readLengths.length > 0 ? readLengths[0] : 0;
        state[3] = revcompFlags.length > 0 ? revcompFlags[0] : 0;
        state[4] = state[2];

        final int[] readLengthsF = readLengths;
        final int[] revcompFlagsF = revcompFlags;
        final int shift = Math.max(1, qbits / 3);
        final int qmaskLocal = (1 << qbits) - 1;
        final int symMask = (1 << shift) - 1;
        final int nQ = nQualities;
        final int[] ctxRemapF = ctxRemap;

        TtioRansNative.ContextResolver resolver = (i, prevSym) -> {
            // Called BEFORE decoding symbol[i].  prevSym is the symbol
            // decoded at i-1 (or 0 for i==0).
            if (i >= nQ) {
                // Padding ctx — but the C streaming decoder does NOT
                // call us for i >= n_symbols (passes 0 internally), so
                // this branch is defensive only.
                return padCtxDense;
            }

            if (i > 0) {
                state[5] = ((state[5] << shift) | (prevSym & symMask)) & qmaskLocal;
                state[1]++;  // posInRead
            }

            // Read-boundary check (mirrors Python and pure-Java decoder).
            if (i > 0 && i >= (long)state[4]
                    && state[0] < readLengthsF.length - 1) {
                state[0]++;                              // readIdx
                state[1] = 0;                            // posInRead
                state[2] = readLengthsF[state[0]];       // curReadLen
                state[3] = revcompFlagsF[state[0]];      // curRevcomp
                state[4] += state[2];                    // cumulativeReadEnd
                state[5] = 0;                            // prevQ
            }

            int pb = positionBucketPbits(state[1], state[2], pbits);
            int ctxSparse = m94zContext(state[5], pb, state[3] & 1, qbits, pbits, sloc);
            int dense = ctxRemapF[ctxSparse];
            if (dense < 0) return padCtxDense; // defensive fallback
            return dense;
        };

        int rc = TtioRansNative.decodeBlockStreaming(
            body, nContexts, freqDense, cumDense, out, nPadded, resolver);
        if (rc != 0) return null;

        byte[] qualities = Arrays.copyOf(out, nQualities);
        return new DecodeResult(qualities, readLengths);
    }

    private static DecodeResult decodeV2PureJava(byte[] encoded, int[] revcompFlags) {
        HeaderUnpack hu = unpackCodecHeaderV2(encoded);
        CodecHeader header = hu.header;
        int bodyOff = hu.bytesConsumed;

        long nQ64 = header.numQualities;
        if (nQ64 < 0 || nQ64 > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "M94Z V2: numQualities out of range: " + nQ64);
        }
        int nQualities = (int) nQ64;
        int nReads = header.numReads;
        int padCount = (header.flags >>> 4) & 0x3;

        int[] readLengths = decodeReadLengths(header.readLengthTable, nReads);

        if (revcompFlags == null) revcompFlags = new int[nReads];
        else if (revcompFlags.length != nReads) {
            throw new IllegalArgumentException(
                "revcompFlags length " + revcompFlags.length
                + " != numReads " + nReads);
        }

        int nPadded = nQualities + padCount;
        if ((nPadded & 3) != 0) {
            throw new IllegalArgumentException(
                "M94Z V2: nPadded " + nPadded + " not a multiple of 4");
        }

        int bodyLen = encoded.length - bodyOff;
        if (bodyLen < 32) {
            throw new IllegalArgumentException(
                "M94Z V2: body shorter than native header");
        }

        // Recover sparse freq tables (still keyed by ORIGINAL sparse ctx id).
        FreqTables ft = deserializeFreqTables(header.freqTablesCompressed);
        int qbits = header.contextParams.qbits;
        int pbits = header.contextParams.pbits;
        int sloc = header.contextParams.sloc;
        int ctxCap = 1 << sloc;
        int[][] freqByCtx = new int[ctxCap][];
        int[][] cumByCtx = new int[ctxCap][];
        for (int i = 0; i < ft.activeCtxs.length; i++) {
            int c = ft.activeCtxs[i];
            int[] freq = ft.freqArrays[i];
            freqByCtx[c] = freq;
            cumByCtx[c] = cumulative(freq);
        }

        // Parse V2 body header: [0..15] 4×uint32 LE final states,
        // [16..31] 4×uint32 LE lane sizes, [32..] per-lane data.
        ByteBuffer bb = ByteBuffer.wrap(encoded, bodyOff, bodyLen)
            .order(ByteOrder.LITTLE_ENDIAN);
        long[] state = new long[NUM_STREAMS];
        for (int k = 0; k < NUM_STREAMS; k++) {
            state[k] = bb.getInt() & 0xFFFFFFFFL;
        }
        int[] laneBytes = new int[NUM_STREAMS];
        long totalData = 0L;
        for (int k = 0; k < NUM_STREAMS; k++) {
            laneBytes[k] = bb.getInt();
            if (laneBytes[k] < 0) {
                throw new IllegalArgumentException(
                    "M94Z V2: lane " + k + " size " + laneBytes[k] + " is negative");
            }
            totalData += laneBytes[k];
        }
        if (bodyLen < 32L + totalData) {
            throw new IllegalArgumentException(
                "M94Z V2: body truncated (have " + bodyLen
                + ", need " + (32L + totalData) + ")");
        }

        // Per-lane sub-buffer offsets into encoded[].
        int[] laneStart = new int[NUM_STREAMS];
        int[] lanePos = new int[NUM_STREAMS];
        int laneOff = bodyOff + 32;
        for (int k = 0; k < NUM_STREAMS; k++) {
            laneStart[k] = laneOff;
            laneOff += laneBytes[k];
        }

        byte[] out = new byte[nPadded];
        int padCtx = m94zContext(0, 0, 0, qbits, pbits, sloc);
        int shift = Math.max(1, qbits / 3);
        int qmaskLocal = (1 << qbits) - 1;
        int symMask = (1 << shift) - 1;

        int readIdx = 0;
        int posInRead = 0;
        int curReadLen = readLengths.length > 0 ? readLengths[0] : 0;
        int curRevcomp = revcompFlags.length > 0 ? revcompFlags[0] : 0;
        int cumulativeReadEnd = curReadLen;
        int prevQ = 0;

        for (int i = 0; i < nPadded; i++) {
            int sIdx = i & 3;
            int ctx;
            if (i < nQualities) {
                if (i >= cumulativeReadEnd
                    && readIdx < readLengths.length - 1) {
                    readIdx++;
                    posInRead = 0;
                    curReadLen = readLengths[readIdx];
                    curRevcomp = revcompFlags[readIdx];
                    cumulativeReadEnd += curReadLen;
                    prevQ = 0;
                }
                int pb = positionBucketPbits(posInRead, curReadLen, pbits);
                ctx = m94zContext(prevQ, pb, curRevcomp & 1, qbits, pbits, sloc);
            } else {
                ctx = padCtx;
            }

            int[] freq = freqByCtx[ctx];
            int[] cum = cumByCtx[ctx];
            if (freq == null) {
                throw new IllegalArgumentException(
                    "M94Z V2 decoder: ctx " + ctx + " not in freq_tables");
            }

            long x = state[sIdx];
            int slot = (int) (x & T_MASK);

            // bisect_right(cum, slot) - 1 over cum[1..256].
            int lo = 1, hi = 257;
            while (lo < hi) {
                int mid = (lo + hi) >>> 1;
                if (cum[mid] <= slot) lo = mid + 1;
                else hi = mid;
            }
            int sym = lo - 1;
            int f = freq[sym];
            int c = cum[sym];
            x = (long) f * (x >>> T_BITS) + (long) slot - (long) c;

            // Renormalise: read 16-bit LE chunks while x < L.
            int p = lanePos[sIdx];
            int laneEnd = laneBytes[sIdx];
            int laneBase = laneStart[sIdx];
            while (x < L) {
                if (p + 2 > laneEnd) {
                    throw new IllegalArgumentException(
                        "M94Z V2: lane " + sIdx + " exhausted at i=" + i);
                }
                int chunk = (encoded[laneBase + p] & 0xFF)
                    | ((encoded[laneBase + p + 1] & 0xFF) << 8);
                p += 2;
                x = (x << B_BITS) | (long) chunk;
            }
            lanePos[sIdx] = p;
            state[sIdx] = x;
            out[i] = (byte) sym;

            if (i < nQualities) {
                prevQ = ((prevQ << shift) | (sym & symMask)) & qmaskLocal;
                posInRead++;
            }
        }

        // Sanity: post-decode states should equal L (encoder's initial state).
        for (int k = 0; k < NUM_STREAMS; k++) {
            if (state[k] != (long) L) {
                throw new IllegalArgumentException(
                    "M94Z V2: post-decode state[" + k + "]=" + state[k]
                    + " != L=" + L + "; stream is corrupt");
            }
            if (lanePos[k] != laneBytes[k]) {
                throw new IllegalArgumentException(
                    "M94Z V2: lane " + k + " consumed " + lanePos[k]
                    + " of " + laneBytes[k] + " bytes; stream may be malformed");
            }
        }

        byte[] qualities = Arrays.copyOf(out, nQualities);
        return new DecodeResult(qualities, readLengths);
    }
}
