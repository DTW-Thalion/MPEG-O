/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.*;
import com.dtwthalion.mpgo.providers.StorageDataset;
import com.dtwthalion.mpgo.providers.StorageGroup;

import java.util.*;

/**
 * An ordered collection of spectra from one acquisition, with instrument
 * config, spectrum index, and optional chromatograms.
 *
 * <p>HDF5 layout: {@code /study/ms_runs/<name>/} with subgroups
 * {@code spectrum_index/}, {@code signal_channels/}, {@code instrument_config/},
 * {@code chromatograms/} (optional), and {@code provenance/} (optional).</p>
 *
 * <p>Conforms to {@link com.dtwthalion.mpgo.protocols.Indexable},
 * {@link com.dtwthalion.mpgo.protocols.Streamable}, and
 * {@link com.dtwthalion.mpgo.protocols.Provenanceable}.
 * {@code Encryptable} conformance is deferred to M41.5.</p>
 *
 * <p>v0.7 M44: I/O routed through {@link StorageGroup} /
 * {@link StorageDataset}; this class no longer references the low-level
 * {@code Hdf5Group} / {@code Hdf5Dataset} types.</p>
 *
 * <p><b>API status:</b> Stable (Encryptable surface pending).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOAcquisitionRun}, Python
 * {@code mpeg_o.acquisition_run.AcquisitionRun}.</p>
 *
 * @since 0.6
 */
