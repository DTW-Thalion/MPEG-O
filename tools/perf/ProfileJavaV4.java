/*
 * tools/perf/ProfileJavaV4.java — V4 codec throughput on real or
 * synthetic input. Java analogue of tools/perf/profile_objc_v4.m.
 *
 * Inputs come from one of:
 *   - synthetic 100K reads × 100 bp Q20-Q40 LCG (default)
 *   - a pre-extracted corpus from /tmp/{name}_v4_qual.bin etc.,
 *     written by tools/perf/htscodecs_compare.sh.
 *
 * Usage:
 *   java -Djava.library.path=... -cp ... tools.perf.ProfileJavaV4
 *   java -Djava.library.path=... -cp ... tools.perf.ProfileJavaV4 chr22
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package tools.perf;

import global.thalion.ttio.codecs.FqzcompNx16Z;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

public final class ProfileJavaV4 {

    public static void main(String[] args) throws Exception {
        byte[] qualities;
        int[] lens;
        int[] rev;
        String label;

        if (args.length > 0) {
            String corpus = args[0];
            Path qpath = Path.of("/tmp", corpus + "_v4_qual.bin");
            Path lpath = Path.of("/tmp", corpus + "_v4_lens.bin");
            Path fpath = Path.of("/tmp", corpus + "_v4_flags.bin");
            if (!Files.exists(qpath) || !Files.exists(lpath) || !Files.exists(fpath)) {
                System.err.println(
                    "ERROR: corpus '" + corpus + "' inputs missing in /tmp.\n"
                    + "Run: bash tools/perf/htscodecs_compare.sh");
                System.exit(1);
            }
            qualities = Files.readAllBytes(qpath);
            byte[] lensBlob  = Files.readAllBytes(lpath);
            byte[] flagsBlob = Files.readAllBytes(fpath);
            int nReads = lensBlob.length / 4;
            ByteBuffer lensBb  = ByteBuffer.wrap(lensBlob).order(ByteOrder.LITTLE_ENDIAN);
            ByteBuffer flagsBb = ByteBuffer.wrap(flagsBlob).order(ByteOrder.LITTLE_ENDIAN);
            lens = new int[nReads];
            rev  = new int[nReads];
            for (int i = 0; i < nReads; i++) {
                lens[i] = lensBb.getInt();
                int sam = flagsBb.getInt();
                rev[i] = (sam & 16) != 0 ? 1 : 0;
            }
            label = corpus;
        } else {
            int nReads = 100_000;
            int readLen = 100;
            int nQual = nReads * readLen;
            qualities = new byte[nQual];
            long s = 0xBEEFL;
            for (int i = 0; i < nQual; i++) {
                s = s * 6364136223846793005L + 1442695040888963407L;
                qualities[i] = (byte) (33 + 20 + (int) ((s >>> 32) & 0xFFFFFFFFL) % 21);
            }
            lens = new int[nReads];
            rev  = new int[nReads];
            for (int i = 0; i < nReads; i++) {
                lens[i] = readLen;
                rev[i]  = (i & 7) == 0 ? 1 : 0;
            }
            label = "synth-10MiB";
        }

        long nQual = qualities.length;
        long nReads = lens.length;
        double mib = nQual / (1024.0 * 1024.0);
        boolean jniLoaded = global.thalion.ttio.codecs.TtioRansNative.isAvailable();
        System.err.printf(
            "Java V4 bench [%s]: JNI=%s, %d reads, %d qualities (%.2f MiB)%n",
            label, jniLoaded ? "loaded" : "MISSING",
            nReads, nQual, mib);

        FqzcompNx16Z.EncodeOptions opts =
            new FqzcompNx16Z.EncodeOptions().preferV4(true);

        long t0 = System.nanoTime();
        byte[] enc = FqzcompNx16Z.encode(qualities, lens, rev, opts);
        double tEnc = (System.nanoTime() - t0) / 1e9;
        int version = enc[4] & 0xff;

        t0 = System.nanoTime();
        FqzcompNx16Z.DecodeResult result = FqzcompNx16Z.decode(enc, rev);
        double tDec = (System.nanoTime() - t0) / 1e9;
        boolean ok = java.util.Arrays.equals(result.qualities(), qualities);

        System.err.printf(
            "Java V4 [%s]: V%d roundtrip=%s out=%d bytes (B/qual=%.4f)%n"
            + "  encode: %.3f s   %.2f MiB/s%n"
            + "  decode: %.3f s   %.2f MiB/s%n",
            label, version, ok ? "OK" : "FAIL",
            enc.length, (double) enc.length / nQual,
            tEnc, mib / tEnc, tDec, mib / tDec);
        System.exit(ok ? 0 : 4);
    }
}
