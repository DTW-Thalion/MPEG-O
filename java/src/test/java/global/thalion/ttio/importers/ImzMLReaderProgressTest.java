/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage C per-spectrum {@link ProgressSink} wiring for
 * {@link ImzMLReader}.
 *
 * <p>Imaging mass-spec totals are known up front (one stub per
 * {@code <spectrum>}), so callbacks carry a real {@code total} from
 * the first fire — unlike the {@code -1L} mid-parse fires of the
 * streaming readers.</p>
 */
class ImzMLReaderProgressTest {

    private static final byte[] GOOD_UUID = {
        0x12, 0x34, 0x56, 0x78, (byte) 0x9a, (byte) 0xbc, (byte) 0xde, (byte) 0xf0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, (byte) 0x88
    };

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    /** Build a deterministic .imzML + .ibd pair on disk; returns the
     *  .imzML path (sibling .ibd is auto-resolved). */
    private static Path writeSyntheticPair(Path tmp, int gridX, int gridY,
                                            int nPeaks) throws IOException {
        int nPixels = gridX * gridY;
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        payload.write(GOOD_UUID);

        int sharedMzOffset = payload.size();
        ByteBuffer mzBuf = ByteBuffer.allocate(nPeaks * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < nPeaks; i++) mzBuf.putDouble(100.0 + i);
        payload.write(mzBuf.array());

        int[] intOffsets = new int[nPixels];
        for (int pixel = 0; pixel < nPixels; pixel++) {
            intOffsets[pixel] = payload.size();
            ByteBuffer buf = ByteBuffer.allocate(nPeaks * 8).order(ByteOrder.LITTLE_ENDIAN);
            for (int i = 0; i < nPeaks; i++) buf.putDouble(pixel * 1000.0 + i);
            payload.write(buf.array());
        }

        String stem = "progress_" + gridX + "x" + gridY;
        Path ibdPath = tmp.resolve(stem + ".ibd");
        Files.write(ibdPath, payload.toByteArray());

        String uuidHex = hex(GOOD_UUID);
        StringBuilder spectraXml = new StringBuilder();
        for (int pixel = 0; pixel < nPixels; pixel++) {
            int x = (pixel % gridX) + 1;
            int y = (pixel / gridX) + 1;
            spectraXml.append(String.format(
                "    <spectrum index=\"%d\" id=\"px=%d\">%n"
              + "      <scanList count=\"1\"><scan>%n"
              + "        <cvParam cvRef=\"IMS\" accession=\"IMS:1000050\""
              + " name=\"position x\" value=\"%d\"/>%n"
              + "        <cvParam cvRef=\"IMS\" accession=\"IMS:1000051\""
              + " name=\"position y\" value=\"%d\"/>%n"
              + "      </scan></scanList>%n"
              + "      <binaryDataArrayList count=\"2\">%n"
              + "        <binaryDataArray encodedLength=\"%d\">%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000523\""
              + " name=\"64-bit float\"/>%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000514\""
              + " name=\"m/z array\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000102\""
              + " name=\"external offset\" value=\"%d\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000103\""
              + " name=\"external array length\" value=\"%d\"/>%n"
              + "        </binaryDataArray>%n"
              + "        <binaryDataArray encodedLength=\"%d\">%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000523\""
              + " name=\"64-bit float\"/>%n"
              + "          <cvParam cvRef=\"MS\" accession=\"MS:1000515\""
              + " name=\"intensity array\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000102\""
              + " name=\"external offset\" value=\"%d\"/>%n"
              + "          <cvParam cvRef=\"IMS\" accession=\"IMS:1000103\""
              + " name=\"external array length\" value=\"%d\"/>%n"
              + "        </binaryDataArray>%n"
              + "      </binaryDataArrayList>%n"
              + "    </spectrum>%n",
                pixel, pixel, x, y,
                nPeaks * 8, sharedMzOffset, nPeaks,
                nPeaks * 8, intOffsets[pixel], nPeaks));
        }

        String imzmlText = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<mzML version=\"1.1.0\">\n"
            + "  <fileDescription><fileContent>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000042\""
            + " name=\"universally unique identifier\" value=\"{" + uuidHex + "}\"/>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000030\""
            + " name=\"continuous mode\"/>\n"
            + "  </fileContent></fileDescription>\n"
            + "  <scanSettingsList count=\"1\"><scanSettings id=\"s1\">\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000003\""
            + " name=\"max count of pixels x\" value=\"" + gridX + "\"/>\n"
            + "    <cvParam cvRef=\"IMS\" accession=\"IMS:1000004\""
            + " name=\"max count of pixels y\" value=\"" + gridY + "\"/>\n"
            + "  </scanSettings></scanSettingsList>\n"
            + "  <run id=\"ims_run\"><spectrumList count=\"" + nPixels + "\">\n"
            + spectraXml.toString()
            + "  </spectrumList></run>\n"
            + "</mzML>\n";
        Path imzmlPath = tmp.resolve(stem + ".imzML");
        Files.writeString(imzmlPath, imzmlText);
        return imzmlPath;
    }

    @Test
    void imzmlReader_emits_progress_per_hundred_pixels(@TempDir Path tmp)
            throws Exception {
        // 15 x 15 = 225 pixels → 2 mid-fires (100, 200) + 1 final fire.
        Path imzml = writeSyntheticPair(tmp, 15, 15, 4);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        ImzMLReader.read(imzml, sink);

        assertTrue(callbackCount.get() >= 2,
            "expected at least 2 callbacks for 225 pixels, got "
                + callbackCount.get());
        assertEquals(225L, lastDone.get(),
            "final callback should report exact pixel count");
        assertEquals(225L, lastTotal.get(),
            "final callback should set total == pixel count");
    }

    @Test
    void imzmlReader_emits_final_callback_for_small_inputs(@TempDir Path tmp)
            throws Exception {
        Path imzml = writeSyntheticPair(tmp, 2, 2, 4);  // 4 pixels.

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        ImzMLReader.read(imzml, sink);

        assertTrue(callbackCount.get() >= 1,
            "final callback must always fire even for small inputs");
        assertEquals(4L, lastDone.get(), "final done == pixel count");
        assertEquals(4L, lastTotal.get(), "final total == done");
    }

    @Test
    void imzmlReader_no_sink_overload_still_works(@TempDir Path tmp)
            throws Exception {
        Path imzml = writeSyntheticPair(tmp, 2, 2, 4);
        ImzMLReader.ImzMLImport im = ImzMLReader.read(imzml);
        assertEquals(4, im.spectra().size(),
            "no-sink overload should parse pixels as before");
    }
}
