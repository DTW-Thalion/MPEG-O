/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests for the V2 (libttio_rans-body) wire-format dispatch in
 * {@link FqzcompNx16Z}. Mirrors the Python {@code test_m94z_v2_dispatch.py}
 * suite added in commit {@code 7efa658}.
 *
 * <p>V1 streams (default) round-trip via the pure-Java path. V2 streams
 * carry version byte = 2 and a self-contained native body produced by
 * {@code ttio_rans_encode_block}. Native-body tests are gated on
 * {@link TtioRansNative#isAvailable()} so suites without the JNI library
 * still pass.
 */
final class FqzcompNx16ZV2DispatchTest {

    /** Matches @EnabledIf signature: a no-arg method returning boolean. */
    static boolean isNativeAvailable() {
        return TtioRansNative.isAvailable();
    }

    private static byte[] makeQualities(int nReads, int readLen) {
        byte[] q = new byte[nReads * readLen];
        for (int i = 0; i < q.length; i++) {
            // Range 33..53 (Phred-33 ASCII), enough variety to exercise contexts.
            q[i] = (byte) (33 + 20 + ((i * 31) % 21));
        }
        return q;
    }

    private static int[] fill(int n, int v) {
        int[] a = new int[n];
        Arrays.fill(a, v);
        return a;
    }

    // ── V1 default behaviour ────────────────────────────────────────

    @Test
    void v1IsDefaultWhenV4Suppressed() {
        // After Task 4, V4 became the default whenever JNI is loaded. This
        // test asserts the *pre-V4* default — that with V4 explicitly
        // suppressed and native off, the encoder produces V1.
        byte[] q = makeQualities(50, 80);
        int[] rls = fill(50, 80);
        int[] rcs = new int[50];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(false));
        assertEquals('M', enc[0]);
        assertEquals('9', enc[1]);
        assertEquals('4', enc[2]);
        assertEquals('Z', enc[3]);
        assertEquals(1, enc[4], "with V4 + native off, encoder must produce V1");
    }

    @Test
    void v1RoundTripUnchanged() {
        byte[] q = makeQualities(32, 50);
        int[] rls = fill(32, 50);
        int[] rcs = new int[32];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(false));
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(enc, rcs);
        assertArrayEquals(q, r.qualities());
        assertArrayEquals(rls, r.readLengths());
    }

    @Test
    void preferNativeFalseForcesV1() {
        byte[] q = makeQualities(20, 30);
        int[] rls = fill(20, 30);
        int[] rcs = new int[20];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(false));
        assertEquals(1, enc[4], "preferNative=false (with V4 suppressed) must force V1");
    }

    // ── V2 native dispatch ──────────────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void v2EncodeProducesVersionByte2() {
        byte[] q = makeQualities(10, 20);
        int[] rls = fill(10, 20);
        int[] rcs = new int[10];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4], "V2 encoded version byte must be 2");
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RoundTripSmall() {
        byte[] q = makeQualities(8, 16);
        int[] rls = fill(8, 16);
        int[] rcs = new int[8];

        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4]);

        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(enc, rcs);
        assertArrayEquals(q, r.qualities());
        assertArrayEquals(rls, r.readLengths());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RoundTripUnaligned() {
        // n_qualities not a multiple of 4 — exercises the padding logic.
        byte[] q = makeQualities(7, 13);   // 91 symbols → padded to 92
        int[] rls = fill(7, 13);
        int[] rcs = new int[7];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(enc, rcs);
        assertArrayEquals(q, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RoundTripMultiReadWithRevcomp() {
        byte[] q = makeQualities(100, 80);
        int[] rls = fill(100, 80);
        int[] rcs = new int[100];
        for (int i = 0; i < 100; i++) rcs[i] = (i & 1);

        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4], "V2 encoded version byte");

        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(enc, rcs);
        assertArrayEquals(q, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v1V2DecodeProduceSameQualities() {
        byte[] q = makeQualities(64, 100);
        int[] rls = fill(64, 100);
        int[] rcs = new int[64];

        byte[] encV1 = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(false));
        byte[] encV2 = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));

        // Wire formats differ (V1 has trailer, V2 has native body).
        assertEquals(1, encV1[4]);
        assertEquals(2, encV2[4]);

        byte[] decV1 = FqzcompNx16Z.decode(encV1, rcs).qualities();
        byte[] decV2 = FqzcompNx16Z.decode(encV2, rcs).qualities();

        assertArrayEquals(q, decV1);
        assertArrayEquals(q, decV2);
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2HeaderHasNoStateInitSuffix() {
        // V2 omits the 16-byte state_init suffix on the codec header.
        // For a tiny input, V2's encoded length should be smaller than
        // V1's by at least 16 bytes (state_init suffix) minus any body
        // size differences. We don't assert exact size, just ensure
        // both round-trip and that the body-format byte differs.
        byte[] q = makeQualities(4, 8);
        int[] rls = fill(4, 8);
        int[] rcs = new int[4];

        byte[] encV1 = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(false));
        byte[] encV2 = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));

        // Both must round-trip.
        assertArrayEquals(q, FqzcompNx16Z.decode(encV1, rcs).qualities());
        assertArrayEquals(q, FqzcompNx16Z.decode(encV2, rcs).qualities());

        // Wire formats are distinct byte streams (different version byte).
        assertNotEquals(encV1[4], encV2[4]);
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RejectsCorruptBody() {
        byte[] q = makeQualities(8, 16);
        int[] rls = fill(8, 16);
        int[] rcs = new int[8];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));

        // Sanity: round-trip works.
        assertArrayEquals(q, FqzcompNx16Z.decode(enc, rcs).qualities());

        // Flip a byte in the body data (at the very end, in the lane data).
        byte[] corrupt = enc.clone();
        corrupt[corrupt.length - 1] ^= (byte) 0xFF;
        // Either decode throws, or final state validation fails. Both raise
        // IllegalArgumentException.
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16Z.decode(corrupt, rcs));
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RoundTripSingleSymbol() {
        // 1 read, 1 base — tiny edge case.
        byte[] q = new byte[]{60};
        int[] rls = new int[]{1};
        int[] rcs = new int[]{0};
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(enc, rcs);
        assertArrayEquals(q, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2RoundTripExact4Multiple() {
        // n_qualities exactly multiple of 4 → no padding.
        byte[] q = makeQualities(8, 4);  // 32 symbols
        int[] rls = fill(8, 4);
        int[] rcs = new int[8];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4]);
        // pad_count flag bits should be zero.
        assertEquals(0, (enc[5] >>> 4) & 0x3, "pad_count must be 0");
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(enc, rcs);
        assertArrayEquals(q, r.qualities());
    }

    // ── V2 not enabled when native unavailable ─────────────────────

    @Test
    void v2OptDoesNothingWhenNativeUnavailable() {
        // When the native lib is absent, preferNative=true silently falls
        // back to V1 (the default path). This is the same behaviour as
        // the Python reference (use_native_v2 = bool(prefer_native) AND
        // _HAVE_NATIVE_LIB).
        if (TtioRansNative.isAvailable()) {
            return;  // Only meaningful when native is unavailable.
        }
        byte[] q = makeQualities(8, 4);
        int[] rls = fill(8, 4);
        int[] rcs = new int[8];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(1, enc[4],
            "preferNative=true must fall back to V1 when native lib absent");
    }

    // ── Header validation ──────────────────────────────────────────

    @Test
    @EnabledIf("isNativeAvailable")
    void decodeRejectsTruncatedV2Stream() {
        byte[] q = makeQualities(8, 16);
        int[] rls = fill(8, 16);
        int[] rcs = new int[8];
        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));

        // Truncate to last few bytes.
        byte[] truncated = Arrays.copyOf(enc, enc.length - 4);
        assertThrows(IllegalArgumentException.class,
            () -> FqzcompNx16Z.decode(truncated, rcs));
    }

    // ── V2 native streaming decode (Task 26c) ──────────────────────
    //
    // The streaming decode path routes the inner rANS loop through the
    // libttio_rans `ttio_rans_decode_block_streaming` API with a Java
    // ContextResolver lambda for per-symbol context derivation. The path
    // is shipped as infrastructure proving the C streaming API is wired
    // end-to-end across all bindings; per-symbol JNI dispatch is too
    // expensive to be a perf win for realistic blocks. The streaming
    // path is opt-in (gated on TTIO_M94Z_USE_NATIVE_STREAMING env var);
    // these tests force-invoke it via the package-private
    // decodeV2ForceNativeStreamingForTest entry point.

    @Test
    @EnabledIf("isNativeAvailable")
    void v2NativeStreamingRoundTrip() {
        byte[] q = makeQualities(32, 50);
        int[] rls = fill(32, 50);
        int[] rcs = new int[32];

        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4]);

        FqzcompNx16Z.DecodeResult r =
            FqzcompNx16Z.decodeV2ForceNativeStreamingForTest(enc, rcs);
        assertNotNull(r, "streaming decode must not be null on valid V2 blob");
        assertArrayEquals(q, r.qualities());
        assertArrayEquals(rls, r.readLengths());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2NativeStreamingRoundTripUnaligned() {
        // Unaligned (n_qualities not multiple of 4) — exercises padding.
        byte[] q = makeQualities(7, 13);
        int[] rls = fill(7, 13);
        int[] rcs = new int[7];

        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertEquals(2, enc[4]);
        FqzcompNx16Z.DecodeResult r =
            FqzcompNx16Z.decodeV2ForceNativeStreamingForTest(enc, rcs);
        assertNotNull(r);
        assertArrayEquals(q, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2NativeStreamingRoundTripWithRevcomp() {
        byte[] q = makeQualities(50, 80);
        int[] rls = fill(50, 80);
        int[] rcs = new int[50];
        for (int i = 0; i < 50; i++) rcs[i] = (i & 1);

        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        FqzcompNx16Z.DecodeResult r =
            FqzcompNx16Z.decodeV2ForceNativeStreamingForTest(enc, rcs);
        assertNotNull(r);
        assertArrayEquals(q, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v2NativeStreamingMatchesPureJava() {
        // Both paths must decode to identical output.
        byte[] q = makeQualities(20, 32);
        int[] rls = fill(20, 32);
        int[] rcs = new int[20];

        byte[] enc = FqzcompNx16Z.encode(q, rls, rcs,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));

        FqzcompNx16Z.DecodeResult viaPureJava = FqzcompNx16Z.decode(enc, rcs);
        FqzcompNx16Z.DecodeResult viaStreaming =
            FqzcompNx16Z.decodeV2ForceNativeStreamingForTest(enc, rcs);
        assertNotNull(viaStreaming);
        assertArrayEquals(viaPureJava.qualities(), viaStreaming.qualities());
        assertArrayEquals(viaPureJava.readLengths(), viaStreaming.readLengths());
    }

    /**
     * Direct invocation of the streaming JNI API — verifies the binding
     * itself works against a hand-rolled ContextResolver. Independent of
     * the M94.Z dispatch path so a regression in {@link FqzcompNx16Z}
     * doesn't mask a binding bug.
     */
    @Test
    @EnabledIf("isNativeAvailable")
    void streamingApiDirectInvocation() {
        // Encode a small fixed-context block via TtioRansNative.encodeBlock,
        // then decode it back via the streaming API using a constant
        // resolver. This isolates the streaming binding from M94.Z logic.
        int nSymbols = 64;
        int nContexts = 1;
        byte[] symbols = new byte[nSymbols];
        for (int i = 0; i < nSymbols; i++) symbols[i] = (byte) ((i * 7) % 16);
        short[] contexts = new short[nSymbols];  // all zero

        // Build a freq table that sums to T=4096.
        int[] freqRow = new int[256];
        // Use only 16 distinct symbols → 16 buckets of 256 each = 4096.
        for (int s = 0; s < 16; s++) freqRow[s] = 256;
        int[][] freq = new int[][] { freqRow };

        // Encode.
        byte[] outBuf = new byte[nSymbols * 4 + 64];
        int[] outLen = new int[] { outBuf.length };
        int rcEnc = TtioRansNative.encodeBlock(
            symbols, contexts, nContexts, freq, outBuf, outLen);
        assertEquals(0, rcEnc, "encodeBlock rc");
        byte[] body = Arrays.copyOf(outBuf, outLen[0]);

        // Build matching cum table.
        int[] cumRow = new int[256];
        int running = 0;
        for (int s = 0; s < 256; s++) { cumRow[s] = running; running += freqRow[s]; }
        int[][] cum = new int[][] { cumRow };

        // Streaming decode with a constant resolver (always returns 0).
        byte[] decoded = new byte[nSymbols];
        int[] callCount = new int[1];
        TtioRansNative.ContextResolver resolver = (i, prev) -> {
            callCount[0]++;
            return 0;
        };
        int rcDec = TtioRansNative.decodeBlockStreaming(
            body, nContexts, freq, cum, decoded, nSymbols, resolver);
        assertEquals(0, rcDec, "decodeBlockStreaming rc");
        assertArrayEquals(symbols, decoded);
        // Resolver must have been called at least nSymbols times
        // (the C lib skips the call for padding positions, but for
        // nSymbols=64, padding=0).
        assertTrue(callCount[0] >= nSymbols,
            "resolver called " + callCount[0] + " times, expected >= " + nSymbols);
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void streamingApiInvalidContextReturnsParam() {
        // Resolver returning ctx >= nContexts must trigger ERR_PARAM (-1).
        int nSymbols = 16;
        byte[] decoded = new byte[nSymbols];
        // Body is irrelevant since the resolver fails before any decode.
        // Build a minimal valid header (32 bytes: 4×state + 4×lane_size=0).
        byte[] body = new byte[32];
        // states all 0 (will be invalid but irrelevant — we fail in resolver)
        int[] freqRow = new int[256];
        for (int s = 0; s < 16; s++) freqRow[s] = 256;
        int[] cumRow = new int[256];
        int running = 0;
        for (int s = 0; s < 256; s++) { cumRow[s] = running; running += freqRow[s]; }

        TtioRansNative.ContextResolver bad = (i, prev) -> 999;  // out of range
        int rc = TtioRansNative.decodeBlockStreaming(
            body, 1, new int[][]{ freqRow }, new int[][]{ cumRow },
            decoded, nSymbols, bad);
        // Expect either ERR_PARAM (-1) or some other negative code; the
        // contract is "non-zero on error".
        assertNotEquals(0, rc, "expected non-zero return for invalid resolver output");
    }
}
