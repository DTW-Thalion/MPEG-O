/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Cross-language counterpart of
 *   python/tests/test_m84_base_pack.py
 *   objc/Tests/TestM84BasePack.m
 *
 * <p>The canonical-vector fixtures under
 * {@code resources/ttio/codecs/base_pack_*.bin} are identical bytes
 * copied from the Python test fixtures; the Java encoder must
 * produce byte-for-byte identical output for the same inputs.
 */
final class BasePackTest {

    // ── Helpers ─────────────────────────────────────────────────────

    private static byte[] loadFixture(String name) throws IOException {
        String path = "/ttio/codecs/" + name;
        try (InputStream in = BasePackTest.class.getResourceAsStream(path)) {
            assertNotNull(in, "fixture missing on classpath: " + path);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        }
    }

    private static byte[] repeat(String unit, int times) {
        byte[] u = unit.getBytes(StandardCharsets.UTF_8);
        byte[] out = new byte[u.length * times];
        for (int i = 0; i < times; i++) {
            System.arraycopy(u, 0, out, i * u.length, u.length);
        }
        return out;
    }

    private static byte[] vectorA() throws Exception {
        byte[] seed = MessageDigest.getInstance("SHA-256")
            .digest("ttio-base-pack-vector-a".getBytes(StandardCharsets.UTF_8));
        byte[] acgt = "ACGT".getBytes(StandardCharsets.UTF_8);
        byte[] data = new byte[256];
        for (int i = 0; i < 256; i++) {
            data[i] = acgt[seed[i % 32] & 0b11];
        }
        return data;
    }

    private static byte[] vectorB() throws Exception {
        byte[] seedB = MessageDigest.getInstance("SHA-256")
            .digest("ttio-base-pack-vector-b".getBytes(StandardCharsets.UTF_8));
        byte[] acgt = "ACGT".getBytes(StandardCharsets.UTF_8);
        byte[] data = new byte[1024];
        for (int i = 0; i < 1024; i++) {
            if (i % 100 == 0) {
                data[i] = (byte) 'N';
            } else {
                int bitPair = (Byte.toUnsignedInt(seedB[i % 32]) >>> ((i / 32) % 4 * 2)) & 0b11;
                data[i] = acgt[bitPair];
            }
        }
        return data;
    }

    private static byte[] vectorC() {
        // Vector C — IUPAC + soft-mask stress, exactly 64 bytes.
        // Mirrors python/tests/test_m84_base_pack.py::_vector_c().
        StringBuilder sb = new StringBuilder(64);
        sb.append("ACGT");          // 0-3   plain ACGT (packed)
        sb.append("acgt");          // 4-7   soft-mask (lowercase)
        sb.append("NNNN");          // 8-11  all-N
        sb.append("RYSW");          // 12-15 IUPAC
        sb.append("KMBD");          // 16-19 IUPAC
        sb.append("HVN-");          // 20-23 IUPAC + N + gap
        sb.append("....AC..GT..");  // 24-35 gap + ACGT mix
        for (int i = 0; i < 7; i++) {
            sb.append("ACGT");      // 36-63 plain ACGT padding
        }
        byte[] out = sb.toString().getBytes(StandardCharsets.UTF_8);
        if (out.length != 64) {
            throw new AssertionError("vector C must be 64 bytes, got " + out.length);
        }
        return out;
    }

    // ── 1. Round-trip pure ACGT 1 MiB ───────────────────────────────

