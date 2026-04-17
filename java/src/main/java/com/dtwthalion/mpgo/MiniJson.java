/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON parser/encoder for the compound-metadata JSON attribute
 * fallback path (§6 of format-spec). Handles the exact shapes emitted
 * by the three language implementations: flat arrays of objects whose
 * values are strings, numbers, booleans, arrays, objects, or null.
 *
 * <p>Not a general-purpose JSON library. Kept in-tree to avoid pulling
 * Jackson/Gson into the dependency tree for one attribute parser.</p>
 */
public final class MiniJson {

    private MiniJson() {}

    /** Parse {@code [{...},{...}]} into a list of string-keyed maps. */
    public static List<Map<String, Object>> parseArrayOfObjects(String blob) {
        if (blob == null || blob.isEmpty()) return List.of();
        Parser p = new Parser(blob);
        p.skipWhitespace();
        Object v = p.parseValue();
        if (!(v instanceof List<?> list)) return List.of();
        List<Map<String, Object>> out = new ArrayList<>(list.size());
        for (Object o : list) {
            if (o instanceof Map<?, ?> m) {
                @SuppressWarnings("unchecked")
                Map<String, Object> cast = (Map<String, Object>) m;
                out.add(cast);
            }
        }
        return out;
    }

    /**
     * Parse a JSON object whose values are strings, e.g.
     * {@code {"key":"val"}}. Non-string values are coerced via
     * {@code toString()}. Returns an empty map on null or malformed input.
     */
    public static Map<String, String> parseStringMap(String blob) {
        if (blob == null || blob.isEmpty()) return Map.of();
        Parser p = new Parser(blob);
        p.skipWhitespace();
        Object v = p.parseValue();
        if (!(v instanceof Map<?, ?> m)) return Map.of();
        Map<String, String> out = new LinkedHashMap<>();
        for (Map.Entry<?, ?> e : m.entrySet()) {
            out.put(e.getKey().toString(),
                    e.getValue() == null ? "" : e.getValue().toString());
        }
        return out;
    }

    /** Parse a JSON array of strings, e.g. {@code ["a","b"]}. */
    public static List<String> parseArrayOfStrings(String blob) {
        if (blob == null || blob.isEmpty()) return List.of();
        Parser p = new Parser(blob);
        p.skipWhitespace();
        Object v = p.parseValue();
        if (!(v instanceof List<?> list)) return List.of();
        List<String> out = new ArrayList<>(list.size());
        for (Object o : list) {
            out.add(o == null ? "" : o.toString());
        }
        return out;
    }

    /** Encode any parsed value back to JSON. Round-trips what parser produces. */
    public static String encode(Object v) {
        StringBuilder sb = new StringBuilder();
        writeValue(sb, v);
        return sb.toString();
    }

    /** Quote a string as a JSON string literal (adds the quotes). */
    public static String quote(String s) {
        StringBuilder sb = new StringBuilder();
        writeString(sb, s == null ? "" : s);
        return sb.toString();
    }

    public static String getString(Map<String, Object> m, String key, String defaultValue) {
        Object v = m.get(key);
        if (v == null) return defaultValue;
        return v.toString();
    }

    public static long getLong(Map<String, Object> m, String key, long defaultValue) {
        Object v = m.get(key);
        if (v instanceof Number n) return n.longValue();
        if (v instanceof String s) {
            try { return Long.parseLong(s); } catch (NumberFormatException e) { return defaultValue; }
        }
        return defaultValue;
    }

    public static double getDouble(Map<String, Object> m, String key, double defaultValue) {
        Object v = m.get(key);
        if (v instanceof Number n) return n.doubleValue();
        if (v instanceof String s) {
            try { return Double.parseDouble(s); } catch (NumberFormatException e) { return defaultValue; }
        }
        return defaultValue;
    }

    // ── Encoder ─────────────────────────────────────────────────────

    private static void writeValue(StringBuilder sb, Object v) {
        if (v == null) sb.append("null");
        else if (v instanceof String s) writeString(sb, s);
        else if (v instanceof Boolean b) sb.append(b.booleanValue());
        else if (v instanceof Number n) writeNumber(sb, n);
        else if (v instanceof List<?> list) writeArray(sb, list);
        else if (v instanceof Map<?, ?> map) writeObject(sb, map);
        else writeString(sb, v.toString());
    }

