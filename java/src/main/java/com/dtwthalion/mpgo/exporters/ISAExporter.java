/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.exporters;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.InstrumentConfig;
import com.dtwthalion.mpgo.SpectralDataset;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Exports a {@link SpectralDataset} to ISA-Tab TSV files and ISA-JSON.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGOISAExporter} &middot;
 * Python: {@code mpeg_o.exporters.isa}</p>
 *
 * @since 0.6
 */
public final class ISAExporter {

    private ISAExporter() {}

    // ── ISA-Tab export ──────────────────────────────────────────────

    /**
     * Write ISA-Tab files (i_investigation.txt, s_study.txt,
     * a_assay_ms_&lt;run&gt;.txt) into {@code outputDir}.
     */
    public static void exportTab(SpectralDataset ds, Path outputDir) {
        try {
            Files.createDirectories(outputDir);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }

        String id = ds.isaInvestigationId() != null ? ds.isaInvestigationId() : "";
        String title = ds.title() != null ? ds.title() : "";
        List<String> runNames = new ArrayList<>(ds.msRuns().keySet());

        writeInvestigation(outputDir, id, title, runNames, ds.msRuns());
        writeStudy(outputDir, runNames);
        for (String run : runNames) {
            writeAssay(outputDir, run, ds.msRuns().get(run));
        }
    }

    private static void writeInvestigation(Path dir, String id, String title,
                                           List<String> runNames,
                                           Map<String, AcquisitionRun> runs) {
        StringBuilder sb = new StringBuilder();
        sb.append("ONTOLOGY SOURCE REFERENCE\n");
        sb.append("Term Source Name\tMS\n");
        sb.append("Term Source File\thttps://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo\n");
        sb.append("Term Source Version\t4.1.0\n");
        sb.append("Term Source Description\tProteomics Standards Initiative Mass Spectrometry Ontology\n");
        sb.append("INVESTIGATION\n");
        sb.append("Investigation Identifier\t").append(escapeCell(id)).append('\n');
        sb.append("Investigation Title\t").append(escapeCell(title)).append('\n');
        sb.append("Investigation Description\t\n");
        sb.append("Investigation Submission Date\t\n");
        sb.append("Investigation Public Release Date\t\n");

        // ISA-Tab 1.0 requires every section header to be present, even
        // when data rows are empty. isatools halts at the first missing
        // required section.
        sb.append("INVESTIGATION PUBLICATIONS\n");
        sb.append("Investigation PubMed ID\n");
        sb.append("Investigation Publication DOI\n");
        sb.append("Investigation Publication Author List\n");
        sb.append("Investigation Publication Title\n");
        sb.append("Investigation Publication Status\n");
        sb.append("Investigation Publication Status Term Accession Number\n");
        sb.append("Investigation Publication Status Term Source REF\n");

        sb.append("INVESTIGATION CONTACTS\n");
        sb.append("Investigation Person Last Name\n");
        sb.append("Investigation Person First Name\n");
        sb.append("Investigation Person Mid Initials\n");
        sb.append("Investigation Person Email\n");
        sb.append("Investigation Person Phone\n");
        sb.append("Investigation Person Fax\n");
        sb.append("Investigation Person Address\n");
        sb.append("Investigation Person Affiliation\n");
        sb.append("Investigation Person Roles\n");
        sb.append("Investigation Person Roles Term Accession Number\n");
        sb.append("Investigation Person Roles Term Source REF\n");

        // STUDY. isatools requires Study Description to be non-empty;
        // fall back to title or id when the dataset carries nothing.
        String studyDesc = title != null && !title.isEmpty() ? title
                : (id != null && !id.isEmpty() ? id : "MPEG-O exported study");
        sb.append("STUDY\n");
        sb.append("Study Identifier\t").append(escapeCell(id)).append('\n');
        sb.append("Study Title\t").append(escapeCell(title)).append('\n');
        sb.append("Study Description\t").append(escapeCell(studyDesc)).append('\n');
        sb.append("Study Submission Date\t\n");
        sb.append("Study Public Release Date\t\n");
        sb.append("Study File Name\ts_study.txt\n");

        sb.append("STUDY DESIGN DESCRIPTORS\n");
        sb.append("Study Design Type\n");
        sb.append("Study Design Type Term Accession Number\n");
        sb.append("Study Design Type Term Source REF\n");

        sb.append("STUDY PUBLICATIONS\n");
        sb.append("Study PubMed ID\n");
        sb.append("Study Publication DOI\n");
        sb.append("Study Publication Author List\n");
        sb.append("Study Publication Title\n");
        sb.append("Study Publication Status\n");
        sb.append("Study Publication Status Term Accession Number\n");
        sb.append("Study Publication Status Term Source REF\n");

        sb.append("STUDY FACTORS\n");
        sb.append("Study Factor Name\n");
        sb.append("Study Factor Type\n");
        sb.append("Study Factor Type Term Accession Number\n");
        sb.append("Study Factor Type Term Source REF\n");

        sb.append("STUDY ASSAYS\n");

        // Measurement type row
        sb.append("Study Assay Measurement Type");
        for (int i = 0; i < runNames.size(); i++) {
            sb.append('\t').append("metabolite profiling");
        }
        sb.append('\n');

        // Technology type row
        sb.append("Study Assay Technology Type");
        for (int i = 0; i < runNames.size(); i++) {
            sb.append('\t').append("mass spectrometry");
        }
        sb.append('\n');

        // Technology platform row
        sb.append("Study Assay Technology Platform");
        for (String run : runNames) {
            sb.append('\t').append(escapeCell(instrumentModel(runs.get(run))));
        }
        sb.append('\n');

        // Assay file name row
        sb.append("Study Assay File Name");
        for (String run : runNames) {
            sb.append('\t').append("a_assay_ms_").append(escapeCell(run)).append(".txt");
        }
        sb.append('\n');

        // Add Measurement/Technology Term Accession + REF columns that
        // isatools expects alongside the Type rows (empty strings are
        // valid; just the header must exist).
        sb.append("Study Assay Measurement Type Term Accession Number");
        for (int i = 0; i < runNames.size(); i++) sb.append('\t');
        sb.append('\n');
        sb.append("Study Assay Measurement Type Term Source REF");
        for (int i = 0; i < runNames.size(); i++) sb.append('\t');
        sb.append('\n');
        sb.append("Study Assay Technology Type Term Accession Number");
        for (int i = 0; i < runNames.size(); i++) sb.append('\t');
        sb.append('\n');
        sb.append("Study Assay Technology Type Term Source REF");
        for (int i = 0; i < runNames.size(); i++) sb.append('\t');
        sb.append('\n');

        // STUDY PROTOCOLS — declare every Protocol REF used in the
        // study + assay files ("sample collection" + "mass spectrometry").
        sb.append("STUDY PROTOCOLS\n");
        sb.append("Study Protocol Name\tsample collection\tmass spectrometry\n");
        sb.append("Study Protocol Type\tsample collection\tmass spectrometry\n");
        sb.append("Study Protocol Type Term Accession Number\t\t\n");
        sb.append("Study Protocol Type Term Source REF\t\t\n");
        sb.append("Study Protocol Description\t\t\n");
        sb.append("Study Protocol URI\t\t\n");
        sb.append("Study Protocol Version\t\t\n");
        sb.append("Study Protocol Parameters Name\t\t\n");
        sb.append("Study Protocol Parameters Name Term Accession Number\t\t\n");
        sb.append("Study Protocol Parameters Name Term Source REF\t\t\n");
        sb.append("Study Protocol Components Name\t\t\n");
        sb.append("Study Protocol Components Type\t\t\n");
        sb.append("Study Protocol Components Type Term Accession Number\t\t\n");
        sb.append("Study Protocol Components Type Term Source REF\t\t\n");

        sb.append("STUDY CONTACTS\n");
        sb.append("Study Person Last Name\n");
        sb.append("Study Person First Name\n");
        sb.append("Study Person Mid Initials\n");
        sb.append("Study Person Email\n");
        sb.append("Study Person Phone\n");
        sb.append("Study Person Fax\n");
        sb.append("Study Person Address\n");
        sb.append("Study Person Affiliation\n");
        sb.append("Study Person Roles\n");
        sb.append("Study Person Roles Term Accession Number\n");
        sb.append("Study Person Roles Term Source REF\n");

        writeFile(dir.resolve("i_investigation.txt"), sb.toString());
    }

