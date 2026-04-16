/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.*;
import com.dtwthalion.mpgo.Enums.*;

import org.xml.sax.Attributes;
import org.xml.sax.SAXException;
import org.xml.sax.helpers.DefaultHandler;

import javax.xml.parsers.SAXParser;
import javax.xml.parsers.SAXParserFactory;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.zip.Inflater;

/**
 * SAX-based parser for nmrML files.
 *
 * <p>Extracts acquisition parameters (spectrometer frequency, nucleus, number
 * of scans, dwell time), FID data, and processed spectrum data. Returns an
 * {@link AcquisitionRun} with {@link AcquisitionMode#NMR_1D} mode,
 * {@code chemical_shift} and {@code intensity} channels, and optionally a
 * {@link FreeInductionDecay}.</p>
 */
public final class NmrMLReader {

    private NmrMLReader() {}

    /** Parse result bundling the AcquisitionRun and optional FID. */
    public static final class NmrMLResult {
        private final AcquisitionRun run;
        private final FreeInductionDecay fid;

        NmrMLResult(AcquisitionRun run, FreeInductionDecay fid) {
            this.run = run;
            this.fid = fid;
        }

        public AcquisitionRun run() { return run; }
        public FreeInductionDecay fid() { return fid; }
    }

    /** Read an nmrML file from the given path. */
    public static NmrMLResult read(String path) {
        try (InputStream is = Files.newInputStream(Path.of(path))) {
            return read(is, Path.of(path).getFileName().toString());
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to read nmrML: " + path, e);
        }
    }

    /** Read an nmrML document from an input stream. */
    public static NmrMLResult read(InputStream is, String name) {
        try {
            SAXParserFactory factory = SAXParserFactory.newInstance();
            factory.setNamespaceAware(true);
            SAXParser parser = factory.newSAXParser();
            NmrMLHandler handler = new NmrMLHandler();
            parser.parse(is, handler);
            return handler.buildResult(name);
        } catch (Exception e) {
            throw new RuntimeException("Failed to parse nmrML: " + name, e);
        }
    }

    // ── SAX handler ────────────────────────────────────────────────

    private static final class NmrMLHandler extends DefaultHandler {

        // Acquisition parameters
        private double spectrometerFrequencyHz = 0;
        private String nucleus = null;
        private int numberOfScans = 1;
        private double dwellTimeSeconds = 0;

        // FID
        private String fidBase64 = null;
        private String fidByteFormat = "float64";
        private boolean fidCompressed = false;

        // Spectrum data
        private String xAxisBase64 = null;
        private String yAxisBase64 = null;
        private String spectrumByteFormat = "float64";
        private boolean spectrumCompressed = false;

        // Parse state
        private final StringBuilder textBuf = new StringBuilder();
        private boolean inFidData = false;
        private boolean inXAxis = false;
        private boolean inYAxis = false;
        private boolean inSpectrumDataArray = false;
        private boolean inAcquisitionParameterSet = false;

        @Override
        public void startElement(String uri, String localName, String qName,
                                 Attributes atts) throws SAXException {
            textBuf.setLength(0);

            switch (localName) {
                case "acquisitionParameterSet" -> {
                    inAcquisitionParameterSet = true;
                    String ns = atts.getValue("numberOfScans");
                    if (ns != null) {
                        try { numberOfScans = Integer.parseInt(ns); } catch (NumberFormatException ignored) {}
                    }
                }
                case "acquisitionNucleus" -> {
                    String n = atts.getValue("name");
                    if (n != null) nucleus = CVTermMapper.nucleusNormalize(n);
                }
                case "cvParam" -> {
                    if (inAcquisitionParameterSet) {
                        String acc = atts.getValue("accession");
                        String val = atts.getValue("value");
                        if (acc != null && val != null) {
                            switch (acc) {
                                case "NMR:1000001" -> {
                                    try {
                                        spectrometerFrequencyHz = Double.parseDouble(val);
                                    } catch (NumberFormatException ignored) {}
                                }
                                case "NMR:1000002" -> nucleus = CVTermMapper.nucleusNormalize(val);
                                case "NMR:1000003" -> {
                                    try { numberOfScans = Integer.parseInt(val); } catch (NumberFormatException ignored) {}
                                }
                                case "NMR:1000004" -> {
                                    try { dwellTimeSeconds = Double.parseDouble(val); } catch (NumberFormatException ignored) {}
                                }
                            }
                        }
                    }
                }
                case "fidData" -> {
                    inFidData = true;
                    String bf = atts.getValue("byteFormat");
                    if (bf != null) fidByteFormat = bf;
                    String comp = atts.getValue("compressed");
                    fidCompressed = "true".equalsIgnoreCase(comp) || "zlib".equalsIgnoreCase(comp);
                }
                case "xAxis" -> inXAxis = true;
                case "yAxis" -> inYAxis = true;
                case "spectrumDataArray" -> {
                    inSpectrumDataArray = true;
                    String bf = atts.getValue("byteFormat");
                    if (bf != null) spectrumByteFormat = bf;
                    String comp = atts.getValue("compressed");
                    boolean isCompressed = "true".equalsIgnoreCase(comp) || "zlib".equalsIgnoreCase(comp);
                    if (inXAxis || inYAxis) {
                        spectrumCompressed = isCompressed;
                    }
                }
            }
        }

