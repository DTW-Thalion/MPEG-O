package global.thalion.ttio.browser.importers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.SignalArray;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.importers.BrukerTDFReader;
import global.thalion.ttio.importers.CramReader;
import global.thalion.ttio.importers.FastaReader;
import global.thalion.ttio.importers.FastqReader;
import global.thalion.ttio.importers.ImzMLReader;
import global.thalion.ttio.importers.JcampDxReader;
import global.thalion.ttio.importers.MzMLReader;
import global.thalion.ttio.importers.MzTabReader;
import global.thalion.ttio.importers.NmrMLReader;
import global.thalion.ttio.importers.SamReader;
import global.thalion.ttio.importers.ThermoRawReader;
import global.thalion.ttio.importers.WatersMassLynxReader;
import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.progress.ProgressTracker;
import global.thalion.ttio.io.ProgressSink;
import javafx.concurrent.Task;

/**
 * Background {@link Task} that runs the chosen importer and writes the
 * result to {@link ImportConfig#targetTio} as a fresh {@code .tio}.
 *
 * <p>Per-format dispatch on {@link ImportFormatSpec#name}. Wired
 * formats (Phase 8 + 8.x acceptance-gate set):</p>
 * <ul>
 *   <li>mzML -- single {@code AcquisitionRun}.</li>
 *   <li>nmrML -- single {@code AcquisitionRun}.</li>
 *   <li>mzTab -- identifications + quantifications.</li>
 *   <li>BAM / SAM / CRAM -- {@code WrittenGenomicRun}.</li>
 *   <li>FASTA -- reference or unaligned reads.</li>
 *   <li>FASTQ -- {@code WrittenGenomicRun}.</li>
 *   <li>imzML -- {@code MSImage} via HDF5 (continuous mode only).</li>
 *   <li>JCAMP-DX -- single-spectrum {@code AcquisitionRun}.</li>
 *   <li>Waters MassLynx -- via masslynxraw converter.</li>
 *   <li>Thermo .raw -- via ThermoRawFileParser.</li>
 *   <li>Bruker timsTOF -- via Python bruker_tdf_cli helper.</li>
 * </ul>
 */
public final class ImportTask extends Task<Void> {

    private final ImportFormatSpec spec;
    private final ImportConfig config;
    private volatile ProgressListener progressListener;
    /** Bytes-mode tracker, driven by the heartbeat ticker (fallback for
     *  not-yet-instrumented formats). */
    private ProgressTracker bytesTracker;
    /** Units-mode tracker, driven by ProgressSink callbacks from
     *  instrumented SDK calls (records / chromosomes / spectra). Built
     *  lazily on first sink fire. */
    private volatile ProgressTracker unitsTracker;
    /** Set true by a ProgressSink when an instrumented format starts
     *  reporting real units; the heartbeat ticker stands down. */
    private final java.util.concurrent.atomic.AtomicBoolean sinkActive =
        new java.util.concurrent.atomic.AtomicBoolean(false);

    public ImportTask(ImportFormatSpec spec, ImportConfig config) {
        this.spec = spec;
        this.config = config;
    }

