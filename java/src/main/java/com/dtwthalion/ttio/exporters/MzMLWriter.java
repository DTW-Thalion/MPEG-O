/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.ttio.exporters;

import com.dtwthalion.ttio.*;
import com.dtwthalion.ttio.Enums.*;
import com.dtwthalion.ttio.importers.CVTermMapper;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.zip.Deflater;

/**
 * Writes an {@link AcquisitionRun} as indexedmzML.
 *
 * <p>Uses {@link StringBuilder} (not XMLStreamWriter) for precise byte-offset
 * control required by the indexedmzML index and checksum footer.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code TTIOMzMLWriter} &middot;
 * Python: {@code ttio.exporters.mzml}</p>
 *
 * @since 0.6
 */
public final class MzMLWriter {

    private MzMLWriter() {}

    /** Write with zlib compression enabled by default. */
    public static void write(AcquisitionRun run, String path) {
        write(run, path, true);
    }

    /**
     * Write an AcquisitionRun as indexedmzML.
     *
     * @param run           the acquisition run to serialize
     * @param path          output file path
     * @param zlibCompress  if true, zlib-compress binary data arrays
     */
    public static void write(AcquisitionRun run, String path, boolean zlibCompress) {
        StringBuilder sb = new StringBuilder();
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.append("<indexedmzML xmlns=\"http://psi.hupo.org/ms/mzml\"" +
                  " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n");
        sb.append("<mzML xmlns=\"http://psi.hupo.org/ms/mzml\">\n");

        // cvList
        sb.append("  <cvList count=\"2\">\n");
        sb.append("    <cv id=\"MS\" fullName=\"Proteomics Standards Initiative Mass Spectrometry Ontology\"" +
                  " version=\"4.1.30\" URI=\"https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo\"/>\n");
        sb.append("    <cv id=\"UO\" fullName=\"Unit Ontology\"" +
                  " version=\"09:04:2014\" URI=\"https://raw.githubusercontent.com/bio-ontology-research-group/unit-ontology/master/unit.obo\"/>\n");
        sb.append("  </cvList>\n");

        // fileDescription
        sb.append("  <fileDescription>\n");
        sb.append("    <fileContent>\n");
        sb.append("      <cvParam cvRef=\"MS\" accession=\"MS:1000579\" name=\"MS1 spectrum\"/>\n");
        sb.append("      <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\"/>\n");
        sb.append("    </fileContent>\n");
        sb.append("  </fileDescription>\n");

        // softwareList (required by XSD when later sections reference a softwareRef)
        sb.append("  <softwareList count=\"1\">\n");
        sb.append("    <software id=\"ttio\" version=\"0.9.0\">\n");
        sb.append("      <cvParam cvRef=\"MS\" accession=\"MS:1000799\"");
        sb.append(" name=\"custom unreleased software tool\" value=\"mpeg-o\"/>\n");
        sb.append("    </software>\n");
        sb.append("  </softwareList>\n");

        // instrumentConfigurationList — populated from InstrumentConfig where present.
        InstrumentConfig cfg = run.instrumentConfig();
        String model = cfg != null && cfg.model() != null ? escapeXml(cfg.model()) : "";
        String manuf = cfg != null && cfg.manufacturer() != null ? escapeXml(cfg.manufacturer()) : "";
        String serial = cfg != null && cfg.serialNumber() != null ? escapeXml(cfg.serialNumber()) : "";
        sb.append("  <instrumentConfigurationList count=\"1\">\n");
        sb.append("    <instrumentConfiguration id=\"IC1\">\n");
        sb.append("      <cvParam cvRef=\"MS\" accession=\"MS:1000031\" name=\"instrument model\" value=\"")
          .append(model).append("\"/>\n");
        if (!manuf.isEmpty()) {
            sb.append("      <userParam name=\"manufacturer\" value=\"").append(manuf)
              .append("\" type=\"xsd:string\"/>\n");
        }
        if (!serial.isEmpty()) {
            sb.append("      <userParam name=\"serial number\" value=\"").append(serial)
              .append("\" type=\"xsd:string\"/>\n");
        }
        sb.append("    </instrumentConfiguration>\n");
        sb.append("  </instrumentConfigurationList>\n");

        // dataProcessingList (referenced by spectrumList/chromatogramList via defaultDataProcessingRef).
        sb.append("  <dataProcessingList count=\"1\">\n");
        sb.append("    <dataProcessing id=\"dp\">\n");
        sb.append("      <processingMethod order=\"0\" softwareRef=\"ttio\">\n");
        sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1000544\" name=\"Conversion to mzML\"/>\n");
        sb.append("      </processingMethod>\n");
        sb.append("    </dataProcessing>\n");
        sb.append("  </dataProcessingList>\n");

