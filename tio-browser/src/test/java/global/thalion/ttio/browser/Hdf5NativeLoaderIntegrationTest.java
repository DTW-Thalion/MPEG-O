package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/**
 * End-to-end test of {@link Hdf5NativeLoader}: invokes ensureLoaded,
 * then calls H5.H5get_libversion(int[]) and asserts HDF5 1.14. Skips
 * gracefully if the running JAR doesn't bundle natives for this
 * platform (Phase D wires the bundling).
 */
class Hdf5NativeLoaderIntegrationTest {

    @Test
    void loadedHdf5ReportsVersion1_14() {
        Assumptions.assumeTrue(
            Hdf5NativeLoader.class.getResourceAsStream(
                "/native/linux-x64/hdf5/libhdf5.so.310") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/mac-aarch64/hdf5/libhdf5.310.dylib") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/win-x64/hdf5/hdf5.dll") != null,
            "no platform's HDF5 natives bundled in this build (Phase D wires it)");
        Hdf5NativeLoader.ensureLoaded();
        int[] v = new int[3];
        hdf.hdf5lib.H5.H5get_libversion(v);
        assertEquals(1, v[0], "HDF5 major version should be 1");
        assertEquals(14, v[1], "HDF5 minor version should be 14");
        assertNotNull(Hdf5NativeLoader.tempDir());
    }
}
