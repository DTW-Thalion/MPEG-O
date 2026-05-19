/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pure-unit tests for the W5.3 dialog static validators.
 * Dialog behaviour (FX form + submit lifecycle) is covered by the
 * existing transport-dialog smoke pattern; the SDK-level filter
 * builder is the source of truth for value semantics.
 */
class UploadDownloadDialogTest {

    @Test
    void uploadProjectValidator() {
        assertFalse(UploadStartDialog.isValidProject(null));
        assertFalse(UploadStartDialog.isValidProject(""));
        assertFalse(UploadStartDialog.isValidProject("   "));
        assertTrue(UploadStartDialog.isValidProject("alpha"));
    }

    @Test
    void uploadContainerUriValidator() {
        assertFalse(UploadStartDialog.isValidContainerUri(null));
        assertFalse(UploadStartDialog.isValidContainerUri(""));
        assertFalse(UploadStartDialog.isValidContainerUri("uri:tio:"));
        assertFalse(UploadStartDialog.isValidContainerUri("https://x.com"));
        assertTrue(UploadStartDialog.isValidContainerUri("uri:tio:demo"));
        assertTrue(UploadStartDialog.isValidContainerUri("uri:tio:alpha-001"));
        assertTrue(UploadStartDialog.isValidContainerUri(
            "  uri:tio:demo  "));  // trims
    }

    @Test
    void downloadContainerUriValidator() {
        // Same rule as upload.
        assertTrue(DownloadStartDialog.isValidContainerUri("uri:tio:demo"));
        assertFalse(DownloadStartDialog.isValidContainerUri("not-a-uri"));
        assertFalse(DownloadStartDialog.isValidContainerUri("uri:tio:"));
    }
}
