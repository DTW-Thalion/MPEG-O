/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class EncodingPanelTest {

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
}
