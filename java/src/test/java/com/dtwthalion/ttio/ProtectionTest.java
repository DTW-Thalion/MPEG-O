/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import com.dtwthalion.ttio.Enums.*;
import com.dtwthalion.ttio.hdf5.*;
import com.dtwthalion.ttio.protection.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M34 acceptance criteria tests for encryption, signatures, key rotation,
 * and anonymization.
 */
class ProtectionTest {

    @TempDir
    Path tempDir;

    // ── Encryption ──────────────────────────────────────────────────

    @Test
    void encryptDecryptRoundTrip() {
        byte[] key = EncryptionManager.testKey();
        byte[] plaintext = "Hello, TTI-O encryption!".getBytes();

        EncryptionManager.EncryptResult result = EncryptionManager.encrypt(plaintext, key);
        assertNotNull(result.ciphertext());
        assertEquals(12, result.iv().length);
        assertEquals(16, result.tag().length);

        byte[] decrypted = EncryptionManager.decrypt(
                result.ciphertext(), result.iv(), result.tag(), key);
        assertArrayEquals(plaintext, decrypted);
    }

    @Test
    void encryptDecryptChannel() {
        byte[] key = EncryptionManager.testKey();
        double[] data = { 100.5, 200.3, 300.1, 400.7, 500.9 };

        EncryptionManager.EncryptResult result = EncryptionManager.encryptChannel(data, key);
        assertNotNull(result.ciphertext());

        double[] decrypted = EncryptionManager.decryptChannel(
                result.ciphertext(), result.iv(), result.tag(), key, data.length);
        assertArrayEquals(data, decrypted, 1e-15);
    }

    @Test
    void wrongKeyFailsDecryption() {
        byte[] key = EncryptionManager.testKey();
        byte[] wrongKey = new byte[32];
        Arrays.fill(wrongKey, (byte) 0x42);

        byte[] plaintext = "secret data".getBytes();
        EncryptionManager.EncryptResult result = EncryptionManager.encrypt(plaintext, key);

        assertThrows(Exception.class, () ->
                EncryptionManager.decrypt(result.ciphertext(), result.iv(), result.tag(), wrongKey));
    }

    @Test
    void readEncryptedFixture() {
        // Read the encrypted fixture and verify structure
        String fixturePath = getFixturePath("ttio/encrypted.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(fixturePath);
             Hdf5Group root = f.rootGroup()) {
            assertTrue(root.hasAttribute("encrypted"));
            assertEquals("aes-256-gcm", root.readStringAttribute("encrypted"));
        }
    }

    // ── Signatures ──────────────────────────────────────────────────

    @Test
    void signAndVerify() {
        byte[] key = SignatureManager.testKey();
        double[] data = { 1.0, 2.0, 3.0, 4.0, 5.0 };
        byte[] canonical = SignatureManager.canonicalBytes(data);

        String sig = SignatureManager.sign(canonical, key);
        assertTrue(sig.startsWith("v2:"));
        assertTrue(SignatureManager.verify(canonical, sig, key));

        // Wrong data should not verify
        double[] wrong = { 1.0, 2.0, 3.0, 4.0, 6.0 };
        byte[] wrongCanonical = SignatureManager.canonicalBytes(wrong);
        assertFalse(SignatureManager.verify(wrongCanonical, sig, key));
    }

    @Test
    void v2SignatureFormat() {
        byte[] key = SignatureManager.testKey();
        byte[] data = { 0x01, 0x02, 0x03 };

        String sig = SignatureManager.sign(data, key);
        assertTrue(sig.startsWith("v2:"));

        // The base64 part should decode to 32 bytes (HMAC-SHA256)
        String b64 = sig.substring(3);
        byte[] decoded = java.util.Base64.getDecoder().decode(b64);
        assertEquals(32, decoded.length);
    }

    @Test
    void canonicalBytesLittleEndian() {
        double[] data = { 1.0 };
        byte[] bytes = SignatureManager.canonicalBytes(data);
        assertEquals(8, bytes.length);
        // 1.0 in IEEE 754 LE = 00 00 00 00 00 00 F0 3F
        assertEquals((byte) 0x00, bytes[0]);
        assertEquals((byte) 0x3F, bytes[7]);
        assertEquals((byte) 0xF0, bytes[6]);
    }

