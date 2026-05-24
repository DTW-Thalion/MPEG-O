package global.thalion.ttio.browser.progress;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProgressFormatterTest {

    private static final long NOW = 1_000_000L;

    @Test
    void bytesKnownUnitsNa() {
        ProgressReport r = new ProgressReport("uploading",
            1_262_720_385L, 3_006_477_107L, -1L, -1L,
            19_293_798.4, Double.NaN, 87L, 5L, NOW);
        assertEquals(
            "42.0% · 1.2 GB / 2.8 GB · 18.4 MB/s · ETA 1m 27s",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void unitsKnownBytesNa() {
        ProgressReport r = new ProgressReport("encoding",
            -1L, -1L, 1247L, 8420L,
            Double.NaN, 312.0, 23L, 4L, NOW);
        assertEquals(
            "1,247 / 8,420 AUs · 312 AU/s · ETA 23s",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void neitherTotalKnownShowsBytesProcessed() {
        ProgressReport r = new ProgressReport("streaming",
            1_258_291L, -1L, -1L, -1L,
            19_293_798.4, Double.NaN, -1L, 72L, NOW);
        assertEquals(
            "1.2 MB processed · 18.4 MB/s · elapsed 1m 12s",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void stalledHidesRateAndShowsLastActivity() {
        ProgressReport r = new ProgressReport("uploading",
            500L, 1000L, -1L, -1L,
            50.0, Double.NaN, -1L, 60L, NOW - 12_000L);
        assertEquals(
            "stalled — last activity 12s ago",
            ProgressFormatter.line(r, NOW));
    }

    @Test
    void rateNanShowsBareBytesProcessed() {
        ProgressReport r = new ProgressReport("uploading",
            500L, 1000L, -1L, -1L,
            Double.NaN, Double.NaN, -1L, 0L, NOW);
        assertEquals(
            "50.0% · 500 B / 1000 B · measuring rate…",
            ProgressFormatter.line(r, NOW));
    }
}
