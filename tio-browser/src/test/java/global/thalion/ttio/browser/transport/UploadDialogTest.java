package global.thalion.ttio.browser.transport;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link UploadDialog}'s static validators.
 * No JavaFX toolkit required — validators are pure static methods.
 */
class UploadDialogTest {

    @Test
    void acceptsAllSupportedSchemes() {
        assertTrue(UploadDialog.isValidUrl("http://host/path"));
        assertTrue(UploadDialog.isValidUrl("https://host/path"));
        assertTrue(UploadDialog.isValidUrl("ws://host:8080/"));
        assertTrue(UploadDialog.isValidUrl("wss://secure.host:443/api"));
        assertTrue(UploadDialog.isValidUrl("http://127.0.0.1:9000/upload"));
        assertTrue(UploadDialog.isValidUrl("https://example.com"));
    }

    @Test
    void rejectsUnsupportedAndEmptyInputs() {
        assertFalse(UploadDialog.isValidUrl(""));
        assertFalse(UploadDialog.isValidUrl(null));
        assertFalse(UploadDialog.isValidUrl("ftp://host/x"));
        assertFalse(UploadDialog.isValidUrl("file:///tmp/x.tio"));
        assertFalse(UploadDialog.isValidUrl("smtp://host"));
        assertFalse(UploadDialog.isValidUrl("justtext"));
        assertFalse(UploadDialog.isValidUrl("//host/path"));
    }
}
