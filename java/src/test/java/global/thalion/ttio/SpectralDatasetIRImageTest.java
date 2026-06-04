/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage 5.2 (transport-spec v0.11, Deferral 1): verify that
 * {@link SpectralDataset#irImage()} exposes the third imaging modality
 * as a first-class accessor, mirroring {@code image()} (MSImage) and
 * {@code ramanImage()} (RamanImage). Backs {@code /study/ir_image_cube/}.
 */
class SpectralDatasetIRImageTest {

    @TempDir
    Path tempDir;

    /** Write an IR image cube into a dataset, reopen via
     *  {@link SpectralDataset#open(String)}, and assert
     *  {@link SpectralDataset#irImage()} returns the materialised cube. */
    @Test
    void irImageAccessorRoundTrip() {
        String path = tempDir.resolve("ir_image_accessor.tio").toString();

        int w = 4, h = 4, s = 16;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.125;
        double[] wn = new double[s];
        for (int i = 0; i < s; i++) wn[i] = 400.0 + i * 10.0;

        IRImage img = new IRImage(w, h, s, 2,
                1.0, 1.0, "raster",
                IRMode.ABSORBANCE, 8.0,
                cube, wn,
                "IR map", "", List.of(), List.of(), List.of());

        // First create a minimal SpectralDataset shell so the .tio has
        // /study/ etc. — then attach the ir_image_cube subgroup via the
        // same Hdf5Provider adapter the Raman/MS image tests use.
        try (SpectralDataset ds = SpectralDataset.create(path, "IR accessor test",
                "ISA-IR-001", List.of(), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        try (Hdf5File f = Hdf5File.open(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            img.writeTo(global.thalion.ttio.providers.Hdf5Provider.adapterForGroup(study));
        }

        // Reopen and assert irImage() returns a matching IRImage.
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            IRImage read = (IRImage) ds.imageForKind(Enums.ImageKind.IR);
            assertNotNull(read, "irImage() must materialise /study/ir_image_cube");
            assertEquals(w, read.width());
            assertEquals(h, read.height());
            assertEquals(s, read.spectralPoints());
            assertEquals(IRMode.ABSORBANCE, read.mode());
            assertEquals(8.0, read.resolutionCmInv(), 1e-10);
            assertEquals("raster", read.scanPattern());
            assertArrayEquals(wn, read.wavenumbers(), 1e-12);
            assertArrayEquals(cube, read.intensityCube(), 1e-10);

            // Sibling accessors stay null since we wrote neither modality.
            assertNull(ds.imageForKind(Enums.ImageKind.MS),
                    "MS image must be null when /study/image_cube absent");
            assertNull(ds.imageForKind(Enums.ImageKind.RAMAN),
                    "raman image must be null when /study/raman_image_cube absent");
        }
    }

    /** Empty dataset (no ir_image_cube on disk) must yield
     *  {@link SpectralDataset#irImage()} == null. */
    @Test
    void irImageAccessorNullWhenAbsent() {
        String path = tempDir.resolve("ir_image_absent.tio").toString();

        try (SpectralDataset ds = SpectralDataset.create(path, "no IR",
                "ISA-NONE", List.of(), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertNull(ds.imageForKind(Enums.ImageKind.IR),
                    "IR image must be null when /study/ir_image_cube is absent");
        }
    }
}
