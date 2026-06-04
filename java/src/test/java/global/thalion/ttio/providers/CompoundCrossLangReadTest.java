/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.Statement;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * P2.7 QT2 — cross-language compound round-trip conformance fence.
 *
 * <p>This is the documented <em>read-side</em> (#205) cross-language
 * conformance test for {@link SqliteProvider}'s Jackson-based compound-JSON
 * reader. It opens a {@code .tio.sqlite} whose {@code compound_fields},
 * {@code compound_rows}, and {@code shape_json} columns hold the <b>verbatim
 * byte form a non-Java writer (the Python {@code SqliteProvider}) actually
 * emits via {@code json.dumps}</b> — i.e. {@code ", "} / {@code ": "}
 * whitespace-padded separators, Python's float repr ({@code 3.0} for an
 * integral float), escaped string values, AND a field VALUE that contains the
 * literal token {@code "kind":"int64"} — the exact substring-confusion class
 * that the old hand-rolled split-on-{@code "},{"} reader mishandled (#205).
 *
 * <p>The JSON strings below were captured directly from
 * {@code ttio.providers.sqlite}'s {@code json.dumps} output (see the matching
 * Python test {@code test_compound_sqlite_crosslang_roundtrip.py}). The fixture
 * is assembled in-test against the byte-identical SQLite schema both SDKs share,
 * so this fence runs on every CI without a runtime Python or a checked-in binary.
 *
 * <p>The byte-canonical JSON <em>serializer</em> is unchanged by QT1/QT2, so
 * compound byte-parity across languages is preserved (asserted separately by
 * {@code test_compound_writer_parity.py} /
 * {@code test_canonical_bytes_cross_backend.py}); this test asserts the dual
 * obligation — Java must <em>read back</em> what another language legitimately
 * <em>wrote</em>, with the correct typed values.
 */
final class CompoundCrossLangReadTest {

    // Verbatim Python json.dumps output for a 4-field schema. Note the
    // ", " and ": " padding a non-Java writer emits but the Java
    // canonical serializer never would.
    private static final String PY_FIELDS_JSON =
        "[{\"name\": \"run_name\", \"kind\": \"vl_string\"}, "
        + "{\"name\": \"spectrum_index\", \"kind\": \"uint32\"}, "
        + "{\"name\": \"score\", \"kind\": \"float64\"}, "
        + "{\"name\": \"chem_id\", \"kind\": \"vl_string\"}]";

    // Verbatim Python json.dumps output for three rows. Row 1's run_name VALUE
    // contains the literal substring "kind":"int64" plus a comma and braces;
    // row 1's score is the integral float -1.5; row 2's score 3.0 is emitted by
    // Python's float repr as "3.0" (a floating-point JSON token, not "3").
    private static final String PY_ROWS_JSON =
        "[{\"run_name\": \"runA\", \"spectrum_index\": 0, "
        + "\"score\": 0.95, \"chem_id\": \"CHEBI:15377\"}, "
        + "{\"run_name\": \"r,b{x} said \\\"kind\\\":\\\"int64\\\"\", "
        + "\"spectrum_index\": 42, \"score\": -1.5, \"chem_id\": \"\"}, "
        + "{\"run_name\": \"pi\", \"spectrum_index\": 7, "
        + "\"score\": 3.0, \"chem_id\": \"u\"}]";

    private static final String PY_SHAPE_JSON = "[3]";

    /**
     * Build a {@code .tio.sqlite} whose datasets row carries the verbatim
     * Python on-disk JSON, then return its path. The schema mirrors the one
     * both SDKs' {@code SqliteProvider} create — a single root group "/" with
     * one compound dataset.
     */
    private static Path writePythonStyleFixture(Path dir) throws Exception {
        Path f = dir.resolve("py_compound.tio.sqlite");
        String url = "jdbc:sqlite:" + f.toAbsolutePath();
        try (Connection c = DriverManager.getConnection(url)) {
            try (Statement st = c.createStatement()) {
                st.execute("CREATE TABLE groups ("
                    + "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                    + "parent_id INTEGER REFERENCES groups(id) ON DELETE CASCADE,"
                    + "name TEXT NOT NULL, UNIQUE(parent_id, name))");
                st.execute("CREATE TABLE datasets ("
                    + "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                    + "group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,"
                    + "name TEXT NOT NULL,"
                    + "kind TEXT NOT NULL CHECK(kind IN ('primitive','compound')),"
                    + "precision TEXT, shape_json TEXT NOT NULL, data BLOB,"
                    + "compound_fields TEXT, compound_rows TEXT,"
                    + "UNIQUE(group_id, name))");
                st.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
                st.execute("INSERT INTO meta (key, value) VALUES "
                    + "('schema_version','1'),('provider','ttio.providers.sqlite')");
                st.execute("INSERT INTO groups (parent_id, name) VALUES (NULL, '/')");
            }
            try (PreparedStatement ps = c.prepareStatement(
                    "INSERT INTO datasets (group_id, name, kind, precision, "
                    + "shape_json, compound_fields, compound_rows) "
                    + "VALUES (1, 'idents', 'compound', NULL, ?, ?, ?)")) {
                ps.setString(1, PY_SHAPE_JSON);
                ps.setString(2, PY_FIELDS_JSON);
                ps.setString(3, PY_ROWS_JSON);
                ps.executeUpdate();
            }
        }
        return f;
    }

