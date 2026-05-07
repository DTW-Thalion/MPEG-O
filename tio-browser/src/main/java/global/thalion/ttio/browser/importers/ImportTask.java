package global.thalion.ttio.browser.importers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.importers.CramReader;
import global.thalion.ttio.importers.FastaReader;
import global.thalion.ttio.importers.FastqReader;
import global.thalion.ttio.importers.MzMLReader;
import global.thalion.ttio.importers.MzTabReader;
import global.thalion.ttio.importers.NmrMLReader;
import global.thalion.ttio.importers.SamReader;
import javafx.concurrent.Task;

/**
 * Background {@link Task} that runs the chosen importer and writes the
 * result to {@link ImportConfig#targetTio} as a fresh {@code .tio}.
 *
 * <p>Per-format dispatch on {@link ImportFormatSpec#name}. Wired
 * formats (Phase 8 acceptance-gate set):</p>
 * <ul>
 *   <li>mzML — produces a single {@code AcquisitionRun}.</li>
 *   <li>nmrML — produces a single {@code AcquisitionRun} (FID and
 *       acquisition params live on the run via the result wrapper).</li>
 *   <li>mzTab — produces identifications + quantifications, no run.</li>
 *   <li>BAM / SAM / CRAM — produces a {@code WrittenGenomicRun}
 *       via {@code samtools}; CRAM requires
 *       {@link ImportConfig#cramReference}.</li>
 *   <li>FASTA — reference-mode embeds a {@code ReferenceImport};
 *       unaligned-reads mode produces a {@code WrittenGenomicRun}.</li>
 *   <li>FASTQ — produces a {@code WrittenGenomicRun}; Phred offset
 *       auto-detected unless {@link ImportConfig#fastqPhred} is set.</li>
 * </ul>
 *
 * <p>Stubbed formats (raise on attempt — follow-up):
 * imzML, JCAMP-DX, Bruker timsTOF, Waters MassLynx, Thermo .raw.</p>
 */
public final class ImportTask extends Task<Void> {

    private final ImportFormatSpec spec;
    private final ImportConfig config;

    public ImportTask(ImportFormatSpec spec, ImportConfig config) {
        this.spec = spec;
        this.config = config;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Importing " + spec.name + " from " + config.sourcePath);
        switch (spec.name) {
            case "mzML"  -> importMzML();
            case "nmrML" -> importNmrML();
            case "mzTab" -> importMzTab();
            case "BAM"   -> importBamLike(spec.name);
            case "SAM"   -> importBamLike(spec.name);
            case "CRAM"  -> importBamLike(spec.name);
            case "FASTA" -> importFasta();
            case "FASTQ" -> importFastq();
            default -> throw new UnsupportedOperationException(
                spec.name + " import not yet wired in Phase 8 — see "
                + "tio-browser/README.md follow-ups.");
        }
        updateMessage("Done.");
        return null;
    }

    private void importMzML() throws Exception {
        AcquisitionRun run = MzMLReader.read(config.sourcePath.toString());
        writeAnalytical(List.of(run));
    }

    private void importNmrML() throws Exception {
        NmrMLReader.NmrMLResult result =
            NmrMLReader.read(config.sourcePath.toString());
        writeAnalytical(List.of(result.run()));
    }

    private void importMzTab() throws Exception {
        MzTabReader.MzTabImport im = MzTabReader.read(config.sourcePath);
        SpectralDataset.create(
            config.targetTio.toString(),
            config.datasetTitle.isEmpty() ? im.title() : config.datasetTitle,
            "",
            List.of(),
            im.identifications(),
            im.quantifications(),
            List.of());
    }

    private void importBamLike(String name) throws Exception {
        WrittenGenomicRun run;
        Path source = config.sourcePath;
        switch (name) {
            case "BAM" -> {
                BamReader r = new BamReader(source);
                run = r.toGenomicRun(config.runName);
            }
            case "SAM" -> {
                SamReader r = new SamReader(source);
                run = r.toGenomicRun(config.runName);
            }
            case "CRAM" -> {
                if (config.cramReference == null) {
                    throw new IllegalArgumentException(
                        "CRAM import requires a reference FASTA");
                }
                CramReader r = new CramReader(source, config.cramReference);
                run = r.toGenomicRun(config.runName);
            }
            default -> throw new IllegalStateException(name);
        }
        writeGenomic(List.of(run));
    }

    private void importFasta() throws Exception {
        FastaReader r = new FastaReader(config.sourcePath);
        if (config.fastaTreatAs == ImportConfig.FastaTreatAs.REFERENCE) {
            ReferenceImport ref = r.readReference();
            // Create an empty dataset, then embed the reference.
            SpectralDataset ds = SpectralDataset.create(
                config.targetTio.toString(),
                config.datasetTitle, "",
                List.of(), List.of(), List.of(), List.of());
            try (ds) {
                ref.writeToDataset(ds);
            }
        } else {
            WrittenGenomicRun run =
                r.readUnaligned(config.runName);
            writeGenomic(List.of(run));
        }
    }

    private void importFastq() throws Exception {
        FastqReader r = (config.fastqPhred == null)
            ? new FastqReader(config.sourcePath)
            : new FastqReader(config.sourcePath, config.fastqPhred);
        WrittenGenomicRun run = r.read(config.runName);
        writeGenomic(List.of(run));
    }

    private void writeAnalytical(List<AcquisitionRun> runs) {
        SpectralDataset.create(
            config.targetTio.toString(),
            config.datasetTitle,
            "",
            runs,
            List.of(),
            List.of(),
            List.of());
    }

    private void writeGenomic(List<WrittenGenomicRun> runs) {
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
            flags);
    }

    /** Visible for tests — does the source path point at a real file? */
    static boolean sourceExists(Path p) {
        return p != null && Files.exists(p);
    }
}
