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

    @Test
    @EnabledIf("isNativeAvailable")
    void v2ExplicitStillWorks() {
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions()
            .preferV4(false).preferNative(true);
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        assertEquals(2, out[4], "preferV4=false + preferNative=true must produce V2");
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, SYNTH_REVCOMP);
        assertArrayEquals(SYNTH_QUALITIES, r.qualities());
    }

    @Test
    @EnabledIf("isNativeAvailable")
    void v1ExplicitStillWorks() {
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions()
            .preferV4(false).preferNative(false);
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        assertEquals(1, out[4], "preferV4=false + preferNative=false must produce V1");
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, SYNTH_REVCOMP);
        assertArrayEquals(SYNTH_QUALITIES, r.qualities());
    }

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

    @Test
    @EnabledIf("isNativeAvailable")
    void v4SizeSanityVsV2() {
        // Both V4 and V2 should produce reasonable encodings on synthetic
        // data; we only assert V4 is not pathologically larger than V2.
        // Allow a 200-byte slack for header overhead differences.
        byte[] qual = new byte[1000];
        for (int i = 0; i < 1000; i++) qual[i] = (byte) (33 + 20 + (i * 7) % 21);
        int[] lens = new int[10];
        int[] rev = new int[10];
        for (int i = 0; i < 10; i++) lens[i] = 100;

        byte[] v4 = FqzcompNx16Z.encode(qual, lens, rev,
            new FqzcompNx16Z.EncodeOptions().preferV4(true));
        byte[] v2 = FqzcompNx16Z.encode(qual, lens, rev,
            new FqzcompNx16Z.EncodeOptions().preferV4(false).preferNative(true));
        assertTrue(v4.length <= v2.length + 200,
            "V4=" + v4.length + " bytes vs V2=" + v2.length + " bytes");
    }

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
        // V4 stream with version byte rewritten to 2 must fail to decode
        // via the V2 path (the body is fqzcomp, not the libttio_rans-block
        // V2 codec).
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] v4 = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        v4[4] = 2;  // Tamper version byte.
        boolean threw = false;
        try {
            FqzcompNx16Z.decode(v4, SYNTH_REVCOMP);
        } catch (RuntimeException expected) {
            // V2 decoder will fail to parse the V4 body — expected.
            threw = true;
        }
        assertTrue(threw, "decode of V4 blob with version byte rewritten to 2 must throw");
    }
}
