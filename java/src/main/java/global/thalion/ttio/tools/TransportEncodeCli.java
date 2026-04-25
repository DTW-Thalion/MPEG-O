/*
 * TTI-O Java Implementation — v0.10 M70.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.TransportWriter;

import java.nio.file.Path;

/**
 * Encode a .tio file as an TTI-O transport stream. Parallel to
 * Python {@code ttio.tools.transport_encode_cli} and ObjC
 * {@code TtioTransportEncode}.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/classes:&lt;deps&gt; \
 *        global.thalion.ttio.tools.TransportEncodeCli \
 *        input.tio output.tis
 * </pre>
 */
public final class TransportEncodeCli {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: TransportEncodeCli <input.tio> <output.tis>");
            System.exit(2);
        }
        String input = args[0];
        String output = args[1];
        try (SpectralDataset ds = SpectralDataset.open(input);
             TransportWriter tw = new TransportWriter(Path.of(output))) {
            tw.writeDataset(ds);
        }
    }
}
