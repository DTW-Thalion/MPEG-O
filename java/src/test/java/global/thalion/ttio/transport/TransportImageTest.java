/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.MSImage;
import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 1.7 (transport-spec §4.16-§4.18): exercise
 * {@code IMAGE_HEADER} (0x13), {@code IMAGE_PIXEL} (0x14), and
 * {@code END_OF_IMAGE} (0x15) on {@link TransportWriter} +
 * {@link TransportReader}.
 *
 * <p>Continuous mode only — every pixel shares the same m/z axis.
 * Processed-mode (per-pixel axis) is deferred to a follow-up
 * (transport-spec §4.17 second paragraph).</p>
 *
 * <p>Wire layout summary (LITTLE-ENDIAN, see §4.16-§4.18):</p>
 * <ul>
 *   <li>IMAGE_HEADER: modality(u8), width(u32), height(u32),
 *       spectrum_bins(u32), pixel_size_x(f64), pixel_size_y(f64),
 *       scan_pattern(u8), axis_kind(u8), axis_length(u32),
 *       axis(f64[axis_length]), is_continuous(u8),
 *       title_length(u16), title_utf8, isa_id_length(u16),
 *       isa_id_utf8.</li>
 *   <li>IMAGE_PIXEL (continuous): x(u32), y(u32), precision(u8),
 *       compression(u8), payload_length(u32), intensities[..].</li>
 *   <li>END_OF_IMAGE: pixel_count_seen(u32).</li>
 * </ul>
 */
class TransportImageTest {

