/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * FQZCOMP_NX16.Z — lossless quality codec (M94.Z), V4 wire format only.
 *
 * <p>This class is a thin JNI wrapper over the native {@code libttio_rans}
 * CRAM-3.1 {@code fqzcomp_qual} core. It emits and decodes only the M94.Z
 * <b>V4</b> wire format (magic {@code M94Z}, version byte {@code 4}); the
 * legacy V1/V2/V3 dispatch paths were removed in Phase 2c and are rejected
 * on decode.
 *
 * <p>The native library is required for both encode and decode: when
 * libttio_rans_jni is not on {@code java.library.path}, encode/decode throw
 * {@link IllegalStateException}. There is no pure-Java fallback.
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

    /** M94.Z V5: sequence-context body, emitted only when it beats V4
     *  by exact size (spec
     *  docs/superpowers/specs/2026-08-16-qualities-v5-design.md). */
    public static final int VERSION_V5_SEQCTX = 5;

    /** Strategy hint: V4 with its internal preset selection, sequences
     *  ignored (kernel TTIO_M94Z_HINT_V4_AUTO). -1 auto, 0..4 V4
     *  preset, 5..6 forced V5. */
    public static final int HINT_V4_AUTO = 7;

    /** M94.Z V6: segmented adaptive body, decoded without sequences
     *  (docs/codecs/m94z_v6.md). */
    public static final int VERSION_V6_SEGMENTED = 6;

    /** Strategy hint: force V6. Auto-tune never selects it, because V6
     *  does not beat V4 or V5 on size and must stay out of the size
     *  race; it is reached by this hint, or by writer policy. */
    public static final int HINT_V6 = 8;

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
     *       {@code java.library.path}; in this state encode/decode throw
     *       {@link IllegalStateException} (there is no pure-Java fallback).</li>
     * </ul>
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
     * Encoder options bag. The only effective knob is
     * {@link #v4StrategyHint(int)}, which selects the V4 (CRAM 3.1
     * fqzcomp) strategy preset ({@code -1} = auto-tune; {@code 0..3} =
     * explicit preset).
     *
     * <p>{@link #preferNative(boolean)} and {@link #preferV4(boolean)} are
     * retained for source/ABI backward compatibility but are <b>ignored</b>:
     * only the V4 wire format is ever emitted (the legacy V1/V2 dispatch
     * paths were removed in Phase 2c).
     */
    public static final class EncodeOptions {
        // Retained for backward compatibility; ignored — only V4 is emitted.
        Boolean preferNative = null;

        // Retained for backward compatibility; ignored — only V4 is emitted.
        Boolean preferV4 = null;
        // v4StrategyHint: null = -1 (auto-tune); 0..3 = explicit preset.
        Integer v4StrategyHint = null;

        /** Accepted for backward compatibility; ignored — only V4 is emitted. */
        public EncodeOptions preferNative(boolean v) {
            this.preferNative = v;
            return this;
        }

        /** Accepted for backward compatibility; ignored — only V4 is emitted. */
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
    private static byte[] encodeQualInternal(byte[] qualities, int[] readLengths,
                                              int[] revcompFlags,
                                              byte[] sequences,
                                              int strategyHint,
                                              int padCount) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "encodeQualInternal called but libttio_rans_jni not loaded");
        }
        // Convert revcompFlags 0/1 to SAM-flag byte (bit 4 = SAM_REVERSE).
        int[] samFlags = new int[revcompFlags.length];
        for (int i = 0; i < revcompFlags.length; i++) {
            samFlags[i] = (revcompFlags[i] & 1) != 0 ? 16 : 0;
        }
        return TtioRansNative.encodeQual(qualities, readLengths, samFlags,
                                          sequences, strategyHint, padCount);
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

    /** V5 decode: same outer-header parse as V4 (identical layout),
     *  dispatched through the native umbrella with the sequences
     *  side input. */
    private static DecodeResult decodeQualInternal(byte[] encoded,
                                                   int[] revcompFlags,
                                                   byte[] sequences) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "decodeQualInternal called but libttio_rans_jni not loaded");
        }
        int ver = encoded.length >= 5 ? (encoded[4] & 0xFF) : -1;
        if (encoded.length < 26 || encoded[0] != 'M' || encoded[1] != '9'
            || encoded[2] != '4' || encoded[3] != 'Z'
            || (ver != VERSION_V5_SEQCTX && ver != VERSION_V6_SEGMENTED)) {
            throw new IllegalArgumentException("not an M94.Z V5 or V6 stream");
        }
        long numQual = 0L, numReads = 0L;
        for (int i = 0; i < 8; i++) numQual  |= ((long)(encoded[6 + i] & 0xFF)) << (8 * i);
        for (int i = 0; i < 8; i++) numReads |= ((long)(encoded[14 + i] & 0xFF)) << (8 * i);
        if (numQual > Integer.MAX_VALUE || numReads > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "M94Z stream too large for Java int sizes");
        }
        int nQual  = (int) numQual;
        int nReads = (int) numReads;
        // V5 always needs the sequences side input. V6 needs it only
        // when its header carries a sequence-context width, which the
        // native decoder reads for itself, so pass whatever the caller
        // has and let the stream decide. A width of 0 ignores them.
        if (ver == VERSION_V5_SEQCTX
                && (sequences == null || sequences.length != nQual)) {
            throw new IllegalArgumentException(
                "M94Z V5: sequences length ("
                + (sequences == null ? "null" : sequences.length)
                + ") != num_qualities (" + nQual + ")");
        }
        if (ver == VERSION_V6_SEGMENTED
                && sequences != null && sequences.length != nQual) {
            sequences = null;
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
        Object[] result = TtioRansNative.decodeQual(encoded, nReads, nQual,
                                                    samFlags, sequences);
        return new DecodeResult((byte[]) result[0], (int[]) result[1]);
    }

    // ── Top-level encoder ───────────────────────────────────────────

    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags) {
        return encode(qualities, readLengths, revcompFlags,
                      ContextParams.defaults(), null);
    }

    /**
     * Encode with the V5 sequence-context strategies eligible.
     * {@code sequences} must be base bytes parallel to
     * {@code qualities}; the encoder keeps the smaller of the best V4
     * and sequence-context streams, so the output is version 5 only
     * when sequence context won. {@code null} keeps V4-only behaviour
     * byte for byte.
     */
    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags, byte[] sequences) {
        return encodeWithSequences(qualities, readLengths, revcompFlags,
                                   sequences, null);
    }

    /** Sequences-aware encode with options ({@code v4StrategyHint}
     *  selects or pins the strategy; see {@link #HINT_V4_AUTO}). */
    public static byte[] encode(byte[] qualities, int[] readLengths,
                                int[] revcompFlags, byte[] sequences,
                                EncodeOptions opts) {
        return encodeWithSequences(qualities, readLengths, revcompFlags,
                                   sequences, opts);
    }

    public static int streamStrategy(byte[] stream) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "FQZCOMP_NX16_Z streamStrategy requires libttio_rans_jni");
        }
        int rc = TtioRansNative.qualStreamStrategy(stream);
        if (rc < 0) {
            throw new IllegalArgumentException(
                "not an M94.Z qualities stream (rc=" + rc + ")");
        }
        return rc;
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

    /**
     * Encode qualities to the M94.Z V4 wire format.
     *
     * <p>{@code params} is accepted for API compatibility; the V4 codec
     * derives contexts internally and ignores it.
     */
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
        return encodeQualInternal(qualities, readLengths, revcompFlags,
                                   null, strategy, padCount);
    }

    /** Shared body for the sequences-aware overloads. */
    private static byte[] encodeWithSequences(byte[] qualities,
                                              int[] readLengths,
                                              int[] revcompFlags,
                                              byte[] sequences,
                                              EncodeOptions opts) {
        if (sequences != null && sequences.length != qualities.length) {
            throw new IllegalArgumentException(
                "sequences length (" + sequences.length
                + ") != qualities length (" + qualities.length
                + "); the V5 sequence context needs one base per quality");
        }
        if (sequences == null || qualities.length == 0) {
            return encode(qualities, readLengths, revcompFlags,
                          ContextParams.defaults(), opts);
        }
        if (readLengths.length != revcompFlags.length) {
            throw new IllegalArgumentException(
                "readLengths (" + readLengths.length + ") != revcompFlags ("
                + revcompFlags.length + ")");
        }
        int n = qualities.length;
        int padCount = (-n) & 3;
        int strategy = (opts != null && opts.v4StrategyHint != null)
            ? opts.v4StrategyHint : -1;
        return encodeQualInternal(qualities, readLengths, revcompFlags,
                                   sequences, strategy, padCount);
    }

    // ── Top-level decoder ───────────────────────────────────────────

    /**
     * Decode with the run's decoded sequences available for V5 streams.
     * The supplier is invoked only when the stream's version byte is 5;
     * a V5 stream decoded through the 2-arg overload (no supplier)
     * throws {@link IllegalStateException} naming the requirement.
     */
    public static DecodeResult decode(byte[] encoded, int[] revcompFlags,
                                      java.util.function.Supplier<byte[]> sequencesProvider) {
        /* A V6 stream needs the sequences only when its header carries a
         * sequence-context width, which the native decoder reads for
         * itself. A provider is therefore used when there is one and
         * never demanded: a width of 0, which is every stream written
         * before the field existed, decodes without one. */
        if (encoded != null && encoded.length >= 5
                && (encoded[4] & 0xFF) == VERSION_V6_SEGMENTED) {
            return decodeQualInternal(encoded, revcompFlags,
                sequencesProvider == null ? null : sequencesProvider.get());
        }
        if (encoded != null && encoded.length >= 5
                && (encoded[4] & 0xFF) == VERSION_V5_SEQCTX) {
            if (sequencesProvider == null) {
                throw new IllegalStateException(
                    "M94Z V5 stream requires sequences: pass a "
                    + "sequencesProvider returning the run's decoded "
                    + "sequences bytes");
            }
            return decodeQualInternal(encoded, revcompFlags,
                                      sequencesProvider.get());
        }
        return decode(encoded, revcompFlags);
    }

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
        if (versionByte == VERSION_V6_SEGMENTED) {
            return decodeQualInternal(encoded, revcompFlags, null);
        }
        if (versionByte == VERSION_V5_SEQCTX) {
            throw new IllegalStateException(
                "M94Z V5 stream requires sequences: use "
                + "decode(encoded, revcompFlags, sequencesProvider)");
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

    /** Threads the FQZCOMP auto-tune uses for its candidate encodes
     *  (default 3; {@code n <= 1} runs them in sequence). No-op when the
     *  native library is absent. */
    /** Ask the encoder to choose the sequence-context width per block. */
    public static final int V6_SBITS_AUTO = 255;

    /** Width of M94.Z V6's sequence-context field for streams this process writes. 0, the default, is the context V6 shipped with and needs no sequences to decode. 255 asks the encoder to pick per block, coding a prefix of the block's first segment each way. Any other value is used as given, and encoding without sequences then fails rather than dropping the field silently. The width travels in the stream, so decoding never consults it.
     *
     *  <p>No-op when the native library is absent. Python:
     *  {@code ttio.codecs.fqzcomp_nx16_z.set_v6_sbits}; Objective-C:
     *  {@code +[TTIOFqzcompNx16Z setV6SequenceContextBits:]}. */
    public static void setV6Sbits(int n) {
        if (TtioRansNative.isAvailable()) TtioRansNative.setV6Sbits(n);
    }

    /** @return the width {@link #setV6Sbits} last set, 0 by default. */
    public static int getV6Sbits() {
        return TtioRansNative.isAvailable() ? TtioRansNative.getV6Sbits() : 0;
    }

    public static void setV6Threads(int n) {
        if (TtioRansNative.isAvailable()) TtioRansNative.setV6Threads(n);
    }

    /** @return the V6 segment thread count, or 0 when it defers to the
     *  auto-tune knob. */
    public static int getV6Threads() {
        return TtioRansNative.isAvailable() ? TtioRansNative.getV6Threads() : 0;
    }

    public static void setAutotuneThreads(int n) {
        if (TtioRansNative.isAvailable()) TtioRansNative.setAutotuneThreads(n);
    }

    public static int getAutotuneThreads() {
        return TtioRansNative.isAvailable() ? TtioRansNative.getAutotuneThreads() : 1;
    }
}
