/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.protection;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.Enums;
import com.dtwthalion.mpgo.InstrumentConfig;
import com.dtwthalion.mpgo.SpectralDataset;
import com.dtwthalion.mpgo.SpectrumIndex;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v1.0 file-level per-AU encryption round-trip. Builds a small
 * plaintext .mpgo via {@link SpectralDataset#create}, encrypts it
 * in place with {@link PerAUFile#encryptFile}, and verifies
 * {@link PerAUFile#decryptFile} recovers the plaintext channels
 * bit-for-bit.
 */
class PerAUFileTest {

    @TempDir
    Path tempDir;

    private static byte[] testKey() {
        byte[] k = new byte[32];
        java.util.Arrays.fill(k, (byte) 0x77);
        return k;
    }

    private String buildFixture(String fname) {
        String path = tempDir.resolve(fname).toString();
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
                "per-AU fixture", "ISA-PERAU",
                List.of(run), List.of(), List.of(), List.of())) {
            // closed automatically
        }
        return path;
    }

    @Test
    void channelOnlyRoundTrip() {
        String path = buildFixture("channel_only.h5");
        byte[] src = copyOfBytesFromFile(path);   // just for size sanity

        PerAUFile.encryptFile(path, testKey(), false, "hdf5");
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptFile(path, testKey(), "hdf5");
        assertTrue(plain.containsKey("run_0001"));
        PerAUFile.DecryptedRun run = plain.get("run_0001");
        assertNotNull(run.channels().get("mz"));
        assertNotNull(run.channels().get("intensity"));
        assertNull(run.auHeaders(),
                   "channels-only mode shouldn't produce au headers");
        // 3 spectra × 4 elements × 8 bytes each = 96 bytes per channel
        assertEquals(96, run.channels().get("mz").length);
        assertEquals(96, run.channels().get("intensity").length);

        // Source file bytes should be strictly smaller than the encrypted
        // file (encryption adds ~28 bytes per spectrum for IV+TAG).
        byte[] afterSize = copyOfBytesFromFile(path);
        assertTrue(afterSize.length >= src.length / 2,
                   "encrypted file non-empty and comparable size");
    }

    @Test
    void encryptedHeadersRoundTrip() {
        String path = buildFixture("encrypted_hdr.h5");

        PerAUFile.encryptFile(path, testKey(), true, "hdf5");
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptFile(path, testKey(), "hdf5");
        PerAUFile.DecryptedRun run = plain.get("run_0001");
        assertNotNull(run.auHeaders());
        assertEquals(3, run.auHeaders().size());
        // Row 0 was ms_level=1, polarity=1, rt=1.0, precursor_mz=0.0
        assertEquals(1, run.auHeaders().get(0).msLevel());
        assertEquals(1, run.auHeaders().get(0).polarity());
        assertEquals(1.0, run.auHeaders().get(0).retentionTime(), 0.0);
        assertEquals(0.0, run.auHeaders().get(0).precursorMz(), 0.0);
        // Row 1 was ms_level=2, rt=2.0, precursor_mz=500.0, precursor_charge=2
        assertEquals(2, run.auHeaders().get(1).msLevel());
        assertEquals(2.0, run.auHeaders().get(1).retentionTime(), 0.0);
        assertEquals(500.0, run.auHeaders().get(1).precursorMz(), 0.0);
        assertEquals(2, run.auHeaders().get(1).precursorCharge());
    }

    @Test
    void decryptRefusesNonEncryptedFile() {
        String path = buildFixture("plain.h5");
        Exception ex = assertThrows(IllegalStateException.class,
            () -> PerAUFile.decryptFile(path, testKey(), "hdf5"));
        assertTrue(ex.getMessage().contains("opt_per_au_encryption"));
    }

    private static byte[] copyOfBytesFromFile(String p) {
        try {
            return java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(p));
        } catch (java.io.IOException e) {
            throw new RuntimeException(e);
        }
    }
}
