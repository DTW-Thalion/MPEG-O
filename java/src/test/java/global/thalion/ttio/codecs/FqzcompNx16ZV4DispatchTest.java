/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V4 (CRAM 3.1 fqzcomp) dispatch tests for {@link FqzcompNx16Z} (Java).
 *
 * <p>Mirrors {@code python/tests/test_m94z_v4_dispatch.py}. All tests skip
 * when {@link TtioRansNative#isAvailable()} is false (no JNI lib on
 * {@code java.library.path}).
 *
 * <p>To run from Maven the JNI lib must be locatable; surefire's
 * {@code argLine} sets {@code java.library.path} from the
 * {@code hdf5.native.path} property. Pass
 * {@code -Dhdf5.native.path=…:/path/to/native/_build} to include the
 * libttio_rans_jni build directory. (CI: pom.xml's
 * {@code linux-system-hdf5} profile already includes
 * {@code /home/toddw/TTI-O/native/_build}.)
 */
final class FqzcompNx16ZV4DispatchTest {

    /** Matches @EnabledIf signature: a no-arg method returning boolean. */
    static boolean isNativeAvailable() {
        return TtioRansNative.isAvailable();
    }

    // 12 qualities, 3 reads of 4 → padCount = 0.
    private static final byte[] SYNTH_QUALITIES = {
        'I','I','?','?',  '5','5','5','5',  'I','?','I','?'
    };
    private static final int[] SYNTH_LENS    = {4, 4, 4};
    private static final int[] SYNTH_REVCOMP = {0, 1, 0};

    @Test
    @EnabledIf("isNativeAvailable")
    void v4SmokeRoundtrip() {
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        assertEquals('M', out[0]);
        assertEquals('9', out[1]);
        assertEquals('4', out[2]);
        assertEquals('Z', out[3]);
        assertEquals(4, out[4], "V4 version byte must be 4");
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, SYNTH_REVCOMP);
        assertArrayEquals(SYNTH_QUALITIES, r.qualities());
        assertArrayEquals(SYNTH_LENS, r.readLengths());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v4DefaultWhenJniLoaded() {
        // Empty EncodeOptions (preferV4=null, preferNative=null) — when JNI
        // is loaded the dispatcher should choose V4.
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP,
            new FqzcompNx16Z.EncodeOptions());
        assertEquals(4, out[4], "default with JNI loaded must be V4");
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v4DefaultBareEncode() {
        // The 3-arg encode() (no options at all) must also default to V4.
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP);
        assertEquals(4, out[4], "bare encode() with JNI loaded must default to V4");
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, SYNTH_REVCOMP);
        assertArrayEquals(SYNTH_QUALITIES, r.qualities());
    }

    // v2ExplicitStillWorks and v1ExplicitStillWorks — REMOVED in
    // Phase 2c. The V1 / V2 encoder dispatch paths were deleted; only
    // V4 (CRAM 3.1 fqzcomp_qual) is emitted in v1.0+. The opts knobs
    // (preferV4=false, preferNative=true) are accepted for API
    // compatibility but always go V4.

    @Test
    @EnabledIf("isNativeAvailable")
    void v4PadCountThirteenQualities() {
        // 13 qualities → padCount = (-13) & 3 = 3. Exercises non-zero
        // padding through the V4 path.
        byte[] qual = new byte[13];
        for (int i = 0; i < 13; i++) qual[i] = (byte) (33 + i);
        int[] lens = {13};
        int[] rev = {0};
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] out = FqzcompNx16Z.encode(qual, lens, rev, opts);
        assertEquals(4, out[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, rev);
        assertArrayEquals(qual, r.qualities());
        assertArrayEquals(lens, r.readLengths());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v4SingleRead() {
        byte[] qual = new byte[50];
        for (int i = 0; i < 50; i++) qual[i] = 'I';
        int[] lens = {50};
        int[] rev = {0};
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] out = FqzcompNx16Z.encode(qual, lens, rev, opts);
        assertEquals(4, out[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, rev);
        assertArrayEquals(qual, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v4MixedRevcompRoundtrip() {
        // 20 reads of varied length, mixed revcomp — exercises the V4
        // SAM-flag mapping (bit 4 = SAM_REVERSE) and the per-read state
        // reset.
        int target = 2342;
        byte[] qual = new byte[target];
        long s = 0xBEEFL;
        for (int i = 0; i < target; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            qual[i] = (byte) (33 + 20 + (int) ((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        int nReads = 20;
        int[] lens = new int[nReads];
        int[] rev = new int[nReads];
        int rem = target;
        for (int i = 0; i < nReads - 1; i++) {
            lens[i] = 50 + (i * 7) % 150;
            rem -= lens[i];
            rev[i] = (i % 3 == 0) ? 1 : 0;
        }
        lens[nReads - 1] = rem;
        rev[nReads - 1] = 1;
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] out = FqzcompNx16Z.encode(qual, lens, rev, opts);
        assertEquals(4, out[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, rev);
        assertArrayEquals(qual, r.qualities());
        assertArrayEquals(lens, r.readLengths());
    }

    // v4SizeSanityVsV2 — REMOVED in Phase 2c (V2 path is gone).

    @Test
    @EnabledIf("isNativeAvailable")
    void v4MagicAndMinHeaderSize() {
        // V4 outer header is ~30 bytes (magic[4] + version[1] + flags[1] +
        // num_qual[8] + num_reads[8] + RLT [≥8]). Sanity-check the magic
        // bytes and that encoded length exceeds the minimum header size.
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP,
            new FqzcompNx16Z.EncodeOptions().preferV4(true));
        assertTrue(out.length > 30,
            "V4 stream should have > 30 byte header, got " + out.length);
        assertEquals('M', out[0]);
        assertEquals('9', out[1]);
        assertEquals('4', out[2]);
        assertEquals('Z', out[3]);
        assertEquals(4, out[4]);
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v4DecodeRejectsTamperedVersionByte() {
        // V4 stream with version byte rewritten to 2 must fail to
        // decode — V2 is no longer a recognised version (Phase 2c).
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] v4 = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        v4[4] = 2;  // Tamper version byte.
        boolean threw = false;
        try {
            FqzcompNx16Z.decode(v4, SYNTH_REVCOMP);
        } catch (RuntimeException expected) {
            threw = true;
        }
        assertTrue(threw, "decode of V4 blob with version byte rewritten to 2 must throw");
    }
}