    public void setProgressListener(ProgressListener listener) {
        this.progressListener = listener;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Importing " + spec.name + " from " + config.sourcePath);
        long inputBytes = Files.size(config.sourcePath);
        long startMs = System.currentTimeMillis();
        // Fallback bytes-mode tracker for not-yet-instrumented formats.
        // Heartbeat ticker polls target file size; SDK calls without a
        // ProgressSink hook fall through to this path.
        bytesTracker = new ProgressTracker(
            "importing", inputBytes, -1L, startMs);
        emitBytes(0L);
        java.util.concurrent.atomic.AtomicBoolean done =
            new java.util.concurrent.atomic.AtomicBoolean(false);
        Thread ticker = new Thread(() -> {
            while (!done.get()) {
                if (!sinkActive.get()) {
                    long current = 0L;
                    try {
                        if (Files.exists(config.targetTio)) {
                            current = Math.min(Files.size(config.targetTio), inputBytes);
                        }
                    } catch (Exception ignored) { /* file may flicker mid-write */ }
                    emitBytes(current);
                }
                try { Thread.sleep(500L); }
                catch (InterruptedException ie) { return; }
            }
        }, "import-progress-ticker");
        ticker.setDaemon(true);
        ticker.start();

        // Sink supplied to instrumented SDK calls. First non-empty fire
        // builds the units tracker; subsequent fires update it. Heartbeat
        // sees sinkActive=true and stops polling output bytes.
        ProgressSink sink = (recDone, recTotal) -> {
            sinkActive.set(true);
            ProgressTracker t = unitsTracker;
            if (t == null && recTotal > 0L) {
                t = new ProgressTracker(
                    "importing", -1L, recTotal, startMs);
                unitsTracker = t;
            }
            if (t == null) return;
            ProgressReport r = t.sample(0L, recDone, System.currentTimeMillis());
            ProgressListener l = progressListener;
            if (l != null) l.onProgress(r);
        };

        long t0 = System.currentTimeMillis();
        System.err.println("[ImportTask] start " + spec.name
            + " source=" + config.sourcePath + " target=" + config.targetTio
            + " inputBytes=" + inputBytes);
        try {
            switch (spec.name) {
            case "mzML"             -> importMzML(sink);
            case "nmrML"            -> importNmrML(sink);
            case "mzTab"            -> importMzTab(sink);
            case "BAM"              -> importBamLike(spec.name, sink);
            case "SAM"              -> importBamLike(spec.name, sink);
            case "CRAM"             -> importBamLike(spec.name, sink);
            case "FASTA"            -> importFasta(sink);
            case "FASTQ"            -> importFastq(sink);
            case "imzML"            -> importImzML(sink);
            case "JCAMP-DX"         -> importJcampDx(sink);
            case "Waters MassLynx"  -> importWatersMassLynx();
            case "Thermo .raw"      -> importThermoRaw();
            case "Bruker timsTOF"   -> importBrukerTimsTOF();
            default -> throw new UnsupportedOperationException(
                spec.name + " import not yet wired -- see "
                + "tio-browser/README.md follow-ups.");
            }
            long t1 = System.currentTimeMillis();
            System.err.println("[ImportTask] dispatch returned after "
                + (t1 - t0) + " ms");
            done.set(true);
            try { ticker.join(1_000L); } catch (InterruptedException ignored) {}
            // For sink-instrumented paths the SDK already fired
            // onProgress(total, total) at the last iteration. For the
            // bytes-fallback path, emit the final 100%.
            if (!sinkActive.get()) emitBytes(inputBytes);
        } finally {
            done.set(true);
            ticker.interrupt();
            updateMessage("Done.");
        }
        return null;
    }

    // -- Existing wired formats ----------------------------------------

    private void importMzML(ProgressSink sink) throws Exception {
        AcquisitionRun run = MzMLReader.read(
            config.sourcePath.toString(), sink);
        writeAnalytical(List.of(run), sink);
    }

    private void importNmrML(ProgressSink sink) throws Exception {
        NmrMLReader.NmrMLResult result =
            NmrMLReader.read(config.sourcePath.toString(), sink);
        writeAnalytical(List.of(result.run()), sink);
    }

    private void importMzTab(ProgressSink sink) throws Exception {
        MzTabReader.MzTabImport im = MzTabReader.read(config.sourcePath, sink);
        // Stage D: thread the sink through to the .tio writer's
        // per-section progress hook too. Stage E (task #68) reshapes
        // the phase math to a 0..50 read / 50..100 write split; for
        // now both sides drive the same units tracker.
        SpectralDataset.create(
            config.targetTio.toString(),
            config.datasetTitle.isEmpty() ? im.title() : config.datasetTitle,
            "",
            List.of(),
            im.identifications(),
            im.quantifications(),
            List.of(),
            sink);
    }

    private void importBamLike(String name, ProgressSink sink) throws Exception {
        WrittenGenomicRun run;
        Path source = config.sourcePath;
        switch (name) {
            case "BAM" -> {
                BamReader r = new BamReader(source);
                run = r.toGenomicRun(config.runName, null, null, sink);
            }
            case "SAM" -> {
                SamReader r = new SamReader(source);
                run = r.toGenomicRun(config.runName, null, null, sink);
            }
            case "CRAM" -> {
                if (config.cramReference == null) {
                    throw new IllegalArgumentException(
                        "CRAM import requires a reference FASTA");
                }
                CramReader r = new CramReader(source, config.cramReference);
                run = r.toGenomicRun(config.runName, null, null, sink);
            }
            default -> throw new IllegalStateException(name);
        }
        writeGenomic(List.of(run), sink);
    }