public class AcquisitionRun implements
        com.dtwthalion.mpgo.protocols.Indexable<Spectrum>,
        com.dtwthalion.mpgo.protocols.Streamable<Spectrum>,
        com.dtwthalion.mpgo.protocols.Provenanceable,
        com.dtwthalion.mpgo.protocols.Encryptable,
        AutoCloseable {

    private static final int CHUNK_SIZE = 65536;
    private static final int COMPRESSION_LEVEL = 6;

    private final String name;
    private final AcquisitionMode acquisitionMode;
    private final SpectrumIndex spectrumIndex;
    private final InstrumentConfig instrumentConfig;
    private final List<Chromatogram> chromatograms;
    private final List<ProvenanceRecord> provenanceRecords;

    // NMR-specific
    private final String nucleusType;
    private final double spectrometerFrequencyMHz;

    // Channel data (concatenated across all spectra)
    private final Map<String, double[]> channels;

    // M41.3: Streamable cursor and Provenanceable cache.
    private int cursor = 0;
    private java.util.List<ProvenanceRecord> provenanceCache;
    // M41.5: Encryptable conformance.
    private com.dtwthalion.mpgo.protection.AccessPolicy accessPolicy;
    private String persistenceFilePath;
    private String persistenceRunName;

    public AcquisitionRun(String name, AcquisitionMode acquisitionMode,
                          SpectrumIndex spectrumIndex,
                          InstrumentConfig instrumentConfig,
                          Map<String, double[]> channels,
                          List<Chromatogram> chromatograms,
                          List<ProvenanceRecord> provenanceRecords,
                          String nucleusType, double spectrometerFrequencyMHz) {
        this.name = name;
        this.acquisitionMode = acquisitionMode;
        this.spectrumIndex = spectrumIndex;
        this.instrumentConfig = instrumentConfig;
        this.channels = channels != null ? Map.copyOf(channels) : Map.of();
        this.chromatograms = chromatograms != null ? List.copyOf(chromatograms) : List.of();
        this.provenanceRecords = provenanceRecords != null ? List.copyOf(provenanceRecords) : List.of();
        this.nucleusType = nucleusType;
        this.spectrometerFrequencyMHz = spectrometerFrequencyMHz;
    }

    public String name() { return name; }
    public AcquisitionMode acquisitionMode() { return acquisitionMode; }
    public SpectrumIndex spectrumIndex() { return spectrumIndex; }
    public InstrumentConfig instrumentConfig() { return instrumentConfig; }
    public Map<String, double[]> channels() { return channels; }
    public List<Chromatogram> chromatograms() { return chromatograms; }
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }
    public String nucleusType() { return nucleusType; }
    public double spectrometerFrequencyMHz() { return spectrometerFrequencyMHz; }

    public int spectrumCount() { return spectrumIndex.count(); }

    /** Read a single spectrum's channel data by index (hyperslab). */
    public double[] channelSlice(String channelName, int spectrumIdx) {
        double[] data = channels.get(channelName);
        if (data == null) return null;
        long offset = spectrumIndex.offsetAt(spectrumIdx);
        int length = spectrumIndex.lengthAt(spectrumIdx);
        return Arrays.copyOfRange(data, (int) offset, (int) offset + length);
    }

    /** Get the spectrum class name for HDF5 @spectrum_class attribute. */
    public String spectrumClassName() {
        return switch (acquisitionMode) {
            case NMR_1D -> "MPGONMRSpectrum";
            case NMR_2D -> "MPGONMR2DSpectrum";
            default -> "MPGOMassSpectrum";
        };
    }

    // ── Protocol conformances ────────────────────────────────────────

    // ---- Indexable conformance ----

    @Override
    public Spectrum objectAtIndex(int index) {
        long offset = spectrumIndex.offsetAt(index);
        int length = spectrumIndex.lengthAt(index);

        double[] mz = channels.getOrDefault("mz", new double[0]);
        double[] intensity = channels.getOrDefault("intensity", new double[0]);
        double[] chemShift = channels.getOrDefault("chemical_shift", new double[0]);

        double scanTime = spectrumIndex.retentionTimeAt(index);
        double precursorMz = spectrumIndex.precursorMzAt(index);
        int precursorCharge = spectrumIndex.precursorChargeAt(index);

        if (chemShift.length > 0) {
            double[] cs = java.util.Arrays.copyOfRange(chemShift, (int) offset, (int) offset + length);
            double[] it = java.util.Arrays.copyOfRange(intensity, (int) offset, (int) offset + length);
            return new NMRSpectrum(cs, it, index, scanTime,
                nucleusType != null ? nucleusType : "",
                spectrometerFrequencyMHz);
        }

        double[] mzSlice = java.util.Arrays.copyOfRange(mz, (int) offset, (int) offset + length);
        double[] intSlice = java.util.Arrays.copyOfRange(intensity, (int) offset, (int) offset + length);
        return new MassSpectrum(mzSlice, intSlice, index, scanTime,
            precursorMz, precursorCharge,
            spectrumIndex.msLevelAt(index),
            spectrumIndex.polarityAt(index),
            null);
    }

    @Override
    public int count() { return spectrumIndex.count(); }

    // ---- Streamable conformance ----

    @Override
    public Spectrum nextObject() {
        if (cursor >= count()) throw new java.util.NoSuchElementException();
        Spectrum s = objectAtIndex(cursor);
        cursor++;
        return s;
    }

    @Override
    public boolean hasMore() { return cursor < count(); }

    @Override
    public int currentPosition() { return cursor; }

    @Override
    public boolean seekToPosition(int position) {
        if (position < 0 || position > count()) return false;
        cursor = position;
        return true;
    }

    @Override
    public void reset() { cursor = 0; }

    // ---- Provenanceable conformance ----

    @Override
    public void addProcessingStep(ProvenanceRecord step) {
        ensureProvenanceCache().add(step);
    }

    @Override
    public java.util.List<ProvenanceRecord> provenanceChain() {
        if (provenanceCache != null) return java.util.List.copyOf(provenanceCache);
        return provenanceRecords;
    }

    @Override
    public java.util.List<String> inputEntities() {
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        for (ProvenanceRecord r : provenanceChain()) seen.addAll(r.inputRefs());
        return new java.util.ArrayList<>(seen);
    }

    @Override
    public java.util.List<String> outputEntities() {
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        for (ProvenanceRecord r : provenanceChain()) seen.addAll(r.outputRefs());
        return new java.util.ArrayList<>(seen);
    }

    private java.util.List<ProvenanceRecord> ensureProvenanceCache() {
        if (provenanceCache == null) {
            provenanceCache = new java.util.ArrayList<>(provenanceRecords);
        }
        return provenanceCache;
    }

    // ---- Encryptable conformance ----

    /**
     * Attach the persistence context after loading — used by
     * {@link SpectralDataset} so {@link #encryptWithKey} can delegate.
     */
    public void setPersistenceContext(String filePath, String runName) {
        this.persistenceFilePath = filePath;
        this.persistenceRunName = runName;
    }

    @Override
    public void encryptWithKey(byte[] key, com.dtwthalion.mpgo.Enums.EncryptionLevel level)
            throws Exception {
        if (persistenceFilePath == null || persistenceRunName == null) {
            throw new IllegalStateException(
                "AcquisitionRun.encryptWithKey requires a persistence " +
                "context; call via a run obtained from SpectralDataset.open");
        }
        com.dtwthalion.mpgo.protection.EncryptionManager
            .encryptIntensityChannelInRun(persistenceFilePath, persistenceRunName, key);
    }

    @Override
    public void decryptWithKey(byte[] key) throws Exception {
        // The protocol declares void return; plaintext is not returned to the
        // caller because decrypt is read-only (file is not rewritten).
        // If caller wants plaintext bytes, use
        // EncryptionManager.decryptIntensityChannelInRun directly.
        if (persistenceFilePath == null || persistenceRunName == null) {
            throw new IllegalStateException(
                "AcquisitionRun.decryptWithKey requires a persistence context");
        }
        // Verify we can decrypt (auth-tag check) without returning data.
        com.dtwthalion.mpgo.protection.EncryptionManager
            .decryptIntensityChannelInRun(persistenceFilePath, persistenceRunName, key);
    }

    @Override
    public Object accessPolicy() { return accessPolicy; }

    @Override
    public void setAccessPolicy(Object policy) {
        this.accessPolicy = (com.dtwthalion.mpgo.protection.AccessPolicy) policy;
    }

    // ── Storage I/O ─────────────────────────────────────────────────
    //
    // v0.7 M44: everything below is routed through the StorageGroup /
    // StorageDataset protocols. HDF5, SQLite, and Memory providers all
    // satisfy the same contract.

    /** Write this run to a parent group (creates <name>/ subgroup). */
    public void writeTo(StorageGroup parentGroup) {
        try (StorageGroup runGroup = parentGroup.createGroup(name)) {
            runGroup.setAttribute("acquisition_mode", (long) acquisitionMode.ordinal());
            runGroup.setAttribute("spectrum_count", (long) spectrumIndex.count());
            runGroup.setAttribute("spectrum_class", spectrumClassName());

            if (nucleusType != null) {
                runGroup.setAttribute("nucleus_type", nucleusType);
            }
            if (spectrometerFrequencyMHz > 0) {
                try (StorageDataset ds = runGroup.createDataset(
                        "_spectrometer_freq_mhz", Precision.FLOAT64, 1, 0,
                        Compression.NONE, 0)) {
                    ds.writeAll(new double[]{ spectrometerFrequencyMHz });
                }
            }

            // Spectrum index
            spectrumIndex.writeTo(runGroup);

            // Signal channels
            writeSignalChannels(runGroup);

            // Instrument config
            if (instrumentConfig != null) {
                writeInstrumentConfig(runGroup);
            }

            // Chromatograms
            if (!chromatograms.isEmpty()) {
                writeChromatograms(runGroup);
            }

            // Per-run provenance
            if (!provenanceRecords.isEmpty()) {
                writeProvenance(runGroup);
            }
        }
    }

    /** Read a run from an existing storage group. */
    public static AcquisitionRun readFrom(StorageGroup parentGroup, String runName) {
        try (StorageGroup runGroup = parentGroup.openGroup(runName)) {
            AcquisitionMode mode = AcquisitionMode.values()[
                    ((Number) runGroup.getAttribute("acquisition_mode")).intValue()];

            String nucleusType = runGroup.hasAttribute("nucleus_type")
                    ? (String) runGroup.getAttribute("nucleus_type") : null;

            double freqMHz = 0;
            if (runGroup.hasChild("_spectrometer_freq_mhz")) {
                try (StorageDataset ds = runGroup.openDataset("_spectrometer_freq_mhz")) {
                    freqMHz = ((double[]) ds.readAll())[0];
                }
            }

            SpectrumIndex index = SpectrumIndex.readFrom(runGroup);
            Map<String, double[]> channels = readSignalChannels(runGroup);
            InstrumentConfig config = readInstrumentConfig(runGroup);
            List<Chromatogram> chroms = readChromatograms(runGroup);
            List<ProvenanceRecord> provenance = readProvenance(runGroup);

            return new AcquisitionRun(runName, mode, index, config, channels,
                    chroms, provenance, nucleusType, freqMHz);
        }
    }

    private void writeSignalChannels(StorageGroup runGroup) {
        try (StorageGroup sc = runGroup.createGroup("signal_channels")) {
            StringBuilder channelNames = new StringBuilder();
            boolean first = true;
            // v0.9 M64.5: some providers (ZarrProvider Java v0.8) don't
            // implement compression. Probe on the first channel and
            // reuse the decision for the rest so the loop is
            // consistent rather than half-compressed/half-not.
            Compression codec = Compression.ZLIB;
            for (var entry : channels.entrySet()) {
                if (!first) channelNames.append(",");
                channelNames.append(entry.getKey());

                String dsName = entry.getKey() + "_values";
                double[] data = entry.getValue();
                StorageDataset ds;
                try {
                    ds = sc.createDataset(dsName, Precision.FLOAT64,
                            data.length, CHUNK_SIZE, codec, COMPRESSION_LEVEL);
                } catch (UnsupportedOperationException e) {
                    if (codec != Compression.NONE) {
                        codec = Compression.NONE;
                        ds = sc.createDataset(dsName, Precision.FLOAT64,
                                data.length, CHUNK_SIZE, codec, 0);
                    } else {
                        throw e;
                    }
                }
                try (StorageDataset closeMe = ds) {
                    closeMe.writeAll(data);
                }
                first = false;
            }
            sc.setAttribute("channel_names", channelNames.toString());
        }
    }

    private static Map<String, double[]> readSignalChannels(StorageGroup runGroup) {
        Map<String, double[]> channels = new LinkedHashMap<>();
        if (!runGroup.hasChild("signal_channels")) return channels;

        try (StorageGroup sc = runGroup.openGroup("signal_channels")) {
            String namesStr = (String) sc.getAttribute("channel_names");
            for (String ch : namesStr.split(",")) {
                String dsName = ch.strip() + "_values";
                if (sc.hasChild(dsName)) {
                    try (StorageDataset ds = sc.openDataset(dsName)) {
                        // v0.7 M44: route through the storage protocol, not
                        // Hdf5Dataset directly. Providers decide how to
                        // materialise the underlying array.
                        channels.put(ch.strip(), (double[]) ds.readAll());
                    }
                }
            }
        }
        return channels;
    }

    private void writeInstrumentConfig(StorageGroup runGroup) {
        try (StorageGroup ic = runGroup.createGroup("instrument_config")) {
            if (instrumentConfig.manufacturer() != null)
                ic.setAttribute("manufacturer", instrumentConfig.manufacturer());
            if (instrumentConfig.model() != null)
                ic.setAttribute("model", instrumentConfig.model());
            if (instrumentConfig.serialNumber() != null)
                ic.setAttribute("serial_number", instrumentConfig.serialNumber());
            if (instrumentConfig.sourceType() != null)
                ic.setAttribute("source_type", instrumentConfig.sourceType());
            if (instrumentConfig.analyzerType() != null)
                ic.setAttribute("analyzer_type", instrumentConfig.analyzerType());
            if (instrumentConfig.detectorType() != null)
                ic.setAttribute("detector_type", instrumentConfig.detectorType());
        }
    }

    private static InstrumentConfig readInstrumentConfig(StorageGroup runGroup) {
        if (!runGroup.hasChild("instrument_config")) return null;
        try (StorageGroup ic = runGroup.openGroup("instrument_config")) {
            return new InstrumentConfig(
                readOptionalAttr(ic, "manufacturer"),
                readOptionalAttr(ic, "model"),
                readOptionalAttr(ic, "serial_number"),
                readOptionalAttr(ic, "source_type"),
                readOptionalAttr(ic, "analyzer_type"),
                readOptionalAttr(ic, "detector_type")
            );
        }
    }

    private void writeChromatograms(StorageGroup runGroup) {
        try (StorageGroup cg = runGroup.createGroup("chromatograms")) {
            cg.setAttribute("count", (long) chromatograms.size());

            // Concatenate time and intensity arrays
            int totalPoints = chromatograms.stream().mapToInt(Chromatogram::length).sum();
            double[] allTime = new double[totalPoints];
            double[] allIntensity = new double[totalPoints];
            long[] offsets = new long[chromatograms.size()];
            int[] lengths = new int[chromatograms.size()];
            int[] types = new int[chromatograms.size()];
            double[] targetMzs = new double[chromatograms.size()];
            double[] precursorMzs = new double[chromatograms.size()];
            double[] productMzs = new double[chromatograms.size()];

            int pos = 0;
            for (int i = 0; i < chromatograms.size(); i++) {
                Chromatogram c = chromatograms.get(i);
                offsets[i] = pos;
                lengths[i] = c.length();
                types[i] = c.type().ordinal();
                targetMzs[i] = c.targetMz();
                precursorMzs[i] = c.precursorMz();
                productMzs[i] = c.productMz();
                System.arraycopy(c.timeValues(), 0, allTime, pos, c.length());
                System.arraycopy(c.intensityValues(), 0, allIntensity, pos, c.length());
                pos += c.length();
            }

            writeDoubleDs(cg, "time_values", allTime);
            writeDoubleDs(cg, "intensity_values", allIntensity);

            try (StorageGroup idx = cg.createGroup("chromatogram_index")) {
                writeLongDs(idx, "offsets", offsets);
                writeIntDs(idx, "lengths", lengths);
                writeIntDs(idx, "types", types);
                writeDoubleDs(idx, "target_mzs", targetMzs);
                writeDoubleDs(idx, "precursor_mzs", precursorMzs);
                writeDoubleDs(idx, "product_mzs", productMzs);
            }
        }
    }

    private static List<Chromatogram> readChromatograms(StorageGroup runGroup) {
        if (!runGroup.hasChild("chromatograms")) return List.of();
        List<Chromatogram> result = new ArrayList<>();

        try (StorageGroup cg = runGroup.openGroup("chromatograms")) {
            double[] allTime = readDoubleDs(cg, "time_values");
            double[] allIntensity = readDoubleDs(cg, "intensity_values");

            try (StorageGroup idx = cg.openGroup("chromatogram_index")) {
                long[] offsets = readLongDs(idx, "offsets");
                int[] lengths = readIntDs(idx, "lengths");
                int[] types = readIntDs(idx, "types");
                double[] targetMzs = readDoubleDs(idx, "target_mzs");
                double[] precursorMzs = readDoubleDs(idx, "precursor_mzs");
                double[] productMzs = readDoubleDs(idx, "product_mzs");

                for (int i = 0; i < offsets.length; i++) {
                    int off = (int) offsets[i];
                    int len = lengths[i];
                    double[] time = Arrays.copyOfRange(allTime, off, off + len);
                    double[] intensity = Arrays.copyOfRange(allIntensity, off, off + len);
                    ChromatogramType type = ChromatogramType.values()[types[i]];
                    result.add(new Chromatogram(time, intensity, type,
                            targetMzs[i], precursorMzs[i], productMzs[i]));
                }
            }
        }
        return result;
    }

    private void writeProvenance(StorageGroup runGroup) {
        // v0.3+: per-run provenance as JSON attribute (compound dataset deferred)
        try (StorageGroup prov = runGroup.createGroup("provenance")) {
            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < provenanceRecords.size(); i++) {
                if (i > 0) json.append(",");
                ProvenanceRecord r = provenanceRecords.get(i);
                json.append("{\"timestamp_unix\":").append(r.timestampUnix())
                    .append(",\"software\":\"").append(r.software()).append("\"")
                    .append(",\"parameters\":").append(r.parametersJson())
                    .append(",\"input_refs\":").append(r.inputRefsJson())
                    .append(",\"output_refs\":").append(r.outputRefsJson())
                    .append("}");
            }
            json.append("]");
            runGroup.setAttribute("provenance_json", json.toString());
        }
    }

    private static List<ProvenanceRecord> readProvenance(StorageGroup runGroup) {
        // Read from provenance_json attribute (v0.2+ compat)
        if (!runGroup.hasAttribute("provenance_json")) return List.of();
        // Simple parse — full JSON parsing deferred to M32 compound dataset support
        return List.of(); // placeholder - compound dataset reading in SpectralDataset
    }

    // ── Dataset helpers ─────────────────────────────────────────────

    private static void writeDoubleDs(StorageGroup g, String name, double[] data) {
        try (StorageDataset ds = g.createDataset(name, Precision.FLOAT64,
                data.length, CHUNK_SIZE, Compression.ZLIB, COMPRESSION_LEVEL)) {
            ds.writeAll(data);
        }
    }

    private static void writeLongDs(StorageGroup g, String name, long[] data) {
        try (StorageDataset ds = g.createDataset(name, Precision.INT64,
                data.length, 0, Compression.NONE, 0)) {
            ds.writeAll(data);
        }
    }

    private static void writeIntDs(StorageGroup g, String name, int[] data) {
        try (StorageDataset ds = g.createDataset(name, Precision.INT32,
                data.length, 0, Compression.NONE, 0)) {
            ds.writeAll(data);
        }
    }

    private static double[] readDoubleDs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (double[]) ds.readAll();
        }
    }

    private static long[] readLongDs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (long[]) ds.readAll();
        }
    }

    private static int[] readIntDs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (int[]) ds.readAll();
        }
    }

    private static String readOptionalAttr(StorageGroup g, String name) {
        return g.hasAttribute(name) ? (String) g.getAttribute(name) : null;
    }

    @Override
    public void close() {
        // No storage handles held — all closed after read/write
    }
}
