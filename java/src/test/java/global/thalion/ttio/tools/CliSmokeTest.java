/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.Identification;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.ProvenanceJsonParse;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-restoration smoke tests for six CLI / helper classes that
 * the bundle JaCoCo report had at 0% line coverage before this test
 * landed (PQCTool, ProvenanceJsonParse, Benchmark, DumpIdentifications,
 * TtioVerify, TtioWriteGenomicFixture).
 *
 * <p>Why this is needed in addition to the existing {@link C1CliMainsTest}
 * + {@link C1ToolsLeftoversTest}: those run mains via
 * {@link CliSubprocessRunner}, but the JaCoCo agent only attaches to the
 * surefire-spawned test JVM. Lines executed in a child {@code java}
 * subprocess are <em>not</em> recorded in {@code jacoco.exec}, so the
 * bundle report shows 0% for those classes. To gain coverage we must
 * exercise the code <em>in-process</em>.</p>
 *
 * <p>For four of the six classes (TtioVerify, DumpIdentifications,
 * TtioWriteGenomicFixture, Benchmark) the happy path returns normally
 * without any {@link System#exit(int)} call, so we can call
 * {@code main(String[])} directly. For PQCTool, only the non-verify
 * subcommands (sig-keygen, sig-sign, kem-keygen, kem-encaps, kem-decaps)
 * return without exiting; these account for the bulk of its lines so we
 * stick to those. For ProvenanceJsonParse — which is not a CLI at all,
 * just a static helper — we call its public {@code parseArray} entry
 * point with hand-rolled JSON inputs.</p>
 *
 * <p>Each test redirects {@code System.out} / {@code System.err} so the
 * tools' chatty stdout doesn't pollute the surefire log.</p>
 */
public class CliSmokeTest {

    /** Build the deterministic 100-read genomic fixture used by Benchmark,
     *  TtioVerify, and DumpIdentifications. Same shape as
     *  {@code TtioWriteGenomicFixture.main}. */
    private static Path buildGenomicFixture(Path dir, String name) throws Exception {
        Path out = dir.resolve(name);
        TtioWriteGenomicFixture.main(new String[]{out.toString()});
        assertTrue(Files.exists(out),
            "TtioWriteGenomicFixture.main should write the fixture");
        return out;
    }

    /** Build a small MS fixture with one identification, one quantification,
     *  and one provenance record. Drives the per-record formatting branches
     *  in DumpIdentifications.{identification,quantification,provenance}Record
     *  that the genomic-only fixture does not exercise. */
    private static Path buildRichMsFixture(Path dir, String name) {
        String path = dir.resolve(name).toString();
        int nSpectra = 2;
        double[] mz = { 100.0, 101.0, 200.0, 201.0 };
        double[] intensity = { 10, 20, 30, 40 };
        long[] offsets = { 0, 2 };
        int[] lengths = { 2, 2 };
        double[] rts = { 1.0, 2.0 };
        int[] msLevels = { 1, 1 };
        int[] pols = { 1, 1 };
        double[] pmzs = { 0.0, 0.0 };
        int[] pcs = { 0, 0 };
        double[] bpis = { 20.0, 40.0 };
        SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths,
                rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);

        ProvenanceRecord runProv = new ProvenanceRecord(
            1700000123L, "TTI-O CliSmokeTest writer",
            Map.of("opt", "true"),
            List.of("file:///raw/sample.raw"),
            List.of("file:///out/run_0001.tio"));

        AcquisitionRun run = new AcquisitionRun(
            "run_0001",
            Enums.AcquisitionMode.MS1_DDA,
            idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels,
            List.of(),
            List.of(runProv),
            null,
            0.0
        );

        Identification ident = new Identification(
            "run_0001", 0, "CHEBI:15377", 0.95,
            List.of("MS:1001143", "MS:1002338"));
        Quantification quant = new Quantification(
            "CHEBI:15377", "sample_001", 1234.5, "median");
        ProvenanceRecord topProv = new ProvenanceRecord(
            1700000456L, "TTI-O top-level provenance",
            Map.of("k", "v"),
            List.of("file:///in.raw"),
            List.of("file:///out.tio"));

        try (SpectralDataset ds = SpectralDataset.create(path,
                "CliSmokeTest rich MS fixture", "ISA-CLI-SMOKE",
                List.of(run), List.of(ident), List.of(quant), List.of(topProv))) {
            // close
        }
        return Path.of(path);
    }

    /** Run {@code action} with stdout + stderr swallowed. */
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
    // 1. TtioWriteGenomicFixture — happy path: writes a .tio
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("TtioWriteGenomicFixture: writes a .tio file in-process")
    void writeGenomicFixtureSmoke(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("smoke_fixture.tio");
        captureStdout(() -> TtioWriteGenomicFixture.main(new String[]{out.toString()}));
        assertTrue(Files.exists(out), "fixture .tio should exist");
        assertTrue(Files.size(out) > 0, "fixture .tio should be non-empty");

        // The static build() helper is also part of the public surface; exercise it
        // directly so any branch in the loop body is covered.
        var run = TtioWriteGenomicFixture.build();
        assertNotNull(run);
    }

    // ───────────────────────────────────────────────────────────────────
    // 2. TtioVerify — happy path: reads a fixture, prints JSON summary
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("TtioVerify: prints JSON summary of a real fixture in-process")
    void ttioVerifySmoke(@TempDir Path tmp) throws Exception {
        Path src = buildGenomicFixture(tmp, "verify_smoke.tio");
        String stdout = captureStdout(() ->
            TtioVerify.main(new String[]{src.toString()}));
        assertTrue(stdout.contains("\"title\""),
            "TtioVerify should print a JSON title key; got: " + stdout);
        assertTrue(stdout.contains("\"genomic_runs\""),
            "TtioVerify should print a genomic_runs block; got: " + stdout);
        assertTrue(stdout.contains("\"identification_count\""));
    }

    // ───────────────────────────────────────────────────────────────────
    // 3. DumpIdentifications — happy path: dumps sections to stdout
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("DumpIdentifications: dumps sections from a rich MS fixture in-process")
    void dumpIdentificationsSmoke(@TempDir Path tmp) throws Exception {
        // The MS fixture has identifications + quantifications + per-run +
        // top-level provenance, so every per-record formatter branch
        // (identificationRecord/quantificationRecord/provenanceRecord) is
        // hit, plus the per-run-provenance loop in dump().
        Path src = buildRichMsFixture(tmp, "dump_smoke.tio");
        String stdout = captureStdout(() ->
            DumpIdentifications.main(new String[]{src.toString()}));
        assertTrue(stdout.startsWith("{"),
            "DumpIdentifications should print a JSON object; got start: "
            + stdout.substring(0, Math.min(80, stdout.length())));
        assertTrue(stdout.contains("identifications"));
        assertTrue(stdout.contains("quantifications"));
        assertTrue(stdout.contains("provenance"));
        assertTrue(stdout.contains("CHEBI:15377"),
            "should mention identified compound");
        assertTrue(stdout.contains("ms_per_run_provenance"),
            "should include per-run provenance section");

        // Also exercise the static dump() entry directly so any branch in
        // the run-iteration loop is covered without going through main().
        String blob = DumpIdentifications.dump(src.toString());
        assertNotNull(blob);
        assertTrue(blob.startsWith("{"));
    }

    // ───────────────────────────────────────────────────────────────────
    // 4. Benchmark — happy path: encode + decode timing on a fixture
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("Benchmark: writes a JSON results file from a real fixture in-process")
    void benchmarkSmoke(@TempDir Path tmp) throws Exception {
        Path src = buildGenomicFixture(tmp, "bench_smoke.tio");
        Path results = tmp.resolve("bench_results.json");
        captureStdout(() -> {
            try {
                Benchmark.main(new String[]{src.toString(), results.toString()});
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
        assertTrue(Files.exists(results),
            "Benchmark should write the results JSON file");
        String body = Files.readString(results);
        assertTrue(body.contains("\"language\""), "results should carry language key");
        assertTrue(body.contains("java"), "results should self-identify as java");
        assertTrue(body.contains("transport_encode_per_au"),
            "results should carry the per-AU encode scenario");
        assertTrue(body.contains("transport_decode_bulk"),
            "results should carry the bulk decode scenario");
    }

    // ───────────────────────────────────────────────────────────────────
    // 5. PQCTool — drive every non-System.exit subcommand in-process
    //    (the *-verify subcommands always System.exit, so those are still
    //    only exercised by C1CliMainsTest's subprocess runs).
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("PQCTool: sig-keygen + sig-sign + kem-keygen + kem-encaps + kem-decaps in-process")
    void pqcToolSmoke(@TempDir Path tmp) throws Exception {
        // BouncyCastle bcprov-jdk18on is on the main classpath (see pom.xml
        // line 85), so PostQuantumCrypto wires up at compile-time. No
        // gating needed — a missing BC would already break compilation.

        Path pk = tmp.resolve("sig_pk.bin");
        Path sk = tmp.resolve("sig_sk.bin");
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"sig-keygen",
                pk.toString(), sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(pk) && Files.size(pk) > 0,
            "sig-keygen should write a non-empty public key");
        assertTrue(Files.exists(sk) && Files.size(sk) > 0,
            "sig-keygen should write a non-empty secret key");

        Path msg = tmp.resolve("msg.bin");
        Path sig = tmp.resolve("sig.bin");
        Files.write(msg, "smoke message for sig-sign".getBytes());
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"sig-sign",
                sk.toString(), msg.toString(), sig.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(sig) && Files.size(sig) > 0,
            "sig-sign should write a non-empty signature");

        Path kpk = tmp.resolve("kem_pk.bin");
        Path ksk = tmp.resolve("kem_sk.bin");
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"kem-keygen",
                kpk.toString(), ksk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(kpk) && Files.size(kpk) > 0);
        assertTrue(Files.exists(ksk) && Files.size(ksk) > 0);

        Path ct = tmp.resolve("ct.bin");
        Path ss1 = tmp.resolve("ss1.bin");
        Path ss2 = tmp.resolve("ss2.bin");
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"kem-encaps",
                kpk.toString(), ct.toString(), ss1.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(ct) && Files.size(ct) > 0);
        assertTrue(Files.exists(ss1) && Files.size(ss1) > 0);

        captureStdout(() -> {
            try { PQCTool.main(new String[]{"kem-decaps",
                ksk.toString(), ct.toString(), ss2.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        assertTrue(Files.exists(ss2) && Files.size(ss2) > 0);
        assertArrayEquals(Files.readAllBytes(ss1), Files.readAllBytes(ss2),
            "kem-encaps and kem-decaps shared secrets should match");
    }

    @Test
    @DisplayName("PQCTool: hdf5-sign + provider-sign on a real .tio in-process")
    void pqcToolSignDataset(@TempDir Path tmp) throws Exception {
        // Build a real MS fixture so HDF5 datasets exist on disk.
        Path tio = buildRichMsFixture(tmp, "pqc_sign_smoke.tio");
        Path pk = tmp.resolve("hpk.bin");
        Path sk = tmp.resolve("hsk.bin");
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"sig-keygen",
                pk.toString(), sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });

        // hdf5-sign returns normally on success (only hdf5-verify System.exits).
        // Path matches the canonical TTI-O layout used by C1RichFixturesTest.
        // intensity_values is float64 → covers the H5T_FLOAT/8 branch in
        // readCanonicalBytes.
        String dsPath = "/study/ms_runs/run_0001/signal_channels/intensity_values";
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"hdf5-sign",
                tio.toString(), dsPath, sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });

        // provider-sign on a file:// URL exercises the provider-dispatched
        // signOrVerifyProvider() path.
        String url = "file://" + tio.toString();
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"provider-sign",
                url, dsPath, sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
    }

    @Test
    @DisplayName("PQCTool: hdf5-sign covers int64 + uint32 readCanonicalBytes branches")
    void pqcToolSignIntegerDatasets(@TempDir Path tmp) throws Exception {
        // The genomic fixture writes /study/genomic_runs/genomic_0001/
        //   genomic_index/positions  (int64)
        //   genomic_index/flags      (uint32 → int32-shaped read)
        // Signing each in turn covers the two integer branches in
        // PQCTool.readCanonicalBytes (lines 311-329).
        Path tio = buildGenomicFixture(tmp, "pqc_sign_int_smoke.tio");
        Path pk = tmp.resolve("ipk.bin");
        Path sk = tmp.resolve("isk.bin");
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"sig-keygen",
                pk.toString(), sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });

        String posPath = "/study/genomic_runs/genomic_0001/genomic_index/positions";
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"hdf5-sign",
                tio.toString(), posPath, sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });

        String flagsPath = "/study/genomic_runs/genomic_0001/genomic_index/flags";
        captureStdout(() -> {
            try { PQCTool.main(new String[]{"hdf5-sign",
                tio.toString(), flagsPath, sk.toString()}); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
    }

    // ───────────────────────────────────────────────────────────────────
    // 6. ProvenanceJsonParse — direct static-method tests (no main())
    // ───────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("ProvenanceJsonParse: parses the canonical provenance_json shape")
    void provenanceJsonParseSmoke() {
        // This is the exact shape AcquisitionRun.writeProvenance produces
        // (lines 652-664): a top-level JSON array of objects with the
        // five fixed keys. Cover every readXField() helper.
        String json = "["
            + "{\"timestamp_unix\":1700000000,"
            +  "\"software\":\"TTI-O Java 1.0.0\","
            +  "\"parameters\":{\"threshold\":\"0.5\",\"mode\":\"strict\"},"
            +  "\"input_refs\":[\"file:///in/sample.raw\"],"
            +  "\"output_refs\":[\"file:///out/sample.tio\"]},"
            + "{\"timestamp_unix\":-42,"
            +  "\"software\":\"second \\\"step\\\" with escapes\","
            +  "\"parameters\":{\"nested\":{\"a\":\"b\"}},"
            +  "\"input_refs\":[],"
            +  "\"output_refs\":[\"file:///out/2.tio\"]}"
            + "]";
        List<ProvenanceRecord> records = ProvenanceJsonParse.parseArray(json);
        assertEquals(2, records.size());

        ProvenanceRecord first = records.get(0);
        assertEquals(1700000000L, first.timestampUnix());
        assertEquals("TTI-O Java 1.0.0", first.software());
        assertEquals(List.of("file:///in/sample.raw"), first.inputRefs());
        assertEquals(List.of("file:///out/sample.tio"), first.outputRefs());
        assertEquals("0.5", first.parameters().get("threshold"));
        assertEquals("strict", first.parameters().get("mode"));

        ProvenanceRecord second = records.get(1);
        assertEquals(-42L, second.timestampUnix());
        assertTrue(second.software().contains("escapes"));
        assertEquals(List.of(), second.inputRefs());
        assertEquals(List.of("file:///out/2.tio"), second.outputRefs());

        // Nested-object splitTopLevelObjects branch: nested {a:b} inside
        // parameters should not break the outer object split.
        assertNotNull(second.parameters());
    }

    @Test
    @DisplayName("ProvenanceJsonParse: degenerate inputs return empty list")
    void provenanceJsonParseDegenerate() {
        assertEquals(List.of(), ProvenanceJsonParse.parseArray(null));
        assertEquals(List.of(), ProvenanceJsonParse.parseArray(""));
        assertEquals(List.of(), ProvenanceJsonParse.parseArray("   "));
        // Not an array
        assertEquals(List.of(), ProvenanceJsonParse.parseArray("{\"x\":1}"));
        // Empty array
        assertEquals(List.of(), ProvenanceJsonParse.parseArray("[]"));
        // Array with whitespace-only entry — splitTopLevelObjects yields no
        // objects, so still returns empty without crashing.
        assertEquals(List.of(), ProvenanceJsonParse.parseArray("[   ]"));
    }

    @Test
    @DisplayName("ProvenanceJsonParse: missing fields fall through to defaults")
    void provenanceJsonParseMissingFields() {
        // No keys at all — readLongField/readStringField/readBracketedField
        // each take the "key not found" branch.
        String json = "[{}]";
        List<ProvenanceRecord> records = ProvenanceJsonParse.parseArray(json);
        assertEquals(1, records.size());
        ProvenanceRecord r = records.get(0);
        assertEquals(0L, r.timestampUnix());
        assertEquals("", r.software());
        assertTrue(r.inputRefs().isEmpty());
        assertTrue(r.outputRefs().isEmpty());

        // timestamp_unix present but non-numeric — readLongField's
        // NumberFormatException catch branch.
        String json2 = "[{\"timestamp_unix\":not-a-number,\"software\":\"x\"}]";
        List<ProvenanceRecord> records2 = ProvenanceJsonParse.parseArray(json2);
        assertEquals(1, records2.size());
        assertEquals(0L, records2.get(0).timestampUnix());

        // String with embedded backslash escape — readStringField escape
        // branch.
        String json3 = "[{\"software\":\"a\\\\b\",\"timestamp_unix\":1}]";
        List<ProvenanceRecord> records3 = ProvenanceJsonParse.parseArray(json3);
        assertEquals("a\\b", records3.get(0).software());
    }
}
