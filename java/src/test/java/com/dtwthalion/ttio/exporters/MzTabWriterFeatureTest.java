/*
 * TTI-O Java Implementation — M78 PEH/PEP + SFH/SMF + SEH/SME tests.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.exporters;

import com.dtwthalion.ttio.Feature;
import com.dtwthalion.ttio.Identification;
import com.dtwthalion.ttio.Quantification;
import com.dtwthalion.ttio.importers.MzTabReader;
import com.dtwthalion.ttio.importers.MzTabReader.MzTabImport;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M78 writer/reader parity with Python {@code test_m78_feature.py}:
 * PEH/PEP round-trip for proteomics 1.0, SFH/SMF + SEH/SME for
 * metabolomics 2.0.0-M, SFH omission when features are absent, and
 * rank↔confidence mapping.
 */
final class MzTabWriterFeatureTest {

    private static List<Feature> proteomicsFeats() {
        Map<String, Double> a1 = new HashMap<>();
        a1.put("sample_1", 1.5e6);
        a1.put("sample_2", 2.25e6);
        Map<String, Double> a2 = new HashMap<>();
        a2.put("sample_1", 8.0e5);
        return List.of(
            new Feature("pep_1", "run_a", "AAAAPEPTIDER",
                302.5, 615.3291, 2, "",
                a1, List.of("ms_run[1]:scan=42")),
            new Feature("pep_2", "run_a", "QWERTYK",
                450.1, 412.2012, 1, "",
                a2, List.of("ms_run[1]:scan=51"))
        );
    }

    @Test
    void pepRoundTripPreservesFeatureFields(@TempDir Path tmp) throws Exception {
        List<Feature> feats = proteomicsFeats();
        Path out = tmp.resolve("pep.mztab");

        MzTabWriter.WriteResult res = MzTabWriter.write(
            out, List.of(), List.of(), feats,
            "1.0", "M78 PEP round-trip", null);
        assertEquals(2, res.nPEPRows());
        assertEquals(0, res.nPSMRows());

        MzTabImport imp = MzTabReader.read(out);
        assertEquals("1.0", imp.version());
        assertEquals(2, imp.features().size());

        Map<String, Feature> got = new HashMap<>();
        for (Feature f : imp.features()) got.put(f.chemicalEntity(), f);

        Feature a = got.get("AAAAPEPTIDER");
        assertNotNull(a, "AAAAPEPTIDER feature round-trips");
        assertEquals(2, a.charge());
        assertEquals(615.3291, a.expMassToCharge(), 1e-3);
        assertEquals(302.5, a.retentionTimeSeconds(), 1e-3);

        // Abundances re-keyed by assay sample names from MTD round-trip.
        double[] values = a.abundances().values().stream()
            .mapToDouble(Double::doubleValue).sorted().toArray();
        assertEquals(2, values.length);
        assertEquals(1.5e6, values[0], 1.0);
        assertEquals(2.25e6, values[1], 1.0);
    }

    @Test
    void pepWriterAddsPehHeader(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("pep.mztab");
        MzTabWriter.write(out, List.of(), List.of(), proteomicsFeats(),
            "1.0", null, null);
        String text = Files.readString(out);
        List<String> lines = Arrays.asList(text.split("\n"));
        String peh = lines.stream()
            .filter(ln -> ln.startsWith("PEH\t"))
            .findFirst().orElse(null);
        assertNotNull(peh, "writer emits a PEH header");
        List<String> cols = Arrays.asList(peh.split("\t"));
        for (String col : List.of("sequence", "charge", "mass_to_charge",
                                   "retention_time", "spectra_ref")) {
            assertTrue(cols.contains(col), "PEH must contain '" + col + "'");
        }
        assertTrue(cols.stream().anyMatch(c -> c.startsWith("peptide_abundance_assay[")),
            "PEH must contain per-assay abundance columns");
    }

    @Test
    void emptyFeaturesEmitsNoPeh(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("no-pep.mztab");
        List<Identification> ids = List.of(
            new Identification("run_a", 0, "PROT_X", 0.9, List.of())
        );
        MzTabWriter.write(out, ids, List.of(), "1.0", null, null);
        String text = Files.readString(out);
        assertFalse(text.contains("PEH\t"), "no PEH when features empty");
        assertFalse(text.contains("PEP\t"), "no PEP when features empty");
    }

    // --------------------------------------------------------------------- //
    // mzTab-M 2.0.0-M — SFH/SMF + SEH/SME.
    // --------------------------------------------------------------------- //

