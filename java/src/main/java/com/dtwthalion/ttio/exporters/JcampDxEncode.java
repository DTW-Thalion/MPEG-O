/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.ttio.exporters;

import java.util.Locale;

/**
 * JCAMP-DX 5.01 compressed-XYDATA encoder (PAC / SQZ / DIF).
 *
 * <p>Byte-for-byte mirror of Python
 * {@code ttio.exporters._jcamp_encode} and Objective-C
 * {@code TTIOJcampDxWriter+Compress}. The conformance fixtures under
 * {@code conformance/jcamp_dx/} are the gate — if this encoder and the
 * Python/ObjC encoders diverge, one of them is wrong.</p>
 *
 * <p>Package-private implementation detail of {@link JcampDxWriter};
 * no public API surface.</p>
 */
final class JcampDxEncode {

    private JcampDxEncode() {}

    static final int VALUES_PER_LINE = 10;

    private static final String SQZ_POS = "@ABCDEFGHI"; // 0..9 positive
    private static final String SQZ_NEG = "@abcdefghi"; // 0..9 negative (0 reuses '@')
    private static final String DIF_POS = "%JKLMNOPQR"; // 0..9 positive
    private static final String DIF_NEG = "%jklmnopqr"; // 0..9 negative (0 reuses '%')

    /**
     * Pick a YFACTOR that scales {@code ys} to ~{@code sigDigits}-digit integers.
     * Returns {@code 10 ** (ceil(log10(max_abs)) - sigDigits)}, or 1.0
     * for an empty / all-zero input. Must match Python
     * {@code choose_yfactor} exactly.
     */
    static double chooseYFactor(double[] ys, int sigDigits) {
        if (ys.length == 0) {
            return 1.0;
        }
        double maxAbs = 0.0;
        for (double y : ys) {
            double a = Math.abs(y);
            if (a > maxAbs) {
                maxAbs = a;
            }
        }
        if (maxAbs == 0.0) {
            return 1.0;
        }
        double exp = Math.ceil(Math.log10(maxAbs));
        return Math.pow(10.0, exp - sigDigits);
    }

    static double chooseYFactor(double[] ys) {
        return chooseYFactor(ys, 7);
    }

    /**
     * Half-away-from-zero rounding — portable across Python, Java, C.
     * Python's {@code round} is half-to-even; Java {@code Math.round}
     * matches here only for non-negative values, so the explicit form
     * is used to guarantee byte-parity.
     */
    static long roundInt(double value) {
        return (long) (value + (value >= 0.0 ? 0.5 : -0.5));
    }

    static String encodeSqz(long value) {
        if (value == 0L) {
            return "@";
        }
        boolean negative = value < 0L;
        String digits = Long.toString(Math.abs(value));
        int lead = digits.charAt(0) - '0';
        String tail = digits.substring(1);
        char head = (negative ? SQZ_NEG : SQZ_POS).charAt(lead);
        return head + tail;
    }

    static String encodeDif(long delta) {
        if (delta == 0L) {
            return "%";
        }
        boolean negative = delta < 0L;
        String digits = Long.toString(Math.abs(delta));
        int lead = digits.charAt(0) - '0';
        String tail = digits.substring(1);
        char head = (negative ? DIF_NEG : DIF_POS).charAt(lead);
        return head + tail;
    }

    static String encodePacY(long value) {
        // Matches Python f"{value:+d}": explicit + for non-negatives,
        // - otherwise. Java's "%+d" format flag does the same.
        return String.format(Locale.ROOT, "%+d", value);
    }