    @Test
    void roundTripPureACGT() {
        byte[] data = repeat("ACGT", 262144); // 1 MiB
        assertEquals(1 << 20, data.length, "1 MiB input length");
        byte[] enc = BasePack.encode(data);
        // Header(13) + body(262144) + mask(0) = 262157.
        assertEquals(262157, enc.length, "pure ACGT encoded total");
        // First body byte: 'A','C','G','T' → 0x1B (binding decision §82).
        assertEquals((byte) 0x1B, enc[13], "first body byte = 0x1B");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "pure ACGT round-trip");
    }

    // ── 2. Round-trip realistic with N every 100th ──────────────────

    @Test
    void roundTripRealistic() {
        int n = 1 << 20;
        byte[] data = repeat("ACGT", n / 4);
        for (int i = 0; i < n; i += 100) {
            data[i] = (byte) 'N';
        }
        byte[] enc = BasePack.encode(data);
        // mask_count read directly from header (offset 9).
        int maskCount = ((enc[9] & 0xFF) << 24) | ((enc[10] & 0xFF) << 16)
            | ((enc[11] & 0xFF) << 8) | (enc[12] & 0xFF);
        assertEquals(10486, maskCount, "mask_count for 1 MiB w/ N every 100th");
        assertEquals(13 + (n / 4) + 5 * 10486, enc.length, "realistic total");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "realistic round-trip");
    }

    // ── 3. Round-trip all-N 1 MiB ───────────────────────────────────

    @Test
    void roundTripAllN() {
        int n = 1 << 20;
        byte[] data = new byte[n];
        Arrays.fill(data, (byte) 'N');
        byte[] enc = BasePack.encode(data);
        int maskCount = ((enc[9] & 0xFF) << 24) | ((enc[10] & 0xFF) << 16)
            | ((enc[11] & 0xFF) << 8) | (enc[12] & 0xFF);
        assertEquals(n, maskCount, "every byte must be in mask");
        // 13 + 262144 + 5*1048576 = 5505037
        assertEquals(5505037, enc.length, "all-N total length");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "all-N round-trip");
    }

    // ── 4. Round-trip empty ─────────────────────────────────────────

    @Test
    void roundTripEmpty() {
        byte[] enc = BasePack.encode(new byte[0]);
        assertEquals(13, enc.length, "empty encoded length = header only");
        assertEquals((byte) 0x00, enc[0], "version byte");
        // orig_len, packed_len, mask_count all zero.
        for (int i = 1; i < 13; i++) {
            assertEquals((byte) 0x00, enc[i], "header byte " + i + " must be zero");
        }
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(new byte[0], dec, "empty round-trip");
    }

    // ── 5. Round-trip single ACGT + 2-byte + 3-byte tails ───────────

    @Test
    void roundTripSingleACGT() {
        byte[][] inputs = new byte[][]{
            {'A'}, {'C'}, {'G'}, {'T'}
        };
        byte[] expectedBodies = new byte[]{0x00, 0x40, (byte) 0x80, (byte) 0xC0};
        for (int i = 0; i < 4; i++) {
            byte[] enc = BasePack.encode(inputs[i]);
            assertEquals(14, enc.length, "single base encoded len");
            assertEquals(expectedBodies[i], enc[13],
                "body byte for '" + (char) inputs[i][0] + "'");
            byte[] dec = BasePack.decode(enc);
            assertArrayEquals(inputs[i], dec,
                "single base round-trip '" + (char) inputs[i][0] + "'");
        }
        // Two-base tail "AC" → body 0x10.
        byte[] ac = BasePack.encode("AC".getBytes(StandardCharsets.UTF_8));
        assertEquals(14, ac.length, "AC encoded len");
        assertEquals((byte) 0x10, ac[13], "AC body byte = 0x10");
        assertArrayEquals("AC".getBytes(StandardCharsets.UTF_8),
            BasePack.decode(ac), "AC round-trip");
        // Three-base tail "ACG" → body 0x18.
        byte[] acg = BasePack.encode("ACG".getBytes(StandardCharsets.UTF_8));
        assertEquals(14, acg.length, "ACG encoded len");
        assertEquals((byte) 0x18, acg[13], "ACG body byte = 0x18");
        assertArrayEquals("ACG".getBytes(StandardCharsets.UTF_8),
            BasePack.decode(acg), "ACG round-trip");
    }

    // ── 6. Round-trip single N ──────────────────────────────────────

    @Test
    void roundTripSingleN() {
        byte[] data = "N".getBytes(StandardCharsets.UTF_8);
        byte[] enc = BasePack.encode(data);
        // 13 (header) + 1 (body) + 5 (mask entry) = 19.
        assertEquals(19, enc.length, "single-N encoded total");
        // Body slot is placeholder 0b00 in two highest bits.
        assertEquals((byte) 0x00, enc[13], "single-N body placeholder");
        // Mask entry: position 0, original_byte 'N'.
        assertEquals((byte) 0x00, enc[14], "mask pos byte 0");
        assertEquals((byte) 0x00, enc[15], "mask pos byte 1");
        assertEquals((byte) 0x00, enc[16], "mask pos byte 2");
        assertEquals((byte) 0x00, enc[17], "mask pos byte 3");
        assertEquals((byte) 'N', enc[18], "mask original byte");
        assertArrayEquals(data, BasePack.decode(enc), "single-N round-trip");
    }

    // ── 7. IUPAC stress ─────────────────────────────────────────────

    @Test
    void iupacStress() {
        byte[] data = "ACGTacgtNRYSWKMBDHV-.".getBytes(StandardCharsets.UTF_8);
        assertEquals(21, data.length, "IUPAC input length");
        byte[] enc = BasePack.encode(data);
        int maskCount = ((enc[9] & 0xFF) << 24) | ((enc[10] & 0xFF) << 16)
            | ((enc[11] & 0xFF) << 8) | (enc[12] & 0xFF);
        // 4 ACGT bases + 17 non-ACGT (lowercase acgt, N, IUPAC ambig, gaps).
        assertEquals(17, maskCount, "IUPAC mask_count = 17");
        // 13 + ceil(21/4)=6 + 5*17 = 104.
        assertEquals(13 + 6 + 5 * 17, enc.length, "IUPAC total");
        assertArrayEquals(data, BasePack.decode(enc), "IUPAC round-trip");
    }

    // ── 8. Canonical vector A ───────────────────────────────────────

    @Test
    void canonicalVectorA() throws Exception {
        byte[] data = vectorA();
        assertEquals(256, data.length, "vector A length");
        byte[] enc = BasePack.encode(data);
        byte[] fixture = loadFixture("base_pack_a.bin");
        assertArrayEquals(fixture, enc, "vector A byte-exact");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "vector A round-trip");
    }

    // ── 9. Canonical vector B ───────────────────────────────────────

    @Test
    void canonicalVectorB() throws Exception {
        byte[] data = vectorB();
        assertEquals(1024, data.length, "vector B length");
        byte[] enc = BasePack.encode(data);
        byte[] fixture = loadFixture("base_pack_b.bin");
        assertArrayEquals(fixture, enc, "vector B byte-exact");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "vector B round-trip");
    }

    // ── 10. Canonical vector C ──────────────────────────────────────

    @Test
    void canonicalVectorC() throws Exception {
        byte[] data = vectorC();
        byte[] enc = BasePack.encode(data);
        byte[] fixture = loadFixture("base_pack_c.bin");
        assertArrayEquals(fixture, enc, "vector C byte-exact");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "vector C round-trip");
    }

    // ── 11. Canonical vector D (empty) ──────────────────────────────

    @Test
    void canonicalVectorD() throws Exception {
        byte[] data = new byte[0];
        byte[] enc = BasePack.encode(data);
        assertEquals(13, enc.length, "vector D = 13-byte header only");
        byte[] fixture = loadFixture("base_pack_d.bin");
        assertEquals(13, fixture.length, "fixture D length");
        assertArrayEquals(fixture, enc, "vector D byte-exact");
        assertArrayEquals(data, BasePack.decode(enc), "vector D round-trip");
    }

    // ── 12. Decode malformed ────────────────────────────────────────

    @Test
    void decodeMalformed() {
        byte[] good = BasePack.encode("ACGTNACGT".getBytes(StandardCharsets.UTF_8));

        // Truncated stream (shorter than the declared length).
        byte[] truncated = Arrays.copyOf(good, good.length - 3);
        assertThrows(IllegalArgumentException.class,
            () -> BasePack.decode(truncated), "truncated stream");

        // Bad version byte.
        byte[] badVer = good.clone();
        badVer[0] = 0x01;
        assertThrows(IllegalArgumentException.class,
            () -> BasePack.decode(badVer), "bad version byte");

        // packed_length mismatch — bump declared packed_len by 1.
        byte[] badPacked = good.clone();
        // packed_len at offset 5..8.
        int pl = ((badPacked[5] & 0xFF) << 24) | ((badPacked[6] & 0xFF) << 16)
            | ((badPacked[7] & 0xFF) << 8) | (badPacked[8] & 0xFF);
        int bumped = pl + 1;
        badPacked[5] = (byte) (bumped >>> 24);
        badPacked[6] = (byte) (bumped >>> 16);
        badPacked[7] = (byte) (bumped >>> 8);
        badPacked[8] = (byte) bumped;
        assertThrows(IllegalArgumentException.class,
            () -> BasePack.decode(badPacked), "packed_length mismatch");

        // Mask position out of range — orig_len=9, set first mask pos to 99.
        byte[] badPos = good.clone();
        // packed_len = ceil(9/4) = 3, so mask starts at 13 + 3 = 16.
        // Single mask entry at offset 16..20. Position bytes 16..19, byte 20.
        badPos[16] = 0x00;
        badPos[17] = 0x00;
        badPos[18] = 0x00;
        badPos[19] = 99;
        assertThrows(IllegalArgumentException.class,
            () -> BasePack.decode(badPos), "mask position out of range");

        // Mask positions out of order — encode 2 mask entries then swap.
        byte[] twoMask = BasePack.encode("ANANACGT".getBytes(StandardCharsets.UTF_8));
        // orig_len=8, packed_len=2, mask starts at 15. Entries at 15..19 and 20..24.
        // Entry 0 has pos 1, entry 1 has pos 3. Reverse → out of order.
        byte[] badOrder = twoMask.clone();
        // Swap the position bytes of the two entries (keep original_byte).
        // Place pos 3 first, pos 1 second.
        badOrder[15] = 0x00; badOrder[16] = 0x00; badOrder[17] = 0x00; badOrder[18] = 0x03;
        badOrder[20] = 0x00; badOrder[21] = 0x00; badOrder[22] = 0x00; badOrder[23] = 0x01;
        assertThrows(IllegalArgumentException.class,
            () -> BasePack.decode(badOrder), "mask positions out of order");
    }

    // ── 13. Soft-masking round-trip ─────────────────────────────────

    @Test
    void softMaskingRoundTrip() {
        byte[] data = "ACGTacgtACGT".getBytes(StandardCharsets.UTF_8);
        byte[] enc = BasePack.encode(data);
        int maskCount = ((enc[9] & 0xFF) << 24) | ((enc[10] & 0xFF) << 16)
            | ((enc[11] & 0xFF) << 8) | (enc[12] & 0xFF);
        // Lowercase 'acgt' all → mask (case-sensitive packing, §81).
        assertEquals(4, maskCount, "lowercase mask count");
        // 13 + 3 + 5*4 = 36.
        assertEquals(13 + 3 + 5 * 4, enc.length, "soft-masking total");
        byte[] dec = BasePack.decode(enc);
        assertArrayEquals(data, dec, "soft-masking round-trip preserves case");
    }

    // ── 14. Throughput ──────────────────────────────────────────────

    @Test
    void throughput() {
        int n = 4 * (1 << 20); // 4 MiB
        byte[] data = repeat("ACGT", n / 4);
        assertEquals(n, data.length, "throughput input size");

        long t0 = System.nanoTime();
        byte[] enc = BasePack.encode(data);
        long encDt = System.nanoTime() - t0;

        long t1 = System.nanoTime();
        byte[] dec = BasePack.decode(enc);
        long decDt = System.nanoTime() - t1;

        double mib = (double) n / (1 << 20);
        double encMbS = mib / (encDt / 1e9);
        double decMbS = mib / (decDt / 1e9);
        System.out.printf(
            "%n  M84 throughput (4 MiB pure ACGT, Java): "
                + "encode %.2f MB/s, decode %.2f MB/s%n",
            encMbS, decMbS);

        assertArrayEquals(data, dec, "throughput round-trip integrity");
        assertTrue(encMbS > 0.0, "encode throughput > 0");
        assertTrue(decMbS > 0.0, "decode throughput > 0");
    }
}
