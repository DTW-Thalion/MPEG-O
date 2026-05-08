package global.thalion.ttio.browser.exporters;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.UVVisSpectrum;
import global.thalion.ttio.exporters.BamWriter;
import global.thalion.ttio.exporters.CramWriter;
import global.thalion.ttio.exporters.FastaWriter;
import global.thalion.ttio.exporters.FastqWriter;
import global.thalion.ttio.exporters.ISAExporter;
import global.thalion.ttio.exporters.JcampDxEncoding;
import global.thalion.ttio.exporters.JcampDxWriter;
import global.thalion.ttio.exporters.MzMLWriter;
import global.thalion.ttio.exporters.MzTabWriter;
import global.thalion.ttio.exporters.NmrMLWriter;
import global.thalion.ttio.genomics.GenomicIndex;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import javafx.concurrent.Task;

/**
 * Background {@link Task} that writes the open dataset to
 * {@link ExportConfig#targetPath} via the writer dictated by
 * {@link ExportFormatSpec#name}. Mirrors {@link ImportTask}'s
 * dispatch shape on the export side.
 *
 * <p>Phase 9 acceptance set wires:</p>
 * <ul>
 *   <li>mzML (indexed) — one MS run via {@link MzMLWriter}.</li>
 *   <li>nmrML — one analytical run via {@link NmrMLWriter}.</li>
 *   <li>mzTab — identifications + quantifications, dialect chosen
 *       via {@link ExportConfig#mzTabDialect}.</li>
 *   <li>JCAMP-DX — first Raman/IR/UV-Vis spectrum encountered;
 *       AFFN default, PAC/SQZ/DIF gated by encoding extra.</li>
 *   <li>ISA-Tab/JSON — directory-style tab export (extension
 *       {@code .json} switches to JSON serialisation).</li>
 *   <li>BAM / CRAM — first genomic run via {@link BamWriter} /
 *       {@link CramWriter}; reflective {@code GenomicRun ->
 *       WrittenGenomicRun} adapter.</li>
 *   <li>FASTA (reference) / FASTA (reads) — first reference or
 *       genomic run via {@link FastaWriter}.</li>
 *   <li>FASTQ — first genomic run via {@link FastqWriter}.</li>
 * </ul>
 *
 * <p>Stubbed: imzML (requires PixelSpectrum re-projection — Phase 10
 * follow-up).</p>
 */
public final class ExportTask extends Task<Void> {

    private final ExportFormatSpec spec;
    private final ExportConfig config;
    private final SpectralDataset dataset;

    public ExportTask(ExportFormatSpec spec, ExportConfig config,
                      SpectralDataset dataset) {
        this.spec = spec;
        this.config = config;
        this.dataset = dataset;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Exporting " + spec.name + " to " + config.targetPath);
        switch (spec.name) {
            case "mzML (indexed)" -> exportMzML();
            case "mzTab"          -> exportMzTab();
            case "nmrML"          -> exportNmrML();
            case "JCAMP-DX"       -> exportJcampDx();
            case "ISA-Tab/JSON"   -> exportIsa();
            case "BAM"            -> exportBamLike(false);
            case "CRAM"           -> exportBamLike(true);
            case "FASTA (reference)" -> exportFastaReference();
            case "FASTA (reads)"     -> exportFastaReads();
            case "FASTQ"          -> exportFastq();
            case "imzML" -> throw new UnsupportedOperationException(
                "imzML export not yet wired in Phase 9 — requires " +
                "PixelSpectrum re-projection follow-up.");
            default -> throw new UnsupportedOperationException(
                spec.name + " export not wired.");
        }
        updateMessage("Done.");
        return null;
    }

    // ── analytical formats ──────────────────────────────────────────

    private void exportMzML() {
        AcquisitionRun run = pickRun();
        MzMLWriter.write(run, config.targetPath.toString(), true);
    }

    private void exportNmrML() {
        AcquisitionRun run = pickRun();
        NmrMLWriter.write(run, config.targetPath.toString());
    }

    private void exportMzTab() {
        MzTabWriter.write(
            config.targetPath,
            dataset.identifications(),
            dataset.quantifications(),
            config.mzTabDialect,
            dataset.title(),
            "");
    }

    private void exportJcampDx() throws IOException {
        JcampDxEncoding enc = JcampDxEncoding.fromString(config.jcampEncoding);
        for (AcquisitionRun run : dataset.msRuns().values()) {
            for (Spectrum s : run.spectra()) {
                if (s instanceof RamanSpectrum r) {
                    JcampDxWriter.writeRamanSpectrum(r, config.targetPath, dataset.title(), enc);
                    return;
                }
                if (s instanceof IRSpectrum ir) {
                    JcampDxWriter.writeIRSpectrum(ir, config.targetPath, dataset.title(), enc);
                    return;
                }
                if (s instanceof UVVisSpectrum uv) {
                    JcampDxWriter.writeUVVisSpectrum(uv, config.targetPath, dataset.title(), enc);
                    return;
                }
            }
        }
        throw new IllegalStateException(
            "JCAMP-DX export found no Raman / IR / UV-Vis spectrum.");
    }

