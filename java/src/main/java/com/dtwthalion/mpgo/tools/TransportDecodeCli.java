/*
 * MPEG-O Java Implementation — v0.10 M70.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.tools;

import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.transport.TransportReader;

import java.nio.file.Path;

/**
 * Decode an MPEG-O transport stream into a .mpgo file. Parallel to
 * Python {@code mpeg_o.tools.transport_decode_cli} and ObjC
 * {@code MpgoTransportDecode}.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/classes:&lt;deps&gt; \
 *        com.dtwthalion.mpgo.tools.TransportDecodeCli \
 *        input.mots output.mpgo
 * </pre>
 */
public final class TransportDecodeCli {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: TransportDecodeCli <input.mots> <output.mpgo>");
            System.exit(2);
        }
        try (TransportReader tr = new TransportReader(Path.of(args[0]));
             SpectralDataset ds = tr.materializeTo(args[1])) {
            // just materialize
        }
    }
}
