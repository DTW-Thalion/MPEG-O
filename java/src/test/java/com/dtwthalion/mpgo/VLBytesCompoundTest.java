/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.providers.CompoundField;
import com.dtwthalion.mpgo.providers.ProviderRegistry;
import com.dtwthalion.mpgo.providers.StorageDataset;
import com.dtwthalion.mpgo.providers.StorageGroup;
import com.dtwthalion.mpgo.providers.StorageProvider;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v1.0 VL_BYTES compound field round-trip through the HDF5 provider.
 * Exercises the {@code hvl_t} write/read path used by
 * {@code opt_per_au_encryption}'s {@code <channel>_segments} schema.
 */
class VLBytesCompoundTest {

    @TempDir
    Path tempDir;

    @Test
    void channelSegmentsCompoundRoundTripsThroughHdf5() throws Exception {
        String path = tempDir.resolve("vl_bytes_roundtrip.h5").toString();

        List<CompoundField> fields = List.of(
            new CompoundField("offset", CompoundField.Kind.INT64),
            new CompoundField("length", CompoundField.Kind.UINT32),
            new CompoundField("iv", CompoundField.Kind.VL_BYTES),
            new CompoundField("tag", CompoundField.Kind.VL_BYTES),
            new CompoundField("ciphertext", CompoundField.Kind.VL_BYTES));

        // Build three synthetic encrypted rows with distinct IVs / tags /
        // ciphertexts of varying lengths.
        List<Object[]> rows = new ArrayList<>();
        for (int i = 0; i < 3; i++) {
            byte[] iv = new byte[12];
            for (int j = 0; j < 12; j++) iv[j] = (byte) (0x10 + i * 12 + j);
            byte[] tag = new byte[16];
            for (int j = 0; j < 16; j++) tag[j] = (byte) (0x20 + i * 16 + j);
            byte[] ct = new byte[8 + i * 8];
            for (int j = 0; j < ct.length; j++) ct[j] = (byte) (0x30 + j);
            rows.add(new Object[]{
                (long) (i * 4),     // offset
                4,                   // length
                iv, tag, ct
            });
        }

        StorageProvider sp = ProviderRegistry.open(path,
            StorageProvider.Mode.CREATE);
        try {
            StorageGroup root = sp.rootGroup();
            StorageDataset ds = root.createCompoundDataset(
                "seg", fields, rows.size());
            ds.writeAll(rows);
        } finally {
            sp.close();
        }

        StorageProvider sp2 = ProviderRegistry.open(path,
            StorageProvider.Mode.READ);
        try {
            StorageGroup root = sp2.rootGroup();
            StorageDataset ds = root.openDataset("seg");
            @SuppressWarnings("unchecked")
            List<Object[]> back = (List<Object[]>) ds.readAll();
            assertEquals(3, back.size());
            for (int i = 0; i < 3; i++) {
                Object[] src = rows.get(i);
                Object[] got = back.get(i);
                assertEquals(((Number) src[0]).longValue(),
                             ((Number) got[0]).longValue(),
                             "row " + i + " offset");
                assertEquals(((Number) src[1]).intValue(),
                             ((Number) got[1]).intValue(),
                             "row " + i + " length");
                assertArrayEquals((byte[]) src[2], (byte[]) got[2],
                                   "row " + i + " iv bytes round-trip");
                assertArrayEquals((byte[]) src[3], (byte[]) got[3],
                                   "row " + i + " tag bytes round-trip");
                assertArrayEquals((byte[]) src[4], (byte[]) got[4],
                                   "row " + i + " ciphertext bytes round-trip");
            }
        } finally {
            sp2.close();
        }
    }
}
