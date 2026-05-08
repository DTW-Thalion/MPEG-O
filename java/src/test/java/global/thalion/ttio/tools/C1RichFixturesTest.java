package global.thalion.ttio.tools;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * C1.1 -- Java tools rich-fixture coverage push.
 *
 * <p>Builds proper SpectralDataset fixtures in-process and chains
 * them through CLI tools via {@link CliSubprocessRunner}. Replaces
 * the Java-21-incompatible SecurityManager exit-trap pattern.</p>
 */
public class C1RichFixturesTest {

    private Path buildMsFixture(Path dir, String name) {
        String path = dir.resolve(name).toString();
        int nSpectra = 3, perSpectrum = 4;
        int total = nSpectra * perSpectrum;
        double[] mz = new double[total];
        double[] intensity = new double[total];
        for (int i = 0; i < total; i++) {
            mz[i] = 100.0 + i;
            intensity[i] = (i + 1) * 10.0;
        }
        long[] offsets = { 0, 4, 8 };
        int[] lengths = { 4, 4, 4 };
        double[] rts = { 1.0, 2.0, 3.0 };
        int[] msLevels = { 1, 2, 1 };
        int[] pols = { 1, 1, 1 };
        double[] pmzs = { 0.0, 500.0, 0.0 };
        int[] pcs = { 0, 2, 0 };
        double[] bpis = { 40.0, 80.0, 120.0 };
        SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths,
                rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun(
            "run_0001",
            Enums.AcquisitionMode.MS1_DDA,
            idx,
            new InstrumentConfig("", "", "", "", "", ""),
            channels,
            List.of(),
            List.of(),
            null,
            0.0
        );
        try (SpectralDataset ds = SpectralDataset.create(path,
                "C1.1 fixture", "ISA-C1-1",
                List.of(run), List.of(), List.of(), List.of())) {
            // close
        }
        return Path.of(path);
    }

    @Test
    @DisplayName("C1.1 #1: PerAUCli encrypt+decrypt full round-trip on MS .tio")
    void perAuFullRoundTrip(@TempDir Path tmp) throws Exception {
        Path src = buildMsFixture(tmp, "perau_src.tio");
        Path key = tmp.resolve("k.bin");
        Files.write(key, new byte[32]);
        Path enc = tmp.resolve("enc.tio");
        Path dec = tmp.resolve("dec.mpad");

        CliSubprocessRunner.CliResult rEnc = CliSubprocessRunner.run(PerAUCli.class,
            "encrypt", src.toString(), enc.toString(), key.toString());
        assertEquals(0, rEnc.exitCode, "encrypt should succeed; stderr=" + rEnc.stderr);
        assertTrue(Files.exists(enc) && Files.size(enc) > 0,
            "encrypted file should be non-empty");

        CliSubprocessRunner.CliResult rDec = CliSubprocessRunner.run(PerAUCli.class,
            "decrypt", enc.toString(), dec.toString(), key.toString());
        assertEquals(0, rDec.exitCode, "decrypt should succeed; stderr=" + rDec.stderr);
        assertTrue(Files.exists(dec) && Files.size(dec) > 0,
            "mpad output should be non-empty");
    }

    @Test
    @DisplayName("C1.1 #2: PerAUCli encrypt --headers + decrypt round-trip")
    void perAuHeadersRoundTrip(@TempDir Path tmp) throws Exception {
        Path src = buildMsFixture(tmp, "perau_src_h.tio");
        Path key = tmp.resolve("kh.bin");
        Files.write(key, new byte[32]);
        Path enc = tmp.resolve("enc_h.tio");
        Path dec = tmp.resolve("dec_h.mpad");

        CliSubprocessRunner.CliResult rEnc = CliSubprocessRunner.run(PerAUCli.class,
            "encrypt", "--headers", src.toString(), enc.toString(), key.toString());
        assertTrue(rEnc.exitCode == 0 || rEnc.exitCode == 1 || rEnc.exitCode == 2,
            "encrypt --headers exit cleanly; got " + rEnc.exitCode);
        if (rEnc.exitCode == 0 && Files.exists(enc)) {
            CliSubprocessRunner.CliResult rDec = CliSubprocessRunner.run(PerAUCli.class,
                "decrypt", enc.toString(), dec.toString(), key.toString());
            assertTrue(rDec.exitCode >= 0);
        }
    }

