package global.thalion.ttio.browser.progress;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProgressReportTest {

    @Test
    void determinateWhenBytesTotalKnown() {
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 100.0, Double.NaN, 5, 5, 0L);
        assertTrue(r.isDeterminate());
        assertEquals(0.5, r.percent(), 1e-9);
    }

    @Test
    void determinateWhenUnitsTotalKnownEvenWithoutBytes() {
        ProgressReport r = new ProgressReport("encoding",
            -1, -1, 250, 1000, Double.NaN, 50.0, 15, 5, 0L);
        assertTrue(r.isDeterminate());
        assertEquals(0.25, r.percent(), 1e-9);
    }

    @Test
    void indeterminateWhenNeitherTotalKnown() {
        ProgressReport r = new ProgressReport("streaming",
            500, -1, -1, -1, 100.0, Double.NaN, -1, 5, 0L);
        assertFalse(r.isDeterminate());
        assertTrue(Double.isNaN(r.percent()));
    }

    @Test
    void stalledWhenRateLowAndQuietForOverTenSeconds() {
        long now = 1_000_000L;
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 50.0, Double.NaN, -1, 60, now - 11_000L);
        assertTrue(r.isStalled(now));
    }

    @Test
    void notStalledWhenRateAdequate() {
        long now = 1_000_000L;
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 5000.0, Double.NaN, 5, 60, now - 11_000L);
        assertFalse(r.isStalled(now));
    }

    @Test
    void notStalledWhenRecentActivity() {
        long now = 1_000_000L;
        ProgressReport r = new ProgressReport("uploading",
            500, 1000, -1, -1, 0.0, Double.NaN, -1, 60, now - 5_000L);
        assertFalse(r.isStalled(now));
    }
}
