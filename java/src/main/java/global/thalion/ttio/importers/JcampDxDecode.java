/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.importers;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * JCAMP-DX 5.01 compressed-XYDATA decoder (SQZ / DIF / DUP / PAC).
 *
 * <p>Implements §5.9 of JCAMP-DX 5.01. The AFFN dialect is handled
 * directly by {@link JcampDxReader}; this class is consulted only
 * when {@link #hasCompression} reports a compression sentinel.</p>
 *
 * <p>Y values are returned in order; X values are synthesised from
 * {@code firstx + i * deltax} per the equispaced-X invariant of
 * {@code ##XYDATA=(X++(Y..Y))}.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOJcampDxDecode}, Python
 * {@code ttio.importers._jcamp_decode}.</p>
 *
 * @since 0.11.1
 */
public final class JcampDxDecode {

    private static final Map<Character, int[]> SQZ = new HashMap<>();
    private static final Map<Character, int[]> DIF = new HashMap<>();
    private static final Map<Character, Integer> DUP = new HashMap<>();
    private static final java.util.Set<Character> COMPRESSION_CHARS = new java.util.HashSet<>();
    // ASCII-only fast-lookup table for hasCompression. All SQZ/DIF/DUP
    // sentinels fall in 0x20–0x7F. Replacing HashSet<Character>.contains
    // (which autoboxes every char) with a boolean[] turned a ~50ms
    // per-spectrum scan into a few hundred microseconds at n=10K.
    private static final boolean[] DETECT_TABLE = new boolean[128];

    static {
        SQZ.put('@', new int[]{0, +1});
        String sPos = "ABCDEFGHI";
        for (int i = 0; i < sPos.length(); i++) {
            SQZ.put(sPos.charAt(i), new int[]{i + 1, +1});
        }
        String sNeg = "abcdefghi";
        for (int i = 0; i < sNeg.length(); i++) {
            SQZ.put(sNeg.charAt(i), new int[]{i + 1, -1});
        }

        DIF.put('%', new int[]{0, +1});
        String dPos = "JKLMNOPQR";
        for (int i = 0; i < dPos.length(); i++) {
            DIF.put(dPos.charAt(i), new int[]{i + 1, +1});
        }
        String dNeg = "jklmnopqr";
        for (int i = 0; i < dNeg.length(); i++) {
            DIF.put(dNeg.charAt(i), new int[]{i + 1, -1});
        }

        String dup = "STUVWXYZ";
        for (int i = 0; i < dup.length(); i++) {
            DUP.put(dup.charAt(i), i + 2);
        }
        DUP.put('s', 9);

        COMPRESSION_CHARS.addAll(SQZ.keySet());
        COMPRESSION_CHARS.addAll(DIF.keySet());
        COMPRESSION_CHARS.addAll(DUP.keySet());
        for (Character c : COMPRESSION_CHARS) {
            char ch = c;
            if (ch < 128) DETECT_TABLE[ch] = true;
        }
        // 'E'/'e' overlap with scientific-notation exponent markers in
        // AFFN doubles, so they are excluded from compression detection.
        DETECT_TABLE['E'] = false;
        DETECT_TABLE['e'] = false;
    }

    private JcampDxDecode() {}

    /** Return {@code true} iff {@code body} carries any SQZ/DIF/DUP sentinel. */
    public static boolean hasCompression(String body) {
        for (int i = 0; i < body.length(); i++) {
            char c = body.charAt(i);
            if (c < 128 && DETECT_TABLE[c]) return true;
        }
        return false;
    }

    /**
     * List-of-lines variant: scans without re-joining the body. Used
     * by {@link JcampDxReader} which already has the body split into
     * lines, to avoid an O(body) {@code String.join} allocation.
     */
    public static boolean hasCompression(List<String> lines) {
        for (String line : lines) {
            for (int i = 0; i < line.length(); i++) {
                char c = line.charAt(i);
                if (c < 128 && DETECT_TABLE[c]) return true;
            }
        }
        return false;
    }

    /** Decoded XYDATA: two equal-length primitive arrays. */
    public static final class DecodedXY {
        public final double[] xs;
        public final double[] ys;

        DecodedXY(double[] xs, double[] ys) {
            this.xs = xs;
            this.ys = ys;
        }
    }

    /**
     * Decode a compressed {@code ##XYDATA=(X++(Y..Y))} body.
     *
     * @param lines raw text lines of the XYDATA block (no header, no
     *     terminal {@code ##END=})
     * @param firstx first X value from {@code ##FIRSTX=}
     * @param deltax {@code (LASTX - FIRSTX) / (NPOINTS - 1)}
     * @param xfactor {@code ##XFACTOR=} scale factor
     * @param yfactor {@code ##YFACTOR=} scale factor
     */
    public static DecodedXY decode(List<String> lines, double firstx, double deltax,
                                   double xfactor, double yfactor) {
        List<Double> ysRaw = new ArrayList<>();
        Double prevLastY = null;

        for (String raw : lines) {
            int comment = raw.indexOf("$$");
            String line = (comment >= 0 ? raw.substring(0, comment) : raw).strip();
            if (line.isEmpty()) continue;

            List<String> toks = tokenize(line);
            if (toks.size() < 2) continue;

            Double currentY = null;
            List<Double> lineYs = new ArrayList<>();

            // toks.get(0) is the X anchor; ignored in favour of firstx+deltax.
            for (int i = 1; i < toks.size(); i++) {
                String tok = toks.get(i);
                char head = tok.charAt(0);
                if (DIF.containsKey(head)) {
                    double base = currentY != null ? currentY
                                : (prevLastY != null ? prevLastY : Double.NaN);
                    if (Double.isNaN(base)) {
                        throw new IllegalArgumentException(
                            "JCAMP-DX: DIF token at start of data stream");
                    }
                    currentY = base + parseDif(tok);
                    lineYs.add(currentY);
                } else if (DUP.containsKey(head)) {
                    if (currentY == null) {
                        throw new IllegalArgumentException(
                            "JCAMP-DX: DUP token before any absolute Y");
                    }
                    int count = parseDupCount(tok) - 1;
                    for (int k = 0; k < count; k++) lineYs.add(currentY);
                } else {
                    currentY = parseSqzOrAffn(tok);
                    lineYs.add(currentY);
                }
            }

            // DIF Y-check: drop leading redundancy that matches last Y of prior line.
            if (prevLastY != null && !lineYs.isEmpty()
                    && Math.abs(lineYs.get(0) - prevLastY) < 1e-9) {
                lineYs.remove(0);
            }

            if (!lineYs.isEmpty()) {
                ysRaw.addAll(lineYs);
                prevLastY = lineYs.get(lineYs.size() - 1);
            }
        }

        int n = ysRaw.size();
        double[] xs = new double[n];
        double[] ys = new double[n];
        for (int i = 0; i < n; i++) {
            xs[i] = (firstx + i * deltax) * xfactor;
            ys[i] = ysRaw.get(i) * yfactor;
        }
        return new DecodedXY(xs, ys);
    }

    private static List<String> tokenize(String line) {
        List<String> tokens = new ArrayList<>();
        StringBuilder cur = new StringBuilder();

        for (int i = 0; i < line.length(); i++) {
            char ch = line.charAt(i);
            if (Character.isWhitespace(ch)) {
                if (cur.length() > 0) { tokens.add(cur.toString()); cur.setLength(0); }
                continue;
            }
            if (ch == '$') break;  // $$ inline comment
            if (COMPRESSION_CHARS.contains(ch) || ch == '+' || ch == '-') {
                if (cur.length() > 0) { tokens.add(cur.toString()); cur.setLength(0); }
                cur.append(ch);
                continue;
            }
            if (Character.isDigit(ch) || ch == '.' || ch == 'e' || ch == 'E') {
                cur.append(ch);
                continue;
            }
            if (cur.length() > 0) { tokens.add(cur.toString()); cur.setLength(0); }
        }
        if (cur.length() > 0) tokens.add(cur.toString());
        return tokens;
    }

    private static double parseSqzOrAffn(String tok) {
        char head = tok.charAt(0);
        int[] sq = SQZ.get(head);
        if (sq != null) {
            int digit = sq[0];
            int sign = sq[1];
            String rest = tok.substring(1);
            double magnitude = rest.isEmpty() ? digit : Double.parseDouble(digit + rest);
            return sign * magnitude;
        }
        return Double.parseDouble(tok);
    }

    private static double parseDif(String tok) {
        int[] d = DIF.get(tok.charAt(0));
        int digit = d[0];
        int sign = d[1];
        String rest = tok.substring(1);
        double magnitude = rest.isEmpty() ? digit : Double.parseDouble(digit + rest);
        return sign * magnitude;
    }

    private static int parseDupCount(String tok) {
        int base = DUP.get(tok.charAt(0));
        String rest = tok.substring(1);
        return rest.isEmpty() ? base : Integer.parseInt(base + rest);
    }
}
