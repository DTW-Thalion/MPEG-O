package global.thalion.ttio.browser.transport;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link DownloadDialog}'s static validators.
 * No JavaFX toolkit required - validators are pure static methods.
 */
class DownloadDialogTest {

    @Test
    void rejectsNonWsScheme() {
        assertFalse(DownloadDialog.isValidUrl(""));
        assertFalse(DownloadDialog.isValidUrl(null));
        assertFalse(DownloadDialog.isValidUrl("http://x"));
        assertFalse(DownloadDialog.isValidUrl("https://x"));
        assertFalse(DownloadDialog.isValidUrl("ftp://x"));
        assertTrue(DownloadDialog.isValidUrl("ws://x:8080/"));
        assertTrue(DownloadDialog.isValidUrl("wss://x.example.com/feed"));
        assertTrue(DownloadDialog.isValidUrl("ws://127.0.0.1:9000"));
        assertTrue(DownloadDialog.isValidUrl("wss://secure.host:443/api"));
    }

    @Test
    void filterJsonValidator() {
        assertTrue(DownloadDialog.isValidJson("{}"));
        assertTrue(DownloadDialog.isValidJson("{\"runs\": [\"r1\"]}"));
        assertTrue(DownloadDialog.isValidJson("{\"ms_level\": 2}"));
        assertTrue(DownloadDialog.isValidJson("{\"rt_min\": 1.0, \"rt_max\": 5.0}"));
        assertFalse(DownloadDialog.isValidJson("{not json"));
        assertFalse(DownloadDialog.isValidJson(""));
        assertFalse(DownloadDialog.isValidJson("   "));
        assertFalse(DownloadDialog.isValidJson(null));
        assertTrue(DownloadDialog.isValidJson("[1, 2, 3]"));
    }
}