/* TTI-O Java tests / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio;

import global.thalion.ttio.providers.Hdf5Provider;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class MSImageMzAxisTest {

    @Test
    void mzAxisRoundTrip(@TempDir Path tmp) {
        int w = 4, h = 3, sp = 8;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.1;
        double[] mz = new double[sp];
        for (int i = 0; i < sp; i++) mz[i] = 100.0 + i * 100.0;

        MSImage img = new MSImage(w, h, sp, 0, 10.0, 10.0, "raster",
                cube, mz, "", "", List.of(), List.of(), List.of());

        String path = tmp.resolve("mz_axis_test.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            MSImage read = MSImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertArrayEquals(mz, read.mzAxis(), 0.0,
                "mz_axis byte-equal after round-trip");
        }
    }

    @Test
    void legacyFileReturnsEmptyMzAxis(@TempDir Path tmp) {
        // Write a file via the legacy 7-arg ctor (no mzAxis); confirm
        // read-back returns an empty axis without throwing.
        int w = 2, h = 2, sp = 3;
        double[] cube = new double[w * h * sp];
        MSImage legacy = new MSImage(w, h, sp, 5.0, 5.0, "raster", cube);

        String path = tmp.resolve("legacy.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            legacy.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            MSImage read = MSImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertEquals(0, read.mzAxis().length,
                "legacy file with no mz_axis dataset returns empty");
        }
    }

    @Test
    void mzAxisLengthMismatchRejected() {
        int w = 2, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        double[] badMz = new double[sp + 1];   // wrong length
        assertThrows(IllegalArgumentException.class, () ->
            new MSImage(w, h, sp, 0, 0.0, 0.0, "raster", cube, badMz,
                "", "", List.of(), List.of(), List.of()));
    }
}
