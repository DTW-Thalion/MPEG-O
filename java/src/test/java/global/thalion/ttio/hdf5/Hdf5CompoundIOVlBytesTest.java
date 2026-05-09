/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * J.3 -- Coverage for {@link Hdf5CompoundIO} VL_BYTES paths via the
 * {@link VlBytesFFM} helper (Java 21 FFM rewrite shipped in PR #35).
 *
 * <p>Exercises the public {@link Hdf5CompoundIO#writeCompoundDataset(
 * Hdf5Group, String, Hdf5CompoundIO.Schema, int, Hdf5CompoundIO.RowPacker)}
 * and {@link Hdf5CompoundIO#readCompoundFull(Hdf5Group, String,
 * Hdf5CompoundIO.Schema)} APIs with schemas that contain VL_BYTES columns
 * (alone, alongside fixed columns, alongside multiple VL_BYTES columns,
 * and with empty / near-max-size cells). Round-trip parity is asserted
 * byte-for-byte.</p>
 *
 * <p>Per docs/superpowers/plans/2026-05-09-coverage-restoration.md §J.3.</p>
 */
class Hdf5CompoundIOVlBytesTest {

    @TempDir
    Path tempDir;

    // ── 1: Single VL_BYTES column + one fixed column ────────────────────

    @Test
    @DisplayName("J.3 #1: VL_BYTES + UINT32 round-trips through FFM split path")
    void vlBytesPlusFixedColumnRoundTrip() {
        String path = tempDir.resolve("vlb_plus_fixed.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("idx", Hdf5CompoundIO.FieldKind.UINT32),
                new Hdf5CompoundIO.Field("payload", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        byte[][] payloads = {
                new byte[]{ 0x01, 0x02, 0x03 },
                new byte[]{ (byte)0xAA, (byte)0xBB },
                new byte[]{ 0x10, 0x20, 0x30, 0x40, 0x50 }
        };
        int count = payloads.length;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{ row + 100, payloads[row] });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = rows.get(row);
                assertEquals(row + 100, ((Number) rec[0]).intValue(),
                        "row " + row + " idx");
                assertArrayEquals(payloads[row], (byte[]) rec[1],
                        "row " + row + " payload bytes");
            }
        }
    }

    // ── 2: Multiple VL_BYTES columns ────────────────────────────────────

    @Test
    @DisplayName("J.3 #2: multiple VL_BYTES columns each round-trip independently")
    void multipleVlBytesColumnsRoundTrip() {
        String path = tempDir.resolve("vlb_multi.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("a", Hdf5CompoundIO.FieldKind.VL_BYTES),
                new Hdf5CompoundIO.Field("b", Hdf5CompoundIO.FieldKind.VL_BYTES),
                new Hdf5CompoundIO.Field("c", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        byte[][] aData = {
                new byte[]{ 0x11 },
                new byte[]{ 0x22, 0x23 },
                new byte[]{ 0x33, 0x34, 0x35 }
        };
        byte[][] bData = {
                new byte[]{ (byte)0xF0, (byte)0xF1, (byte)0xF2, (byte)0xF3 },
                new byte[]{ (byte)0xE0 },
                new byte[]{ (byte)0xD0, (byte)0xD1 }
        };
        byte[][] cData = {
                new byte[]{ 0x00 },
                new byte[]{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 },
                new byte[]{ (byte)0xFF, (byte)0xEE }
        };
        int count = 3;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{ aData[row], bData[row], cData[row] });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = rows.get(row);
                assertArrayEquals(aData[row], (byte[]) rec[0], "row " + row + " a");
                assertArrayEquals(bData[row], (byte[]) rec[1], "row " + row + " b");
                assertArrayEquals(cData[row], (byte[]) rec[2], "row " + row + " c");
            }
        }
    }

    // ── 3: VL_BYTES with empty (zero-length) cells ──────────────────────

    @Test
    @DisplayName("J.3 #3: empty (zero-length) VL_BYTES cells round-trip as byte[0]")
    void emptyVlBytesCellsRoundTrip() {
        String path = tempDir.resolve("vlb_empty.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("payload", Hdf5CompoundIO.FieldKind.VL_BYTES),
                new Hdf5CompoundIO.Field("kind", Hdf5CompoundIO.FieldKind.UINT32)));

        // Mix of empty, one-byte, and a few-byte rows; first and last are empty.
        byte[][] payloads = {
                new byte[0],
                new byte[]{ 0x42 },
                new byte[0],
                new byte[]{ 0x10, 0x20, 0x30 },
                new byte[0]
        };
        int count = payloads.length;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{ payloads[row], row });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = rows.get(row);
                byte[] back = (byte[]) rec[0];
                assertNotNull(back, "row " + row + " back must not be null");
                assertArrayEquals(payloads[row], back, "row " + row + " payload");
                assertEquals(row, ((Number) rec[1]).intValue(), "row " + row + " kind");
            }
        }
    }

    // ── 4: VL_BYTES with bytes near the largest expected size ───────────

    @Test
    @DisplayName("J.3 #4: large VL_BYTES cells (~256 KiB) round-trip exactly")
    void largeVlBytesCellsRoundTrip() {
        String path = tempDir.resolve("vlb_large.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("blob", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        // 256 KiB and 512 KiB blobs -- realistic per-au_encryption ciphertext sizes.
        byte[][] payloads = new byte[][]{
                makePattern(256 * 1024, 0xA5),
                makePattern(512 * 1024, 0x5A),
                new byte[0],
                makePattern(1024, 0x00) // boundary: small after large
        };
        int count = payloads.length;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{ payloads[row] });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                byte[] got = (byte[]) rows.get(row)[0];
                assertEquals(payloads[row].length, got.length,
                        "row " + row + " length");
                assertArrayEquals(payloads[row], got, "row " + row + " bytes");
            }
        }
    }

    // ── 5: Full round-trip with VL_BYTES + VL_STRING + every primitive ──

    @Test
    @DisplayName("J.3 #5: VL_BYTES alongside VL_STRING and every primitive round-trips")
    void mixedSchemaWithVlBytesAndVlStringRoundTrip() {
        String path = tempDir.resolve("vlb_mixed.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("u32", Hdf5CompoundIO.FieldKind.UINT32),
                new Hdf5CompoundIO.Field("i64", Hdf5CompoundIO.FieldKind.INT64),
                new Hdf5CompoundIO.Field("f64", Hdf5CompoundIO.FieldKind.FLOAT64),
                new Hdf5CompoundIO.Field("name", Hdf5CompoundIO.FieldKind.VL_STRING),
                new Hdf5CompoundIO.Field("blob", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        String[] names = { "alpha", "", "beta-gamma" };
        byte[][] blobs = {
                new byte[]{ 0x01, 0x02 },
                new byte[0],
                new byte[]{ (byte)0xFE, (byte)0xED, (byte)0xFA, (byte)0xCE }
        };
        int count = 3;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{
                            row + 1,                  // u32
                            (long) row * 1_000_000L,  // i64
                            row + 0.5,                // f64
                            names[row],               // VL_STRING
                            blobs[row]                // VL_BYTES
                    });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = rows.get(row);
                assertEquals(row + 1, ((Number) rec[0]).intValue(), "row " + row + " u32");
                assertEquals(row * 1_000_000L, ((Number) rec[1]).longValue(),
                        "row " + row + " i64");
                assertEquals(row + 0.5, ((Number) rec[2]).doubleValue(), 0.0,
                        "row " + row + " f64");
                assertEquals(names[row], rec[3], "row " + row + " name");
                assertArrayEquals(blobs[row], (byte[]) rec[4], "row " + row + " blob");
            }
        }
    }

    // ── 6: Zero-row dataset with VL_BYTES schema ────────────────────────

    @Test
    @DisplayName("J.3 #6: zero-row VL_BYTES schema writes/reads cleanly")
    void zeroRowVlBytesSchema() {
        String path = tempDir.resolve("vlb_empty_dataset.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("idx", Hdf5CompoundIO.FieldKind.UINT32),
                new Hdf5CompoundIO.Field("blob", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "empty", schema, 0,
                    (row, pool) -> { throw new AssertionError("packer should not be called for count=0"); });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "empty", schema);
            assertTrue(rows.isEmpty(), "zero-row dataset reads back empty list");

            List<Object[]> rowsPrim = Hdf5CompoundIO.readCompoundPrimitives(
                    root, "empty", schema);
            assertTrue(rowsPrim.isEmpty(), "zero-row primitives read back empty list");
        }
    }

    // ── 7: All-primitive schema (no VL fields) -- exercises original path

    @Test
    @DisplayName("J.3 #7: all-primitive schema uses non-split write+read path")
    void allPrimitiveSchemaRoundTrip() {
        String path = tempDir.resolve("vlb_no_vl.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("u32", Hdf5CompoundIO.FieldKind.UINT32),
                new Hdf5CompoundIO.Field("i64", Hdf5CompoundIO.FieldKind.INT64),
                new Hdf5CompoundIO.Field("f64", Hdf5CompoundIO.FieldKind.FLOAT64)));

        int count = 4;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{ row + 7, (long) row * 11L, row * 0.25 });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = rows.get(row);
                assertEquals(row + 7, ((Number) rec[0]).intValue(), "row " + row + " u32");
                assertEquals(row * 11L, ((Number) rec[1]).longValue(),
                        "row " + row + " i64");
                assertEquals(row * 0.25, ((Number) rec[2]).doubleValue(), 0.0,
                        "row " + row + " f64");
            }

            // Also drive readCompoundPrimitives (returns primitive values
            // and "" for any VL fields -- here, none, so identical to above).
            List<Object[]> primRows = Hdf5CompoundIO.readCompoundPrimitives(
                    root, "ds", schema);
            assertEquals(count, primRows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = primRows.get(row);
                assertEquals(row + 7, ((Number) rec[0]).intValue());
                assertEquals(row * 11L, ((Number) rec[1]).longValue());
                assertEquals(row * 0.25, ((Number) rec[2]).doubleValue(), 0.0);
            }
        }
    }

    // ── 8: readCompoundPrimitives returns "" placeholder for VL columns ─

    @Test
    @DisplayName("J.3 #8: readCompoundPrimitives returns primitive values + \"\" for VL")
    void readCompoundPrimitivesReturnsEmptyStringForVlFields() {
        String path = tempDir.resolve("vlb_prim_only.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("u32", Hdf5CompoundIO.FieldKind.UINT32),
                new Hdf5CompoundIO.Field("i64", Hdf5CompoundIO.FieldKind.INT64),
                new Hdf5CompoundIO.Field("name", Hdf5CompoundIO.FieldKind.VL_STRING),
                new Hdf5CompoundIO.Field("blob", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        int count = 2;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{
                            row + 50,
                            (long) row + 9000L,
                            "row-" + row,
                            new byte[]{ (byte) row, (byte) (row + 1) }
                    });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundPrimitives(
                    root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                Object[] rec = rows.get(row);
                assertEquals(row + 50, ((Number) rec[0]).intValue(),
                        "row " + row + " u32");
                assertEquals(row + 9000L, ((Number) rec[1]).longValue(),
                        "row " + row + " i64");
                // VL_STRING and VL_BYTES come back as "" placeholders here.
                assertEquals("", rec[2], "row " + row + " name placeholder");
                assertEquals("", rec[3], "row " + row + " blob placeholder");
            }
        }
    }

    // ── 9: Single VL_BYTES column only (no fixed columns at all) ────────

    @Test
    @DisplayName("J.3 #9: single VL_BYTES column with no primitive fields round-trips")
    void singleVlBytesColumnNoPrimitives() {
        String path = tempDir.resolve("vlb_only.h5").toString();

        Hdf5CompoundIO.Schema schema = new Hdf5CompoundIO.Schema(List.of(
                new Hdf5CompoundIO.Field("blob", Hdf5CompoundIO.FieldKind.VL_BYTES)));

        byte[][] payloads = {
                new byte[]{ 0x01 },
                new byte[]{ 0x02, 0x03 },
                new byte[0],
                new byte[]{ 0x04, 0x05, 0x06, 0x07 }
        };
        int count = payloads.length;

        try (Hdf5File f = Hdf5File.create(path);
             Hdf5Group root = f.rootGroup()) {
            Hdf5CompoundIO.writeCompoundDataset(root, "ds", schema, count,
                    (row, pool) -> new Object[]{ payloads[row] });
        }

        try (Hdf5File f = Hdf5File.openReadOnly(path);
             Hdf5Group root = f.rootGroup()) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(root, "ds", schema);
            assertEquals(count, rows.size());
            for (int row = 0; row < count; row++) {
                assertArrayEquals(payloads[row], (byte[]) rows.get(row)[0],
                        "row " + row);
            }
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────

    private static byte[] makePattern(int len, int seedByte) {
        byte[] out = new byte[len];
        // Deterministic mixing: avoid all-equal bytes that might compress
        // away under a hidden filter pipeline.
        for (int i = 0; i < len; i++) {
            out[i] = (byte) ((seedByte + (i * 31) + (i >> 8)) & 0xFF);
        }
        return out;
    }
}
