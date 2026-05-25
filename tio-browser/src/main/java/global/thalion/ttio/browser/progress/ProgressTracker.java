package global.thalion.ttio.browser.progress;

import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Aggregates raw (bytesDone, unitsDone, epochMs) samples into a
 * {@link ProgressReport}. Rate is a sliding 5-second window mean,
 * computed over samples whose timestamps lie within the window. ETA
 * is derived from rate and remaining bytes (or units). lastActivity
 * tracks the latest non-zero-delta sample.
 */
public final class ProgressTracker {
    private static final long WINDOW_MS = 5_000L;

    private final String phase;
    private final long bytesTotal;
    private final long unitsTotal;
    private final long startEpochMs;
    private final Deque<Sample> window = new ArrayDeque<>();
    private long lastActivityEpochMs;
    private long lastBytesDone = 0L;
    private long lastUnitsDone = 0L;

    private record Sample(long epochMs, long bytesDone, long unitsDone) {}

    public ProgressTracker(String phase, long bytesTotal,
                           long unitsTotal, long startEpochMs) {
        this.phase = phase;
        this.bytesTotal = bytesTotal;
        this.unitsTotal = unitsTotal;
        this.startEpochMs = startEpochMs;
        this.lastActivityEpochMs = startEpochMs;
    }

    public ProgressReport sample(long bytesDone, long unitsDone,
                                  long epochMs) {
        if (bytesDone != lastBytesDone || unitsDone != lastUnitsDone) {
            lastActivityEpochMs = epochMs;
            lastBytesDone = bytesDone;
            lastUnitsDone = unitsDone;
        }
        window.addLast(new Sample(epochMs, bytesDone, unitsDone));
        long cutoff = epochMs - WINDOW_MS;
        while (window.size() > 1 && window.peekFirst().epochMs() < cutoff) {
            window.removeFirst();
        }

        double rateBytes = Double.NaN;
        double rateUnits = Double.NaN;
        long eta = -1L;
        if (window.size() >= 2) {
            Sample first = window.peekFirst();
            Sample last = window.peekLast();
            double dtSec = (last.epochMs() - first.epochMs()) / 1000.0;
            if (dtSec > 0.0) {
                rateBytes = (last.bytesDone() - first.bytesDone()) / dtSec;
                rateUnits = (last.unitsDone() - first.unitsDone()) / dtSec;
                if (bytesTotal > 0 && rateBytes > 0) {
                    long remaining = bytesTotal - bytesDone;
                    eta = Math.max(0L, (long) (remaining / rateBytes));
                } else if (unitsTotal > 0 && rateUnits > 0) {
                    long remaining = unitsTotal - unitsDone;
                    eta = Math.max(0L, (long) (remaining / rateUnits));
                }
            }
        }
        long elapsedSec = (epochMs - startEpochMs) / 1000L;
        return new ProgressReport(phase, bytesDone, bytesTotal,
            unitsDone, unitsTotal, rateBytes, rateUnits, eta,
            elapsedSec, lastActivityEpochMs);
    }
}