    private static void writeStudy(Path dir, List<String> runNames) {
        StringBuilder sb = new StringBuilder();
        sb.append("Source Name\tSample Name\tCharacteristics[organism]\tProtocol REF\tDate\n");
        for (String run : runNames) {
            sb.append("src_").append(escapeCell(run)).append('\t');
            sb.append("sample_").append(escapeCell(run)).append('\t');
            sb.append('\t');
            sb.append("sample collection").append('\t');
            sb.append('\n');
        }
        writeFile(dir.resolve("s_study.txt"), sb.toString());
    }

    private static void writeAssay(Path dir, String run, AcquisitionRun acq) {
        StringBuilder sb = new StringBuilder();
        sb.append("Sample Name\tProtocol REF\tParameter Value[instrument]\t");
        sb.append("Parameter Value[ionization]\tAssay Name\t");
        sb.append("Raw Spectral Data File\tDerived Spectral Data File\n");

        String model = instrumentModel(acq);
        String sourceType = instrumentSourceType(acq);

        sb.append("sample_").append(escapeCell(run)).append('\t');
        sb.append("mass spectrometry").append('\t');
        sb.append(escapeCell(model)).append('\t');
        sb.append(escapeCell(sourceType)).append('\t');
        sb.append(escapeCell(run)).append('\t');
        sb.append(escapeCell(run)).append(".mzML").append('\t');
        sb.append('\n');

        writeFile(dir.resolve("a_assay_ms_" + run + ".txt"), sb.toString());
    }

    // ── ISA-JSON export ─────────────────────────────────────────────

