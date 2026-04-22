/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.hdf5.Hdf5CompoundIO;
import com.dtwthalion.mpgo.hdf5.Hdf5File;
import com.dtwthalion.mpgo.hdf5.Hdf5Group;
import com.dtwthalion.mpgo.providers.Hdf5Provider;
import com.dtwthalion.mpgo.providers.StorageProvider;

import java.util.*;

/**
 * Root reader/writer for MPEG-O {@code .mpgo} files. Implements
 * {@link AutoCloseable} for try-with-resources.
 *
 * <p>HDF5 layout: root group has {@code @mpeg_o_format_version} and
 * {@code @mpeg_o_features} attributes. The {@code /study/} group contains
 * runs, identifications, quantifications, and provenance.</p>
 *
 * <p><b>Compound metadata (§6 of format-spec).</b> Writing emits the
 * native HDF5 compound dataset <em>and</em> a JSON attribute mirror
 * (transition-window behavior, §6.4). Reading prefers the JSON attribute
 * because JHI5 1.10 cannot marshal VL-string fields out of a compound;
 * when only the native compound is present, primitive fields are
 * recovered via type projection and VL-string fields decode as empty
 * strings. The mirror is emitted to keep Java-written files fully
 * round-trippable by every implementation.</p>
 *
 * <p><b>API status:</b> Stable. {@code Encryptable} conformance is
 * delivered in slice 41.5 when the encryption manager lands in Java.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOSpectralDataset}, Python
 * {@code mpeg_o.spectral_dataset.SpectralDataset}.</p>
 *
 * @since 0.6
 */
