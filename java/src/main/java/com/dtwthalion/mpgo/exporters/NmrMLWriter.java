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
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGONmrMLWriter} &middot;
 * Python: {@code mpeg_o.exporters.nmrml}</p>
 *
 * @since 0.6
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
        // nmrML XSD requires a version attribute on the root element.
        sb.append("<nmrML xmlns=\"http://nmrml.org/schema\" version=\"1.1.0\">\n");

        // cvList
        sb.append("  <cvList>\n");
        sb.append("    <cv id=\"nmrCV\" fullName=\"nmrML Controlled Vocabulary\"" +
                  " version=\"1.1.0\" URI=\"http://nmrml.org/cv/v1.1.0/nmrCV.owl\"/>\n");
        sb.append("  </cvList>\n");

        // nmrML XSD requires <fileDescription> between <cvList> and <acquisition>.
        sb.append("  <fileDescription>\n");
        sb.append("    <fileContent>\n");
        sb.append("      <cvParam cvRef=\"nmrCV\" accession=\"NMR:1000002\"" +
                  " name=\"acquisition nucleus\" value=\"\"/>\n");
        sb.append("    </fileContent>\n");
        sb.append("  </fileDescription>\n");

        // softwareList + instrumentConfigurationList before <acquisition>.
        sb.append("  <softwareList>\n");
        sb.append("    <software id=\"mpeg_o\" version=\"0.9.0\"" +
                  " cvRef=\"nmrCV\" accession=\"NMR:1400217\" name=\"custom software\"/>\n");
        sb.append("  </softwareList>\n");
        sb.append("  <instrumentConfigurationList>\n");
        sb.append("    <instrumentConfiguration id=\"IC1\">\n");
        sb.append("      <cvParam cvRef=\"nmrCV\" accession=\"NMR:1400255\"" +
                  " name=\"nmr instrument\" value=\"\"/>\n");
        sb.append("    </instrumentConfiguration>\n");
        sb.append("  </instrumentConfigurationList>\n");

        // Strict XSD element order per AcquisitionParameterSet[1D]Type.
        sb.append("  <acquisition>\n");
        sb.append("    <acquisition1D>\n");
        sb.append("      <acquisitionParameterSet numberOfScans=\"1\"" +
                  " numberOfSteadyStateScans=\"0\">\n");
        sb.append("        <softwareRef ref=\"mpeg_o\"/>\n");
        sb.append("        <sampleContainer cvRef=\"nmrCV\"" +
                  " accession=\"NMR:1400128\" name=\"tube\"/>\n");
        sb.append("        <sampleAcquisitionTemperature value=\"298.0\"" +
                  " unitAccession=\"UO:0000012\" unitName=\"kelvin\" unitCvRef=\"UO\"/>\n");
        sb.append("        <spinningRate value=\"0.0\"" +
                  " unitAccession=\"UO:0000106\" unitName=\"hertz\" unitCvRef=\"UO\"/>\n");
        sb.append("        <relaxationDelay value=\"1.0\"" +
                  " unitAccession=\"UO:0000010\" unitName=\"second\" unitCvRef=\"UO\"/>\n");
        sb.append("        <pulseSequence/>\n");

        String effectiveNucleus = nucleus == null || nucleus.isEmpty() ? "1H" : nucleus;
        double sweepValue = 10.0; // placeholder when writer has no sweep info
        int nPoints = intensity.length;
        sb.append("        <DirectDimensionParameterSet decoupled=\"false\"" +
                  " numberOfDataPoints=\"").append(nPoints).append("\">\n");
        sb.append("          <acquisitionNucleus cvRef=\"nmrCV\"" +
                  " accession=\"NMR:1000002\" name=\"").append(escapeXml(effectiveNucleus))
          .append("\"/>\n");
        sb.append("          <effectiveExcitationField value=\"0.0\"" +
                  " unitAccession=\"UO:0000228\" unitName=\"tesla\" unitCvRef=\"UO\"/>\n");
        sb.append("          <sweepWidth value=\"").append(sweepValue).append("\"" +
                  " unitAccession=\"UO:0000169\" unitName=\"parts per million\"" +
                  " unitCvRef=\"UO\"/>\n");
        sb.append("          <pulseWidth value=\"10.0\"" +
                  " unitAccession=\"UO:0000029\" unitName=\"microsecond\" unitCvRef=\"UO\"/>\n");
        sb.append("          <irradiationFrequency value=\"").append(freqHz).append("\"" +
                  " unitAccession=\"UO:0000106\" unitName=\"hertz\" unitCvRef=\"UO\"/>\n");
        sb.append("          <irradiationFrequencyOffset value=\"0.0\"" +
                  " unitAccession=\"UO:0000106\" unitName=\"hertz\" unitCvRef=\"UO\"/>\n");
        sb.append("          <samplingStrategy cvRef=\"nmrCV\"" +
                  " accession=\"NMR:1400285\" name=\"uniform sampling\"/>\n");
        sb.append("        </DirectDimensionParameterSet>\n");
        sb.append("      </acquisitionParameterSet>\n");
        sb.append("      <fidData compressed=\"false\" byteFormat=\"Complex128\"" +
                  " encodedLength=\"0\"></fidData>\n");
        sb.append("    </acquisition1D>\n");
        sb.append("  </acquisition>\n");

        // Canonical spectrum1D: single <spectrumDataArray> with interleaved
        // (x,y) doubles + attribute-only <xAxis>. Reader detects the
        // interleaved form via encodedLength == 2 * numberOfDataPoints * 8.
        double[] xy = new double[nPoints * 2];
        for (int i = 0; i < nPoints; i++) {
            xy[2*i    ] = chemicalShift[i];
            xy[2*i + 1] = intensity[i];
        }
        String xyBase64 = encodeArray(xy);

        sb.append("  <spectrumList>\n");
        sb.append("    <spectrum1D id=\"s1\" numberOfDataPoints=\"")
          .append(nPoints).append("\">\n");
        sb.append("      <spectrumDataArray compressed=\"false\" byteFormat=\"Complex128\"" +
                  " encodedLength=\"").append(xyBase64.length()).append("\">");
        sb.append(xyBase64);
        sb.append("</spectrumDataArray>\n");
        sb.append("      <xAxis unitAccession=\"UO:0000169\"" +
                  " unitName=\"parts per million\" unitCvRef=\"UO\"/>\n");
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