        // run — IC1 default so every spectrum inherits the instrument config we just wrote.
        sb.append("  <run id=\"").append(escapeXml(run.name()))
          .append("\" defaultInstrumentConfigurationRef=\"IC1\">\n");

        // spectrumList
        SpectrumIndex idx = run.spectrumIndex();
        int specCount = idx.count();
        List<Chromatogram> chroms = run.chromatograms();

        sb.append("    <spectrumList count=\"").append(specCount)
          .append("\" defaultDataProcessingRef=\"dp\">\n");

        // Track byte offsets for the index (offsets are measured in the UTF-8 encoded output)
        List<Long> spectrumOffsets = new ArrayList<>();
        List<String> spectrumIds = new ArrayList<>();

        for (int i = 0; i < specCount; i++) {
            int len = idx.lengthAt(i);
            int msLevel = idx.msLevels()[i];
            Polarity polarity = idx.polarityAt(i);
            double rt = idx.retentionTimes()[i];
            double precMz = idx.precursorMzs()[i];
            int precCharge = idx.precursorCharges()[i];

            double[] mzData = run.channelSlice("mz", i);
            double[] intData = run.channelSlice("intensity", i);
            if (mzData == null) mzData = new double[0];
            if (intData == null) intData = new double[0];

            String scanId = "scan=" + (i + 1);
            spectrumIds.add(scanId);

            // Record byte offset before this <spectrum tag
            spectrumOffsets.add(byteLength(sb));

            sb.append("      <spectrum index=\"").append(i)
              .append("\" id=\"").append(scanId)
              .append("\" defaultArrayLength=\"").append(len).append("\">\n");

            // MS level
            sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"")
              .append(msLevel).append("\"/>\n");

