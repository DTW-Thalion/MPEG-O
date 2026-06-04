/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Fence test for QT1: the SqliteProvider JSON reader must round-trip the
 * byte-canonical serializer with IDENTICAL value types, and must robustly
 * parse non-canonical (whitespace-padded / reordered-key / escaped) JSON
 * that a non-Java writer could emit (the #205 fix).
 */
final class SqliteProviderJsonReaderTest {

    // ── Round-trip identity: fields ──────────────────────────────────────

    @Test
    void fieldsRoundTripPreservesEachKind() {
        List<CompoundField> fields = List.of(
            new CompoundField("u", CompoundField.Kind.UINT32),
            new CompoundField("i", CompoundField.Kind.INT64),
            new CompoundField("f", CompoundField.Kind.FLOAT64),
            new CompoundField("s", CompoundField.Kind.VL_STRING)
        );
        assertEquals(fields,
            SqliteProvider.fieldsFromJson(SqliteProvider.fieldsToJson(fields)));
    }

    @Test
    void fieldsEmptyRoundTrips() {
        List<CompoundField> fields = new ArrayList<>();
        assertEquals(fields,
            SqliteProvider.fieldsFromJson(SqliteProvider.fieldsToJson(fields)));
    }

    // ── Round-trip identity: rows (value types preserved) ────────────────

    @Test
    void rowsRoundTripPreservesValueTypes() {
        Map<String, Object> row = new LinkedHashMap<>();
        // A string with the JSON-significant characters: comma, braces, quote,
        // and a backslash — the case the brittle split-on-},{ mishandles.
        row.put("str", "a,b{c}d\"e\\f");
        row.put("lng", 42L);
        row.put("dbl", 3.5);
        row.put("bool", Boolean.TRUE);
        row.put("nul", null);

        List<Map<String, Object>> rows = List.of(row);
        List<Map<String, Object>> out =
            SqliteProvider.rowsFromJson(SqliteProvider.rowsToJson(rows));

        assertEquals(1, out.size());
        Map<String, Object> r = out.get(0);

        assertInstanceOf(String.class, r.get("str"));
        assertEquals("a,b{c}d\"e\\f", r.get("str"));

        assertInstanceOf(Long.class, r.get("lng"));
        assertEquals(42L, r.get("lng"));

        assertInstanceOf(Double.class, r.get("dbl"));
        assertEquals(3.5, r.get("dbl"));

        assertInstanceOf(Boolean.class, r.get("bool"));
        assertEquals(Boolean.TRUE, r.get("bool"));

        assertTrue(r.containsKey("nul"));
        assertNull(r.get("nul"));

        assertEquals(row, r);
    }

    @Test
    void rowsEmptyRoundTrips() {
        List<Map<String, Object>> rows = new ArrayList<>();
        assertEquals(rows,
            SqliteProvider.rowsFromJson(SqliteProvider.rowsToJson(rows)));
    }

    // ── Round-trip identity: shapes ──────────────────────────────────────

    @Test
    void shapesRoundTrip() {
        long[][] cases = { {}, {7}, {2, 3, 5} };
        for (long[] shape : cases) {
            assertArrayEquals(shape,
                SqliteProvider.shapeFromJson(SqliteProvider.shapeToJson(shape)));
        }
    }

    // ── Robustness (#205): non-canonical JSON a non-Java writer emits ────

    @Test
    void fieldsParseWhitespacePadded() {
        List<CompoundField> got = SqliteProvider.fieldsFromJson(
            "[ { \"name\" : \"x\" , \"kind\" : \"vl_string\" } ]");
        assertEquals(
            List.of(new CompoundField("x", CompoundField.Kind.VL_STRING)), got);
    }

    @Test
    void fieldsParseReorderedKeys() {
        List<CompoundField> got = SqliteProvider.fieldsFromJson(
            "[{\"kind\":\"int64\",\"name\":\"y\"}]");
        assertEquals(
            List.of(new CompoundField("y", CompoundField.Kind.INT64)), got);
    }

    @Test
    void fieldNameValueContainingKindTokenParsesCorrectly() {
        // A "name" VALUE that itself contains the text "kind":"int64" must not
        // be confused for the real kind key (#205 bug class). A structural JSON
        // parser keys off structure, not substrings.
        List<CompoundField> got = SqliteProvider.fieldsFromJson(
            "[{\"name\":\"a \\\"kind\\\":\\\"int64\\\" b\",\"kind\":\"vl_string\"}]");
        assertEquals(1, got.size());
        assertEquals("a \"kind\":\"int64\" b", got.get(0).name());
        assertEquals(CompoundField.Kind.VL_STRING, got.get(0).kind());
    }

    @Test
    void rowsParseReorderedKeysWhitespaceAndEscapes() {
        // Reordered keys, padded whitespace, and an escaped string value.
        List<Map<String, Object>> got = SqliteProvider.rowsFromJson(
            "[ { \"v\" : \"he said \\\"hi\\\" , {ok}\" , \"n\" : 7 } ]");
        assertEquals(1, got.size());
        Map<String, Object> r = got.get(0);
        assertEquals("he said \"hi\" , {ok}", r.get("v"));
        assertInstanceOf(Long.class, r.get("n"));
        assertEquals(7L, r.get("n"));
    }
}
