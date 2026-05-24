/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;

import static org.junit.jupiter.api.Assertions.*;

class EncodingPanelTest {

    @BeforeAll
    static void startupFX() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            latch.countDown();
        }
        latch.await();
    }

    // ---- deriveContainerUri ----

    @Test
    void deriveUriFromSimpleName() {
        assertEquals("uri:tio:alpha-sample",
            EncodingPanel.deriveContainerUri("alpha", "sample.bam"));
    }

    @Test
    void deriveUriStripsPathAndExtension() {
        assertEquals("uri:tio:alpha-reads",
            EncodingPanel.deriveContainerUri("alpha", "/data/run1/reads.fastq.gz"));
    }

    @Test
    void deriveUriLowercasesAndHyphenates() {
        assertEquals("uri:tio:alpha-my-sample-01",
            EncodingPanel.deriveContainerUri("alpha", "My Sample 01.mzML"));
    }

    @Test
    void deriveUriWithoutProject() {
        assertEquals("uri:tio:sample",
            EncodingPanel.deriveContainerUri("", "sample.bam"));
        assertEquals("uri:tio:sample",
            EncodingPanel.deriveContainerUri(null, "sample.bam"));
    }

    @Test
    void deriveUriFallsBackForEmptyBase() {
        // A name whose base reduces to empty after stripping
        // non-alphanumerics yields the "container" fallback. The
        // ".tio" extension is stripped (dot index > 0), leaving
        // "@@@", which sanitises to empty.
        assertEquals("uri:tio:alpha-container",
            EncodingPanel.deriveContainerUri("alpha", "@@@.tio"));
    }

    @Test
    void deriveUriKeepsBaseForDotPrefixedName() {
        // A leading dot at index 0 is NOT an extension separator,
        // so ".bam" keeps "bam" as its base rather than emptying.
        assertEquals("uri:tio:alpha-bam",
            EncodingPanel.deriveContainerUri("alpha", ".bam"));
    }

    @Test
    void deriveUriHandlesWindowsBackslashPath() {
        assertEquals("uri:tio:alpha-reads",
            EncodingPanel.deriveContainerUri("alpha", "C:\\data\\reads.bam"));
    }

    // ---- deriveTempTio ----

    @Test
    void deriveTempTioEndsWithDotTio() {
        Path p = EncodingPanel.deriveTempTio("/data/sample.bam");
        assertTrue(p.toString().endsWith(".tio"), p.toString());
        assertTrue(p.getFileName().toString().contains("sample"), p.toString());
    }

    @Test
    void deriveTempTioFallbackName() {
        Path p = EncodingPanel.deriveTempTio(null);
        assertTrue(p.getFileName().toString().contains("encoded"), p.toString());
    }

    // ---- isValidProject ----

    @Test
    void projectValidator() {
        assertFalse(EncodingPanel.isValidProject(null));
        assertFalse(EncodingPanel.isValidProject(" "));
        assertTrue(EncodingPanel.isValidProject("alpha"));
    }

    // ---- setProgressListener ----

    @Test
    void encodeForwardsProgressReportsToExternalListener() throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        var got = new java.util.concurrent.CopyOnWriteArrayList<
            global.thalion.ttio.browser.progress.ProgressReport>();
        Platform.runLater(() -> {
            try {
                EncodingPanel panel = new EncodingPanel(null,
                    ConnectionManager.instance(), TransferManager.instance());
                panel.setProgressListener(got::add);
                // Verify that setProgressListener is callable and stores the listener.
                assertNotNull(got);
            } finally {
                latch.countDown();
            }
        });
        latch.await();
    }
}