    private void importFasta(ProgressSink sink) throws Exception {
        FastaReader r = new FastaReader(config.sourcePath);
        if (config.fastaTreatAs == ImportConfig.FastaTreatAs.REFERENCE) {
            ReferenceImport ref = r.readReference();
            SpectralDataset ds = SpectralDataset.create(
                config.targetTio.toString(),
                config.datasetTitle, "",
                List.of(), List.of(), List.of(), List.of());
            try (ds) {
                ref.writeToDataset(ds, /*overwrite=*/false, sink);
            }
        } else {
            // Unaligned reads: thread the sink into the FASTA reader so
            // the dialog reports per-read progress instead of falling
            // back to the bytes heartbeat.
            WrittenGenomicRun run = r.readUnaligned(config.runName, sink);
            writeGenomic(List.of(run), sink);
        }
    }

    private void importFastq(ProgressSink sink) throws Exception {
        FastqReader r = (config.fastqPhred == null)
            ? new FastqReader(config.sourcePath)
            : new FastqReader(config.sourcePath, config.fastqPhred);
        WrittenGenomicRun run = r.read(config.runName, sink);
        writeGenomic(List.of(run), sink);
    }

    // -- Phase 8.x: newly-wired formats --------------------------------

    /**
     * imzML import (continuous mode only).
     *
     * Reads the .imzML + .ibd pair via ImzMLReader, projects pixel
     * spectra into a flat intensity cube, and writes an MSImage group
     * directly via the HDF5 layer.
     */
    private void importImzML(ProgressSink sink) throws Exception {
        ImzMLReader.ImzMLImport imp = ImzMLReader.read(config.sourcePath, sink);
        if (imp.spectra().isEmpty()) {
            throw new IllegalStateException(
                "imzML import: no pixels parsed from " + config.sourcePath);
        }
        if (!"continuous".equals(imp.mode())) {
            throw new UnsupportedOperationException(
                "imzML import: processed mode not yet supported; "
                + "only continuous mode is wired. "
                + "File reports mode=" + imp.mode() + ".");
        }

        int width  = imp.gridMaxX();
        int height = imp.gridMaxY();
        int sp     = imp.spectra().get(0).mz().length;
        double[] mzAxis = imp.spectra().get(0).mz();

        double[] cube = new double[width * height * sp];
        for (ImzMLReader.PixelSpectrum pix : imp.spectra()) {
            int col = pix.x() - 1;  // imzML is 1-indexed
            int row = pix.y() - 1;
            if (row < 0 || row >= height || col < 0 || col >= width) continue;
            double[] pi = pix.intensity();
            int base = (row * width + col) * sp;
            System.arraycopy(pi, 0, cube, base, Math.min(pi.length, sp));
        }

        MSImage img = new MSImage(
            width, height, sp, 0,
            imp.pixelSizeX(), imp.pixelSizeY(),
            imp.scanPattern(),
            cube, mzAxis,
            config.datasetTitle, "",
            List.of(), List.of(), List.of());

        try (StorageProvider provider = ProviderRegistry.open(
                config.targetTio.toString(), StorageProvider.Mode.CREATE)) {
            StorageGroup root = provider.rootGroup();
            FeatureFlags.defaultCurrent().writeTo(root);
            try (StorageGroup study = root.createGroup("study")) {
                if (!config.datasetTitle.isEmpty()) {
                    study.setAttribute("title", config.datasetTitle);
                }
                img.writeTo(study);
            }
        }
    }

