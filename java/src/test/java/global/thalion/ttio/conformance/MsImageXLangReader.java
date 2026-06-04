/* TTI-O Java conformance helpers / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.Enums;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** CLI: reads a .tio MSImage fields via SpectralDataset.open() and imageForKind(MS).
 *  Writes data to stdout as little-endian float64.
 *
 *  Usage: MsImageXLangReader path.tio [--field=mz_axis|pixel_size_x|pixel_size_y]
 *  Default field is mz_axis. mz_axis emits N*8 bytes; pixel_size_x/y emit 8 bytes each.
 *
 *  Used by python/tests/conformance/test_msimage_xlang.py.
 */
public final class MsImageXLangReader {

    public static void main(String[] args) throws Exception {
        if (args.length < 1 || args.length > 2) {
            System.err.println(
                "usage: MsImageXLangReader <path.tio> [--field=mz_axis|pixel_size_x|pixel_size_y]");
            System.exit(2);
        }
        String field = "mz_axis";
        if (args.length == 2 && args[1].startsWith("--field=")) {
            field = args[1].substring("--field=".length());
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            MSImage img = (MSImage) ds.imageForKind(Enums.ImageKind.MS);
            if (img == null) {
                System.err.println("no MSImage in " + args[0]);
                System.exit(3);
            }
            switch (field) {
                case "mz_axis" -> {
                    double[] axis = img.mzAxis();
                    ByteBuffer buf = ByteBuffer.allocate(axis.length * 8)
                            .order(ByteOrder.LITTLE_ENDIAN);
                    for (double v : axis) buf.putDouble(v);
                    System.out.write(buf.array());
                }
                case "pixel_size_x" -> {
                    ByteBuffer buf = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
                    buf.putDouble(img.pixelSizeX());
                    System.out.write(buf.array());
                }
                case "pixel_size_y" -> {
                    ByteBuffer buf = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
                    buf.putDouble(img.pixelSizeY());
                    System.out.write(buf.array());
                }
                default -> {
                    System.err.println("unknown field: " + field);
                    System.exit(4);
                }
            }
            System.out.flush();
        }
    }
}
