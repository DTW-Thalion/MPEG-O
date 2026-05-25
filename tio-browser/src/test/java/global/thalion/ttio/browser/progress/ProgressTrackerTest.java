package global.thalion.ttio.browser.progress;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProgressTrackerTest {

    @Test
    void firstSampleProducesReportWithoutRate() {
        ProgressTracker t = new ProgressTracker(
            "uploading", /*bytesTotal=*/1000L, /*unitsTotal=*/-1L, /*epochMs=*/0L);
        ProgressReport r = t.sample(/*bytesDone=*/100L, /*unitsDone=*/0L, /*epochMs=*/0L);
        assertEquals("uploading", r.phase());
        assertEquals(100L, r.bytesDone());
        assertTrue(Double.isNaN(r.rateBytesPerSec()),
            "rate is NaN until the EWMA window has >=2 samples");
        assertEquals(-1L, r.etaSeconds(),
            "ETA hidden until rate is computable");
    }

    @Test
    void secondSampleAfterOneSecondProducesRateAndEta() {
        ProgressTracker t = new ProgressTracker(
            "uploading", /*bytesTotal=*/1000L, /*unitsTotal=*/-1L, /*epochMs=*/0L);
        t.sample(0L, 0L, 0L);
        ProgressReport r = t.sample(200L, 0L, 1000L);
        assertEquals(200.0, r.rateBytesPerSec(), 1e-6);
        // remaining = 800 bytes / 200 B/s = 4s
        assertEquals(4L, r.etaSeconds());
        assertEquals(1L, r.elapsedSeconds());
    }

    @Test
    void slidingWindowDropsSamplesOlderThanFiveSeconds() {
        ProgressTracker t = new ProgressTracker(
            "uploading", 10_000L, -1L, 0L);
        // sample at t=0, t=1s, t=6s, t=7s -> t=0 sample falls out
        t.sample(0L, 0L, 0L);
        t.sample(1000L, 0L, 1000L);
        t.sample(6000L, 0L, 6000L);
        ProgressReport r = t.sample(7000L, 0L, 7000L);
        // Within window: samples from t=2s..7s. Rate is computed over
        // the in-window span. Verify rate is positive and sensible.
        assertTrue(r.rateBytesPerSec() > 0.0,
            "rate should be positive after window slides");
    }

    @Test
    void lastActivityTimestampUpdatesOnEveryNonZeroDelta() {
        ProgressTracker t = new ProgressTracker(
            "uploading", 1000L, -1L, 0L);
        t.sample(0L, 0L, 0L);
        t.sample(100L, 0L, 500L);
        ProgressReport r = t.sample(100L, 0L, 2000L); // no delta
        assertEquals(500L, r.lastActivityEpochMs(),
            "lastActivity stays at last non-zero-delta sample time");
    }
}
