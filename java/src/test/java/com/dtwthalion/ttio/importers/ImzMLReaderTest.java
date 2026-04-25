/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.importers;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Synthetic-fixture coverage for {@link ImzMLReader}.
 * Cross-language counterpart:
 *   python/tests/integration/test_imzml_import.py
 *   objc/Tests/TestImzMLReader.m
 */
final class ImzMLReaderTest {

    private static final byte[] GOOD_UUID = {
        0x12, 0x34, 0x56, 0x78, (byte) 0x9a, (byte) 0xbc, (byte) 0xde, (byte) 0xf0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, (byte) 0x88
    };
    private static final byte[] BAD_UUID = {
        (byte) 0xff, (byte) 0xff, (byte) 0xff, (byte) 0xff,
        (byte) 0xff, (byte) 0xff, (byte) 0xff, (byte) 0xff,
        (byte) 0xff, (byte) 0xff, (byte) 0xff, (byte) 0xff,
        (byte) 0xff, (byte) 0xff, (byte) 0xff, (byte) 0xff
    };

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    private record Pair(Path imzml, Path ibd, String uuidHex) {}

    /**
     * Build a deterministic .imzML + .ibd pair on disk.
     */
    private static Pair writeSyntheticPair(Path tmp,
                                            String mode,
                                            int gridX, int gridY, int nPeaks,
                                            boolean useBadUuidInIbd,
                                            int truncateIbdTo /* -1 = no truncation */)
            throws IOException
    {
        int nPixels = gridX * gridY;
        java.io.ByteArrayOutputStream payload = new java.io.ByteArrayOutputStream();
        payload.write(useBadUuidInIbd ? BAD_UUID : GOOD_UUID);

        int sharedMzOffset = -1;
        if ("continuous".equals(mode)) {
            sharedMzOffset = payload.size();
            ByteBuffer buf = ByteBuffer.allocate(nPeaks * 8).order(ByteOrder.LITTLE_ENDIAN);
            for (int i = 0; i < nPeaks; i++) buf.putDouble(100.0 + i);
            payload.write(buf.array());
        }

        int[] mzOffsets = new int[nPixels];
        int[] intOffsets = new int[nPixels];
        for (int pixel = 0; pixel < nPixels; pixel++) {
            int mzOffset;
            if ("continuous".equals(mode)) {
                mzOffset = sharedMzOffset;
            } else {
                mzOffset = payload.size();
                ByteBuffer buf = ByteBuffer.allocate(nPeaks * 8).order(ByteOrder.LITTLE_ENDIAN);
                for (int i = 0; i < nPeaks; i++) buf.putDouble(100.0 + i + pixel);
                payload.write(buf.array());
            }
            mzOffsets[pixel] = mzOffset;

            int intOffset = payload.size();
            intOffsets[pixel] = intOffset;
            ByteBuffer buf = ByteBuffer.allocate(nPeaks * 8).order(ByteOrder.LITTLE_ENDIAN);
            for (int i = 0; i < nPeaks; i++) buf.putDouble(pixel * 1000.0 + i);
            payload.write(buf.array());
        }

        byte[] payloadBytes = payload.toByteArray();
        if (truncateIbdTo >= 0 && truncateIbdTo < payloadBytes.length) {
            byte[] trimmed = new byte[truncateIbdTo];
            System.arraycopy(payloadBytes, 0, trimmed, 0, truncateIbdTo);
            payloadBytes = trimmed;
        }
        Path ibdPath = tmp.resolve("synth_" + mode + ".ibd");
        Files.write(ibdPath, payloadBytes);

        String uuidHex = hex(GOOD_UUID);
        String modeAcc = "continuous".equals(mode) ? "IMS:1000030" : "IMS:1000031";

        StringBuilder spectraXml = new StringBuilder();
        for (int pixel = 0; pixel < nPixels; pixel++) {
            int x = (pixel % gridX) + 1;
            int y = (pixel / gridX) + 1;
            spectraXml.append(String.format(
                "    <spectrum index=\"%d\" id=\"px=%d\">%n"
              + "      <scanList count=\"1\"><scan>%n"
              + "        <cvParam cvRef=\"IMS\" accession=\"IMS:1000050\" name=\"position x\" value=\"%d\"/>%n"
              + "        <cvParam cvRef=\"IMS\" accession=\"IMS:1000051\" name=\"position y\" value=\"%d\"/>%n"
              + "      </scan></scanList>%n"
              + "      <binaryDataArrayList count=\"2\">%n"
              + "        <binaryDataArray encodedLength=\"%d\">%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000102\" name=\"external offset\" value=\"%d\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000103\" name=\"external array length\" value=\"%d\"/>%n"
              + "        </binaryDataArray>%n"
              + "        <binaryDataArray encodedLength=\"%d\">%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000102\" name=\"external offset\" value=\"%d\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000103\" name=\"external array length\" value=\"%d\"/>%n"
              + "        </binaryDataArray>%n"
              + "      </binaryDataArrayList>%n"
              + "    </spectrum>%n",
                pixel, pixel, x, y,
                nPeaks * 8, mzOffsets[pixel], nPeaks,
                nPeaks * 8, intOffsets[pixel], nPeaks));
        }

        String imzmlText = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<mzML version=\"1.1.0\">\n"
            + "  <fileDescription><fileContent>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000042\" name=\"universally unique identifier\" value=\"{" + uuidHex + "}\"/>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"" + modeAcc + "\" name=\"" + mode + " mode\"/>\n"
            + "  </fileContent></fileDescription>\n"
            + "  <scanSettingsList count=\"1\"><scanSettings id=\"s1\">\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000003\" name=\"max count of pixels x\" value=\"" + gridX + "\"/>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000004\" name=\"max count of pixels y\" value=\"" + gridY + "\"/>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000040\" name=\"scan pattern\" value=\"flyback\"/>\n"
            + "  </scanSettings></scanSettingsList>\n"
            + "  <run id=\"ims_run\"><spectrumList count=\"" + nPixels + "\">\n"
            + spectraXml.toString()
            + "  </spectrumList></run>\n"
            + "</mzML>\n";
        Path imzmlPath = tmp.resolve("synth_" + mode + ".imzML");
        Files.writeString(imzmlPath, imzmlText);

        return new Pair(imzmlPath, ibdPath, uuidHex);
    }

