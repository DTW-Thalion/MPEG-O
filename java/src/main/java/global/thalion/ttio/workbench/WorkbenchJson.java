/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON encoder + parser scoped to the workbench client's
 * handshake + ack frames.
 *
 * <p>This package intentionally avoids a Jackson / Gson dependency
 * (matching the rest of the TTI-O Java codebase: see
 * {@link global.thalion.ttio.importers.BamDump} and
 * {@link global.thalion.ttio.ProvenanceJsonParse} for the
 * hand-rolled pattern). The frames we handle are shallow: 5-6
 * top-level fields, scalar values (string, integer, boolean), one
 * level of nesting for the download {@code filter} object.</p>
 *
 * <p>NOT a general-purpose JSON library. Refuses comments,
 * trailing commas, unicode escapes outside the BMP, scientific
 * notation, and arrays of mixed types beyond what the workbench
 * frames need.</p>
 *
 * <p>Marked {@code public} only because the sub-packages
 * {@code auth} and {@code transport} need to call into it. Treat
 * as an internal utility -- not part of the SDK's API stability
 * promise.</p>
 */
public final class WorkbenchJson {

    private WorkbenchJson() {}

    // ---------------- emitter ----------------

    /** Emit {@code obj} as compact JSON (no whitespace between
     *  tokens). Output is a UTF-8-safe ASCII string -- non-ASCII
     *  codepoints emerge as {@code \\uXXXX} escapes. */
    public static String encode(Object obj) {
        StringBuilder sb = new StringBuilder(128);
        write(sb, obj);
        return sb.toString();
    }

    @SuppressWarnings("unchecked")
    private static void write(StringBuilder sb, Object value) {
        if (value == null) {
            sb.append("null");
        } else if (value instanceof Boolean b) {
            sb.append(b.booleanValue() ? "true" : "false");
        } else if (value instanceof Number n) {
            sb.append(n.toString());
        } else if (value instanceof CharSequence cs) {
            writeString(sb, cs.toString());
        } else if (value instanceof Map<?, ?> m) {
            sb.append('{');
            boolean first = true;
            for (var entry : m.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                writeString(sb, entry.getKey().toString());
                sb.append(':');
                write(sb, entry.getValue());
            }
            sb.append('}');
        } else if (value instanceof List<?> l) {
            sb.append('[');
            boolean first = true;
            for (Object item : l) {
                if (!first) sb.append(',');
                first = false;
                write(sb, item);
            }
            sb.append(']');
        } else {
            writeString(sb, value.toString());
        }
    }

    private static void writeString(StringBuilder sb, String s) {
        sb.append('"');
        int n = s.length();
        for (int i = 0; i < n; i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                case '\b': sb.append("\\b");  break;
                case '\f': sb.append("\\f");  break;
                default:
                    if (c < 0x20 || c > 0x7E) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
    }

    // ---------------- parser ----------------

    /** Parse a JSON document into Map / List / String / Long / Double /
     *  Boolean / null. Throws {@link IllegalArgumentException} for
     *  anything malformed. */
    public static Object parse(String json) {
        Parser p = new Parser(json);
        p.skipWs();
        Object out = p.readValue();
        p.skipWs();
        if (p.pos != p.src.length()) {
            throw new IllegalArgumentException(
                "trailing garbage at offset " + p.pos);
        }
        return out;
    }

    private static final class Parser {
        final String src;
        int pos;
        Parser(String src) { this.src = src; this.pos = 0; }

        void skipWs() {
            while (pos < src.length()) {
                char c = src.charAt(pos);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++;
                else break;
            }
        }

        Object readValue() {
            skipWs();
            if (pos >= src.length()) throw fail("unexpected end of input");
            char c = src.charAt(pos);
            if (c == '{') return readObject();
            if (c == '[') return readArray();
            if (c == '"') return readString();
            if (c == 't' || c == 'f') return readBool();
            if (c == 'n') return readNull();
            if (c == '-' || (c >= '0' && c <= '9')) return readNumber();
            throw fail("unexpected character '" + c + "'");
        }

        Map<String, Object> readObject() {
            expect('{');
            Map<String, Object> out = new LinkedHashMap<>();
            skipWs();
            if (peek() == '}') { pos++; return out; }
            while (true) {
                skipWs();
                String key = readString();
                skipWs();
                expect(':');
                Object value = readValue();
                out.put(key, value);
                skipWs();
                char c = peek();
                if (c == ',') { pos++; continue; }
                if (c == '}') { pos++; return out; }
                throw fail("expected ',' or '}'");
            }
        }

        List<Object> readArray() {
            expect('[');
            List<Object> out = new java.util.ArrayList<>();
            skipWs();
            if (peek() == ']') { pos++; return out; }
            while (true) {
                out.add(readValue());
                skipWs();
                char c = peek();
                if (c == ',') { pos++; continue; }
                if (c == ']') { pos++; return out; }
                throw fail("expected ',' or ']'");
            }
        }

        String readString() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (pos < src.length()) {
                char c = src.charAt(pos++);
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    if (pos >= src.length()) throw fail("bad escape");
                    char e = src.charAt(pos++);
                    switch (e) {
                        case '"':  sb.append('"');  break;
                        case '\\': sb.append('\\'); break;
                        case '/':  sb.append('/');  break;
                        case 'n':  sb.append('\n'); break;
                        case 'r':  sb.append('\r'); break;
                        case 't':  sb.append('\t'); break;
                        case 'b':  sb.append('\b'); break;
                        case 'f':  sb.append('\f'); break;
                        case 'u':
                            if (pos + 4 > src.length()) throw fail("bad \\u");
                            int cp = Integer.parseInt(src.substring(pos, pos + 4), 16);
                            sb.append((char) cp);
                            pos += 4;
                            break;
                        default: throw fail("bad escape \\" + e);
                    }
                } else {
                    sb.append(c);
                }
            }
            throw fail("unterminated string");
        }

        Boolean readBool() {
            if (src.startsWith("true", pos))  { pos += 4; return Boolean.TRUE;  }
            if (src.startsWith("false", pos)) { pos += 5; return Boolean.FALSE; }
            throw fail("expected boolean");
        }

        Object readNull() {
            if (src.startsWith("null", pos)) { pos += 4; return null; }
            throw fail("expected null");
        }

        Object readNumber() {
            int start = pos;
            if (peek() == '-') pos++;
            while (pos < src.length() && Character.isDigit(src.charAt(pos))) pos++;
            boolean isFloat = false;
            if (pos < src.length() && src.charAt(pos) == '.') {
                isFloat = true;
                pos++;
                while (pos < src.length() && Character.isDigit(src.charAt(pos))) pos++;
            }
            if (pos < src.length() && (src.charAt(pos) == 'e' || src.charAt(pos) == 'E')) {
                isFloat = true;
                pos++;
                if (pos < src.length() && (src.charAt(pos) == '+' || src.charAt(pos) == '-')) pos++;
                while (pos < src.length() && Character.isDigit(src.charAt(pos))) pos++;
            }
            String text = src.substring(start, pos);
            if (isFloat) return Double.parseDouble(text);
            return Long.parseLong(text);
        }

        void expect(char want) {
            if (pos >= src.length() || src.charAt(pos) != want) {
                throw fail("expected '" + want + "'");
            }
            pos++;
        }

        char peek() {
            if (pos >= src.length()) throw fail("unexpected end of input");
            return src.charAt(pos);
        }

        IllegalArgumentException fail(String message) {
            return new IllegalArgumentException(
                "WorkbenchJson parse error at offset " + pos + ": " + message);
        }
    }
}