    private void exportIsa() {
        String name = config.targetPath.getFileName().toString().toLowerCase();
        if (name.endsWith(".json")) {
            try {
                String json = ISAExporter.exportJson(dataset);
                java.nio.file.Files.writeString(config.targetPath, json);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
        } else {
            ISAExporter.exportTab(dataset, config.targetPath);
        }
    }

    // ── genomic formats ─────────────────────────────────────────────

    private void exportBamLike(boolean cram) throws Exception {
        GenomicRun run = pickGenomicRun();
        WrittenGenomicRun w = toWritten(run);
        BamWriter writer;
        if (cram) {
            if (config.cramReference == null) {
                throw new IllegalArgumentException(
                    "CRAM export requires a reference FASTA");
            }
            writer = new CramWriter(config.targetPath, config.cramReference);
        } else {
            writer = new BamWriter(config.targetPath);
        }
        writer.write(w, dataset.provenanceRecords(), true);
    }

    private void exportFastaReference() throws IOException {
        if (dataset.references().isEmpty()) {
            throw new IllegalStateException(
                "FASTA (reference) export found no embedded references.");
        }
        ReferenceImport ref = dataset.references().values().iterator().next();
        FastaWriter.writeReference(ref, config.targetPath,
            config.fastaLineWidth, config.gzipOutput, false);
    }

    private void exportFastaReads() throws IOException {
        GenomicRun run = pickGenomicRun();
        FastaWriter.writeRun(run, config.targetPath,
            config.fastaLineWidth, config.gzipOutput, false);
    }

    private void exportFastq() throws IOException {
        GenomicRun run = pickGenomicRun();
        FastqWriter.write(run, config.targetPath,
            config.gzipOutput, config.fastqPhred);
    }

    // ── helpers ─────────────────────────────────────────────────────

    private AcquisitionRun pickRun() {
        if (dataset.msRuns().isEmpty()) {
            throw new IllegalStateException(
                "Dataset has no analytical runs; cannot export "
                + spec.name + ".");
        }
        if (config.selectedRunName != null
            && dataset.msRuns().containsKey(config.selectedRunName)) {
            return dataset.msRuns().get(config.selectedRunName);
        }
        return dataset.msRuns().values().iterator().next();
    }

    private GenomicRun pickGenomicRun() {
        if (dataset.genomicRuns().isEmpty()) {
            throw new IllegalStateException(
                "Dataset has no genomic runs; cannot export "
                + spec.name + ".");
        }
        if (config.selectedRunName != null
            && dataset.genomicRuns().containsKey(config.selectedRunName)) {
            return dataset.genomicRuns().get(config.selectedRunName);
        }
        return dataset.genomicRuns().values().iterator().next();
    }

    /** Materialise a read-side {@link GenomicRun} into a write-side
     *  {@link WrittenGenomicRun} for BAM / CRAM consumption. */
    static WrittenGenomicRun toWritten(GenomicRun run) {
        int n = run.readCount();
        GenomicIndex idx = run.index();
        long[] positions = new long[n];
        byte[] mapqs     = new byte[n];
        int[]  flags     = new int[n];
        long[] offsets   = new long[n];
        int[]  lengths   = new int[n];
        List<String> chromosomes = new ArrayList<>(n);
        List<String> readNames   = new ArrayList<>(n);
        List<String> cigars      = new ArrayList<>(n);
        List<String> mateChroms  = new ArrayList<>(n);
        long[] matePos   = new long[n];
        int[]  tlens     = new int[n];
        for (int i = 0; i < n; i++) {
            positions[i] = idx.positionAt(i);
            mapqs[i]     = (byte) idx.mappingQualityAt(i);
            flags[i]     = idx.flagsAt(i);
            offsets[i]   = idx.offsetAt(i);
            lengths[i]   = idx.lengthAt(i);
            chromosomes.add(idx.chromosomeAt(i));
            readNames.add(run.readNameAt(i));
            cigars.add(run.cigarAt(i));
            mateChroms.add(run.mateChromAt(i));
            matePos[i]   = run.matePosAt(i);
            tlens[i]     = run.mateTlenAt(i);
        }
        byte[] seqs  = n > 0 ? run.sequencesFull() : new byte[0];
        byte[] quals = n > 0 ? run.qualitiesFull() : new byte[0];
        return new WrittenGenomicRun(
            run.acquisitionMode() != null
                ? run.acquisitionMode() : Enums.AcquisitionMode.GENOMIC_WGS,
            run.referenceUri() != null ? run.referenceUri() : "",
            run.platform() != null ? run.platform() : "",
            run.sampleName() != null ? run.sampleName() : "",
            positions, mapqs, flags,
            seqs, quals,
            offsets, lengths,
            cigars, readNames, mateChroms, matePos, tlens, chromosomes,
            Enums.Compression.NONE
        );
    }
}
