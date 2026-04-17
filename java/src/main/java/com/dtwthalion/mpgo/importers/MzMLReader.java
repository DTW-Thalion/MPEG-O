/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.*;
import com.dtwthalion.mpgo.Enums.*;
import org.xml.sax.*;
import org.xml.sax.helpers.DefaultHandler;
import javax.xml.parsers.SAXParser;
import javax.xml.parsers.SAXParserFactory;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.*;
import java.util.zip.Inflater;

/**
 * SAX-based mzML 1.1 parser. Produces an {@link AcquisitionRun} from an
 * mzML document, decoding binary data arrays, cvParam metadata, and
 * chromatograms.
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGOMzMLReader} &middot;
 * Python: {@code mpeg_o.importers.mzml}</p>
 *
 * @since 0.6
 */
public class MzMLReader {

    public static AcquisitionRun read(String path) throws Exception {
        return read(new File(path));
    }

    public static AcquisitionRun read(File file) throws Exception {
        SAXParserFactory factory = SAXParserFactory.newInstance();
        factory.setNamespaceAware(true);
        SAXParser parser = factory.newSAXParser();
        MzMLHandler handler = new MzMLHandler();
        parser.parse(file, handler);
        return handler.buildRun(file.getName().replaceFirst("\\.mzML$", ""));
    }

    // Base64 + optional zlib decode
    static byte[] decodeBase64Zlib(String text, boolean zlib) {
        String cleaned = text.replaceAll("\\s+", "");
        byte[] raw = java.util.Base64.getDecoder().decode(cleaned);
        if (!zlib) return raw;
        // zlib inflate
        try {
            Inflater inflater = new Inflater();
            inflater.setInput(raw);
            ByteArrayOutputStream out = new ByteArrayOutputStream(raw.length * 4);
            byte[] buf = new byte[8192];
            while (!inflater.finished()) {
                int count = inflater.inflate(buf);
                if (count == 0 && inflater.needsInput()) break;
                out.write(buf, 0, count);
            }
            inflater.end();
            return out.toByteArray();
        } catch (Exception e) {
            throw new RuntimeException("zlib inflate failed", e);
        }
    }

    static double[] bytesToDoubles(byte[] data, Precision precision) {
        ByteBuffer bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
        int elementSize = precision.elementSize();
        int count = data.length / elementSize;
        double[] result = new double[count];
        for (int i = 0; i < count; i++) {
            result[i] = switch (precision) {
                case FLOAT32 -> bb.getFloat();
                case FLOAT64 -> bb.getDouble();
                case INT32 -> (double) bb.getInt();
                case INT64 -> (double) bb.getLong();
                default -> bb.getDouble();
            };
        }
        return result;
    }

    private static class MzMLHandler extends DefaultHandler {
        // Spectrum accumulation
        private final List<double[]> mzArrays = new ArrayList<>();
        private final List<double[]> intensityArrays = new ArrayList<>();
        private final List<Double> retentionTimes = new ArrayList<>();
        private final List<Integer> msLevels = new ArrayList<>();
        private final List<Integer> polarities = new ArrayList<>();
        private final List<Double> precursorMzs = new ArrayList<>();
        private final List<Integer> precursorCharges = new ArrayList<>();
        private final List<Double> basePeakIntensities = new ArrayList<>();

        // Chromatogram accumulation
        private final List<Chromatogram> chromatograms = new ArrayList<>();

        // Current spectrum state
        private boolean inSpectrum;
        private boolean inChromatogram;
        private boolean inBinaryDataArray;
        private int precursorDepth;
        private int selectedIonDepth;
        private int scanDepth;
        private int scanWindowDepth;
        private int specDefaultLen;
        private int chromDefaultLen;

        private int curMsLevel = 1;
        private int curPolarity = 0;
        private double curScanTime = 0;
        private double curPrecursorMz = 0;
        private int curPrecursorCharge = 0;
        private double curBasePeak = 0;
        private double curScanWinLow = 0;
        private double curScanWinHigh = 0;
        private boolean hasScanWin = false;

        // Binary array state
        private Precision curPrecision = Precision.FLOAT64;
        private boolean curZlib = false;
        private String curArrayRole = null;
        private StringBuilder charBuf = new StringBuilder();
        private boolean capturing = false;

        // Per-spectrum arrays
        private final Map<String, double[]> specArrays = new LinkedHashMap<>();

        // Per-chromatogram arrays
        private final Map<String, double[]> chromArrays = new LinkedHashMap<>();
        private ChromatogramType chromType = ChromatogramType.TIC;
        private double chromTargetMz = 0, chromPrecursorMz = 0, chromProductMz = 0;