    /** Writer's low-level helper on a 4x4 MSImage emits exactly
     *  1 IMAGE_HEADER + 16 IMAGE_PIXEL + 1 END_OF_IMAGE packets in
     *  order, with the END_OF_IMAGE pixel_count_seen matching
     *  width*height. */
    @Test
    void writeImage_emits_header_pixels_and_end_in_order(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildImageMsContinuous(tmp.resolve("img.tio"));
        Path tis = tmp.resolve("img.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            assertNotNull(ds.image(),
                "fixture precondition: dataset must carry an MSImage");
            try (OutputStream out = Files.newOutputStream(tis);
                 TransportWriter w = new TransportWriter(out)) {
                w.writeStreamHeader("1.2", ds.title(), ds.isaInvestigationId(),
                    List.of(), 0);
                w.writeImage(ds.image());
                w.writeEndOfStream();
            }
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        // 1 StreamHeader + 1 IMAGE_HEADER + 16 IMAGE_PIXEL + 1 EOI + 1 EOS
        assertEquals(20, records.size(),
            "expected StreamHeader + IMAGE_HEADER + 16 pixels + EOI + EOS");
        assertEquals(PacketType.STREAM_HEADER, records.get(0).header.packetType);
        assertEquals(PacketType.IMAGE_HEADER,  records.get(1).header.packetType);
        for (int i = 0; i < 16; i++) {
            assertEquals(PacketType.IMAGE_PIXEL,
                records.get(2 + i).header.packetType,
                "packet " + (2 + i) + " must be IMAGE_PIXEL");
        }
        assertEquals(PacketType.END_OF_IMAGE,  records.get(18).header.packetType);
        assertEquals(PacketType.END_OF_STREAM, records.get(19).header.packetType);

        // Decode the IMAGE_HEADER payload to validate the wire layout.
        ByteBuffer hdr = ByteBuffer.wrap(records.get(1).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int modality = hdr.get() & 0xFF;
        int width    = hdr.getInt();
        int height   = hdr.getInt();
        int bins     = hdr.getInt();
        double pxX   = hdr.getDouble();
        double pxY   = hdr.getDouble();
        int scanPat  = hdr.get() & 0xFF;
        int axisKind = hdr.get() & 0xFF;
        int axisLen  = hdr.getInt();
        double[] axis = new double[axisLen];
        for (int i = 0; i < axisLen; i++) axis[i] = hdr.getDouble();
        int continuous = hdr.get() & 0xFF;
        assertEquals(0, modality, "MSImage maps to modality 0");
        assertEquals(4, width);
        assertEquals(4, height);
        assertEquals(5, bins);
        assertEquals(10.0, pxX, 1e-12);
        assertEquals(10.0, pxY, 1e-12);
        assertEquals(0, scanPat, "raster maps to scan_pattern 0");
        assertEquals(0, axisKind, "MSImage axis_kind is mz=0");
        assertEquals(5, axisLen);
        for (int i = 0; i < 5; i++) {
            assertEquals(100.0 + i * 10.0, axis[i], 1e-12,
                "axis[" + i + "] mismatch");
        }
        assertEquals(1, continuous, "fixture is continuous mode");

        // END_OF_IMAGE pixel_count_seen must equal width*height.
        ByteBuffer eoi = ByteBuffer.wrap(records.get(18).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        // Spec §4.18 says pixel_count_seen is uint32.
        int pixelCount = eoi.getInt();
        assertEquals(16, pixelCount);
    }

    /** End-to-end round-trip: writer emits the image packets, reader
     *  materialises them, the resulting on-disk .tio carries the same
     *  MSImage content (cube + mz axis). */
    @Test
    void image_round_trips_via_writeDataset_materializeTo(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildImageMsContinuous(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // close immediately so the file is flushed to disk.
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            MSImage imgA = a.image();
            MSImage imgB = b.image();
            assertNotNull(imgA, "source must carry an MSImage");
            assertNotNull(imgB, "round-tripped dataset must carry an MSImage");
            assertEquals(imgA.width(),          imgB.width());
            assertEquals(imgA.height(),         imgB.height());
            assertEquals(imgA.spectralPoints(), imgB.spectralPoints());
            assertEquals(imgA.pixelSizeX(),     imgB.pixelSizeX(),    1e-12);
            assertEquals(imgA.pixelSizeY(),     imgB.pixelSizeY(),    1e-12);
            assertEquals(imgA.scanPattern(),    imgB.scanPattern());
            assertArrayEquals(imgA.mzAxis(),    imgB.mzAxis(),        1e-12);
            assertArrayEquals(imgA.intensityCube(),
                              imgB.intensityCube(), 1e-12);
        }
    }

    /** writeDataset on a .tio carrying an image emits the
     *  transport_v0_11 feature flag in the StreamHeader. */
    @Test
    void writeDataset_emits_v0_11_feature_when_image_present(@TempDir Path tmp)
            throws Exception {
        Path src = FixtureBuilder.buildImageMsContinuous(tmp.resolve("img.tio"));
        Path tis = tmp.resolve("img.tis");
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }
        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        String streamHeaderPayload = new String(records.get(0).payload,
            StandardCharsets.UTF_8);
        assertTrue(streamHeaderPayload.contains("transport_v0_11"),
            "image-carrying dataset must flip the v0.11 feature flag");
    }

    /** writeDataset on a .tio with NO image emits ZERO image-related
     *  packets, preserving v0.10 byte-stream identity for legacy files. */
    @Test
    void writeDataset_no_image_packets_when_image_absent(@TempDir Path tmp)
            throws Exception {
        Path src = tmp.resolve("plain.tio");
        try (SpectralDataset ignore = SpectralDataset.create(
                src.toString(), "plain", "",
                List.of(), List.of(), List.of(), List.of())) {
            // empty dataset, no image.
        }
        Path tis = tmp.resolve("plain.tis");
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            assertNull(ds.image(),
                "fixture precondition: dataset must carry no image");
            w.writeDataset(ds);
        }
        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        for (var rec : r.recordsForTest()) {
            assertNotEquals(PacketType.IMAGE_HEADER, rec.header.packetType,
                "image-less dataset must not emit IMAGE_HEADER");
            assertNotEquals(PacketType.IMAGE_PIXEL, rec.header.packetType,
                "image-less dataset must not emit IMAGE_PIXEL");
            assertNotEquals(PacketType.END_OF_IMAGE, rec.header.packetType,
                "image-less dataset must not emit END_OF_IMAGE");
        }
    }
}
