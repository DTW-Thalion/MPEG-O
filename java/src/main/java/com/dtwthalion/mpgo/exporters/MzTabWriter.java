/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.exporters;

import com.dtwthalion.mpgo.Identification;
import com.dtwthalion.mpgo.Quantification;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * mzTab exporter — v0.9+. Reverses {@link
 * com.dtwthalion.mpgo.importers.MzTabReader}: takes identifications +
 * quantifications and emits a mzTab file. Both proteomics 1.0
 * (PSH/PSM + PRH/PRT sections) and metabolomics 2.0.0-M (SMH/SML)
 * dialects are supported.
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Python: {@code mpeg_o.exporters.mztab} &middot;
 * Objective-C: {@code MPGOMzTabWriter}</p>
 *
 * @since 0.9
 */
public final class MzTabWriter {

    /** Paths + per-section row counts. */
    public record WriteResult(
        Path path,
        String version,
        int nPSMRows,
        int nPRTRows,
        int nSMLRows
    ) {}

    private MzTabWriter() {}

    public static WriteResult write(
        Path path,
        List<Identification> identifications,
        List<Quantification> quantifications,
        String version,
        String title,
        String description
    ) {
        if (!"1.0".equals(version) && !"2.0.0-M".equals(version)) {
            throw new IllegalArgumentException(
                "unsupported mzTab version: " + version);
        }
        List<Identification> idents = identifications == null ? List.of() : identifications;
        List<Quantification> quants = quantifications == null ? List.of() : quantifications;

        // Stable run-name → index mapping.
        Map<String, Integer> runIdx = new LinkedHashMap<>();
        for (Identification id : idents) {
            runIdx.putIfAbsent(id.runName(), runIdx.size() + 1);
        }

        // Stable sample → assay index mapping.
        Map<String, Integer> sampleIdx = new LinkedHashMap<>();
        for (Quantification q : quants) {
            String s = q.sampleRef() != null ? q.sampleRef() : "sample";
            sampleIdx.putIfAbsent(s, sampleIdx.size() + 1);
        }

        List<String> lines = new ArrayList<>();

        // ── MTD ───────────────────────────────────────────────────
        lines.add("MTD\tmzTab-version\t" + version);
        lines.add("MTD\tmzTab-mode\tSummary");
        lines.add("MTD\tmzTab-type\tIdentification");
        if ("1.0".equals(version)) {
            lines.add("MTD\tmzTab-ID\tmpgo-export");
        }
        if (title != null && !title.isEmpty()) {
            lines.add("MTD\ttitle\t" + escapeTsv(title));
        }
        if (description != null && !description.isEmpty()) {
            lines.add("MTD\tdescription\t" + escapeTsv(description));
        }
        lines.add("MTD\tsoftware[1]\t[MS, MS:1000799, custom unreleased software tool, mpeg-o]");

        for (var e : runIdx.entrySet()) {
            lines.add(String.format(
                "MTD\tms_run[%d]-location\tfile://%s.mzML",
                e.getValue(), e.getKey()));
        }

        if (!quants.isEmpty()) {
            for (var e : sampleIdx.entrySet()) {
                int i = e.getValue();
                String sample = e.getKey();
                lines.add(String.format("MTD\tassay[%d]-sample_ref\t%s", i, escapeTsv(sample)));
                lines.add(String.format(
                    "MTD\tassay[%d]-quantification_reagent\t[MS, MS:1002038, unlabeled sample, %s]",
                    i, escapeTsv(sample)));
                lines.add(String.format("MTD\tassay[%d]-ms_run_ref\tms_run[1]", i));
                if ("2.0.0-M".equals(version)) {
                    lines.add(String.format(
                        "MTD\tstudy_variable[%d]-description\t%s", i, escapeTsv(sample)));
                    lines.add(String.format(
                        "MTD\tstudy_variable[%d]-assay_refs\tassay[%d]", i, i));
                }
            }
        }

        lines.add("");  // blank separator

        int nPSM = 0, nPRT = 0, nSML = 0;

        if ("1.0".equals(version)) {
            // ── PSH + PSM ────────────────────────────────────────
            if (!idents.isEmpty()) {
                lines.add("PSH\tsequence\tPSM_ID\taccession\tunique\tdatabase\tdatabase_version"
                    + "\tsearch_engine\tsearch_engine_score[1]\tmodifications"
                    + "\tretention_time\tcharge\texp_mass_to_charge\tcalc_mass_to_charge"
                    + "\tspectra_ref\tpre\tpost\tstart\tend");
                int psmId = 1;
                for (Identification id : idents) {
                    String se = "[MS, MS:1001083, mascot, ]";
                    if (id.evidenceChain() != null && !id.evidenceChain().isEmpty()) {
                        se = id.evidenceChain().get(0);
                    }
                    lines.add(String.format(
                        "PSM\t\t%d\t%s\tnull\tnull\tnull\t%s\t%s\tnull\tnull\tnull\tnull\tnull"
                        + "\tms_run[%d]:index=%d\tnull\tnull\tnull\tnull",
                        psmId++,
                        escapeTsv(id.chemicalEntity()),
                        escapeTsv(se),
                        fmt(id.confidenceScore()),
                        runIdx.get(id.runName()),
                        id.spectrumIndex()));
                    nPSM++;
                }
                lines.add("");
            }

            // ── PRH + PRT ────────────────────────────────────────
            if (!quants.isEmpty()) {
                Map<String, Map<Integer, Double>> grouped = new LinkedHashMap<>();
                for (Quantification q : quants) {
                    String entity = q.chemicalEntity();
                    Integer ai = sampleIdx.get(q.sampleRef() != null ? q.sampleRef() : "sample");
                    grouped.computeIfAbsent(entity, k -> new LinkedHashMap<>())
                           .put(ai, q.abundance());
                }
                int nAssays = sampleIdx.size();
                StringBuilder prh = new StringBuilder(
                    "PRH\taccession\tdescription\ttaxid\tspecies\tdatabase\tdatabase_version"
                    + "\tsearch_engine\tbest_search_engine_score[1]\tambiguity_members"
                    + "\tmodifications\tprotein_coverage");
                for (int k = 1; k <= nAssays; k++) {
                    prh.append("\tprotein_abundance_assay[").append(k).append("]");
                }
                lines.add(prh.toString());
                for (var entry : grouped.entrySet()) {
                    StringBuilder row = new StringBuilder("PRT\t")
                        .append(escapeTsv(entry.getKey()))
                        .append("\t\tnull\tnull\tnull\tnull\tnull\tnull\tnull\tnull\tnull");
                    Map<Integer, Double> ab = entry.getValue();
                    for (int k = 1; k <= nAssays; k++) {
                        Double v = ab.get(k);
                        row.append("\t").append(v == null ? "null" : fmt(v));
                    }
                    lines.add(row.toString());
                    nPRT++;
                }
                lines.add("");
            }
        } else {
            // Metabolomics: SMH + SML.
            Map<String, Map<Integer, Double>> entityQuants = new LinkedHashMap<>();
            for (Quantification q : quants) {
                Integer ai = sampleIdx.get(q.sampleRef() != null ? q.sampleRef() : "sample");
                entityQuants.computeIfAbsent(q.chemicalEntity(), k -> new LinkedHashMap<>())
                            .put(ai, q.abundance());
            }
            for (Identification id : idents) {
                entityQuants.computeIfAbsent(id.chemicalEntity(), k -> new LinkedHashMap<>());
            }

            if (!entityQuants.isEmpty()) {
                Map<String, Double> confByEntity = new LinkedHashMap<>();
                for (Identification id : idents) {
                    double best = Math.max(
                        confByEntity.getOrDefault(id.chemicalEntity(), 0.0),
                        id.confidenceScore());
                    confByEntity.put(id.chemicalEntity(), best);
                }
                int nSV = sampleIdx.size();
                StringBuilder smh = new StringBuilder(
                    "SMH\tSML_ID\tSMF_ID_REFS\tdatabase_identifier\tchemical_formula\tsmiles"
                    + "\tinchi\tchemical_name\turi\ttheoretical_neutral_mass\tadduct_ions"
                    + "\treliability\tbest_id_confidence_measure\tbest_id_confidence_value");
                for (int k = 1; k <= nSV; k++) {
                    smh.append("\tabundance_study_variable[").append(k).append("]");
                    smh.append("\tabundance_variation_study_variable[").append(k).append("]");
                }
                lines.add(smh.toString());

                int smlId = 1;
                for (var entry : entityQuants.entrySet()) {
                    double conf = confByEntity.getOrDefault(entry.getKey(), 0.0);
                    StringBuilder row = new StringBuilder(String.format(
                        "SML\t%d\tnull\t%s\tnull\tnull\tnull\tnull\tnull\tnull\tnull\t1"
                        + "\t[MS, MS:1001090, null, ]\t%s",
                        smlId++, escapeTsv(entry.getKey()), fmt(conf)));
                    Map<Integer, Double> ab = entry.getValue();
                    for (int k = 1; k <= nSV; k++) {
                        Double v = ab.get(k);
                        row.append("\t").append(v == null ? "null" : fmt(v));
                        row.append("\tnull");
                    }
                    lines.add(row.toString());
                    nSML++;
                }
                lines.add("");
            }
        }

        String text = String.join("\n", lines) + "\n";
        try {
            Files.writeString(path, text, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to write mzTab: " + path, e);
        }

        return new WriteResult(path, version, nPSM, nPRT, nSML);
    }

    // ── helpers ────────────────────────────────────────────────

    private static String escapeTsv(String value) {
        if (value == null) return "";
        return value.replace("\t", " ").replace("\r", " ").replace("\n", " ");
    }

    /** %g-ish formatting; mirrors Python's {@code f"{v:g}"}. */
    private static String fmt(double v) {
        // Java's %g defaults to 6 significant digits and leaves trailing
        // zeros that Python's :g trims. Go via Double.toString for
        // round-trip-friendly output.
        if (v == 0.0) return "0";
        String s = Double.toString(v);
        // Strip trailing ".0" so integers come out clean ("10" not "10.0").
        if (s.endsWith(".0")) return s.substring(0, s.length() - 2);
        return s;
    }
}
