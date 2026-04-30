package global.thalion.ttio.codecs;
import org.junit.jupiter.api.Test;
public class PerfQuickDecode {
    @Test
    public void measure() {
        int n = 50_000;
        byte[] q = new byte[n * 100];
        long s = 0xBEEFL;
        for (int i = 0; i < q.length; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            q[i] = (byte)(33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        int[] rl = new int[n]; int[] rf = new int[n];
        for (int i = 0; i < n; i++) rl[i] = 100;
        // Warmup: 3 rounds for JIT.
        byte[] blob0 = FqzcompNx16.encode(q, rl, rf);
        FqzcompNx16.decodeWithMetadata(blob0, rf);
        FqzcompNx16.encode(q, rl, rf);
        FqzcompNx16.decodeWithMetadata(blob0, rf);
        FqzcompNx16.encode(q, rl, rf);
        FqzcompNx16.decodeWithMetadata(blob0, rf);
        long t0 = System.nanoTime();
        byte[] blob = FqzcompNx16.encode(q, rl, rf);
        long encNs = System.nanoTime() - t0;
        t0 = System.nanoTime();
        var dr = FqzcompNx16.decodeWithMetadata(blob, rf);
        long decNs = System.nanoTime() - t0;
        double mb = q.length / 1024.0 / 1024.0;
        System.out.printf("Java: %.2f MB; encode %.2f MB/s; decode %.2f MB/s%n",
            mb, mb * 1e9 / encNs, mb * 1e9 / decNs);
    }
}
