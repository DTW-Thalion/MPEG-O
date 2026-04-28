/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.genomics.GenomicIndex;        // M82.3
import global.thalion.ttio.genomics.GenomicRun;          // M82.3
import global.thalion.ttio.genomics.WrittenGenomicRun;   // M82.3
import global.thalion.ttio.hdf5.Hdf5CompoundIO;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;
import global.thalion.ttio.providers.StorageProvider;

import java.util.*;

/**
 * Root reader/writer for TTI-O {@code .tio} files. Implements
 * {@link AutoCloseable} for try-with-resources.
 *
 * <p>HDF5 layout: root group has {@code @ttio_format_version} and
 * {@code @ttio_features} attributes. The {@code /study/} group contains
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
 * {@code TTIOSpectralDataset}, Python
 * {@code ttio.spectral_dataset.SpectralDataset}.</p>
 *
 * @since 0.6
 */
public class SpectralDataset implements
        global.thalion.ttio.protocols.Encryptable,
        AutoCloseable {

    private final StorageProvider provider;  // M39: owning provider
    private final Hdf5File file;             // native handle (kept for
                                              // signature/encryption paths)
    private final FeatureFlags featureFlags;
    private final String title;
    private final String isaInvestigationId;
    private final Map<String, AcquisitionRun> msRuns;
    private final Map<String, GenomicRun> genomicRuns;  // M82.3
    private final List<Identification> identifications;
    private final List<Quantification> quantifications;
    private final List<ProvenanceRecord> provenanceRecords;
    // M41.5: Encryptable conformance.
    private global.thalion.ttio.protection.AccessPolicy accessPolicy;
    // v1.1 Issue A: root-level encryption state that survives close/reopen.
    // Empty string when the dataset carries no @encrypted root attribute;
    // "aes-256-gcm" when it does. Updated by encryptWithKey and by both
    // readers.
    private String encryptedAlgorithm;

    private SpectralDataset(StorageProvider provider, Hdf5File file,
                            FeatureFlags featureFlags,
                            String title, String isaInvestigationId,
                            Map<String, AcquisitionRun> msRuns,
                            Map<String, GenomicRun> genomicRuns,
                            List<Identification> identifications,
                            List<Quantification> quantifications,
                            List<ProvenanceRecord> provenanceRecords,
                            String encryptedAlgorithm) {
        this.provider = provider;
        this.file = file;
        this.featureFlags = featureFlags;
        this.title = title;
        this.isaInvestigationId = isaInvestigationId;
        this.msRuns = msRuns;
        this.genomicRuns = genomicRuns != null ? genomicRuns : Map.of();
        this.identifications = identifications;
        this.quantifications = quantifications;
        this.provenanceRecords = provenanceRecords;
        this.encryptedAlgorithm = encryptedAlgorithm != null ? encryptedAlgorithm : "";
    }

    // Pre-M82.3 constructors (kept for callers that don't use genomic_runs).
    private SpectralDataset(StorageProvider provider, Hdf5File file,
                            FeatureFlags featureFlags,
                            String title, String isaInvestigationId,
                            Map<String, AcquisitionRun> msRuns,
                            List<Identification> identifications,
                            List<Quantification> quantifications,
                            List<ProvenanceRecord> provenanceRecords,
                            String encryptedAlgorithm) {
        this(provider, file, featureFlags, title, isaInvestigationId, msRuns,
                Map.of(), identifications, quantifications, provenanceRecords,
                encryptedAlgorithm);
    }

    private SpectralDataset(StorageProvider provider, Hdf5File file,
                            FeatureFlags featureFlags,
                            String title, String isaInvestigationId,
                            Map<String, AcquisitionRun> msRuns,
                            List<Identification> identifications,
                            List<Quantification> quantifications,
                            List<ProvenanceRecord> provenanceRecords) {
        this(provider, file, featureFlags, title, isaInvestigationId, msRuns,
                Map.of(), identifications, quantifications, provenanceRecords, "");
    }

    /** The absolute path of the underlying .tio file (null for in-memory datasets). */
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
    /** v0.11 M82.3: zero or more named genomic runs. Empty for pre-M82
     *  files; populated when {@code /study/genomic_runs/} is present. */
    public Map<String, GenomicRun> genomicRuns() { return genomicRuns; }

    // ── Phase 2 (post-M91) — canonical unified runs accessor ────────

    /** Phase 2: canonical mapping over every run in the file (MS +
     *  genomic), keyed by run name. Values conform to the
     *  {@link global.thalion.ttio.protocols.Run} interface so callers
     *  can iterate uniformly without knowing the underlying modality:
     *
     *  <pre>{@code
     *  for (var entry : ds.runs().entrySet()) {
     *      Run run = entry.getValue();
     *      System.out.println(run.name() + ": " + run.count() + " measurements");
     *  }
     *  }</pre>
     *
     *  <p>Use {@link #runsOfModality(Class)} to narrow by class, or
     *  {@link #runsForSample(String)} to filter by provenance sample
     *  URI. Phase 2 promotes this to the canonical access pattern;
     *  the legacy {@link #msRuns()} / {@link #genomicRuns()} maps
     *  continue to work, but new code should prefer {@code runs()}.</p>
     *
     *  <p>NMR runs are reported alongside MS runs because the Java
     *  implementation does not split them on disk —
     *  {@link AcquisitionRun} carries both modalities, and
     *  {@code msRuns} already covers both.</p> */
    public Map<String, global.thalion.ttio.protocols.Run> runs() {
        Map<String, global.thalion.ttio.protocols.Run> merged =
            new LinkedHashMap<>();
        for (var entry : msRuns.entrySet()) {
            merged.put(entry.getKey(), entry.getValue());
        }
        for (var entry : genomicRuns.entrySet()) {
            // First-write-wins, matching Python's ``setdefault`` semantics.
            merged.putIfAbsent(entry.getKey(), entry.getValue());
        }
        return merged;
    }

    /** Phase 1 (post-M91): every run associated with {@code sampleUri}.
     *  A run is considered associated when its
     *  {@link global.thalion.ttio.protocols.Run#provenanceChain
     *  provenanceChain} carries {@code sampleUri} in any record's
     *  {@link ProvenanceRecord#inputRefs}. Walks all modalities (MS,
     *  NMR, genomic) uniformly via the Run interface — closes the M91
     *  cross-modality query gap that previously had to fork on
     *  access pattern.
     *
     *  <p>Returns a map keyed by run name; empty when no run matches.
     *  Iteration order is the unified order of {@link #runs()}.</p> */
    public Map<String, global.thalion.ttio.protocols.Run> runsForSample(
            String sampleUri) {
        Map<String, global.thalion.ttio.protocols.Run> out =
            new LinkedHashMap<>();
        for (var entry : runs().entrySet()) {
            global.thalion.ttio.protocols.Run run = entry.getValue();
            List<ProvenanceRecord> chain;
            try {
                chain = run.provenanceChain();
            } catch (Exception e) {
                continue;
            }
            if (chain == null) continue;
            for (ProvenanceRecord r : chain) {
                if (r.inputRefs().contains(sampleUri)) {
                    out.put(entry.getKey(), run);
                    break;
                }
            }
        }
        return out;
    }

    /** Phase 1 (post-M91): every run whose value is an instance of
     *  {@code runType}. Pass {@link AcquisitionRun}{@code .class} to
     *  get the union of MS + NMR runs (any spectrum-class subtype);
     *  pass {@link GenomicRun}{@code .class} to get genomic only. The
     *  return is a thin filter over {@link #runs()}. */
    public Map<String, global.thalion.ttio.protocols.Run> runsOfModality(
            Class<? extends global.thalion.ttio.protocols.Run> runType) {
        Map<String, global.thalion.ttio.protocols.Run> out =
            new LinkedHashMap<>();
        for (var entry : runs().entrySet()) {
            if (runType.isInstance(entry.getValue())) {
                out.put(entry.getKey(), entry.getValue());
            }
        }
        return out;
    }

    public List<Identification> identifications() { return identifications; }
    public List<Quantification> quantifications() { return quantifications; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    /** {@code true} iff this dataset carries an {@code @encrypted} root
     *  attribute. Survives close/reopen because the value is read back
     *  from disk by {@link #open}. Mirrors Python
     *  {@code SpectralDataset.is_encrypted} and Objective-C
     *  {@code -[TTIOSpectralDataset isEncrypted]}. */
    public boolean isEncrypted() { return !encryptedAlgorithm.isEmpty(); }

    /** Algorithm string stored in the root {@code @encrypted} attribute,
     *  or the empty string when the dataset is not encrypted. Typical
     *  value is {@code "aes-256-gcm"}. Mirrors Python
     *  {@code SpectralDataset.encrypted_algorithm} and Objective-C
     *  {@code -[TTIOSpectralDataset encryptedAlgorithm]}. */
    public String encryptedAlgorithm() { return encryptedAlgorithm; }

    // ── Open (read) ─────────────────────────────────────────────────

    /** Open an existing .tio file for reading. v0.9 M64.5 (Java):
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
            String encryptedAlg = root.hasAttribute("encrypted")
                    ? root.readStringAttribute("encrypted") : "";

            String title = null;
            String isaId = null;
            Map<String, AcquisitionRun> runs = new LinkedHashMap<>();
            Map<String, GenomicRun> genomicRuns = new LinkedHashMap<>();  // M82.3
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

                    // M82.3: read genomic_runs/ when present.
                    if (study.hasChild("genomic_runs")) {
                        try (Hdf5Group gG = study.openGroup("genomic_runs")) {
                            if (gG.hasAttribute("_run_names")) {
                                String names = gG.readStringAttribute("_run_names");
                                var gAdapter = Hdf5Provider.adapterForGroup(gG);
                                for (String rn : names.split(",")) {
                                    String name = rn.strip();
                                    if (!name.isEmpty() && gG.hasChild(name)) {
                                        var rgGroup = gAdapter.openGroup(name);
                                        genomicRuns.put(name,
                                            GenomicRun.readFrom(rgGroup, name));
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
                    genomicRuns, idents, quants, prov, encryptedAlg);
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
        StorageProvider provider = global.thalion.ttio.providers
                .ProviderRegistry.open(url, StorageProvider.Mode.READ);
        try (global.thalion.ttio.providers.StorageGroup root =
                provider.rootGroup()) {
            FeatureFlags flags = FeatureFlags.readFrom(root);
            String encryptedAlg = "";
            if (root.hasAttribute("encrypted")) {
                Object v = root.getAttribute("encrypted");
                if (v != null) encryptedAlg = v.toString();
            }
            String title = null, isaId = null;
            Map<String, AcquisitionRun> runs = new LinkedHashMap<>();
            Map<String, GenomicRun> genomicRuns = new LinkedHashMap<>();  // M82.3
            List<Identification> idents = List.of();
            List<Quantification> quants = List.of();
            List<ProvenanceRecord> prov = List.of();

            if (root.hasChild("study")) {
                try (global.thalion.ttio.providers.StorageGroup study =
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
                        try (global.thalion.ttio.providers.StorageGroup ms =
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
                    // M82.3: read genomic_runs/ from any provider.
                    if (study.hasChild("genomic_runs")) {
                        try (var gG = study.openGroup("genomic_runs")) {
                            if (gG.hasAttribute("_run_names")) {
                                Object n = gG.getAttribute("_run_names");
                                String csv = n != null ? n.toString() : "";
                                for (String rn : csv.split(",")) {
                                    String name = rn.strip();
                                    if (!name.isEmpty() && gG.hasChild(name)) {
                                        var rgGroup = gG.openGroup(name);
                                        genomicRuns.put(name,
                                            GenomicRun.readFrom(rgGroup, name));
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
                    genomicRuns, idents, quants, prov, encryptedAlg);
        }
    }

    private static SpectralDataset createViaProviderMixed(
            String url, String title, String isaInvestigationId,
            List<AcquisitionRun> runs,
            List<WrittenGenomicRun> genomicRuns,
            List<String> genomicRunNames,
            List<Identification> identifications,
            List<Quantification> quantifications,
            List<ProvenanceRecord> provenanceRecords,
            FeatureFlags featureFlags) {
        StorageProvider provider = global.thalion.ttio.providers
                .ProviderRegistry.open(url, StorageProvider.Mode.CREATE);
        // Batch all create-time writes into a single provider transaction so
        // SQLite doesn't fsync per group/dataset/attribute. No-op for
        // providers without explicit transactions (default StorageProvider
        // impl).
        provider.beginTransaction();
        try (global.thalion.ttio.providers.StorageGroup root =
                provider.rootGroup()) {
            featureFlags.writeTo(root);
            try (global.thalion.ttio.providers.StorageGroup study =
                    root.createGroup("study")) {
                if (title != null) study.setAttribute("title", title);
                if (isaInvestigationId != null)
                    study.setAttribute("isa_investigation_id", isaInvestigationId);

                Map<String, AcquisitionRun> runMap = new LinkedHashMap<>();
                if (runs != null && !runs.isEmpty()) {
                    try (global.thalion.ttio.providers.StorageGroup ms =
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

                // M82.3: genomic_runs subtree (provider-agnostic).
                Map<String, GenomicRun> genomicMap = new LinkedHashMap<>();
                if (genomicRuns != null && !genomicRuns.isEmpty()) {
                    try (var gG = study.createGroup("genomic_runs")) {
                        StringBuilder names = new StringBuilder();
                        for (int i = 0; i < genomicRuns.size(); i++) {
                            WrittenGenomicRun gr = genomicRuns.get(i);
                            String gname = genomicRunNames.get(i);
                            if (i > 0) names.append(",");
                            names.append(gname);
                            writeGenomicRunSubtree(gG, gname, gr);
                            try (var rgGroup = gG.openGroup(gname)) {
                                genomicMap.put(gname, GenomicRun.readFrom(rgGroup, gname));
                            }
                        }
                        gG.setAttribute("_run_names", names.toString());
                    }
                }

                SpectralDataset out = new SpectralDataset(provider, null,
                        featureFlags, title, isaInvestigationId, runMap,
                        genomicMap,
                        identifications != null ? identifications : List.of(),
                        quantifications != null ? quantifications : List.of(),
                        provenanceRecords != null ? provenanceRecords : List.of(),
                        "");
                provider.commitTransaction();
                return out;
            }
        }
    }

    // ── Create (write) ──────────────────────────────────────────────

    /** Create a new .tio file with the given content. */
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

    /** v0.11 M82.3: Convenience overload that delegates to the
     *  {@code genomicRuns}-aware variant with an empty genomic list. */
    public static SpectralDataset create(String pathOrUrl, String title,
                                          String isaInvestigationId,
                                          List<AcquisitionRun> runs,
                                          List<Identification> identifications,
                                          List<Quantification> quantifications,
                                          List<ProvenanceRecord> provenanceRecords,
                                          FeatureFlags featureFlags) {
        return create(pathOrUrl, title, isaInvestigationId, runs, List.of(),
                identifications, quantifications, provenanceRecords, featureFlags);
    }

    /** Phase 2 (post-M91): mixed-Map create. The {@code runs} map may
     *  carry both {@link AcquisitionRun} (MS / NMR) and
     *  {@link WrittenGenomicRun} (genomic) values; this overload
     *  dispatches by {@code instanceof} on each value and forwards to
     *  the typed-list create API. Mirrors the Python
     *  {@code SpectralDataset.write_minimal} mixed-dict path.
     *
     *  <p>Run-name collision between an MS entry and a genomic entry
     *  raises {@link IllegalArgumentException}. Names are preserved on
     *  disk as-is — the genomic entries no longer get an automatic
     *  {@code genomic_NNNN} prefix when supplied via this overload, so
     *  callers control the storage name.</p>
     *
     *  <p>{@code values} may be empty. Acquired ordering is preserved
     *  (use {@link java.util.LinkedHashMap}). Other parameters mirror
     *  the typed-list overload. */
    public static SpectralDataset create(String pathOrUrl, String title,
                                          String isaInvestigationId,
                                          Map<String, Object> runs,
                                          List<Identification> identifications,
                                          List<Quantification> quantifications,
                                          List<ProvenanceRecord> provenanceRecords,
                                          FeatureFlags featureFlags) {
        if (runs == null) runs = Map.of();
        List<AcquisitionRun> msList = new ArrayList<>();
        List<WrittenGenomicRun> gList = new ArrayList<>();
        java.util.Set<String> msNames = new java.util.LinkedHashSet<>();
        java.util.Set<String> gNames = new java.util.LinkedHashSet<>();
        for (var entry : runs.entrySet()) {
            String name = entry.getKey();
            Object value = entry.getValue();
            if (value instanceof AcquisitionRun ar) {
                if (gNames.contains(name)) {
                    throw new IllegalArgumentException(
                        "Phase 2 mixed runs map: name '" + name
                        + "' appears as both AcquisitionRun and "
                        + "WrittenGenomicRun");
                }
                msNames.add(name);
                // The on-disk name comes from the AcquisitionRun's own
                // ``name()`` field; reject mismatches early so the
                // caller doesn't silently get a different on-disk name.
                if (!name.equals(ar.name())) {
                    throw new IllegalArgumentException(
                        "Phase 2 mixed runs map: key '" + name
                        + "' does not match AcquisitionRun.name() = '"
                        + ar.name() + "'");
                }
                msList.add(ar);
            } else if (value instanceof WrittenGenomicRun gr) {
                if (msNames.contains(name)) {
                    throw new IllegalArgumentException(
                        "Phase 2 mixed runs map: name '" + name
                        + "' appears as both AcquisitionRun and "
                        + "WrittenGenomicRun");
                }
                gNames.add(name);
                gList.add(gr);
            } else if (value == null) {
                throw new IllegalArgumentException(
                    "Phase 2 mixed runs map: value for '" + name
                    + "' is null");
            } else {
                throw new IllegalArgumentException(
                    "Phase 2 mixed runs map: value for '" + name
                    + "' has unsupported type "
                    + value.getClass().getName()
                    + " (expected AcquisitionRun or WrittenGenomicRun)");
            }
        }
        // Phase 2: the mixed-Map path uses the caller-supplied genomic
        // run names verbatim, bypassing the ``genomic_NNNN`` auto-
        // naming used by the typed-list create. Forward through a
        // private helper so we keep the existing list-based factory
        // intact for back-compat.
        return createMixed(pathOrUrl, title, isaInvestigationId,
                           msList, gList, gNames,
                           identifications, quantifications,
                           provenanceRecords, featureFlags);
    }

    /** v0.11 M82.3: full create signature accepting genomic runs
     *  alongside MS runs. When {@code genomicRuns} is non-empty,
     *  {@link FeatureFlags#OPT_GENOMIC} is added (idempotent if the
     *  caller-supplied {@code featureFlags} already includes it) and
     *  the format version is bumped to {@code "1.4"}. */
    public static SpectralDataset create(String pathOrUrl, String title,
                                          String isaInvestigationId,
                                          List<AcquisitionRun> runs,
                                          List<WrittenGenomicRun> genomicRuns,
                                          List<Identification> identifications,
                                          List<Quantification> quantifications,
                                          List<ProvenanceRecord> provenanceRecords,
                                          FeatureFlags featureFlags) {
        // Phase 2: forward through the names-aware helper with the
        // legacy auto-naming scheme (genomic_NNNN). The mixed-Map create
        // overload calls createMixed directly with caller-supplied names.
        java.util.List<String> autoNames = new java.util.ArrayList<>();
        if (genomicRuns != null) {
            for (int i = 0; i < genomicRuns.size(); i++) {
                autoNames.add("genomic_" + String.format("%04d", i + 1));
            }
        }
        return createMixed(pathOrUrl, title, isaInvestigationId,
                runs != null ? runs : List.of(),
                genomicRuns != null ? genomicRuns : List.of(),
                autoNames,
                identifications, quantifications, provenanceRecords,
                featureFlags);
    }

    /** Phase 2 (post-M91): names-aware backend used by both the
     *  typed-list {@link #create(String, String, String, List, List,
     *  List, List, List, FeatureFlags) create} (auto-named genomic
     *  runs) and the mixed-Map {@link #create(String, String, String,
     *  Map, List, List, List, FeatureFlags) create} (caller-supplied
     *  genomic names). Kept private — callers go through one of the
     *  public {@code create} overloads. */
    private static SpectralDataset createMixed(
            String pathOrUrl, String title, String isaInvestigationId,
            List<AcquisitionRun> runs,
            List<WrittenGenomicRun> genomicRuns,
            java.util.Collection<String> genomicRunNames,
            List<Identification> identifications,
            List<Quantification> quantifications,
            List<ProvenanceRecord> provenanceRecords,
            FeatureFlags featureFlags) {
        // M82.3: opt_genomic + format_version 1.4 when genomic content present.
        boolean hasGenomic = genomicRuns != null && !genomicRuns.isEmpty();
        if (hasGenomic && !featureFlags.features().contains(FeatureFlags.OPT_GENOMIC)) {
            java.util.Set<String> withFlag =
                new java.util.LinkedHashSet<>(featureFlags.features());
            withFlag.add(FeatureFlags.OPT_GENOMIC);
            featureFlags = new FeatureFlags("1.4", withFlag);
        } else if (hasGenomic && !"1.4".equals(featureFlags.formatVersion())) {
            featureFlags = new FeatureFlags("1.4", featureFlags.features());
        }

        java.util.List<String> gNamesList = genomicRunNames != null
            ? new java.util.ArrayList<>(genomicRunNames) : new java.util.ArrayList<>();
        if (hasGenomic && gNamesList.size() != genomicRuns.size()) {
            throw new IllegalStateException(
                "createMixed: genomicRunNames (" + gNamesList.size()
                + ") does not match genomicRuns (" + genomicRuns.size() + ")");
        }

        if (pathOrUrl != null && isNonHdf5Url(pathOrUrl)) {
            return createViaProviderMixed(pathOrUrl, title, isaInvestigationId,
                    runs, genomicRuns, gNamesList,
                    identifications, quantifications,
                    provenanceRecords, featureFlags);
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

                // M82.3: genomic_runs subtree (only when non-empty).
                Map<String, GenomicRun> genomicMap = new LinkedHashMap<>();
                if (hasGenomic) {
                    try (Hdf5Group gRunsGroup = study.createGroup("genomic_runs")) {
                        StringBuilder names = new StringBuilder();
                        for (int i = 0; i < genomicRuns.size(); i++) {
                            WrittenGenomicRun gr = genomicRuns.get(i);
                            String gname = gNamesList.get(i);
                            if (i > 0) names.append(",");
                            names.append(gname);
                            writeGenomicRunSubtree(
                                Hdf5Provider.adapterForGroup(gRunsGroup), gname, gr);
                            // Open a read-side handle to populate genomicMap.
                            try (var gAdapter = Hdf5Provider.adapterForGroup(gRunsGroup);
                                 var rgGroup = gAdapter.openGroup(gname)) {
                                genomicMap.put(gname, GenomicRun.readFrom(rgGroup, gname));
                            }
                        }
                        gRunsGroup.setStringAttribute("_run_names", names.toString());
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
                        runMap, genomicMap,
                        identifications != null ? identifications : List.of(),
                        quantifications != null ? quantifications : List.of(),
                        provenanceRecords != null ? provenanceRecords : List.of(),
                        "");
            }
        }
    }

    /** v0.11 M82.3: write one {@code /study/genomic_runs/<name>/}
     *  subtree via the StorageGroup protocol. Provider-agnostic — used
     *  by both the HDF5 fast path and the {@code memory://} /
     *  {@code sqlite://} / {@code zarr://} paths.
     *
     *  <p>M86: validates {@link WrittenGenomicRun#signalCodecOverrides}
     *  before any file mutation (Binding Decision §88: only sequences
     *  / qualities accept overrides). Phase A allowed RANS_ORDER0 /
     *  RANS_ORDER1 / BASE_PACK on either byte channel. Phase D
     *  (Binding Decision §108) adds QUALITY_BINNED but restricts it to
     *  the {@code qualities} channel only — applying it to ACGT bytes
     *  would silently destroy the sequence via Phred-bin quantisation.
     *  Validation throws {@link IllegalArgumentException} so the caller
     *  sees the failure immediately and the file is left untouched.</p> */
    private static void writeGenomicRunSubtree(
            global.thalion.ttio.providers.StorageGroup parent,
            String name,
            WrittenGenomicRun run) {
        // M86 Phase D/E/B: per-channel allowed-codec map (Gotcha §119).
        // Sequences accepts RANS+BASE_PACK; qualities additionally
        // accepts QUALITY_BINNED. Phase E adds read_names which only
        // accepts NAME_TOKENIZED (Binding Decision §113). Phase B adds
        // positions/flags/mapping_qualities which accept ONLY the rANS
        // codecs (Binding Decision §117 — BASE_PACK / QUALITY_BINNED /
        // NAME_TOKENIZED would silently corrupt the integer values).
        // Runs BEFORE any group/dataset is created so the file is
        // untouched on a bad override (Gotcha §96 — no half-written run).
        java.util.Map<String, java.util.Set<Enums.Compression>>
            allowedCodecsByChannel = java.util.Map.of(
                "sequences", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1,
                    Enums.Compression.BASE_PACK),
                "qualities", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1,
                    Enums.Compression.BASE_PACK,
                    Enums.Compression.QUALITY_BINNED),
                "read_names", java.util.Set.of(
                    Enums.Compression.NAME_TOKENIZED),
                "cigars", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1,
                    Enums.Compression.NAME_TOKENIZED),
                "positions", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1),
                "flags", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1),
                "mapping_qualities", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1),
                // M86 Phase F: per-field decomposition of the M82
                // mate_info compound dataset. The bare key "mate_info"
                // is reserved and rejected (Binding Decision §126);
                // callers must use the three per-field virtual channel
                // names. The chrom field accepts the same codec set as
                // cigars (Binding Decision §130). The pos and tlen
                // fields are integer channels and accept the same
                // codec set as positions/flags (§117 generalised).
                "mate_info_chrom", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1,
                    Enums.Compression.NAME_TOKENIZED),
                "mate_info_pos", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1),
                "mate_info_tlen", java.util.Set.of(
                    Enums.Compression.RANS_ORDER0,
                    Enums.Compression.RANS_ORDER1));
        java.util.Set<String> integerChannelNames = java.util.Set.of(
            "positions", "flags", "mapping_qualities",
            "mate_info_pos", "mate_info_tlen");
        for (var entry : run.signalCodecOverrides().entrySet()) {
            String chName = entry.getKey();
            Enums.Compression codec = entry.getValue();
            // M86 Phase F Binding Decision §126 / Gotcha §143: the
            // bare "mate_info" key is reserved and rejected with a
            // message pointing at the three per-field virtual channel
            // names. Without this explicit reject, the bare key would
            // fall through to the generic "channel not supported"
            // branch and the caller would not learn about the per-
            // field surface.
            if ("mate_info".equals(chName)) {
                throw new IllegalArgumentException(
                    "signalCodecOverrides['mate_info']: the bare "
                    + "'mate_info' key is reserved and rejected — "
                    + "mate_info is decomposed at the per-field level "
                    + "in M86 Phase F. Use one or more of the three "
                    + "per-field virtual channel names instead: "
                    + "'mate_info_chrom', 'mate_info_pos', "
                    + "'mate_info_tlen'. See docs/format-spec.md §10.9.");
            }
            if (!allowedCodecsByChannel.containsKey(chName)) {
                throw new IllegalArgumentException(
                    "signalCodecOverrides: channel '" + chName
                    + "' not supported (only sequences, qualities, "
                    + "read_names, cigars, positions, flags, "
                    + "mapping_qualities, mate_info_chrom, "
                    + "mate_info_pos, and mate_info_tlen can use "
                    + "TTIO codecs)");
            }
            java.util.Set<Enums.Compression> allowed =
                allowedCodecsByChannel.get(chName);
            if (codec == null || !allowed.contains(codec)) {
                // Phase D Binding Decision §110: explicit message for
                // the (sequences, QUALITY_BINNED) category error —
                // names the codec, the channel, and the
                // lossy-quantisation rationale.
                if (codec == Enums.Compression.QUALITY_BINNED
                        && "sequences".equals(chName)) {
                    throw new IllegalArgumentException(
                        "signalCodecOverrides['" + chName + "']: codec "
                        + "QUALITY_BINNED is not valid on the '"
                        + chName + "' channel — quality binning is "
                        + "lossy and only applies to Phred quality "
                        + "scores. Applying it to ACGT sequence bytes "
                        + "would silently destroy the sequence via "
                        + "Phred-bin quantisation. Use the 'qualities' "
                        + "channel for QUALITY_BINNED, or RANS_ORDER0/"
                        + "RANS_ORDER1/BASE_PACK on sequences.");
                }
                // Phase E Binding Decision §113: explicit message for
                // (sequences|qualities, NAME_TOKENIZED) — names the
                // codec, the channel, and the wrong-input-type
                // rationale (codec tokenises UTF-8 strings, not
                // binary byte streams).
                if (codec == Enums.Compression.NAME_TOKENIZED
                        && ("sequences".equals(chName)
                            || "qualities".equals(chName))) {
                    throw new IllegalArgumentException(
                        "signalCodecOverrides['" + chName + "']: codec "
                        + "NAME_TOKENIZED is not valid on the '"
                        + chName + "' channel — NAME_TOKENIZED "
                        + "tokenises UTF-8 read name strings (digit "
                        + "runs vs string runs), not binary byte "
                        + "streams like ACGT sequence bytes or Phred "
                        + "quality scores. Applying it to '" + chName
                        + "' would mis-tokenise the data and fall "
                        + "back to verbatim, producing nonsensical "
                        + "compression. Use the 'read_names' channel "
                        + "for NAME_TOKENIZED, or RANS_ORDER0/"
                        + "RANS_ORDER1/BASE_PACK on '" + chName + "'.");
                }
                // Phase B Binding Decision §117: explicit messages for
                // wrong-content codecs on integer channels. Each names
                // the codec, the channel, and explains why the codec
                // does not preserve integer values.
                if (integerChannelNames.contains(chName)) {
                    if (codec == Enums.Compression.BASE_PACK) {
                        throw new IllegalArgumentException(
                            "signalCodecOverrides['" + chName + "']: codec "
                            + "BASE_PACK is not valid on the '"
                            + chName + "' channel — BASE_PACK 2-bit-packs "
                            + "ACGT sequence bytes and would silently "
                            + "corrupt the integer values stored on this "
                            + "channel. Use RANS_ORDER0 or RANS_ORDER1 on '"
                            + chName + "'.");
                    }
                    if (codec == Enums.Compression.QUALITY_BINNED) {
                        throw new IllegalArgumentException(
                            "signalCodecOverrides['" + chName + "']: codec "
                            + "QUALITY_BINNED is not valid on the '"
                            + chName + "' channel — QUALITY_BINNED "
                            + "quantises Phred quality scores onto an "
                            + "8-bin centre table and would silently "
                            + "destroy the integer values stored on this "
                            + "channel. Use RANS_ORDER0 or RANS_ORDER1 on '"
                            + chName + "'.");
                    }
                    if (codec == Enums.Compression.NAME_TOKENIZED) {
                        throw new IllegalArgumentException(
                            "signalCodecOverrides['" + chName + "']: codec "
                            + "NAME_TOKENIZED is not valid on the '"
                            + chName + "' channel — NAME_TOKENIZED "
                            + "tokenises UTF-8 read-name strings and "
                            + "would mis-tokenise the integer values "
                            + "stored on this channel. Use RANS_ORDER0 "
                            + "or RANS_ORDER1 on '" + chName + "'.");
                    }
                }
                // Phase C Binding Decision §120: explicit messages for
                // wrong-content codecs on the cigars channel. CIGAR
                // strings are 7-bit ASCII per the SAM spec; BASE_PACK
                // assumes ACGT bytes and QUALITY_BINNED assumes Phred
                // values, so either would silently corrupt the CIGARs.
                //
                // M86 Phase F Binding Decision §130: mate_info_chrom
                // shares the same codec set as cigars (both are list
                // of structured ASCII strings), so reuse the same
                // wrong-content rejection messages.
                if ("cigars".equals(chName)
                        || "mate_info_chrom".equals(chName)) {
                    if (codec == Enums.Compression.BASE_PACK) {
                        throw new IllegalArgumentException(
                            "signalCodecOverrides['" + chName + "']: codec "
                            + "BASE_PACK is not valid on the '"
                            + chName + "' channel — BASE_PACK 2-bit-packs "
                            + "ACGT sequence bytes and would silently "
                            + "corrupt the structured ASCII strings stored "
                            + "on this channel. Use RANS_ORDER0, "
                            + "RANS_ORDER1, or NAME_TOKENIZED on '"
                            + chName + "'.");
                    }
                    if (codec == Enums.Compression.QUALITY_BINNED) {
                        throw new IllegalArgumentException(
                            "signalCodecOverrides['" + chName + "']: codec "
                            + "QUALITY_BINNED is not valid on the '"
                            + chName + "' channel — QUALITY_BINNED "
                            + "quantises Phred quality scores onto an "
                            + "8-bin centre table and would silently "
                            + "destroy the structured ASCII strings stored "
                            + "on this channel. Use RANS_ORDER0, "
                            + "RANS_ORDER1, or NAME_TOKENIZED on '"
                            + chName + "'.");
                    }
                }
                throw new IllegalArgumentException(
                    "signalCodecOverrides['" + chName + "']: codec "
                    + codec + " not supported on the '" + chName
                    + "' channel (allowed: " + allowed + ")");
            }
        }
        try (var rg = parent.createGroup(name)) {
            // Run-level attributes.
            rg.setAttribute("acquisition_mode",
                (long) run.acquisitionMode().ordinal());
            rg.setAttribute("modality", "genomic_sequencing");
            rg.setAttribute("spectrum_class", 5L);
            rg.setAttribute("reference_uri", run.referenceUri());
            rg.setAttribute("platform", run.platform());
            rg.setAttribute("sample_name", run.sampleName());
            rg.setAttribute("read_count", (long) run.readCount());

            // genomic_index (delegates to GenomicIndex.writeTo).
            GenomicIndex idx = new GenomicIndex(
                run.offsets(), run.lengths(), run.chromosomes(),
                run.positions(), run.mappingQualities(), run.flags());
            try (var ig = rg.createGroup("genomic_index")) {
                idx.writeTo(ig);
            }

            // signal_channels: 5 typed channels + 3 compound datasets.
            try (var sc = rg.createGroup("signal_channels")) {
                // M86 Phase B: integer channels dispatch through
                // writeIntChannelWithCodec; when the per-channel
                // override is rANS the channel is serialised to
                // little-endian bytes and written as flat uint8 with
                // @compression. When the override is absent the helper
                // delegates to the existing typed writer so byte parity
                // with M82/Phase A/D/E files is preserved.
                writeIntChannelWithCodec(sc, "positions",
                    run.positions(), run.signalCompression(),
                    run.signalCodecOverrides().get("positions"));
                // M86: sequences/qualities go through the codec
                // dispatch helper; absent from the override map →
                // existing HDF5-filter path with @compression unset.
                writeByteChannelWithCodec(sc, "sequences",
                    run.sequences(), run.signalCompression(),
                    run.signalCodecOverrides().get("sequences"));
                writeByteChannelWithCodec(sc, "qualities",
                    run.qualities(), run.signalCompression(),
                    run.signalCodecOverrides().get("qualities"));
                writeIntChannelWithCodec(sc, "flags",
                    run.flags(), run.signalCompression(),
                    run.signalCodecOverrides().get("flags"));
                writeIntChannelWithCodec(sc, "mapping_qualities",
                    run.mappingQualities(), run.signalCompression(),
                    run.signalCodecOverrides().get("mapping_qualities"));

                // Compound datasets: cigars + read_names (single
                // VL_STRING). M82.4: Java now reads VL_STRING in
                // compounds correctly via Unsafe-based char* deref;
                // wire format matches Python and ObjC.
                List<global.thalion.ttio.providers.CompoundField> vlField = List.of(
                    new global.thalion.ttio.providers.CompoundField("value",
                        global.thalion.ttio.providers.CompoundField.Kind.VL_STRING));
                // M86 Phase C: schema lift for cigars. When an override
                // is present, replace the M82 compound dataset with a
                // flat 1-D uint8 dataset of the same name carrying the
                // codec output, plus an @compression attribute (Binding
                // Decisions §120-§122). Three codec ids are supported:
                //   * RANS_ORDER0 / RANS_ORDER1: serialise the CIGAR
                //     list[String] via length-prefix-concat
                //     (varint(asciiLen) + asciiBytes per CIGAR — §2.5
                //     of the Phase C plan), then encode through M83
                //     rANS. Per Gotcha §139 this is NOT NAME_TOKENIZED's
                //     verbatim format then rANS-encoded.
                //   * NAME_TOKENIZED: pass the list[String] directly
                //     to NameTokenizer.encode (the codec already
                //     handles list[str] input).
                // The two layouts are mutually exclusive within a
                // single run; readers dispatch on dataset shape and the
                // @compression attribute. No HDF5 filter is applied —
                // codec output is high-entropy (Binding Decision §87).
                if (run.signalCodecOverrides().containsKey("cigars")) {
                    Enums.Compression cigarsCodec =
                        run.signalCodecOverrides().get("cigars");
                    byte[] encoded = encodeCigars(run.cigars(), cigarsCodec);
                    global.thalion.ttio.providers.StorageDataset cgDs;
                    try {
                        cgDs = sc.createDataset("cigars",
                            Enums.Precision.UINT8, encoded.length,
                            65536, Enums.Compression.NONE, 0);
                    } catch (UnsupportedOperationException e) {
                        cgDs = sc.createDataset("cigars",
                            Enums.Precision.UINT8, encoded.length,
                            0, Enums.Compression.NONE, 0);
                    }
                    try (var closeMe = cgDs) {
                        closeMe.writeAll(encoded);
                        closeMe.setAttribute("compression",
                            codecIdFor(cigarsCodec));
                    }
                } else {
                    writeCompoundOneCol(sc, "cigars", vlField, run.cigars());
                }
                // M86 Phase E: schema lift for read_names. When the
                // NAME_TOKENIZED override is set, replace the M82
                // compound dataset with a flat 1-D uint8 dataset of
                // the same name carrying the codec output, plus an
                // @compression == 8 attribute (Binding Decisions
                // §111, §113). The two layouts are mutually exclusive
                // within a single run; readers dispatch on dataset
                // shape (compound vs uint8). No HDF5 filter is applied
                // — codec output is high-entropy (Binding Decision §87).
                if (run.signalCodecOverrides().containsKey("read_names")) {
                    byte[] encoded =
                        global.thalion.ttio.codecs.NameTokenizer
                            .encode(run.readNames());
                    global.thalion.ttio.providers.StorageDataset rnDs;
                    try {
                        rnDs = sc.createDataset("read_names",
                            Enums.Precision.UINT8, encoded.length,
                            65536, Enums.Compression.NONE, 0);
                    } catch (UnsupportedOperationException e) {
                        rnDs = sc.createDataset("read_names",
                            Enums.Precision.UINT8, encoded.length,
                            0, Enums.Compression.NONE, 0);
                    }
                    try (var closeMe = rnDs) {
                        closeMe.writeAll(encoded);
                        closeMe.setAttribute("compression",
                            codecIdFor(Enums.Compression.NAME_TOKENIZED));
                    }
                } else {
                    writeCompoundOneCol(sc, "read_names", vlField,
                        run.readNames());
                }

                // M86 Phase F: schema lift for mate_info. When ANY of
                // the three per-field overrides (mate_info_chrom /
                // mate_info_pos / mate_info_tlen) is in
                // signalCodecOverrides, the writer creates a subgroup
                // signal_channels/mate_info/ containing three child
                // datasets (chrom, pos, tlen) and dispatches each
                // child independently — codec-compressed if the per-
                // field override is set, natural-dtype HDF5 ZLIB if
                // not (Binding Decisions §125, §127). Partial
                // overrides allowed (Gotcha §142). When NO mate_info_*
                // override is set, the existing M82 compound write
                // path is used unchanged for byte parity with pre-
                // Phase-F files.
                java.util.Map<String, Enums.Compression> mateOverrides =
                    new java.util.LinkedHashMap<>();
                for (String k : new String[]{"mate_info_chrom",
                        "mate_info_pos", "mate_info_tlen"}) {
                    if (run.signalCodecOverrides().containsKey(k)) {
                        mateOverrides.put(k,
                            run.signalCodecOverrides().get(k));
                    }
                }
                if (!mateOverrides.isEmpty()) {
                    writeMateInfoSubgroup(sc, run, mateOverrides);
                } else {
                    // mate_info: chrom (VL_STRING) + pos (int64) + tlen (int64).
                    List<global.thalion.ttio.providers.CompoundField> mateFields = List.of(
                        new global.thalion.ttio.providers.CompoundField("chrom",
                            global.thalion.ttio.providers.CompoundField.Kind.VL_STRING),
                        new global.thalion.ttio.providers.CompoundField("pos",
                            global.thalion.ttio.providers.CompoundField.Kind.INT64),
                        new global.thalion.ttio.providers.CompoundField("tlen",
                            global.thalion.ttio.providers.CompoundField.Kind.INT64));
                    List<Object[]> mateRows = new ArrayList<>(run.readCount());
                    for (int i = 0; i < run.readCount(); i++) {
                        mateRows.add(new Object[]{
                            run.mateChromosomes().get(i),
                            run.matePositions()[i],
                            (long) run.templateLengths()[i],
                        });
                    }
                    try (var ds = sc.createCompoundDataset("mate_info", mateFields,
                                                             mateRows.size())) {
                        ds.writeAll(mateRows);
                    }
                }
            }

            // Phase 2 (post-M91): per-run provenance, mirroring
            // AcquisitionRun.writeProvenance. On the HDF5 fast path
            // we write the canonical compound ``provenance/steps``
            // (the same layout Python writes). The JSON attribute is
            // also emitted so non-HDF5 providers
            // (memory/sqlite/zarr) and legacy Java readers still see
            // the chain.
            if (!run.provenanceRecords().isEmpty()) {
                try (var prov = rg.createGroup("provenance")) {
                    Hdf5Group h5 = global.thalion.ttio.providers.Hdf5Provider
                        .tryUnwrapHdf5Group(prov);
                    if (h5 != null) {
                        List<ProvenanceRecord> recs = run.provenanceRecords();
                        Hdf5CompoundIO.writeCompoundDataset(h5, "steps",
                            Hdf5CompoundIO.provenanceSchema(),
                            recs.size(),
                            (row, pool) -> {
                                ProvenanceRecord r = recs.get(row);
                                return new Object[]{
                                    r.timestampUnix(),
                                    pool.addString(r.software()),
                                    pool.addString(r.parametersJson()),
                                    pool.addString(r.inputRefsJson()),
                                    pool.addString(r.outputRefsJson())
                                };
                            });
                    }
                }
                rg.setAttribute("provenance_json",
                    buildProvenanceJsonArray(run.provenanceRecords()));
            }
        }
    }

    /** Phase 1: build the JSON array attribute carrying per-run
     *  provenance for a genomic run. Same shape as
     *  {@link global.thalion.ttio.AcquisitionRun#writeProvenance}. */
    private static String buildProvenanceJsonArray(
            List<ProvenanceRecord> records) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < records.size(); i++) {
            if (i > 0) json.append(",");
            ProvenanceRecord r = records.get(i);
            json.append("{\"timestamp_unix\":").append(r.timestampUnix())
                .append(",\"software\":\"").append(
                    r.software().replace("\"", "\\\""))
                .append("\"")
                .append(",\"parameters\":").append(r.parametersJson())
                .append(",\"input_refs\":").append(r.inputRefsJson())
                .append(",\"output_refs\":").append(r.outputRefsJson())
                .append("}");
        }
        return json.append("]").toString();
    }

    /** M86 Phase F: write the mate_info subgroup with per-field codec
     *  dispatch. Triggered when any of the three per-field override
     *  keys is in {@code run.signalCodecOverrides}. Creates a subgroup
     *  {@code signal_channels/mate_info/} containing three child
     *  datasets (chrom, pos, tlen). Each field is independently codec-
     *  compressible: fields with an override are written as flat 1-D
     *  uint8 with the codec output and {@code @compression} attribute
     *  (no HDF5 filter — Binding Decision §87); fields without an
     *  override use their natural dtype with HDF5 ZLIB filter inside
     *  the subgroup (Binding Decision §127, partial overrides allowed).
     *
     *  <p>The chrom field's serialisation matches Phase C cigars:
     *  NAME_TOKENIZED takes the {@code List<String>} directly; rANS
     *  uses length-prefix-concat ({@code varint(len) + ASCII bytes}
     *  per chrom).
     *
     *  <p>The pos and tlen fields' serialisation matches Phase B
     *  integer channels: rANS over the LE byte representation of the
     *  typed array ({@code <i8} for pos, {@code <i4} for tlen). */
    private static void writeMateInfoSubgroup(
            global.thalion.ttio.providers.StorageGroup sc,
            WrittenGenomicRun run,
            java.util.Map<String, Enums.Compression> overrides) {
        try (var mateGroup = sc.createGroup("mate_info")) {
            // ---- chrom field ------------------------------------
            List<String> chroms = run.mateChromosomes();
            Enums.Compression chromCodec = overrides.get("mate_info_chrom");
            if (chromCodec == null) {
                // Natural dtype (VL_STRING-in-compound) inside the
                // subgroup. Mirrors the cigars/read_names compound
                // writer used elsewhere in this class.
                List<global.thalion.ttio.providers.CompoundField> vlField = List.of(
                    new global.thalion.ttio.providers.CompoundField("value",
                        global.thalion.ttio.providers.CompoundField.Kind.VL_STRING));
                writeCompoundOneCol(mateGroup, "chrom", vlField, chroms);
            } else {
                byte[] encoded;
                if (chromCodec == Enums.Compression.NAME_TOKENIZED) {
                    encoded = global.thalion.ttio.codecs.NameTokenizer
                        .encode(chroms);
                } else if (chromCodec == Enums.Compression.RANS_ORDER0
                        || chromCodec == Enums.Compression.RANS_ORDER1) {
                    java.io.ByteArrayOutputStream buf =
                        new java.io.ByteArrayOutputStream();
                    for (int idx = 0; idx < chroms.size(); idx++) {
                        String c = chroms.get(idx);
                        if (c == null) {
                            throw new IllegalArgumentException(
                                "signalCodecOverrides['mate_info_chrom']: "
                                + "chrom at index " + idx + " is null");
                        }
                        for (int j = 0; j < c.length(); j++) {
                            if (c.charAt(j) > 0x7F) {
                                throw new IllegalArgumentException(
                                    "signalCodecOverrides['mate_info_chrom']: "
                                    + "chrom at index " + idx + " contains "
                                    + "non-ASCII bytes");
                            }
                        }
                        byte[] payload = c.getBytes(
                            java.nio.charset.StandardCharsets.US_ASCII);
                        writeUnsignedVarint(buf, payload.length);
                        buf.write(payload, 0, payload.length);
                    }
                    int order = (chromCodec == Enums.Compression.RANS_ORDER0)
                        ? 0 : 1;
                    encoded = global.thalion.ttio.codecs.Rans
                        .encode(buf.toByteArray(), order);
                } else {
                    // Defensive — caller-side validation rejects this.
                    throw new IllegalArgumentException(
                        "writeMateInfoSubgroup: unsupported chrom codec "
                        + chromCodec);
                }
                global.thalion.ttio.providers.StorageDataset chDs;
                try {
                    chDs = mateGroup.createDataset("chrom",
                        Enums.Precision.UINT8, encoded.length,
                        65536, Enums.Compression.NONE, 0);
                } catch (UnsupportedOperationException e) {
                    chDs = mateGroup.createDataset("chrom",
                        Enums.Precision.UINT8, encoded.length,
                        0, Enums.Compression.NONE, 0);
                }
                try (var closeMe = chDs) {
                    closeMe.writeAll(encoded);
                    closeMe.setAttribute("compression",
                        codecIdFor(chromCodec));
                }
            }

            // ---- pos field --------------------------------------
            writeMateIntField(mateGroup, "pos",
                run.matePositions(), Enums.Precision.INT64,
                overrides.get("mate_info_pos"));

            // ---- tlen field -------------------------------------
            writeMateIntField(mateGroup, "tlen",
                run.templateLengths(), Enums.Precision.INT32,
                overrides.get("mate_info_tlen"));
        }
    }

    /** M86 Phase F helper: write one of the integer mate fields (pos
     *  or tlen) with optional codec dispatch. Mirrors the Phase B
     *  integer-channel write contract: when {@code codec} is null the
     *  array is written at its natural integer precision with HDF5
     *  ZLIB. When {@code codec} is RANS_ORDER0 or RANS_ORDER1, the LE
     *  byte representation of the array is encoded through M83 rANS
     *  and written as a flat unfiltered uint8 dataset with
     *  {@code @compression} carrying the codec id. */
    private static void writeMateIntField(
            global.thalion.ttio.providers.StorageGroup mateGroup,
            String name, Object data,
            Enums.Precision naturalPrecision,
            Enums.Compression codec) {
        if (codec == null) {
            // Natural-dtype write with HDF5 ZLIB filter inside the
            // subgroup. Goes through the typed writer.
            int len;
            if (data instanceof long[] a)      len = a.length;
            else if (data instanceof int[] a)  len = a.length;
            else throw new IllegalArgumentException(
                "writeMateIntField: unsupported data type "
                + data.getClass().getName());
            global.thalion.ttio.providers.StorageDataset ds;
            try {
                ds = mateGroup.createDataset(name, naturalPrecision,
                    len, 65536, Enums.Compression.ZLIB, 6);
            } catch (UnsupportedOperationException e) {
                ds = mateGroup.createDataset(name, naturalPrecision,
                    len, 0, Enums.Compression.NONE, 0);
            }
            try (var closeMe = ds) { closeMe.writeAll(data); }
            return;
        }
        if (codec != Enums.Compression.RANS_ORDER0
                && codec != Enums.Compression.RANS_ORDER1) {
            // Defensive — caller-side validation rejects this first.
            throw new IllegalArgumentException(
                "writeMateIntField: unsupported codec " + codec
                + " on integer mate field '" + name + "'");
        }
        // Serialise array → little-endian byte buffer (mirrors §118).
        byte[] leBytes;
        if (naturalPrecision == Enums.Precision.INT64) {
            long[] arr = (long[]) data;
            java.nio.ByteBuffer bb = java.nio.ByteBuffer
                .allocate(arr.length * 8)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN);
            for (long v : arr) bb.putLong(v);
            leBytes = bb.array();
        } else if (naturalPrecision == Enums.Precision.INT32) {
            int[] arr = (int[]) data;
            java.nio.ByteBuffer bb = java.nio.ByteBuffer
                .allocate(arr.length * 4)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN);
            for (int v : arr) bb.putInt(v);
            leBytes = bb.array();
        } else {
            throw new IllegalArgumentException(
                "writeMateIntField: unsupported precision "
                + naturalPrecision);
        }
        int order = (codec == Enums.Compression.RANS_ORDER0) ? 0 : 1;
        byte[] encoded = global.thalion.ttio.codecs.Rans
            .encode(leBytes, order);
        global.thalion.ttio.providers.StorageDataset ds;
        try {
            ds = mateGroup.createDataset(name, Enums.Precision.UINT8,
                encoded.length, 65536, Enums.Compression.NONE, 0);
        } catch (UnsupportedOperationException e) {
            ds = mateGroup.createDataset(name, Enums.Precision.UINT8,
                encoded.length, 0, Enums.Compression.NONE, 0);
        }
        try (var closeMe = ds) {
            closeMe.writeAll(encoded);
            closeMe.setAttribute("compression", codecIdFor(codec));
        }
    }

    /** M86: write a uint8 byte channel, optionally through a TTI-O
     *  codec (rANS order-0/1, BASE_PACK, QUALITY_BINNED). When
     *  {@code codecOverride} is {@code null} the channel is written
     *  via the default HDF5-filter path (identical to M82 behaviour,
     *  no {@code @compression} attribute set). When it names a TTI-O
     *  codec, the raw bytes are encoded, written as an unfiltered
     *  uint8 dataset (Binding Decision §87 — no double-compression),
     *  and the codec id is stored on the dataset's
     *  {@code @compression} attribute (uint8).
     *
     *  <p>Phase D: QUALITY_BINNED (M85 Phase A codec id 7) added.
     *  Caller-side validation in {@link #writeGenomicRunSubtree}
     *  guarantees this branch only fires for the {@code qualities}
     *  channel (Binding Decision §108).</p> */
    private static void writeByteChannelWithCodec(
            global.thalion.ttio.providers.StorageGroup sc,
            String name, byte[] data,
            Enums.Compression defaultCodec,
            Enums.Compression codecOverride) {
        if (codecOverride == null) {
            writeSignalChannel(sc, name, Enums.Precision.UINT8, data, defaultCodec);
            return;
        }
        byte[] encoded;
        switch (codecOverride) {
            case RANS_ORDER0 -> encoded =
                global.thalion.ttio.codecs.Rans.encode(data, 0);
            case RANS_ORDER1 -> encoded =
                global.thalion.ttio.codecs.Rans.encode(data, 1);
            case BASE_PACK   -> encoded =
                global.thalion.ttio.codecs.BasePack.encode(data);
            case QUALITY_BINNED -> encoded =
                global.thalion.ttio.codecs.Quality.encode(data);
            default -> throw new IllegalArgumentException(
                "writeByteChannelWithCodec: unsupported codec "
                + codecOverride);
        }
        // Unfiltered uint8 dataset; codec output already entropy-coded.
        // Force a chunked layout (chunkSize > 0) so HDF5 honours our
        // explicit Compression.NONE choice rather than the legacy
        // contiguous fallback.
        global.thalion.ttio.providers.StorageDataset ds;
        try {
            ds = sc.createDataset(name, Enums.Precision.UINT8,
                encoded.length, 65536, Enums.Compression.NONE, 0);
        } catch (UnsupportedOperationException e) {
            ds = sc.createDataset(name, Enums.Precision.UINT8,
                encoded.length, 0, Enums.Compression.NONE, 0);
        }
        try (var closeMe = ds) {
            closeMe.writeAll(encoded);
            // M79 codec id (4 / 5 / 6) as a uint8 attribute on the
            // dataset itself — read path dispatches on this.
            int codecId = codecIdFor(codecOverride);
            closeMe.setAttribute("compression", codecId);
        }
    }

    /** Map a {@link Enums.Compression} enum value to its M79 codec id
     *  (the wire-format integer that travels in the
     *  {@code @compression} attribute). The enum's {@code ordinal()}
     *  already matches the M79 numbering — this helper exists so the
     *  intent is explicit at the call site. */
    private static int codecIdFor(Enums.Compression codec) {
        return codec.ordinal();
    }

    /** M86 Phase C: encode a {@code List<String>} of CIGARs through one
     *  of the three accepted codec paths.
     *
     *  <p>For {@link Enums.Compression#RANS_ORDER0} and
     *  {@link Enums.Compression#RANS_ORDER1} the list is first
     *  serialised via length-prefix-concat ({@code varint(asciiLen) +
     *  asciiBytes} per CIGAR — §2.5 of the Phase C plan), then encoded
     *  through M83 rANS at the matching order. ASCII-only per the SAM
     *  spec; non-ASCII input throws {@link IllegalArgumentException}.
     *
     *  <p>For {@link Enums.Compression#NAME_TOKENIZED} the list is
     *  passed directly to
     *  {@link global.thalion.ttio.codecs.NameTokenizer#encode} which
     *  already handles {@code List<String>} input.
     *
     *  <p>Per Gotcha §139 the rANS path uses raw length-prefix-concat
     *  directly — NOT NAME_TOKENIZED's verbatim format then rANS-
     *  encoded. The two encodings would produce different byte streams
     *  for the same input. */
    private static byte[] encodeCigars(
            List<String> cigars,
            Enums.Compression codec) {
        if (codec == Enums.Compression.NAME_TOKENIZED) {
            return global.thalion.ttio.codecs.NameTokenizer.encode(cigars);
        }
        if (codec != Enums.Compression.RANS_ORDER0
                && codec != Enums.Compression.RANS_ORDER1) {
            // Defensive — caller-side validation rejects this first.
            throw new IllegalArgumentException(
                "encodeCigars: unsupported codec " + codec);
        }
        java.io.ByteArrayOutputStream buf = new java.io.ByteArrayOutputStream();
        for (int idx = 0; idx < cigars.size(); idx++) {
            String cig = cigars.get(idx);
            if (cig == null) {
                throw new IllegalArgumentException(
                    "signalCodecOverrides['cigars']: cigar at index "
                    + idx + " is null");
            }
            for (int j = 0; j < cig.length(); j++) {
                if (cig.charAt(j) > 0x7F) {
                    throw new IllegalArgumentException(
                        "signalCodecOverrides['cigars']: cigar at index "
                        + idx + " contains non-ASCII bytes — CIGARs "
                        + "must be 7-bit ASCII per the SAM spec");
                }
            }
            byte[] payload = cig.getBytes(java.nio.charset.StandardCharsets.US_ASCII);
            writeUnsignedVarint(buf, payload.length);
            buf.write(payload, 0, payload.length);
        }
        int order = (codec == Enums.Compression.RANS_ORDER0) ? 0 : 1;
        return global.thalion.ttio.codecs.Rans.encode(buf.toByteArray(), order);
    }

    /** Unsigned LEB128 varint writer matching the encoding used by the
     *  {@link global.thalion.ttio.codecs.NameTokenizer} verbatim path —
     *  low 7 bits per byte, top bit set on continuation, terminated by
     *  the first byte with the top bit clear. The cigars rANS path
     *  serialises each entry as {@code varint(asciiLen) + asciiBytes}. */
    private static void writeUnsignedVarint(
            java.io.ByteArrayOutputStream out, long n) {
        if (n < 0) {
            throw new IllegalArgumentException(
                "writeUnsignedVarint: negative value " + n);
        }
        while (Long.compareUnsigned(n, 0x80L) >= 0) {
            out.write((int) ((n & 0x7FL) | 0x80L));
            n >>>= 7;
        }
        out.write((int) (n & 0x7FL));
    }

    /** M86 Phase B: write an integer signal channel, optionally through
     *  a TTI-O rANS codec. When {@code codecOverride} is {@code null}
     *  the channel is written via the existing typed writer (identical
     *  to M82 behaviour, no {@code @compression} attribute). When it is
     *  {@link Enums.Compression#RANS_ORDER0} or
     *  {@link Enums.Compression#RANS_ORDER1}, the integer array is
     *  serialised to its little-endian byte representation (Binding
     *  Decision §118), encoded through the M83 rANS codec, and written
     *  as an unfiltered uint8 dataset (Binding Decision §87 — codec
     *  output is high-entropy) with the codec id stored on the
     *  dataset's {@code @compression} attribute (uint8).
     *
     *  <p>The channel-name → dtype mapping (Binding Decision §115)
     *  is fixed: {@code positions → int64}, {@code flags → uint32},
     *  {@code mapping_qualities → uint8}. The reader recovers the
     *  original dtype the same way, so no extra on-disk attribute is
     *  needed.</p>
     *
     *  <p>Caller-side validation in {@link #writeGenomicRunSubtree}
     *  guarantees this branch only fires for the three integer channel
     *  names with a valid rANS codec (Binding Decision §117).</p> */
    private static void writeIntChannelWithCodec(
            global.thalion.ttio.providers.StorageGroup sc,
            String name, Object data,
            Enums.Compression defaultCodec,
            Enums.Compression codecOverride) {
        if (codecOverride == null) {
            // No override: delegate to the typed writer so byte parity
            // with pre-Phase-B files is preserved.
            Enums.Precision p;
            switch (name) {
                case "positions" -> p = Enums.Precision.INT64;
                case "flags"     -> p = Enums.Precision.UINT32;
                case "mapping_qualities" -> p = Enums.Precision.UINT8;
                default -> throw new IllegalArgumentException(
                    "writeIntChannelWithCodec: unknown integer channel '"
                    + name + "'");
            }
            writeSignalChannel(sc, name, p, data, defaultCodec);
            return;
        }
        if (codecOverride != Enums.Compression.RANS_ORDER0
                && codecOverride != Enums.Compression.RANS_ORDER1) {
            // Defensive — the caller-side validation in
            // writeGenomicRunSubtree rejects this combination first
            // with a clearer message.
            throw new IllegalArgumentException(
                "writeIntChannelWithCodec: unsupported codec "
                + codecOverride + " on integer channel '" + name + "'");
        }
        // Serialise array → little-endian byte buffer (Binding
        // Decision §118).
        byte[] leBytes;
        switch (name) {
            case "positions" -> {
                long[] arr = (long[]) data;
                java.nio.ByteBuffer bb = java.nio.ByteBuffer
                    .allocate(arr.length * 8)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN);
                for (long v : arr) bb.putLong(v);
                leBytes = bb.array();
            }
            case "flags" -> {
                int[] arr = (int[]) data;
                java.nio.ByteBuffer bb = java.nio.ByteBuffer
                    .allocate(arr.length * 4)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN);
                for (int v : arr) bb.putInt(v);
                leBytes = bb.array();
            }
            case "mapping_qualities" -> {
                // uint8 → byte buffer is endian-neutral; copy through.
                byte[] arr = (byte[]) data;
                leBytes = arr.clone();
            }
            default -> throw new IllegalArgumentException(
                "writeIntChannelWithCodec: unknown integer channel '"
                + name + "'");
        }
        // Encode through M83 rANS.
        int order = (codecOverride == Enums.Compression.RANS_ORDER0) ? 0 : 1;
        byte[] encoded = global.thalion.ttio.codecs.Rans.encode(leBytes, order);
        // Write as flat unfiltered uint8 dataset.
        global.thalion.ttio.providers.StorageDataset ds;
        try {
            ds = sc.createDataset(name, Enums.Precision.UINT8,
                encoded.length, 65536, Enums.Compression.NONE, 0);
        } catch (UnsupportedOperationException e) {
            ds = sc.createDataset(name, Enums.Precision.UINT8,
                encoded.length, 0, Enums.Compression.NONE, 0);
        }
        try (var closeMe = ds) {
            closeMe.writeAll(encoded);
            closeMe.setAttribute("compression", codecIdFor(codecOverride));
        }
    }

    private static void writeSignalChannel(
            global.thalion.ttio.providers.StorageGroup sc,
            String name, Enums.Precision precision, Object data,
            Enums.Compression codec) {
        int len;
        if (data instanceof long[] a)        len = a.length;
        else if (data instanceof int[] a)    len = a.length;
        else if (data instanceof byte[] a)   len = a.length;
        else throw new IllegalArgumentException(
            "writeSignalChannel: unsupported data type "
            + data.getClass().getName());
        global.thalion.ttio.providers.StorageDataset ds;
        try {
            ds = sc.createDataset(name, precision, len, 65536, codec, 6);
        } catch (UnsupportedOperationException e) {
            ds = sc.createDataset(name, precision, len, 0,
                Enums.Compression.NONE, 0);
        }
        try (var closeMe = ds) { closeMe.writeAll(data); }
    }

    private static void writeCompoundOneCol(
            global.thalion.ttio.providers.StorageGroup sc,
            String name,
            List<global.thalion.ttio.providers.CompoundField> fields,
            List<String> values) {
        List<Object[]> rows = new ArrayList<>(values.size());
        for (String v : values) rows.add(new Object[]{ v });
        try (var ds = sc.createCompoundDataset(name, fields, rows.size())) {
            ds.writeAll(rows);
        }
    }

    /** v0.11 M82.3: same as {@link #writeCompoundOneCol} but encodes
     *  values as UTF-8 byte[] for compound VL_BYTES fields (the
     *  Java-side workaround for the JHI5 VL_STRING-in-compound limit). */
    private static void writeCompoundOneColBytes(
            global.thalion.ttio.providers.StorageGroup sc,
            String name,
            List<global.thalion.ttio.providers.CompoundField> fields,
            List<String> values) {
        List<Object[]> rows = new ArrayList<>(values.size());
        for (String v : values) {
            rows.add(new Object[]{
                v.getBytes(java.nio.charset.StandardCharsets.UTF_8) });
        }
        try (var ds = sc.createCompoundDataset(name, fields, rows.size())) {
            ds.writeAll(rows);
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
        // M82.4: identifications_json mirror retired. Java reads
        // VL_STRING from the compound directly via Unsafe deref now,
        // so the JSON shadow is dead weight on the HDF5 fast path.
    }

    private static List<Identification> readIdentifications(Hdf5Group study) {
        // M82.4: prefer the compound (canonical) — VL_STRING reads
        // work via Unsafe deref now. Fall back to legacy JSON mirror
        // only when the compound is absent (older Java-written files
        // that were JSON-only or unusual layouts).
        if (study.hasChild("identifications")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(
                    study, "identifications", Hdf5CompoundIO.identificationSchema());
            List<Identification> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new Identification(
                        (String) r[0], (Integer) r[1], (String) r[2],
                        (Double) r[3], MiniJson.parseArrayOfStrings((String) r[4])));
            }
            return out;
        }
        if (study.hasAttribute("identifications_json")) {
            return parseIdentificationsJson(study.readStringAttribute("identifications_json"));
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
        // M82.4: quantifications_json mirror retired (see writeIdentifications).
    }

    private static List<Quantification> readQuantifications(Hdf5Group study) {
        // M82.4: compound first (canonical); JSON fallback for legacy.
        if (study.hasChild("quantifications")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(
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
        if (study.hasAttribute("quantifications_json")) {
            return parseQuantificationsJson(study.readStringAttribute("quantifications_json"));
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
        // M82.4: study-level provenance_json mirror retired
        // (see writeIdentifications). The per-run provenance_json
        // attribute on /study/ms_runs/<name>/ is a different layer
        // and is signed by signatures.py — that one stays.
    }

    private static List<ProvenanceRecord> readProvenance(Hdf5Group study) {
        // M82.4: compound first (canonical); JSON fallback for legacy.
        if (study.hasChild("provenance")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(
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
        if (study.hasAttribute("provenance_json")) {
            return parseProvenanceJson(study.readStringAttribute("provenance_json"));
        }
        return List.of();
    }

    // ── StorageGroup-based JSON metadata (v0.9 M64.5) ───────────────

    private static List<Identification> readIdentificationsFromJson(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasAttribute("identifications_json")) return List.of();
        Object v = study.getAttribute("identifications_json");
        return v != null ? parseIdentificationsJson(v.toString()) : List.of();
    }

    private static List<Quantification> readQuantificationsFromJson(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasAttribute("quantifications_json")) return List.of();
        Object v = study.getAttribute("quantifications_json");
        return v != null ? parseQuantificationsJson(v.toString()) : List.of();
    }

    private static List<ProvenanceRecord> readProvenanceFromJson(
            global.thalion.ttio.providers.StorageGroup study) {
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
    public void encryptWithKey(byte[] key, global.thalion.ttio.Enums.EncryptionLevel level)
            throws Exception {
        for (var run : msRuns.values()) run.encryptWithKey(key, level);
        markRootEncrypted();
    }

    /** v1.1 Issue A: write the root {@code @encrypted} attribute so
     *  {@link #isEncrypted} / {@link #encryptedAlgorithm} survive
     *  close/reopen. For HDF5-backed datasets (the only backend with
     *  per-run on-disk encryption today) this opens the file R/W after
     *  each run has finished its own encrypt pass. Callers must treat
     *  the dataset as logically closed after this — matching the
     *  Objective-C contract where {@code closeFile} precedes encrypt. */
    private void markRootEncrypted() {
        String path = file != null ? file.getPath() : null;
        if (path != null) {
            try (global.thalion.ttio.hdf5.Hdf5File f =
                         global.thalion.ttio.hdf5.Hdf5File.open(path);
                 Hdf5Group root = f.rootGroup()) {
                root.setStringAttribute("encrypted", "aes-256-gcm");
            }
        }
        this.encryptedAlgorithm = "aes-256-gcm";
    }

    @Override
    public void decryptWithKey(byte[] key) throws Exception {
        for (var run : msRuns.values()) run.decryptWithKey(key);
    }

    /**
     * v1.1.1: persist-to-disk decrypt. Strips AES-256-GCM encryption
     * from the {@code .tio} file at {@code path}: for every MS run
     * with an encrypted intensity channel, writes plaintext back as
     * {@code intensity_values} and removes the encrypted siblings.
     * Finally clears the root {@code @encrypted} attribute so
     * {@link #isEncrypted} returns {@code false} when the file is
     * reopened.
     *
     * <p>Symmetric with {@link #encryptWithKey(byte[],
     * global.thalion.ttio.Enums.EncryptionLevel)} (which leaves the root
     * attribute set). After this call the file is byte-compatible with
     * the pre-encryption layout.</p>
     *
     * <p>The file must not be held open by another writer.</p>
     *
     * <p><b>Cross-language equivalents:</b> Python
     * {@code SpectralDataset.decrypt_in_place}, Objective-C
     * {@code +[TTIOSpectralDataset decryptInPlaceAtPath:withKey:error:]}.</p>
     */
    public static void decryptInPlace(String path, byte[] key) {
        if (key == null || key.length != 32) {
            throw new IllegalArgumentException("Key must be exactly 32 bytes");
        }
        java.util.List<String> runNames = new java.util.ArrayList<>();
        try (global.thalion.ttio.hdf5.Hdf5File f =
                     global.thalion.ttio.hdf5.Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            if (root.hasChild("study")) {
                try (Hdf5Group study = root.openGroup("study")) {
                    if (study.hasChild("ms_runs")) {
                        try (Hdf5Group msRunsG = study.openGroup("ms_runs")) {
                            runNames.addAll(msRunsG.childNames());
                        }
                    }
                }
            }
        }

        for (String runName : runNames) {
            global.thalion.ttio.protection.EncryptionManager
                    .decryptIntensityChannelInRunInPlace(path, runName, key);
        }

        try (global.thalion.ttio.hdf5.Hdf5File f =
                     global.thalion.ttio.hdf5.Hdf5File.open(path);
             Hdf5Group root = f.rootGroup()) {
            if (root.hasAttribute("encrypted")) {
                root.deleteAttribute("encrypted");
            }
        }
    }

    @Override
    public Object accessPolicy() { return accessPolicy; }

    @Override
    public void setAccessPolicy(Object policy) {
        this.accessPolicy = (global.thalion.ttio.protection.AccessPolicy) policy;
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
