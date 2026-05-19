/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Direct tests for the internal {@link WorkbenchJson} encoder +
 * parser. The handshake suite exercises encoder paths transitively,
 * but the parser branches (booleans, null, arrays, scientific
 * notation, escape sequences) need targeted tests to drive
 * coverage to the v1.0 0.84 BUNDLE line floor.
 */
class WorkbenchJsonTest {

    // ---------------- encoder

    @Test
    void encodeNull() {
        assertEquals("null", WorkbenchJson.encode(null));
    }

    @Test
    void encodeBooleans() {
        assertEquals("true", WorkbenchJson.encode(Boolean.TRUE));
        assertEquals("false", WorkbenchJson.encode(Boolean.FALSE));
    }

    @Test
    void encodeNumbers() {
        assertEquals("0", WorkbenchJson.encode(0));
        assertEquals("-42", WorkbenchJson.encode(-42L));
        assertEquals("1.5", WorkbenchJson.encode(1.5));
    }

    @Test
    void encodeStringEscapes() {
        assertEquals("\"\\\"\\\\\\n\\r\\t\\b\\f\"",
            WorkbenchJson.encode("\"\\\n\r\t\b\f"));
    }

    @Test
    void encodeAsciiStringUnchanged() {
        assertEquals("\"hello world\"", WorkbenchJson.encode("hello world"));
    }

    @Test
    void encodeUnicodeEscapesNonAscii() {
        // ASCII-only output: non-ASCII codepoints become \\uXXXX.
        String out = WorkbenchJson.encode("café");
        assertEquals("\"caf\\u00e9\"", out);
    }

    @Test
    void encodeControlCharEscapes() {
        // C0 control (NUL through US, except the named escapes) -> \\uXXXX.
        assertEquals("\"\\u0001\"", WorkbenchJson.encode(""));
    }

    @Test
    void encodeNestedObject() {
        Map<String, Object> inner = new LinkedHashMap<>();
        inner.put("k", "v");
        Map<String, Object> outer = new LinkedHashMap<>();
        outer.put("nested", inner);
        outer.put("n", 1L);
        assertEquals("{\"nested\":{\"k\":\"v\"},\"n\":1}",
            WorkbenchJson.encode(outer));
    }

    @Test
    void encodeList() {
        assertEquals("[1,2,3]", WorkbenchJson.encode(List.of(1L, 2L, 3L)));
    }

    @Test
    void encodeEmptyCollections() {
        assertEquals("[]", WorkbenchJson.encode(List.of()));
        assertEquals("{}", WorkbenchJson.encode(Map.of()));
    }

    @Test
    void encodeFallbackToString() {
        // Non-Boolean/Number/CharSequence/Map/List goes through
        // toString() + string-quote.
        Object opaque = new Object() {
            @Override public String toString() { return "OPAQUE"; }
        };
        assertEquals("\"OPAQUE\"", WorkbenchJson.encode(opaque));
    }

    // ---------------- parser

    @Test
    void parseNull() {
        assertNull(WorkbenchJson.parse("null"));
    }

    @Test
    void parseBooleans() {
        assertEquals(Boolean.TRUE, WorkbenchJson.parse("true"));
        assertEquals(Boolean.FALSE, WorkbenchJson.parse("false"));
    }

    @Test
    void parseInteger() {
        assertEquals(42L, WorkbenchJson.parse("42"));
        assertEquals(-7L, WorkbenchJson.parse("-7"));
    }

    @Test
    void parseDouble() {
        assertEquals(1.5, WorkbenchJson.parse("1.5"));
        assertEquals(-0.125, WorkbenchJson.parse("-0.125"));
    }

    @Test
    void parseScientificNotation() {
        assertEquals(1.0e3, WorkbenchJson.parse("1.0e3"));
        assertEquals(1.0e-3, WorkbenchJson.parse("1.0e-3"));
        assertEquals(2.0E2, WorkbenchJson.parse("2.0E+2"));
    }

    @Test
    void parseString() {
        assertEquals("hello", WorkbenchJson.parse("\"hello\""));
    }

    @Test
    void parseStringEscapes() {
        assertEquals("\"\\\n\r\t\b\f/",
            WorkbenchJson.parse("\"\\\"\\\\\\n\\r\\t\\b\\f\\/\""));
    }

    @Test
    void parseUnicodeEscape() {
        assertEquals("café",
            WorkbenchJson.parse("\"caf\\u00e9\""));
    }

    @Test
    void parseEmptyObject() {
        Object result = WorkbenchJson.parse("{}");
        assertInstanceOf(Map.class, result);
        assertTrue(((Map<?, ?>) result).isEmpty());
    }

    @Test
    void parseEmptyArray() {
        Object result = WorkbenchJson.parse("[]");
        assertInstanceOf(List.class, result);
        assertTrue(((List<?>) result).isEmpty());
    }

    @Test
    void parseNestedObject() {
        @SuppressWarnings("unchecked")
        Map<String, Object> m = (Map<String, Object>)
            WorkbenchJson.parse("{\"a\":1,\"b\":[true,null,\"x\"]}");
        assertEquals(1L, m.get("a"));
        @SuppressWarnings("unchecked")
        List<Object> b = (List<Object>) m.get("b");
        assertEquals(3, b.size());
        assertEquals(Boolean.TRUE, b.get(0));
        assertNull(b.get(1));
        assertEquals("x", b.get(2));
    }

    @Test
    void parseTolerantOfWhitespace() {
        assertEquals(42L, WorkbenchJson.parse("  42  "));
        assertEquals("a",
            ((Map<?, ?>) WorkbenchJson.parse("  {  \"k\"  :  \"a\"  }  ")).get("k"));
    }

    @Test
    void parseRoundTripObject() {
        Map<String, Object> in = new LinkedHashMap<>();
        in.put("s", "hello");
        in.put("n", 7L);
        in.put("b", Boolean.TRUE);
        in.put("nil", null);
        in.put("arr", List.of(1L, 2L, 3L));
        String encoded = WorkbenchJson.encode(in);
        @SuppressWarnings("unchecked")
        Map<String, Object> out = (Map<String, Object>) WorkbenchJson.parse(encoded);
        assertEquals("hello", out.get("s"));
        assertEquals(7L, out.get("n"));
        assertEquals(Boolean.TRUE, out.get("b"));
        assertNull(out.get("nil"));
        assertEquals(List.of(1L, 2L, 3L), out.get("arr"));
    }

    // ---------------- parser error cases

    @Test
    void parseRejectsTrailingGarbage() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("{} junk"));
    }

    @Test
    void parseRejectsUnterminatedString() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("\"oops"));
    }

    @Test
    void parseRejectsBadEscape() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("\"\\x\""));
    }

    @Test
    void parseRejectsTruncatedUnicode() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("\"\\u00\""));
    }

    @Test
    void parseRejectsUnexpectedChar() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("???"));
    }

    @Test
    void parseRejectsBadBool() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("tru"));
    }

    @Test
    void parseRejectsBadNull() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("nu"));
    }

    @Test
    void parseRejectsUnclosedObject() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("{\"k\":1"));
    }

    @Test
    void parseRejectsObjectMissingColon() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("{\"k\" 1}"));
    }

    @Test
    void parseRejectsArrayMissingComma() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse("[1 2]"));
    }

    @Test
    void parseRejectsEmptyInput() {
        assertThrows(IllegalArgumentException.class,
            () -> WorkbenchJson.parse(""));
    }
}
