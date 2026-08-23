/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.codecs.FloatDeltaZstd;
import global.thalion.ttio.providers.CompoundField;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Writes one spectral run with bounded memory: every per-spectrum
 * dataset is extendable and appended per batch; codec-17 channels emit
 * an FDZ1 block as each {@link FloatDeltaZstd#BLOCK_SIZE} values fill and
 * have their header rewritten at close. The result is what
 * {@link AcquisitionRun#writeTo} writes for the same spectra. Python:
 * {@code ttio.spectral_stream_writer.SpectralStreamWriter}.
 */
public final class SpectralStreamWriter implements AutoCloseable {

    /** Run-level options.
     *
     *  @param spectrumClass       {@code @spectrum_class}, e.g. {@code TTIOMassSpectrum}
     *  @param channelNames        channel order of {@code @channel_names}
     *  @param batchSpectra        spectra per {@link #append} buffer flush
     *  @param optDisableFloatDelta {@code true} keeps codec 0 for MS runs
     *  @param signalCompression   {@code ZLIB} (default) or {@code FLOAT_DELTA_ZSTD} */
    public record Options(String spectrumClass, AcquisitionMode acquisitionMode,
                          List<String> channelNames, InstrumentConfig instrumentConfig,
                          int batchSpectra, boolean optDisableFloatDelta,
                          Compression signalCompression, String nucleusType, String solvent,
                          List<ProvenanceRecord> provenanceRecords) {
        public Options {
            channelNames = List.copyOf(channelNames);
            if (batchSpectra < 1) throw new IllegalArgumentException("batchSpectra must be >= 1");
            if (signalCompression == null) signalCompression = Compression.ZLIB;
            provenanceRecords = provenanceRecords == null ? List.of() : List.copyOf(provenanceRecords);
        }

        /** MS defaults: {@code TTIOMassSpectrum}, 4096 spectra per batch. */
        public static Options ms(AcquisitionMode mode, List<String> channelNames,
                                 InstrumentConfig instrumentConfig) {
            return new Options("TTIOMassSpectrum", mode, channelNames, instrumentConfig,
                4096, false, Compression.ZLIB, null, "", List.of());
        }

        public Options withProvenance(List<ProvenanceRecord> records) {
            return new Options(spectrumClass, acquisitionMode, channelNames, instrumentConfig,
                batchSpectra, optDisableFloatDelta, signalCompression, nucleusType, solvent, records);
        }

        public Options withBatchSpectra(int n) {
            return new Options(spectrumClass, acquisitionMode, channelNames, instrumentConfig,
                n, optDisableFloatDelta, signalCompression, nucleusType, solvent, provenanceRecords);
        }

        public Options withFloatDeltaDisabled(boolean disabled) {
            return new Options(spectrumClass, acquisitionMode, channelNames, instrumentConfig,
                batchSpectra, disabled, signalCompression, nucleusType, solvent, provenanceRecords);
        }
    }

    private static final String[][] INDEX_COLUMNS = {
        {"lengths", "UINT32"}, {"retention_times", "FLOAT64"}, {"ms_levels", "INT32"},
        {"polarities", "INT32"}, {"precursor_mzs", "FLOAT64"}, {"precursor_charges", "INT32"},
        {"base_peak_intensities", "FLOAT64"},
    };
    private static final String[][] M74_COLUMNS = {
        {"activation_methods", "INT32"}, {"isolation_target_mzs", "FLOAT64"},
        {"isolation_lower_offsets", "FLOAT64"}, {"isolation_upper_offsets", "FLOAT64"},
    };

    private final StorageGroup study;
    private final String name;
    private final Options opt;
    private final boolean useFloatDelta;
    private StorageGroup rg;
    private StorageGroup idxGroup;
    private final Map<String, StorageDataset> idx = new LinkedHashMap<>();
    private final Map<String, StorageDataset> sig = new LinkedHashMap<>();
    private final Map<String, double[]> fdzBuf = new LinkedHashMap<>();
    private int threads;
    private global.thalion.ttio.Threads.PoolScope scope;
    private record InFlightFdz(java.util.concurrent.Future<FloatDeltaZstd.EncodedBlock> encoded, int nValues) {}
    private final Map<String, java.util.ArrayDeque<InFlightFdz>> fdzInflight = new LinkedHashMap<>();
    private final Map<String, Long> fdzValues = new LinkedHashMap<>();
    private final List<Object[]> blockRows = new ArrayList<>();
    private final Map<String, Integer> fdzBlocks = new LinkedHashMap<>();
    private boolean m74;
    private boolean centroided;
    private int count;
    private List<Chromatogram> chromatograms = List.of();
    private final List<Spectrum> pending = new ArrayList<>();
    private boolean closed;

    /** Append spectra to run {@code runName} of {@code /study}
     *  {@code studyGroup}; creates {@code ms_runs} when absent and
     *  maintains {@code @_run_names}. */
    public SpectralStreamWriter(StorageGroup studyGroup, String runName, Options options) {
        this(studyGroup, runName, options, global.thalion.ttio.Threads.resolve(null));
    }

    /** With {@code threads} > 1 the codec-17 blocks of each channel are
     *  encoded on a pool and appended in emission order by the caller's
     *  thread; at most {@code threads + 1} blocks per channel are in
     *  flight. The file is byte for byte the one thread's. */
    public SpectralStreamWriter(StorageGroup studyGroup, String runName, Options options, int threads) {
        this.study = studyGroup;
        this.name = runName;
        this.opt = options;
        this.useFloatDelta = options.signalCompression() == Compression.FLOAT_DELTA_ZSTD
            || (options.signalCompression() == Compression.ZLIB && !options.optDisableFloatDelta()
                && "TTIOMassSpectrum".equals(options.spectrumClass()));
        this.threads = Math.max(1, threads);
        this.scope = useFloatDelta ? global.thalion.ttio.Threads.pool(this.threads)
                                   : global.thalion.ttio.Threads.pool(1);
    }

    public int threads() { return threads; }

    public int spectrumCount() { return count + pending.size(); }

    /** Chromatograms written at close. */
    public void setChromatograms(List<Chromatogram> c) {
        this.chromatograms = c == null ? List.of() : List.copyOf(c);
    }

    /** Buffer one spectrum; flushed every {@code batchSpectra}. */
    public void append(Spectrum s) {
        if (closed) throw new IllegalStateException("writer is closed");
        pending.add(s);
        if (pending.size() >= opt.batchSpectra()) flush();
    }

    /** Write a batch (after any buffered single spectra). */
    public void appendBatch(WrittenSpectralBatch b) {
        if (closed) throw new IllegalStateException("writer is closed");
        flush();
        if (b.spectrumCount() > 0) writeBatch(b);
    }

    /** Write the buffered single spectra. */
    public void flush() {
        if (pending.isEmpty()) return;
        WrittenSpectralBatch b = batchOf(pending);
        pending.clear();
        writeBatch(b);
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        try {
            closeInner();
        } finally {
            scope.close();
        }
    }

    private void closeInner() {
        flush();
        if (rg == null) ensureLayout(null);
        for (String c : opt.channelNames()) {
            if (!useFloatDelta) continue;
            double[] buf = fdzBuf.get(c);
            if (buf.length > 0) emitFdzBlock(c, buf);
            fdzBuf.put(c, new double[0]);
            drainFdz(c, 0);
            sig.get(c).writeSlice(0, FloatDeltaZstd.headerBytes(fdzValues.get(c), fdzBlocks.get(c)));
        }
        writeBlockIndex();
        rg.setAttribute("spectrum_count", (long) count);
        idxGroup.setAttribute("count", (long) count);
        if (!chromatograms.isEmpty()) AcquisitionRun.writeChromatograms(rg, chromatograms);
        if (!opt.provenanceRecords().isEmpty()) AcquisitionRun.writeProvenance(rg, opt.provenanceRecords());
    }

    // ------------------------------------------------------------------

    private StorageGroup runsGroup() {
        StorageGroup g;
        if (study.hasChild("ms_runs")) {
            g = study.openGroup("ms_runs");
        } else {
            g = study.createGroup("ms_runs");
            g.setAttribute("_run_names", "");
        }
        Object namesAttr = g.hasAttribute("_run_names") ? g.getAttribute("_run_names") : null;
        String names = namesAttr == null ? "" : namesAttr.toString();
        List<String> list = new ArrayList<>();
        for (String s : names.split(",")) if (!s.isEmpty()) list.add(s);
        if (!list.contains(name)) {
            list.add(name);
            g.setAttribute("_run_names", String.join(",", list));
        }
        return g;
    }

    private void ensureLayout(WrittenSpectralBatch first) {
        if (rg != null) return;
        StorageGroup parent = runsGroup();
        if (parent.hasChild(name)) throw new IllegalArgumentException("run '" + name + "' already exists");
        StorageGroup g = parent.createGroup(name);
        g.setAttribute("acquisition_mode", (long) opt.acquisitionMode().ordinal());
        g.setAttribute("spectrum_count", 0L);
        g.setAttribute("spectrum_class", opt.spectrumClass());
        if (opt.nucleusType() != null) g.setAttribute("nucleus_type", opt.nucleusType());
        if (opt.solvent() != null && !opt.solvent().isEmpty()) g.setAttribute("solvent", opt.solvent());
        if (opt.instrumentConfig() != null) AcquisitionRun.writeInstrumentConfig(g, opt.instrumentConfig());
        idxGroup = g.createGroup("spectrum_index");
        idxGroup.setAttribute("count", 0L);
        for (String[] c : INDEX_COLUMNS) createIndexColumn(c[0], c[1]);
        if (first != null && first.hasM74()) {
            m74 = true;
            for (String[] c : M74_COLUMNS) createIndexColumn(c[0], c[1]);
        }
        if (first != null && first.centroideds() != null) {
            centroided = true;
            createIndexColumn("centroideds", "INT32");
        }
        StorageGroup sc = g.createGroup("signal_channels");
        sc.setAttribute("channel_names", String.join(",", opt.channelNames()));
        for (String c : opt.channelNames()) {
            StorageDataset ds;
            if (useFloatDelta) {
                ds = sc.createDataset(c + "_values", Precision.UINT8, 0, AcquisitionRun.CHUNK_SIZE,
                    Compression.NONE, 0, true);
                ds.setAttribute("compression", Compression.FLOAT_DELTA_ZSTD.ordinal());
                ds.append(FloatDeltaZstd.headerBytes(0, 0));
                fdzBuf.put(c, new double[0]);
                fdzValues.put(c, 0L);
                fdzBlocks.put(c, 0);
            } else {
                Compression codec = opt.signalCompression() == Compression.ZLIB
                    ? Compression.ZLIB : Compression.NONE;
                try {
                    ds = sc.createDataset(c + "_values", Precision.FLOAT64, 0, AcquisitionRun.CHUNK_SIZE,
                        codec, AcquisitionRun.COMPRESSION_LEVEL, true);
                } catch (UnsupportedOperationException e) {
                    ds = sc.createDataset(c + "_values", Precision.FLOAT64, 0, AcquisitionRun.CHUNK_SIZE,
                        Compression.NONE, 0, true);
                }
            }
            sig.put(c, ds);
        }
        rg = g;
    }

    private void createIndexColumn(String name, String precision) {
        StorageDataset ds;
        try {
            ds = idxGroup.createDataset(name, Precision.valueOf(precision), 0,
                SpectrumIndex.INDEX_CHUNK_SIZE, Compression.ZLIB, AcquisitionRun.COMPRESSION_LEVEL, true);
        } catch (UnsupportedOperationException e) {
            ds = idxGroup.createDataset(name, Precision.valueOf(precision), 0,
                SpectrumIndex.INDEX_CHUNK_SIZE, Compression.NONE, 0, true);
        }
        idx.put(name, ds);
    }

    private void writeBatch(WrittenSpectralBatch b) {
        ensureLayout(b);
        int n = b.spectrumCount();
        if (b.hasM74() && !m74) {
            m74 = true;
            for (String[] c : M74_COLUMNS) {
                createIndexColumn(c[0], c[1]);
                if (count > 0) idx.get(c[0]).append(zeros(c[1], count));
            }
        }
        if (b.centroideds() != null && !centroided) {
            centroided = true;
            createIndexColumn("centroideds", "INT32");
            if (count > 0) idx.get("centroideds").append(new int[count]);
        }
        idx.get("lengths").append(b.lengths());
        idx.get("retention_times").append(b.retentionTimes());
        idx.get("ms_levels").append(b.msLevels());
        idx.get("polarities").append(b.polarities());
        idx.get("precursor_mzs").append(b.precursorMzs());
        idx.get("precursor_charges").append(b.precursorCharges());
        idx.get("base_peak_intensities").append(b.basePeakIntensities());
        if (m74) {
            idx.get("activation_methods").append(b.hasM74() ? b.activationMethods() : new int[n]);
            idx.get("isolation_target_mzs").append(b.hasM74() ? b.isolationTargetMzs() : new double[n]);
            idx.get("isolation_lower_offsets").append(b.hasM74() ? b.isolationLowerOffsets() : new double[n]);
            idx.get("isolation_upper_offsets").append(b.hasM74() ? b.isolationUpperOffsets() : new double[n]);
        }
        if (centroided) {
            idx.get("centroideds").append(b.centroideds() != null ? b.centroideds() : new int[n]);
        }
        for (String c : opt.channelNames()) {
            double[] data = b.channelData().get(c);
            if (data == null) data = new double[0];
            if (useFloatDelta) {
                double[] prev = fdzBuf.get(c);
                double[] buf;
                if (prev.length == 0) {
                    buf = data;
                } else {
                    buf = Arrays.copyOf(prev, prev.length + data.length);
                    System.arraycopy(data, 0, buf, prev.length, data.length);
                }
                int pos = 0;
                while (buf.length - pos >= FloatDeltaZstd.BLOCK_SIZE) {
                    emitFdzBlock(c, Arrays.copyOfRange(buf, pos, pos + FloatDeltaZstd.BLOCK_SIZE));
                    pos += FloatDeltaZstd.BLOCK_SIZE;
                }
                fdzBuf.put(c, pos == 0 ? buf : Arrays.copyOfRange(buf, pos, buf.length));
            } else {
                sig.get(c).append(data);
            }
        }
        count += n;
        rg.setAttribute("spectrum_count", (long) count);
        idxGroup.setAttribute("count", (long) count);
    }

    private void emitFdzBlock(String c, double[] values) {
        if (scope.executor() == null) {
            appendFdz(c, FloatDeltaZstd.encodeBlock(values), values.length);
            return;
        }
        drainFdz(c, threads);
        fdzInflight.computeIfAbsent(c, k -> new java.util.ArrayDeque<>())
            .add(new InFlightFdz(scope.executor().submit(() -> FloatDeltaZstd.encodeBlock(values)), values.length));
    }

    /** Append completed blocks of channel {@code c} in emission order; wait
     *  on the oldest until at most {@code blockUntil} remain in flight. */
    private void drainFdz(String c, int blockUntil) {
        java.util.ArrayDeque<InFlightFdz> q = fdzInflight.get(c);
        if (q == null) return;
        while (!q.isEmpty() && (q.size() > blockUntil || q.peekFirst().encoded().isDone())) {
            InFlightFdz f = q.pollFirst();
            try {
                appendFdz(c, f.encoded().get(), f.nValues());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException(e);
            } catch (java.util.concurrent.ExecutionException e) {
                Throwable t = e.getCause();
                throw t instanceof RuntimeException r ? r : new IllegalStateException(t);
            }
        }
    }

    private void appendFdz(String c, FloatDeltaZstd.EncodedBlock encoded, int nValues) {
        byte[] block = FloatDeltaZstd.blockBytes(encoded);
        // The block lands at the current end of the channel dataset. The
        // recorded extent covers the 5-byte block header as well as the
        // body, so one range read yields a self-describing block.
        long off = sig.get(c).length();
        int ordinal = fdzBlocks.get(c);
        long valueStart = fdzValues.get(c);
        sig.get(c).append(block);
        fdzValues.put(c, valueStart + nValues);
        fdzBlocks.put(c, ordinal + 1);

        List<String> chans = opt.channelNames();
        int i = chans.indexOf(c);
        if (i < 0) return;
        int cols = 2 + 3 * chans.size();
        while (blockRows.size() <= ordinal) blockRows.add(new Object[cols]);
        Object[] row = blockRows.get(ordinal);
        row[0] = valueStart;
        row[1] = nValues;
        row[2 + 2 * i] = off;
        row[3 + 2 * i] = (long) block.length;
        row[2 + 2 * chans.size() + i] = Compression.FLOAT_DELTA_ZSTD.ordinal();
    }

    /**
     * {@code blocks/index} describes one value range per row, so it is
     * only meaningful when every channel cut its blocks at the same
     * points. They do when each spectrum contributes one value per
     * channel, which is every case the writer produces today; a run
     * that ever fell out of step gets no table rather than a wrong one.
     */
    private void writeBlockIndex() {
        if (!useFloatDelta || blockRows.isEmpty()) return;
        List<String> chans = opt.channelNames();
        int cols = 2 + 3 * chans.size();
        for (Object[] row : blockRows) {
            for (int k = 0; k < cols; k++) {
                if (row[k] == null) return;
            }
        }
        List<CompoundField> fields = new ArrayList<>();
        fields.add(new CompoundField("value_start", CompoundField.Kind.UINT64));
        fields.add(new CompoundField("n_values", CompoundField.Kind.UINT32));
        for (String ch : chans) {
            fields.add(new CompoundField(ch + "_off", CompoundField.Kind.UINT64));
            fields.add(new CompoundField(ch + "_len", CompoundField.Kind.UINT64));
        }
        for (String ch : chans) {
            fields.add(new CompoundField(ch + "_codec", CompoundField.Kind.UINT32));
        }
        // Every row is known here, so the chunk is sized to them: a
        // fixed 256-row chunk costs a run with one block 13 KB of
        // padding, which dominates a small .tio.
        int chunkRows = Math.min(Math.max(blockRows.size(), 1), 1024);
        StorageGroup blocks = rg.createGroup("blocks");
        StorageDataset ds = blocks.createCompoundDataset("index", fields, 0, true, chunkRows);
        ds.append(blockRows);
    }

    private static Object zeros(String precision, int n) {
        return switch (Precision.valueOf(precision)) {
            case FLOAT64 -> new double[n];
            case INT32, UINT32 -> new int[n];
            default -> throw new IllegalArgumentException(precision);
        };
    }

    /** One batch from buffered spectra ({@link MassSpectrum} fields;
     *  other spectrum kinds carry their channel arrays and scan time). */
    private WrittenSpectralBatch batchOf(List<Spectrum> spectra) {
        int n = spectra.size();
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        double[] rts = new double[n];
        int[] msLevels = new int[n];
        int[] polarities = new int[n];
        double[] precMz = new double[n];
        int[] precZ = new int[n];
        double[] bpi = new double[n];
        Map<String, List<double[]>> parts = new LinkedHashMap<>();
        for (String c : opt.channelNames()) parts.put(c, new ArrayList<>());
        long off = 0;
        for (int i = 0; i < n; i++) {
            Spectrum s = spectra.get(i);
            offsets[i] = off;
            rts[i] = s.scanTimeSeconds();
            precMz[i] = s.precursorMz();
            precZ[i] = s.precursorCharge();
            int len = 0;
            for (String c : opt.channelNames()) {
                SignalArray a = s.signalArray(c);
                double[] v = a == null ? new double[0] : a.asDoubles();
                parts.get(c).add(v);
                len = Math.max(len, v.length);
            }
            lengths[i] = len;
            off += len;
            if (s instanceof MassSpectrum ms) {
                msLevels[i] = ms.msLevel();
                polarities[i] = ms.polarity() == null ? 0 : ms.polarity().intValue();
                double max = 0;
                for (double d : ms.intensityValues()) if (d > max) max = d;
                bpi[i] = max;
            }
        }
        Map<String, double[]> data = new LinkedHashMap<>();
        for (String c : opt.channelNames()) {
            double[] all = new double[(int) off];
            int p = 0;
            for (double[] v : parts.get(c)) { System.arraycopy(v, 0, all, p, v.length); p += v.length; }
            data.put(c, all);
        }
        return new WrittenSpectralBatch(offsets, lengths, rts, msLevels, polarities, precMz, precZ, bpi,
            null, null, null, null, null, data);
    }
}