        @Override
        public void characters(char[] ch, int start, int length) {
            textBuf.append(ch, start, length);
        }

        @Override
        public void endElement(String uri, String localName, String qName) {
            switch (localName) {
                case "acquisitionParameterSet" -> inAcquisitionParameterSet = false;
                case "fidData" -> {
                    fidBase64 = textBuf.toString().strip();
                    inFidData = false;
                }
                case "spectrumDataArray" -> {
                    if (inSpectrumDataArray) {
                        String b64 = textBuf.toString().strip();
                        if (inXAxis) xAxisBase64 = b64;
                        else if (inYAxis) yAxisBase64 = b64;
                        inSpectrumDataArray = false;
                    }
                }
                case "xAxis" -> inXAxis = false;
                case "yAxis" -> inYAxis = false;
            }
        }

        NmrMLResult buildResult(String runName) {
            // Convert frequency from Hz to MHz
            double freqMHz = spectrometerFrequencyHz / 1.0e6;

            // Decode spectrum data
            double[] chemicalShift = new double[0];
            double[] intensity = new double[0];

            if (xAxisBase64 != null && !xAxisBase64.isEmpty()) {
                chemicalShift = decodeFloat64Array(xAxisBase64, spectrumCompressed);
            }
            if (yAxisBase64 != null && !yAxisBase64.isEmpty()) {
                intensity = decodeFloat64Array(yAxisBase64, spectrumCompressed);
            }

            // Build channels map
            Map<String, double[]> channels = new LinkedHashMap<>();
            channels.put("chemical_shift", chemicalShift);
            channels.put("intensity", intensity);

            int pointCount = chemicalShift.length;

            // Build SpectrumIndex (single spectrum)
            SpectrumIndex specIdx = new SpectrumIndex(
                    1,
                    new long[]{0},
                    new int[]{pointCount},
                    new double[]{0.0},
                    new int[]{0},
                    new int[]{0},
                    new double[]{0.0},
                    new int[]{0},
                    new double[]{0.0}
            );

            AcquisitionRun run = new AcquisitionRun(
                    runName,
                    AcquisitionMode.NMR_1D,
                    specIdx,
                    null,  // no instrument config from nmrML
                    channels,
                    List.of(),
                    List.of(),
                    nucleus,
                    freqMHz
            );

            // Decode FID if present
            FreeInductionDecay fid = null;
            if (fidBase64 != null && !fidBase64.isEmpty()) {
                double[] complexData = decodeFloat64Array(fidBase64, fidCompressed);
                int scanCount = complexData.length / 2;
                fid = new FreeInductionDecay(complexData, scanCount, dwellTimeSeconds, 0.0);
            }

            return new NmrMLResult(run, fid);
        }
    }

    // ── Decoding helpers ───────────────────────────────────────────

    static double[] decodeFloat64Array(String base64, boolean zlibCompressed) {
        byte[] raw = Base64.getDecoder().decode(base64);
        if (zlibCompressed) {
            raw = inflate(raw);
        }
        return bytesToDoubles(raw);
    }

    static double[] bytesToDoubles(byte[] data) {
        int count = data.length / 8;
        double[] result = new double[count];
        ByteBuffer buf = ByteBuffer.wrap(data);
        buf.order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < count; i++) {
            result[i] = buf.getDouble();
        }
        return result;
    }

    static byte[] inflate(byte[] compressed) {
        try {
            Inflater inflater = new Inflater();
            inflater.setInput(compressed);
            // Estimate uncompressed size; grow if needed
            byte[] buffer = new byte[compressed.length * 4];
            int totalLen = 0;
            while (!inflater.finished()) {
                if (totalLen == buffer.length) {
                    buffer = Arrays.copyOf(buffer, buffer.length * 2);
                }
                totalLen += inflater.inflate(buffer, totalLen, buffer.length - totalLen);
            }
            inflater.end();
            return Arrays.copyOf(buffer, totalLen);
        } catch (Exception e) {
            throw new RuntimeException("zlib inflate failed", e);
        }
    }
}
