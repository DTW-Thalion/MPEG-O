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
        out.append("##XYDATA=(X++(Y..Y))\n");
        for (int i = 0; i < xs.length; i++) {
            out.append(String.format(Locale.ROOT, "%.10g %.10g%n", xs[i], ys[i]));
        }
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
          .append("##YUNITS=ARBITRARY UNITS\n")
          .append(String.format(Locale.ROOT, "##FIRSTX=%.10g%n", n > 0 ? xs[0] : 0.0))
          .append(String.format(Locale.ROOT, "##LASTX=%.10g%n", n > 0 ? xs[n - 1] : 0.0))
          .append("##NPOINTS=").append(n).append('\n')
          .append("##XFACTOR=1\n")
          .append("##YFACTOR=1\n")
          .append(String.format(Locale.ROOT, "##$EXCITATION WAVELENGTH NM=%.10g%n",
                  spectrum.excitationWavelengthNm()))
          .append(String.format(Locale.ROOT, "##$LASER POWER MW=%.10g%n",
                  spectrum.laserPowerMw()))
          .append(String.format(Locale.ROOT, "##$INTEGRATION TIME SEC=%.10g%n",
                  spectrum.integrationTimeSec()));
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
          .append("##YUNITS=").append(yUnits).append('\n')
          .append(String.format(Locale.ROOT, "##FIRSTX=%.10g%n", n > 0 ? xs[0] : 0.0))
          .append(String.format(Locale.ROOT, "##LASTX=%.10g%n", n > 0 ? xs[n - 1] : 0.0))
          .append("##NPOINTS=").append(n).append('\n')
          .append("##XFACTOR=1\n")
          .append("##YFACTOR=1\n")
          .append(String.format(Locale.ROOT, "##RESOLUTION=%.10g%n",
                  spectrum.resolutionCmInv()))
          .append("##$NUMBER OF SCANS=").append(spectrum.numberOfScans()).append('\n');
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
          .append("##YUNITS=ABSORBANCE\n")
          .append(String.format(Locale.ROOT, "##FIRSTX=%.10g%n", n > 0 ? xs[0] : 0.0))
          .append(String.format(Locale.ROOT, "##LASTX=%.10g%n", n > 0 ? xs[n - 1] : 0.0))
          .append("##NPOINTS=").append(n).append('\n')
          .append("##XFACTOR=1\n")
          .append("##YFACTOR=1\n")
          .append(String.format(Locale.ROOT, "##$PATH LENGTH CM=%.10g%n",
                  spectrum.pathLengthCm()))
          .append("##$SOLVENT=").append(spectrum.solvent()).append('\n');
        appendXYDATA(sb, xs, ys);
        sb.append("##END=\n");
        Files.writeString(path, sb.toString(), StandardCharsets.UTF_8);
    }
}
