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
import java.util.Locale;

/**
 * JCAMP-DX 5.01 writer for 1-D Raman and IR spectra. Emits AFFN
 * {@code ##XYDATA=(X++(Y..Y))} with one {@code (X, Y)} pair per line.
 * PAC / SQZ / DIF compression is not produced.
 *
 * <p><b>API status:</b> Stable (v0.11, M73).</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGOJcampDxWriter} &middot;
 * Python: {@code mpeg_o.exporters.jcamp_dx}</p>
 *
 * @since 0.11
 */
public final class JcampDxWriter {

    private JcampDxWriter() {}

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
        double[] xs = spectrum.wavenumberValues();
        double[] ys = spectrum.intensityValues();
        if (xs.length != ys.length) {
            throw new IllegalArgumentException(
                    "wavenumber/intensity length mismatch: "
                            + xs.length + " vs " + ys.length);
        }
        int n = xs.length;
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
    }

    public static void writeIRSpectrum(IRSpectrum spectrum,
                                       Path path,
                                       String title) throws IOException {
        double[] xs = spectrum.wavenumberValues();
        double[] ys = spectrum.intensityValues();
        if (xs.length != ys.length) {
            throw new IllegalArgumentException(
                    "wavenumber/intensity length mismatch: "
                            + xs.length + " vs " + ys.length);
        }
        int n = xs.length;
        String dataType = spectrum.mode() == IRMode.ABSORBANCE
                ? "INFRARED ABSORBANCE" : "INFRARED TRANSMITTANCE";
        String yUnits = spectrum.mode() == IRMode.ABSORBANCE
                ? "ABSORBANCE" : "TRANSMITTANCE";

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
    }

    public static void writeUVVisSpectrum(UVVisSpectrum spectrum,
                                          Path path,
                                          String title) throws IOException {
        double[] xs = spectrum.wavelengthValues();
        double[] ys = spectrum.absorbanceValues();
        if (xs.length != ys.length) {
            throw new IllegalArgumentException(
                    "wavelength/absorbance length mismatch: "
                            + xs.length + " vs " + ys.length);
        }
        int n = xs.length;
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
    }
}
