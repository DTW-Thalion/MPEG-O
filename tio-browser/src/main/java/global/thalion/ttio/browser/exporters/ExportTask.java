package global.thalion.ttio.browser.exporters;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

import global.thalion.ttio.Enums;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.ExporterRegistry;
import global.thalion.ttio.exporters.FastaWriter;
import global.thalion.ttio.exporters.FastqWriter;
import global.thalion.ttio.exporters.RunSelection;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.browser.SdkFormatKeys;
import global.thalion.ttio.browser.progress.PhaseProgress;
import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.io.ProgressSink;
import javafx.concurrent.Task;

/**
 * Background {@link Task} that writes the open dataset to
 * {@link ExportConfig#targetPath} via the writer dictated by
 * {@link ExportFormatSpec#name}. Mirrors {@link ImportTask}'s
 * dispatch shape on the export side.
 *
 * <p><b>PR-J2 GT4:</b> the eight registry-covered rows
 * ("mzML (indexed)", "mzTab", "nmrML", "imzML", "JCAMP-DX",
 * "ISA-Tab/JSON", "BAM", "CRAM") now dispatch through the SDK
 * {@link ExporterRegistry} {@code Writer} adapters via
 * {@link SdkFormatKeys#exportKey} — the GUI no longer carries a private
 * copy of each writer call (or of the {@code GenomicRun ->
 * WrittenGenomicRun} materialisation, which moved to
 * {@link RunSelection#toWritten}). Per-format knobs reach the writer
 * through {@link #exportOpts()} ({@code dialect}, {@code mode},
 * {@code encoding}, {@code reference}).</p>
 *
 * <p>The three GUI-local rows stay here because their export knobs
 * ({@link ExportConfig#fastaLineWidth}, {@link ExportConfig#gzipOutput},
 * {@link ExportConfig#fastqPhred}) have no SDK-registry equivalent —
 * {@code fasta}/{@code fastq} are {@link ExporterRegistry#CLI_DELEGATED},
 * not registered:</p>
 * <ul>
 *   <li>FASTA (reference) / FASTA (reads) — first reference or
 *       genomic run via {@link FastaWriter}.</li>
 *   <li>FASTQ — first genomic run via {@link FastqWriter}.</li>
 * </ul>
 *
 * <p>Note: the SDK {@code Writer.write} has no {@link ProgressSink}
 * parameter, so registry-dispatched exports no longer emit per-section
 * writer progress. The progress bar still completes: the reader phase
 * fires its 50% boundary sample and {@link PhaseProgress#emitFinal()}
 * advances it to 100% after the writer returns.</p>
 */
public final class ExportTask extends Task<Void> {

    private final ExportFormatSpec spec;
    private final ExportConfig config;
    private final SpectralDataset dataset;
    private volatile ProgressListener progressListener;
    /** Stage E: two-phase progress wrapper. The .tio source-read
     *  side fills 0..50% and the target-format writer fills
     *  50..100%. Replaces the pre-Stage-E single-units-tracker
     *  that "restarted" the records count at the read/write
     *  boundary. */
    private PhaseProgress phaseProgress;

    public ExportTask(ExportFormatSpec spec, ExportConfig config,
                      SpectralDataset dataset) {
        this.spec = spec;
        this.config = config;
        this.dataset = dataset;
    }

