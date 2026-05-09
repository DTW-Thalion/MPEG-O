/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.FqzcompNx16Z;
import global.thalion.ttio.codecs.MateInfoV2;
import global.thalion.ttio.codecs.RefDiffV2;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-restoration smoke tests for the V2 codec CLI helpers
 * ({@link RefDiffV2Cli} + {@link MateInfoV2Cli}). Both classes were at
 * 0% line coverage in the bundle JaCoCo report before this test landed.
 *
 * <p>Uses the same in-process pattern as {@link CliSmokeTest}: invokes
 * {@code main(String[])} directly so JaCoCo (which only attaches to the
 * surefire test JVM) records the executed lines. Subprocess runs from
 * {@code C1CliMainsTest} would not register here.</p>
 *
 * <p>Both CLIs are guarded with {@link EnabledIf} on the underlying
 * native availability — the codec entry points delegate to the
 * {@code libttio_rans} JNI bridge. When the native library is missing
 * (no {@code -Djava.library.path}) the tests are skipped rather than
 * blowing up; CI provides the lib path so the tests run there.</p>
 *
 * <p>Branches not covered here (intentional):</p>
 * <ul>
 *   <li>The {@code args.length != N} usage-banner branch and the
 *       per-argument length-mismatch branches both terminate via
 *       {@link System#exit}. Java 21 forbids
 *       {@code System.setSecurityManager}, so these paths can only be
 *       reached from the subprocess runner — and subprocess runs are
 *       invisible to JaCoCo. The happy-path coverage delivered here
 *       is the maximum achievable in-process.</li>
 * </ul>
 */
class V2CliSmokeTest {

    static boolean refDiffNativeAvailable() {
        return RefDiffV2.isAvailable();
    }

    static boolean mateInfoNativeAvailable() {
        return MateInfoV2.isAvailable();
    }

    static boolean fqzNativeAvailable() {
        // M94zV4Cli explicitly opts into the V4 path, which requires
        // the libttio_rans JNI bridge. Gate on that availability.
        return global.thalion.ttio.codecs.TtioRansNative.isAvailable();
    }

    /** Run {@code action} with stdout + stderr swallowed (mirrors
     *  {@link CliSmokeTest}'s helper). Returned string is captured stdout. */
    private static String captureStdout(Runnable action) {
        PrintStream origOut = System.out;
        PrintStream origErr = System.err;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteArrayOutputStream err = new ByteArrayOutputStream();
        try {
            System.setOut(new PrintStream(out));
            System.setErr(new PrintStream(err));
            action.run();
        } finally {
            System.setOut(origOut);
            System.setErr(origErr);
        }
        return out.toString();
    }

    // ───────────────────────────────────────────────────────────────────
    // RefDiffV2Cli — happy-path, file-output (covers the file-write branch
    // of the args[7]=="-" else clause)
    // ───────────────────────────────────────────────────────────────────

    @Test
    @EnabledIf("refDiffNativeAvailable")
    @DisplayName("RefDiffV2Cli: happy-path round-trip writes encoded blob to file")
    void refDiffV2CliHappyPath(@TempDir Path tmp) throws Exception {
        // Build a deterministic per-read fixture matching RefDiffV2Test's
        // shape: 4 reads of 50 bases each, perfect-match against a small
        // reference.
        int n = 4;
        int readLen = 50;
        byte[] reference = new byte[n * 50 + 200];
        for (int i = 0; i < reference.length; i++) {
            reference[i] = (byte) "ACGT".charAt(i % 4);
        }

        byte[] sequences = new byte[n * readLen];
        long[] offsets = new long[n + 1];
        long[] positions = new long[n];
        String[] cigars = new String[n];
        for (int r = 0; r < n; r++) {
            int refPos = r * 50;
            System.arraycopy(reference, refPos, sequences, r * readLen, readLen);
            offsets[r + 1] = (r + 1) * readLen;
            positions[r] = refPos + 1;
            cigars[r] = "50M";
        }
        byte[] md5 = MessageDigest.getInstance("MD5").digest(reference);
        String referenceUri = "test://reference";

        Path seqFile = tmp.resolve("sequences.bin");
        Path offFile = tmp.resolve("offsets.bin");
        Path posFile = tmp.resolve("positions.bin");
        Path cigFile = tmp.resolve("cigars.txt");
        Path refFile = tmp.resolve("reference.bin");
        Path md5File = tmp.resolve("reference_md5.bin");
        Path uriFile = tmp.resolve("reference_uri.txt");
        Path outFile = tmp.resolve("out.bin");

        Files.write(seqFile, sequences);
        Files.write(offFile, longArrayToLeBytes(offsets));
        Files.write(posFile, longArrayToLeBytes(positions));
        Files.writeString(cigFile, String.join("\n", cigars) + "\n",
                StandardCharsets.UTF_8);
        Files.write(refFile, reference);
        Files.write(md5File, md5);
        // Trailing whitespace tests the .strip() branch in RefDiffV2Cli.
        Files.writeString(uriFile, referenceUri + "  \n", StandardCharsets.UTF_8);

        captureStdout(() -> {
            try {
                RefDiffV2Cli.main(new String[]{
                    seqFile.toString(),
                    offFile.toString(),
                    posFile.toString(),
                    cigFile.toString(),
                    refFile.toString(),
                    md5File.toString(),
                    uriFile.toString(),
                    outFile.toString()
                });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });

        // Outcome assertion: a non-empty RDF2-magic blob is on disk.
        assertTrue(Files.exists(outFile), "out.bin should be written");
        byte[] encoded = Files.readAllBytes(outFile);
        assertTrue(encoded.length > 4, "encoded blob should not be empty");
        assertEquals('R', (char) encoded[0]);
        assertEquals('D', (char) encoded[1]);
        assertEquals('F', (char) encoded[2]);
        assertEquals('2', (char) encoded[3]);

        // Cross-check: feeding the same blob back into the codec must
        // recover the original sequences. This proves the CLI wrote
        // genuine round-trippable bytes, not just *something*.
        RefDiffV2.Pair decoded = RefDiffV2.decode(
                encoded, positions, cigars, reference, n, n * (long) readLen);
        assertArrayEquals(sequences, decoded.sequences);
        assertArrayEquals(offsets, decoded.offsets);
    }

    // ───────────────────────────────────────────────────────────────────
    // RefDiffV2Cli — stdout-output branch ("-" sentinel for args[7])
    // ───────────────────────────────────────────────────────────────────

    @Test
    @EnabledIf("refDiffNativeAvailable")
    @DisplayName("RefDiffV2Cli: \"-\" out path writes encoded blob to stdout")
    void refDiffV2CliStdoutOutput(@TempDir Path tmp) throws Exception {
        // Tiny single-read fixture. We only care about the stdout-write
        // branch here; round-trip parity is asserted in the file test.
        int n = 1;
        int readLen = 8;
        byte[] reference = new byte[16];
        for (int i = 0; i < reference.length; i++) {
            reference[i] = (byte) "ACGT".charAt(i % 4);
        }
        byte[] sequences = new byte[readLen];
        System.arraycopy(reference, 0, sequences, 0, readLen);

        long[] offsets = { 0, readLen };
        long[] positions = { 1 };
        String[] cigars = { "8M" };
        byte[] md5 = MessageDigest.getInstance("MD5").digest(reference);
        String uri = "test://stdout";

        Path seqFile = tmp.resolve("sequences.bin");
        Path offFile = tmp.resolve("offsets.bin");
        Path posFile = tmp.resolve("positions.bin");
        Path cigFile = tmp.resolve("cigars.txt");
        Path refFile = tmp.resolve("reference.bin");
        Path md5File = tmp.resolve("reference_md5.bin");
        Path uriFile = tmp.resolve("reference_uri.txt");

        Files.write(seqFile, sequences);
        Files.write(offFile, longArrayToLeBytes(offsets));
        Files.write(posFile, longArrayToLeBytes(positions));
        Files.writeString(cigFile, cigars[0] + "\n", StandardCharsets.UTF_8);
        Files.write(refFile, reference);
        Files.write(md5File, md5);
        Files.writeString(uriFile, uri, StandardCharsets.UTF_8);

        // Use the captureStdout helper so the binary blob doesn't spam
        // surefire's log; we read the captured bytes back out instead.
        // Note: captureStdout uses ByteArrayOutputStream for stdout; the
        // CLI writes binary bytes to System.out, which is fine because
        // PrintStream forwards write(byte[]) verbatim.
        ByteArrayOutputStream capturedOut = new ByteArrayOutputStream();
        PrintStream origOut = System.out;
        PrintStream origErr = System.err;
        try {
            System.setOut(new PrintStream(capturedOut));
            System.setErr(new PrintStream(new ByteArrayOutputStream()));
            try {
                RefDiffV2Cli.main(new String[]{
                    seqFile.toString(), offFile.toString(),
                    posFile.toString(), cigFile.toString(),
                    refFile.toString(), md5File.toString(),
                    uriFile.toString(), "-"
                });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        } finally {
            System.setOut(origOut);
            System.setErr(origErr);
        }
        byte[] stdoutBytes = capturedOut.toByteArray();
        assertTrue(stdoutBytes.length > 4,
            "stdout should contain non-empty encoded blob");
        assertEquals('R', (char) stdoutBytes[0]);
        assertEquals('D', (char) stdoutBytes[1]);
        assertEquals('F', (char) stdoutBytes[2]);
        assertEquals('2', (char) stdoutBytes[3]);
    }

    // ───────────────────────────────────────────────────────────────────
    // MateInfoV2Cli — happy-path, file-output
    // ───────────────────────────────────────────────────────────────────

    @Test
    @EnabledIf("mateInfoNativeAvailable")
    @DisplayName("MateInfoV2Cli: happy-path round-trip writes encoded blob to file")
    void mateInfoV2CliHappyPath(@TempDir Path tmp) throws Exception {
        int n = 8;
        int[]   mc = new int[n];
        long[]  mp = new long[n];
        int[]   ts = new int[n];
        short[] oc = new short[n];
        long[]  op = new long[n];
        for (int i = 0; i < n; i++) {
            oc[i] = (short) (i % 4);
            op[i] = 1000L + i * 100L;
            // 80% of the time mate is on same chrom near own pos
            // (matches MateInfoV2 codec's main compression path).
            mc[i] = oc[i] & 0xFFFF;
            mp[i] = op[i] + (i % 5) - 2;
            ts[i] = 200 + i;
        }

        Path mcFile = tmp.resolve("mc.bin");
        Path mpFile = tmp.resolve("mp.bin");
        Path tsFile = tmp.resolve("ts.bin");
        Path ocFile = tmp.resolve("oc.bin");
        Path opFile = tmp.resolve("op.bin");
        Path outFile = tmp.resolve("out.bin");

        Files.write(mcFile, intArrayToLeBytes(mc));
        Files.write(mpFile, longArrayToLeBytes(mp));
        Files.write(tsFile, intArrayToLeBytes(ts));
        Files.write(ocFile, shortArrayToLeBytes(oc));
        Files.write(opFile, longArrayToLeBytes(op));

        captureStdout(() -> {
            try {
                MateInfoV2Cli.main(new String[]{
                    mcFile.toString(), mpFile.toString(), tsFile.toString(),
                    ocFile.toString(), opFile.toString(), outFile.toString()
                });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });

        assertTrue(Files.exists(outFile), "out.bin should be written");
        byte[] encoded = Files.readAllBytes(outFile);
        assertTrue(encoded.length > 4, "encoded blob should not be empty");
        assertEquals('M', (char) encoded[0]);
        assertEquals('I', (char) encoded[1]);
        assertEquals('v', (char) encoded[2]);
        assertEquals('2', (char) encoded[3]);

        // Round-trip parity: decode the CLI's blob and confirm we recover
        // the inputs byte-for-byte.
        MateInfoV2.Triple decoded = MateInfoV2.decode(encoded, oc, op, n);
        assertArrayEquals(mc, decoded.mateChromIds);
        assertArrayEquals(mp, decoded.matePositions);
        assertArrayEquals(ts, decoded.templateLengths);
    }

    // ───────────────────────────────────────────────────────────────────
    // MateInfoV2Cli — stdout-output branch ("-" sentinel for args[5])
    // ───────────────────────────────────────────────────────────────────

    @Test
    @EnabledIf("mateInfoNativeAvailable")
    @DisplayName("MateInfoV2Cli: \"-\" out path writes encoded blob to stdout")
    void mateInfoV2CliStdoutOutput(@TempDir Path tmp) throws Exception {
        int n = 2;
        int[]   mc = { 0, 0 };
        long[]  mp = { 1000L, 1100L };
        int[]   ts = { 200, 200 };
        short[] oc = { (short) 0, (short) 0 };
        long[]  op = { 1000L, 1100L };

        Path mcFile = tmp.resolve("mc.bin");
        Path mpFile = tmp.resolve("mp.bin");
        Path tsFile = tmp.resolve("ts.bin");
        Path ocFile = tmp.resolve("oc.bin");
        Path opFile = tmp.resolve("op.bin");

        Files.write(mcFile, intArrayToLeBytes(mc));
        Files.write(mpFile, longArrayToLeBytes(mp));
        Files.write(tsFile, intArrayToLeBytes(ts));
        Files.write(ocFile, shortArrayToLeBytes(oc));
        Files.write(opFile, longArrayToLeBytes(op));

        ByteArrayOutputStream capturedOut = new ByteArrayOutputStream();
        PrintStream origOut = System.out;
        PrintStream origErr = System.err;
        try {
            System.setOut(new PrintStream(capturedOut));
            System.setErr(new PrintStream(new ByteArrayOutputStream()));
            try {
                MateInfoV2Cli.main(new String[]{
                    mcFile.toString(), mpFile.toString(), tsFile.toString(),
                    ocFile.toString(), opFile.toString(), "-"
                });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        } finally {
            System.setOut(origOut);
            System.setErr(origErr);
        }
        byte[] stdoutBytes = capturedOut.toByteArray();
        assertTrue(stdoutBytes.length > 4,
            "stdout should contain non-empty MIv2 blob");
        assertEquals('M', (char) stdoutBytes[0]);
        assertEquals('I', (char) stdoutBytes[1]);
        assertEquals('v', (char) stdoutBytes[2]);
        assertEquals('2', (char) stdoutBytes[3]);
    }

    // ───────────────────────────────────────────────────────────────────
    // M94zV4Cli — happy-path encode of a tiny qual/lens/flags fixture
    // ───────────────────────────────────────────────────────────────────

    @Test
    @EnabledIf("fqzNativeAvailable")
    @DisplayName("M94zV4Cli: encodes qual/lens/flags fixture into M94Z V4 stream")
    void m94zV4CliHappyPath(@TempDir Path tmp) throws Exception {
        // 2 reads, 8 quality bytes each — deterministic enough that
        // FqzcompNx16Z encoder is exercised end-to-end.
        int nReads = 2;
        int qualLen = 8;
        byte[] qualities = new byte[nReads * qualLen];
        for (int i = 0; i < qualities.length; i++) qualities[i] = (byte) (32 + (i % 8));

        ByteBuffer lensBb = ByteBuffer.allocate(nReads * 4)
                .order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer flagsBb = ByteBuffer.allocate(nReads * 4)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < nReads; i++) {
            lensBb.putInt(qualLen);
            // First read forward (flag bit 4 clear), second reverse-complemented.
            flagsBb.putInt(i == 0 ? 0 : 16);
        }

        Path qualFile  = tmp.resolve("qual.bin");
        Path lensFile  = tmp.resolve("lens.bin");
        Path flagsFile = tmp.resolve("flags.bin");
        Path outFile   = tmp.resolve("out.fqz");
        Files.write(qualFile, qualities);
        Files.write(lensFile, lensBb.array());
        Files.write(flagsFile, flagsBb.array());

        // Capture stdout/stderr — the CLI prints a 1-line summary to stderr.
        captureStdout(() -> {
            try {
                M94zV4Cli.main(new String[]{
                    qualFile.toString(),
                    lensFile.toString(),
                    flagsFile.toString(),
                    outFile.toString()
                });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
        assertTrue(Files.exists(outFile), "M94Z V4 stream should be on disk");
        byte[] encoded = Files.readAllBytes(outFile);
        assertTrue(encoded.length > 0, "encoded stream should be non-empty");

        // Cross-check: the JNI-encoded blob should also round-trip
        // through the library's decode path. This guarantees the
        // CLI didn't write a corrupted blob.
        int[] rev = { 0, 1 };
        FqzcompNx16Z.DecodeResult decoded = FqzcompNx16Z.decode(encoded, rev);
        assertArrayEquals(qualities, decoded.qualities(),
            "M94Z V4 round-trip should recover the original qualities");
    }

    // ───────────────────────────────────────────────────────────────────
    // SimulatorCli.parse — flag parser unit tests (no native deps)
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("SimulatorCli.parse: positional output + every --flag value pair")
    void simulatorCliParseEveryFlag() {
        // Cover the non-default branch of every supported flag, plus
        // the implicit --output positional.
        Map<String, String> p = SimulatorCli.parse(new String[]{
            "out.tis",
            "--scan-rate", "5.0",
            "--duration", "20",
            "--ms1-fraction", "0.5",
            "--mz-min", "200",
            "--mz-max", "1500",
            "--n-peaks", "300",
            "--seed", "1234"
        });
        assertNotNull(p, "valid argv must parse");
        assertEquals("out.tis", p.get("__output"));
        assertEquals("5.0", p.get("scan-rate"));
        assertEquals("20", p.get("duration"));
        assertEquals("0.5", p.get("ms1-fraction"));
        assertEquals("200", p.get("mz-min"));
        assertEquals("1500", p.get("mz-max"));
        assertEquals("300", p.get("n-peaks"));
        assertEquals("1234", p.get("seed"));
    }

    @Test
    @DisplayName("SimulatorCli.parse: degenerate inputs return null")
    void simulatorCliParseDegenerate() {
        // Missing positional output → null.
        assertNull(SimulatorCli.parse(new String[]{"--scan-rate", "5"}),
            "argv without positional output must parse to null");
        // --flag with no value (i + 1 >= args.length branch) → null.
        assertNull(SimulatorCli.parse(new String[]{"out.tis", "--scan-rate"}),
            "trailing flag without value must parse to null");
        // Two positional args → null (the second one falls into the
        // "already have output, surplus positional" branch).
        assertNull(SimulatorCli.parse(
            new String[]{"out.tis", "extra-positional"}),
            "surplus positional must parse to null");
    }

    @Test
    @DisplayName("SimulatorCli.main: writes a non-empty .tis file with default flags")
    void simulatorCliMainHappyPath(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("smoke.tis");
        // Use a short duration to keep the simulator quick. The
        // defaults for the rest of the flags exercise the
        // {@code parsed.getOrDefault(...)} branch for every option.
        captureStdout(() -> {
            try {
                SimulatorCli.main(new String[]{
                    out.toString(),
                    "--duration", "0.5",
                    "--scan-rate", "20"
                });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
        assertTrue(Files.exists(out), "simulator should write a .tis file");
        assertTrue(Files.size(out) > 0, "simulator output should be non-empty");
    }

    // ── Internal helpers ────────────────────────────────────────────

    private static byte[] longArrayToLeBytes(long[] data) {
        ByteBuffer bb = ByteBuffer.allocate(data.length * 8)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (long v : data) bb.putLong(v);
        return bb.array();
    }

    private static byte[] intArrayToLeBytes(int[] data) {
        ByteBuffer bb = ByteBuffer.allocate(data.length * 4)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (int v : data) bb.putInt(v);
        return bb.array();
    }

    private static byte[] shortArrayToLeBytes(short[] data) {
        ByteBuffer bb = ByteBuffer.allocate(data.length * 2)
                .order(ByteOrder.LITTLE_ENDIAN);
        for (short v : data) bb.putShort(v);
        return bb.array();
    }
}
