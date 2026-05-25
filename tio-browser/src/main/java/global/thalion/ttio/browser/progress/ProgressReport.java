package global.thalion.ttio.browser.progress;

/** Immutable snapshot of a long-running operation's progress. */
public record ProgressReport(
    String phase,
    long bytesDone,
    long bytesTotal,
    long unitsDone,
    long unitsTotal,
    double rateBytesPerSec,
    double rateUnitsPerSec,
    long etaSeconds,
    long elapsedSeconds,
    long lastActivityEpochMs
) {
    /**
     * @return true if at least one of {@code bytesTotal} or {@code unitsTotal} is known.
     */
    public boolean isDeterminate() {
        return bytesTotal > 0 || unitsTotal > 0;
    }

    /**
     * @return true if the byte-rate has fallen below ~100 B/s and at least 10 seconds have passed since the last non-zero progress delta. Always false when {@link #percent()} is at or above 0.99 — at ~100% the operation is finalizing (e.g. closing an HDF5 file), not stalled.
     */
    public boolean isStalled(long nowEpochMs) {
        if (isDeterminate() && percent() >= 0.99) return false;
        return rateBytesPerSec < 100.0
            && (nowEpochMs - lastActivityEpochMs) > 10_000L;
    }

    /**
     * @return a fraction in {@code [0.0, 1.0]} indicating progress, or {@code Double.NaN} if neither {@code bytesTotal} nor {@code unitsTotal} is known.
     */
    public double percent() {
        if (bytesTotal > 0) return (double) bytesDone / (double) bytesTotal;
        if (unitsTotal > 0) return (double) unitsDone / (double) unitsTotal;
        return Double.NaN;
    }
}