    /**
     * Return an ISA-JSON string for the given dataset.
     * Keys are sorted alphabetically; indentation is 2 spaces.
     */
    public static String exportJson(SpectralDataset ds) {
        String id = ds.isaInvestigationId() != null ? ds.isaInvestigationId() : "";
        String title = ds.title() != null ? ds.title() : "";
        List<String> runNames = new ArrayList<>(ds.msRuns().keySet());

        StringBuilder sb = new StringBuilder();
        sb.append("{\n");
        sb.append("  \"identifier\": ").append(jsonString(id)).append(",\n");

        // ontologySourceReferences
        sb.append("  \"ontologySourceReferences\": [\n");
        sb.append("    {\n");
        sb.append("      \"description\": \"Proteomics Standards Initiative Mass Spectrometry Ontology\",\n");
        sb.append("      \"file\": \"https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo\",\n");
        sb.append("      \"name\": \"MS\",\n");
        sb.append("      \"version\": \"4.1.0\"\n");
        sb.append("    }\n");
        sb.append("  ],\n");

        // studies
        sb.append("  \"studies\": [\n");
        sb.append("    {\n");

        // assays
        sb.append("      \"assays\": [\n");
        for (int i = 0; i < runNames.size(); i++) {
            String run = runNames.get(i);
            AcquisitionRun acq = ds.msRuns().get(run);
            String model = instrumentModel(acq);

            sb.append("        {\n");
            sb.append("          \"dataFiles\": [\n");
            sb.append("            {\n");
            sb.append("              \"name\": ").append(jsonString(run + ".mzML")).append(",\n");
            sb.append("              \"type\": \"Raw Spectral Data File\"\n");
            sb.append("            }\n");
            sb.append("          ],\n");
            sb.append("          \"filename\": ").append(jsonString("a_assay_ms_" + run + ".txt")).append(",\n");
            sb.append("          \"measurementType\": {\n");
            sb.append("            \"annotationValue\": \"metabolite profiling\"\n");
            sb.append("          },\n");
            sb.append("          \"technologyPlatform\": ").append(jsonString(model)).append(",\n");
            sb.append("          \"technologyType\": {\n");
            sb.append("            \"annotationValue\": \"mass spectrometry\"\n");
            sb.append("          }\n");
            sb.append("        }");
            if (i < runNames.size() - 1) sb.append(',');
            sb.append('\n');
        }
        sb.append("      ],\n");

        // filename
        sb.append("      \"filename\": \"s_study.txt\",\n");

        // identifier
        sb.append("      \"identifier\": ").append(jsonString(id)).append(",\n");

        // materials
        sb.append("      \"materials\": {\n");

        // samples
        sb.append("        \"samples\": [\n");
        for (int i = 0; i < runNames.size(); i++) {
            String run = runNames.get(i);
            sb.append("          {\n");
            sb.append("            \"@id\": ").append(jsonString("#sample/" + run)).append(",\n");
            sb.append("            \"name\": ").append(jsonString("sample_" + run)).append('\n');
            sb.append("          }");
            if (i < runNames.size() - 1) sb.append(',');
            sb.append('\n');
        }
        sb.append("        ],\n");

        // sources
        sb.append("        \"sources\": [\n");
        for (int i = 0; i < runNames.size(); i++) {
            String run = runNames.get(i);
            sb.append("          {\n");
            sb.append("            \"@id\": ").append(jsonString("#source/" + run)).append(",\n");
            sb.append("            \"name\": ").append(jsonString("src_" + run)).append('\n');
            sb.append("          }");
            if (i < runNames.size() - 1) sb.append(',');
            sb.append('\n');
        }
        sb.append("        ]\n");

        sb.append("      },\n");

        // title
        sb.append("      \"title\": ").append(jsonString(title)).append('\n');

        sb.append("    }\n");
        sb.append("  ],\n");

        // title (top-level)
        sb.append("  \"title\": ").append(jsonString(title)).append('\n');

        sb.append("}\n");
        return sb.toString();
    }

    // ── Helpers ─────────────────────────────────────────────────────

    /** ISA-Tab escape: if the cell contains tab, quote, or newline, wrap in quotes and double any quotes. */
    static String escapeCell(String value) {
        if (value == null) return "";
        if (value.indexOf('\t') >= 0 || value.indexOf('"') >= 0
                || value.indexOf('\n') >= 0 || value.indexOf('\r') >= 0) {
            return "\"" + value.replace("\"", "\"\"") + "\"";
        }
        return value;
    }

    /** JSON-encode a string value (with surrounding quotes). */
    private static String jsonString(String value) {
        if (value == null) return "\"\"";
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:   sb.append(c);
            }
        }
        sb.append('"');
        return sb.toString();
    }

    private static String instrumentModel(AcquisitionRun acq) {
        if (acq == null || acq.instrumentConfig() == null) return "";
        String model = acq.instrumentConfig().model();
        return model != null ? model : "";
    }

    private static String instrumentSourceType(AcquisitionRun acq) {
        if (acq == null || acq.instrumentConfig() == null) return "";
        String st = acq.instrumentConfig().sourceType();
        return st != null ? st : "";
    }

    private static void writeFile(Path path, String content) {
        try {
            Files.writeString(path, content, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
