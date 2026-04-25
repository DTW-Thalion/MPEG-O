/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Identification;
import global.thalion.ttio.Quantification;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Cross-language counterpart of
 *   python/tests/integration/test_mztab_import.py
 *   objc/Tests/TestMzTabReader.m
 */
final class MzTabReaderTest {

    private static final String PROTEOMICS_FIXTURE =
        "COM\tSynthetic mzTab 1.0 fixture for v0.9 M60.\n"
      + "MTD\tmzTab-version\t1.0\n"
      + "MTD\tdescription\tSynthetic BSA digest results\n"
      + "MTD\tms_run[1]-location\tfile:///tmp/bsa_digest.mzML\n"
      + "MTD\tsoftware[1]\t[MS, MS:1001456, X!Tandem, v2.4.0]\n"
      + "MTD\tpsm_search_engine_score[1]\t[MS, MS:1001330, X!Tandem expect, ]\n"
      + "MTD\tassay[1]-sample_ref\tsample[1]\n"
      + "MTD\tassay[2]-sample_ref\tsample[2]\n"
      + "\n"
      + "PRH\taccession\tdescription\ttaxid\tspecies\tdatabase\tdatabase_version\tsearch_engine\tbest_search_engine_score[1]\tprotein_abundance_assay[1]\tprotein_abundance_assay[2]\n"
      + "PRT\tP02769\tBovine serum albumin\t9913\tBos taurus\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.99\t123456.7\t98765.4\n"
      + "\n"
      + "PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\tdatabase_version\tsearch_engine\tsearch_engine_score[1]\tmodifications\tretention_time\tcharge\texp_mass_to_charge\tcalc_mass_to_charge\tpre\tpost\tstart\tend\tspectra_ref\n"
      + "PSM\tDTHKSEIAHR\t1\tP02769\t1\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.95\tnull\t120.5\t2\t413.7\t413.69\tK\tI\t125\t134\tms_run[1]:scan=42\n"
      + "PSM\tLVNELTEFAK\t2\tP02769\t1\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.88\tnull\t130.2\t2\t582.3\t582.29\tK\tS\t66\t75\tms_run[1]:scan=87\n"
      + "PSM\tYICDNQDTISSK\t3\tP02769\t1\tUniProtKB\t2024_04\t[MS, MS:1001456, X!Tandem, v2.4.0]\t0.91\tnull\t150.8\t2\t701.4\t701.38\tK\tL\t209\t220\tms_run[1]:scan=152\n";

    private static final String METABOLOMICS_FIXTURE =
        "MTD\tmzTab-version\t2.0.0-M\n"
      + "MTD\tmzTab-ID\tMTBLS9999\n"
      + "MTD\tdescription\tSynthetic metabolomics study\n"
      + "MTD\tms_run[1]-location\tfile:///tmp/glucose_run.mzML\n"
      + "MTD\tsoftware[1]\t[MS, MS:1003121, OpenMS, v3.0.0]\n"
      + "MTD\tstudy_variable[1]-description\tcontrol\n"
      + "MTD\tstudy_variable[2]-description\ttreatment\n"
      + "\n"
      + "SMH\tSML_ID\tdatabase_identifier\tchemical_formula\tsmiles\tinchi\tchemical_name\turi\tbest_id_confidence_measure\tbest_id_confidence_value\tabundance_study_variable[1]\tabundance_study_variable[2]\n"
      + "SML\t1\tCHEBI:17234\tC6H12O6\tOC[C@H]1OC(O)[C@H](O)[C@@H](O)[C@@H]1O\tnull\tD-glucose\tnull\t[MS, MS:1003124, mass match,]\t0.95\t1.5e6\t2.1e6\n"
      + "SML\t2\tCHEBI:30769\tC6H8O7\tOC(=O)CC(O)(CC(O)=O)C(O)=O\tnull\tcitric acid\tnull\t[MS, MS:1003124, mass match,]\t0.88\t8.2e5\t7.5e5\n";

    private static Path writeFixture(Path tmp, String name, String body) throws IOException {
        Path p = tmp.resolve(name);
        Files.writeString(p, body);
        return p;
    }

