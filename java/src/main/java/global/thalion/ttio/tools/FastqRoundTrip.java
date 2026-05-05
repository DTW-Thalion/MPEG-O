/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.exporters.FastqWriter;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.FastqReader;

import java.io.IOException;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Java mirror of {@code python -m ttio.tools.fastq_export_cli} for
 * the cross-language FASTQ round-trip conformance harness.
 *
 * <p>Reads a FASTQ file via {@link FastqReader} (auto-detect Phred),
 * then writes it back to the destination via {@link FastqWriter}.
 * Phred+33 is the canonical output offset (Phred+64 inputs are
 * normalised to +33 internally).</p>
 *
 * <p>Usage:</p>
 * <pre>
 *   java -cp ... global.thalion.ttio.tools.FastqRoundTrip \\
 *     &lt;in.fq&gt; &lt;out.fq&gt;
 * </pre>
 *
 * <p>Exit codes:
 *   0 = success, 1 = argument error, 2 = read/write failure.</p>
 */
public final class FastqRoundTrip {

    private FastqRoundTrip() {}

    public static void main(String[] args) {
        if (args.length != 2) {
            System.err.println("usage: FastqRoundTrip <in.fq> <out.fq>");
            System.exit(1);
        }
        Path in = Paths.get(args[0]);
        Path out = Paths.get(args[1]);
        try {
            WrittenGenomicRun run = new FastqReader(in).read("");
            FastqWriter.write(run, out);
        } catch (IOException e) {
            System.err.println("error: " + e.getMessage());
            System.exit(2);
        }
    }
}
