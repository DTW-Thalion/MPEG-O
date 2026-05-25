package global.thalion.ttio.browser.util;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class UnitsTest {

    @Test
    void humanBytesScales() {
        assertEquals("0 B", Units.humanBytes(0L));
        assertEquals("512 B", Units.humanBytes(512L));
        assertEquals("1.0 KB", Units.humanBytes(1024L));
        assertEquals("1.5 KB", Units.humanBytes(1536L));
        assertEquals("1.2 MB", Units.humanBytes(1_258_291L));
        assertEquals("2.8 GB", Units.humanBytes(3_006_477_107L));
        assertEquals("1.0 TB", Units.humanBytes(1_099_511_627_776L));
    }

    @Test
    void humanRateAppendsPerSecond() {
        assertEquals("18.4 MB/s", Units.humanRate(19_293_798.4));
        assertEquals("312 B/s", Units.humanRate(312.0));
    }

    @Test
    void humanDurationHumanizesSeconds() {
        assertEquals("0s", Units.humanDuration(0L));
        assertEquals("23s", Units.humanDuration(23L));
        assertEquals("1m 27s", Units.humanDuration(87L));
        assertEquals("2h 5m", Units.humanDuration(7500L));
        assertEquals("1d 3h", Units.humanDuration(97_200L));
    }

    @Test
    void humanCountFormatsWithThousandsSeparator() {
        assertEquals("0", Units.humanCount(0L));
        assertEquals("1,247", Units.humanCount(1247L));
        assertEquals("8,420", Units.humanCount(8420L));
    }
}