            // Polarity
            if (polarity == Polarity.POSITIVE) {
                sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1000130\" name=\"positive scan\"/>\n");
            } else if (polarity == Polarity.NEGATIVE) {
                sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1000129\" name=\"negative scan\"/>\n");
            }

            // scanList
            sb.append("        <scanList count=\"1\"><scan>\n");
            sb.append("          <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"")
              .append(rt).append("\" unitCvRef=\"UO\" unitAccession=\"UO:0000010\" unitName=\"second\"/>\n");
            sb.append("        </scan></scanList>\n");

            // precursorList (MS2+)
            if (msLevel >= 2 && precMz > 0) {
                // M74: consult the index for activation method + isolation
                // window so the writer emits real metadata when the source
                // file carried it (opt_ms2_activation_detail flag), rather
                // than a CID placeholder.
                ActivationMethod activation = idx.activationMethodAt(i);
                IsolationWindow isoWindow = idx.isolationWindowAt(i);

                sb.append("        <precursorList count=\"1\"><precursor>\n");
                // mzML 1.1 XSD puts <isolationWindow> (optional) before
                // <selectedIonList>. Skip entirely when no window is stored.
                if (isoWindow != null) {
                    sb.append("          <isolationWindow>\n");
                    sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000827\"");
                    sb.append(" name=\"isolation window target m/z\" value=\"")
                      .append(isoWindow.targetMz())
                      .append("\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n");
                    sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000828\"");
                    sb.append(" name=\"isolation window lower offset\" value=\"")
                      .append(isoWindow.lowerOffset())
                      .append("\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n");
                    sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000829\"");
                    sb.append(" name=\"isolation window upper offset\" value=\"")
                      .append(isoWindow.upperOffset())
                      .append("\" unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n");
                    sb.append("          </isolationWindow>\n");
                }
                sb.append("          <selectedIonList count=\"1\"><selectedIon>\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000744\" name=\"selected ion m/z\" value=\"")
                  .append(precMz).append("\"/>\n");
                if (precCharge > 0) {
                    sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000041\" name=\"charge state\" value=\"")
                      .append(precCharge).append("\"/>\n");
                }
                sb.append("          </selectedIon></selectedIonList>\n");
                // PSI mzML 1.1 XSD requires <activation> inside every
                // <precursor>. Populate the method cvParam only when the
                // index carries a known ActivationMethod (MS2+ with the
                // opt_ms2_activation_detail flag); otherwise emit the
                // element empty so consumers can distinguish "unknown"
                // from a fabricated value.
                String[] pair = CVTermMapper.activationAccessionFor(activation);
                if (activation != null && activation != ActivationMethod.NONE && pair != null) {
                    sb.append("          <activation>\n");
                    sb.append("            <cvParam cvRef=\"MS\" accession=\"").append(pair[0])
                      .append("\" name=\"").append(pair[1]).append("\" value=\"\"/>\n");
                    sb.append("          </activation>\n");
                } else {
                    sb.append("          <activation/>\n");
                }
                sb.append("        </precursor></precursorList>\n");
            }

            // binaryDataArrayList
            String compressionAcc = zlibCompress ? "MS:1000574" : "MS:1000576";
            String compressionName = zlibCompress ? "zlib compression" : "no compression";

            String mzBase64 = encodeArray(mzData, zlibCompress);
            String intBase64 = encodeArray(intData, zlibCompress);

            sb.append("        <binaryDataArrayList count=\"2\">\n");

            // m/z array
            sb.append("          <binaryDataArray encodedLength=\"").append(mzBase64.length()).append("\">\n");
            sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n");
            sb.append("            <cvParam cvRef=\"MS\" accession=\"").append(compressionAcc)
              .append("\" name=\"").append(compressionName).append("\"/>\n");
            sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"" +
                      " unitCvRef=\"MS\" unitAccession=\"MS:1000040\" unitName=\"m/z\"/>\n");
            sb.append("            <binary>").append(mzBase64).append("</binary>\n");
            sb.append("          </binaryDataArray>\n");

            // intensity array
            sb.append("          <binaryDataArray encodedLength=\"").append(intBase64.length()).append("\">\n");
            sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n");
            sb.append("            <cvParam cvRef=\"MS\" accession=\"").append(compressionAcc)
              .append("\" name=\"").append(compressionName).append("\"/>\n");
            sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"" +
                      " unitCvRef=\"MS\" unitAccession=\"MS:1000131\" unitName=\"number of detector counts\"/>\n");
            sb.append("            <binary>").append(intBase64).append("</binary>\n");
            sb.append("          </binaryDataArray>\n");

            sb.append("        </binaryDataArrayList>\n");
            sb.append("      </spectrum>\n");
        }

        sb.append("    </spectrumList>\n");

        // chromatogramList
        List<Long> chromOffsets = new ArrayList<>();
        List<String> chromIds = new ArrayList<>();

        if (!chroms.isEmpty()) {
            sb.append("    <chromatogramList count=\"").append(chroms.size())
              .append("\" defaultDataProcessingRef=\"dp\">\n");

            for (int i = 0; i < chroms.size(); i++) {
                Chromatogram c = chroms.get(i);
                String chromId = "chrom=" + (i + 1);
                chromIds.add(chromId);
                chromOffsets.add(byteLength(sb));

                sb.append("      <chromatogram index=\"").append(i)
                  .append("\" id=\"").append(chromId)
                  .append("\" defaultArrayLength=\"").append(c.length()).append("\">\n");

                // chromatogram type cvParam
                switch (c.type()) {
                    case TIC -> sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1000235\" name=\"total ion current chromatogram\"/>\n");
                    case XIC -> sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1000627\" name=\"selected ion current chromatogram\"/>\n");
                    case SRM -> sb.append("        <cvParam cvRef=\"MS\" accession=\"MS:1001473\" name=\"selected reaction monitoring chromatogram\"/>\n");
                }

                if (c.targetMz() > 0) {
                    sb.append("        <userParam name=\"target m/z\" value=\"")
                      .append(c.targetMz()).append("\"/>\n");
                }

                String compressionAcc = zlibCompress ? "MS:1000574" : "MS:1000576";
                String compressionName = zlibCompress ? "zlib compression" : "no compression";

                String timeBase64 = encodeArray(c.timeValues(), zlibCompress);
                String intBase64 = encodeArray(c.intensityValues(), zlibCompress);

                sb.append("        <binaryDataArrayList count=\"2\">\n");

                // time array
                sb.append("          <binaryDataArray encodedLength=\"").append(timeBase64.length()).append("\">\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"").append(compressionAcc)
                  .append("\" name=\"").append(compressionName).append("\"/>\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000595\" name=\"time array\"" +
                          " unitCvRef=\"UO\" unitAccession=\"UO:0000010\" unitName=\"second\"/>\n");
                sb.append("            <binary>").append(timeBase64).append("</binary>\n");
                sb.append("          </binaryDataArray>\n");

                // intensity array
                sb.append("          <binaryDataArray encodedLength=\"").append(intBase64.length()).append("\">\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"").append(compressionAcc)
                  .append("\" name=\"").append(compressionName).append("\"/>\n");
                sb.append("            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n");
                sb.append("            <binary>").append(intBase64).append("</binary>\n");
                sb.append("          </binaryDataArray>\n");

                sb.append("        </binaryDataArrayList>\n");
                sb.append("      </chromatogram>\n");
            }

            sb.append("    </chromatogramList>\n");
        }

        sb.append("  </run>\n");
        sb.append("</mzML>\n");

        // indexList
        long indexListOffset = byteLength(sb);
        int indexCount = 1 + (chromOffsets.isEmpty() ? 0 : 1);
        sb.append("<indexList count=\"").append(indexCount).append("\">\n");

        // spectrum index
        sb.append("  <index name=\"spectrum\">\n");
        for (int i = 0; i < spectrumOffsets.size(); i++) {
            sb.append("    <offset idRef=\"").append(spectrumIds.get(i))
              .append("\">").append(spectrumOffsets.get(i)).append("</offset>\n");
        }
        sb.append("  </index>\n");

        // chromatogram index
        if (!chromOffsets.isEmpty()) {
            sb.append("  <index name=\"chromatogram\">\n");
            for (int i = 0; i < chromOffsets.size(); i++) {
                sb.append("    <offset idRef=\"").append(chromIds.get(i))
                  .append("\">").append(chromOffsets.get(i)).append("</offset>\n");
            }
            sb.append("  </index>\n");
        }

        sb.append("</indexList>\n");
        sb.append("<indexListOffset>").append(indexListOffset).append("</indexListOffset>\n");
        sb.append("<fileChecksum>0</fileChecksum>\n");
        sb.append("</indexedmzML>\n");

        try {
            Files.writeString(Path.of(path), sb.toString(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to write mzML: " + path, e);
        }
    }

    // ── Encoding helpers ───────────────────────────────────────────

    static String encodeArray(double[] data, boolean zlibCompress) {
        byte[] raw = doublesToBytes(data);
        if (zlibCompress) {
            raw = deflate(raw);
        }
        return Base64.getEncoder().encodeToString(raw);
    }

    static byte[] doublesToBytes(double[] data) {
        ByteBuffer buf = ByteBuffer.allocate(data.length * 8);
        buf.order(ByteOrder.LITTLE_ENDIAN);
        for (double v : data) {
            buf.putDouble(v);
        }
        return buf.array();
    }

    static byte[] deflate(byte[] input) {
        Deflater deflater = new Deflater();
        try {
            deflater.setInput(input);
            deflater.finish();
            byte[] buffer = new byte[input.length + 64];
            int len = deflater.deflate(buffer);
            byte[] result = new byte[len];
            System.arraycopy(buffer, 0, result, 0, len);
            return result;
        } finally {
            deflater.end();
        }
    }

    /** Return the UTF-8 byte length of the StringBuilder contents so far. */
    private static long byteLength(StringBuilder sb) {
        return sb.toString().getBytes(StandardCharsets.UTF_8).length;
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
