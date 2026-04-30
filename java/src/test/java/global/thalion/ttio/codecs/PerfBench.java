/*
 * Standalone perf bench for FqzcompNx16 — runnable via `java -cp` for
 * direct JFR profiling without surefire fork.
 *
 * Usage: java -cp target/classes:target/test-classes \
 *           -XX:StartFlightRecording=settings=profile,filename=/tmp/fqz.jfr,duration=60s \
 *           global.thalion.ttio.codecs.PerfBench
 *
 * Delete after profiling.
 */
package global.thalion.ttio.codecs;

public class PerfBench {

    private static byte[] buildVariedQualities(int n) {
        byte[] out = new byte[n];
        long s = 0xBEEFL;
        for (int i = 0; i < n; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            out[i] = (byte) (33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        return out;
    }

    public static void main(String[] args) {
        // Smaller workload for faster profiling.
        int nReads = Integer.parseInt(System.getProperty("nReads", "10000"));
        int readLen = 100;
        int nQual = nReads * readLen;
        byte[] qualities = buildVariedQualities(nQual);
        int[] readLengths = new int[nReads];
        int[] revcompFlags = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            readLengths[i] = readLen;
            revcompFlags[i] = ((i & 7) == 0) ? 1 : 0;
        }

        // Warm-up: small encode + small decode (use matching revcompFlags).
        int[] warmFlags = new int[]{0, 1, 0, 1};
        byte[] warmEnc = FqzcompNx16.encode(new byte[400], new int[]{100, 100, 100, 100},
                warmFlags);
        FqzcompNx16.decodeWithMetadata(warmEnc, warmFlags);

        // Encode
        long t0 = System.nanoTime();
        byte[] encoded = FqzcompNx16.encode(qualities, readLengths, revcompFlags);
        long encDt = System.nanoTime() - t0;

        // Decode
        long t1 = System.nanoTime();
        FqzcompNx16.DecodeResult dr = FqzcompNx16.decodeWithMetadata(encoded, revcompFlags);
        long decDt = System.nanoTime() - t1;

        double mb = (double) nQual / 1e6;
        double encMbS = mb / (encDt / 1e9);
        double decMbS = mb / (decDt / 1e9);

        System.out.printf(
            "PerfBench %d reads x %d bp = %.1f MB raw: encode %.3f MB/s (%.3fs), decode %.3f MB/s (%.3fs), ratio %.3fx%n",
            nReads, readLen, mb, encMbS, encDt / 1e9, decMbS, decDt / 1e9,
            (double) encoded.length / nQual);

        if (dr.qualities().length != nQual) {
            throw new RuntimeException("decode length mismatch: " + dr.qualities().length + " != " + nQual);
        }
    }
}
