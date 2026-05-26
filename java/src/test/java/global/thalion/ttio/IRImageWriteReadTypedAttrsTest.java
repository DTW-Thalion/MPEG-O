/* TTI-O Java tests / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.IRMode;
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
 * Stage 5.6 cross-language conformance follow-up: verify that
 * {@link IRImage#writeTo(StorageGroup)} now persists numeric
 * attributes ({@code pixel_size_x}, {@code pixel_size_y},
 * {@code resolution_cm_inv}) as native {@code f64} and
 * {@code ir_mode} as native {@code i64} (matching Python/ObjC), and
 * that {@link IRImage#readFrom(StorageGroup)} still accepts legacy
 * VL-string-typed attributes written by older Java releases.
 *
 * <p>Backs commit {@code 56f54fdf} of the cross-SDK accessor matrix:
 * the 8 previously-skipped IR_IMAGE cells in xlang now exercise this
 * typed wire-form.</p>
 */
class IRImageWriteReadTypedAttrsTest {

    /** New typed wire-form: write through {@link IRImage} and verify
     *  every field round-trips byte-for-byte. */
    @Test
    void typedAttrsRoundTrip(@TempDir Path tmp) {
        int w = 4, h = 3, s = 8;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) cube[i] = i * 0.0625;
        double[] wn = new double[s];
        for (int i = 0; i < s; i++) wn[i] = 1000.0 + i * 4.0;

        IRImage img = new IRImage(w, h, s, 2,
                0.5, 0.5, "raster",
                IRMode.ABSORBANCE, 4.0,
                cube, wn,
                "", "", List.of(), List.of(), List.of());

        String path = tmp.resolve("ir_typed.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        // Probe the raw attribute types on disk: typed f64 / i64.
        // Hdf5Provider.getAttribute() dispatches on the HDF5 type class,
        // returning Double for H5T_FLOAT and Long for H5T_INTEGER —
        // so the runtime class of the returned Object is wire-type proof.
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group icRaw = study.openGroup("ir_image_cube")) {
            StorageGroup ic = Hdf5Provider.adapterForGroup(icRaw);
            Object px = ic.getAttribute("pixel_size_x");
            Object py = ic.getAttribute("pixel_size_y");
            Object res = ic.getAttribute("resolution_cm_inv");
            Object mode = ic.getAttribute("ir_mode");
            assertTrue(px instanceof Double,
                    "pixel_size_x must be H5T_FLOAT (Double) — was "
                            + (px == null ? "null" : px.getClass().getSimpleName()));
            assertTrue(py instanceof Double,
                    "pixel_size_y must be H5T_FLOAT (Double) — was "
                            + (py == null ? "null" : py.getClass().getSimpleName()));
            assertTrue(res instanceof Double,
                    "resolution_cm_inv must be H5T_FLOAT (Double) — was "
                            + (res == null ? "null" : res.getClass().getSimpleName()));
            assertTrue(mode instanceof Long,
                    "ir_mode must be H5T_INTEGER (Long) — was "
                            + (mode == null ? "null" : mode.getClass().getSimpleName()));
            assertEquals(0.5, ((Number) px).doubleValue(), 0.0);
            assertEquals(0.5, ((Number) py).doubleValue(), 0.0);
            assertEquals(4.0, ((Number) res).doubleValue(), 0.0);
            assertEquals(1L, ((Number) mode).longValue(),
                    "ir_mode i64 enum: 1 = ABSORBANCE");
        }

        // Round-trip via IRImage.readFrom.
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            IRImage read = IRImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertEquals(w, read.width());
            assertEquals(h, read.height());
            assertEquals(s, read.spectralPoints());
            assertEquals(2, read.tileSize());
            assertEquals(0.5, read.pixelSizeX(), 0.0);
            assertEquals(0.5, read.pixelSizeY(), 0.0);
            assertEquals("raster", read.scanPattern());
            assertEquals(IRMode.ABSORBANCE, read.mode());
            assertEquals(4.0, read.resolutionCmInv(), 0.0);
            assertArrayEquals(wn, read.wavenumbers(), 0.0);
            assertArrayEquals(cube, read.intensityCube(), 0.0);
        }
    }

    /** TRANSMITTANCE round-trips as i64 = 0. */
    @Test
    void typedTransmittanceMode(@TempDir Path tmp) {
        int w = 2, h = 2, s = 2;
        double[] cube = new double[w * h * s];
        double[] wn = new double[] { 1.0, 2.0 };
        IRImage img = new IRImage(w, h, s, 0,
                0.25, 0.25, "raster",
                IRMode.TRANSMITTANCE, 2.0,
                cube, wn,
                "", "", List.of(), List.of(), List.of());
        String path = tmp.resolve("ir_trans.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group icRaw = study.openGroup("ir_image_cube")) {
            StorageGroup ic = Hdf5Provider.adapterForGroup(icRaw);
            Object mode = ic.getAttribute("ir_mode");
            assertTrue(mode instanceof Long,
                    "ir_mode must be H5T_INTEGER (Long)");
            assertEquals(0L, ((Number) mode).longValue(),
                    "ir_mode i64 enum: 0 = TRANSMITTANCE");
        }
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            IRImage read = IRImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertEquals(IRMode.TRANSMITTANCE, read.mode());
        }
    }

    /** Legacy VL-string wire-form (pre-fix Java + ObjC): construct the
     *  on-disk shape by hand via {@code Hdf5Group} primitives, then
     *  verify {@link IRImage#readFrom} still parses it. Guards
     *  existing .tio files against regression. */
    @Test
    void legacyStringAttrsStillReadable(@TempDir Path tmp) {
        int w = 2, h = 2, s = 3;
        double[] cube = new double[w * h * s];
        for (int i = 0; i < cube.length; i++) cube[i] = i;
        double[] wn = new double[] { 100.0, 200.0, 300.0 };

        // First create a real .tio shell + an ir_image_cube via the
        // current writer, then *overwrite* the typed attrs with the
        // legacy string forms to simulate an older .tio.
        IRImage seed = new IRImage(w, h, s, 0,
                0.0, 0.0, "raster",
                IRMode.TRANSMITTANCE, 0.0,
                cube, wn,
                "", "", List.of(), List.of(), List.of());
        String path = tmp.resolve("ir_legacy.tio").toString();
        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.createGroup("study")) {
            seed.writeTo(Hdf5Provider.adapterForGroup(study));
        }

        // Now overwrite the four attrs with legacy string-typed
        // forms. Hdf5Group.setStringAttribute first deletes any
        // existing attribute, so this fully swaps the wire type.
        try (Hdf5File f = Hdf5File.open(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group ic = study.openGroup("ir_image_cube")) {
            ic.setStringAttribute("pixel_size_x", "0.75");
            ic.setStringAttribute("pixel_size_y", "0.75");
            ic.setStringAttribute("resolution_cm_inv", "6.5");
            ic.setStringAttribute("ir_mode", "absorbance");
        }

        // The new reader must still parse the legacy wire-form.
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            IRImage read = IRImage.readFrom(Hdf5Provider.adapterForGroup(study));
            assertNotNull(read);
            assertEquals(0.75, read.pixelSizeX(), 0.0,
                    "legacy string-form pixel_size_x parses");
            assertEquals(0.75, read.pixelSizeY(), 0.0,
                    "legacy string-form pixel_size_y parses");
            assertEquals(6.5, read.resolutionCmInv(), 0.0,
                    "legacy string-form resolution_cm_inv parses");
            assertEquals(IRMode.ABSORBANCE, read.mode(),
                    "legacy string-form ir_mode='absorbance' parses to ABSORBANCE");
        }
    }
}
