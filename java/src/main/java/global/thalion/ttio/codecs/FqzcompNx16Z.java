/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

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

    // ── Wire-format constants ───────────────────────────────────────

    public static final byte[] MAGIC = new byte[]{'M', '9', '4', 'Z'};
    /** M94.Z V1 wire-format version (legacy pure-Java rANS-Nx16).
     *  No longer decodable — retained so {@link #decode} can recognise and
     *  reject legacy streams. */
    public static final int VERSION = 1;
    /** M94.Z V2 wire-format version (legacy libttio_rans body).
     *  No longer decodable — retained so {@link #decode} can recognise and
     *  reject legacy streams. */
    public static final int VERSION_V2_NATIVE = 2;
    /** M94.Z V4 wire-format version: CRAM 3.1 fqzcomp port (Stage 2/3).
     *  The only version emitted and decoded in v1.0+. */
    public static final int VERSION_V4_FQZCOMP = 4;
    /** Env var that overrides the default M94.Z dispatch version
     *  ("1"/"2"/"3" → force pre-V4 path; "4" → force V4). */
    public static final String ENV_VERSION_OVERRIDE = "TTIO_M94Z_VERSION";

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

        // only V4 (CRAM 3.1 fqzcomp_qual) is
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
        // V1 (pure-Java rANS-Nx16) and V2
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
}