    @Test
    void canonicalStringBytes() {
        byte[] bytes = SignatureManager.canonicalStringBytes("test");
        assertEquals(8, bytes.length); // 4 (length) + 4 (chars)
        // Length prefix: 4 in LE = 04 00 00 00
        assertEquals((byte) 0x04, bytes[0]);
        assertEquals((byte) 0x00, bytes[1]);
        // String bytes
        assertEquals((byte) 't', bytes[4]);
        assertEquals((byte) 'e', bytes[5]);
    }

    @Test
    void readSignedFixture() {
        String fixturePath = getFixturePath("ttio/signed.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(fixturePath);
             Hdf5Group root = f.rootGroup()) {
            FeatureFlags flags = FeatureFlags.readFrom(root);
            assertTrue(flags.has(FeatureFlags.OPT_DIGITAL_SIGNATURES));
        }
    }

    // ── Key Rotation ────────────────────────────────────────────────

    @Test
    void keyWrapUnwrap() {
        byte[] kek = EncryptionManager.testKey();
        byte[] dek = new byte[32];
        new java.security.SecureRandom().nextBytes(dek);

        // v0.7 M47: default wrapKey emits the v1.2 versioned blob
        // (71 bytes for AES-256-GCM: 11-byte header + 28-byte
        // metadata + 32-byte ciphertext). The legacy v1.1 60-byte
        // layout is tested separately below.
        byte[] wrapped = EncryptionManager.wrapKey(dek, kek);
        assertEquals(71, wrapped.length,
                "default v1.2 AES-GCM blob must be 71 bytes");
        assertEquals((byte) 'M', wrapped[0]);
        assertEquals((byte) 'W', wrapped[1]);
        assertEquals((byte) 0x02, wrapped[2]);
        byte[] unwrapped = EncryptionManager.unwrapKey(wrapped, kek);
        assertArrayEquals(dek, unwrapped);
    }

    @Test
    void keyWrapUnwrapLegacyV11BackwardCompat() {
        // M47 Binding Decision 38: v1.1 60-byte AES-GCM blobs remain
        // readable by v0.7+ code indefinitely.
        byte[] kek = EncryptionManager.testKey();
        byte[] dek = new byte[32];
        new java.security.SecureRandom().nextBytes(dek);

        byte[] legacy = EncryptionManager.wrapKey(dek, kek, /* legacyV1= */ true);
        assertEquals(60, legacy.length, "v1.1 layout is 60 bytes");
        byte[] unwrapped = EncryptionManager.unwrapKey(legacy, kek);
        assertArrayEquals(dek, unwrapped,
                "v0.7 unwrapKey must accept v1.1 legacy blobs");
    }

    @Test
    void keyUnwrapRejectsUnknownV12Algorithm() {
        // A v1.2 blob carrying a reserved algorithm id (e.g. ML-KEM-1024,
        // M49 target) must raise IllegalArgumentException, not a
        // garbled decrypt error.
        byte[] pqcDummy = new byte[1568];
        for (int i = 0; i < pqcDummy.length; i++) pqcDummy[i] = (byte) (i & 0xFF);
        byte[] v12 = EncryptionManager.packBlobV2(
                EncryptionManager.WK_ALG_ML_KEM_1024,
                pqcDummy, new byte[0]);
        byte[] kek = EncryptionManager.testKey();
        IllegalArgumentException thrown = assertThrows(
                IllegalArgumentException.class,
                () -> EncryptionManager.unwrapKey(v12, kek));
        assertTrue(thrown.getMessage().contains("0x0001"),
                "error must identify the unsupported algorithm id");
    }

