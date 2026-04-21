/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.Enums.IRMode;
import com.dtwthalion.mpgo.IRSpectrum;
import com.dtwthalion.mpgo.RamanSpectrum;
import com.dtwthalion.mpgo.Spectrum;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * JCAMP-DX 5.01 reader for 1-D vibrational spectra. Dispatches on
 * {@code ##DATA TYPE=} and returns a {@link RamanSpectrum} or
 * {@link IRSpectrum}.
 *
 * <p>Accepts the AFFN {@code ##XYDATA=(X++(Y..Y))} dialect emitted by
 * {@code JcampDxWriter} and the more permissive "one (X, Y) pair per
 * line" variant. PAC / SQZ / DIF compression is not supported in M73.</p>
 *
 * <p><b>API status:</b> Stable (v0.11, M73).</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGOJcampDxReader} &middot;
 * Python: {@code mpeg_o.importers.jcamp_dx}</p>
 *
 * @since 0.11
 */
public final class JcampDxReader {

    private JcampDxReader() {}

    /**
     * Parse {@code path} and return an appropriate spectrum subclass.
     *
     * @throws IOException if reading fails
     * @throws IllegalArgumentException on malformed content or
     *     unsupported {@code ##DATA TYPE=}
     */
    public static Spectrum readSpectrum(Path path) throws IOException {
        String text = Files.readString(path, StandardCharsets.UTF_8);
        Map<String, String> ldrs = new HashMap<>();
        List<Double> xs = new ArrayList<>();
        List<Double> ys = new ArrayList<>();
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

            if (inXYDATA) {
                String[] toks = line.split("\\s+");
                List<Double> nums = new ArrayList<>(toks.length);
                for (String t : toks) {
                    if (t.isEmpty()) continue;
                    try {
                        nums.add(Double.parseDouble(t));
                    } catch (NumberFormatException ignored) {
                        // skip non-numeric tokens
                    }
                }
                if (nums.size() >= 2) {
                    xs.add(nums.get(0));
                    ys.add(nums.get(1));
                } else if (nums.size() == 1 && xs.size() == ys.size() + 1) {
                    ys.add(nums.get(0));
                }
            }
        }

        if (xs.size() != ys.size() || xs.isEmpty()) {
            throw new IllegalArgumentException("JCAMP-DX: empty or mismatched XYDATA");
        }

        String dataType = ldrs.getOrDefault("DATA TYPE", "").toUpperCase();
        double[] x = toArray(xs);
        double[] y = toArray(ys);

        if (dataType.equals("RAMAN SPECTRUM")) {
            return new RamanSpectrum(
                    x, y, 0, 0.0,
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
                String yUnits = ldrs.getOrDefault("YUNITS", "").toUpperCase();
                mode = yUnits.contains("ABSORB") ? IRMode.ABSORBANCE : IRMode.TRANSMITTANCE;
            }
            return new IRSpectrum(
                    x, y, 0, 0.0,
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

    private static double[] toArray(List<Double> list) {
        double[] out = new double[list.size()];
        for (int i = 0; i < list.size(); i++) out[i] = list.get(i);
        return out;
    }
}
