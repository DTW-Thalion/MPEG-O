/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;

/**
 * v0.7 M51 — deterministic JSON formatter for cross-language compound
 * byte-parity. Output is byte-identical to
 * ``ttio.tools._canonical_json`` in Python and
 * {@code TTIOCanonicalJSON} in Objective-C.
 *
 * <p>Format rules:</p>
 * <ul>
 *   <li>Top-level object, alphabetically sorted keys.</li>
 *   <li>Each array element on its own line (LF).</li>
 *   <li>Within a record: tight JSON (no spaces), keys sorted.</li>
 *   <li>Floats: C99 {@code %.17g} semantics (Java's {@code %g} output
 *       post-processed to strip trailing zeros and optional decimal
 *       point, matching C / Python output).</li>
 *   <li>Integers: base-10 decimal.</li>
 *   <li>Strings: JSON-escaped, UTF-8 preserved (raw non-ASCII, no
 *       backslash-u escapes except for C0 control chars).</li>
 * </ul>
 *
 *
 */
public final class CanonicalJson {

    private CanonicalJson() {}

    public static String escapeString(String s) {
        StringBuilder out = new StringBuilder(s.length() + 2);
        out.append('"');
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            switch (ch) {
                case '"'  -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (ch < 0x20) {
                        out.append(String.format(Locale.ROOT, "\\u%04x", (int) ch));
                    } else {
                        out.append(ch);
                    }
                }
            }
        }
        out.append('"');
        return out.toString();
    }

    /** Mirror C99 {@code %.17g}: 17-significant-digit {@code %g} output
     *  of the IEEE-754 exact value, with trailing zeros and the
     *  optional decimal point stripped from the mantissa.
     *
     *  <p>Java's {@code String.format("%.17g", x)} does <b>not</b>
     *  match C99: it renders the short round-trip decimal then pads with
     *  trailing zeros to reach 17 digits — so {@code 0.85} emits
     *  {@code "0.85000000000000000"} where C99 would give
     *  {@code "0.84999999999999998"} (the true 17-sig-digit decimal).
     *  We reproduce C99 semantics by routing through
     *  {@link java.math.BigDecimal#BigDecimal(double)} (exact value)
     *  with {@link java.math.MathContext} precision 17.</p> */
    public static String formatFloat(double x) {
        if (Double.isNaN(x)) return "nan";
        if (Double.isInfinite(x)) return x < 0 ? "-inf" : "inf";
        if (x == 0.0) {
            return 1.0 / x < 0 ? "-0" : "0";
        }
        java.math.BigDecimal bd = new java.math.BigDecimal(x,
                new java.math.MathContext(17));
        // Split into mantissa digits + decimal exponent.
        String plain = bd.abs().stripTrailingZeros().toPlainString();
        // Recompute exponent from the rounded value directly to avoid
        // locale / scaling noise.
        int exp;
        String digits;
        {
            String s = bd.abs().round(new java.math.MathContext(17))
                    .toString();
            int eIdx = s.indexOf('E');
            String beforeE = eIdx >= 0 ? s.substring(0, eIdx) : s;
            int xExp;
            int dotIdx = beforeE.indexOf('.');
            String rawDigits;
            if (dotIdx < 0) {
                rawDigits = beforeE;
                xExp = beforeE.length() - 1;
            } else {
                rawDigits = beforeE.substring(0, dotIdx)
                           + beforeE.substring(dotIdx + 1);
                xExp = dotIdx - 1;
            }
            // Strip leading zeros from the rawDigits (can appear when
            // BigDecimal normalises 0.0085 → "0.0085" with leading 0s
            // after the dot — adjust xExp to compensate).
            int leadZeros = 0;
            while (leadZeros < rawDigits.length() - 1
                    && rawDigits.charAt(leadZeros) == '0') {
                leadZeros++;
            }
            rawDigits = rawDigits.substring(leadZeros);
            xExp -= leadZeros;
            if (eIdx >= 0) {
                xExp += Integer.parseInt(s.substring(eIdx + 1));
            }
            // Strip trailing zeros (C99 %g strips them).
            int cut = rawDigits.length();
            while (cut > 1 && rawDigits.charAt(cut - 1) == '0') cut--;
            digits = rawDigits.substring(0, cut);
            exp = xExp;
        }
        boolean negative = bd.signum() < 0;
        final int p = 17;
        StringBuilder sb = new StringBuilder();
        if (negative) sb.append('-');
        if (p > exp && exp >= -4) {
            // Fixed notation.
            if (exp >= 0) {
                int intLen = exp + 1;
                if (digits.length() <= intLen) {
                    sb.append(digits);
                    for (int i = digits.length(); i < intLen; i++) {
                        sb.append('0');
                    }
                } else {
                    sb.append(digits, 0, intLen)
                      .append('.')
                      .append(digits, intLen, digits.length());
                }
            } else {
                sb.append("0.");
                for (int i = 0; i < -exp - 1; i++) sb.append('0');
                sb.append(digits);
            }
        } else {
            // Scientific: mantissa with single integer digit + exponent.
            sb.append(digits.charAt(0));
            if (digits.length() > 1) {
                sb.append('.').append(digits, 1, digits.length());
            }
            sb.append('e');
            sb.append(exp >= 0 ? '+' : '-');
            int absExp = Math.abs(exp);
            if (absExp < 10) sb.append('0');
            sb.append(absExp);
        }
        // (Fixed path already stripped trailing zeros via `digits`; the
        // scientific path mantissa may have a trailing '.' if digits
        // had length 1 which is impossible here because the first
        // character is always non-zero by construction.)
        return sb.toString();
    }

    public static String formatInt(long x) {
        return Long.toString(x);
    }

    @SuppressWarnings("unchecked")
    public static String formatValue(Object v) {
        if (v == null) return "null";
        if (v instanceof Boolean b) return b ? "true" : "false";
        if (v instanceof Long l) return formatInt(l);
        if (v instanceof Integer i) return formatInt(i.longValue());
        if (v instanceof Short s) return formatInt(s.longValue());
        if (v instanceof Byte b) return formatInt(b.longValue());
        if (v instanceof Double d) return formatFloat(d);
        if (v instanceof Float f) return formatFloat(f.doubleValue());
        if (v instanceof String s) return escapeString(s);
        if (v instanceof List<?> list) {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) sb.append(',');
                sb.append(formatValue(list.get(i)));
            }
            return sb.append(']').toString();
        }
        if (v instanceof Map<?, ?> map) {
            TreeMap<String, Object> sorted = new TreeMap<>();
            for (var e : map.entrySet()) {
                sorted.put(e.getKey().toString(), e.getValue());
            }
            StringBuilder sb = new StringBuilder("{");
            boolean first = true;
            for (var e : sorted.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                sb.append(escapeString(e.getKey()))
                  .append(':')
                  .append(formatValue(e.getValue()));
            }
            return sb.append('}').toString();
        }
        throw new IllegalArgumentException(
                "unsupported canonical JSON value: " + v.getClass().getName());
    }

    public static String formatRecord(Map<String, Object> record) {
        return formatValue(record);
    }

    /** Top-level M51 dump: outer object keyed by section name, each
     *  value an array of records; one record per line. */
    public static String formatTopLevel(Map<String, List<Map<String, Object>>> sections) {
        TreeMap<String, List<Map<String, Object>>> sorted = new TreeMap<>(sections);
        StringBuilder out = new StringBuilder("{");
        boolean firstSection = true;
        for (var e : sorted.entrySet()) {
            if (!firstSection) out.append(',');
            firstSection = false;
            out.append('\n').append(escapeString(e.getKey())).append(": [");
            List<Map<String, Object>> records = e.getValue();
            for (int i = 0; i < records.size(); i++) {
                out.append('\n').append(formatRecord(records.get(i)));
                if (i < records.size() - 1) out.append(',');
            }
            if (!records.isEmpty()) out.append('\n');
            out.append(']');
        }
        out.append("\n}\n");
        return out.toString();
    }
}
