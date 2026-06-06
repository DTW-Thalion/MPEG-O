/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * In-process coverage for four CLI tools that the bundle JaCoCo report
 * had at 0% line coverage: MzMLProbe, NmrMLProbe, TransportEncodeCli,
 * FastaImportBench.
 *
 * <p>Like {@link CliSmokeTest}, these run {@code main(String[])}
 * in-process because the JaCoCo agent only attaches to the surefire JVM
 * — lines run in a {@link CliSubprocessRunner} child are not recorded.
 * Only happy paths (which return without {@link System#exit(int)}) are
 * exercised here; the usage/error {@code System.exit} branches stay
 * covered by the subprocess tests in {@code C1CliMainsTest}.</p>
 */
public class CliMainsCoverageTest {

    /** Run {@code action} with stdout + stderr swallowed; return stdout. */
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

    /** Resolve a fixture under src/test/resources via the classloader. */
    private static String fixture(String name) {
        var url = CliMainsCoverageTest.class.getClassLoader().getResource(name);
        assertNotNull(url, "fixture not found on classpath: " + name);
        return url.getFile();
    }

    @Test
    @DisplayName("MzMLProbe: prints JSON for a real mzML fixture in-process")
    void mzmlProbeSmoke() {
        String stdout = captureStdout(() -> {
            try { MzMLProbe.main(new String[]{fixture("tiny.pwiz.1.1.mzML")}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(stdout.contains("{") && stdout.contains("}"),
            "MzMLProbe should print a JSON object; got: " + stdout);
        assertTrue(stdout.contains("\"spectrumCount\""),
            "MzMLProbe should print a spectrumCount key; got: " + stdout);
    }

    @Test
    @DisplayName("NmrMLProbe: prints JSON for a real nmrML fixture in-process")
    void nmrmlProbeSmoke() {
        String stdout = captureStdout(() -> {
            try { NmrMLProbe.main(new String[]{fixture("bmse000325.nmrML")}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(stdout.contains("{") && stdout.contains("}"),
            "NmrMLProbe should print a JSON object; got: " + stdout);
        assertTrue(stdout.contains("\"numberOfScans\""),
            "NmrMLProbe should print a numberOfScans key; got: " + stdout);
    }

    @Test
    @DisplayName("TransportEncodeCli: encodes a .tio fixture to a non-empty .tis in-process")
    void transportEncodeSmoke(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("encode_src.tio");
        captureStdout(() -> TtioWriteGenomicFixture.main(new String[]{tio.toString()}));
        assertTrue(Files.exists(tio), "fixture .tio should exist");
        Path tis = tmp.resolve("encode_out.tis");
        captureStdout(() -> {
            try { TransportEncodeCli.main(new String[]{tio.toString(), tis.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(tis) && Files.size(tis) > 0,
            "TransportEncodeCli should write a non-empty .tis");
    }

    @Test
    @DisplayName("FastaImportBench: imports a tiny FASTA to a .tio in-process")
    void fastaImportBenchSmoke(@TempDir Path tmp) throws Exception {
        Path fa = tmp.resolve("tiny.fa");
        Files.writeString(fa, ">chr1\nACGTACGTACGTACGTACGT\n>chr2\nTTTTGGGGCCCCAAAA\n");
        Path tio = tmp.resolve("fasta_out.tio");
        String stdout = captureStdout(() -> {
            try { FastaImportBench.main(new String[]{fa.toString(), tio.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(tio) && Files.size(tio) > 0,
            "FastaImportBench should write a non-empty .tio");
        assertTrue(stdout.contains("BENCH"),
            "FastaImportBench should print BENCH lines; got: " + stdout);
    }
}
