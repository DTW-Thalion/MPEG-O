/*
 * MPEG-O Java Implementation — mzTab writer round-trip + dialect tests.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.exporters;

import com.dtwthalion.mpgo.Identification;
import com.dtwthalion.mpgo.Quantification;
import com.dtwthalion.mpgo.importers.MzTabReader;
import com.dtwthalion.mpgo.importers.MzTabReader.MzTabImport;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

final class MzTabWriterTest {

    private static List<Identification> idents() {
        return List.of(
            new Identification("run1", 10, "sp|P12345|BSA_BOVIN", 0.95,
                    List.of("[MS, MS:1001083, mascot, 1.0]")),
            new Identification("run1", 17, "sp|P67890|CRP_HUMAN", 0.82, List.of())
        );
    }

    private static List<Quantification> quants() {
        return List.of(
            new Quantification("sp|P12345|BSA_BOVIN", "sample_A", 1234.5, ""),
            new Quantification("sp|P67890|CRP_HUMAN", "sample_A", 67.0, ""),
            new Quantification("sp|P12345|BSA_BOVIN", "sample_B", 2222.2, "")
        );
    }

    @Test
    void proteomicsDialectRoundTrip(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("out.mztab");
        MzTabWriter.WriteResult res = MzTabWriter.write(
            out, idents(), quants(), "1.0", "BSA digest", null);
        assertEquals("1.0", res.version());
        assertEquals(2, res.nPSMRows());
        assertEquals(2, res.nPRTRows());
        assertEquals(0, res.nSMLRows());

        MzTabImport imp = MzTabReader.read(out);
        assertEquals("1.0", imp.version());
        assertEquals(2, imp.identifications().size());
        assertEquals(3, imp.quantifications().size(),
                "PRT abundance columns → one Quantification per assay");

        Set<String> sampleLabels = imp.quantifications().stream()
                .map(Quantification::sampleRef)
                .collect(Collectors.toCollection(HashSet::new));
        assertTrue(sampleLabels.contains("sample_A"),
                "sample_A label round-trips via MTD");
        assertTrue(sampleLabels.contains("sample_B"),
                "sample_B label round-trips via MTD");
    }

    @Test
    void metabolomicsDialectRoundTrip(@TempDir Path tmp) throws Exception {
        List<Identification> metIdents = List.of(
            new Identification("metabolomics", 0, "CHEBI:15365", 0.9, List.of())
        );
        List<Quantification> metQuants = List.of(
            new Quantification("CHEBI:15365", "S1", 10.0, ""),
            new Quantification("CHEBI:15365", "S2", 20.0, "")
        );
        Path out = tmp.resolve("met.mztab");
        MzTabWriter.WriteResult res = MzTabWriter.write(
            out, metIdents, metQuants, "2.0.0-M", null, null);
        assertEquals(1, res.nSMLRows());
        assertEquals(0, res.nPSMRows());

        MzTabImport imp = MzTabReader.read(out);
        assertEquals("2.0.0-M", imp.version());
        assertEquals(2, imp.quantifications().size());
    }

    @Test
    void mtdDeclaresEveryReferencedMsRun(@TempDir Path tmp) throws Exception {
        List<Identification> ids = List.of(
            new Identification("alpha", 0, "X", 0.5, List.of()),
            new Identification("beta",  1, "Y", 0.5, List.of())
        );
        Path out = tmp.resolve("runs.mztab");
        MzTabWriter.write(out, ids, List.of(), "1.0", null, null);
        String text = java.nio.file.Files.readString(out);
        assertTrue(text.contains("MTD\tms_run[1]-location\t"),
                "MTD declares ms_run[1]");
        assertTrue(text.contains("MTD\tms_run[2]-location\t"),
                "MTD declares ms_run[2]");
        assertTrue(text.contains("ms_run[1]:index=0"),
                "PSM row references ms_run[1]");
        assertTrue(text.contains("ms_run[2]:index=1"),
                "PSM row references ms_run[2]");
    }

    @Test
    void rejectsUnknownVersion(@TempDir Path tmp) {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> MzTabWriter.write(tmp.resolve("x.mztab"),
                idents(), List.of(), "0.9", null, null));
        assertTrue(ex.getMessage().contains("unsupported mzTab version"));
    }

    @Test
    void tabsInFieldValuesAreEscaped(@TempDir Path tmp) throws Exception {
        List<Identification> dirty = List.of(
            new Identification("r", 0, "nasty\tvalue\nwith\rspecials", 0.1, List.of())
        );
        Path out = tmp.resolve("dirty.mztab");
        MzTabWriter.write(out, dirty, List.of(), "1.0", null, null);
        String text = java.nio.file.Files.readString(out);
        assertTrue(text.contains("nasty value with specials"),
                "special characters replaced with spaces");
        assertFalse(text.contains("nasty\tvalue"),
                "embedded tab must not survive to break the TSV grid");
    }
}
