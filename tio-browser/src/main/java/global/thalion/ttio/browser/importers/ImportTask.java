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
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
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
import global.thalion.ttio.providers.Hdf5Provider;
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

    public ImportTask(ImportFormatSpec spec, ImportConfig config) {
        this.spec = spec;
        this.config = config;
    }

    @Override
    protected Void call() throws Exception {
        updateMessage("Importing " + spec.name + " from " + config.sourcePath);
        switch (spec.name) {
            case "mzML"             -> importMzML();
            case "nmrML"            -> importNmrML();
            case "mzTab"            -> importMzTab();
            case "BAM"              -> importBamLike(spec.name);
            case "SAM"              -> importBamLike(spec.name);
            case "CRAM"             -> importBamLike(spec.name);
            case "FASTA"            -> importFasta();
            case "FASTQ"            -> importFastq();
            case "imzML"            -> importImzML();
            case "JCAMP-DX"         -> importJcampDx();
            case "Waters MassLynx"  -> importWatersMassLynx();
            case "Thermo .raw"      -> importThermoRaw();
            case "Bruker timsTOF"   -> importBrukerTimsTOF();
            default -> throw new UnsupportedOperationException(
                spec.name + " import not yet wired -- see "
                + "tio-browser/README.md follow-ups.");
        }
        updateMessage("Done.");
        return null;
    }

    // -- Existing wired formats ----------------------------------------

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
            SpectralDataset ds = SpectralDataset.create(
                config.targetTio.toString(),
                config.datasetTitle, "",
                List.of(), List.of(), List.of(), List.of());
            try (ds) {
                ref.writeToDataset(ds);
            }
        } else {
            WrittenGenomicRun run = r.readUnaligned(config.runName);
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

    // -- Phase 8.x: newly-wired formats --------------------------------

    /**
     * imzML import (continuous mode only).
     *
     * Reads the .imzML + .ibd pair via ImzMLReader, projects pixel
     * spectra into a flat intensity cube, and writes an MSImage group
     * directly via the HDF5 layer.
     */
    private void importImzML() throws Exception {
        ImzMLReader.ImzMLImport imp = ImzMLReader.read(config.sourcePath);
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

        try (Hdf5File f = Hdf5File.create(config.targetTio.toString());
             Hdf5Group root = f.rootGroup()) {
            FeatureFlags.defaultCurrent().writeTo(root);
            try (Hdf5Group study = root.createGroup("study")) {
                if (!config.datasetTitle.isEmpty()) {
                    study.setStringAttribute("title", config.datasetTitle);
                }
                img.writeTo(Hdf5Provider.adapterForGroup(study));
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
    private void importJcampDx() throws Exception {
        Spectrum spectrum = JcampDxReader.readSpectrum(config.sourcePath);

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
        writeAnalytical(List.of(run));
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
        writeAnalytical(List.of(run));
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
        writeAnalytical(List.of(run));
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

    /** Visible for tests -- does the source path point at a real file? */
    static boolean sourceExists(Path p) {
        return p != null && Files.exists(p);
    }
}