    /**
     * JCAMP-DX import.
     *
     * Wraps the single parsed spectrum into a single-spectrum
     * AcquisitionRun. The AcquisitionMode is chosen from the spectrum
     * subclass (Raman, IR, UV-Vis). All named signal arrays from the
     * Spectrum are forwarded as run channels.
     */
    private void importJcampDx(ProgressSink sink) throws Exception {
        Spectrum spectrum = JcampDxReader.readSpectrum(config.sourcePath, sink);

        AcquisitionMode mode;
        if (spectrum instanceof global.thalion.ttio.RamanSpectrum) {
            mode = AcquisitionMode.RAMAN;
        } else if (spectrum instanceof global.thalion.ttio.IRSpectrum) {
            mode = AcquisitionMode.IR;
        } else if (spectrum instanceof global.thalion.ttio.UVVisSpectrum) {
            mode = AcquisitionMode.UV_VIS;
        } else {
            mode = AcquisitionMode.RAMAN;
        }

        Map<String, double[]> channels = new LinkedHashMap<>();
        for (Map.Entry<String, SignalArray> entry
                : spectrum.signalArrays().entrySet()) {
            channels.put(entry.getKey(), entry.getValue().asDoubles());
        }

        int totalPeaks = channels.isEmpty() ? 0
            : channels.values().iterator().next().length;
        SpectrumIndex index = new SpectrumIndex(
            1,
            new long[]   { 0 },
            new int[]    { totalPeaks },
            new double[] { 0.0 },
            new int[]    { 1 },
            new int[]    { 0 },
            new double[] { 0.0 },
            new int[]    { 0 },
            new double[] { 0.0 });

        String runName = (config.runName != null && !config.runName.isEmpty())
            ? config.runName : "spectrum_0001";
        AcquisitionRun run = new AcquisitionRun(
            runName, mode, index,
            new InstrumentConfig("", "", "", "", "", ""),
            channels, List.of(), List.of(), "", 0.0);
        writeAnalytical(List.of(run), sink);
    }

    /**
     * Waters MassLynx import.
     *
     * Delegates to the masslynxraw converter (or the MASSLYNXRAW env
     * var), which emits mzML, then parses via MzMLReader.
     */
    private void importWatersMassLynx() throws Exception {
        AcquisitionRun run =
            WatersMassLynxReader.read(config.sourcePath.toString());
        writeAnalytical(List.of(run), ProgressSink.discard());
    }

    /**
     * Thermo .raw import.
     *
     * Delegates to ThermoRawFileParser (or the THERMORAWFILEPARSER env
     * var), which emits mzML, then parses via MzMLReader.
     */
    private void importThermoRaw() throws Exception {
        AcquisitionRun run =
            ThermoRawReader.read(config.sourcePath.toString());
        writeAnalytical(List.of(run), ProgressSink.discard());
    }

    /**
     * Bruker timsTOF import.
     *
     * Validates the .d directory via SQLite metadata, then delegates
     * binary frame extraction to the Python bruker_tdf_cli helper.
     * Requires Python with ttio[bruker] installed, and either python3
     * on PATH or the TTIO_PYTHON env var set.
     */
    private void importBrukerTimsTOF() throws Exception {
        BrukerTDFReader.read(config.sourcePath, config.targetTio);
    }

    // -- Write helpers --------------------------------------------------

    /** Stage D: writeAnalytical now accepts the same {@link ProgressSink}
     *  the reader was using; the writer's per-section progress reports
     *  flow into the same units tracker. Stage E (task #68) will split
     *  the 0..50 / 50..100 read+write phases — for now both phases drive
     *  the same tracker. */
    private void writeAnalytical(List<AcquisitionRun> runs, ProgressSink sink) {
        SpectralDataset.create(
            config.targetTio.toString(),
            config.datasetTitle,
            "",
            runs,
            List.of(),
            List.of(),
            List.of(),
            sink);
    }

    /** Stage D: writeGenomic with sink threading. See {@link
     *  #writeAnalytical(List, ProgressSink)} for the phase-math
     *  follow-up note. */
    private void writeGenomic(List<WrittenGenomicRun> runs, ProgressSink sink) {
        FeatureFlags flags = new FeatureFlags(
            "1.0", List.of(FeatureFlags.OPT_GENOMIC));
        SpectralDataset.create(
            config.targetTio.toString(),
            config.datasetTitle,
            "",
            List.of(),
            runs,
            List.of(),
            List.of(),
            List.of(),
            flags,
            sink);
    }

    private void emitBytes(long bytesDone) {
        ProgressListener l = progressListener;
        if (l == null || bytesTracker == null) return;
        l.onProgress(bytesTracker.sample(bytesDone, 0L, System.currentTimeMillis()));
    }

    /** Visible for tests -- does the source path point at a real file? */
    static boolean sourceExists(Path p) {
        return p != null && Files.exists(p);
    }
}