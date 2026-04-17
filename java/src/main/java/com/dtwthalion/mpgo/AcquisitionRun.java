/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.*;
import com.dtwthalion.mpgo.hdf5.Hdf5Dataset;
import com.dtwthalion.mpgo.hdf5.Hdf5Group;

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
        AutoCloseable {

    private static final int CHUNK_SIZE = 16384;
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
        for (ProvenanceRecord r : provenanceChain()) {
            seen.addAll(parseStringArray(r.inputRefsJson()));
        }
        return new java.util.ArrayList<>(seen);
    }

    @Override
    public java.util.List<String> outputEntities() {
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        for (ProvenanceRecord r : provenanceChain()) {
            seen.addAll(parseStringArray(r.outputRefsJson()));
        }
        return new java.util.ArrayList<>(seen);
    }

    private java.util.List<ProvenanceRecord> ensureProvenanceCache() {
        if (provenanceCache == null) {
            provenanceCache = new java.util.ArrayList<>(provenanceRecords);
        }
        return provenanceCache;
    }

    /**
     * Minimal JSON string-array parser for {@code ["a","b","c"]} format.
     * Returns empty list on null, empty, or malformed input. Will be
     * replaced by proper List&lt;String&gt; accessor on
     * {@link ProvenanceRecord} in slice 41.4.
     */
    private static java.util.List<String> parseStringArray(String json) {
        if (json == null) return java.util.List.of();
        String trimmed = json.trim();
        if (trimmed.isEmpty() || trimmed.equals("[]")) return java.util.List.of();
        if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return java.util.List.of();
        String inner = trimmed.substring(1, trimmed.length() - 1).trim();
        if (inner.isEmpty()) return java.util.List.of();
        java.util.List<String> out = new java.util.ArrayList<>();
        // Simple split on ","  — works because our refs are URIs/IDs without commas.
        // For robustness, strip outer quotes per element.
        for (String tok : inner.split(",")) {
            String t = tok.trim();
            if (t.startsWith("\"") && t.endsWith("\"")) {
                t = t.substring(1, t.length() - 1).replace("\\\"", "\"");
            }
            if (!t.isEmpty()) out.add(t);
        }
        return out;
    }

    // ── HDF5 I/O ────────────────────────────────────────────────────

    /** Write this run to a parent group (creates <name>/ subgroup). */
    public void writeTo(Hdf5Group parentGroup) {
        try (Hdf5Group runGroup = parentGroup.createGroup(name)) {
            runGroup.setIntegerAttribute("acquisition_mode", acquisitionMode.ordinal());
            runGroup.setIntegerAttribute("spectrum_count", spectrumIndex.count());
            runGroup.setStringAttribute("spectrum_class", spectrumClassName());

            if (nucleusType != null) {
                runGroup.setStringAttribute("nucleus_type", nucleusType);
            }
            if (spectrometerFrequencyMHz > 0) {
                try (Hdf5Dataset ds = runGroup.createDataset("_spectrometer_freq_mhz",
                        Precision.FLOAT64, 1, 0, 0)) {
                    ds.writeData(new double[]{ spectrometerFrequencyMHz });
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

    /** Read a run from an existing HDF5 group. */
    public static AcquisitionRun readFrom(Hdf5Group parentGroup, String runName) {
        try (Hdf5Group runGroup = parentGroup.openGroup(runName)) {
            AcquisitionMode mode = AcquisitionMode.values()[
                    (int) runGroup.readIntegerAttribute("acquisition_mode", 0)];

            String spectrumClass = null;
            if (runGroup.hasAttribute("spectrum_class")) {
                spectrumClass = runGroup.readStringAttribute("spectrum_class");
            }

            String nucleusType = null;
            if (runGroup.hasAttribute("nucleus_type")) {
                nucleusType = runGroup.readStringAttribute("nucleus_type");
            }

            double freqMHz = 0;
            if (runGroup.hasChild("_spectrometer_freq_mhz")) {
                try (Hdf5Dataset ds = runGroup.openDataset("_spectrometer_freq_mhz")) {
                    freqMHz = ((double[]) ds.readData())[0];
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

    private void writeSignalChannels(Hdf5Group runGroup) {
        try (Hdf5Group sc = runGroup.createGroup("signal_channels")) {
            StringBuilder channelNames = new StringBuilder();
            boolean first = true;
            for (var entry : channels.entrySet()) {
                if (!first) channelNames.append(",");
                channelNames.append(entry.getKey());
                first = false;

                String dsName = entry.getKey() + "_values";
                double[] data = entry.getValue();
                try (Hdf5Dataset ds = sc.createDataset(dsName, Precision.FLOAT64,
                        data.length, CHUNK_SIZE, COMPRESSION_LEVEL)) {
                    ds.writeData(data);
                }
            }
            sc.setStringAttribute("channel_names", channelNames.toString());
        }
    }

    private static Map<String, double[]> readSignalChannels(Hdf5Group runGroup) {
        Map<String, double[]> channels = new LinkedHashMap<>();
        if (!runGroup.hasChild("signal_channels")) return channels;

        try (Hdf5Group sc = runGroup.openGroup("signal_channels")) {
            String namesStr = sc.readStringAttribute("channel_names");
            for (String ch : namesStr.split(",")) {
                String dsName = ch.strip() + "_values";
                if (sc.hasChild(dsName)) {
                    try (Hdf5Dataset ds = sc.openDataset(dsName)) {
                        channels.put(ch.strip(), (double[]) ds.readData());
                    }
                }
            }
        }
        return channels;
    }

    private void writeInstrumentConfig(Hdf5Group runGroup) {
        try (Hdf5Group ic = runGroup.createGroup("instrument_config")) {
            if (instrumentConfig.manufacturer() != null)
                ic.setStringAttribute("manufacturer", instrumentConfig.manufacturer());
            if (instrumentConfig.model() != null)
                ic.setStringAttribute("model", instrumentConfig.model());
            if (instrumentConfig.serialNumber() != null)
                ic.setStringAttribute("serial_number", instrumentConfig.serialNumber());
            if (instrumentConfig.sourceType() != null)
                ic.setStringAttribute("source_type", instrumentConfig.sourceType());
            if (instrumentConfig.analyzerType() != null)
                ic.setStringAttribute("analyzer_type", instrumentConfig.analyzerType());
            if (instrumentConfig.detectorType() != null)
                ic.setStringAttribute("detector_type", instrumentConfig.detectorType());
        }
    }

    private static InstrumentConfig readInstrumentConfig(Hdf5Group runGroup) {
        if (!runGroup.hasChild("instrument_config")) return null;
        try (Hdf5Group ic = runGroup.openGroup("instrument_config")) {
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

    private void writeChromatograms(Hdf5Group runGroup) {
        try (Hdf5Group cg = runGroup.createGroup("chromatograms")) {
            cg.setIntegerAttribute("count", chromatograms.size());

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

            try (Hdf5Group idx = cg.createGroup("chromatogram_index")) {
                writeLongDs(idx, "offsets", offsets);
                writeIntDs(idx, "lengths", lengths);
                writeIntDs(idx, "types", types);
                writeDoubleDs(idx, "target_mzs", targetMzs);
                writeDoubleDs(idx, "precursor_mzs", precursorMzs);
                writeDoubleDs(idx, "product_mzs", productMzs);
            }
        }
    }

    private static List<Chromatogram> readChromatograms(Hdf5Group runGroup) {
        if (!runGroup.hasChild("chromatograms")) return List.of();
        List<Chromatogram> result = new ArrayList<>();

        try (Hdf5Group cg = runGroup.openGroup("chromatograms")) {
            double[] allTime = readDoubleDs(cg, "time_values");
            double[] allIntensity = readDoubleDs(cg, "intensity_values");

            try (Hdf5Group idx = cg.openGroup("chromatogram_index")) {
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

    private void writeProvenance(Hdf5Group runGroup) {
        // v0.3+: per-run provenance as JSON attribute (compound dataset deferred)
        try (Hdf5Group prov = runGroup.createGroup("provenance")) {
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
            runGroup.setStringAttribute("provenance_json", json.toString());
        }
    }

    private static List<ProvenanceRecord> readProvenance(Hdf5Group runGroup) {
        // Read from provenance_json attribute (v0.2+ compat)
        if (!runGroup.hasAttribute("provenance_json")) return List.of();
        // Simple parse — full JSON parsing deferred to M32 compound dataset support
        return List.of(); // placeholder - compound dataset reading in SpectralDataset
    }

    // ── Dataset helpers ─────────────────────────────────────────────

    private static void writeDoubleDs(Hdf5Group g, String name, double[] data) {
        try (Hdf5Dataset ds = g.createDataset(name, Precision.FLOAT64,
                data.length, CHUNK_SIZE, COMPRESSION_LEVEL)) {
            ds.writeData(data);
        }
    }

    private static void writeLongDs(Hdf5Group g, String name, long[] data) {
        try (Hdf5Dataset ds = g.createDataset(name, Precision.INT64, data.length, 0, 0)) {
            ds.writeData(data);
        }
    }

    private static void writeIntDs(Hdf5Group g, String name, int[] data) {
        try (Hdf5Dataset ds = g.createDataset(name, Precision.INT32, data.length, 0, 0)) {
            ds.writeData(data);
        }
    }

    private static double[] readDoubleDs(Hdf5Group g, String name) {
        try (Hdf5Dataset ds = g.openDataset(name)) {
            return (double[]) ds.readData();
        }
    }

    private static long[] readLongDs(Hdf5Group g, String name) {
        try (Hdf5Dataset ds = g.openDataset(name)) {
            return (long[]) ds.readData();
        }
    }

    private static int[] readIntDs(Hdf5Group g, String name) {
        try (Hdf5Dataset ds = g.openDataset(name)) {
            return (int[]) ds.readData();
        }
    }

    private static String readOptionalAttr(Hdf5Group g, String name) {
        return g.hasAttribute(name) ? g.readStringAttribute(name) : null;
    }

    @Override
    public void close() {
        // No HDF5 handles held — all closed after read/write
    }
}
