/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.RefDiffV2;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * CLI tool for ref_diff v2 cross-language byte-equality tests.
 *
 * <p>Reads pre-extracted binary blobs:
 * <ul>
 *   <li>{@code sequences.bin} — concatenated uint8 ACGTN ASCII bytes</li>
 *   <li>{@code offsets.bin}   — uint64 LE, n_reads + 1 entries</li>
 *   <li>{@code positions.bin} — int64 LE per-read 1-based POS</li>
 *   <li>{@code cigars.txt}    — UTF-8 text, one CIGAR per line, exactly n_reads lines</li>
 *   <li>{@code reference.bin} — uint8 reference chrom bytes</li>
 *   <li>{@code reference_md5.bin} — exactly 16 bytes</li>
 *   <li>{@code reference_uri.txt} — UTF-8 text (trailing whitespace stripped)</li>
 * </ul>
 *
 * <p>Writes the encoded inline blob to {@code out.bin} (or stdout if "-").
 *
 * <p>Usage: {@code java -Djava.library.path=<native_dir> -cp <jar>
 *           global.thalion.ttio.tools.RefDiffV2Cli sequences.bin offsets.bin
 *           positions.bin cigars.txt reference.bin reference_md5.bin
 *           reference_uri.txt out.bin}
 */
public final class RefDiffV2Cli {

    public static void main(String[] args) throws IOException {
        if (args.length != 8) {
            System.err.println(
                "usage: RefDiffV2Cli sequences.bin offsets.bin positions.bin "
                + "cigars.txt reference.bin reference_md5.bin reference_uri.txt out.bin");
            System.err.println("  sequences.bin:     concatenated uint8 ACGTN read bases");
            System.err.println("  offsets.bin:       uint64 LE, n_reads + 1 entries");
            System.err.println("  positions.bin:     int64 LE per-read 1-based POS");
            System.err.println("  cigars.txt:        UTF-8, one CIGAR per line");
            System.err.println("  reference.bin:     uint8 reference chromosome bytes");
            System.err.println("  reference_md5.bin: exactly 16 bytes");
            System.err.println("  reference_uri.txt: UTF-8 reference URI string");
            System.err.println("  out.bin:           encoded blob output (or '-' for stdout)");
            System.exit(1);
        }

        byte[] sequences      = Files.readAllBytes(Path.of(args[0]));
        byte[] offsetsBytes   = Files.readAllBytes(Path.of(args[1]));
        byte[] positionsBytes = Files.readAllBytes(Path.of(args[2]));
        List<String> cigarsList = Files.readAllLines(Path.of(args[3]));
        byte[] reference      = Files.readAllBytes(Path.of(args[4]));
        byte[] md5            = Files.readAllBytes(Path.of(args[5]));
        String referenceUri   = Files.readString(Path.of(args[6])).strip();

        if (md5.length != 16) {
            System.err.printf("reference_md5 must be 16 bytes, got %d%n", md5.length);
            System.exit(1);
        }

        int n = positionsBytes.length / 8;
        if (offsetsBytes.length != (n + 1) * 8) {
            System.err.printf("offsets length mismatch: expected %d bytes, got %d%n",
                (n + 1) * 8, offsetsBytes.length);
            System.exit(1);
        }
        if (cigarsList.size() != n) {
            System.err.printf("cigars line count mismatch: expected %d, got %d%n",
                n, cigarsList.size());
            System.exit(1);
        }

        long[] offsets   = new long[n + 1];
        long[] positions = new long[n];
        ByteBuffer offBb = ByteBuffer.wrap(offsetsBytes).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer posBb = ByteBuffer.wrap(positionsBytes).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i <= n; i++) offsets[i]   = offBb.getLong();
        for (int i = 0;  i < n; i++) positions[i] = posBb.getLong();

        String[] cigars = cigarsList.toArray(new String[0]);

        byte[] encoded = RefDiffV2.encode(
            sequences, offsets, positions, cigars,
            reference, md5, referenceUri, 10000);

        if (args[7].equals("-")) {
            try (OutputStream out = System.out) {
                out.write(encoded);
            }
        } else {
            Files.write(Path.of(args[7]), encoded);
        }
    }
}
