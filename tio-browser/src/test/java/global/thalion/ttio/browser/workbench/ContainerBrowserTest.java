/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.containers.ContainerManifest;
import global.thalion.ttio.workbench.containers.ContainerManifest.GenomicRunSummary;
import global.thalion.ttio.workbench.containers.ContainerManifest.MsRunSummary;
import global.thalion.ttio.workbench.containers.ContainerManifest.NmrRunSummary;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Pure-unit tests for {@link ContainerBrowser}'s static helpers.
 * No FX toolkit required.
 */
class ContainerBrowserTest {

    // ---- parseLimit ----

    @Test
    void parseLimitAcceptsPositiveInteger() {
        assertEquals(50, ContainerBrowser.parseLimit("50"));
        assertEquals(500, ContainerBrowser.parseLimit("500"));
        assertEquals(1, ContainerBrowser.parseLimit("1"));
    }

    @Test
    void parseLimitTrimsWhitespace() {
        assertEquals(50, ContainerBrowser.parseLimit("  50  "));
    }

    @Test
    void parseLimitRejectsBlankAndNull() {
        assertNull(ContainerBrowser.parseLimit(null));
        assertNull(ContainerBrowser.parseLimit(""));
        assertNull(ContainerBrowser.parseLimit("   "));
    }

    @Test
    void parseLimitRejectsNonNumeric() {
        assertNull(ContainerBrowser.parseLimit("abc"));
        assertNull(ContainerBrowser.parseLimit("50x"));
    }

    @Test
    void parseLimitRejectsZeroAndNegative() {
        assertNull(ContainerBrowser.parseLimit("0"));
        assertNull(ContainerBrowser.parseLimit("-10"));
    }

    // ---- formatTimestamp ----

    @Test
    void formatTimestampRendersUtcIso8601() {
        // 1700000000 = 2023-11-14T22:13:20Z
        String formatted = ContainerBrowser.formatTimestamp(1700000000L);
        assertEquals("2023-11-14T22:13:20Z", formatted);
    }

    @Test
    void formatTimestampZeroIsBlank() {
        assertEquals("", ContainerBrowser.formatTimestamp(0L));
    }

    @Test
    void formatTimestampNegativeIsBlank() {
        // Defensive: server should never send a negative timestamp,
        // but if it does, render blank rather than a Gregorian
        // pre-epoch date.
        assertEquals("", ContainerBrowser.formatTimestamp(-1L));
    }

    // ---- renderManifest ----

    @Test
    void renderManifestIncludesUri() {
        ContainerManifest m = ContainerManifest.fromJson(Map.of(
            "uri", "uri:tio:demo",
            "title", "demo"));
        String text = ContainerBrowser.renderManifest(m);
        assertTrue(text.contains("uri:tio:demo"),
            "manifest text should include URI; was: " + text);
        assertTrue(text.contains("demo"),
            "manifest text should include title; was: " + text);
        assertTrue(text.contains("MS runs:      0"),
            "manifest text should show MS runs count; was: " + text);
    }

    @Test
    void renderManifestEnumeratesRunsByType() {
        ContainerManifest m = ContainerManifest.fromJson(Map.of(
            "uri", "uri:tio:demo",
            "ms_runs", List.of(Map.of(
                "name", "run1",
                "spectrum_class", "MassSpectrum",
                "spectrum_count", 1000L)),
            "nmr_runs", List.of(Map.of(
                "name", "nmr1", "spectrum_count", 4L)),
            "genomic_runs", List.of(Map.of(
                "name", "wgs1", "read_count", 100L,
                "platform", "illumina"))));
        String text = ContainerBrowser.renderManifest(m);
        assertTrue(text.contains("run1"), text);
        assertTrue(text.contains("MassSpectrum"), text);
        assertTrue(text.contains("nmr1"), text);
        assertTrue(text.contains("wgs1"), text);
        assertTrue(text.contains("illumina"), text);
    }

    @Test
    void renderManifestStableMultilineShape() {
        // Stability test: rendering an identical manifest twice
        // returns identical strings (no Map iteration-order surprises).
        ContainerManifest m = ContainerManifest.fromJson(Map.of(
            "uri", "uri:tio:demo",
            "ms_runs", List.of(Map.of(
                "name", "run1",
                "spectrum_class", "MassSpectrum",
                "spectrum_count", 1L))));
        assertEquals(
            ContainerBrowser.renderManifest(m),
            ContainerBrowser.renderManifest(m));
    }
}