    public void setProgressListener(ProgressListener listener) {
        this.progressListener = listener;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Exporting " + spec.name + " to " + config.targetPath);
        long startMs = System.currentTimeMillis();
        // Stage E commit 2: the previous bytes-heartbeat ticker has
        // been removed. Stages C/D wired real record-level
        // ProgressSink callbacks across every writer, so the
        // heartbeat is no longer needed -- the ProgressDisplay
        // refresh now responds purely to real ProgressSink samples
        // flowing through PhaseProgress.
        //
        // ISA-Tab/JSON, which writes via java.nio.Files.writeString
        // rather than through a sink-instrumented SDK call, will
        // stay at the 50% phase boundary throughout its (typically
        // sub-second) write and then advance to 100% via the
        // emitFinal() at the end of call(). Not worth resurrecting
        // the heartbeat for that one case.
        //
        // PhaseProgress fetches the listener via a small forwarder
        // so setProgressListener() calls after call() begins still
        // take effect (preserves the pre-Stage-E behavior).
        ProgressListener forwarder = r -> {
            ProgressListener l = progressListener;
            if (l != null) l.onProgress(r);
        };
        phaseProgress = new PhaseProgress(
            forwarder, "reading", "writing", startMs);
        phaseProgress.emitInitial();

        // Reader phase: opening + materialising the source data
        // happens inside pickRun() / pickGenomicRun() / imageForKind()
        // which are synchronous-fast and don't fire ProgressSink
        // callbacks (the dataset is already open before ExportTask
        // runs). Fire a single (1, 1) reader sample so the bar
        // advances to the 50% phase boundary before the writer
        // starts; the phase label flips from "reading" to "writing".
        // Future enhancement: thread a reader-side sink through
        // SpectralDataset section loads.
        ProgressSink readerSink = phaseProgress.readerSink();
        ProgressSink writerSink = phaseProgress.writerSink();
        readerSink.onProgress(1L, 1L);

        try {
            String key = SdkFormatKeys.exportKey(spec.name);
            if (key != null) {
                // Preserve the GUI's pinned imzML "no image" contract:
                // the SDK ImzMLWriterAdapter raises IllegalArgumentException
                // ("dataset has no MS image..."), but the tio-browser dialog
                // (and ExportTaskTest.imzMLOnNonImageDatasetRaisesIllegalState)
                // expects IllegalStateException mentioning "image_cube".
                // Guard here, then let the adapter do the real write so the
                // imzMlMode knob is still honored via exportOpts().
                if ("imzml".equals(key)
                        && dataset.imageForKind(Enums.ImageKind.MS) == null) {
                    throw new IllegalStateException(
                        "imzML export requires an MSImage in /study/image_cube; "
                        + "this .tio has none.");
                }
                // Registry-covered: dispatch to the SDK Writer adapter
                // against the already-open dataset. The SDK Writer has no
                // ProgressSink param — writerSink stays unused here; the
                // bar reaches 100% via emitFinal() below.
                ExporterRegistry.specFor(key).writer().write(
                    dataset, config.selectedRunName, config.targetPath,
                    exportOpts());
            } else {
                switch (spec.name) {
                    case "FASTA (reference)" -> exportFastaReference(writerSink);
                    case "FASTA (reads)"     -> exportFastaReads(writerSink);
                    case "FASTQ"          -> exportFastq(writerSink);
                    default -> throw new UnsupportedOperationException(
                        spec.name + " export not wired.");
                }
            }
            // Always emit a final 100% sample so the dialog
            // terminates at the full bar (the writer SDK already
            // fired its terminal (T, T) for instrumented formats,
            // but ISA-Tab/JSON has no sink and stays mid-bar).
            phaseProgress.emitFinal();
        } finally {
            updateMessage("Done.");
        }
        return null;
    }

    /**
     * Build the SDK {@code Writer} opts map from this export's config,
     * including only the knobs the registry writer adapters honor and only
     * when non-null. Unknown opts are ignored by the adapters, so threading
     * every registry-covered config knob here is safe:
     * <ul>
     *   <li>{@code dialect} — {@code MzTabWriterAdapter} (mzTab version)</li>
     *   <li>{@code mode} — {@code ImzMLWriterAdapter} (continuous/processed)</li>
     *   <li>{@code encoding} — {@code JcampDxWriterAdapter} (AFFN/PAC/SQZ/DIF)</li>
     *   <li>{@code reference} — {@code CramWriterAdapter} (CRAM reference FASTA)</li>
     * </ul>
     * The GUI-only fasta/fastq knobs ({@code fastaLineWidth},
     * {@code gzipOutput}, {@code fastqPhred}) are intentionally absent — no
     * registry writer honors them, so the fasta/fastq rows stay GUI-local
     * (below) rather than silently dropping those options.
     */
    private Map<String, Object> exportOpts() {
        Map<String, Object> opts = new LinkedHashMap<>();
        if (config.mzTabDialect != null)  opts.put("dialect", config.mzTabDialect);
        if (config.imzMlMode != null)     opts.put("mode", config.imzMlMode);
        if (config.jcampEncoding != null) opts.put("encoding", config.jcampEncoding);
        if (config.cramReference != null) opts.put("reference", config.cramReference);
        return opts;
    }

    // ── GUI-local genomic formats (no SDK-registry equivalent) ──────
    // fasta/fastq are ExporterRegistry.CLI_DELEGATED, not registered, and
    // their wrap-width / gzip / phred knobs have no Writer-adapter opt.
    // Run selection uses the shared SDK RunSelection (the GUI's private
    // pickRun/pickGenomicRun/toWritten were removed in GT4).

    private void exportFastaReference(ProgressSink sink) throws IOException {
        if (dataset.references().isEmpty()) {
            throw new IllegalStateException(
                "FASTA (reference) export found no embedded references.");
        }
        ReferenceImport ref = dataset.references().values().iterator().next();
        FastaWriter.writeReference(ref, config.targetPath,
            config.fastaLineWidth, config.gzipOutput, false, sink);
    }

    private void exportFastaReads(ProgressSink sink) throws IOException {
        GenomicRun run = RunSelection.genomicRun(dataset, config.selectedRunName);
        FastaWriter.writeRun(run, config.targetPath,
            config.fastaLineWidth, config.gzipOutput, false, sink);
    }

    private void exportFastq(ProgressSink sink) throws IOException {
        GenomicRun run = RunSelection.genomicRun(dataset, config.selectedRunName);
        FastqWriter.write(run, config.targetPath,
            config.gzipOutput, config.fastqPhred, sink);
    }

}