    /**
     * Python {@code f"{x:.10g}"}-equivalent formatter.
     *
     * <p>Java's {@code %.10g} pads with trailing zeros; Python strips
     * them along with a trailing decimal point. This helper wraps
     * Java's formatter and performs the same post-processing so both
     * languages emit the same bytes for every finite double.</p>
     */
    static String formatG10(double x) {
        if (Double.isNaN(x)) {
            return "nan";
        }
        if (Double.isInfinite(x)) {
            return x > 0 ? "inf" : "-inf";
        }
        String raw = String.format(Locale.ROOT, "%.10g", x);
        int eIdx = raw.indexOf('e');
        if (eIdx < 0) {
            eIdx = raw.indexOf('E');
        }
        if (eIdx >= 0) {
            String mantissa = raw.substring(0, eIdx);
            String exponent = raw.substring(eIdx); // includes the 'e'
            return stripTrailingZeros(mantissa) + exponent;
        }
        return stripTrailingZeros(raw);
    }

    /** Anchor X token — {@code f"{x:.10g}"} in Python. */
    static String formatAnchor(double x) {
        return formatG10(x);
    }

    private static String stripTrailingZeros(String s) {
        if (s.indexOf('.') < 0) {
            return s;
        }
        int end = s.length();
        while (end > 0 && s.charAt(end - 1) == '0') {
            end--;
        }
        if (end > 0 && s.charAt(end - 1) == '.') {
            end--;
        }
        return s.substring(0, end);
    }

    /**
     * Return the body of an {@code ##XYDATA=(X++(Y..Y))} block for a
     * PAC / SQZ / DIF encoding. AFFN is NOT routed through here.
     *
     * <p>Output is newline-separated with a trailing newline, so the
     * caller can concatenate {@code "##END=\n"} without bookkeeping.</p>
     */
    static String encodeXYData(double[] ys,
                               double firstx,
                               double deltax,
                               double yfactor,
                               JcampDxEncoding mode) {
        if (mode == JcampDxEncoding.AFFN) {
            throw new IllegalArgumentException(
                    "AFFN is not routed through the compressed encoder");
        }
        int n = ys.length;
        if (n == 0) {
            return "";
        }

        long[] yInt = new long[n];
        for (int i = 0; i < n; i++) {
            yInt[i] = roundInt(ys[i] / yfactor);
        }

        StringBuilder out = new StringBuilder(32 + n * 8);
        int i = 0;
        boolean havePrev = false;
        long prevLast = 0L;
        while (i < n) {
            int j = Math.min(i + VALUES_PER_LINE, n);
            String anchor = formatAnchor(firstx + i * deltax);

            if (mode == JcampDxEncoding.PAC) {
                out.append(anchor).append(' ');
                if (havePrev) {
                    // Explicit Y-check — the decoder drops line-start
                    // values matching prev_last_y unconditionally, so
                    // a plateau (repeated boundary value) would
                    // silently steal data without this sentinel.
                    out.append(encodePacY(prevLast));
                }
                for (int k = i; k < j; k++) {
                    out.append(encodePacY(yInt[k]));
                }
                out.append('\n');
                prevLast = yInt[j - 1];
                havePrev = true;
                i = j;
                continue;
            }

            if (mode == JcampDxEncoding.SQZ) {
                out.append(anchor);
                if (havePrev) {
                    out.append(' ').append(encodeSqz(prevLast)); // Y-check
                }
                for (int k = i; k < j; k++) {
                    out.append(' ').append(encodeSqz(yInt[k]));
                }
                out.append('\n');
                prevLast = yInt[j - 1];
                havePrev = true;
                i = j;
                continue;
            }

            // DIF — each line starts with an SQZ absolute (y[0] for
            // line 0, prev_last elsewhere); DIF tokens in the body
            // encode deltas from the running value.
            out.append(anchor);
            long running;
            int start;
            if (!havePrev) {
                out.append(' ').append(encodeSqz(yInt[i]));
                running = yInt[i];
                start = i + 1;
            } else {
                out.append(' ').append(encodeSqz(prevLast));
                running = prevLast;
                start = i;
            }
            for (int k = start; k < j; k++) {
                long delta = yInt[k] - running;
                out.append(' ').append(encodeDif(delta));
                running = yInt[k];
            }
            out.append('\n');
            prevLast = yInt[j - 1];
            havePrev = true;
            i = j;
        }

        return out.toString();
    }
}
