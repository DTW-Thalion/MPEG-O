/*
 * FqzcompNx16ZPerfTest — M94.Z throughput regression smoke (Java).
 *
 * Mirrors FqzcompNx16PerfTest but for the M94.Z codec. Reports both
 * encode AND decode throughput on the standard 100K-reads × 100bp
 * Q20-Q40 input.
 *
 * Loose targets per the spec instructions: encode ≥ 50 MB/s,
 * decode ≥ 30 MB/s. Below 30 MB/s = profile and report.
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class FqzcompNx16ZPerfTest {

    private static byte[] buildVariedQualities(int n) {
        byte[] out = new byte[n];
        long s = 0xBEEFL;
        for (int i = 0; i < n; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            // Q20..Q40 (ASCII 53..73) varied profile.
            out[i] = (byte) (33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        return out;
    }

    @Test
    void encodeAndDecodeThroughput() {
        final int nReads = 100_000;
        final int readLen = 100;
        final int nQual = nReads * readLen;

        byte[] qualities = buildVariedQualities(nQual);
        int[] readLengths = new int[nReads];
        int[] revcompFlags = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            readLengths[i] = readLen;
            revcompFlags[i] = ((i & 7) == 0) ? 1 : 0;  // ~12.5% revcomp
        }

        // JIT warm-up — encode + decode several times on a smaller
        // input so HotSpot tiers up the hot loops before timing.
        {
            byte[] warmQ = buildVariedQualities(10_000);
            int[] warmRl = new int[100];
            int[] warmRc = new int[100];
            for (int i = 0; i < 100; i++) warmRl[i] = 100;
            for (int w = 0; w < 5; w++) {
                byte[] warmEnc = FqzcompNx16Z.encode(warmQ, warmRl, warmRc);
                FqzcompNx16Z.decode(warmEnc, warmRc);
            }
        }

        // Encode timing.
        long t0 = System.nanoTime();
        byte[] encoded = FqzcompNx16Z.encode(qualities, readLengths, revcompFlags);
        long encDt = System.nanoTime() - t0;

        // Decode timing.
        long t1 = System.nanoTime();
        FqzcompNx16Z.DecodeResult dec = FqzcompNx16Z.decode(encoded, revcompFlags);
        long decDt = System.nanoTime() - t1;

        double mb = (double) nQual / 1e6;
        double encMbS = mb / (encDt / 1e9);
        double decMbS = mb / (decDt / 1e9);
        double ratio = (double) encoded.length / (double) nQual;

        System.out.printf(
            "%n  M94.Z FQZCOMP_NX16Z throughput (Java, %d reads × %d bp = %.1f MB raw): "
                + "encode %.2f MB/s (%.3fs), decode %.2f MB/s (%.3fs), ratio %.3fx%n",
            nReads, readLen, mb, encMbS, encDt / 1e9, decMbS, decDt / 1e9, ratio);

        // Sanity: decoded matches input.
        assertTrue(java.util.Arrays.equals(qualities, dec.qualities()),
            "decode output mismatch");

        // Regression floors: catch catastrophic regressions only.
        // Spec target: encode ≥50 MB/s, decode ≥30 MB/s.
        assertTrue(encMbS >= 10.0,
            String.format("Java: encode throughput >= 10 MB/s "
                + "(got %.2f MB/s, target 50 MB/s)", encMbS));
        assertTrue(decMbS >= 5.0,
            String.format("Java: decode throughput >= 5 MB/s "
                + "(got %.2f MB/s, target 30 MB/s)", decMbS));
    }
}