    @Test
    void readsPythonWrittenCompoundFieldsRowsAndShape(@TempDir Path dir) throws Exception {
        Path fixture = writePythonStyleFixture(dir);

        SqliteProvider provider = new SqliteProvider();
        try (StorageProvider p = provider.open(fixture.toString(), StorageProvider.Mode.READ)) {
            StorageDataset ds = p.rootGroup().openDataset("idents");

            // ── Schema (compound_fields) round-trips from Python whitespace JSON.
            List<CompoundField> fields = ds.compoundFields();
            assertEquals(List.of(
                new CompoundField("run_name", CompoundField.Kind.VL_STRING),
                new CompoundField("spectrum_index", CompoundField.Kind.UINT32),
                new CompoundField("score", CompoundField.Kind.FLOAT64),
                new CompoundField("chem_id", CompoundField.Kind.VL_STRING)
            ), fields);

            // ── Shape round-trips.
            assertArrayEquals(new long[]{3L}, ds.shape());

            // ── Rows round-trip with the correct typed values.
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> rows = (List<Map<String, Object>>) ds.readAll();
            assertEquals(3, rows.size());

            // Row 0.
            Map<String, Object> r0 = rows.get(0);
            assertEquals("runA", r0.get("run_name"));
            assertInstanceOf(Long.class, r0.get("spectrum_index"));
            assertEquals(0L, r0.get("spectrum_index"));
            assertInstanceOf(Double.class, r0.get("score"));
            assertEquals(0.95, r0.get("score"));
            assertEquals("CHEBI:15377", r0.get("chem_id"));

            // Row 1 — the #205 substring-confusion case: a run_name VALUE that
            // contains the literal token "kind":"int64" plus a comma and braces.
            // A structural parser keys off JSON structure, not substrings.
            Map<String, Object> r1 = rows.get(1);
            assertEquals("r,b{x} said \"kind\":\"int64\"", r1.get("run_name"));
            assertEquals(42L, r1.get("spectrum_index"));
            assertEquals(-1.5, r1.get("score"));
            assertEquals("", r1.get("chem_id"));

            // Row 2 — Python's float repr emits the integral float as "3.0", a
            // floating-point JSON token, so it must read back as a Double 3.0.
            Map<String, Object> r2 = rows.get(2);
            assertEquals("pi", r2.get("run_name"));
            assertEquals(7L, r2.get("spectrum_index"));
            assertInstanceOf(Double.class, r2.get("score"));
            assertEquals(3.0, r2.get("score"));
            assertEquals("u", r2.get("chem_id"));
        }
    }

    /**
     * A read-slice over the Python-written compound dataset must return the
     * same typed rows as a full read (exercises the offset/count branch of the
     * compound {@code readSlice} against another language's on-disk bytes).
     */
    @Test
    void readSlicePythonWrittenCompound(@TempDir Path dir) throws Exception {
        Path fixture = writePythonStyleFixture(dir);
        SqliteProvider provider = new SqliteProvider();
        try (StorageProvider p = provider.open(fixture.toString(), StorageProvider.Mode.READ)) {
            StorageDataset ds = p.rootGroup().openDataset("idents");
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> slice =
                (List<Map<String, Object>>) ds.readSlice(1, 2);
            assertEquals(2, slice.size());
            assertEquals("r,b{x} said \"kind\":\"int64\"", slice.get(0).get("run_name"));
            assertEquals("pi", slice.get(1).get("run_name"));
            assertTrue(slice.get(0).containsKey("chem_id"));
        }
    }
}