        // referenceableParamGroup support
        private final Map<String, List<String[]>> paramGroups = new LinkedHashMap<>();
        private String currentGroupId = null;
        private boolean inRefGroup = false;

        @Override
        public void startElement(String uri, String localName, String qName, Attributes attrs) {
            switch (localName) {
                case "referenceableParamGroup" -> {
                    currentGroupId = attrs.getValue("id");
                    inRefGroup = true;
                    paramGroups.putIfAbsent(currentGroupId, new ArrayList<>());
                }
                case "referenceableParamGroupRef" -> {
                    String ref = attrs.getValue("ref");
                    List<String[]> group = paramGroups.get(ref);
                    if (group != null) {
                        for (String[] cv : group) {
                            handleCvParam(cv[0], cv[1], cv[2]);
                        }
                    }
                }
                case "spectrum" -> {
                    inSpectrum = true;
                    specDefaultLen = 0;
                    String dal = attrs.getValue("defaultArrayLength");
                    if (dal != null) specDefaultLen = Integer.parseInt(dal);
                    curMsLevel = 1; curPolarity = 0; curScanTime = 0;
                    curPrecursorMz = 0; curPrecursorCharge = 0; curBasePeak = 0;
                    curScanWinLow = 0; curScanWinHigh = 0; hasScanWin = false;
                    specArrays.clear();
                }
                case "chromatogram" -> {
                    inChromatogram = true;
                    chromDefaultLen = 0;
                    String dal = attrs.getValue("defaultArrayLength");
                    if (dal != null) chromDefaultLen = Integer.parseInt(dal);
                    chromArrays.clear();
                    chromType = ChromatogramType.TIC;
                    chromTargetMz = 0; chromPrecursorMz = 0; chromProductMz = 0;
                }
                case "precursor" -> precursorDepth++;
                case "selectedIon" -> selectedIonDepth++;
                case "scan" -> scanDepth++;
                case "scanWindow" -> scanWindowDepth++;
                case "binaryDataArray" -> {
                    inBinaryDataArray = true;
                    curPrecision = Precision.FLOAT64;
                    curZlib = false;
                    curArrayRole = null;
                }
                case "binary" -> {
                    capturing = true;
                    charBuf.setLength(0);
                }
                case "cvParam" -> {
                    String acc = attrs.getValue("accession");
                    String val = attrs.getValue("value");
                    String unitAcc = attrs.getValue("unitAccession");
                    if (inRefGroup) {
                        paramGroups.get(currentGroupId).add(new String[]{acc, val, unitAcc});
                    } else {
                        handleCvParam(acc, val, unitAcc);
                    }
                }
                case "userParam" -> {
                    if (inChromatogram) {
                        String name = attrs.getValue("name");
                        String val = attrs.getValue("value");
                        if ("target m/z".equals(name) && val != null) chromTargetMz = Double.parseDouble(val);
                        if ("precursor m/z".equals(name) && val != null) chromPrecursorMz = Double.parseDouble(val);
                        if ("product m/z".equals(name) && val != null) chromProductMz = Double.parseDouble(val);
                    }
                }
            }
        }

        private void handleCvParam(String acc, String val, String unitAcc) {
            if (acc == null) return;

            if (inBinaryDataArray) {
                Precision p = CVTermMapper.precisionFor(acc);
                if (p != null) { curPrecision = p; return; }
                if (CVTermMapper.isZlib(acc)) { curZlib = true; return; }
                String role = CVTermMapper.arrayRoleFor(acc);
                if (role != null) { curArrayRole = role; return; }
            }

            if (inSpectrum && selectedIonDepth > 0) {
                if (CVTermMapper.MS_SELECTED_ION_MZ.equals(acc) && val != null)
                    curPrecursorMz = Double.parseDouble(val);
                if (CVTermMapper.MS_CHARGE_STATE.equals(acc) && val != null)
                    curPrecursorCharge = Integer.parseInt(val);
                return;
            }

            if (inSpectrum && scanWindowDepth > 0) {
                if (CVTermMapper.MS_SCAN_WIN_LOWER.equals(acc) && val != null)
                    { curScanWinLow = Double.parseDouble(val); hasScanWin = true; }
                if (CVTermMapper.MS_SCAN_WIN_UPPER.equals(acc) && val != null)
                    { curScanWinHigh = Double.parseDouble(val); hasScanWin = true; }
                return;
            }

            if (inSpectrum && (scanDepth > 0 || selectedIonDepth == 0) && scanWindowDepth == 0) {
                if (CVTermMapper.MS_SCAN_START_TIME.equals(acc) && val != null) {
                    curScanTime = Double.parseDouble(val);
                    if (CVTermMapper.UO_MINUTE.equals(unitAcc)) curScanTime *= 60.0;
                }
                if (CVTermMapper.MS_MS_LEVEL.equals(acc) && val != null) curMsLevel = Integer.parseInt(val);
                if (CVTermMapper.MS_POSITIVE_SCAN.equals(acc)) curPolarity = 1;
                if (CVTermMapper.MS_NEGATIVE_SCAN.equals(acc)) curPolarity = -1;
                if (CVTermMapper.MS_BASE_PEAK_INTENSITY.equals(acc) && val != null)
                    curBasePeak = Double.parseDouble(val);
            }

            if (inChromatogram && !inBinaryDataArray) {
                if (CVTermMapper.MS_TIC_CHROM.equals(acc)) chromType = ChromatogramType.TIC;
                if (CVTermMapper.MS_XIC_CHROM.equals(acc)) chromType = ChromatogramType.XIC;
                if (CVTermMapper.MS_SRM_CHROM.equals(acc)) chromType = ChromatogramType.SRM;
            }
        }

