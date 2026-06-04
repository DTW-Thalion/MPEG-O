/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.assertEquals;

import global.thalion.ttio.exporters.ExporterRegistry;
import global.thalion.ttio.importers.ImporterRegistry;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * Cross-language golden fence: the Java importer/exporter registries must
 * expose EXACTLY the same canonical key sets and alias maps as the Python
 * registries ({@code ttio.importers.registry} / {@code ttio.exporters.registry}).
 *
 * <p>The expected lists below are hardcoded from the Python files; a drift in
 * either language breaks this test.
 */
final class RegistryParityTest {

    /** Sorted import keys, copied verbatim from Python {@code registry_keys()}. */
    private static final List<String> PY_IMPORT_KEYS = List.of(
        "bam", "bruker-timstof", "cram", "imzml", "jcamp-dx", "mzml",
        "mztab", "nmrml", "sam", "thermo-raw", "waters-masslynx");

    /** Sorted export keys, copied verbatim from Python {@code registry_keys()}. */
    private static final List<String> PY_EXPORT_KEYS = List.of(
        "bam", "cram", "imzml", "isa", "jcamp-dx", "mzml", "mztab", "nmrml");

    private static final Map<String, String> PY_IMPORT_ALIASES = Map.ofEntries(
        Map.entry("thermo", "thermo-raw"),
        Map.entry("thermo.raw", "thermo-raw"),
        Map.entry("raw", "thermo-raw"),
        Map.entry("waters", "waters-masslynx"),
        Map.entry("masslynx", "waters-masslynx"),
        Map.entry("bruker", "bruker-timstof"),
        Map.entry("timstof", "bruker-timstof"),
        Map.entry("tdf", "bruker-timstof"),
        Map.entry("jcamp", "jcamp-dx"),
        Map.entry("jdx", "jcamp-dx"),
        Map.entry("dx", "jcamp-dx"),
        Map.entry("jcm", "jcamp-dx"));

    private static final Map<String, String> PY_EXPORT_ALIASES = Map.ofEntries(
        Map.entry("isa-tab", "isa"),
        Map.entry("isatab", "isa"),
        Map.entry("jcamp", "jcamp-dx"),
        Map.entry("jdx", "jcamp-dx"),
        Map.entry("dx", "jcamp-dx"),
        Map.entry("jcm", "jcamp-dx"));

    @Test
    void importKeysMatchPython() {
        assertEquals(PY_IMPORT_KEYS, ImporterRegistry.registryKeys());
    }

    @Test
    void exportKeysMatchPython() {
        assertEquals(PY_EXPORT_KEYS, ExporterRegistry.registryKeys());
    }

    @Test
    void importAliasesMatchPython() {
        for (Map.Entry<String, String> e : PY_IMPORT_ALIASES.entrySet()) {
            assertEquals(e.getValue(), ImporterRegistry.normalize(e.getKey()),
                "import alias " + e.getKey());
        }
    }

    @Test
    void exportAliasesMatchPython() {
        for (Map.Entry<String, String> e : PY_EXPORT_ALIASES.entrySet()) {
            assertEquals(e.getValue(), ExporterRegistry.normalize(e.getKey()),
                "export alias " + e.getKey());
        }
    }

    @Test
    void cliDelegatedAreNotRegistered() {
        assertEquals(false, ImporterRegistry.isRegistryFormat("fasta"));
        assertEquals(false, ImporterRegistry.isRegistryFormat("fastq"));
        assertEquals(false, ExporterRegistry.isRegistryFormat("fasta"));
        assertEquals(false, ExporterRegistry.isRegistryFormat("fastq"));
    }
}
