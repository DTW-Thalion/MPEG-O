package global.thalion.ttio.browser.exporters;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.Enums;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;
import global.thalion.ttio.browser.importers.ImportConfig;
import global.thalion.ttio.browser.importers.ImportFormatRegistry;
import global.thalion.ttio.browser.importers.ImportFormatSpec;
import global.thalion.ttio.browser.importers.ImportTask;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

class ExportTaskTest {

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS),
            "JavaFX toolkit did not start");
    }

    private static ExportFormatSpec exportSpec(String name) {
        return ExportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst().orElseThrow();
    }

    private static ImportFormatSpec importSpec(String name) {
        return ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(name))
            .findFirst().orElseThrow();
    }

    private static <T extends javafx.concurrent.Task<?>> void runAndWait(T task)
            throws InterruptedException {
        var exec = Executors.newSingleThreadExecutor();
        exec.submit(task);
        exec.shutdown();
        assertTrue(exec.awaitTermination(120, TimeUnit.SECONDS),
            "task did not finish within 120s");
    }

    private static boolean samtoolsAvailable() {
        try {
            Process p = new ProcessBuilder("samtools", "--version")
                .redirectErrorStream(true).start();
            p.waitFor(5, TimeUnit.SECONDS);
            return p.exitValue() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    /** True iff libttio_rans_jni resolves via {@code java.library.path}.
     *  BAM round-trip needs the NAME_TOKENIZED_V2 codec which has no
     *  pure-Java fallback in v1.0+. */
    private static boolean nativeLibraryAvailable() {
        try {
            global.thalion.ttio.browser.util.NativeLibraryLoader.ensureRansJni();
            return global.thalion.ttio.browser.util.NativeLibraryLoader.isLoaded();
        } catch (Throwable t) {
            return false;
        }
    }

    @Test
    void mzMLRoundTrip(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
            .toAbsolutePath();
        Path mzml = tmp.resolve("out.mzML");
        Path reTio = tmp.resolve("re.tio");
        Path origTio = tmp.resolve("orig.tio");

        // import source mzML -> orig.tio
        ImportTask imp = new ImportTask(importSpec("mzML"),
            ImportConfig.basic(src, origTio, "hdf5", "run_0001", "tiny pwiz"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("import failed: " + ee.getCause(), ee.getCause());
        }

        // export orig.tio -> mzml
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            ExportTask exp = new ExportTask(exportSpec("mzML (indexed)"),
                ExportConfig.basic(mzml), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(mzml));

        // re-import mzml -> re.tio
        ImportTask imp2 = new ImportTask(importSpec("mzML"),
            ImportConfig.basic(mzml, reTio, "hdf5", "run_0001", "round-trip"));
        runAndWait(imp2);
        try { imp2.get(); } catch (ExecutionException ee) {
            fail("re-import failed: " + ee.getCause(), ee.getCause());
        }

        try (SpectralDataset orig = SpectralDataset.open(origTio.toString());
             SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            assertEquals(orig.msRuns().size(), round.msRuns().size());
            AcquisitionRun ro = orig.msRuns().values().iterator().next();
            AcquisitionRun rr = round.msRuns().values().iterator().next();
            assertEquals(ro.spectra().size(), rr.spectra().size());
            // Spot-check intensity arrays of first MS spectrum.
            MassSpectrum mso = (MassSpectrum) ro.spectra().get(0);
            MassSpectrum msr = (MassSpectrum) rr.spectra().get(0);
            assertArrayEquals(mso.intensityValues(), msr.intensityValues(), 1e-9,
                "first-spectrum intensity mismatch after mzML round-trip");
        }
    }

    @Test
    void fastqRoundTripFromBamFixture(@TempDir Path tmp) throws Exception {
        assumeTrue(samtoolsAvailable(), "samtools not on PATH");
        assumeTrue(nativeLibraryAvailable(),
            "libttio_rans_jni not loadable; skip BAM round-trip");
        Path bam = Paths.get("../java/src/test/resources/ttio/fixtures/genomic/m87_test.bam")
            .toAbsolutePath();
        Path origTio = tmp.resolve("orig.tio");

        ImportTask imp = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bam, origTio, "hdf5", "run_0001", "m87"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("BAM import failed: " + ee.getCause(), ee.getCause());
        }

        Path fastq = tmp.resolve("out.fastq");
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            assertFalse(ds.genomicRuns().isEmpty(),
                "imported m87_test.bam should contain a genomic run");
            ExportTask exp = new ExportTask(exportSpec("FASTQ"),
                ExportConfig.basic(fastq), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("FASTQ export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(fastq), "expected " + fastq);
        assertTrue(Files.size(fastq) > 0, "FASTQ output is empty");
        // Sanity: starts with '@' (FASTQ record header).
        byte[] first = Files.readAllBytes(fastq);
        assertEquals('@', (char) first[0],
            "FASTQ output should begin with '@' header line");
    }

    @Test
    void bamRoundTripPreservesReadCount(@TempDir Path tmp) throws Exception {
        assumeTrue(samtoolsAvailable(), "samtools not on PATH");
        assumeTrue(nativeLibraryAvailable(),
            "libttio_rans_jni not loadable; skip BAM round-trip");
        Path bam = Paths.get("../java/src/test/resources/ttio/fixtures/genomic/m87_test.bam")
            .toAbsolutePath();
        Path origTio = tmp.resolve("orig.tio");

        ImportTask imp = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bam, origTio, "hdf5", "run_0001", "m87"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("BAM import failed: " + ee.getCause(), ee.getCause());
        }

        Path bamOut = tmp.resolve("out.bam");
        int origReadCount;
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            origReadCount = ds.genomicRuns().values().iterator().next().readCount();
            ExportTask exp = new ExportTask(exportSpec("BAM"),
                ExportConfig.basic(bamOut), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("BAM export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(bamOut));
        Path reTio = tmp.resolve("re.tio");
        ImportTask imp2 = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bamOut, reTio, "hdf5", "run_0001", "round"));
        runAndWait(imp2);
        try { imp2.get(); } catch (ExecutionException ee) {
            fail("BAM re-import failed: " + ee.getCause(), ee.getCause());
        }
        try (SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            int roundReadCount = round.genomicRuns().values().iterator().next().readCount();
            assertEquals(origReadCount, roundReadCount,
                "BAM round-trip should preserve read count");
        }
    }

    @Test
    void nmrMLRoundTripPreservesChemicalShifts(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/ttio/nmr_1d.tio")
            .toAbsolutePath();
        Path nmrml = tmp.resolve("out.nmrML");
        Path reTio = tmp.resolve("re.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            ExportTask exp = new ExportTask(exportSpec("nmrML"),
                ExportConfig.basic(nmrml), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("nmrML export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(nmrml));

        // Re-import nmrML -> re.tio
        ImportTask imp = new ImportTask(importSpec("nmrML"),
            ImportConfig.basic(nmrml, reTio, "hdf5", "run_0001", "round"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("nmrML re-import failed: " + ee.getCause(), ee.getCause());
        }

        try (SpectralDataset orig = SpectralDataset.open(src.toString());
             SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            AcquisitionRun ro = orig.msRuns().values().iterator().next();
            AcquisitionRun rr = round.msRuns().values().iterator().next();
            double[] csO = ro.channels().getOrDefault("chemical_shift", new double[0]);
            double[] csR = rr.channels().getOrDefault("chemical_shift", new double[0]);
            assertEquals(csO.length, csR.length,
                "nmrML round-trip changed chemical_shift array length");
            assertArrayEquals(csO, csR, 1e-9,
                "chemical_shift array mismatch after nmrML round-trip");
        }
    }

    @Test
    void bamRoundTripPreservesFirstReadSequence(@TempDir Path tmp) throws Exception {
        assumeTrue(samtoolsAvailable(), "samtools not on PATH");
        assumeTrue(nativeLibraryAvailable(),
            "libttio_rans_jni not loadable; skip BAM round-trip");
        Path bam = Paths.get("../java/src/test/resources/ttio/fixtures/genomic/m87_test.bam")
            .toAbsolutePath();
        Path origTio = tmp.resolve("orig.tio");

        ImportTask imp = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bam, origTio, "hdf5", "run_0001", "m87"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("BAM import failed: " + ee.getCause(), ee.getCause());
        }

        Path bamOut = tmp.resolve("out.bam");
        byte[] origFirstSeq;
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            var run = ds.genomicRuns().values().iterator().next();
            int len = run.index().lengthAt(0);
            origFirstSeq = new byte[len];
            byte[] seqs = run.sequencesFull();
            int off = (int) run.index().offsetAt(0);
            System.arraycopy(seqs, off, origFirstSeq, 0, len);
            ExportTask exp = new ExportTask(exportSpec("BAM"),
                ExportConfig.basic(bamOut), ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("BAM export failed: " + ee.getCause(), ee.getCause());
            }
        }

        Path reTio = tmp.resolve("re.tio");
        ImportTask imp2 = new ImportTask(importSpec("BAM"),
            ImportConfig.basic(bamOut, reTio, "hdf5", "run_0001", "round"));
        runAndWait(imp2);
        try { imp2.get(); } catch (ExecutionException ee) {
            fail("BAM re-import failed: " + ee.getCause(), ee.getCause());
        }
        try (SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            var run = round.genomicRuns().values().iterator().next();
            int len = run.index().lengthAt(0);
            byte[] roundFirstSeq = new byte[len];
            byte[] seqs = run.sequencesFull();
            int off = (int) run.index().offsetAt(0);
            System.arraycopy(seqs, off, roundFirstSeq, 0, len);
            assertArrayEquals(origFirstSeq, roundFirstSeq,
                "first-read sequence mismatch after BAM round-trip");
        }
    }

    @Test
    void imzMLOnNonImageDatasetRaisesIllegalState(@TempDir Path tmp) throws Exception {
        // full_ms.tio has no /study/image_cube — must now surface
        // IllegalStateException (not UnsupportedOperationException).
        Path src = Paths.get("../java/src/test/resources/ttio/full_ms.tio")
            .toAbsolutePath();
        Path out = tmp.resolve("out.imzML");
        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            ExportTask exp = new ExportTask(exportSpec("imzML"),
                ExportConfig.basic(out), ds);
            runAndWait(exp);
            ExecutionException ee = assertThrows(ExecutionException.class,
                exp::get);
            assertTrue(ee.getCause() instanceof IllegalStateException,
                "wrong cause (expected IllegalStateException): " + ee.getCause());
            assertTrue(ee.getCause().getMessage().contains("image_cube"),
                "missing 'image_cube' in: " + ee.getCause().getMessage());
        }
    }

    @Test
    void imzMLRoundTrip(@TempDir Path tmp) throws Exception {
        Path origTio = tmp.resolve("orig.tio");
        Path imzml   = tmp.resolve("out.imzML");

        // Synthesize a deterministic MSImage and write to .tio
        int w = 4, h = 3, sp = 8;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.1;
        double[] mz = new double[sp];
        for (int i = 0; i < sp; i++) mz[i] = 100.0 + i * 100.0;

        MSImage img = new MSImage(w, h, sp, 0, 10.0, 10.0, "raster",
            cube, mz, "imzml-roundtrip", "",
            List.of(), List.of(), List.of());

        try (Hdf5File f = Hdf5File.create(origTio.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        // Open the .tio and export to imzML
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            ExportConfig cfg = new ExportConfig(
                imzml, null, "continuous", null, false,
                null, null, 60, null, 33, null);
            ExportTask exp = new ExportTask(exportSpec("imzML"), cfg, ds);
            runAndWait(exp);
            try { exp.get(); } catch (ExecutionException ee) {
                fail("imzML export failed: " + ee.getCause(), ee.getCause());
            }
        }
        assertTrue(Files.exists(imzml), "expected " + imzml);
        Path ibd = imzml.resolveSibling("out.ibd");
        assertTrue(Files.exists(ibd), "expected sibling .ibd at " + ibd);

        // Re-import via Phase 8.x imzML import path (wired in PR #39).
        // The import projects pixels back into an MSImage cube — NOT into
        // an analytical msRun — so we assert on the MS image rather than on
        // msRuns(). Continuous-mode files round-trip; processed-mode raises.
        Path reTio = tmp.resolve("re.tio");
        ImportTask imp = new ImportTask(importSpec("imzML"),
            ImportConfig.basic(imzml, reTio, "hdf5", "img_0001", "round"));
        runAndWait(imp);
        try {
            imp.get();
        } catch (ExecutionException ee) {
            fail("imzML re-import failed: " + ee.getCause(), ee.getCause());
        }

        // Re-import succeeded — spot-check structural invariants.
        try (SpectralDataset round = SpectralDataset.open(reTio.toString())) {
            MSImage imgRound = (MSImage) round.imageForKind(Enums.ImageKind.MS);
            assertNotNull(imgRound, "imzML re-import should produce an MSImage");
            assertTrue(imgRound.mzAxis().length > 0,
                "round-tripped MSImage must carry an mz_axis");
        }
    }

    @Test
    void emitsProgressReportsDuringExport(@TempDir Path tmp) throws Exception {
        Path src = Paths.get("../java/src/test/resources/tiny.pwiz.1.1.mzML")
            .toAbsolutePath();
        Path origTio = tmp.resolve("orig.tio");
        Path mzml = tmp.resolve("out.mzML");

        // import source mzML -> orig.tio
        ImportTask imp = new ImportTask(importSpec("mzML"),
            ImportConfig.basic(src, origTio, "hdf5", "run_0001", "progress test"));
        runAndWait(imp);
        try { imp.get(); } catch (ExecutionException ee) {
            fail("import failed: " + ee.getCause(), ee.getCause());
        }

        // export orig.tio -> mzml and capture progress reports
        try (SpectralDataset ds = SpectralDataset.open(origTio.toString())) {
            ExportTask task = new ExportTask(exportSpec("mzML (indexed)"),
                ExportConfig.basic(mzml), ds);
            var got = new java.util.concurrent.CopyOnWriteArrayList<
                global.thalion.ttio.browser.progress.ProgressReport>();
            task.setProgressListener(got::add);
            runAndWait(task);
            try {
                task.get();
            } catch (ExecutionException ee) {
                fail("mzML export threw: " + ee.getCause(), ee.getCause());
            }
            assertFalse(got.isEmpty(),
                "should emit at least one progress report");
            assertTrue(got.stream().anyMatch(r -> r.bytesDone() > 0L || r.unitsDone() > 0L),
                "should emit at least one report with non-zero progress");
        }
    }
}
