/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.hdf5.Hdf5File;
import com.dtwthalion.mpgo.hdf5.Hdf5Group;

import java.util.*;

/**
 * Root reader/writer for MPEG-O {@code .mpgo} files. Implements
 * {@link AutoCloseable} for try-with-resources.
 *
 * <p>HDF5 layout: root group has {@code @mpeg_o_format_version} and
 * {@code @mpeg_o_features} attributes. The {@code /study/} group contains
 * runs, identifications, quantifications, and provenance.</p>
 */
public class SpectralDataset implements AutoCloseable {

    private final Hdf5File file;
    private final FeatureFlags featureFlags;
    private final String title;
    private final String isaInvestigationId;
    private final Map<String, AcquisitionRun> msRuns;
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;

    private SpectralDataset(Hdf5File file, FeatureFlags featureFlags,
                            String title, String isaInvestigationId,
                            Map<String, AcquisitionRun> msRuns,
                            List<Identification> identifications,
                            List<Quantification> quantifications,
                            List<ProvenanceRecord> provenanceRecords) {
        this.file = file;
        this.featureFlags = featureFlags;
        this.title = title;
        this.isaInvestigationId = isaInvestigationId;
        this.msRuns = msRuns;
        this.identifications = identifications;
        this.quantifications = quantifications;
        this.provenanceRecords = provenanceRecords;
    }

    // ── Accessors ───────────────────────────────────────────────────

