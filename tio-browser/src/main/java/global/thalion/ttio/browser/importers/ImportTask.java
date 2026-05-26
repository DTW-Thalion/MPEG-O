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
import global.thalion.ttio.browser.progress.PhaseProgress;
import global.thalion.ttio.browser.progress.ProgressListener;
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
    /** Stage E: two-phase progress wrapper. Reader callbacks scale
     *  to 0..50%, writer callbacks to 50..100%. The phase label
     *  flips from "reading" to "encoding" at the boundary so the
     *  UI shows which half the percent belongs to. Replaces the
     *  pre-Stage-E single-units-tracker that "restarted" the
     *  records count at the read/write boundary. */
    private PhaseProgress phaseProgress;
    /** Fallback bytes-mode tracker for not-yet-sink-instrumented
     *  formats (Waters / Thermo / Bruker -- where SDK delegates
     *  to external converters with no per-record hook). Driven by
     *  the heartbeat ticker which polls target file size. Removed
     *  in Stage E commit 2 once all formats have real callbacks. */
    private ProgressTracker bytesTracker;
    /** Set true by PhaseProgress callbacks; gates the heartbeat
     *  ticker so it stands down once real records-based progress
     *  is flowing. */
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
        // Fallback bytes-mode tracker for the heartbeat path
        // (Waters / Thermo / Bruker formats with no per-record
        // hook -- they go through external converters). Real
        // sink-instrumented formats flip sinkActive=true on first
        // emit and the heartbeat stands down. Stage E commit 2
        // removes this fallback entirely.
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

        // Stage E: two-phase progress. Reader fills 0..50%; writer
        // fills 50..100%. PhaseProgress flips sinkActive=true on
        // first emit so the heartbeat ticker stands down.
        // PhaseProgress fetches the listener via a small forwarder
        // so setProgressListener() calls after call() begins still
        // take effect (preserves the pre-Stage-E behavior).
        ProgressListener forwarder = r -> {
            sinkActive.set(true);
            ProgressListener l = progressListener;
            if (l != null) l.onProgress(r);
        };
        phaseProgress = new PhaseProgress(
            forwarder, "reading", "encoding", startMs);

        ProgressSink readerSink = phaseProgress.readerSink();
        ProgressSink writerSink = phaseProgress.writerSink();

        long t0 = System.currentTimeMillis();
        System.err.println("[ImportTask] start " + spec.name
            + " source=" + config.sourcePath + " target=" + config.targetTio
            + " inputBytes=" + inputBytes);
        try {
            switch (spec.name) {
            case "mzML"             -> importMzML(readerSink, writerSink);
            case "nmrML"            -> importNmrML(readerSink, writerSink);
            case "mzTab"            -> importMzTab(readerSink, writerSink);
            case "BAM"              -> importBamLike(spec.name, readerSink, writerSink);
            case "SAM"              -> importBamLike(spec.name, readerSink, writerSink);
            case "CRAM"             -> importBamLike(spec.name, readerSink, writerSink);
            case "FASTA"            -> importFasta(readerSink, writerSink);
            case "FASTQ"            -> importFastq(readerSink, writerSink);
            case "imzML"            -> importImzML(readerSink);
            case "JCAMP-DX"         -> importJcampDx(readerSink, writerSink);
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
            if (sinkActive.get()) {
                // Sink-instrumented format: emit final 100% via
                // PhaseProgress so the bar terminates cleanly.
                phaseProgress.emitFinal();
            } else {
                // Bytes-fallback path: emit the final input-size
                // bytes-done sample.
                emitBytes(inputBytes);
            }
        } finally {
            done.set(true);
            ticker.interrupt();
            updateMessage("Done.");
        }
        return null;
    }

    // -- Existing wired formats ----------------------------------------

    private void importMzML(ProgressSink readerSink, ProgressSink writerSink)
            throws Exception {
        AcquisitionRun run = MzMLReader.read(
            config.sourcePath.toString(), readerSink);
        writeAnalytical(List.of(run), writerSink);
    }

    private void importNmrML(ProgressSink readerSink, ProgressSink writerSink)
            throws Exception {
        NmrMLReader.NmrMLResult result =
            NmrMLReader.read(config.sourcePath.toString(), readerSink);
        writeAnalytical(List.of(result.run()), writerSink);
    }

    private void importMzTab(ProgressSink readerSink, ProgressSink writerSink)
            throws Exception {
        MzTabReader.MzTabImport im =
            MzTabReader.read(config.sourcePath, readerSink);
        // Stage E: writer-side sink is a separate scaled half so the
        // dialog's percent stays monotonic across the read/write
        // boundary (PhaseProgress.writerSink maps onto 50..100%).
        SpectralDataset.create(
            config.targetTio.toString(),
            config.datasetTitle.isEmpty() ? im.title() : config.datasetTitle,
            "",
            List.of(),
            im.identifications(),
            im.quantifications(),
            List.of(),
            writerSink);
    }

    private void importBamLike(String name,
                               ProgressSink readerSink,
                               ProgressSink writerSink) throws Exception {
        WrittenGenomicRun run;
        Path source = config.sourcePath;
        switch (name) {
            case "BAM" -> {
                BamReader r = new BamReader(source);
                run = r.toGenomicRun(config.runName, null, null, readerSink);
            }
            case "SAM" -> {
                SamReader r = new SamReader(source);
                run = r.toGenomicRun(config.runName, null, null, readerSink);
            }
            case "CRAM" -> {
                if (config.cramReference == null) {
                    throw new IllegalArgumentException(
                        "CRAM import requires a reference FASTA");
                }
                CramReader r = new CramReader(source, config.cramReference);
                run = r.toGenomicRun(config.runName, null, null, readerSink);
            }
            default -> throw new IllegalStateException(name);
        }
        writeGenomic(List.of(run), writerSink);
    }

    private void importFasta(ProgressSink readerSink, ProgressSink writerSink)
            throws Exception {
        FastaReader r = new FastaReader(config.sourcePath);
        if (config.fastaTreatAs == ImportConfig.FastaTreatAs.REFERENCE) {
            ReferenceImport ref = r.readReference();
            SpectralDataset ds = SpectralDataset.create(
                config.targetTio.toString(),
                config.datasetTitle, "",
                List.of(), List.of(), List.of(), List.of());
            try (ds) {
                ref.writeToDataset(ds, /*overwrite=*/false, writerSink);
            }
        } else {
            // Unaligned reads: reader fills 0..50%, writer fills 50..100%.
            WrittenGenomicRun run = r.readUnaligned(config.runName, readerSink);
            writeGenomic(List.of(run), writerSink);
        }
    }

    private void importFastq(ProgressSink readerSink, ProgressSink writerSink)
            throws Exception {
        FastqReader r = (config.fastqPhred == null)
            ? new FastqReader(config.sourcePath)
            : new FastqReader(config.sourcePath, config.fastqPhred);
        WrittenGenomicRun run = r.read(config.runName, readerSink);
        writeGenomic(List.of(run), writerSink);
    }

    // -- Phase 8.x: newly-wired formats --------------------------------

    /**
     * imzML import (continuous mode only).
     *
     * Reads the .imzML + .ibd pair via ImzMLReader, projects pixel
     * spectra into a flat intensity cube, and writes an MSImage group
     * directly via the HDF5 layer.
     */
    private void importImzML(ProgressSink readerSink) throws Exception {
        // imzML uses the HDF5 layer directly (not SpectralDataset.create),
        // so there is no writer-side ProgressSink hook -- the reader
        // alone drives the percent into the 0..50 read half, and the
        // PhaseProgress.emitFinal() in call() finishes it at 100%.
        ImzMLReader.ImzMLImport imp = ImzMLReader.read(config.sourcePath, readerSink);
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
    private void importJcampDx(ProgressSink readerSink, ProgressSink writerSink)
            throws Exception {
        Spectrum spectrum = JcampDxReader.readSpectrum(config.sourcePath, readerSink);

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
        writeAnalytical(List.of(run), writerSink);
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

    /** Stage D: writeAnalytical accepts the writer-half {@link
     *  ProgressSink} from {@link PhaseProgress#writerSink()}; the
     *  writer's per-section progress flows into the 50..100% half of
     *  the unified bar. */
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
     *  #writeAnalytical(List, ProgressSink)} for the two-phase note. */
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