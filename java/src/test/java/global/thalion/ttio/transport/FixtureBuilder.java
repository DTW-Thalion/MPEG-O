/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.Identification;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Test-only fixture builder. Each {@code build...} method writes a
 * fresh {@code .tio} at the given path and returns it. Used by the
 * v0.11 transport-spec conformance suite to exercise each
 * {@link SpectralDataset} accessor in isolation.
 *
 * <p>Determinism: any randomness uses a fixed seed; sequence bytes
 * are constant by design so the produced files are byte-stable across
 * runs (modulo HDF5's deterministic-on-write guarantees).</p>
 *
 * <p>Stage 0 ships only {@link #buildReferenceOnly(Path)}; later
 * stages of the v0.11 transport-spec plan will add additional
 * {@code build...} methods as their corresponding accessors get test
 * coverage.</p>
 */
public final class FixtureBuilder {

    private FixtureBuilder() {}

    /**
     * Produce a {@code .tio} containing a single
     * {@link ReferenceImport} with three contigs:
     * <ul>
     *   <li>{@code chr_long}   — 6&nbsp;000 bytes of {@code 'A'}</li>
     *   <li>{@code chr_medium} — 1&nbsp;000 bytes of {@code 'C'}</li>
     *   <li>{@code chr_short}  — 18 bytes of an ACGT-mix</li>
     * </ul>
     * No MS runs, no genomic runs, no identifications, no quants, no
     * provenance — only the embedded reference. The file is suitable
     * for exercising the {@link SpectralDataset#references()}
     * accessor on its own.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildReferenceOnly(Path target) throws Exception {
        List<String> names = List.of("chr_long", "chr_medium", "chr_short");
        List<byte[]> seqs = List.of(
            repeat((byte) 'A', 6_000),
            repeat((byte) 'C', 1_000),
            "ACGTACGTACGTACGTAC".getBytes());
        ReferenceImport ref = new ReferenceImport(
            "fixture-reference-only-v1", names, seqs);
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "reference_only", "",
                List.of(), List.of(), List.of(), List.of())) {
            ref.writeToDataset(ds);
        }
        return target;
    }

    private static byte[] repeat(byte b, int n) {
        byte[] out = new byte[n];
        Arrays.fill(out, b);
        return out;
    }

    /**
     * Produce a {@code .tio} containing a single small {@link MSImage}
     * in continuous mode (every pixel shares the same m/z axis). The
     * fixture is a 4x4 grid with 5 spectral bins and deterministic
     * synthetic intensities of the form
     * {@code intensity = (s + 1) * (x + y * width)} (so pixel (0,0)
     * is zero everywhere and pixel (3,3) has the largest values).
     * No MS runs, no genomic runs, no references, no identifications,
     * no quants, no provenance — only the embedded {@link MSImage}.
     * Used by the Task 1.7 transport-spec conformance suite.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildImageMsContinuous(Path target) throws Exception {
        final int w = 4;
        final int h = 4;
        final int s = 5;
        double[] cube = new double[w * h * s];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int pixelIdx = x + y * w;
                int base = (y * w + x) * s;
                for (int k = 0; k < s; k++) {
                    cube[base + k] = (k + 1.0) * pixelIdx;
                }
            }
        }
        double[] mz = new double[s];
        for (int i = 0; i < s; i++) mz[i] = 100.0 + i * 10.0;
        MSImage image = new MSImage(w, h, s, 0,
                10.0, 10.0, "raster",
                cube, mz,
                "image_ms_continuous", "",
                List.of(), List.of(), List.of());

        // SpectralDataset.create(...) does not surface an MSImage
        // parameter, so we follow the same pattern the existing
        // round-trip tests use: open the raw Hdf5File after create()
        // closes and write the image cube directly under /study/.
        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "image_ms_continuous", "",
                List.of(), List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent()
                    .with(FeatureFlags.OPT_NATIVE_MSIMAGE_CUBE))) {
            // create() persists /study/ + feature flags; the image
            // gets layered on next.
        }
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            image.writeTo(Hdf5Provider.adapterForGroup(study));
        }
        return target;
    }

    /**
     * Produce a {@code .tio} containing a small list of
     * {@link Identification} rows and nothing else (no runs, no
     * genomic runs, no references, no image, no quants, no
     * provenance). Used by the Task 1.8 transport-spec conformance
     * suite to exercise {@code IDENTIFICATIONS_TABLE} (0x16)
     * round-tripping on its own.
     *
     * <p>The rows are deterministic and match the Arrow IPC schema
     * exposed by {@link ArrowIpcCodec} verbatim.</p>
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildIdentificationsOnly(Path target) throws Exception {
        List<Identification> ids = List.of(
            new Identification("run1", 42, "CompoundA", 0.91,
                List.of("evidence1", "evidence2")),
            new Identification("run1", 43, "CompoundB", 0.85,
                List.of("evidence3"))
        );
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "ids_only", "",
                List.of(), ids, List.of(), List.of())) {
            // No further writes needed.
        }
        return target;
    }

    /**
     * Produce a {@code .tio} containing a small list of
     * {@link Quantification} rows and nothing else (no runs, no
     * genomic runs, no references, no image, no ids, no
     * provenance). Used by the Task 1.8 transport-spec conformance
     * suite to exercise {@code QUANTIFICATIONS_TABLE} (0x17)
     * round-tripping on its own.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildQuantificationsOnly(Path target) throws Exception {
        List<Quantification> quants = List.of(
            new Quantification("CompoundA", "sample-1", 12.5,
                "intensity-sum", "counts"),
            new Quantification("CompoundB", "sample-1", 7.3,
                "intensity-sum", "counts")
        );
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "quants_only", "",
                List.of(), List.of(), quants, List.of())) {
            // No further writes needed.
        }
        return target;
    }

    /**
     * Produce a {@code .tio} carrying two {@link ProvenanceRecord}
     * entries (one with parameters + input/output refs, one minimal)
     * and nothing else. Used by Task 1.10's accessor-matrix conformance
     * suite to exercise the {@code DATASET_PROVENANCE} (0x18) packet on
     * its own.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildDatasetProvenanceOnly(Path target) throws Exception {
        Map<String, String> params = new LinkedHashMap<>();
        params.put("mode", "strict");
        params.put("threshold", "0.5");
        ProvenanceRecord r1 = new ProvenanceRecord(
            1700000000L, "TTI-O Java 1.0.0",
            params,
            List.of("file:///in.raw", "file:///in2.raw"),
            List.of("file:///out.tio"));
        ProvenanceRecord r2 = new ProvenanceRecord(
            1700000100L, "downstream step",
            Map.of(),
            List.of(),
            List.of("file:///final.tio"));
        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "provenance_only", "",
                List.of(), List.of(), List.of(), List.of(r1, r2))) {
            // The provenance records are persisted as the root
            // /study/provenance_json attribute by create(...).
        }
        return target;
    }

    /**
     * Produce a {@code .tio} whose root group carries the
     * {@code @encrypted} HDF5 attribute set to
     * {@code "aes-256-gcm"} and nothing else. Used by Task 1.10's
     * accessor-matrix conformance suite to exercise the
     * {@code ENCRYPTION_ALGORITHM} (0x1B) packet on its own.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildEncryptionAlgorithmOnly(Path target) throws Exception {
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "encryption_only", "",
                List.of(), List.of(), List.of(), List.of())) {
            // Set the root @encrypted attribute through the open
            // provider so the on-disk file carries it.
            ds.provider().rootGroup().setAttribute("encrypted", "aes-256-gcm");
        }
        return target;
    }

    /**
     * Produce a {@code .tio} carrying a single {@link AcquisitionRun}
     * with 5 spectra of 4 m/z points each and nothing else. Used by
     * Task 1.10's accessor-matrix conformance suite to exercise the
     * MS-run round-trip in isolation. Mirrors the shape used by
     * {@code TransportConformanceTest.buildDataset(1, 5, 4)}.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildMsRunsOnly(Path target) throws Exception {
        AcquisitionRun run = synthMsRun("run_0001", 0, 5, 4);
        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "ms_runs_only", "",
                List.of(run), List.of(), List.of(), List.of())) {
            // create() persists the run; no further writes needed.
        }
        return target;
    }

    /**
     * Produce a {@code .tio} carrying a single genomic run (4 short
     * aligned reads on chr1/chr2/* with deterministic sequences) and
     * nothing else. Used by Task 1.10's accessor-matrix conformance
     * suite to exercise the genomic-run round-trip in isolation.
     * Mirrors the fixture shape used by
     * {@code M89GenomicTransportTest.makeMinimalGenomicRun}.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildGenomicRunsOnly(Path target) throws Exception {
        WrittenGenomicRun run = synthGenomicRun();
        SpectralDataset.create(target.toString(),
            "genomic_runs_only", "",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return target;
    }

    /**
     * Produce a {@code .tio} populated with EVERY first-class v0.11
     * accessor at once (except {@code SUBJECTS} and {@code SAMPLES},
     * which are deferred until they exist as first-class entities on
     * {@link SpectralDataset}). Used by Task 1.11's
     * {@code CoverageGapWatchdogTest} to fire whenever a writer
     * silently drops one of the populated content types.
     *
     * <p>What gets populated:</p>
     * <ul>
     *   <li>1 reference with 3 contigs (chr_long, chr_medium, chr_short)</li>
     *   <li>1 small MSImage in continuous mode (3x3x4)</li>
     *   <li>2 {@link Identification} rows</li>
     *   <li>2 {@link Quantification} rows</li>
     *   <li>2 {@link ProvenanceRecord} entries (one rich, one minimal)</li>
     *   <li>{@code @encrypted = "aes-256-gcm"} root attribute</li>
     *   <li>1 MS run with 5 spectra of 4 m/z points each</li>
     *   <li>1 genomic run with 4 short aligned reads</li>
     * </ul>
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildEverything(Path target) throws Exception {
        // Reference (3 contigs)
        List<String> refNames = List.of("chr_long", "chr_medium", "chr_short");
        List<byte[]> refSeqs = List.of(
            repeat((byte) 'A', 6_000),
            repeat((byte) 'C', 1_000),
            "ACGTACGTACGTACGTAC".getBytes());
        ReferenceImport ref = new ReferenceImport(
            "fixture-everything-v1", refNames, refSeqs);

        // MSImage (3x3x4 continuous)
        final int w = 3;
        final int h = 3;
        final int s = 4;
        double[] cube = new double[w * h * s];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int pixelIdx = x + y * w;
                int base = (y * w + x) * s;
                for (int k = 0; k < s; k++) {
                    cube[base + k] = (k + 1.0) * pixelIdx;
                }
            }
        }
        double[] mz = new double[s];
        for (int i = 0; i < s; i++) mz[i] = 100.0 + i * 10.0;
        MSImage image = new MSImage(w, h, s, 0,
                10.0, 10.0, "raster",
                cube, mz,
                "everything", "",
                List.of(), List.of(), List.of());

        // Identifications
        List<Identification> ids = List.of(
            new Identification("run_0001", 0, "CompoundA", 0.91,
                List.of("evidence1", "evidence2")),
            new Identification("run_0001", 1, "CompoundB", 0.85,
                List.of("evidence3")));

        // Quantifications
        List<Quantification> quants = List.of(
            new Quantification("CompoundA", "sample-1", 12.5,
                "intensity-sum", "counts"),
            new Quantification("CompoundB", "sample-1", 7.3,
                "intensity-sum", "counts"));

        // Provenance
        Map<String, String> params = new LinkedHashMap<>();
        params.put("mode", "strict");
        params.put("threshold", "0.5");
        ProvenanceRecord prov1 = new ProvenanceRecord(
            1700000000L, "TTI-O Java 1.0.0",
            params,
            List.of("file:///in.raw", "file:///in2.raw"),
            List.of("file:///out.tio"));
        ProvenanceRecord prov2 = new ProvenanceRecord(
            1700000100L, "downstream step",
            Map.of(),
            List.of(),
            List.of("file:///final.tio"));

        // MS run + genomic run
        AcquisitionRun msRun = synthMsRun("run_0001", 0, 5, 4);
        WrittenGenomicRun genRun = synthGenomicRun();

        // Combined create with MS + genomic + ids + quants + provenance,
        // feature flags must include OPT_NATIVE_MSIMAGE_CUBE for the
        // subsequent image.writeTo(...) layering pass.
        FeatureFlags flags = FeatureFlags.defaultCurrent()
            .with(FeatureFlags.OPT_NATIVE_MSIMAGE_CUBE);
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "everything", "",
                List.of(msRun), List.of(genRun),
                ids, quants, List.of(prov1, prov2),
                flags)) {
            // Reference is written via writeToDataset on an open ds.
            ref.writeToDataset(ds);
            // Encrypted attribute set through the open provider.
            ds.provider().rootGroup().setAttribute("encrypted", "aes-256-gcm");
        }
        // Image cube layered on after create() closes the provider —
        // mirrors the buildImageMsContinuous pattern.
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            image.writeTo(Hdf5Provider.adapterForGroup(study));
        }
        return target;
    }

    /** Build a deterministic synthetic MS run with {@code nSpectra}
     *  spectra of {@code pointsPerSpectrum} m/z points each. Pattern
     *  matches {@code TransportConformanceTest.buildDataset}. */
    private static AcquisitionRun synthMsRun(String name, int runOffset,
                                              int nSpectra, int pointsPerSpectrum) {
        int total = nSpectra * pointsPerSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 * (runOffset + 1) + i;
            intensity[i] = 100.0 * (runOffset + 1) * (i + 1);
        }
        long[] offsets = new long[nSpectra];
        int[] lengths = new int[nSpectra];
        for (int i = 0; i < nSpectra; i++) {
            offsets[i] = (long) i * pointsPerSpectrum;
            lengths[i] = pointsPerSpectrum;
        }
        double[] rts = new double[nSpectra];
        for (int i = 0; i < nSpectra; i++) rts[i] = 1.0 + i;
        int[] msLevels = new int[nSpectra];
        int[] pols = new int[nSpectra];
        double[] pmzs = new double[nSpectra];
        int[] pcs = new int[nSpectra];
        double[] bpis = new double[nSpectra];
        for (int i = 0; i < nSpectra; i++) {
            msLevels[i] = (i % 2 == 0) ? 1 : 2;
            pols[i] = 1;
            pmzs[i] = msLevels[i] == 1 ? 0.0 : 500.0 + i;
            pcs[i] = msLevels[i] == 1 ? 0 : 2;
            double best = 0;
            for (int k = 0; k < pointsPerSpectrum; k++) {
                best = Math.max(best, intensity[i * pointsPerSpectrum + k]);
            }
            bpis[i] = best;
        }
        SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths, rts,
                msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        return new AcquisitionRun(name,
                Enums.AcquisitionMode.MS1_DDA, idx,
                new InstrumentConfig("", "", "", "", "", ""),
                channels, List.of(), List.of(), "", 0.0);
    }

    /** Build a deterministic minimal {@link WrittenGenomicRun} with
     *  4 short aligned reads. Pattern matches
     *  {@code M89GenomicTransportTest.makeMinimalGenomicRun}. */
    private static WrittenGenomicRun synthGenomicRun() {
        int n = 4;
        String[] chroms = {"chr1", "chr1", "chr2", "*"};
        long[] positions = {100L, 200L, 50L, -1L};
        byte[] mqs = {(byte) 60, (byte) 55, (byte) 40, (byte) 0};
        int[] flags = {0x0003, 0x0003, 0x0003, 0x0004};
        byte[] template = "ACGTACGTACGT".getBytes(StandardCharsets.US_ASCII);
        int readLen = template.length;
        byte[] sequences = new byte[n * readLen];
        byte[] qualities = new byte[n * readLen];
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        for (int i = 0; i < n; i++) {
            System.arraycopy(template, 0, sequences, i * readLen, readLen);
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
        }
        Arrays.fill(qualities, (byte) 30);
        List<String> chromsList = new ArrayList<>(Arrays.asList(chroms));
        List<String> cigars = new ArrayList<>(n);
        List<String> readNames = new ArrayList<>(n);
        List<String> mateChroms = new ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        for (int i = 0; i < n; i++) {
            cigars.add(readLen + "M");
            readNames.add(String.format("read_%03d", i));
            mateChroms.add("");
            matePos[i] = -1L;
            tlens[i] = 0;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chromsList, Compression.ZLIB);
    }
}
