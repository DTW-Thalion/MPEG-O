package global.thalion.ttio.browser.importers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.FastaReader;
import global.thalion.ttio.importers.FastqReader;
import global.thalion.ttio.importers.ImportedDataset;
import global.thalion.ttio.importers.ImporterRegistry;
import global.thalion.ttio.browser.SdkFormatKeys;
import global.thalion.ttio.browser.progress.PhaseProgress;
import global.thalion.ttio.browser.progress.ProgressListener;
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
        long startMs = System.currentTimeMillis();
        // Stage E commit 2: the previous bytes-heartbeat ticker has
        // been removed. Stages A/B/C/D wired real record-level
        // ProgressSink callbacks across every reader + writer, so
        // the heartbeat is no longer needed -- the ProgressDisplay
        // refresh now responds purely to real ProgressSink samples
        // flowing through PhaseProgress.
        //
        // The three formats that still delegate to external
        // converters (Waters MassLynx, Thermo .raw, Bruker timsTOF)
        // run in a tight subprocess wait without intermediate
        // updates; the dialog stays at 0% until the subprocess
        // returns, at which point emitFinal() drives it to 100%.
        //
        // PhaseProgress fetches the listener via a small forwarder
        // so setProgressListener() calls after call() begins still
        // take effect (preserves the pre-Stage-E behavior).
        ProgressListener forwarder = r -> {
            ProgressListener l = progressListener;
            if (l != null) l.onProgress(r);
        };
        phaseProgress = new PhaseProgress(
            forwarder, "reading", "encoding", startMs);
        phaseProgress.emitInitial();

        ProgressSink readerSink = phaseProgress.readerSink();
        ProgressSink writerSink = phaseProgress.writerSink();

        long t0 = System.currentTimeMillis();
        System.err.println("[ImportTask] start " + spec.name
            + " source=" + config.sourcePath + " target=" + config.targetTio);
        try {
            // PR-J2/GT3: the 11 registry-covered formats dispatch through
            // the SDK ImporterRegistry -> Reader.read(...) -> draft.write().
            // The reader is handed the 0..50% readerSink and the write the
            // 50..100% writerSink, so the two-phase progress UX is preserved
            // exactly as the deleted per-format importX bodies did.
            // fasta/fastq stay GUI-local (richer wizard-driven behavior).
            String key = SdkFormatKeys.importKey(spec.name);
            if (key != null) {
                importViaRegistry(key, readerSink, writerSink);
            } else {
                switch (spec.name) {
                case "FASTA" -> importFasta(readerSink, writerSink);
                case "FASTQ" -> importFastq(readerSink, writerSink);
                default -> throw new UnsupportedOperationException(
                    spec.name + " import not yet wired -- see "
                    + "tio-browser/README.md follow-ups.");
                }
            }
            long t1 = System.currentTimeMillis();
            System.err.println("[ImportTask] dispatch returned after "
                + (t1 - t0) + " ms");
            // Emit a final 100% sample so the dialog always
            // terminates at the full bar, regardless of whether
            // the writer SDK fired its own terminal (T, T) sample.
            phaseProgress.emitFinal();
        } finally {
            updateMessage("Done.");
        }
        return null;
    }

    // -- Registry dispatch (PR-J2/GT3) ---------------------------------

    /**
     * Dispatch a registry-covered format through the SDK importer
     * registry, preserving the two-phase progress UX.
     *
     * <p>The SDK {@link global.thalion.ttio.importers.Reader} parses the
     * source into an {@link ImportedDataset} draft (reader phase, 0..50%
     * via {@code readerSink}); {@link ImportedDataset#write} then writes
     * the {@code .tio} (writer phase, 50..100% via {@code writerSink}).
     * This is the exact reader/writer split the deleted per-format
     * {@code importX} bodies implemented.</p>
     *
     * <p>imzML now routes its {@code MSImage} through the SDK adapter +
     * the image-aware {@link SpectralDataset#create} create path (same
     * {@code MSImage.writeTo}) rather than the GUI's former raw-HDF5
     * write; the result is byte-identical.</p>
     */
    private void importViaRegistry(String key,
                                   ProgressSink readerSink,
                                   ProgressSink writerSink) throws Exception {
        Map<String, Object> opts = importOpts();
        List<String> inputs = importInputs();
        ImportedDataset draft = ImporterRegistry.specFor(key).reader()
            .read(inputs, opts, readerSink);
        if (config.datasetTitle != null && !config.datasetTitle.isEmpty()) {
            draft.title = config.datasetTitle;
        }
        draft.write(config.targetTio, writerSink);
    }

    /**
     * Build the SDK opts map from {@link ImportConfig}. Only non-null /
     * non-empty values are added. {@code name} feeds the genomic
     * (BAM/SAM/CRAM) + JCAMP-DX adapters' run name (matching the GUI's
     * former {@code config.runName} threading); {@code reference} feeds
     * the CRAM adapter. Adapters that ignore a key (e.g. mzML) simply do
     * not read it. imzML's {@code .ibd} is auto-located by the adapter
     * from the {@code .imzML} sibling, so no {@code ibd} opt is supplied.
     */
    private Map<String, Object> importOpts() {
        Map<String, Object> opts = new LinkedHashMap<>();
        if (config.runName != null && !config.runName.isEmpty()) {
            opts.put("name", config.runName);
        }
        if (config.cramReference != null) {
            opts.put("reference", config.cramReference);
        }
        return opts;
    }

    /** Primary source path as the single SDK input. */
    private List<String> importInputs() {
        return List.of(config.sourcePath.toString());
    }

    // -- GUI-local formats (fasta/fastq) -------------------------------

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
        // Streamed: the reader's batches feed the blocks_v1 writer, so a
        // FASTQ of any size never sits in memory whole. Reader progress
        // (per batch) fills 0..50%, the writer 50..100%.
        ImportedDataset draft = new ImportedDataset();
        draft.title = config.datasetTitle == null ? "" : config.datasetTitle;
        draft.genomicStreams.put("genomic_0001", r.stream("genomic_0001", config.runName));
        draft.write(config.targetTio, writerSink);
    }

    // -- Write helpers --------------------------------------------------

    /** Stage D: writeGenomic with sink threading -- the writer's
     *  per-section progress flows into the 50..100% half of the unified
     *  bar via {@link PhaseProgress#writerSink()}. Retained for the
     *  GUI-local fasta/fastq paths (the registry-covered formats write
     *  through {@link ImportedDataset#write}). */
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

    /** Visible for tests -- does the source path point at a real file? */
    static boolean sourceExists(Path p) {
        return p != null && Files.exists(p);
    }
}