    @Test
    void proteomicsVersionAndMetadata(@TempDir Path tmp) throws IOException {
        Path fix = writeFixture(tmp, "proteomics.mztab", PROTEOMICS_FIXTURE);
        MzTabReader.MzTabImport result = MzTabReader.read(fix);
        assertEquals("1.0", result.version());
        assertFalse(result.isMetabolomics());
        assertTrue(result.description().contains("BSA"));
        assertEquals("file:///tmp/bsa_digest.mzML", result.msRunLocations().get(1));
        assertTrue(result.software().get(0).contains("X!Tandem"));
    }

    @Test
    void proteomicsPsmCountAndScores(@TempDir Path tmp) throws IOException {
        Path fix = writeFixture(tmp, "proteomics.mztab", PROTEOMICS_FIXTURE);
        MzTabReader.MzTabImport result = MzTabReader.read(fix);
        assertEquals(3, result.identifications().size());
        List<Double> scores = result.identifications().stream()
            .map(Identification::confidenceScore)
            .collect(Collectors.toList());
        assertEquals(List.of(0.95, 0.88, 0.91), scores);
        for (Identification i : result.identifications()) {
            assertEquals("P02769", i.chemicalEntity());
            assertEquals("bsa_digest", i.runName(),
                "run name should resolve from ms_run[1]-location basename");
        }
    }

    @Test
    void proteomicsPsmSpectrumIndices(@TempDir Path tmp) throws IOException {
        Path fix = writeFixture(tmp, "proteomics.mztab", PROTEOMICS_FIXTURE);
        MzTabReader.MzTabImport result = MzTabReader.read(fix);
        List<Integer> idxs = result.identifications().stream()
            .map(Identification::spectrumIndex)
            .collect(Collectors.toList());
        assertEquals(List.of(42, 87, 152), idxs);
    }

    @Test
    void proteomicsProteinAbundance(@TempDir Path tmp) throws IOException {
        Path fix = writeFixture(tmp, "proteomics.mztab", PROTEOMICS_FIXTURE);
        MzTabReader.MzTabImport result = MzTabReader.read(fix);
        assertEquals(2, result.quantifications().size());
        Quantification first = result.quantifications().get(0);
        Quantification second = result.quantifications().get(1);
        assertEquals("P02769", first.chemicalEntity());
        assertEquals(123456.7, first.abundance(), 1e-6);
        assertEquals(98765.4, second.abundance(), 1e-6);
        assertEquals("sample[1]", first.sampleRef());
        assertEquals("sample[2]", second.sampleRef());
    }

    @Test
    void metabolomicsDispatchAndIds(@TempDir Path tmp) throws IOException {
        Path fix = writeFixture(tmp, "metabolomics.mztab", METABOLOMICS_FIXTURE);
        MzTabReader.MzTabImport result = MzTabReader.read(fix);
        assertEquals("2.0.0-M", result.version());
        assertTrue(result.isMetabolomics());
        assertEquals(2, result.identifications().size());
        assertEquals("CHEBI:17234", result.identifications().get(0).chemicalEntity());
        assertEquals(0.95, result.identifications().get(0).confidenceScore(), 1e-9);
        // 2 metabolites × 2 study variables = 4 quantifications.
        assertEquals(4, result.quantifications().size());
    }

    @Test
    void missingVersion_raisesParseException(@TempDir Path tmp) throws IOException {
        Path bad = writeFixture(tmp, "noversion.mztab", "MTD\tdescription\tno version line\n");
        MzTabReader.MzTabParseException ex = assertThrows(
            MzTabReader.MzTabParseException.class,
            () -> MzTabReader.read(bad));
        assertTrue(ex.getMessage().contains("missing MTD mzTab-version"));
    }

    @Test
    void missingFile_raisesParseException(@TempDir Path tmp) {
        Path absent = tmp.resolve("absent.mztab");
        MzTabReader.MzTabParseException ex = assertThrows(
            MzTabReader.MzTabParseException.class,
            () -> MzTabReader.read(absent));
        assertTrue(ex.getMessage().contains("not found"));
    }
}