    @Test
    void continuousMode_pixelCountAndGrid(@TempDir Path tmp) throws IOException {
        Pair p = writeSyntheticPair(tmp, "continuous", 3, 2, 8, false, -1);
        ImzMLReader.ImzMLImport result = ImzMLReader.read(p.imzml(), p.ibd());

        assertEquals("continuous", result.mode());
        assertEquals(p.uuidHex(), result.uuidHex());
        assertEquals(6, result.spectra().size());
        assertEquals(3, result.gridMaxX());
        assertEquals(2, result.gridMaxY());
        assertEquals("flyback", result.scanPattern());
        assertEquals(1, result.spectra().get(0).x());
        assertEquals(1, result.spectra().get(0).y());
        assertEquals(3, result.spectra().get(5).x());
        assertEquals(2, result.spectra().get(5).y());
    }

    @Test
    void continuousMode_sharesMzAxis(@TempDir Path tmp) throws IOException {
        Pair p = writeSyntheticPair(tmp, "continuous", 2, 2, 16, false, -1);
        ImzMLReader.ImzMLImport result = ImzMLReader.read(p.imzml(), p.ibd());
        double[] firstMz = result.spectra().get(0).mz();
        for (ImzMLReader.PixelSpectrum spec : result.spectra()) {
            assertSame(firstMz, spec.mz(),
                "continuous-mode contract: every pixel aliases the same m/z array");
        }
    }

    @Test
    void processedMode_perPixelMz(@TempDir Path tmp) throws IOException {
        Pair p = writeSyntheticPair(tmp, "processed", 2, 3, 4, false, -1);
        ImzMLReader.ImzMLImport result = ImzMLReader.read(p.imzml(), p.ibd());
        assertEquals("processed", result.mode());
        assertEquals(6, result.spectra().size());
        assertNotSame(result.spectra().get(0).mz(),
                       result.spectra().get(1).mz(),
                       "processed mode: per-pixel m/z buffers must be distinct");
        assertEquals(100.0, result.spectra().get(0).mz()[0], 0.0);
        assertEquals(101.0, result.spectra().get(1).mz()[0], 0.0);
    }

    @Test
    void uuidMismatch_raisesBinaryException(@TempDir Path tmp) throws IOException {
        Pair p = writeSyntheticPair(tmp, "continuous", 1, 1, 4, true, -1);
        ImzMLReader.ImzMLBinaryException ex = assertThrows(
            ImzMLReader.ImzMLBinaryException.class,
            () -> ImzMLReader.read(p.imzml(), p.ibd())
        );
        assertTrue(ex.getMessage().contains("UUID mismatch"),
                    "error message should call out UUID mismatch");
    }

    @Test
    void truncatedIbd_raisesOffsetOverflow(@TempDir Path tmp) throws IOException {
        Pair p = writeSyntheticPair(tmp, "continuous", 1, 1, 8, false, 20);
        ImzMLReader.ImzMLBinaryException ex = assertThrows(
            ImzMLReader.ImzMLBinaryException.class,
            () -> ImzMLReader.read(p.imzml(), p.ibd())
        );
        assertTrue(ex.getMessage().contains("reads past end"),
                    "error message should call out the overflow");
    }

    @Test
    void missingImzml_raisesParseException(@TempDir Path tmp) {
        Path absent = tmp.resolve("absent.imzML");
        ImzMLReader.ImzMLParseException ex = assertThrows(
            ImzMLReader.ImzMLParseException.class,
            () -> ImzMLReader.read(absent)
        );
        assertTrue(ex.getMessage().contains("not found"),
                    "error message should mention missing file");
    }
}