        @Override
        public void characters(char[] ch, int start, int length) {
            if (capturing) charBuf.append(ch, start, length);
        }

        @Override
        public void endElement(String uri, String localName, String qName) {
            switch (localName) {
                case "referenceableParamGroup" -> inRefGroup = false;
                case "binary" -> {
                    capturing = false;
                    if (charBuf.length() > 0 && curArrayRole != null) {
                        byte[] decoded = decodeBase64Zlib(charBuf.toString(), curZlib);
                        double[] values = bytesToDoubles(decoded, curPrecision);
                        if (inSpectrum) specArrays.put(curArrayRole, values);
                        if (inChromatogram) chromArrays.put(curArrayRole, values);
                    }
                }
                case "binaryDataArray" -> inBinaryDataArray = false;
                case "spectrum" -> {
                    finishSpectrum();
                    inSpectrum = false;
                }
                case "chromatogram" -> {
                    finishChromatogram();
                    inChromatogram = false;
                }
                case "precursor" -> precursorDepth--;
                case "selectedIon" -> selectedIonDepth--;
                case "scan" -> scanDepth--;
                case "scanWindow" -> scanWindowDepth--;
            }
        }

        private void finishSpectrum() {
            double[] mz = specArrays.get("mz");
            double[] intensity = specArrays.get("intensity");
            if (mz == null || intensity == null) return;

            mzArrays.add(mz);
            intensityArrays.add(intensity);
            retentionTimes.add(curScanTime);
            msLevels.add(curMsLevel);
            polarities.add(curPolarity);
            precursorMzs.add(curPrecursorMz);
            precursorCharges.add(curPrecursorCharge);
            basePeakIntensities.add(curBasePeak);
        }

        private void finishChromatogram() {
            double[] time = chromArrays.get("time");
            double[] intensity = chromArrays.get("intensity");
            if (time == null || intensity == null) return;
            chromatograms.add(new Chromatogram(time, intensity, chromType,
                    chromTargetMz, chromPrecursorMz, chromProductMz));
        }

        AcquisitionRun buildRun(String runName) {
            int specCount = mzArrays.size();
            if (specCount == 0) return null;

            // Concatenate signal channels
            int totalPeaks = mzArrays.stream().mapToInt(a -> a.length).sum();
            double[] allMz = new double[totalPeaks];
            double[] allIntensity = new double[totalPeaks];
            long[] offsets = new long[specCount];
            int[] lengths = new int[specCount];

            int pos = 0;
            for (int i = 0; i < specCount; i++) {
                offsets[i] = pos;
                lengths[i] = mzArrays.get(i).length;
                System.arraycopy(mzArrays.get(i), 0, allMz, pos, lengths[i]);
                System.arraycopy(intensityArrays.get(i), 0, allIntensity, pos, lengths[i]);
                pos += lengths[i];
            }

            SpectrumIndex index = new SpectrumIndex(specCount, offsets, lengths,
                    retentionTimes.stream().mapToDouble(Double::doubleValue).toArray(),
                    msLevels.stream().mapToInt(Integer::intValue).toArray(),
                    polarities.stream().mapToInt(Integer::intValue).toArray(),
                    precursorMzs.stream().mapToDouble(Double::doubleValue).toArray(),
                    precursorCharges.stream().mapToInt(Integer::intValue).toArray(),
                    basePeakIntensities.stream().mapToDouble(Double::doubleValue).toArray());

            Map<String, double[]> channels = new LinkedHashMap<>();
            channels.put("mz", allMz);
            channels.put("intensity", allIntensity);

            return new AcquisitionRun(runName, AcquisitionMode.MS1_DDA,
                    index, null, channels, chromatograms, List.of(), null, 0);
        }
    }
}
