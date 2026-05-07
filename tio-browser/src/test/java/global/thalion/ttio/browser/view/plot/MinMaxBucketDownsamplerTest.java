package global.thalion.ttio.browser.view.plot;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class MinMaxBucketDownsamplerTest {

    @Test
    void belowTargetCountReturnsInputUnchanged() {
        double[] x = {0, 1, 2, 3, 4};
        double[] y = {1, 2, 3, 4, 5};
        MinMaxBucketDownsampler.Result r = MinMaxBucketDownsampler.reduce(x, y, 100);
        assertArrayEquals(x, r.x());
        assertArrayEquals(y, r.y());
    }

    @Test
    void halvesPointCountWhenTargetIsHalf() {
        double[] x = new double[1000];
        double[] y = new double[1000];
        for (int i = 0; i < 1000; i++) {
            x[i] = i;
            y[i] = i;
        }
        MinMaxBucketDownsampler.Result r = MinMaxBucketDownsampler.reduce(x, y, 100);
        assertEquals(100, r.x().length);
        assertEquals(0.0, r.y()[0]);
        assertEquals(999.0, r.y()[r.y().length - 1]);
    }

    @Test
    void preservesPeaksInNoisyData() {
        double[] x = new double[10000];
        double[] y = new double[10000];
        java.util.Random rng = new java.util.Random(42);
        for (int i = 0; i < 10000; i++) {
            x[i] = i;
            y[i] = (i == 5000) ? 1e6 : rng.nextDouble();
        }
        MinMaxBucketDownsampler.Result r = MinMaxBucketDownsampler.reduce(x, y, 200);
        double maxOut = 0;
        for (double v : r.y()) if (v > maxOut) maxOut = v;
        assertEquals(1e6, maxOut, 1e-3, "peak must survive bucketing");
    }
}
