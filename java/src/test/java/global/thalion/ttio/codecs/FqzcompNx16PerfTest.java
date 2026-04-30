/*
 * FqzcompNx16PerfTest — FQZCOMP_NX16 throughput regression smoke (Java).
 *
 * Parallels python/tests/perf/test_m94_throughput.py and
 * objc/Tests/TestM94FqzcompPerf.m. Encodes 100K reads × 100bp varied
 * Illumina-profile qualities (~10 MB raw) and asserts throughput floors.
 *
 * Target per spec §11: ≥60 MB/s encode (native Java JIT inner loop).
 * Hard floor (regression gate): ≥20 MB/s.
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

class FqzcompNx16PerfTest {

    private static byte[] buildVariedQualities(int n) {
        byte[] out = new byte[n];
        long s = 0xBEEFL;
        for (int i = 0; i < n; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            // Q20..Q40 (ASCII 53..73) — varied so adaptive freq tables
            // produce non-trivial divergence.
            out[i] = (byte) (33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        return out;
    }

    @Test
    void encodeThroughput() {
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

        // JIT warm-up — one small encode before timing.
        FqzcompNx16.encode(new byte[400], new int[]{100, 100, 100, 100},
                           new int[]{0, 1, 0, 1});

        long t0 = System.nanoTime();
        byte[] encoded = FqzcompNx16.encode(qualities, readLengths, revcompFlags);
        long encDt = System.nanoTime() - t0;

        double mb = (double) nQual / 1e6;
        double encMbS = mb / (encDt / 1e9);
        double ratio = (double) encoded.length / (double) nQual;

        System.out.printf(
            "%n  M94 FQZCOMP_NX16 throughput (Java, %d reads × %d bp = %.1f MB raw): "
                + "encode %.2f MB/s (%.3fs), ratio %.3fx%n",
            nReads, readLen, mb, encMbS, encDt / 1e9, ratio);

        // Regression floor — below the 60 MB/s spec target, catches
        // catastrophic regressions only. The spec target is the
        // M94 acceptance gate, not this smoke.
        assertTrue(encMbS >= 20.0,
            String.format("Java: encode throughput >= 20 MB/s regression floor "
                + "(got %.2f MB/s, spec target 60 MB/s)", encMbS));
    }
}
