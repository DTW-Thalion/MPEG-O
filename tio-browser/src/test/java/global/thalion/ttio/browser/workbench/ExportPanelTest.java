/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class ExportPanelTest {

    // ---- extensionFor ----

    @Test
    void extensionForKnownFormats() {
        assertEquals("mzML", ExportPanel.extensionFor("mzML"));
        assertEquals("mzTab", ExportPanel.extensionFor("mzTab"));
        assertEquals("bam", ExportPanel.extensionFor("BAM"));
        assertEquals("cram", ExportPanel.extensionFor("CRAM"));
        assertEquals("fasta", ExportPanel.extensionFor("FASTA"));
        assertEquals("fastq", ExportPanel.extensionFor("FASTQ"));
        assertEquals("jdx", ExportPanel.extensionFor("JCAMP-DX"));
    }

    @Test
    void extensionForUnknownFallsBack() {
        assertEquals("out", ExportPanel.extensionFor("WeirdFormat"));
        assertEquals("out", ExportPanel.extensionFor(null));
    }

    // ---- deriveExportTarget ----

    @Test
    void deriveTargetSwapsExtension() {
        Path p = ExportPanel.deriveExportTarget("/data/sample.tio", "BAM");
        assertEquals("/data/sample.bam", p.toString().replace('\\', '/'));
    }

    @Test
    void deriveTargetPreservesDirectory() {
        Path p = ExportPanel.deriveExportTarget("/srv/dl/run1.tio", "mzML");
        String s = p.toString().replace('\\', '/');
        assertTrue(s.startsWith("/srv/dl/"), s);
        assertTrue(s.endsWith("run1.mzML"), s);
    }

    @Test
    void deriveTargetHandlesNoDirectory() {
        Path p = ExportPanel.deriveExportTarget("sample.tio", "FASTQ");
        assertEquals("sample.fastq", p.toString().replace('\\', '/'));
    }

    @Test
    void deriveTargetFallbackForNullSource() {
        Path p = ExportPanel.deriveExportTarget(null, "BAM");
        assertEquals("export.bam", p.getFileName().toString());
    }

    // ---- isValidTioPath ----

    @Test
    void tioPathValidator() {
        assertTrue(ExportPanel.isValidTioPath("/data/x.tio"));
        assertTrue(ExportPanel.isValidTioPath("x.TIO"));
        assertTrue(ExportPanel.isValidTioPath("  x.tio  "));
        assertFalse(ExportPanel.isValidTioPath(null));
        assertFalse(ExportPanel.isValidTioPath(""));
        assertFalse(ExportPanel.isValidTioPath("x.bam"));
    }
}
