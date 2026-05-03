/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.FqzcompNx16Z;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Tiny CLI mirroring objc/Tools/TtioM94zV4Cli.m and the Python harness
 * for cross-language byte-equality tests.
 *
 * <p>Reads {@code qual.bin} (raw uint8 quality bytes), {@code lens.bin}
 * (uint32 LE per-read lengths), {@code flags.bin} (uint32 LE per-read
 * SAM flags — bit 4 = SAM_REVERSE), V4-encodes via JNI, writes the full
 * M94Z V4 stream to {@code out.fqz}.
 *
 * <p>Usage: {@code java -Djava.library.path=<native_dir> -cp <jar>
 * global.thalion.ttio.tools.M94zV4Cli qual.bin lens.bin flags.bin out.fqz}
 */
public final class M94zV4Cli {
    public static void main(String[] args) throws IOException {
        if (args.length != 4) {
            System.err.println(
                "usage: M94zV4Cli qual.bin lens.bin flags.bin out.fqz");
            System.exit(1);
        }
        byte[] qualities = Files.readAllBytes(Path.of(args[0]));
        byte[] lensBlob  = Files.readAllBytes(Path.of(args[1]));
        byte[] flagsBlob = Files.readAllBytes(Path.of(args[2]));
        ByteBuffer lensBb  = ByteBuffer.wrap(lensBlob).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer flagsBb = ByteBuffer.wrap(flagsBlob).order(ByteOrder.LITTLE_ENDIAN);
        int nReads = lensBlob.length / 4;
        int[] lens = new int[nReads];
        int[] rev  = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            lens[i] = lensBb.getInt();
            int sam = flagsBb.getInt();
            rev[i] = (sam & 16) != 0 ? 1 : 0;
        }
        FqzcompNx16Z.EncodeOptions opts =
            new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] out = FqzcompNx16Z.encode(qualities, lens, rev, opts);
        Files.write(Path.of(args[3]), out);
        System.err.printf("Java V4: %d qualities -> %d bytes (B/qual=%.4f)%n",
            qualities.length, out.length,
            (double) out.length / qualities.length);
    }
}