    public FeatureFlags featureFlags() { return featureFlags; }
    public String title() { return title; }
    public String isaInvestigationId() { return isaInvestigationId; }
    public Map<String, AcquisitionRun> msRuns() { return msRuns; }
    public List<Identification> identifications() { return identifications; }
    public List<Quantification> quantifications() { return quantifications; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    // ── Open (read) ─────────────────────────────────────────────────

    /** Open an existing .mpgo file for reading. */
    public static SpectralDataset open(String path) {
        Hdf5File file = Hdf5File.openReadOnly(path);
        try (Hdf5Group root = file.rootGroup()) {
            FeatureFlags flags = FeatureFlags.readFrom(root);

            String title = null;
            String isaId = null;
            Map<String, AcquisitionRun> runs = new LinkedHashMap<>();
            List<Identification> idents = List.of();
            List<Quantification> quants = List.of();
            List<ProvenanceRecord> prov = List.of();

            if (root.hasChild("study")) {
                try (Hdf5Group study = root.openGroup("study")) {
                    if (study.hasAttribute("title"))
                        title = study.readStringAttribute("title");
                    if (study.hasAttribute("isa_investigation_id"))
                        isaId = study.readStringAttribute("isa_investigation_id");

                    // Read MS runs
                    if (study.hasChild("ms_runs")) {
                        try (Hdf5Group msRunsGroup = study.openGroup("ms_runs")) {
                            if (msRunsGroup.hasAttribute("_run_names")) {
                                String names = msRunsGroup.readStringAttribute("_run_names");
                                for (String rn : names.split(",")) {
                                    String name = rn.strip();
                                    if (!name.isEmpty() && msRunsGroup.hasChild(name)) {
                                        AcquisitionRun run = AcquisitionRun.readFrom(msRunsGroup, name);
                                        runs.put(name, run);
                                    }
                                }
                            }
                        }
                    }

                    // Identifications — v0.2+ compound dataset or v0.1 JSON
                    if (flags.has(FeatureFlags.COMPOUND_IDENTIFICATIONS)
                            && study.hasChild("identifications")) {
                        idents = readCompoundIdentifications(study);
                    } else if (study.hasAttribute("identifications_json")) {
                        // v0.1 JSON fallback — parse later
                    }

                    // Quantifications
                    if (flags.has(FeatureFlags.COMPOUND_QUANTIFICATIONS)
                            && study.hasChild("quantifications")) {
                        quants = readCompoundQuantifications(study);
                    }

                    // Provenance
                    if (flags.has(FeatureFlags.COMPOUND_PROVENANCE)
                            && study.hasChild("provenance")) {
                        prov = readCompoundProvenance(study);
                    }
                }
            }

            return new SpectralDataset(file, flags, title, isaId, runs,
                    idents, quants, prov);
        }
    }

    // ── Create (write) ──────────────────────────────────────────────

    /** Create a new .mpgo file with the given content. */
    public static SpectralDataset create(String path, String title,
                                          String isaInvestigationId,
                                          List<AcquisitionRun> runs,
                                          List<Identification> identifications,
                                          List<Quantification> quantifications,
                                          List<ProvenanceRecord> provenanceRecords) {
        return create(path, title, isaInvestigationId, runs,
                identifications, quantifications, provenanceRecords,
                FeatureFlags.defaultCurrent());
    }

    public static SpectralDataset create(String path, String title,
                                          String isaInvestigationId,
                                          List<AcquisitionRun> runs,
                                          List<Identification> identifications,
                                          List<Quantification> quantifications,
                                          List<ProvenanceRecord> provenanceRecords,
                                          FeatureFlags featureFlags) {
        Hdf5File file = Hdf5File.create(path);
        try (Hdf5Group root = file.rootGroup()) {
            featureFlags.writeTo(root);

            try (Hdf5Group study = root.createGroup("study")) {
                if (title != null) study.setStringAttribute("title", title);
                if (isaInvestigationId != null)
                    study.setStringAttribute("isa_investigation_id", isaInvestigationId);

                // Write runs
                Map<String, AcquisitionRun> runMap = new LinkedHashMap<>();
                if (runs != null && !runs.isEmpty()) {
                    try (Hdf5Group msRunsGroup = study.createGroup("ms_runs")) {
                        StringBuilder names = new StringBuilder();
                        for (int i = 0; i < runs.size(); i++) {
                            AcquisitionRun run = runs.get(i);
                            if (i > 0) names.append(",");
                            names.append(run.name());
                            run.writeTo(msRunsGroup);
                            runMap.put(run.name(), run);
                        }
                        msRunsGroup.setStringAttribute("_run_names", names.toString());
                    }
                }

                // Write identifications as compound dataset
                if (identifications != null && !identifications.isEmpty()) {
                    writeCompoundIdentifications(study, identifications);
                }

                // Write quantifications as compound dataset
                if (quantifications != null && !quantifications.isEmpty()) {
                    writeCompoundQuantifications(study, quantifications);
                }

                // Write provenance as compound dataset
                if (provenanceRecords != null && !provenanceRecords.isEmpty()) {
                    writeCompoundProvenance(study, provenanceRecords);
                }

                return new SpectralDataset(file, featureFlags, title, isaInvestigationId,
                        runMap, identifications != null ? identifications : List.of(),
                        quantifications != null ? quantifications : List.of(),
                        provenanceRecords != null ? provenanceRecords : List.of());
            }
        }
    }

    // ── Compound dataset I/O (JSON-in-attributes for now) ───────────
    // Full compound HDF5 I/O requires VL string support in Java HDF5.
    // For M32, we use JSON string attributes as the portable path that
    // all three implementations can read.

    private static void writeCompoundIdentifications(Hdf5Group study,
                                                      List<Identification> idents) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < idents.size(); i++) {
            if (i > 0) json.append(",");
            Identification id = idents.get(i);
            json.append("{\"run_name\":\"").append(id.runName()).append("\"")
                .append(",\"spectrum_index\":").append(id.spectrumIndex())
                .append(",\"chemical_entity\":\"").append(id.chemicalEntity()).append("\"")
                .append(",\"confidence_score\":").append(id.confidenceScore())
                .append(",\"evidence_chain\":").append(id.evidenceChainJson())
                .append("}");
        }
        json.append("]");
        study.setStringAttribute("identifications_json", json.toString());
    }

    private static List<Identification> readCompoundIdentifications(Hdf5Group study) {
        // Compound dataset reading requires native compound I/O.
        // Fall back to JSON attribute if present.
        if (study.hasAttribute("identifications_json")) {
            // JSON parsing placeholder — return empty for now
            return List.of();
        }
        return List.of();
    }

    private static void writeCompoundQuantifications(Hdf5Group study,
                                                      List<Quantification> quants) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < quants.size(); i++) {
            if (i > 0) json.append(",");
            Quantification q = quants.get(i);
            json.append("{\"chemical_entity\":\"").append(q.chemicalEntity()).append("\"")
                .append(",\"sample_ref\":\"").append(q.sampleRef()).append("\"")
                .append(",\"abundance\":").append(q.abundance());
            if (q.normalizationMethod() != null)
                json.append(",\"normalization_method\":\"").append(q.normalizationMethod()).append("\"");
            json.append("}");
        }
        json.append("]");
        study.setStringAttribute("quantifications_json", json.toString());
    }

    private static List<Quantification> readCompoundQuantifications(Hdf5Group study) {
        return List.of();
    }

    private static void writeCompoundProvenance(Hdf5Group study,
                                                 List<ProvenanceRecord> records) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < records.size(); i++) {
            if (i > 0) json.append(",");
            ProvenanceRecord r = records.get(i);
            json.append("{\"timestamp_unix\":").append(r.timestampUnix())
                .append(",\"software\":\"").append(r.software()).append("\"")
                .append(",\"parameters\":").append(r.parametersJson())
                .append(",\"input_refs\":").append(r.inputRefsJson())
                .append(",\"output_refs\":").append(r.outputRefsJson())
                .append("}");
        }
        json.append("]");
        study.setStringAttribute("provenance_json", json.toString());
    }

    private static List<ProvenanceRecord> readCompoundProvenance(Hdf5Group study) {
        return List.of();
    }

    @Override
    public void close() {
        if (file != null) file.close();
    }
}
