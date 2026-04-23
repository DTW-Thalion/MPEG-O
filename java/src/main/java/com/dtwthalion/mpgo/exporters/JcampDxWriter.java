/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.exporters;

import com.dtwthalion.mpgo.Enums.IRMode;
import com.dtwthalion.mpgo.IRSpectrum;
import com.dtwthalion.mpgo.RamanSpectrum;
import com.dtwthalion.mpgo.UVVisSpectrum;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * JCAMP-DX 5.01 writer for 1-D Raman, IR, and UV-Vis spectra.
 *
 * <p>Two XYDATA encoding families are supported:</p>
 * <ul>
 *   <li>{@link JcampDxEncoding#AFFN} — one {@code (X, Y)} pair per
 *       line, free-format doubles via {@link Double#toString(double)}.
 *       Default, and the only mode available prior to v0.12 (M73).</li>
 *   <li>{@link JcampDxEncoding#PAC}, {@link JcampDxEncoding#SQZ},
 *       {@link JcampDxEncoding#DIF} — JCAMP-DX 5.01 §5.9 compressed
 *       forms; require equispaced X (verified to 1e-9 rel tol) and
 *       emit a chosen YFACTOR carrying ~7 sig-digit integer precision.
 *       Byte-for-byte identical to the Python and Objective-C writers
 *       (M76), gated by the fixtures under
 *       {@code conformance/jcamp_dx/}.</li>
 * </ul>
 *
 * <p><b>API status:</b> Stable (v0.11 M73 for AFFN, v0.12 M76 for
 * PAC/SQZ/DIF).</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGOJcampDxWriter} &middot;
 * Python: {@code mpeg_o.exporters.jcamp_dx}</p>
 *
 * @since 0.11
 */
public final class JcampDxWriter {

    private JcampDxWriter() {}

    // ── AFFN (existing, v0.11 M73) ─────────────────────────────────

    private static void appendXYDATA(StringBuilder out, double[] xs, double[] ys) {
        // Per-value String.format was ~75% of this writer's runtime on
        // n=10K. Double.toString is native and guarantees shortest
        // round-trip — strictly more precision than the old "%.10g".
        out.append("##XYDATA=(X++(Y..Y))\n");
        for (int i = 0; i < xs.length; i++) {
            out.append(Double.toString(xs[i]))
               .append(' ')
               .append(Double.toString(ys[i]))
               .append('\n');
        }
    }

    private static void appendScalar(StringBuilder out, String ldr, double value) {
        out.append(ldr).append(Double.toString(value)).append('\n');
    }

    public static void writeRamanSpectrum(RamanSpectrum spectrum,
                                          Path path,
                                          String title) throws IOException {
        writeRamanSpectrum(spectrum, path, title, JcampDxEncoding.AFFN);
    }

    public static void writeIRSpectrum(IRSpectrum spectrum,
                                       Path path,
                                       String title) throws IOException {
        writeIRSpectrum(spectrum, path, title, JcampDxEncoding.AFFN);
    }

    public static void writeUVVisSpectrum(UVVisSpectrum spectrum,
                                          Path path,
                                          String title) throws IOException {
        writeUVVisSpectrum(spectrum, path, title, JcampDxEncoding.AFFN);
    }

    // ── AFFN + compressed dispatch (v0.12 M76) ────────────────────

    public static void writeRamanSpectrum(RamanSpectrum spectrum,
                                          Path path,
                                          String title,
                                          JcampDxEncoding encoding) throws IOException {
        double[] xs = spectrum.wavenumberValues();
        double[] ys = spectrum.intensityValues();
        checkLengths(xs, ys, "wavenumber", "intensity");
        int n = xs.length;

        if (encoding == JcampDxEncoding.AFFN) {
            StringBuilder sb = new StringBuilder(256 + n * 32);
            sb.append("##TITLE=").append(title != null ? title : "").append('\n')
              .append("##JCAMP-DX=5.01\n")
              .append("##DATA TYPE=RAMAN SPECTRUM\n")
              .append("##ORIGIN=MPEG-O\n")
              .append("##OWNER=\n")
              .append("##XUNITS=1/CM\n")
              .append("##YUNITS=ARBITRARY UNITS\n");
            appendScalar(sb, "##FIRSTX=", n > 0 ? xs[0] : 0.0);
            appendScalar(sb, "##LASTX=",  n > 0 ? xs[n - 1] : 0.0);
            sb.append("##NPOINTS=").append(n).append('\n')
              .append("##XFACTOR=1\n")
              .append("##YFACTOR=1\n");
            appendScalar(sb, "##$EXCITATION WAVELENGTH NM=", spectrum.excitationWavelengthNm());
            appendScalar(sb, "##$LASER POWER MW=",           spectrum.laserPowerMw());
            appendScalar(sb, "##$INTEGRATION TIME SEC=",     spectrum.integrationTimeSec());
            appendXYDATA(sb, xs, ys);
            sb.append("##END=\n");
            Files.writeString(path, sb.toString(), StandardCharsets.UTF_8);
            return;
        }

        String body = buildCompressedSpectrum(
                xs, ys, encoding,
                title, "RAMAN SPECTRUM", "1/CM", "ARBITRARY UNITS",
                new String[] {
                        "##$EXCITATION WAVELENGTH NM=" + JcampDxEncode.formatG10(spectrum.excitationWavelengthNm()),
                        "##$LASER POWER MW=" + JcampDxEncode.formatG10(spectrum.laserPowerMw()),
                        "##$INTEGRATION TIME SEC=" + JcampDxEncode.formatG10(spectrum.integrationTimeSec()),
                });
        Files.writeString(path, body, StandardCharsets.UTF_8);
    }

    public static void writeIRSpectrum(IRSpectrum spectrum,
                                       Path path,
                                       String title,
                                       JcampDxEncoding encoding) throws IOException {
        double[] xs = spectrum.wavenumberValues();
        double[] ys = spectrum.intensityValues();
        checkLengths(xs, ys, "wavenumber", "intensity");
        int n = xs.length;
        String dataType = spectrum.mode() == IRMode.ABSORBANCE
                ? "INFRARED ABSORBANCE" : "INFRARED TRANSMITTANCE";
        String yUnits = spectrum.mode() == IRMode.ABSORBANCE
                ? "ABSORBANCE" : "TRANSMITTANCE";

        if (encoding == JcampDxEncoding.AFFN) {
            StringBuilder sb = new StringBuilder(256 + n * 32);
            sb.append("##TITLE=").append(title != null ? title : "").append('\n')
              .append("##JCAMP-DX=5.01\n")
              .append("##DATA TYPE=").append(dataType).append('\n')
              .append("##ORIGIN=MPEG-O\n")
              .append("##OWNER=\n")
              .append("##XUNITS=1/CM\n")
              .append("##YUNITS=").append(yUnits).append('\n');
            appendScalar(sb, "##FIRSTX=", n > 0 ? xs[0] : 0.0);
            appendScalar(sb, "##LASTX=",  n > 0 ? xs[n - 1] : 0.0);
            sb.append("##NPOINTS=").append(n).append('\n')
              .append("##XFACTOR=1\n")
              .append("##YFACTOR=1\n");
            appendScalar(sb, "##RESOLUTION=", spectrum.resolutionCmInv());
            sb.append("##$NUMBER OF SCANS=").append(spectrum.numberOfScans()).append('\n');
            appendXYDATA(sb, xs, ys);
            sb.append("##END=\n");
            Files.writeString(path, sb.toString(), StandardCharsets.UTF_8);
            return;
        }

        String body = buildCompressedSpectrum(
                xs, ys, encoding,
                title, dataType, "1/CM", yUnits,
                new String[] {
                        "##RESOLUTION=" + JcampDxEncode.formatG10(spectrum.resolutionCmInv()),
                        "##$NUMBER OF SCANS=" + spectrum.numberOfScans(),
                });
        Files.writeString(path, body, StandardCharsets.UTF_8);
    }

    public static void writeUVVisSpectrum(UVVisSpectrum spectrum,
                                          Path path,
                                          String title,
                                          JcampDxEncoding encoding) throws IOException {
        double[] xs = spectrum.wavelengthValues();
        double[] ys = spectrum.absorbanceValues();
        checkLengths(xs, ys, "wavelength", "absorbance");
        int n = xs.length;

        if (encoding == JcampDxEncoding.AFFN) {
            StringBuilder sb = new StringBuilder(256 + n * 32);
            sb.append("##TITLE=").append(title != null ? title : "").append('\n')
              .append("##JCAMP-DX=5.01\n")
              .append("##DATA TYPE=UV/VIS SPECTRUM\n")
              .append("##ORIGIN=MPEG-O\n")
              .append("##OWNER=\n")
              .append("##XUNITS=NANOMETERS\n")
              .append("##YUNITS=ABSORBANCE\n");
            appendScalar(sb, "##FIRSTX=", n > 0 ? xs[0] : 0.0);
            appendScalar(sb, "##LASTX=",  n > 0 ? xs[n - 1] : 0.0);
            sb.append("##NPOINTS=").append(n).append('\n')
              .append("##XFACTOR=1\n")
              .append("##YFACTOR=1\n");
            appendScalar(sb, "##$PATH LENGTH CM=", spectrum.pathLengthCm());
            sb.append("##$SOLVENT=").append(spectrum.solvent()).append('\n');
            appendXYDATA(sb, xs, ys);
            sb.append("##END=\n");
            Files.writeString(path, sb.toString(), StandardCharsets.UTF_8);
            return;
        }

        String body = buildCompressedSpectrum(
                xs, ys, encoding,
                title, "UV/VIS SPECTRUM", "NANOMETERS", "ABSORBANCE",
                new String[] {
                        "##$PATH LENGTH CM=" + JcampDxEncode.formatG10(spectrum.pathLengthCm()),
                        "##$SOLVENT=" + spectrum.solvent(),
                });
        Files.writeString(path, body, StandardCharsets.UTF_8);
    }

    // ── Compressed shared path ────────────────────────────────────

    private static void checkLengths(double[] xs, double[] ys, String xName, String yName) {
        if (xs.length != ys.length) {
            throw new IllegalArgumentException(
                    xName + "/" + yName + " length mismatch: "
                            + xs.length + " vs " + ys.length);
        }
    }

    /**
     * Build the full file contents for a compressed spectrum. The
     * header LDRs and the XYDATA body are both formatted with the
     * Python-{@code %.10g}-equivalent helper so the output is
     * byte-identical to the reference Python writer.
     */
    private static String buildCompressedSpectrum(double[] xs,
                                                  double[] ys,
                                                  JcampDxEncoding encoding,
                                                  String title,
                                                  String dataType,
                                                  String xUnits,
                                                  String yUnits,
                                                  String[] tailLdrs) {
        int n = xs.length;
        if (n < 2) {
            throw new IllegalArgumentException(
                    "JCAMP-DX compressed encoding requires NPOINTS >= 2");
        }
        double firstx = xs[0];
        double deltax = (xs[n - 1] - xs[0]) / (n - 1);
        // Verify equispaced X within 1e-9 relative tolerance.
        double maxAbs = 0.0;
        for (int i = 0; i < n; i++) {
            double expected = firstx + i * deltax;
            double a = Math.abs(expected);
            if (a > maxAbs) maxAbs = a;
        }
        double tol = Math.max(1e-9 * maxAbs, 1e-9);
        for (int i = 0; i < n; i++) {
            double expected = firstx + i * deltax;
            if (Math.abs(xs[i] - expected) > tol) {
                throw new IllegalArgumentException(
                        "JCAMP-DX compressed encoding requires equispaced X");
            }
        }

        double yfactor = JcampDxEncode.chooseYFactor(ys);
        String body = JcampDxEncode.encodeXYData(ys, firstx, deltax, yfactor, encoding);

        StringBuilder sb = new StringBuilder(256 + body.length());
        sb.append("##TITLE=").append(title != null ? title : "").append('\n')
          .append("##JCAMP-DX=5.01\n")
          .append("##DATA TYPE=").append(dataType).append('\n')
          .append("##ORIGIN=MPEG-O\n")
          .append("##OWNER=\n")
          .append("##XUNITS=").append(xUnits).append('\n')
          .append("##YUNITS=").append(yUnits).append('\n')
          .append("##FIRSTX=").append(JcampDxEncode.formatG10(xs[0])).append('\n')
          .append("##LASTX=").append(JcampDxEncode.formatG10(xs[n - 1])).append('\n')
          .append("##NPOINTS=").append(n).append('\n')
          .append("##XFACTOR=1\n")
          .append("##YFACTOR=").append(JcampDxEncode.formatG10(yfactor)).append('\n');
        for (String ldr : tailLdrs) {
            sb.append(ldr).append('\n');
        }
        sb.append("##XYDATA=(X++(Y..Y))\n").append(body).append("##END=\n");
        return sb.toString();
    }
}
