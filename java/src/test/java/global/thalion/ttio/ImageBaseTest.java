/* TTI-O Java tests / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.Enums.ImageKind;
import global.thalion.ttio.Enums.SpectralAxisKind;
import global.thalion.ttio.providers.Hdf5Provider;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * JIT1 fence test for the extracted {@link Image} base class.
 *
 * <p>Asserts a byte-faithful {@code writeTo}/{@code readFrom} round-trip
 * for each of the three image kinds (MS, Raman, IR), then exercises the
 * new shared abstraction surface: {@code instanceof Image},
 * {@link Image#kind()}, {@link Image#spectralAxis()}, and
 * {@link Image#spectralAxisKind()}.</p>
 */
class ImageBaseTest {

    @Test
    void msImageRoundTripAndBase(@TempDir Path tmp) {
        int w = 3, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i + 1;
        double[] mzAxis = { 100.0, 101.0, 102.0, 103.0 };

        MSImage img = new MSImage(w, h, sp, 0, 1.5, 2.5, "flyback", cube, mzAxis,
                "imgtitle", "ISA-1", List.of(), List.of(), List.of());

        String path = tmp.resolve("ms.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        MSImage read;
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            read = MSImage.readFrom(Hdf5Provider.adapterForGroup(study));
        }
        assertNotNull(read);
        assertEquals(w, read.width());
        assertEquals(h, read.height());
        assertEquals(sp, read.spectralPoints());
        assertEquals(1.5, read.pixelSizeX(), 0.0);
        assertEquals(2.5, read.pixelSizeY(), 0.0);
        assertEquals("flyback", read.scanPattern());
        assertArrayEquals(cube, read.intensityCube(), 0.0);
        assertArrayEquals(mzAxis, read.mzAxis(), 0.0);

        // Shared base abstraction.
        assertTrue(read instanceof Image);
        Image base = read;
        assertEquals(ImageKind.MS, base.kind());
        assertArrayEquals(mzAxis, base.spectralAxis(), 0.0);
        assertEquals(SpectralAxisKind.MZ, base.spectralAxisKind());
    }

    @Test
    void ramanImageRoundTripAndBase(@TempDir Path tmp) {
        int w = 3, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i + 0.5;
        double[] wn = { 500.0, 600.0, 700.0, 800.0 };

        RamanImage img = new RamanImage(w, h, sp, 2, 1.0, 1.0, "raster",
                532.0, 12.5, cube, wn,
                "rtitle", "ISA-2", List.of(), List.of(), List.of());

        String path = tmp.resolve("raman.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        RamanImage read;
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            read = RamanImage.readFrom(Hdf5Provider.adapterForGroup(study));
        }
        assertNotNull(read);
        assertEquals(w, read.width());
        assertEquals(h, read.height());
        assertEquals(sp, read.spectralPoints());
        assertEquals(2, read.tileSize());
        assertEquals(1.0, read.pixelSizeX(), 0.0);
        assertEquals(1.0, read.pixelSizeY(), 0.0);
        assertEquals("raster", read.scanPattern());
        assertEquals(532.0, read.excitationWavelengthNm(), 0.0);
        assertEquals(12.5, read.laserPowerMw(), 0.0);
        assertArrayEquals(cube, read.intensityCube(), 0.0);
        assertArrayEquals(wn, read.wavenumbers(), 0.0);

        assertTrue(read instanceof Image);
        Image base = read;
        assertEquals(ImageKind.RAMAN, base.kind());
        assertArrayEquals(wn, base.spectralAxis(), 0.0);
        assertEquals(SpectralAxisKind.WAVENUMBER, base.spectralAxisKind());
    }

    @Test
    void irImageRoundTripAndBase(@TempDir Path tmp) {
        int w = 4, h = 3, sp = 8;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.0625;
        double[] wn = new double[sp];
        for (int i = 0; i < sp; i++) wn[i] = 1000.0 + i * 4.0;

        IRImage img = new IRImage(w, h, sp, 2, 0.5, 0.5, "raster",
                IRMode.ABSORBANCE, 4.0, cube, wn,
                "irtitle", "ISA-3", List.of(), List.of(), List.of());

        String path = tmp.resolve("ir.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        IRImage read;
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            read = IRImage.readFrom(Hdf5Provider.adapterForGroup(study));
        }
        assertNotNull(read);
        assertEquals(w, read.width());
        assertEquals(h, read.height());
        assertEquals(sp, read.spectralPoints());
        assertEquals(2, read.tileSize());
        assertEquals(0.5, read.pixelSizeX(), 0.0);
        assertEquals(0.5, read.pixelSizeY(), 0.0);
        assertEquals("raster", read.scanPattern());
        assertEquals(IRMode.ABSORBANCE, read.mode());
        assertEquals(4.0, read.resolutionCmInv(), 0.0);
        assertArrayEquals(cube, read.intensityCube(), 0.0);
        assertArrayEquals(wn, read.wavenumbers(), 0.0);

        assertTrue(read instanceof Image);
        Image base = read;
        assertEquals(ImageKind.IR, base.kind());
        assertArrayEquals(wn, base.spectralAxis(), 0.0);
        assertEquals(SpectralAxisKind.WAVENUMBER, base.spectralAxisKind());
    }
}
