/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import com.dtwthalion.ttio.Enums.AcquisitionMode;
import com.dtwthalion.ttio.Enums.Compression;
import com.dtwthalion.ttio.Enums.Precision;
import com.dtwthalion.ttio.providers.Hdf5Provider;
import com.dtwthalion.ttio.providers.MemoryProvider;
import com.dtwthalion.ttio.providers.SqliteProvider;
import com.dtwthalion.ttio.providers.StorageDataset;
import com.dtwthalion.ttio.providers.StorageGroup;
import com.dtwthalion.ttio.providers.StorageProvider;
import com.dtwthalion.ttio.providers.ZarrProvider;
import com.dtwthalion.ttio.transport.AccessUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 M79 — Modality abstraction + genomic enumerations.
 *
 * <p>Purely additive groundwork covered here:
 * <ul>
 *   <li>{@link Precision#UINT8} round-trips through HDF5, Memory,
 *       SQLite, and Zarr providers byte-exactly.</li>
 *   <li>New {@link Compression} ordinals 4-8 (rANS / base-pack /
 *       quality-binned / name-tokenized) are stable and persist as
 *       integer attributes.</li>
 *   <li>{@link AcquisitionMode#GENOMIC_WGS} == 7,
 *       {@code GENOMIC_WES} == 8.</li>
 *   <li>Transport {@link AccessUnit} encodes/decodes
 *       {@code spectrumClass = 5} (GenomicRead) without crashing.</li>
 * </ul>
 *
 * <p>The {@code @modality} attribute round-trip is exercised in the
 * existing {@code AcquisitionRunProviderTest}-adjacent suites once
 * {@code GenomicRun} ships in M74; M79 only ships read-side default
 * handling, which is asserted via the {@link AcquisitionRun}
 * constructor in {@link #modalityDefaultsToMassSpectrometry()}.</p>
 */
public class M79GenomicEnumsTest {

    @TempDir Path tempDir;

    // ── UINT8 provider round-trip ────────────────────────────────────

    private static byte[] uint8Sample() {
        byte[] data = new byte[1000];
        for (int i = 0; i < data.length; i++) {
            data[i] = (byte) (i & 0xFF);  // 0..255 repeating
        }
        return data;
    }

    @Test
    public void uint8RoundTripHdf5() {
        String path = tempDir.resolve("m79_uint8.h5").toString();
        byte[] expected = uint8Sample();

        Hdf5Provider w = new Hdf5Provider();
        w.open(path, StorageProvider.Mode.CREATE);
        StorageDataset ds = w.rootGroup().createDataset(
                "bases", Precision.UINT8, expected.length, 0,
                Compression.NONE, 0);
        ds.writeAll(expected);
        w.close();

        Hdf5Provider r = new Hdf5Provider();
        r.open(path, StorageProvider.Mode.READ);
        StorageDataset back = r.rootGroup().openDataset("bases");
        assertEquals(Precision.UINT8, back.precision());
        assertArrayEquals(expected, (byte[]) back.readAll());
        r.close();
    }

    @Test
    public void uint8RoundTripMemory() {
        String url = "memory://m79-uint8-" + System.nanoTime();
        byte[] expected = uint8Sample();

        try {
            MemoryProvider w = new MemoryProvider();
            w.open(url, StorageProvider.Mode.CREATE);
            StorageDataset ds = w.rootGroup().createDataset(
                    "bases", Precision.UINT8, expected.length, 0,
                    Compression.NONE, 0);
            ds.writeAll(expected);
            w.close();

            MemoryProvider r = new MemoryProvider();
            r.open(url, StorageProvider.Mode.READ);
            StorageDataset back = r.rootGroup().openDataset("bases");
            assertEquals(Precision.UINT8, back.precision());
            assertArrayEquals(expected, (byte[]) back.readAll());
            r.close();
        } finally {
            MemoryProvider.discardStore(url);
        }
    }

    @Test
    public void uint8RoundTripSqlite() {
        String path = tempDir.resolve("m79_uint8.tio.sqlite").toString();
        byte[] expected = uint8Sample();

        SqliteProvider w = new SqliteProvider();
        w.open(path, StorageProvider.Mode.CREATE);
        StorageDataset ds = w.rootGroup().createDataset(
                "bases", Precision.UINT8, expected.length, 0,
                Compression.NONE, 0);
        ds.writeAll(expected);
        w.close();

        SqliteProvider r = new SqliteProvider();
        r.open(path, StorageProvider.Mode.READ);
        StorageDataset back = r.rootGroup().openDataset("bases");
        assertEquals(Precision.UINT8, back.precision());
        assertArrayEquals(expected, (byte[]) back.readAll());
        r.close();
    }

    @Test
    public void uint8RoundTripZarr() {
        Path store = tempDir.resolve("m79_uint8.zarr");
        byte[] expected = uint8Sample();

        ZarrProvider w = new ZarrProvider();
        w.open(store.toString(), StorageProvider.Mode.CREATE);
        StorageDataset ds = w.rootGroup().createDataset(
                "bases", Precision.UINT8, expected.length, 0,
                Compression.NONE, 0);
        ds.writeAll(expected);
        w.close();

        ZarrProvider r = new ZarrProvider();
        r.open(store.toString(), StorageProvider.Mode.READ);
        StorageDataset back = r.rootGroup().openDataset("bases");
        assertEquals(Precision.UINT8, back.precision());
        assertArrayEquals(expected, (byte[]) back.readAll());
        r.close();
    }

    // ── Compression / AcquisitionMode ordinal stability ──────────────

    @Test
    public void compressionOrdinalsAreStable() {
        assertEquals(0, Compression.NONE.ordinal());
        assertEquals(1, Compression.ZLIB.ordinal());
        assertEquals(2, Compression.LZ4.ordinal());
        assertEquals(3, Compression.NUMPRESS_DELTA.ordinal());
        assertEquals(4, Compression.RANS_ORDER0.ordinal());
        assertEquals(5, Compression.RANS_ORDER1.ordinal());
        assertEquals(6, Compression.BASE_PACK.ordinal());
        assertEquals(7, Compression.QUALITY_BINNED.ordinal());
        assertEquals(8, Compression.NAME_TOKENIZED.ordinal());
    }

    @Test
    public void acquisitionModeOrdinalsAreStable() {
        assertEquals(0, AcquisitionMode.MS1_DDA.ordinal());
        assertEquals(7, AcquisitionMode.GENOMIC_WGS.ordinal());
        assertEquals(8, AcquisitionMode.GENOMIC_WES.ordinal());
    }

    @Test
    public void compressionOrdinalPersistsAsAttribute() {
        String path = tempDir.resolve("m79_codec.h5").toString();
        Hdf5Provider w = new Hdf5Provider();
        w.open(path, StorageProvider.Mode.CREATE);
        StorageGroup root = w.rootGroup();
        for (Compression c : new Compression[]{
                Compression.RANS_ORDER0, Compression.RANS_ORDER1,
                Compression.BASE_PACK, Compression.QUALITY_BINNED,
                Compression.NAME_TOKENIZED}) {
            root.setAttribute("codec_" + c.name(), (long) c.ordinal());
        }
        w.close();

        Hdf5Provider r = new Hdf5Provider();
        r.open(path, StorageProvider.Mode.READ);
        StorageGroup root2 = r.rootGroup();
        for (Compression c : new Compression[]{
                Compression.RANS_ORDER0, Compression.RANS_ORDER1,
                Compression.BASE_PACK, Compression.QUALITY_BINNED,
                Compression.NAME_TOKENIZED}) {
            Object v = root2.getAttribute("codec_" + c.name());
            assertEquals(c.ordinal(),
                    ((Number) v).intValue(),
                    "codec ordinal for " + c.name());
            assertSame(c, Compression.values()[((Number) v).intValue()]);
        }
        r.close();
    }

    // ── Transport: spectrumClass = 5 (GenomicRead) ──────────────────

    @Test
    public void accessUnitGenomicReadRoundTrip() {
        AccessUnit au = new AccessUnit(
                /* spectrumClass    */ 5,
                /* acquisitionMode  */ AcquisitionMode.GENOMIC_WGS.ordinal(),
                /* msLevel          */ 0,
                /* polarity         */ 2,    // unknown — wire convention
                /* retentionTime    */ 0.0,
                /* precursorMz      */ 0.0,
                /* precursorCharge  */ 0,
                /* ionMobility      */ 0.0,
                /* basePeakIntensity*/ 0.0,
                /* channels         */ List.of(),
                /* pixelX           */ 0L,
                /* pixelY           */ 0L,
                /* pixelZ           */ 0L);

        AccessUnit back = AccessUnit.decode(au.encode());

        assertEquals(5, back.spectrumClass);
        assertEquals(AcquisitionMode.GENOMIC_WGS.ordinal(),
                back.acquisitionMode);
        assertEquals(0, back.channels.size());
        // MSImagePixel extension MUST NOT activate for spectrumClass=5.
        assertEquals(0L, back.pixelX);
        assertEquals(0L, back.pixelY);
        assertEquals(0L, back.pixelZ);
    }

    // ── Modality default ────────────────────────────────────────────

    @Test
    public void modalityDefaultsToMassSpectrometry() {
        // Constructor without modality argument applies the v0.10
        // backward-compat default. This is the read-side contract: any
        // pre-v0.11 file with no @modality attribute must surface as
        // mass-spectrometry.
        AcquisitionRun run = new AcquisitionRun(
                "legacy_run", AcquisitionMode.MS1_DDA, null, null,
                null, null, null, null, 0.0);
        assertEquals("mass_spectrometry", run.modality());
    }

    @Test
    public void modalityExplicitGenomicSequencingPreserved() {
        AcquisitionRun run = new AcquisitionRun(
                "genomic_run", AcquisitionMode.GENOMIC_WGS, null, null,
                null, null, null, null, 0.0,
                "genomic_sequencing");
        assertEquals("genomic_sequencing", run.modality());
    }
}
