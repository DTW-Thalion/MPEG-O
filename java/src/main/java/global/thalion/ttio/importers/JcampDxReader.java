/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package global.thalion.ttio.importers;

import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.UVVisSpectrum;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * JCAMP-DX 5.01 reader for 1-D vibrational and UV-Vis spectra.
 *
 * <p>Dispatches on {@code ##DATA TYPE=} and returns a
 * {@link RamanSpectrum}, {@link IRSpectrum}, or {@link UVVisSpectrum}.</p>
 *
 * <p>Accepts two dialects of {@code ##XYDATA=(X++(Y..Y))}:</p>
 * <ul>
 *   <li><b>AFFN</b> (fast path) — one {@code (X, Y)} pair per line,
 *       free-format decimals including scientific notation.</li>
 *   <li><b>PAC / SQZ / DIF / DUP</b> (compressed) — JCAMP-DX 5.01 §5.9
 *       character-encoded Y-stream. Delegated to
 *       {@link JcampDxDecode#decode}. Requires {@code FIRSTX},
 *       {@code LASTX}, and {@code NPOINTS} headers (equispaced X).</li>
 * </ul>
 *
 * <p><b>API status:</b> Stable (v0.11.1 adds compression + UV-Vis).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOJcampDxReader}, Python {@code ttio.importers.jcamp_dx}.</p>
 *
 * @since 0.11
 */
public final class JcampDxReader {

    private static final Set<String> UV_VIS_DATA_TYPES = new HashSet<>(Arrays.asList(
        "UV/VIS SPECTRUM", "UV-VIS SPECTRUM", "UV/VISIBLE SPECTRUM"
    ));

    private JcampDxReader() {}

    public static Spectrum readSpectrum(Path path) throws IOException {
        String text = Files.readString(path, StandardCharsets.UTF_8);
        Map<String, String> ldrs = new HashMap<>();
        List<String> bodyLines = new ArrayList<>();
        boolean inXYDATA = false;

        for (String raw : text.split("\\R")) {
            String line = raw.strip();
            if (line.isEmpty()) continue;

            if (line.startsWith("##")) {
                inXYDATA = false;
                int eq = line.indexOf('=');
                if (eq < 0) continue;
                String label = line.substring(2, eq).strip();
                String value = line.substring(eq + 1).strip();
                ldrs.put(label, value);
                if (label.equals("XYDATA")) {
                    inXYDATA = true;
                } else if (label.equals("END")) {
                    break;
                }
                continue;
            }
            if (inXYDATA) bodyLines.add(raw);
        }

        double xfactor = parseDouble(ldrs.getOrDefault("XFACTOR", "1"));
        if (xfactor == 0.0) xfactor = 1.0;
        double yfactor = parseDouble(ldrs.getOrDefault("YFACTOR", "1"));
        if (yfactor == 0.0) yfactor = 1.0;

        double[] xs;
        double[] ys;
        // hasCompression(List<String>) avoids the String.join allocation
        // that the original String-based overload required.
        if (JcampDxDecode.hasCompression(bodyLines)) {
            if (!ldrs.containsKey("FIRSTX") || !ldrs.containsKey("LASTX")
                    || !ldrs.containsKey("NPOINTS")) {
                throw new IllegalArgumentException(
                    "JCAMP-DX: compressed XYDATA requires FIRSTX / LASTX / NPOINTS");
            }
            double firstx = parseDouble(ldrs.get("FIRSTX"));
            double lastx = parseDouble(ldrs.get("LASTX"));
            int npoints = (int) parseDouble(ldrs.get("NPOINTS"));
            if (npoints < 2) {
                throw new IllegalArgumentException(
                    "JCAMP-DX: NPOINTS must be >= 2 for compressed data");
            }
            double deltax = (lastx - firstx) / (npoints - 1);
            JcampDxDecode.DecodedXY d = JcampDxDecode.decode(
                bodyLines, firstx, deltax, xfactor, yfactor);
            xs = d.xs;
            ys = d.ys;
        } else {
            // AFFN fast path: pre-allocate double[] from NPOINTS hint
            // (default 1024, grown geometrically). Avoids the
            // ArrayList<Double> autoboxing that dominated this path —
            // 20K Double allocations per spectrum at n=10K.
            int hint = 1024;
            String npointsLdr = ldrs.get("NPOINTS");
            if (npointsLdr != null && !npointsLdr.isEmpty()) {
                try {
                    int parsed = (int) Double.parseDouble(npointsLdr);
                    if (parsed > 0 && parsed < (1 << 30)) hint = parsed;
                } catch (NumberFormatException ignored) {
                    // fall through to default
                }
            }
            xs = new double[hint];
            ys = new double[hint];
            int count = 0;
            for (String raw : bodyLines) {
                int len = raw.length();
                int p = 0;
                // Manual whitespace tokenizer — avoids regex compile
                // and String[] allocation per line.
                while (p < len && isAffnSpace(raw.charAt(p))) p++;
                if (p >= len) continue;
                int t1s = p;
                while (p < len && !isAffnSpace(raw.charAt(p))) p++;
                int t1e = p;
                while (p < len && isAffnSpace(raw.charAt(p))) p++;
                if (p >= len) {
                    // Line carries a single number: continuation Y
                    // value when count of pending Xs runs ahead.
                    // Rare for writer output but tolerated by spec.
                    if (count > 0) {
                        // No-op: the single-value-line case is only
                        // legal when xList.size == yList.size + 1, but
                        // this fast path never produces that state.
                        // Fall through.
                    }
                    continue;
                }
                int t2s = p;
                while (p < len && !isAffnSpace(raw.charAt(p))) p++;
                int t2e = p;
                double x;
                double y;
                try {
                    x = Double.parseDouble(raw.substring(t1s, t1e));
                    y = Double.parseDouble(raw.substring(t2s, t2e));
                } catch (NumberFormatException ignored) {
                    continue;
                }
                if (count >= xs.length) {
                    int next = xs.length << 1;
                    xs = Arrays.copyOf(xs, next);
                    ys = Arrays.copyOf(ys, next);
                }
                xs[count] = x * xfactor;
                ys[count] = y * yfactor;
                count++;
            }
            if (count < xs.length) {
                xs = Arrays.copyOf(xs, count);
                ys = Arrays.copyOf(ys, count);
            }
        }

        if (xs.length != ys.length || xs.length == 0) {
            throw new IllegalArgumentException("JCAMP-DX: empty or mismatched XYDATA");
        }

        String dataType = ldrs.getOrDefault("DATA TYPE", "").toUpperCase(Locale.ROOT);

        if (UV_VIS_DATA_TYPES.contains(dataType)) {
            return new UVVisSpectrum(
                xs, ys, 0, 0.0,
                parseDouble(ldrs.get("$PATH LENGTH CM")),
                ldrs.getOrDefault("$SOLVENT", ""));
        }

        if (dataType.equals("RAMAN SPECTRUM")) {
            return new RamanSpectrum(
                xs, ys, 0, 0.0,
                parseDouble(ldrs.get("$EXCITATION WAVELENGTH NM")),
                parseDouble(ldrs.get("$LASER POWER MW")),
                parseDouble(ldrs.get("$INTEGRATION TIME SEC")));
        }

        if (dataType.equals("INFRARED ABSORBANCE")
                || dataType.equals("INFRARED TRANSMITTANCE")
                || dataType.equals("INFRARED SPECTRUM")) {
            IRMode mode;
            if (dataType.equals("INFRARED ABSORBANCE")) {
                mode = IRMode.ABSORBANCE;
            } else if (dataType.equals("INFRARED TRANSMITTANCE")) {
                mode = IRMode.TRANSMITTANCE;
            } else {
                String yUnits = ldrs.getOrDefault("YUNITS", "").toUpperCase(Locale.ROOT);
                mode = yUnits.contains("ABSORB") ? IRMode.ABSORBANCE : IRMode.TRANSMITTANCE;
            }
            return new IRSpectrum(
                xs, ys, 0, 0.0,
                mode,
                parseDouble(ldrs.get("RESOLUTION")),
                (long) parseDouble(ldrs.get("$NUMBER OF SCANS")));
        }

        throw new IllegalArgumentException(
            "JCAMP-DX: unsupported DATA TYPE='" + ldrs.getOrDefault("DATA TYPE", "") + "'");
    }

    private static double parseDouble(String v) {
        if (v == null || v.isEmpty()) return 0.0;
        try {
            return Double.parseDouble(v);
        } catch (NumberFormatException e) {
            return 0.0;
        }
    }

    /**
     * Whitespace classification matching the previous {@code \s+}
     * regex split: ASCII space, tab, vertical tab, form feed, and
     * embedded line terminators (already excluded by the line-split
     * upstream, but kept for safety).
     */
    private static boolean isAffnSpace(char c) {
        return c == ' ' || c == '\t' || c == '\u000B' || c == '\f'
            || c == '\r' || c == '\n';
    }
}
