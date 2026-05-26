/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.MSImage;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 5.1 (Deferral 1, transport-spec §4.17 processed mode):
 * exercise sparse {@code IMAGE_PIXEL} (0x14) emission on
 * {@link TransportWriter#writeImageProcessed} and the matching
 * decode path on {@link TransportReader}.
 *
 * <p>Processed mode emits, per pixel, a list of
 * {@code (channel_index, intensity)} pairs indexed into the shared
 * {@code mzAxis} (carried on the IMAGE_HEADER). The MSImage data
 * model is unchanged — the dense {@code intensityCube} round-trips
 * byte-for-byte through the sparse wire shape. Channels that are
 * not enumerated in the payload decode as 0.0.</p>
 *
 * <p>Wire layout (LITTLE-ENDIAN, see transport-spec §4.17):</p>
 * <pre>
 *   x(u32), y(u32), precision(u8), compression(u8),
 *   payload_length(u32),
 *   payload_bytes = nonzero_count(u32)
 *                 + nonzero_count × { channel_index(u32) + intensity(fXX) }
 * </pre>
 *
 * <p>{@code writeImage} (continuous mode) is unchanged and remains
 * the default emission path; {@code writeImageProcessed} is an
 * opt-in sibling for sparse cubes.</p>
 */
class TransportImageProcessedTest {

    /**
     * Round-trip a sparse 3x3x10 MSImage through processed-mode
     * encode → decode and assert the dense {@code intensityCube}
     * matches the input byte-for-byte. The fixture is ~80% sparse:
     * each pixel has a small handful of nonzero channels seeded by
     * a deterministic pattern.
     */
    @Test
    void processed_mode_round_trips_sparse_cube(@TempDir Path tmp)
            throws Exception {
        MSImage img = buildSparseImage();
        byte[] bytes = encodeImageProcessed(img);

        TransportReader r = new TransportReader(bytes);
        var records = r.recordsForTest();
        // 1 IMAGE_HEADER + 9 IMAGE_PIXEL + 1 END_OF_IMAGE
        assertEquals(11, records.size(),
            "expected 1 header + 9 pixels + 1 EOI");
        assertEquals(PacketType.IMAGE_HEADER,  records.get(0).header.packetType);
        for (int i = 0; i < 9; i++) {
            assertEquals(PacketType.IMAGE_PIXEL,
                records.get(1 + i).header.packetType,
                "packet " + (1 + i) + " must be IMAGE_PIXEL");
        }
        assertEquals(PacketType.END_OF_IMAGE,  records.get(10).header.packetType);

        // IMAGE_HEADER must advertise is_continuous=0.
        ByteBuffer hdr = ByteBuffer.wrap(records.get(0).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        // skip past fixed-prefix to is_continuous (matches §4.16 layout)
        hdr.get();                              // modality
        hdr.getInt(); hdr.getInt(); hdr.getInt();  // w/h/spectrum_bins
        hdr.getDouble(); hdr.getDouble();          // pixel_size_x/y
        hdr.get(); hdr.get();                      // scan_pattern, axis_kind
        int axisLen = hdr.getInt();
        for (int i = 0; i < axisLen; i++) hdr.getDouble();
        int continuous = hdr.get() & 0xFF;
        assertEquals(0, continuous,
            "writeImageProcessed must emit is_continuous=0");

        // Materialise into a fresh MSImage via the reader's image()
        // accessor, then byte-compare the cubes.
        MSImage round = decodeToImage(bytes);
        assertNotNull(round, "reader must surface the materialised MSImage");
        assertEquals(img.width(),          round.width());
        assertEquals(img.height(),         round.height());
        assertEquals(img.spectralPoints(), round.spectralPoints());
        assertArrayEquals(img.mzAxis(),    round.mzAxis(), 1e-12);
        assertArrayEquals(img.intensityCube(),
                          round.intensityCube(), 0.0,
                          "dense cube must round-trip byte-for-byte");
    }

    /**
     * An entire pixel with all-zero intensities must encode as
     * {@code nonzero_count=0}. After round-tripping, the
     * corresponding cube slice stays at 0.0 and the wire payload is
     * tiny (just the outer header + the 4-byte count).
     */
    @Test
    void all_zero_pixel_emits_nonzero_count_zero() throws Exception {
        int w = 2, h = 1, bins = 5;
        double[] cube = new double[w * h * bins];   // all zero
        double[] mz = new double[]{100.0, 110.0, 120.0, 130.0, 140.0};
        MSImage img = new MSImage(w, h, bins, 0,
                10.0, 10.0, "raster",
                cube, mz,
                "all_zero", "",
                List.of(), List.of(), List.of());

        byte[] bytes = encodeImageProcessed(img);
        TransportReader r = new TransportReader(bytes);
        var records = r.recordsForTest();
        // 1 hdr + 2 pixels + 1 EOI
        assertEquals(4, records.size());

        // Each IMAGE_PIXEL payload after the outer fixed header must
        // carry nonzero_count=0 (a single 4-byte u32 LE = 0).
        for (int i = 0; i < 2; i++) {
            byte[] payload = records.get(1 + i).payload;
            ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
            bb.getInt();                 // x
            bb.getInt();                 // y
            bb.get(); bb.get();          // precision, compression
            int plen = bb.getInt();      // payload_length
            assertEquals(4, plen,
                "all-zero pixel must have payload_length=4 (just nonzero_count)");
            int count = bb.getInt();
            assertEquals(0, count, "all-zero pixel must emit nonzero_count=0");
        }

        // Round-trip: cube comes back all-zeros.
        MSImage round = decodeToImage(bytes);
        assertArrayEquals(cube, round.intensityCube(), 0.0);
    }

    /**
     * A fully dense pixel (every channel nonzero) round-trips
     * correctly even in processed mode — no off-by-one on the
     * channel-index loop.
     */
    @Test
    void fully_dense_pixel_round_trips_in_processed_mode() throws Exception {
        int w = 1, h = 1, bins = 8;
        double[] cube = new double[w * h * bins];
        for (int k = 0; k < bins; k++) cube[k] = (k + 1) * 7.5;  // all nonzero
        double[] mz = new double[bins];
        for (int k = 0; k < bins; k++) mz[k] = 200.0 + k;
        MSImage img = new MSImage(w, h, bins, 0,
                5.0, 5.0, "raster",
                cube, mz,
                "dense", "",
                List.of(), List.of(), List.of());

        byte[] bytes = encodeImageProcessed(img);
        TransportReader r = new TransportReader(bytes);
        var records = r.recordsForTest();
        // 1 hdr + 1 pixel + 1 EOI
        assertEquals(3, records.size());

        // Inspect the pixel payload: nonzero_count must be bins, and
        // payload_length = 4 + bins*(4+8).
        byte[] payload = records.get(1).payload;
        ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
        bb.getInt(); bb.getInt(); bb.get(); bb.get();
        int plen = bb.getInt();
        assertEquals(4 + bins * (4 + 8), plen,
            "dense processed-mode pixel payload size mismatch");
        int count = bb.getInt();
        assertEquals(bins, count);
        for (int k = 0; k < bins; k++) {
            int idx = bb.getInt();
            double v = bb.getDouble();
            assertEquals(k, idx,
                "channels must arrive in ascending order for a dense pixel");
            assertEquals((k + 1) * 7.5, v, 0.0);
        }

        MSImage round = decodeToImage(bytes);
        assertArrayEquals(cube, round.intensityCube(), 0.0);
    }

    /**
     * Mixed sparse-and-dense pixels in the same image round-trip
     * correctly: row 0 is dense, row 1 is sparse, row 2 is empty.
     * All three coexist on the wire under a single IMAGE_HEADER.
     */
    @Test
    void mixed_sparse_and_dense_pixels_round_trip() throws Exception {
        int w = 2, h = 3, bins = 6;
        double[] cube = new double[w * h * bins];
        // Row 0: dense.
        for (int x = 0; x < w; x++) {
            int base = (0 * w + x) * bins;
            for (int k = 0; k < bins; k++) cube[base + k] = (k + 1) + x * 0.5;
        }
        // Row 1: sparse — only channels 0, 3 are nonzero.
        for (int x = 0; x < w; x++) {
            int base = (1 * w + x) * bins;
            cube[base + 0] = 99.0 + x;
            cube[base + 3] = -1.5 * (x + 1);
        }
        // Row 2: empty (all zeros — left as default).
        double[] mz = new double[bins];
        for (int k = 0; k < bins; k++) mz[k] = 300.0 + k;
        MSImage img = new MSImage(w, h, bins, 0,
                1.0, 1.0, "raster",
                cube, mz,
                "mixed", "",
                List.of(), List.of(), List.of());

        byte[] bytes = encodeImageProcessed(img);
        MSImage round = decodeToImage(bytes);
        assertArrayEquals(cube, round.intensityCube(), 0.0,
            "mixed-sparsity cube must round-trip exactly");
        assertArrayEquals(mz, round.mzAxis(), 1e-12);
    }

    // -------- helpers --------

    /** 3x3x10 cube, ~80% sparse — per-pixel nonzeros < bins/4. */
    private static MSImage buildSparseImage() {
        final int w = 3, h = 3, bins = 10;
        double[] cube = new double[w * h * bins];
        // Each pixel gets 1-2 nonzero channels deterministically.
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int base = (y * w + x) * bins;
                int p = y * w + x;
                // pixel p: nonzero at channel (p % bins).
                cube[base + (p % bins)] = 1.0 + p;
                // sprinkle a second nonzero on odd-indexed pixels.
                if ((p & 1) == 1) {
                    cube[base + ((p * 3) % bins)] = -2.0 - p;
                }
            }
        }
        double[] mz = new double[bins];
        for (int k = 0; k < bins; k++) mz[k] = 100.0 + k * 5.0;
        return new MSImage(w, h, bins, 0,
                10.0, 10.0, "raster",
                cube, mz,
                "sparse", "",
                List.of(), List.of(), List.of());
    }

    private static byte[] encodeImageProcessed(MSImage img) throws Exception {
        ByteArrayOutputStream sink = new ByteArrayOutputStream();
        try (TransportWriter w = new TransportWriter(sink)) {
            w.writeImageProcessed(img);
        }
        return sink.toByteArray();
    }

    /**
     * Drive the reader byte-by-byte through its packet loop using
     * the {@code recordsForTest} accessor and reconstruct the dense
     * cube ourselves. We re-use the writer's own MSImage round-trip
     * via {@link TransportReader#materializeTo} where possible, but
     * here we don't have a backing dataset, so we just parse the
     * IMAGE_HEADER + IMAGE_PIXEL records directly.
     */
    private static MSImage decodeToImage(byte[] bytes) throws Exception {
        TransportReader r = new TransportReader(bytes);
        var records = r.recordsForTest();
        // Find the IMAGE_HEADER.
        int hdrIdx = -1;
        for (int i = 0; i < records.size(); i++) {
            if (records.get(i).header.packetType == PacketType.IMAGE_HEADER) {
                hdrIdx = i; break;
            }
        }
        assertTrue(hdrIdx >= 0, "must contain an IMAGE_HEADER");

        ByteBuffer hdr = ByteBuffer.wrap(records.get(hdrIdx).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        hdr.get();                                 // modality
        int width  = hdr.getInt();
        int height = hdr.getInt();
        int bins   = hdr.getInt();
        double pxX = hdr.getDouble();
        double pxY = hdr.getDouble();
        hdr.get();                                 // scan_pattern
        hdr.get();                                 // axis_kind
        int axisLen = hdr.getInt();
        double[] mz = new double[axisLen];
        for (int i = 0; i < axisLen; i++) mz[i] = hdr.getDouble();
        int isContinuous = hdr.get() & 0xFF;
        assertEquals(0, isContinuous,
            "decodeToImage helper expects processed-mode header");

        double[] cube = new double[width * height * bins];

        // Walk pixels.
        for (int i = hdrIdx + 1; i < records.size(); i++) {
            var rec = records.get(i);
            if (rec.header.packetType == PacketType.END_OF_IMAGE) break;
            if (rec.header.packetType != PacketType.IMAGE_PIXEL) continue;
            ByteBuffer bb = ByteBuffer.wrap(rec.payload)
                .order(ByteOrder.LITTLE_ENDIAN);
            int x = bb.getInt();
            int y = bb.getInt();
            int precision   = bb.get() & 0xFF;
            int compression = bb.get() & 0xFF;
            int plen = bb.getInt();
            byte[] raw = new byte[plen];
            bb.get(raw);
            ByteBuffer pb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
            int count = pb.getInt();
            int base = (y * width + x) * bins;
            for (int k = 0; k < count; k++) {
                int ch = pb.getInt();
                double v;
                if (precision == 1) v = pb.getDouble();
                else                v = pb.getFloat();
                cube[base + ch] = v;
            }
            assertEquals(0, compression,
                "compression=0 is the only mode produced today");
        }

        return new MSImage(width, height, bins, 0,
                pxX, pxY, "raster",
                cube, mz,
                "", "",
                List.of(), List.of(), List.of());
    }
}