public class SpectralDataset implements
        com.dtwthalion.mpgo.protocols.Encryptable,
        AutoCloseable {

    private final StorageProvider provider;  // M39: owning provider
    private final Hdf5File file;             // native handle (kept for
                                              // signature/encryption paths)
    private final FeatureFlags featureFlags;
    private final String title;
    private final String isaInvestigationId;
    private final Map<String, AcquisitionRun> msRuns;
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;
    // M41.5: Encryptable conformance.
    private com.dtwthalion.mpgo.protection.AccessPolicy accessPolicy;

    private SpectralDataset(StorageProvider provider, Hdf5File file,
                            FeatureFlags featureFlags,
                            String title, String isaInvestigationId,
                            Map<String, AcquisitionRun> msRuns,
                            List<Identification> identifications,
                            List<Quantification> quantifications,
                            List<ProvenanceRecord> provenanceRecords) {
        this.provider = provider;
        this.file = file;
        this.featureFlags = featureFlags;
        this.title = title;
        this.isaInvestigationId = isaInvestigationId;
        this.msRuns = msRuns;
        this.identifications = identifications;
        this.quantifications = quantifications;
        this.provenanceRecords = provenanceRecords;
    }

    /** The absolute path of the underlying .mpgo file (null for in-memory datasets). */
    public String filePath() {
        return file != null ? file.getPath() : null;
    }

    /** M39: the owning storage provider. New call sites should reach
     *  for this instead of the native {@link Hdf5File}. */
    public StorageProvider provider() { return provider; }

    // ── Accessors ───────────────────────────────────────────────────

    public FeatureFlags featureFlags() { return featureFlags; }
    public String title() { return title; }
    public String isaInvestigationId() { return isaInvestigationId; }
    public Map<String, AcquisitionRun> msRuns() { return msRuns; }
    public List<Identification> identifications() { return identifications; }
    public List<Quantification> quantifications() { return quantifications; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    // ── Open (read) ─────────────────────────────────────────────────

    /** Open an existing .mpgo file for reading. v0.9 M64.5 (Java):
     *  a URL scheme ({@code memory://}, {@code sqlite://},
     *  {@code zarr://}) dispatches to the matching StorageProvider
     *  and reads the whole dataset through the protocol
     *  (StorageGroup-based); bare paths (and {@code file://} URLs)
     *  stay on the HDF5 fast path for byte parity with pre-M64.5
     *  files and the cross-language smoke suite. */
    public static SpectralDataset open(String pathOrUrl) {
        if (pathOrUrl != null && isNonHdf5Url(pathOrUrl)) {
            return openViaProvider(pathOrUrl);
        }
        Hdf5Provider provider = (Hdf5Provider) new Hdf5Provider()
                .open(pathOrUrl, StorageProvider.Mode.READ);
        Hdf5File file = (Hdf5File) provider.nativeHandle();
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
                                        // v0.7 M44: AcquisitionRun.readFrom takes
                                        // StorageGroup; wrap the raw Hdf5Group.
                                        AcquisitionRun run = AcquisitionRun.readFrom(
                                                Hdf5Provider.adapterForGroup(msRunsGroup), name);
                                        run.setPersistenceContext(pathOrUrl, name);
                                        runs.put(name, run);
                                    }
                                }
                            }
                        }
                    }

                    idents = readIdentifications(study);
                    quants = readQuantifications(study);
                    prov = readProvenance(study);
                }
            }

            return new SpectralDataset(provider, file, flags, title, isaId, runs,
                    idents, quants, prov);
        }
    }

    // ── URL-scheme detection (v0.9 M64.5) ───────────────────────────

    private static final java.util.regex.Pattern NON_HDF5_URL =
            java.util.regex.Pattern.compile("^(memory|sqlite|zarr)://.*");

    private static boolean isNonHdf5Url(String pathOrUrl) {
        return NON_HDF5_URL.matcher(pathOrUrl).matches();
    }

    // ── Provider-aware read path (v0.9 M64.5) ───────────────────────

    private static SpectralDataset openViaProvider(String url) {
        StorageProvider provider = com.dtwthalion.mpgo.providers
                .ProviderRegistry.open(url, StorageProvider.Mode.READ);
        try (com.dtwthalion.mpgo.providers.StorageGroup root =
                provider.rootGroup()) {
            FeatureFlags flags = FeatureFlags.readFrom(root);
            String title = null, isaId = null;
            Map<String, AcquisitionRun> runs = new LinkedHashMap<>();
            List<Identification> idents = List.of();
            List<Quantification> quants = List.of();
            List<ProvenanceRecord> prov = List.of();

            if (root.hasChild("study")) {
                try (com.dtwthalion.mpgo.providers.StorageGroup study =
                        root.openGroup("study")) {
                    if (study.hasAttribute("title")) {
                        Object v = study.getAttribute("title");
                        title = v != null ? v.toString() : null;
                    }
                    if (study.hasAttribute("isa_investigation_id")) {
                        Object v = study.getAttribute("isa_investigation_id");
                        isaId = v != null ? v.toString() : null;
                    }
                    if (study.hasChild("ms_runs")) {
                        try (com.dtwthalion.mpgo.providers.StorageGroup ms =
                                study.openGroup("ms_runs")) {
                            if (ms.hasAttribute("_run_names")) {
                                Object names = ms.getAttribute("_run_names");
                                String csv = names != null ? names.toString() : "";
                                for (String rn : csv.split(",")) {
                                    String name = rn.strip();
                                    if (!name.isEmpty() && ms.hasChild(name)) {
                                        AcquisitionRun run =
                                                AcquisitionRun.readFrom(ms, name);
                                        run.setPersistenceContext(url, name);
                                        runs.put(name, run);
                                    }
                                }
                            }
                        }
                    }
                    idents = readIdentificationsFromJson(study);
                    quants = readQuantificationsFromJson(study);
                    prov = readProvenanceFromJson(study);
                }
            }
            return new SpectralDataset(provider, null, flags, title, isaId, runs,
                    idents, quants, prov);
        }
    }

    private static SpectralDataset createViaProvider(
            String url, String title, String isaInvestigationId,
            List<AcquisitionRun> runs,
            List<Identification> identifications,
            List<Quantification> quantifications,
            List<ProvenanceRecord> provenanceRecords,
            FeatureFlags featureFlags) {
        StorageProvider provider = com.dtwthalion.mpgo.providers
                .ProviderRegistry.open(url, StorageProvider.Mode.CREATE);
        // Batch all create-time writes into a single provider transaction so
        // SQLite doesn't fsync per group/dataset/attribute. No-op for
        // providers without explicit transactions (default StorageProvider
        // impl).
        provider.beginTransaction();
        try (com.dtwthalion.mpgo.providers.StorageGroup root =
                provider.rootGroup()) {
            featureFlags.writeTo(root);
            try (com.dtwthalion.mpgo.providers.StorageGroup study =
                    root.createGroup("study")) {
                if (title != null) study.setAttribute("title", title);
                if (isaInvestigationId != null)
                    study.setAttribute("isa_investigation_id", isaInvestigationId);

                Map<String, AcquisitionRun> runMap = new LinkedHashMap<>();
                if (runs != null && !runs.isEmpty()) {
                    try (com.dtwthalion.mpgo.providers.StorageGroup ms =
                            study.createGroup("ms_runs")) {
                        StringBuilder names = new StringBuilder();
                        for (int i = 0; i < runs.size(); i++) {
                            AcquisitionRun run = runs.get(i);
                            if (i > 0) names.append(",");
                            names.append(run.name());
                            run.writeTo(ms);
                            runMap.put(run.name(), run);
                        }
                        ms.setAttribute("_run_names", names.toString());
                    }
                }
                if (identifications != null && !identifications.isEmpty()) {
                    study.setAttribute("identifications_json",
                            buildIdentificationsJson(identifications));
                }
                if (quantifications != null && !quantifications.isEmpty()) {
                    study.setAttribute("quantifications_json",
                            buildQuantificationsJson(quantifications));
                }
                if (provenanceRecords != null && !provenanceRecords.isEmpty()) {
                    study.setAttribute("provenance_json",
                            buildProvenanceJson(provenanceRecords));
                }
                SpectralDataset out = new SpectralDataset(provider, null,
                        featureFlags, title, isaInvestigationId, runMap,
                        identifications != null ? identifications : List.of(),
                        quantifications != null ? quantifications : List.of(),
                        provenanceRecords != null ? provenanceRecords : List.of());
                provider.commitTransaction();
                return out;
            }
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
                autoFeatureFlags(runs));
    }

    /** M74 Slice E: default feature flags upgraded with
     *  {@code opt_ms2_activation_detail} + format version bumped to
     *  {@code "1.3"} whenever any run's {@link SpectrumIndex} carries
     *  the four optional activation/isolation columns. Files without
     *  M74 content keep the legacy 1.1 layout so existing byte-parity
     *  tests continue to pass. */
    private static FeatureFlags autoFeatureFlags(List<AcquisitionRun> runs) {
        FeatureFlags base = FeatureFlags.defaultCurrent();
        if (runs == null) return base;
        boolean anyM74 = false;
        for (AcquisitionRun r : runs) {
            if (r.spectrumIndex() != null
                    && r.spectrumIndex().activationMethods() != null) {
                anyM74 = true;
                break;
            }
        }
        if (!anyM74) return base;
        java.util.Set<String> withFlag = new java.util.LinkedHashSet<>(base.features());
        withFlag.add(FeatureFlags.OPT_MS2_ACTIVATION_DETAIL);
        return new FeatureFlags("1.3", withFlag);
    }

    public static SpectralDataset create(String pathOrUrl, String title,
                                          String isaInvestigationId,
                                          List<AcquisitionRun> runs,
                                          List<Identification> identifications,
                                          List<Quantification> quantifications,
                                          List<ProvenanceRecord> provenanceRecords,
                                          FeatureFlags featureFlags) {
        if (pathOrUrl != null && isNonHdf5Url(pathOrUrl)) {
            return createViaProvider(pathOrUrl, title, isaInvestigationId,
                    runs, identifications, quantifications, provenanceRecords,
                    featureFlags);
        }
        Hdf5Provider provider = (Hdf5Provider) new Hdf5Provider()
                .open(pathOrUrl, StorageProvider.Mode.CREATE);
        Hdf5File file = (Hdf5File) provider.nativeHandle();
        try (Hdf5Group root = file.rootGroup()) {
            featureFlags.writeTo(root);

            try (Hdf5Group study = root.createGroup("study")) {
                if (title != null) study.setStringAttribute("title", title);
                if (isaInvestigationId != null)
                    study.setStringAttribute("isa_investigation_id", isaInvestigationId);

                Map<String, AcquisitionRun> runMap = new LinkedHashMap<>();
                if (runs != null && !runs.isEmpty()) {
                    try (Hdf5Group msRunsGroup = study.createGroup("ms_runs")) {
                        StringBuilder names = new StringBuilder();
                        for (int i = 0; i < runs.size(); i++) {
                            AcquisitionRun run = runs.get(i);
                            if (i > 0) names.append(",");
                            names.append(run.name());
                            // v0.7 M44: writeTo takes StorageGroup; wrap the
                            // raw Hdf5Group via the provider adapter.
                            run.writeTo(Hdf5Provider.adapterForGroup(msRunsGroup));
                            runMap.put(run.name(), run);
                        }
                        msRunsGroup.setStringAttribute("_run_names", names.toString());
                    }
                }

                if (identifications != null && !identifications.isEmpty()) {
                    writeIdentifications(study, identifications);
                }
                if (quantifications != null && !quantifications.isEmpty()) {
                    writeQuantifications(study, quantifications);
                }
                if (provenanceRecords != null && !provenanceRecords.isEmpty()) {
                    writeProvenance(study, provenanceRecords);
                }

                return new SpectralDataset(provider, file, featureFlags, title, isaInvestigationId,
                        runMap, identifications != null ? identifications : List.of(),
                        quantifications != null ? quantifications : List.of(),
                        provenanceRecords != null ? provenanceRecords : List.of());
            }
        }
    }

    // ── Compound metadata: identifications ──────────────────────────

    private static void writeIdentifications(Hdf5Group study,
                                              List<Identification> idents) {
        // Native compound dataset matching format-spec §6.1
        Hdf5CompoundIO.writeCompoundDataset(study, "identifications",
                Hdf5CompoundIO.identificationSchema(),
                idents.size(),
                (row, pool) -> new Object[]{
                        pool.addString(idents.get(row).runName()),
                        idents.get(row).spectrumIndex(),
                        pool.addString(idents.get(row).chemicalEntity()),
                        idents.get(row).confidenceScore(),
                        pool.addString(idents.get(row).evidenceChainJson())
                });

        // JSON mirror on @identifications_json so JHI5-1.10 readers
        // (currently only our own) can recover VL-string fields.
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < idents.size(); i++) {
            if (i > 0) json.append(',');
            Identification id = idents.get(i);
            json.append('{')
                .append("\"run_name\":").append(MiniJson.quote(id.runName()))
                .append(",\"spectrum_index\":").append(id.spectrumIndex())
                .append(",\"chemical_entity\":").append(MiniJson.quote(id.chemicalEntity()))
                .append(",\"confidence_score\":").append(id.confidenceScore())
                .append(",\"evidence_chain\":").append(
                        id.evidenceChainJson() == null || id.evidenceChainJson().isEmpty()
                                ? "[]" : id.evidenceChainJson())
                .append('}');
        }
        json.append(']');
        study.setStringAttribute("identifications_json", json.toString());
    }

    private static List<Identification> readIdentifications(Hdf5Group study) {
        if (study.hasAttribute("identifications_json")) {
            return parseIdentificationsJson(study.readStringAttribute("identifications_json"));
        }
        if (study.hasChild("identifications")) {
            // Python/ObjC file without JSON mirror — recover primitive fields.
            // VL strings decode as empty (see class-level javadoc).
            List<Object[]> rows = Hdf5CompoundIO.readCompoundPrimitives(
                    study, "identifications", Hdf5CompoundIO.identificationSchema());
            List<Identification> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new Identification(
                        (String) r[0], (Integer) r[1], (String) r[2],
                        (Double) r[3], MiniJson.parseArrayOfStrings((String) r[4])));
            }
            return out;
        }
        return List.of();
    }

    // ── Compound metadata: quantifications ──────────────────────────

    private static void writeQuantifications(Hdf5Group study,
                                              List<Quantification> quants) {
        Hdf5CompoundIO.writeCompoundDataset(study, "quantifications",
                Hdf5CompoundIO.quantificationSchema(),
                quants.size(),
                (row, pool) -> new Object[]{
                        pool.addString(quants.get(row).chemicalEntity()),
                        pool.addString(quants.get(row).sampleRef()),
                        quants.get(row).abundance(),
                        pool.addString(quants.get(row).normalizationMethod() != null
                                ? quants.get(row).normalizationMethod() : "")
                });

        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < quants.size(); i++) {
            if (i > 0) json.append(',');
            Quantification q = quants.get(i);
            json.append('{')
                .append("\"chemical_entity\":").append(MiniJson.quote(q.chemicalEntity()))
                .append(",\"sample_ref\":").append(MiniJson.quote(q.sampleRef()))
                .append(",\"abundance\":").append(q.abundance());
            if (q.normalizationMethod() != null) {
                json.append(",\"normalization_method\":").append(MiniJson.quote(q.normalizationMethod()));
            }
            json.append('}');
        }
        json.append(']');
        study.setStringAttribute("quantifications_json", json.toString());
    }

    private static List<Quantification> readQuantifications(Hdf5Group study) {
        if (study.hasAttribute("quantifications_json")) {
            return parseQuantificationsJson(study.readStringAttribute("quantifications_json"));
        }
        if (study.hasChild("quantifications")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundPrimitives(
                    study, "quantifications", Hdf5CompoundIO.quantificationSchema());
            List<Quantification> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                String norm = (String) r[3];
                if (norm != null && norm.isEmpty()) norm = null;
                out.add(new Quantification(
                        (String) r[0], (String) r[1], (Double) r[2], norm));
            }
            return out;
        }
        return List.of();
    }

    // ── Compound metadata: provenance ───────────────────────────────

    private static void writeProvenance(Hdf5Group study,
                                         List<ProvenanceRecord> records) {
        Hdf5CompoundIO.writeCompoundDataset(study, "provenance",
                Hdf5CompoundIO.provenanceSchema(),
                records.size(),
                (row, pool) -> new Object[]{
                        records.get(row).timestampUnix(),
                        pool.addString(records.get(row).software()),
                        pool.addString(records.get(row).parametersJson()),
                        pool.addString(records.get(row).inputRefsJson()),
                        pool.addString(records.get(row).outputRefsJson())
                });

        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < records.size(); i++) {
            if (i > 0) json.append(',');
            ProvenanceRecord r = records.get(i);
            json.append('{')
                .append("\"timestamp_unix\":").append(r.timestampUnix())
                .append(",\"software\":").append(MiniJson.quote(r.software()))
                .append(",\"parameters\":").append(nonEmptyJson(r.parametersJson(), "{}"))
                .append(",\"input_refs\":").append(nonEmptyJson(r.inputRefsJson(), "[]"))
                .append(",\"output_refs\":").append(nonEmptyJson(r.outputRefsJson(), "[]"))
                .append('}');
        }
        json.append(']');
        study.setStringAttribute("provenance_json", json.toString());
    }

    private static List<ProvenanceRecord> readProvenance(Hdf5Group study) {
        if (study.hasAttribute("provenance_json")) {
            return parseProvenanceJson(study.readStringAttribute("provenance_json"));
        }
        if (study.hasChild("provenance")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundPrimitives(
                    study, "provenance", Hdf5CompoundIO.provenanceSchema());
            List<ProvenanceRecord> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new ProvenanceRecord(
                        (Long) r[0], (String) r[1],
                        MiniJson.parseStringMap((String) r[2]),
                        MiniJson.parseArrayOfStrings((String) r[3]),
                        MiniJson.parseArrayOfStrings((String) r[4])));
            }
            return out;
        }
        return List.of();
    }

    // ── StorageGroup-based JSON metadata (v0.9 M64.5) ───────────────

    private static List<Identification> readIdentificationsFromJson(
            com.dtwthalion.mpgo.providers.StorageGroup study) {
        if (!study.hasAttribute("identifications_json")) return List.of();
        Object v = study.getAttribute("identifications_json");
        return v != null ? parseIdentificationsJson(v.toString()) : List.of();
    }

    private static List<Quantification> readQuantificationsFromJson(
            com.dtwthalion.mpgo.providers.StorageGroup study) {
        if (!study.hasAttribute("quantifications_json")) return List.of();
        Object v = study.getAttribute("quantifications_json");
        return v != null ? parseQuantificationsJson(v.toString()) : List.of();
    }

    private static List<ProvenanceRecord> readProvenanceFromJson(
            com.dtwthalion.mpgo.providers.StorageGroup study) {
        if (!study.hasAttribute("provenance_json")) return List.of();
        Object v = study.getAttribute("provenance_json");
        return v != null ? parseProvenanceJson(v.toString()) : List.of();
    }

    static String buildIdentificationsJson(List<Identification> idents) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < idents.size(); i++) {
            if (i > 0) json.append(',');
            Identification id = idents.get(i);
            json.append('{')
                .append("\"run_name\":").append(MiniJson.quote(id.runName()))
                .append(",\"spectrum_index\":").append(id.spectrumIndex())
                .append(",\"chemical_entity\":").append(MiniJson.quote(id.chemicalEntity()))
                .append(",\"confidence_score\":").append(id.confidenceScore())
                .append(",\"evidence_chain\":").append(
                        id.evidenceChainJson() == null || id.evidenceChainJson().isEmpty()
                                ? "[]" : id.evidenceChainJson())
                .append('}');
        }
        json.append(']');
        return json.toString();
    }

    static String buildQuantificationsJson(List<Quantification> quants) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < quants.size(); i++) {
            if (i > 0) json.append(',');
            Quantification q = quants.get(i);
            json.append('{')
                .append("\"chemical_entity\":").append(MiniJson.quote(q.chemicalEntity()))
                .append(",\"sample_ref\":").append(MiniJson.quote(q.sampleRef()))
                .append(",\"abundance\":").append(q.abundance());
            if (q.normalizationMethod() != null) {
                json.append(",\"normalization_method\":").append(MiniJson.quote(q.normalizationMethod()));
            }
            json.append('}');
        }
        json.append(']');
        return json.toString();
    }

    static String buildProvenanceJson(List<ProvenanceRecord> records) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < records.size(); i++) {
            if (i > 0) json.append(',');
            ProvenanceRecord r = records.get(i);
            json.append('{')
                .append("\"timestamp_unix\":").append(r.timestampUnix())
                .append(",\"software\":").append(MiniJson.quote(r.software()))
                .append(",\"parameters\":").append(nonEmptyJson(r.parametersJson(), "{}"))
                .append(",\"input_refs\":").append(nonEmptyJson(r.inputRefsJson(), "[]"))
                .append(",\"output_refs\":").append(nonEmptyJson(r.outputRefsJson(), "[]"))
                .append('}');
        }
        json.append(']');
        return json.toString();
    }

    // ── JSON parsing (attribute fallback path) ──────────────────────

    private static List<Identification> parseIdentificationsJson(String blob) {
        List<Identification> out = new ArrayList<>();
        for (Map<String, Object> r : MiniJson.parseArrayOfObjects(blob)) {
            String runName = MiniJson.getString(r, "run_name", "");
            int idx = (int) MiniJson.getLong(r, "spectrum_index", 0);
            String chem = MiniJson.getString(r, "chemical_entity", "");
            double conf = MiniJson.getDouble(r, "confidence_score", 0.0);
            Object ev = r.get("evidence_chain");
            List<String> evidenceChain = ev instanceof List<?> list
                    ? list.stream().map(Object::toString).toList()
                    : List.of();
            out.add(new Identification(runName, idx, chem, conf, evidenceChain));
        }
        return out;
    }

    private static List<Quantification> parseQuantificationsJson(String blob) {
        List<Quantification> out = new ArrayList<>();
        for (Map<String, Object> r : MiniJson.parseArrayOfObjects(blob)) {
            String chem = MiniJson.getString(r, "chemical_entity", "");
            String sample = MiniJson.getString(r, "sample_ref", "");
            double abund = MiniJson.getDouble(r, "abundance", 0.0);
            String norm = r.containsKey("normalization_method")
                    ? MiniJson.getString(r, "normalization_method", null)
                    : null;
            if (norm != null && norm.isEmpty()) norm = null;
            out.add(new Quantification(chem, sample, abund, norm));
        }
        return out;
    }

    private static List<ProvenanceRecord> parseProvenanceJson(String blob) {
        List<ProvenanceRecord> out = new ArrayList<>();
        for (Map<String, Object> r : MiniJson.parseArrayOfObjects(blob)) {
            long ts = MiniJson.getLong(r, "timestamp_unix", 0);
            String software = MiniJson.getString(r, "software", "");
            Object paramsObj = r.get("parameters");
            Map<String, String> params;
            if (paramsObj instanceof Map<?, ?> m) {
                Map<String, String> tmp = new java.util.LinkedHashMap<>();
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    tmp.put(e.getKey().toString(),
                            e.getValue() == null ? "" : e.getValue().toString());
                }
                params = tmp;
            } else {
                params = Map.of();
            }
            Object inRefsObj = r.get("input_refs");
            List<String> inRefs = inRefsObj instanceof List<?> l
                    ? l.stream().map(o -> o == null ? "" : o.toString()).toList()
                    : List.of();
            Object outRefsObj = r.get("output_refs");
            List<String> outRefs = outRefsObj instanceof List<?> l
                    ? l.stream().map(o -> o == null ? "" : o.toString()).toList()
                    : List.of();
            out.add(new ProvenanceRecord(ts, software, params, inRefs, outRefs));
        }
        return out;
    }

    private static String nonEmptyJson(String s, String fallback) {
        return s == null || s.isEmpty() ? fallback : s;
    }

    // ---- Encryptable conformance ----

    @Override
    public void encryptWithKey(byte[] key, com.dtwthalion.mpgo.Enums.EncryptionLevel level)
            throws Exception {
        for (var run : msRuns.values()) run.encryptWithKey(key, level);
    }

    @Override
    public void decryptWithKey(byte[] key) throws Exception {
        for (var run : msRuns.values()) run.decryptWithKey(key);
    }

    @Override
    public Object accessPolicy() { return accessPolicy; }

    @Override
    public void setAccessPolicy(Object policy) {
        this.accessPolicy = (com.dtwthalion.mpgo.protection.AccessPolicy) policy;
    }

    @Override
    public void close() {
        // Prefer closing via the provider (owns the native handle); fall
        // back to direct file close for legacy callers that didn't go
        // through Hdf5Provider.
        if (provider != null) {
            provider.close();
        } else if (file != null) {
            file.close();
        }
    }
}
