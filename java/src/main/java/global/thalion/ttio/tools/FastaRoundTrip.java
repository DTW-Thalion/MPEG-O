/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.exporters.FastaWriter;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.importers.FastaReader;

import java.io.IOException;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Java mirror of {@code python -m ttio.tools.fasta_export_cli} for
 * the cross-language FASTA round-trip conformance harness.
 *
 * <p>Reads a FASTA file via {@link FastaReader#readReference}, then
 * writes it back to the destination via {@link FastaWriter#writeReference}
 * with the requested line width. The destination output is the
 * canonical FASTA the conformance harness diffs against the Python
 * + ObjC outputs.</p>
 *
 * <p>Usage:</p>
 * <pre>
 *   java -cp ... global.thalion.ttio.tools.FastaRoundTrip \\
 *     &lt;in.fa&gt; &lt;out.fa&gt; [line_width]
 * </pre>
 *
 * <p>Exit codes:
 *   0 = success, 1 = argument error, 2 = read/write failure.</p>
 */
public final class FastaRoundTrip {

    private FastaRoundTrip() {}

    public static void main(String[] args) {
        if (args.length < 2 || args.length > 3) {
            System.err.println(
                "usage: FastaRoundTrip <in.fa> <out.fa> [line_width]"
            );
            System.exit(1);
        }
        Path in = Paths.get(args[0]);
        Path out = Paths.get(args[1]);
        int lineWidth = (args.length == 3)
            ? Integer.parseInt(args[2])
            : FastaWriter.DEFAULT_LINE_WIDTH;
        try {
            ReferenceImport ref = new FastaReader(in).readReference();
            FastaWriter.writeReference(ref, out, lineWidth, null, true);
        } catch (IOException e) {
            System.err.println("error: " + e.getMessage());
            System.exit(2);
        }
    }
}
