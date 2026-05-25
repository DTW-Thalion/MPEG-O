/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

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
}
