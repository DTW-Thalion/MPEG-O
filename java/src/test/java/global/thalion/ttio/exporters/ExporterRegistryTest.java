/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;

/** JT8: exporter registry mirrors Python {@code ttio.exporters.registry}. */
final class ExporterRegistryTest {

    private static final Set<String> EXPECTED_KEYS = Set.of(
        "mzml", "mztab", "nmrml", "imzml", "jcamp-dx",
        "isa", "bam", "cram");

    @Test
    void registryKeysAreTheEightKeySet() {
        assertEquals(EXPECTED_KEYS, Set.copyOf(ExporterRegistry.registryKeys()));
        assertEquals(8, ExporterRegistry.registryKeys().size());
    }

    @Test
    void registryKeysAreSorted() {
        List<String> keys = ExporterRegistry.registryKeys();
        assertEquals(keys.stream().sorted().toList(), keys);
    }

    @Test
    void normalizeAppliesAliasesTrimAndLowercase() {
        assertEquals("isa", ExporterRegistry.normalize("isa-tab"));
        assertEquals("isa", ExporterRegistry.normalize("isatab"));
        assertEquals("isa", ExporterRegistry.normalize("  ISA "));
        assertEquals("jcamp-dx", ExporterRegistry.normalize("jcamp"));
        assertEquals("jcamp-dx", ExporterRegistry.normalize("jdx"));
        assertEquals("bam", ExporterRegistry.normalize("bam"));
    }

    @Test
    void specForUnknownThrows() {
        assertThrows(UnknownFormatError.class,
            () -> ExporterRegistry.specFor("ome-tiff"));
    }

    @Test
    void supportedExportFormatsIsRegistryUnionCliDelegated() {
        Set<String> expected = new java.util.HashSet<>(EXPECTED_KEYS);
        expected.add("fasta");
        expected.add("fastq");
        assertEquals(expected,
            Set.copyOf(ExporterRegistry.supportedExportFormats()));
        List<String> got = ExporterRegistry.supportedExportFormats();
        assertEquals(got.stream().sorted().toList(), got);
    }

    @Test
    void everySpecHasNonNullWriter() {
        for (String key : ExporterRegistry.registryKeys()) {
            ExportSpec spec = ExporterRegistry.specFor(key);
            assertNotNull(spec.writer(), key);
            assertInstanceOf(Writer.class, spec.writer(), key);
        }
    }

    @Test
    void bamSpec() {
        ExportSpec spec = ExporterRegistry.specFor("bam");
        assertEquals("BAM", spec.displayName());
        assertEquals(List.of(".bam", ".sam"), spec.extensions());
        // Java uses bundled htsjdk (no external samtools); cf. Python which shells out to samtools.
        assertNull(spec.requiredTool());
    }

    @Test
    void isaSpecMatchesPython() {
        ExportSpec spec = ExporterRegistry.specFor("isa");
        assertEquals("ISA-Tab/JSON", spec.displayName());
        assertEquals(List.of(".zip", ".json"), spec.extensions());
        assertEquals(null, spec.requiredTool());
    }

    @Test
    void isRegistryFormatMatchesAliases() {
        assertTrue(ExporterRegistry.isRegistryFormat("isa-tab"));
        assertTrue(ExporterRegistry.isRegistryFormat("jcamp"));
        assertTrue(!ExporterRegistry.isRegistryFormat("fasta"));
        assertTrue(!ExporterRegistry.isRegistryFormat("ome-tiff"));
    }
}
