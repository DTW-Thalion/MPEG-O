package global.thalion.ttio.browser.view.plot;

/**
 * Peak-preserving downsampler: bucket the input series into {@code targetPoints / 2}
 * buckets, emit the min and max y-value of each bucket in original x order. Local
 * extrema (peaks, valleys) survive bucketing — important for chromatogram /
 * spectrum rendering at zoom-out scales.
 */
public final class MinMaxBucketDownsampler {

    public static final class Result {
        private final double[] x, y;
        public Result(double[] x, double[] y) { this.x = x; this.y = y; }
        public double[] x() { return x; }
        public double[] y() { return y; }
    }

    private MinMaxBucketDownsampler() {}

    public static Result reduce(double[] x, double[] y, int targetPoints) {
        if (x.length <= targetPoints) return new Result(x, y);
        if (targetPoints < 4) targetPoints = 4;

        int bucketCount = targetPoints / 2;
        int n = x.length;
        double bucketWidth = (double) n / bucketCount;

        double[] outX = new double[bucketCount * 2];
        double[] outY = new double[bucketCount * 2];

        for (int b = 0; b < bucketCount; b++) {
            int start = (int) Math.floor(b * bucketWidth);
            int end = Math.min((int) Math.floor((b + 1) * bucketWidth), n);
            int minIdx = start, maxIdx = start;
            for (int i = start + 1; i < end; i++) {
                if (y[i] < y[minIdx]) minIdx = i;
                if (y[i] > y[maxIdx]) maxIdx = i;
            }
            int firstIdx = Math.min(minIdx, maxIdx);
            int secondIdx = Math.max(minIdx, maxIdx);
            outX[b * 2] = x[firstIdx];
            outY[b * 2] = y[firstIdx];
            outX[b * 2 + 1] = x[secondIdx];
            outY[b * 2 + 1] = y[secondIdx];
        }
        return new Result(outX, outY);
    }
}
