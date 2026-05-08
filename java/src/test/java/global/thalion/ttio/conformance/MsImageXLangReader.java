/* TTI-O Java conformance helpers / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.hdf5.Hdf5Dataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** CLI: reads a .tio's MSImage mz_axis and writes the bytes to stdout
 *  in little-endian float64. Used by python/tests/conformance/test_msimage_xlang.py.
 *
 *  Reads /study/image_cube/mz_axis directly via the low-level HDF5 API
 *  to avoid the N-D dataset limitation in the SpectralDataset.open() path
 *  (the intensity cube is 3D and cannot be opened via Hdf5Group.openDataset
 *  which assumes 1D layout).
 */
public final class MsImageXLangReader {

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: MsImageXLangReader <path.tio>");
            System.exit(2);
        }
        try (Hdf5File f = Hdf5File.openReadOnly(args[0]);
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study");
             Hdf5Group ic = study.openGroup("image_cube");
             Hdf5Dataset axisDs = ic.openDataset("mz_axis")) {
            double[] axis = (double[]) axisDs.readData();
            ByteBuffer buf = ByteBuffer.allocate(axis.length * 8)
                    .order(ByteOrder.LITTLE_ENDIAN);
            for (double v : axis) buf.putDouble(v);
            System.out.write(buf.array());
            System.out.flush();
        }
    }
}