    private static List<Feature> metabolomicsFeats() {
        Map<String, Double> a1 = new HashMap<>();
        a1.put("sample_a", 1.2e4);
        a1.put("sample_b", 1.1e4);
        Map<String, Double> a2 = new HashMap<>();
        a2.put("sample_a", 3.3e3);
        return List.of(
            new Feature("smf_1", "metabolomics", "CHEBI:15377",
                85.3, 181.0707, 1, "[M+H]1+",
                a1, List.of("sme_1")),
            new Feature("smf_2", "metabolomics", "CHEBI:16865",
                210.9, 147.0532, 1, "[M+Na]1+",
                a2, List.of("sme_2"))
        );
    }

    private static List<Identification> metabolomicsIdents() {
        return List.of(
            new Identification("metabolomics", 0, "CHEBI:15377", 1.0,
                List.of("SME_ID=sme_1", "name=glucose", "formula=C6H12O6")),
            new Identification("metabolomics", 0, "CHEBI:16865", 0.5,
                List.of("SME_ID=sme_2", "name=glutamate"))
        );
    }

    @Test
    void smfSmeRoundTripPreservesFeatureFields(@TempDir Path tmp) throws Exception {
        List<Feature> feats = metabolomicsFeats();
        List<Identification> idents = metabolomicsIdents();
        Path out = tmp.resolve("m.mztab");

        MzTabWriter.WriteResult res = MzTabWriter.write(
            out, idents, List.of(), feats, "2.0.0-M", null, null);
        assertEquals(2, res.nSMFRows());
        assertEquals(2, res.nSMERows());

        MzTabImport imp = MzTabReader.read(out);
        assertEquals("2.0.0-M", imp.version());
        assertEquals(2, imp.features().size());

        Map<String, Feature> byAdduct = new HashMap<>();
        for (Feature f : imp.features()) byAdduct.put(f.adductIon(), f);
        assertTrue(byAdduct.containsKey("[M+H]1+"));
        Feature glucose = byAdduct.get("[M+H]1+");
        assertEquals(181.0707, glucose.expMassToCharge(), 1e-3);
        assertEquals(85.3, glucose.retentionTimeSeconds(), 1e-3);
        assertEquals(1, glucose.charge());
        assertTrue(glucose.evidenceRefs().contains("sme_1"),
            "SME_ID preserved in evidence refs for back-fill");
        assertEquals("CHEBI:15377", glucose.chemicalEntity(),
            "chemical_entity upgraded from SME back-fill");
    }

    @Test
    void smfWriterAddsSfhAndSehHeaders(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("m.mztab");
        MzTabWriter.write(out, metabolomicsIdents(), List.of(),
            metabolomicsFeats(), "2.0.0-M", null, null);
        String text = Files.readString(out);
        List<String> lines = Arrays.asList(text.split("\n"));
        String sfh = lines.stream()
            .filter(ln -> ln.startsWith("SFH\t")).findFirst().orElse(null);
        assertNotNull(sfh, "writer emits SFH");
        assertTrue(lines.stream().anyMatch(ln -> ln.startsWith("SEH\t")),
            "writer emits SEH");
        List<String> cols = Arrays.asList(sfh.split("\t"));
        for (String col : List.of("SMF_ID", "adduct_ion", "exp_mass_to_charge",
                                   "charge", "retention_time_in_seconds")) {
            assertTrue(cols.contains(col), "SFH must contain '" + col + "'");
        }
    }

    @Test
    void smeEmitsRankFromConfidence(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("m.mztab");
        MzTabWriter.write(out, metabolomicsIdents(), List.of(),
            metabolomicsFeats(), "2.0.0-M", null, null);
        String text = Files.readString(out);
        List<String> smeRows = new ArrayList<>();
        for (String ln : text.split("\n")) {
            if (ln.startsWith("SME\t")) smeRows.add(ln);
        }
        assertEquals(2, smeRows.size());
        int[] ranks = smeRows.stream()
            .mapToInt(r -> {
                String[] parts = r.split("\t");
                return Integer.parseInt(parts[parts.length - 1]);
            })
            .sorted()
            .toArray();
        // confidence 1.0 → rank 1; confidence 0.5 → rank 2.
        assertArrayEquals(new int[]{1, 2}, ranks);
    }

    @Test
    void emptyFeaturesMetabolomicsOmitsSfh(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("m.mztab");
        List<Identification> ids = List.of(
            new Identification("metabolomics", 0, "CHEBI:15377", 0.9, List.of())
        );
        List<Quantification> qs = List.of(
            new Quantification("CHEBI:15377", "sample_a", 1.0e4, "")
        );
        MzTabWriter.write(out, ids, qs, "2.0.0-M", null, null);
        String text = Files.readString(out);
        assertFalse(text.contains("SFH\t"), "no SFH when features absent");
        assertFalse(text.contains("SMF\t"), "no SMF when features absent");
        assertTrue(text.contains("SML\t"), "SML still emitted");
    }
}
