/*
 * TTI-O Java Implementation
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
        // Parse positional + flag args. Accepts --bulk (Phase 2c-T).
        String input = null, output = null;
        boolean bulk = false;
        for (String a : args) {
            if ("--bulk".equals(a)) { bulk = true; continue; }
            if (input == null) { input = a; }
            else if (output == null) { output = a; }
        }
        if (input == null || output == null) {
            System.err.println(
                "usage: TransportEncodeCli [--bulk] <input.tio> <output.tis>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(input);
             TransportWriter tw = new TransportWriter(Path.of(output))) {
            tw.setUseBulkMode(bulk);
            tw.writeDataset(ds);
        }
    }
}
