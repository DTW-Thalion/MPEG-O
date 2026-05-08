/* TTI-O Java conformance helpers / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.RamanImage;
import global.thalion.ttio.SpectralDataset;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** CLI: reads a .tio's RamanImage.wavenumbers via SpectralDataset.open() + .ramanImage()
 *  (the realistic tio-browser code path) and writes the bytes to stdout in
 *  little-endian float64. Used by python/tests/conformance/test_raman_image_xlang.py.
 */
public final class RamanImageXLangReader {

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: RamanImageXLangReader <path.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            RamanImage img = ds.ramanImage();
            if (img == null) {
                System.err.println("no RamanImage in " + args[0]);
                System.exit(3);
            }
            double[] wn = img.wavenumbers();
            ByteBuffer buf = ByteBuffer.allocate(wn.length * 8)
                    .order(ByteOrder.LITTLE_ENDIAN);
            for (double v : wn) buf.putDouble(v);
            System.out.write(buf.array());
            System.out.flush();
        }
    }
}
