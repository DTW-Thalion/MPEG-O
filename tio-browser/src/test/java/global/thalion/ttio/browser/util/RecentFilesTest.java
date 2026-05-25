package global.thalion.ttio.browser.util;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class RecentFilesTest {

    @Test
    void recordsAndReturnsMostRecentFirstUpToCap() {
        RecentFiles r = new RecentFiles("test-cap-8", 8);
        r.clearForTest();
        r.record("/a.tio");
        r.record("/b.tio");
        r.record("/c.tio");
        assertEquals(List.of("/c.tio", "/b.tio", "/a.tio"), r.recent());
    }

    @Test
    void dedupesAndPromotesToFront() {
        RecentFiles r = new RecentFiles("test-dedup", 8);
        r.clearForTest();
        r.record("/a.tio");
        r.record("/b.tio");
        r.record("/a.tio");
        assertEquals(List.of("/a.tio", "/b.tio"), r.recent());
    }

    @Test
    void evictsOldestPastCap() {
        RecentFiles r = new RecentFiles("test-cap-3", 3);
        r.clearForTest();
        r.record("/1"); r.record("/2"); r.record("/3"); r.record("/4");
        assertEquals(List.of("/4", "/3", "/2"), r.recent());
    }
}
