/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.MateInfoV2;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Tiny CLI mirroring objc/Tools/TtioMateInfoV2Cli.m (T10) and the
 * Python ctypes path for cross-language byte-equality tests (T11).
 *
 * <p>Reads pre-extracted binary blobs in the same shape as the Python
 * extract_mate_triples helper:
 * <ul>
 *   <li>{@code mc.bin} — int32 LE per-record mate_chrom_ids</li>
 *   <li>{@code mp.bin} — int64 LE per-record mate_positions</li>
 *   <li>{@code ts.bin} — int32 LE per-record template_lengths</li>
 *   <li>{@code oc.bin} — uint16 LE per-record own_chrom_ids</li>
 *   <li>{@code op.bin} — int64 LE per-record own_positions</li>
 * </ul>
 *
 * <p>Writes the encoded inline_v2 blob to {@code out.bin} (or stdout
 * if {@code -} is passed).
 *
 * <p>Usage: {@code java -Djava.library.path=<native_dir> -cp <jar>
 *           global.thalion.ttio.tools.MateInfoV2Cli mc.bin mp.bin ts.bin
 *           oc.bin op.bin out.bin}
 */
public final class MateInfoV2Cli {

    public static void main(String[] args) throws IOException {
        if (args.length != 6) {
            System.err.println(
                "usage: MateInfoV2Cli mc.bin mp.bin ts.bin oc.bin op.bin out.bin");
            System.err.println(
                "  mc.bin: int32 LE per-record mate_chrom_ids");
            System.err.println(
                "  mp.bin: int64 LE per-record mate_positions");
            System.err.println(
                "  ts.bin: int32 LE per-record template_lengths");
            System.err.println(
                "  oc.bin: uint16 LE per-record own_chrom_ids");
            System.err.println(
                "  op.bin: int64 LE per-record own_positions");
            System.err.println(
                "  out.bin: encoded blob output (or '-' for stdout)");
            System.exit(1);
        }

        byte[] mcBytes = Files.readAllBytes(Path.of(args[0]));
        byte[] mpBytes = Files.readAllBytes(Path.of(args[1]));
        byte[] tsBytes = Files.readAllBytes(Path.of(args[2]));
        byte[] ocBytes = Files.readAllBytes(Path.of(args[3]));
        byte[] opBytes = Files.readAllBytes(Path.of(args[4]));

        int n = mcBytes.length / 4;
        if (mpBytes.length != n * 8 || tsBytes.length != n * 4
                || ocBytes.length != n * 2 || opBytes.length != n * 8) {
            System.err.printf(
                "input length mismatch: n=%d, mc=%d, mp=%d, ts=%d, oc=%d, op=%d%n",
                n, mcBytes.length, mpBytes.length, tsBytes.length,
                ocBytes.length, opBytes.length);
            System.exit(1);
        }

        int[]   mc = new int[n];
        long[]  mp = new long[n];
        int[]   ts = new int[n];
        short[] oc = new short[n];
        long[]  op = new long[n];

        ByteBuffer mcBb = ByteBuffer.wrap(mcBytes).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer mpBb = ByteBuffer.wrap(mpBytes).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer tsBb = ByteBuffer.wrap(tsBytes).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer ocBb = ByteBuffer.wrap(ocBytes).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer opBb = ByteBuffer.wrap(opBytes).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < n; i++) {
            mc[i] = mcBb.getInt();
            mp[i] = mpBb.getLong();
            ts[i] = tsBb.getInt();
            oc[i] = ocBb.getShort();
            op[i] = opBb.getLong();
        }

        byte[] encoded = MateInfoV2.encode(mc, mp, ts, oc, op);

        if (args[5].equals("-")) {
            try (OutputStream out = System.out) {
                out.write(encoded);
            }
        } else {
            Files.write(Path.of(args[5]), encoded);
        }
    }
}
