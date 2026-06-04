/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;

/** JT8: importer registry mirrors Python {@code ttio.importers.registry}. */
final class ImporterRegistryTest {

    private static final Set<String> EXPECTED_KEYS = Set.of(
        "mzml", "mztab", "imzml", "nmrml", "jcamp-dx",
        "bruker-timstof", "waters-masslynx", "thermo-raw",
        "bam", "sam", "cram");

    @Test
    void registryKeysAreTheElevenKeySet() {
        assertEquals(EXPECTED_KEYS, Set.copyOf(ImporterRegistry.registryKeys()));
        assertEquals(11, ImporterRegistry.registryKeys().size());
    }

    @Test
    void registryKeysAreSorted() {
        List<String> keys = ImporterRegistry.registryKeys();
        assertEquals(keys.stream().sorted().toList(), keys);
    }

    @Test
    void normalizeAppliesAliasesTrimAndLowercase() {
        assertEquals("thermo-raw", ImporterRegistry.normalize("thermo"));
        assertEquals("bam", ImporterRegistry.normalize("  Bam "));
        assertEquals("thermo-raw", ImporterRegistry.normalize("raw"));
        assertEquals("waters-masslynx", ImporterRegistry.normalize("masslynx"));
        assertEquals("bruker-timstof", ImporterRegistry.normalize("timstof"));
        assertEquals("jcamp-dx", ImporterRegistry.normalize("jcamp"));
        assertEquals("mzml", ImporterRegistry.normalize("mzml"));
    }

    @Test
    void specForUnknownThrows() {
        assertThrows(UnknownFormatError.class,
            () -> ImporterRegistry.specFor("ome-tiff"));
    }

    @Test
    void supportedEncodeFormatsIsRegistryUnionCliDelegated() {
        Set<String> expected = new java.util.HashSet<>(EXPECTED_KEYS);
        expected.add("fasta");
        expected.add("fastq");
        assertEquals(expected,
            Set.copyOf(ImporterRegistry.supportedEncodeFormats()));
        // sorted
        List<String> got = ImporterRegistry.supportedEncodeFormats();
        assertEquals(got.stream().sorted().toList(), got);
    }

    @Test
    void everySpecHasNonNullReader() {
        for (String key : ImporterRegistry.registryKeys()) {
            FormatSpec spec = ImporterRegistry.specFor(key);
            assertNotNull(spec.reader(), key);
            assertInstanceOf(Reader.class, spec.reader(), key);
        }
    }

    @Test
    void bamSpecMatchesPython() {
        FormatSpec spec = ImporterRegistry.specFor("bam");
        assertEquals("BAM", spec.displayName());
        assertEquals(List.of(".bam"), spec.extensions());
        assertEquals("samtools", spec.requiredTool());
    }

    @Test
    void mzmlSpecMatchesPython() {
        FormatSpec spec = ImporterRegistry.specFor("mzml");
        assertEquals("mzML", spec.displayName());
        assertEquals(List.of(".mzML", ".mzML.gz"), spec.extensions());
        assertEquals(null, spec.requiredTool());
    }

    @Test
    void isRegistryFormatMatchesAliases() {
        assertTrue(ImporterRegistry.isRegistryFormat("thermo"));
        assertTrue(ImporterRegistry.isRegistryFormat("BAM"));
        assertTrue(!ImporterRegistry.isRegistryFormat("fasta"));
        assertTrue(!ImporterRegistry.isRegistryFormat("ome-tiff"));
    }
}