    private static void writeString(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                case '\b' -> sb.append("\\b");
                case '\f' -> sb.append("\\f");
                default -> {
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
                }
            }
        }
        sb.append('"');
    }

    private static void writeNumber(StringBuilder sb, Number n) {
        if (n instanceof Double || n instanceof Float) {
            double d = n.doubleValue();
            if (d == Math.floor(d) && !Double.isInfinite(d) && Math.abs(d) < 1e16) {
                sb.append((long) d).append(".0");
            } else {
                sb.append(d);
            }
        } else {
            sb.append(n.longValue());
        }
    }

    private static void writeArray(StringBuilder sb, List<?> list) {
        sb.append('[');
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            writeValue(sb, list.get(i));
        }
        sb.append(']');
    }

    private static void writeObject(StringBuilder sb, Map<?, ?> map) {
        sb.append('{');
        boolean first = true;
        for (Map.Entry<?, ?> e : map.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            writeString(sb, e.getKey().toString());
            sb.append(':');
            writeValue(sb, e.getValue());
        }
        sb.append('}');
    }

    // ── Parser ──────────────────────────────────────────────────────

    private static final class Parser {
        private final String src;
        private int pos;

        Parser(String src) { this.src = src; this.pos = 0; }

        Object parseValue() {
            skipWhitespace();
            if (pos >= src.length()) throw error("unexpected EOF");
            char c = src.charAt(pos);
            return switch (c) {
                case '"' -> parseString();
                case '{' -> parseObject();
                case '[' -> parseArray();
                case 't', 'f' -> parseBool();
                case 'n' -> parseNull();
                default -> parseNumber();
            };
        }

        Map<String, Object> parseObject() {
            expect('{');
            Map<String, Object> m = new LinkedHashMap<>();
            skipWhitespace();
            if (peek() == '}') { pos++; return m; }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                expect(':');
                Object v = parseValue();
                m.put(key, v);
                skipWhitespace();
                char c = peek();
                if (c == ',') { pos++; continue; }
                if (c == '}') { pos++; return m; }
                throw error("expected , or } in object");
            }
        }

        List<Object> parseArray() {
            expect('[');
            List<Object> list = new ArrayList<>();
            skipWhitespace();
            if (peek() == ']') { pos++; return list; }
            while (true) {
                list.add(parseValue());
                skipWhitespace();
                char c = peek();
                if (c == ',') { pos++; continue; }
                if (c == ']') { pos++; return list; }
                throw error("expected , or ] in array");
            }
        }

        String parseString() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (pos < src.length()) {
                char c = src.charAt(pos++);
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    if (pos >= src.length()) throw error("EOF in escape");
                    char e = src.charAt(pos++);
                    switch (e) {
                        case '"' -> sb.append('"');
                        case '\\' -> sb.append('\\');
                        case '/' -> sb.append('/');
                        case 'n' -> sb.append('\n');
                        case 'r' -> sb.append('\r');
                        case 't' -> sb.append('\t');
                        case 'b' -> sb.append('\b');
                        case 'f' -> sb.append('\f');
                        case 'u' -> {
                            if (pos + 4 > src.length()) throw error("bad \\u escape");
                            int code = Integer.parseInt(src.substring(pos, pos + 4), 16);
                            sb.append((char) code);
                            pos += 4;
                        }
                        default -> throw error("unknown escape \\" + e);
                    }
                } else {
                    sb.append(c);
                }
            }
            throw error("EOF in string");
        }

        Object parseNumber() {
            int start = pos;
            if (peek() == '-') pos++;
            while (pos < src.length() && isNumberChar(src.charAt(pos))) pos++;
            String num = src.substring(start, pos);
            if (num.contains(".") || num.contains("e") || num.contains("E")) {
                return Double.parseDouble(num);
            }
            try {
                return Long.parseLong(num);
            } catch (NumberFormatException e) {
                return Double.parseDouble(num);
            }
        }

        Boolean parseBool() {
            if (src.startsWith("true", pos)) { pos += 4; return Boolean.TRUE; }
            if (src.startsWith("false", pos)) { pos += 5; return Boolean.FALSE; }
            throw error("expected true or false");
        }

        Object parseNull() {
            if (src.startsWith("null", pos)) { pos += 4; return null; }
            throw error("expected null");
        }

        void skipWhitespace() {
            while (pos < src.length() && Character.isWhitespace(src.charAt(pos))) pos++;
        }

        char peek() {
            if (pos >= src.length()) throw error("unexpected EOF");
            return src.charAt(pos);
        }

        void expect(char c) {
            if (pos >= src.length() || src.charAt(pos) != c) {
                throw error("expected '" + c + "'");
            }
            pos++;
        }

        boolean isNumberChar(char c) {
            return (c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-';
        }

        IllegalArgumentException error(String msg) {
            return new IllegalArgumentException("MiniJson: " + msg + " at pos " + pos
                    + " near '" + src.substring(Math.max(0, pos - 10), Math.min(src.length(), pos + 10)) + "'");
        }
    }
}
