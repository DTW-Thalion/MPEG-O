/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.exporters;

import com.dtwthalion.mpgo.AcquisitionRun;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;

/**
 * Writes an {@link AcquisitionRun} as nmrML.
 *
 * <p>Uses {@link StringBuilder} for output construction. Arrays are encoded as
 * Base64 little-endian float64 without compression.</p>
 */
public final class NmrMLWriter {

    private NmrMLWriter() {}

    /**
     * Write an NMR AcquisitionRun as nmrML.
     *
     * @param run  the acquisition run (must have chemical_shift and intensity channels)
     * @param path output file path
     */
    public static void write(AcquisitionRun run, String path) {
        String nucleus = run.nucleusType() != null ? run.nucleusType() : "1H";
        // Internal frequency is MHz; nmrML expects Hz
        double freqHz = run.spectrometerFrequencyMHz() * 1.0e6;

        double[] chemicalShift = run.channels().getOrDefault("chemical_shift", new double[0]);
        double[] intensity = run.channels().getOrDefault("intensity", new double[0]);

        String csBase64 = encodeArray(chemicalShift);
        String intBase64 = encodeArray(intensity);

        StringBuilder sb = new StringBuilder();
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.append("<nmrML xmlns=\"http://nmrml.org/schema\">\n");

        // cvList
        sb.append("  <cvList>\n");
        sb.append("    <cv id=\"nmrCV\" fullName=\"nmrML Controlled Vocabulary\"" +
                  " version=\"1.1.0\" URI=\"http://nmrml.org/cv/v1.1.0/nmrCV.owl\"/>\n");
        sb.append("  </cvList>\n");

        // acquisition
        sb.append("  <acquisition>\n");
        sb.append("    <acquisition1D>\n");
        sb.append("      <acquisitionParameterSet numberOfScans=\"1\">\n");
        sb.append("        <acquisitionNucleus name=\"").append(escapeXml(nucleus)).append("\"/>\n");
        sb.append("        <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000001\"" +
                  " name=\"spectrometer frequency\" value=\"").append(freqHz).append("\"/>\n");
        sb.append("        <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000002\"" +
                  " name=\"acquisition nucleus\" value=\"").append(escapeXml(nucleus)).append("\"/>\n");
        sb.append("      </acquisitionParameterSet>\n");
        sb.append("    </acquisition1D>\n");
        sb.append("  </acquisition>\n");

        // spectrumList
        sb.append("  <spectrumList>\n");
        sb.append("    <spectrum1D>\n");

        sb.append("      <xAxis>\n");
        sb.append("        <spectrumDataArray compressed=\"false\" encodedLength=\"")
          .append(csBase64.length()).append("\">");
        sb.append(csBase64);
        sb.append("</spectrumDataArray>\n");
        sb.append("      </xAxis>\n");

        sb.append("      <yAxis>\n");
        sb.append("        <spectrumDataArray compressed=\"false\" encodedLength=\"")
          .append(intBase64.length()).append("\">");
        sb.append(intBase64);
        sb.append("</spectrumDataArray>\n");
        sb.append("      </yAxis>\n");

        sb.append("    </spectrum1D>\n");
        sb.append("  </spectrumList>\n");

        sb.append("</nmrML>\n");

        try {
            Files.writeString(Path.of(path), sb.toString(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to write nmrML: " + path, e);
        }
    }

    // ── Encoding helpers ───────────────────────────────────────────

    static String encodeArray(double[] data) {
        ByteBuffer buf = ByteBuffer.allocate(data.length * 8);
        buf.order(ByteOrder.LITTLE_ENDIAN);
        for (double v : data) {
            buf.putDouble(v);
        }
        return Base64.getEncoder().encodeToString(buf.array());
    }

    private static String escapeXml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&apos;");
    }
}
