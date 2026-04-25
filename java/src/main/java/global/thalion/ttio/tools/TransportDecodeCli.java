/*
 * TTI-O Java Implementation — v0.10 M70.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.TransportReader;

import java.nio.file.Path;

/**
 * Decode an TTI-O transport stream into a .tio file. Parallel to
 * Python {@code ttio.tools.transport_decode_cli} and ObjC
 * {@code TtioTransportDecode}.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/classes:&lt;deps&gt; \
 *        global.thalion.ttio.tools.TransportDecodeCli \
 *        input.tis output.tio
 * </pre>
 */
public final class TransportDecodeCli {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: TransportDecodeCli <input.tis> <output.tio>");
            System.exit(2);
        }
        try (TransportReader tr = new TransportReader(Path.of(args[0]));
             SpectralDataset ds = tr.materializeTo(args[1])) {
            // just materialize
        }
    }
}
