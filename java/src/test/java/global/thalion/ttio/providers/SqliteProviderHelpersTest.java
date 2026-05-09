/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-bridge tests for {@link SqliteProvider}'s package-private
 * helpers + transaction lifecycle methods that the existing
 * {@link SqliteProviderTest} did not exercise:
 * <ul>
 *   <li>{@link SqliteProvider#encodeAttr} — every value-kind branch.</li>
 *   <li>{@link SqliteProvider#decodeAttr} — every {@code valueType}
 *       switch arm including the catch-all default.</li>
 *   <li>{@link SqliteProvider#beginTransaction},
 *       {@link SqliteProvider#commitTransaction},
 *       {@link SqliteProvider#rollbackTransaction} — both happy-path
 *       and the {@code conn == null} error branches.</li>
 *   <li>{@link SqliteProvider#toString} — both open-with-path and
 *       closed branches.</li>
 * </ul>
 *
 * <p>Per docs/superpowers/plans/2026-05-09-coverage-restoration.md J.6.</p>
 */
class SqliteProviderHelpersTest {

    @Test
    @DisplayName("SqliteProvider.encodeAttr: every value-kind branch")
    void encodeAttrAllBranches() {
        // Boolean → "int" / "0|1"
        assertArrayEquals(new String[]{"int", "1"},
            SqliteProvider.encodeAttr(Boolean.TRUE));
        assertArrayEquals(new String[]{"int", "0"},
            SqliteProvider.encodeAttr(Boolean.FALSE));

        // Integer → "int"
        assertArrayEquals(new String[]{"int", "42"},
            SqliteProvider.encodeAttr(Integer.valueOf(42)));

        // Long → "int"
        assertArrayEquals(new String[]{"int", "-7"},
            SqliteProvider.encodeAttr(Long.valueOf(-7L)));

        // Double → "float"
        assertArrayEquals(new String[]{"float", "1.5"},
            SqliteProvider.encodeAttr(Double.valueOf(1.5)));

        // Float → "float" (widened to double for serialization).
        // 0.5f is exactly representable, so no widening artefact.
        String[] encFloat = SqliteProvider.encodeAttr(Float.valueOf(0.5f));
        assertEquals("float", encFloat[0]);
        assertEquals(Double.toString((double) 0.5f), encFloat[1]);

        // String → "string"
        assertArrayEquals(new String[]{"string", "hello world"},
            SqliteProvider.encodeAttr("hello world"));

        // Anything else → "string" via toString fallback (catch-all).
        // Use a List to confirm the non-String, non-Number branch.
        String[] encList = SqliteProvider.encodeAttr(List.of("a", "b"));
        assertEquals("string", encList[0]);
        assertEquals(List.of("a", "b").toString(), encList[1]);
    }

    @Test
    @DisplayName("SqliteProvider.decodeAttr: every switch arm including default")
    void decodeAttrAllBranches() {
        // "int" → Long
        Object decInt = SqliteProvider.decodeAttr("int", "42");
        assertTrue(decInt instanceof Long);
        assertEquals(42L, decInt);

        // "float" → Double
        Object decFloat = SqliteProvider.decodeAttr("float", "1.5");
        assertTrue(decFloat instanceof Double);
        assertEquals(1.5, (double) decFloat, 0.0);

        // "string" → String (default switch arm)
        Object decStr = SqliteProvider.decodeAttr("string", "hi");
        assertEquals("hi", decStr);

        // Unknown value_type → falls into the same default arm as
        // "string", returning the raw value verbatim. This branch is
        // only reachable when the SQLite column is corrupted or
        // written by a peer with a future-version type tag.
        assertEquals("payload",
            SqliteProvider.decodeAttr("unknown_kind", "payload"));
    }

    @Test
    @DisplayName("SqliteProvider.toString: 'closed' before open, 'path=...' after")
    void toStringOpenAndClosed(@TempDir Path tmp) {
        // Closed (path field still null) → "SqliteProvider(closed)".
        SqliteProvider p = new SqliteProvider();
        assertEquals("SqliteProvider(closed)", p.toString());

        // Open → "SqliteProvider(path=...)".
        String path = tmp.resolve("tostring.tio.sqlite").toString();
        p.open(path, StorageProvider.Mode.CREATE);
        try {
            String s = p.toString();
            assertTrue(s.startsWith("SqliteProvider(path="),
                "open provider stringifies with path prefix: " + s);
            assertTrue(s.contains("tostring"),
                "stringification carries the actual path: " + s);
        } finally {
            p.close();
        }
    }

    @Test
    @DisplayName("SqliteProvider: beginTransaction + commitTransaction batches multiple writes")
    void commitTransactionBatchesWrites(@TempDir Path tmp) {
        String path = tmp.resolve("commit.tio.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();

            // Open an explicit batch — exercises beginTransaction().
            p.beginTransaction();

            // Mutate several attributes inside the batch.
            root.setAttribute("count", 1L);
            root.setAttribute("rate", 0.5);
            root.setAttribute("note", "batched");

            // Commit — exercises commitTransaction() happy path.
            p.commitTransaction();

            // The committed values are visible after commit.
            assertEquals(1L, root.getAttribute("count"));
            assertEquals(0.5, (double) root.getAttribute("rate"), 0.0);
            assertEquals("batched", root.getAttribute("note"));
        }
    }

    @Test
    @DisplayName("SqliteProvider: rollbackTransaction discards uncommitted writes")
    void rollbackTransactionDiscardsWrites(@TempDir Path tmp) {
        String path = tmp.resolve("rollback.tio.sqlite").toString();
        try (SqliteProvider p = new SqliteProvider()) {
            p.open(path, StorageProvider.Mode.CREATE);
            StorageGroup root = p.rootGroup();

            // Establish a baseline value committed outside the batch.
            root.setAttribute("seed", "before");

            // Open a batch, mutate, then roll back — exercises
            // rollbackTransaction(). The mutation must not survive.
            p.beginTransaction();
            root.setAttribute("seed", "during");
            root.setAttribute("scratch", 99L);
            p.rollbackTransaction();

            // Post-rollback: the original baseline survives, the
            // scratch attribute should not exist.
            assertEquals("before", root.getAttribute("seed"));
            List<String> names = root.attributeNames();
            assertFalse(names.contains("scratch"),
                "rolled-back attribute should not be visible: " + names);
        }
    }

    @Test
    @DisplayName("SqliteProvider: commit/rollback on never-opened provider raise IllegalStateException")
    void transactionOnClosedProviderThrows() {
        // Both commit and rollback take the conn == null branch on a
        // freshly constructed provider that was never open()'d.
        SqliteProvider p = new SqliteProvider();
        assertThrows(IllegalStateException.class, p::commitTransaction);
        assertThrows(IllegalStateException.class, p::rollbackTransaction);
    }
}
