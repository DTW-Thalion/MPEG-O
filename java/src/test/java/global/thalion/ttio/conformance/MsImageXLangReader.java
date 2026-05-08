/* TTI-O Java conformance helpers / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** CLI: reads a .tio's MSImage.mzAxis via SpectralDataset.open() + .image()
 *  (the realistic tio-browser code path) and writes the bytes to stdout in
 *  little-endian float64. Used by python/tests/conformance/test_msimage_xlang.py.
 */
public final class MsImageXLangReader {

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: MsImageXLangReader <path.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            MSImage img = ds.image();
            if (img == null) {
                System.err.println("no MSImage in " + args[0]);
                System.exit(3);
            }
            double[] axis = img.mzAxis();
            ByteBuffer buf = ByteBuffer.allocate(axis.length * 8)
                    .order(ByteOrder.LITTLE_ENDIAN);
            for (double v : axis) buf.putDouble(v);
            System.out.write(buf.array());
            System.out.flush();
        }
    }
}
