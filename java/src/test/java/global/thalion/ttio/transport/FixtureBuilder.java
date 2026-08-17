/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.IRImage;
import global.thalion.ttio.Identification;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.RamanImage;
import global.thalion.ttio.Sample;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Subject;
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
     * Stage 5 / Task 5.6: Produce a {@code .tio} containing the same
     * MSImage fixture as {@link #buildImageMsContinuous}. The on-disk
     * .tio is identical — only the encode path differs: the
     * MS_IMAGE_PROCESSED accessor's {@code encode} override emits via
     * {@link TransportWriter#writeImageProcessed} so the conformance
     * suite exercises the opt-in sparse wire mode against the dense
     * cube.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildImageMsProcessedOnly(Path target) throws Exception {
        // Same fixture shape as buildImageMsContinuous — the encode-
        // side override is the only knob that varies between
        // MS_IMAGE and MS_IMAGE_PROCESSED.
        return buildImageMsContinuous(target);
    }

    /**
     * Stage 5 / Task 5.6: Produce a {@code .tio} containing a single
     * small {@link RamanImage} (3x3x5 cube) and nothing else. The
     * fixture mirrors the Python and ObjC equivalents so the cross-
     * language matrix produces byte-identical content on each SDK's
     * write path.
     *
     * <p>Field values: width=3, height=3, spectralPoints=5,
     * intensityCube[i] = i*0.5 (flat index, 45 entries),
     * wavenumbers = [1000, 1100, 1200, 1300, 1400],
     * excitation=785.0nm, laserPower=50.0mW, scanPattern="raster",
     * pixelSize=10.0x10.0.</p>
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildRamanImageOnly(Path target) throws Exception {
        final int w = 3;
        final int h = 3;
        final int s = 5;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) {
            cube[i] = i * 0.5;
        }
        double[] wn = new double[]{1000.0, 1100.0, 1200.0, 1300.0, 1400.0};
        RamanImage img = new RamanImage(
            w, h, s, 0,
            10.0, 10.0, "raster",
            785.0, 50.0,
            cube, wn,
            "raman_image_only", "",
            List.of(), List.of(), List.of());

        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "raman_image_only", "",
                List.of(), List.of(), List.of(), List.of())) {
            // create() persists /study/; image layered on next.
        }
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }
        return target;
    }

    /**
     * Stage 5 / Task 5.6: Produce a {@code .tio} containing a single
     * small {@link IRImage} (3x3x5 cube) and nothing else. Mirrors
     * the Python and ObjC equivalents so the cross-language matrix
     * produces byte-identical content on each SDK's write path.
     *
     * <p>Field values: width=3, height=3, spectralPoints=5,
     * intensityCube[i] = i*0.5 (flat index, 45 entries),
     * wavenumbers = [1000, 1100, 1200, 1300, 1400],
     * mode=ABSORBANCE, resolution=4.0cm-1, scanPattern="raster",
     * pixelSize=10.0x10.0.</p>
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildIrImageOnly(Path target) throws Exception {
        final int w = 3;
        final int h = 3;
        final int s = 5;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) {
            cube[i] = i * 0.5;
        }
        double[] wn = new double[]{1000.0, 1100.0, 1200.0, 1300.0, 1400.0};
        IRImage img = new IRImage(
            w, h, s, 0,
            10.0, 10.0, "raster",
            IRMode.ABSORBANCE, 4.0,
            cube, wn,
            "ir_image_only", "",
            List.of(), List.of(), List.of());

        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "ir_image_only", "",
                List.of(), List.of(), List.of(), List.of())) {
            // create() persists /study/; image layered on next.
        }
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
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
        WrittenGenomicRun run = synthGenomicRun().withOptLegacyWholeChannel(true);
        SpectralDataset.create(target.toString(),
            "genomic_runs_only", "",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return target;
    }

    /**
     * The GENOMIC_RUNS fixture written in the {@code blocks_v1} layout
     * (the writer default): three chromosomes, three blocks. Mirrors
     * Python's {@code build_genomic_runs_blocks}.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildGenomicRunsBlocks(Path target) throws Exception {
        WrittenGenomicRun run = synthGenomicRun();
        SpectralDataset.create(target.toString(),
            "genomic_runs_blocks", "",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();
        return target;
    }

    /**
     * Stage 6 / Task 6.2: produce a {@code .tio} carrying a small list
     * of {@link Subject} rows and nothing else. Used by the SUBJECT_METADATA
     * (0x19) round-trip suite and the AccessorMatrix SUBJECTS entry
     * (Task 6.6).
     *
     * <p>Two rows by design — one minimal (external_id only; all
     * optionals at their unset sentinels) and one fully populated
     * (every optional set, multi-key sort-keys attributes map) — so
     * the write/read pair exercises both the "value present" and
     * "Arrow null on the wire" branches of the codec, and the cross-
     * language byte-parity ride on {@code attributesJson} sort-keys
     * order.</p>
     *
     * <p>IDs follow the Task 6.6 convention (SUBJ-A / SUBJ-B) — short,
     * ASCII, no slashes / no dots; safe for {@code /study/subjects/&lt;id&gt;/}
     * HDF5 group naming on every platform.</p>
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildSubjectsOnly(Path target) throws Exception {
        // Minimal: external_id only, all optionals at unset sentinel.
        Subject minimal = new Subject("SUBJ-A", "", "", 0L, Map.of());
        // Full: every optional set + multi-key attributes (the
        // cross-language sort-keys byte parity probe).
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("notes", "fully populated subject");
        attrs.put("cohort", "control");
        Subject full = new Subject("SUBJ-B", "PROJ_A", "F", 1985L, attrs);
        List<Subject> subjects = List.of(minimal, full);
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "subjects_only", "",
                List.of(), List.of(), List.of(), List.of(),
                subjects, List.of())) {
            // No further writes needed.
        }
        return target;
    }

    /**
     * Stage 6 / Task 6.2 + Task 6.6: produce a {@code .tio} carrying a
     * small list of {@link Sample} rows and nothing else. Used by the
     * SAMPLE_METADATA (0x1A) round-trip suite and the AccessorMatrix
     * SAMPLES entry.
     *
     * <p>Three rows by design:</p>
     * <ul>
     *   <li>{@code SMPL-1} — minimal (sample_id only; subject_external_id
     *       empty, sample_kind empty, collected_at sentinel, no attrs).</li>
     *   <li>{@code SMPL-2} — references a Subject that does NOT exist
     *       in this fixture ({@code subject_external_id = "SUBJ-MISSING"});
     *       valid per spec §4.4 (anonymous / cross-dataset samples
     *       are valid; only logs a WARNING on write).</li>
     *   <li>{@code SMPL-3} — fully populated (every optional set,
     *       multi-key sort-keys attributes map). Exercises the cross-
     *       language byte-parity on {@code attributesJson}.</li>
     * </ul>
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildSamplesOnly(Path target) throws Exception {
        Sample minimal = new Sample("SMPL-1", "", "", 0L, Map.of());
        // Soft-FK miss: subject_external_id refers to a Subject that
        // doesn't exist in this fixture. Spec §4.4 allows this; the
        // validator logs a WARNING but does not fail the write.
        Sample danglingFk =
            new Sample("SMPL-2", "SUBJ-MISSING", "plasma", 0L, Map.of());
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("tissue", "liver");
        attrs.put("notes", "freshly collected");
        Sample full = new Sample("SMPL-3", "", "tissue",
            1700000000L, attrs);
        List<Sample> samples = List.of(minimal, danglingFk, full);
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "samples_only", "",
                List.of(), List.of(), List.of(), List.of(),
                List.of(), samples)) {
            // No further writes needed.
        }
        return target;
    }

    /**
     * Stage 6 / Task 6.2: produce a {@code .tio} carrying both
     * {@link Subject} and {@link Sample} rows. Used to verify the
     * §5.4 step 5 emission order (SUBJECT_METADATA precedes
     * SAMPLE_METADATA) on the wire.
     *
     * @param target file path to write
     * @return {@code target}, unchanged, for fluent use in tests
     */
    public static Path buildSubjectsAndSamples(Path target) throws Exception {
        List<Subject> subjects = List.of(
            new Subject("SUB-A", "P", "F", 1980L,
                Map.of("k", "v")));
        List<Sample> samples = List.of(
            new Sample("SAMP-A", "SUB-A", "tissue",
                1700000000L, Map.of("notes", "ok")));
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "subjects_and_samples", "",
                List.of(), List.of(), List.of(), List.of(),
                subjects, samples)) {
            // No further writes needed.
        }
        return target;
    }

    /**
     * Produce a {@code .tio} populated with EVERY first-class v0.11
     * accessor at once. Used by Task 1.11's
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
     *   <li>Task 6.6: 2 {@link Subject} rows + 3 {@link Sample} rows,
     *       exercising every cross-cardinality case from spec §8:
     *       one fully-linked pair (SUBJ-A &lt;-&gt; SMPL-1), one Subject
     *       without a matching Sample (SUBJ-B), one Sample with an
     *       empty subject ref (SMPL-2), and one Sample whose
     *       {@code subject_external_id} points at a Subject that
     *       does not exist in this fixture (SMPL-3 -&gt; SUBJ-MISSING).</li>
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

        // Task 6.6: 2 Subjects + 3 Samples exercising every spec §8
        // cross-cardinality case:
        //   SUBJ-A — matched (SMPL-1 soft-FK points at it)
        //   SUBJ-B — unmatched (no sample references it)
        //   SMPL-1 — fully linked to SUBJ-A (full row, multi-key attrs)
        //   SMPL-2 — anonymous (subject_external_id = "")
        //   SMPL-3 — Sample without matching Subject
        //            (subject_external_id = "SUBJ-MISSING")
        Map<String, String> subAttrs = new LinkedHashMap<>();
        subAttrs.put("notes", "fully populated subject");
        subAttrs.put("cohort", "control");
        List<Subject> subjects = List.of(
            new Subject("SUBJ-A", "PROJ_A", "F", 1985L, subAttrs),
            // unmatched Subject — no sample carries subject_external_id="SUBJ-B"
            new Subject("SUBJ-B", "", "", 0L, Map.of()));
        Map<String, String> smplAttrs = new LinkedHashMap<>();
        smplAttrs.put("tissue", "liver");
        smplAttrs.put("notes", "freshly collected");
        List<Sample> samples = List.of(
            new Sample("SMPL-1", "SUBJ-A", "tissue",
                1700000000L, smplAttrs),
            new Sample("SMPL-2", "", "plasma", 0L, Map.of()),
            new Sample("SMPL-3", "SUBJ-MISSING", "", 0L, Map.of()));

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
        // mirrors the buildImageMsContinuous pattern. Subjects + samples
        // are layered in the same reopen so we don't need a third
        // file-open/close.
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            image.writeTo(Hdf5Provider.adapterForGroup(study));
            // Task 6.6: layer per-row /study/subjects/<external_id>/ and
            // /study/samples/<sample_id>/ groups via raw HDF5 writes.
            // Mirrors the production layout written by
            // SpectralDataset.createMixed's writeSubjectsViaProvider /
            // writeSamplesViaProvider — duplicated here as a test-only
            // helper because the public create() overload that accepts
            // (genomicRuns, subjects, samples) together doesn't exist
            // yet (private createMixed does the actual work).
            writeSubjectsToStudy(study, subjects);
            writeSamplesToStudy(study, samples);
        }
        return target;
    }

    /** Mirror of {@code SpectralDataset.writeSubjectsViaProvider} for
     *  use after {@code create()} closes its provider. Writes per-row
     *  groups under {@code /study/subjects/<external_id>/} with the
     *  same attribute set (external_id, project, sex, birth_year,
     *  attributes_json) so the reader-side {@code readSubjects} lifts
     *  them back as if they had been written by the create path. */
    private static void writeSubjectsToStudy(Hdf5Group study,
                                              List<Subject> subjects) {
        if (subjects == null || subjects.isEmpty()) return;
        try (Hdf5Group subjectsGroup = study.createGroup("subjects")) {
            for (Subject s : subjects) {
                try (Hdf5Group row = subjectsGroup.createGroup(s.externalId())) {
                    row.setStringAttribute("external_id", s.externalId());
                    if (!s.project().isEmpty()) {
                        row.setStringAttribute("project", s.project());
                    }
                    if (!s.sex().isEmpty()) {
                        row.setStringAttribute("sex", s.sex());
                    }
                    row.setIntegerAttribute("birth_year", s.birthYear());
                    row.setStringAttribute(
                        "attributes_json", s.attributesJson());
                }
            }
        }
    }

    /** Mirror of {@code SpectralDataset.writeSamplesViaProvider} for
     *  use after {@code create()} closes its provider. Mirrors the
     *  on-disk attribute layout exactly so the reader returns the
     *  same {@link Sample} rows. */
    private static void writeSamplesToStudy(Hdf5Group study,
                                             List<Sample> samples) {
        if (samples == null || samples.isEmpty()) return;
        try (Hdf5Group samplesGroup = study.createGroup("samples")) {
            for (Sample s : samples) {
                try (Hdf5Group row = samplesGroup.createGroup(s.sampleId())) {
                    row.setStringAttribute("sample_id", s.sampleId());
                    if (!s.subjectExternalId().isEmpty()) {
                        row.setStringAttribute(
                            "subject_external_id", s.subjectExternalId());
                    }
                    if (!s.sampleKind().isEmpty()) {
                        row.setStringAttribute(
                            "sample_kind", s.sampleKind());
                    }
                    row.setIntegerAttribute(
                        "collected_at", s.collectedAt());
                    row.setStringAttribute(
                        "attributes_json", s.attributesJson());
                }
            }
        }
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
