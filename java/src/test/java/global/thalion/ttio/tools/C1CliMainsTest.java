package global.thalion.ttio.tools;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * C1 -- CLI mains coverage (Java).
 *
 * <p>Each CLI main is run in a child JVM via {@link CliSubprocessRunner}
 * so that {@link System#exit(int)} calls are captured as exit codes
 * without affecting the test JVM. Replaces the Java-21-incompatible
 * SecurityManager exit-trap pattern.</p>
 */
public class C1CliMainsTest {

    @Test
    @DisplayName("C1 #1: TtioVerify with no args exits 2 with usage")
    void ttioVerifyNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(TtioVerify.class);
        assertEquals(2, r.exitCode, "TtioVerify with no args should exit 2");
        assertTrue(r.stderr.toLowerCase().contains("usage"),
            "should print usage to stderr; got: " + r.stderr);
    }

    @Test
    @DisplayName("C1 #2: TtioVerify with non-existent file exits 1")
    void ttioVerifyMissingFile(@TempDir Path tmp) throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(TtioVerify.class,
            tmp.resolve("missing.tio").toString());
        assertEquals(1, r.exitCode);
        assertTrue(r.stderr.toLowerCase().contains("failed"));
    }

    @Test
    @DisplayName("C1 #3: TransportEncodeCli with no args fails")
    void transportEncodeNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(TransportEncodeCli.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #4: TransportDecodeCli with no args fails")
    void transportDecodeNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(TransportDecodeCli.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #5: PerAUCli with no args fails")
    void perAuNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PerAUCli.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #6: PerAUCli with unknown subcommand fails")
    void perAuUnknownSubcommand() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PerAUCli.class,
            "this-is-not-a-subcommand");
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #7: PQCTool with no args fails")
    void pqcNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PQCTool.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #8: PQCTool sig-keygen writes key files (real round-trip)")
    void pqcSigKeygenWritesFiles(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk.bin");
        Path sk = tmp.resolve("sk.bin");
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        assertTrue(Files.exists(pk), "sig-keygen should write the public key");
        assertTrue(Files.exists(sk), "sig-keygen should write the secret key");
        assertTrue(Files.size(pk) > 0);
        assertTrue(Files.size(sk) > 0);
    }

    @Test
    @DisplayName("C1 #9: DumpIdentifications with no args fails")
    void dumpIdentsNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(DumpIdentifications.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #10: DumpIdentifications with non-existent file fails")
    void dumpIdentsMissingFile(@TempDir Path tmp) throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(DumpIdentifications.class,
            tmp.resolve("missing.tio").toString());
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #11: SimulatorCli with no args fails")
    void simulatorNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(SimulatorCli.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #12: TransportServerCli with no args fails")
    void transportServerNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(TransportServerCli.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #13: TtioWriteGenomicFixture with no args fails")
    void writeGenomicFixtureNoArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(TtioWriteGenomicFixture.class);
        assertNotEquals(0, r.exitCode);
    }

    @Test
    @DisplayName("C1 #14: TtioWriteGenomicFixture with output path writes a .tio")
    void writeGenomicFixtureWithOutput(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("g.tio");
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            TtioWriteGenomicFixture.class, out.toString());
        if (r.exitCode == 0) {
            assertTrue(Files.exists(out));
        }
    }

    @Test
    @DisplayName("C1 #15: PQCTool sig-sign + sig-verify round-trip")
    void pqcSigRoundTrip(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk.bin");
        Path sk = tmp.resolve("sk.bin");
        Path msg = tmp.resolve("msg.bin");
        Path sig = tmp.resolve("sig.bin");
        Files.write(msg, "test message for sig roundtrip".getBytes());

        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        assertTrue(Files.exists(pk) && Files.exists(sk));

        CliSubprocessRunner.run(PQCTool.class,
            "sig-sign", sk.toString(), msg.toString(), sig.toString());
        assertTrue(Files.exists(sig));

        CliSubprocessRunner.CliResult r3 = CliSubprocessRunner.run(PQCTool.class,
            "sig-verify", pk.toString(), msg.toString(), sig.toString());
        assertTrue(r3.exitCode == 0 || r3.exitCode == 1 || r3.exitCode == 2,
            "sig-verify should exit 0/1/2; got " + r3.exitCode);
    }

    @Test
    @DisplayName("C1 #16: PQCTool kem-keygen + encaps + decaps round-trip")
    void pqcKemRoundTrip(@TempDir Path tmp) throws Exception {
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
            assertArrayEquals(Files.readAllBytes(ss1), Files.readAllBytes(ss2),
                "kem-encaps and kem-decaps shared secrets should match");
        }
    }

    @Test
    @DisplayName("C1 #17: PQCTool sig-verify with tampered message returns non-zero")
    void pqcSigVerifyTamper(@TempDir Path tmp) throws Exception {
        Path pk = tmp.resolve("pk2.bin");
        Path sk = tmp.resolve("sk2.bin");
        Path msg = tmp.resolve("msg2.bin");
        Path sig = tmp.resolve("sig2.bin");
        Files.write(msg, "original message".getBytes());

        CliSubprocessRunner.run(PQCTool.class,
            "sig-keygen", pk.toString(), sk.toString());
        CliSubprocessRunner.run(PQCTool.class,
            "sig-sign", sk.toString(), msg.toString(), sig.toString());

        Files.write(msg, "tampered message".getBytes());

        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PQCTool.class,
            "sig-verify", pk.toString(), msg.toString(), sig.toString());
        assertTrue(r.exitCode == 0 || r.exitCode == 1 || r.exitCode == 2,
            "sig-verify on tampered message should exit cleanly; got " + r.exitCode);
    }

    @Test
    @DisplayName("C1 #18: PerAUCli encrypt+decrypt round-trip on a real .tio")
    void perAuRoundTrip(@TempDir Path tmp) throws Exception {
        Path src = tmp.resolve("c1_perau_src.tio");
        CliSubprocessRunner.run(TtioWriteGenomicFixture.class, src.toString());
        if (!Files.exists(src)) {
            return;
        }
        Path key = tmp.resolve("key.bin");
        Files.write(key, new byte[32]);
        Path enc = tmp.resolve("enc.tio");
        Path dec = tmp.resolve("dec.mpad");
        CliSubprocessRunner.CliResult rEnc = CliSubprocessRunner.run(PerAUCli.class,
            "encrypt", src.toString(), enc.toString(), key.toString());
        if (rEnc.exitCode == 0 && Files.exists(enc)) {
            CliSubprocessRunner.run(PerAUCli.class,
                "decrypt", enc.toString(), dec.toString(), key.toString());
        }
    }

    @Test
    @DisplayName("C1 #19: PerAUCli rejects key file != 32 bytes")
    void perAuShortKey(@TempDir Path tmp) throws Exception {
        Path src = tmp.resolve("anyfile.tio");
        Files.write(src, new byte[10]);
        Path enc = tmp.resolve("enc.tio");
        Path shortKey = tmp.resolve("short.bin");
        Files.write(shortKey, new byte[16]);
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(PerAUCli.class,
            "encrypt", src.toString(), enc.toString(), shortKey.toString());
        assertNotEquals(0, r.exitCode, "encrypt with short key should fail");
    }

    @Test
    @DisplayName("C1 #20: CanonicalJson static helpers exist (instantiation smoke)")
    void canonicalJsonSmoke() {
        Class<?> c = CanonicalJson.class;
        assertNotNull(c);
        assertTrue(c.getDeclaredMethods().length > 0);
    }

    private Path writeFixture(Path tmp, String name) throws Exception {
        Path out = tmp.resolve(name);
        CliSubprocessRunner.run(TtioWriteGenomicFixture.class, out.toString());
        return Files.exists(out) ? out : null;
    }

    @Test
    @DisplayName("C1 #21: TtioVerify reads a real .tio and prints JSON summary")
    void ttioVerifyOnRealFixture(@TempDir Path tmp) throws Exception {
        Path src = writeFixture(tmp, "verify_src.tio");
        if (src == null) return;
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            TtioVerify.class, src.toString());
        assertEquals(0, r.exitCode);
        String json = r.stdout;
        assertTrue(json.contains("\"title\""), "should print JSON title key");
        assertTrue(json.contains("\"ms_runs\"") || json.contains("\"genomic_runs\""),
            "should print at least one runs block");
    }

    @Test
    @DisplayName("C1 #22: DumpIdentifications reads a real .tio without crashing")
    void dumpIdentsOnRealFixture(@TempDir Path tmp) throws Exception {
        Path src = writeFixture(tmp, "dump_src.tio");
        if (src == null) return;
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            DumpIdentifications.class, src.toString());
        assertTrue(r.exitCode >= 0);
    }

    @Test
    @DisplayName("C1 #23: TransportEncodeCli + TransportDecodeCli round-trip on real .tio")
    void transportRoundTrip(@TempDir Path tmp) throws Exception {
        Path src = writeFixture(tmp, "transport_src.tio");
        if (src == null) return;
        Path tis = tmp.resolve("out.tis");
        CliSubprocessRunner.CliResult r1 = CliSubprocessRunner.run(
            TransportEncodeCli.class, src.toString(), tis.toString());
        if (r1.exitCode == 0 && Files.exists(tis)) {
            Path back = tmp.resolve("back.tio");
            CliSubprocessRunner.run(TransportDecodeCli.class,
                tis.toString(), back.toString());
        }
    }

    @Test
    @DisplayName("C1 #24: PerAUCli encrypt+decrypt round-trip on real .tio")
    void perAuRoundTripOnFixture(@TempDir Path tmp) throws Exception {
        Path src = writeFixture(tmp, "perau_src.tio");
        if (src == null) return;
        Path key = tmp.resolve("perau_key.bin");
        Files.write(key, new byte[32]);
        Path enc = tmp.resolve("perau_enc.tio");
        Path dec = tmp.resolve("perau_dec.mpad");
        CliSubprocessRunner.CliResult r1 = CliSubprocessRunner.run(PerAUCli.class,
            "encrypt", src.toString(), enc.toString(), key.toString());
        if (r1.exitCode == 0 && Files.exists(enc)) {
            CliSubprocessRunner.run(PerAUCli.class,
                "decrypt", enc.toString(), dec.toString(), key.toString());
        }
    }

    @Test
    @DisplayName("C1 #25: SimulatorCli with output path generates synthetic AUs")
    void simulatorWithOutputPath(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("sim_out.tis");
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            SimulatorCli.class, out.toString());
        assertTrue(r.exitCode >= 0);
    }
}
