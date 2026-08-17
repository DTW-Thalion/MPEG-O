/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.Enums;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.PacketType;
import global.thalion.ttio.transport.TransportWriter;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * Encode a .tio file as an TTI-O transport stream. Parallel to
 * Python {@code ttio.tools.transport_encode_cli} and ObjC
 * {@code TtioTransportEncode}.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/classes:&lt;deps&gt; \
 *        global.thalion.ttio.tools.TransportEncodeCli \
 *        [--bulk] [--image-processed] [--compress &lt;codec&gt;] \
 *        input.tio output.tis
 * </pre>
 *
 * <p>{@code --compress} turns spectral AU channel compression on with
 * the named codec: {@code float_delta_zstd} (wire id 17), {@code zstd}
 * (id 16) or {@code zlib} (id 1).
 */
public final class TransportEncodeCli {

    public static void main(String[] args) throws Exception {
        // Parse positional + flag args.
        //   --bulk            Phase 2c-T bulk-mode v2 blobs.
        //   --image-processed Stage 5 / Task 5.6 (Deferral 1):
        //                     emit MSImage via writeImageProcessed
        //                     (sparse wire mode).
        String input = null, output = null;
        boolean bulk = false;
        boolean imageProcessed = false;
        String compress = null;
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--bulk".equals(a)) { bulk = true; continue; }
            if ("--image-processed".equals(a)) {
                imageProcessed = true;
                continue;
            }
            if ("--compress".equals(a) && i + 1 < args.length) {
                compress = args[++i];
                continue;
            }
            if (input == null) { input = a; }
            else if (output == null) { output = a; }
        }
        if (input == null || output == null) {
            System.err.println(
                "usage: TransportEncodeCli [--bulk] [--image-processed] "
                + "[--compress float_delta_zstd|zstd|zlib] "
                + "<input.tio> <output.tis>");
            System.exit(2);
        }
        if (imageProcessed) {
            // Focused affordance for the MS_IMAGE_PROCESSED cross-
            // language accessor cell. Emits a minimal v0.11 stream:
            // stream-header + IMAGE_HEADER (is_continuous=0) + N x
            // IMAGE_PIXEL + END_OF_IMAGE + EOS. Other dataset content
            // is intentionally ignored — this is not a general
            // encode override.
            try (SpectralDataset ds = SpectralDataset.open(input);
                 OutputStream out = Files.newOutputStream(Path.of(output));
                 TransportWriter tw = new TransportWriter(out)) {
                tw.writeStreamHeader("1.2",
                    ds.title(), ds.isaInvestigationId(),
                    List.of(PacketType.TRANSPORT_V0_11_FEATURE),
                    0);
                tw.writeImageProcessed(
                    (MSImage) ds.imageForKind(Enums.ImageKind.MS));
                tw.writeEndOfStream();
            }
        } else {
            try (SpectralDataset ds = SpectralDataset.open(input);
                 TransportWriter tw = new TransportWriter(Path.of(output))) {
                tw.setUseBulkMode(bulk);
                if (compress != null) {
                    tw.setUseCompression(true);
                    tw.setCompressionCodec(compress);
                }
                tw.writeDataset(ds);
            }
        }
    }
}
