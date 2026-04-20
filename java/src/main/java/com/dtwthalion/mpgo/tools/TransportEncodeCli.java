/*
 * MPEG-O Java Implementation — v0.10 M70.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.tools;

import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.transport.TransportWriter;

import java.nio.file.Path;

/**
 * Encode a .mpgo file as an MPEG-O transport stream. Parallel to
 * Python {@code mpeg_o.tools.transport_encode_cli} and ObjC
 * {@code MpgoTransportEncode}.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/classes:&lt;deps&gt; \
 *        com.dtwthalion.mpgo.tools.TransportEncodeCli \
 *        input.mpgo output.mots
 * </pre>
 */
public final class TransportEncodeCli {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: TransportEncodeCli <input.mpgo> <output.mots>");
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