    @Test
    void keyRotationRoundTrip() {
        String path = tempDir.resolve("key_rotation.tio").toString();
        byte[] kek1 = new byte[32];
        Arrays.fill(kek1, (byte) 0x11);
        byte[] kek2 = new byte[32];
        Arrays.fill(kek2, (byte) 0x22);

        // Create with KEK-1
        KeyRotationManager mgr = new KeyRotationManager();
        mgr.enableEnvelopeEncryption(kek1, "kek-1");
        byte[] originalDek = mgr.getDek().clone();

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            FeatureFlags.defaultCurrent()
                    .with(FeatureFlags.OPT_KEY_ROTATION)
                    .writeTo(root);
            mgr.writeTo(root);
        }

        // Read back with KEK-1
        try (Hdf5File f = Hdf5File.open(path);
             Hdf5Group root = f.rootGroup()) {
            KeyRotationManager readMgr = KeyRotationManager.readFrom(root, kek1);
            assertArrayEquals(originalDek, readMgr.getDek());

            // Rotate to KEK-2
            readMgr.rotateKey(kek2, "kek-2");
            readMgr.writeTo(root);
        }

        // Read with KEK-2
        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            KeyRotationManager readMgr2 = KeyRotationManager.readFrom(root, kek2);
            assertArrayEquals(originalDek, readMgr2.getDek(),
                    "DEK should survive rotation from KEK-1 to KEK-2");
        }
    }

    // ── Anonymization ───────────────────────────────────────────────

    @Test
    void anonymizeSaavRedaction() {
        String inputPath = tempDir.resolve("anon_input.tio").toString();
        String outputPath = tempDir.resolve("anon_output.tio").toString();

        // Create dataset with one SAAV identification
        SpectrumIndex idx = new SpectrumIndex(3,
                new long[]{0, 4, 8}, new int[]{4, 4, 4},
                new double[]{0, 1, 2}, new int[]{1, 1, 1},
                new int[]{1, 1, 1}, new double[]{0, 0, 0},
                new int[]{0, 0, 0}, new double[]{100, 200, 300});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100,200,300,400, 150,250,350,450, 110,210,310,410});
        ch.put("intensity", new double[]{10,20,30,40, 15,25,35,45, 11,21,31,41});

        AcquisitionRun run = new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(), List.of(), null, 0);

        List<Identification> idents = List.of(
                Identification.of("run_0001", 1, "SAAV:p.Ala123Val", 0.9, List.of("MS2")),
                Identification.of("run_0001", 0, "CHEBI:15377", 0.95, List.of("RT"))
        );

        try (SpectralDataset ds = SpectralDataset.create(inputPath, "Anon Test",
                null, List.of(run), idents, List.of(), List.of())) {
            Anonymizer.AnonymizationPolicy policy = new Anonymizer.AnonymizationPolicy(
                    true, 0, false, 0.05, -1, -1, true);
            Anonymizer.AnonymizationResult result = Anonymizer.anonymize(ds, outputPath, policy);

            assertEquals(1, result.spectraRedacted());
            assertEquals(1, result.metadataFieldsStripped());
        }

        // Verify anonymized file
        try (SpectralDataset anon = SpectralDataset.open(outputPath)) {
            assertEquals("", anon.title()); // metadata stripped
            assertTrue(anon.featureFlags().has(FeatureFlags.OPT_ANONYMIZED));

            AcquisitionRun anonRun = anon.msRuns().get("run_0001");
            assertNotNull(anonRun);
            // Spectrum 1 (SAAV) should be zeroed
            double[] mz1 = anonRun.channelSlice("mz", 1);
            for (double v : mz1) assertEquals(0.0, v, 1e-15);
            // Spectrum 0 (non-SAAV) should be intact
            double[] mz0 = anonRun.channelSlice("mz", 0);
            assertEquals(100.0, mz0[0], 1e-10);
        }
    }

    @Test
    void anonymizeIntensityMasking() {
        String inputPath = tempDir.resolve("mask_input.tio").toString();
        String outputPath = tempDir.resolve("mask_output.tio").toString();

        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{10},
                new double[]{0}, new int[]{1}, new int[]{1},
                new double[]{0}, new int[]{0}, new double[]{1000});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100,200,300,400,500,600,700,800,900,1000});
        ch.put("intensity", new double[]{1,2,3,4,5,6,7,8,9,10});

        AcquisitionRun run = new AcquisitionRun("run", AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(), List.of(), null, 0);

        try (SpectralDataset ds = SpectralDataset.create(inputPath, "Mask",
                null, List.of(run), List.of(), List.of(), List.of())) {
            Anonymizer.AnonymizationPolicy policy = new Anonymizer.AnonymizationPolicy(
                    false, 0.5, false, 0.05, -1, -1, false);
            Anonymizer.AnonymizationResult result = Anonymizer.anonymize(ds, outputPath, policy);
            assertTrue(result.intensitiesZeroed() > 0);
        }

        try (SpectralDataset anon = SpectralDataset.open(outputPath)) {
            double[] intensity = anon.msRuns().get("run").channels().get("intensity");
            // Values below 50th percentile (5.5) should be zeroed
            long zeroCount = Arrays.stream(intensity).filter(v -> v == 0.0).count();
            assertTrue(zeroCount > 0);
        }
    }

    @Test
    void anonymizeMzCoarsening() {
        String inputPath = tempDir.resolve("coarse_input.tio").toString();
        String outputPath = tempDir.resolve("coarse_output.tio").toString();

        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{3},
                new double[]{0}, new int[]{1}, new int[]{1},
                new double[]{0}, new int[]{0}, new double[]{100});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100.12345, 200.67891, 300.99999});
        ch.put("intensity", new double[]{10, 20, 30});

        AcquisitionRun run = new AcquisitionRun("run", AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(), List.of(), null, 0);

        try (SpectralDataset ds = SpectralDataset.create(inputPath, "Coarse",
                null, List.of(run), List.of(), List.of(), List.of())) {
            Anonymizer.AnonymizationPolicy policy = new Anonymizer.AnonymizationPolicy(
                    false, 0, false, 0.05, 2, -1, false);
            Anonymizer.AnonymizationResult result = Anonymizer.anonymize(ds, outputPath, policy);
            assertTrue(result.mzValuesCoarsened() > 0);
        }

        try (SpectralDataset anon = SpectralDataset.open(outputPath)) {
            double[] mz = anon.msRuns().get("run").channels().get("mz");
            assertEquals(100.12, mz[0], 1e-10);
            assertEquals(200.68, mz[1], 1e-10);
            assertEquals(301.0, mz[2], 1e-10);
        }
    }

    // ── AcquisitionRun / SpectralDataset Encryptable ────────────────

    @Test
    void acquisitionRunEncryptDecryptRoundTrip() throws Exception {
        String path = tempDir.resolve("encryptable.tio").toString();
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;
        double[] originalIntensity = { 1.0, 2.0, 3.0, 4.0 };

        // Build a minimal fixture with one run containing an intensity channel
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{4},
                new double[]{0.0}, new int[]{1}, new int[]{1},
                new double[]{0.0}, new int[]{0}, new double[]{100.0});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100.0, 200.0, 300.0, 400.0});
        ch.put("intensity", originalIntensity);
        AcquisitionRun run = new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(), List.of(), null, 0.0);
        try (SpectralDataset ds = SpectralDataset.create(path, "EncryptTest",
                null, List.of(run), List.of(), List.of(), List.of())) {
            // dataset written; close before re-opening
        }

        // HDF5 cannot open R/W while a R/O handle is open (same pattern
        // as ObjC: close file before encrypt, then re-open for reads).
        // The persistence context is captured at open-time so the run can
        // encrypt itself AFTER the dataset is closed.
        AcquisitionRun runRef;
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            runRef = ds.msRuns().get("run_0001");
            assertNotNull(runRef, "run_0001 must be present in fixture");
            assertNotNull(ds.filePath(), "filePath must be set on SpectralDataset");
            assertEquals("run_0001", runRef.name());
        }

        // Dataset is closed; run retains its persistence context.
        // Exercise the full delegation: run.encryptWithKey → EncryptionManager.
        runRef.encryptWithKey(key, com.dtwthalion.ttio.Enums.EncryptionLevel.DATASET);

        // Re-open to verify encryption is on disk.
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            // fixture successfully reads back after encryption
            assertNotNull(ds.msRuns().get("run_0001"));
        }

        // Decrypt via EncryptionManager.decryptIntensityChannelInRun and assert plaintext
        byte[] plaintext = EncryptionManager.decryptIntensityChannelInRun(path, "run_0001", key);

        java.nio.DoubleBuffer db = java.nio.ByteBuffer
                .wrap(plaintext).order(java.nio.ByteOrder.LITTLE_ENDIAN).asDoubleBuffer();
        double[] recovered = new double[originalIntensity.length];
        db.get(recovered);
        assertArrayEquals(originalIntensity, recovered, 1e-12,
                "decrypted intensity values must match original");

        // Idempotency: encrypting again should be a no-op (no exception)
        EncryptionManager.encryptIntensityChannelInRun(path, "run_0001", key);
    }

    // ── v1.1 encrypt → close → reopen → decrypt → read parity ──────────

    @Test
    void v11EncryptedStateSurvivesCloseReopen() throws Exception {
        String path = tempDir.resolve("v11_issue_a.tio").toString();
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;

        writeMinimalOneRunFixture(path, "run_0001");

        // Open, capture run + file context, close. Encrypt must run with
        // the dataset closed — HDF5 single-writer contract, same as ObjC.
        SpectralDataset holder = SpectralDataset.open(path);
        assertFalse(holder.isEncrypted(), "freshly-written file must not be flagged");
        assertEquals("", holder.encryptedAlgorithm());
        holder.close();

        // Issue A: dataset-level encrypt must persist @encrypted to disk.
        holder.encryptWithKey(key, EncryptionLevel.DATASET);

        try (SpectralDataset reopened = SpectralDataset.open(path)) {
            assertTrue(reopened.isEncrypted(),
                    "reopen must see the persisted @encrypted root attribute");
            assertEquals("aes-256-gcm", reopened.encryptedAlgorithm());
        }
    }

    @Test
    void v11DecryptRehydratesSpectrumIntensity() throws Exception {
        String path = tempDir.resolve("v11_issue_b.tio").toString();
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;
        double[] expected = { 1.0, 2.0, 3.0, 4.0 };

        writeMinimalOneRunFixture(path, "run_0001");

        SpectralDataset holder = SpectralDataset.open(path);
        holder.close();
        holder.encryptWithKey(key, EncryptionLevel.DATASET);

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertTrue(ds.isEncrypted());
            // Issue B: after decrypt, the spectrum API must see plaintext
            // intensities without the caller parsing bytes themselves.
            ds.decryptWithKey(key);
            AcquisitionRun run = ds.msRuns().get("run_0001");
            Spectrum s = run.objectAtIndex(0);
            assertInstanceOf(MassSpectrum.class, s);
            double[] got = ((MassSpectrum) s).intensityValues();
            assertArrayEquals(expected, got, 1e-12,
                    "decrypt_with_key must rehydrate intensity so spectra are usable");
        }
    }

    // ── v1.1.1 decryptInPlace parity ──────────────────────────────────

    @Test
    void v111DecryptInPlaceSingleRunRoundTrip() throws Exception {
        String path = tempDir.resolve("v111_single.tio").toString();
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;
        double[] expected = { 1.0, 2.0, 3.0, 4.0 };

        writeMinimalOneRunFixture(path, "run_0001");

        SpectralDataset holder = SpectralDataset.open(path);
        holder.close();
        holder.encryptWithKey(key, EncryptionLevel.DATASET);

        SpectralDataset.decryptInPlace(path, key);

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertFalse(ds.isEncrypted(),
                    "decryptInPlace must clear the root @encrypted attribute");
            assertEquals("", ds.encryptedAlgorithm());
            double[] got = ((MassSpectrum) ds.msRuns().get("run_0001")
                    .objectAtIndex(0)).intensityValues();
            assertArrayEquals(expected, got, 1e-12);
        }
    }

    @Test
    void v111DecryptInPlaceMultiRunRoundTrip() throws Exception {
        String path = tempDir.resolve("v111_multi.tio").toString();
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;
        double[] expected = { 1.0, 2.0, 3.0, 4.0 };

        writeMinimalMultiRunFixture(path, List.of("run_A", "run_B", "run_C"));

        SpectralDataset holder = SpectralDataset.open(path);
        holder.close();
        holder.encryptWithKey(key, EncryptionLevel.DATASET);

        SpectralDataset.decryptInPlace(path, key);

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertFalse(ds.isEncrypted());
            for (String name : List.of("run_A", "run_B", "run_C")) {
                double[] got = ((MassSpectrum) ds.msRuns().get(name)
                        .objectAtIndex(0)).intensityValues();
                assertArrayEquals(expected, got, 1e-12,
                        "intensity mismatch in " + name
                                + " after decryptInPlace");
            }
        }
    }

    @Test
    void v111DecryptInPlaceIdempotentOnPlaintext() throws Exception {
        String path = tempDir.resolve("v111_plaintext.tio").toString();
        byte[] key = new byte[32];
        writeMinimalOneRunFixture(path, "run_0001");

        // No encrypt() call — must be a no-op.
        SpectralDataset.decryptInPlace(path, key);

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertFalse(ds.isEncrypted());
            double[] got = ((MassSpectrum) ds.msRuns().get("run_0001")
                    .objectAtIndex(0)).intensityValues();
            assertArrayEquals(new double[]{1.0, 2.0, 3.0, 4.0}, got, 1e-12);
        }
    }

    @Test
    void v111DecryptInPlaceRejectsShortKey() throws Exception {
        String path = tempDir.resolve("v111_shortkey.tio").toString();
        writeMinimalOneRunFixture(path, "run_0001");

        assertThrows(IllegalArgumentException.class, () ->
                SpectralDataset.decryptInPlace(path, new byte[]{1, 2, 3}));
    }

    private static void writeMinimalMultiRunFixture(String path,
                                                     java.util.List<String> runNames) {
        java.util.List<AcquisitionRun> runs = new java.util.ArrayList<>();
        for (String runName : runNames) {
            SpectrumIndex idx = new SpectrumIndex(1,
                    new long[]{0}, new int[]{4},
                    new double[]{0.0}, new int[]{1}, new int[]{1},
                    new double[]{0.0}, new int[]{0}, new double[]{100.0});
            Map<String, double[]> ch = new LinkedHashMap<>();
            ch.put("mz", new double[]{100.0, 200.0, 300.0, 400.0});
            ch.put("intensity", new double[]{1.0, 2.0, 3.0, 4.0});
            runs.add(new AcquisitionRun(runName, AcquisitionMode.MS1_DDA,
                    idx, null, ch, List.of(), List.of(), null, 0.0));
        }
        try (SpectralDataset ds = SpectralDataset.create(path, "v1.1.1 parity",
                null, runs, List.of(), List.of(), List.of())) {
            // dataset written
        }
    }

    private static void writeMinimalOneRunFixture(String path, String runName) {
        SpectrumIndex idx = new SpectrumIndex(1,
                new long[]{0}, new int[]{4},
                new double[]{0.0}, new int[]{1}, new int[]{1},
                new double[]{0.0}, new int[]{0}, new double[]{100.0});
        Map<String, double[]> ch = new LinkedHashMap<>();
        ch.put("mz", new double[]{100.0, 200.0, 300.0, 400.0});
        ch.put("intensity", new double[]{1.0, 2.0, 3.0, 4.0});
        AcquisitionRun run = new AcquisitionRun(runName, AcquisitionMode.MS1_DDA,
                idx, null, ch, List.of(), List.of(), null, 0.0);
        try (SpectralDataset ds = SpectralDataset.create(path, "v1.1 parity",
                null, List.of(run), List.of(), List.of(), List.of())) {
            // dataset written
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────

    private static String getFixturePath(String name) {
        var url = ProtectionTest.class.getClassLoader().getResource(name);
        if (url == null) throw new RuntimeException("Fixture not found: " + name);
        return url.getFile();
    }
}