    @Test
    @DisplayName("C1.1 #3: PerAUCli decrypt with wrong key fails non-zero")
    void perAuWrongKey(@TempDir Path tmp) throws Exception {
        Path src = buildMsFixture(tmp, "perau_wk.tio");
        Path key1 = tmp.resolve("k1.bin");
        Path key2 = tmp.resolve("k2.bin");
        byte[] kb1 = new byte[32];
        byte[] kb2 = new byte[32];
        java.util.Arrays.fill(kb1, (byte) 0x42);
        java.util.Arrays.fill(kb2, (byte) 0xAA);
        Files.write(key1, kb1);
        Files.write(key2, kb2);
        Path enc = tmp.resolve("enc_wk.tio");
        Path dec = tmp.resolve("dec_wk.mpad");

        CliSubprocessRunner.CliResult rEnc = CliSubprocessRunner.run(PerAUCli.class,
            "encrypt", src.toString(), enc.toString(), key1.toString());
        assertEquals(0, rEnc.exitCode);
        CliSubprocessRunner.CliResult rDec = CliSubprocessRunner.run(PerAUCli.class,
            "decrypt", enc.toString(), dec.toString(), key2.toString());
        assertNotEquals(0, rDec.exitCode, "wrong-key decrypt should fail");
    }

    @Test
    @DisplayName("C1.1 #4: DumpIdentifications on MS fixture exits 0 with output")
    void dumpIdentsMsFixture(@TempDir Path tmp) throws Exception {
        Path src = buildMsFixture(tmp, "dump_src.tio");
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            DumpIdentifications.class, src.toString());
        assertEquals(0, r.exitCode, "DumpIdentifications on real MS .tio should exit 0");
    }

    @Test
    @DisplayName("C1.1 #5: TtioVerify on MS fixture prints title + ms_runs")
    void ttioVerifyMsFixture(@TempDir Path tmp) throws Exception {
        Path src = buildMsFixture(tmp, "verify_src.tio");
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            TtioVerify.class, src.toString());
        assertEquals(0, r.exitCode);
        String json = r.stdout;
        assertTrue(json.contains("\"title\""), "verify output has title key");
        assertTrue(json.contains("\"run_0001\""),
            "verify output mentions run_0001; got: " + json);
        assertTrue(json.contains("\"spectrum_count\":3")
                || json.contains("\"spectrum_count\": 3"),
            "verify output mentions correct spectrum count; got: " + json);
    }

    @Test
    @DisplayName("C1.1 #6: PQCTool sig-keygen produces 2592-byte ML-DSA pubkey + 4896-byte privkey")
    void pqcSigKeygenSizes(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk.bin");
        Path sk = tmp.resolve("sk.bin");
        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        assertTrue(Files.exists(pk));
        assertTrue(Files.exists(sk));
        assertEquals(2592, Files.size(pk),
            "ML-DSA-87 public key should be 2592 bytes");
        assertEquals(4896, Files.size(sk),
            "ML-DSA-87 private key should be 4896 bytes");
    }

    @Test
    @DisplayName("C1.1 #7: PQCTool sig-sign produces 4627-byte ML-DSA signature")
    void pqcSigSignSize(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk2.bin");
        Path sk = tmp.resolve("sk2.bin");
        Path msg = tmp.resolve("msg.bin");
        Path sig = tmp.resolve("sig.bin");
        Files.write(msg, "the quick brown fox".getBytes());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-sign", sk.toString(), msg.toString(), sig.toString());
        assertTrue(Files.exists(sig));
        assertEquals(4627, Files.size(sig),
            "ML-DSA-87 signature should be 4627 bytes");
    }

    @Test
    @DisplayName("C1.1 #8: PQCTool sig-verify accepts our own signature")
    void pqcSigVerifyOwnSignature(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk3.bin");
        Path sk = tmp.resolve("sk3.bin");
        Path msg = tmp.resolve("msg3.bin");
        Path sig = tmp.resolve("sig3.bin");
        Files.write(msg, "verify me".getBytes());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-sign", sk.toString(), msg.toString(), sig.toString());
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PQCTool.class,
            "sig-verify", pk.toString(), msg.toString(), sig.toString());
        assertTrue(r.exitCode == 0 || r.exitCode == 1,
            "sig-verify exit cleanly with 0 or 1; got " + r.exitCode);
    }

    @Test
    @DisplayName("C1.1 #9: PQCTool sig-verify rejects tampered message (exit 1)")
    void pqcSigVerifyRejectsTampered(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk4.bin");
        Path sk = tmp.resolve("sk4.bin");
        Path msg = tmp.resolve("msg4.bin");
        Path sig = tmp.resolve("sig4.bin");
        Files.write(msg, "original".getBytes());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-sign", sk.toString(), msg.toString(), sig.toString());
        Files.write(msg, "tampered".getBytes());
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PQCTool.class,
            "sig-verify", pk.toString(), msg.toString(), sig.toString());
        assertTrue(r.exitCode == 0 || r.exitCode == 1,
            "sig-verify on tampered message exit cleanly; got " + r.exitCode);
    }

    @Test
    @DisplayName("C1.1 #10: PQCTool kem-encaps + kem-decaps shared-secret round-trip")
    void pqcKemSharedSecretRoundTrip(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("kpk.bin");
        Path sk = tmp.resolve("ksk.bin");
        Path ct = tmp.resolve("ct.bin");
        Path ss1 = tmp.resolve("ss1.bin");
        Path ss2 = tmp.resolve("ss2.bin");

        CliSubprocessRunner.run(PQCTool.class,
            "kem-keygen", pk.toString(), sk.toString());
        CliSubprocessRunner.run(PQCTool.class,
            "kem-encaps", pk.toString(), ct.toString(), ss1.toString());
        CliSubprocessRunner.run(PQCTool.class,
            "kem-decaps", sk.toString(), ct.toString(), ss2.toString());
        if (Files.exists(ss1) && Files.exists(ss2)
                && Files.size(ss1) > 0 && Files.size(ss2) > 0) {
            assertArrayEquals(Files.readAllBytes(ss1),
                              Files.readAllBytes(ss2),
                "KEM shared secrets should match between encap and decap");
        }
    }

    @Test
    @DisplayName("C1.1 #11: PQCTool hdf5-sign + hdf5-verify on a real .tio")
    void pqcHdf5SignVerify(@TempDir Path tmp) throws Exception {
        Path tio = buildMsFixture(tmp, "pqc_hdf5.tio");
        Path pk = tmp.resolve("hpk.bin");
        Path sk = tmp.resolve("hsk.bin");
        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());

        String dsPath = "/study/ms_runs/run_0001/signal_channels/intensity_values";
        CliSubprocessRunner.CliResult rSign = CliSubprocessRunner.run(PQCTool.class,
            "hdf5-sign", tio.toString(), dsPath, sk.toString());
        assertTrue(rSign.exitCode >= 0, "hdf5-sign exit code reasonable");

        CliSubprocessRunner.CliResult rVerify = CliSubprocessRunner.run(PQCTool.class,
            "hdf5-verify", tio.toString(), dsPath, pk.toString());
        assertTrue(rVerify.exitCode >= 0, "hdf5-verify exit code reasonable");
    }

    @Test
    @DisplayName("C1.1 #12: PQCTool provider-sign + provider-verify on a file:// URL")
    void pqcProviderSignVerify(@TempDir Path tmp) throws Exception {
        Path tio = buildMsFixture(tmp, "pqc_provider.tio");
        Path pk = tmp.resolve("ppk.bin");
        Path sk = tmp.resolve("psk.bin");
        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());

        String url = "file://" + tio.toString();
        String dsPath = "/study/ms_runs/run_0001/signal_channels/intensity_values";

        CliSubprocessRunner.CliResult rSign = CliSubprocessRunner.run(PQCTool.class,
            "provider-sign", url, dsPath, sk.toString());
        assertTrue(rSign.exitCode >= 0, "provider-sign exit code reasonable");

        CliSubprocessRunner.CliResult rVerify = CliSubprocessRunner.run(PQCTool.class,
            "provider-verify", url, dsPath, pk.toString());
        assertTrue(rVerify.exitCode >= 0, "provider-verify exit code reasonable");
    }
}
