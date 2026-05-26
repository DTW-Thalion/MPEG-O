/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.RamanImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 5.3 (Deferral 1, transport-spec §4.16): exercise the
 * IMAGE pipeline for {@link RamanImage} (modality=1). The
 * IMAGE_HEADER carries a {@code modality_extras} slot at its tail
 * with the Raman-specific fields
 * {@code excitation_wavelength_nm + laser_power_mw} (two FLOAT64,
 * 16 bytes total).
 *
 * <p>The shared header otherwise matches MS (modality=0) verbatim;
 * each pixel rides as a continuous-mode IMAGE_PIXEL whose payload
 * is a dense vector of {@code spectrum_bins} float64 intensities.
 * The shared axis on the IMAGE_HEADER is the Raman wavenumbers
 * vector (axis_kind=1).</p>
 */
class TransportRamanImageTest {

    /** Build a small 3x3x4 Raman image fixture in a freshly-created
     *  .tio under {@code target}. Returns the path for fluent use. */
    private static Path buildRamanFixture(Path target) throws Exception {
        final int w = 3;
        final int h = 3;
        final int s = 4;
        double[] cube = new double[w * h * s];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int base = (y * w + x) * s;
                for (int k = 0; k < s; k++) {
                    cube[base + k] = (k + 1.0) * (x + y * w);
                }
            }
        }
        double[] wn = new double[s];
        for (int i = 0; i < s; i++) wn[i] = 500.0 + i * 50.0;
        RamanImage img = new RamanImage(
            w, h, s, 0,
            12.5, 12.5, "raster",
            785.0, 50.0,
            cube, wn,
            "raman_fixture", "",
            List.of(), List.of(), List.of());

        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "raman_fixture", "",
                List.of(), List.of(), List.of(), List.of())) {
            // create() persists /study/; image layered on next.
        }
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            img.writeTo(Hdf5Provider.adapterForGroup(study));
        }
        return target;
    }

    /** Writer emits IMAGE_HEADER + N IMAGE_PIXEL + END_OF_IMAGE
     *  with modality=1 (Raman) and the modality_extras slot at the
     *  tail of the IMAGE_HEADER carrying the two Raman FLOAT64
     *  fields. */
    @Test
    void writeRamanImage_emits_header_pixels_eoi_with_modality_1(
            @TempDir Path tmp) throws Exception {
        Path src = buildRamanFixture(tmp.resolve("raman.tio"));
        Path tis = tmp.resolve("raman.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            assertNotNull(ds.ramanImage(),
                "fixture precondition: dataset must carry a RamanImage");
            try (OutputStream out = Files.newOutputStream(tis);
                 TransportWriter w = new TransportWriter(out)) {
                w.writeStreamHeader("1.2", ds.title(), ds.isaInvestigationId(),
                    List.of(), 0);
                w.writeRamanImage(ds.ramanImage());
                w.writeEndOfStream();
            }
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        // 1 StreamHeader + 1 IMAGE_HEADER + 9 IMAGE_PIXEL + 1 EOI + 1 EOS
        assertEquals(13, records.size(),
            "expected StreamHeader + IMAGE_HEADER + 9 pixels + EOI + EOS");
        assertEquals(PacketType.STREAM_HEADER, records.get(0).header.packetType);
        assertEquals(PacketType.IMAGE_HEADER,  records.get(1).header.packetType);
        for (int i = 0; i < 9; i++) {
            assertEquals(PacketType.IMAGE_PIXEL,
                records.get(2 + i).header.packetType);
        }
        assertEquals(PacketType.END_OF_IMAGE,  records.get(11).header.packetType);
        assertEquals(PacketType.END_OF_STREAM, records.get(12).header.packetType);

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
        int titleLen = hdr.getShort() & 0xFFFF;
        byte[] titleBytes = new byte[titleLen];
        hdr.get(titleBytes);
        int isaLen = hdr.getShort() & 0xFFFF;
        byte[] isaBytes = new byte[isaLen];
        hdr.get(isaBytes);
        int extrasLen = hdr.getShort() & 0xFFFF;
        assertEquals(1, modality, "RamanImage maps to modality 1");
        assertEquals(3, width);
        assertEquals(3, height);
        assertEquals(4, bins);
        assertEquals(12.5, pxX, 1e-12);
        assertEquals(12.5, pxY, 1e-12);
        assertEquals(0, scanPat, "raster maps to scan_pattern 0");
        assertEquals(1, axisKind, "RamanImage axis_kind is wavenumber=1");
        assertEquals(4, axisLen);
        for (int i = 0; i < 4; i++) {
            assertEquals(500.0 + i * 50.0, axis[i], 1e-12);
        }
        assertEquals(1, continuous, "fixture is continuous mode");
        assertEquals(16, extrasLen,
            "modality=1 extras = 8B excitation + 8B laser_power = 16B");
        double exc = hdr.getDouble();
        double laser = hdr.getDouble();
        assertEquals(785.0, exc, 1e-12);
        assertEquals(50.0,  laser, 1e-12);

        ByteBuffer eoi = ByteBuffer.wrap(records.get(11).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        assertEquals(9, eoi.getInt(), "pixel_count_seen = width*height");
    }

    /** End-to-end: writeDataset → materializeTo → re-read; the
     *  round-tripped dataset carries the RamanImage with all fields
     *  byte-equal to the original. */
    @Test
    void ramanImage_round_trips_via_writeDataset_materializeTo(
            @TempDir Path tmp) throws Exception {
        Path src = buildRamanFixture(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // close immediately so the file is flushed.
        }

        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            RamanImage imgA = a.ramanImage();
            RamanImage imgB = b.ramanImage();
            assertNotNull(imgA, "source must carry a RamanImage");
            assertNotNull(imgB, "round-tripped dataset must carry a RamanImage");
            assertEquals(imgA.width(),                   imgB.width());
            assertEquals(imgA.height(),                  imgB.height());
            assertEquals(imgA.spectralPoints(),          imgB.spectralPoints());
            assertEquals(imgA.pixelSizeX(),              imgB.pixelSizeX(), 1e-12);
            assertEquals(imgA.pixelSizeY(),              imgB.pixelSizeY(), 1e-12);
            assertEquals(imgA.scanPattern(),             imgB.scanPattern());
            assertEquals(imgA.excitationWavelengthNm(),  imgB.excitationWavelengthNm(), 1e-12);
            assertEquals(imgA.laserPowerMw(),            imgB.laserPowerMw(),           1e-12);
            assertArrayEquals(imgA.wavenumbers(),        imgB.wavenumbers(),        1e-12);
            assertArrayEquals(imgA.intensityCube(),      imgB.intensityCube(),      1e-12);
        }
    }

    /** Reader logs + skips an unknown modality byte (modality=99)
     *  rather than aborting the stream. The trailing END_OF_STREAM
     *  is still observed; the rest of the stream remains parseable. */
    @Test
    void readerSkipsUnknownModality(@TempDir Path tmp) throws Exception {
        // Synthesize a stream with an IMAGE_HEADER (modality=99,
        // 1x1x1) + 1 IMAGE_PIXEL + END_OF_IMAGE + END_OF_STREAM.
        // The reader must NOT throw; it skips the image block.
        Path tis = tmp.resolve("unknown_mod.tis");
        ByteArrayOutputStream baos = new ByteArrayOutputStream();

        // Build IMAGE_HEADER payload manually with modality=99.
        // Layout: 1+4+4+4+8+8+1+1+4+(0)+1+2+0+2+0+2+0 = 43 bytes
        ByteBuffer hbuf = ByteBuffer.allocate(43)
            .order(ByteOrder.LITTLE_ENDIAN);
        hbuf.put((byte) 99);     // modality (unknown)
        hbuf.putInt(1);          // width
        hbuf.putInt(1);          // height
        hbuf.putInt(1);          // spectrum_bins
        hbuf.putDouble(1.0);     // pixel_size_x
        hbuf.putDouble(1.0);     // pixel_size_y
        hbuf.put((byte) 0);      // scan_pattern
        hbuf.put((byte) 0);      // axis_kind
        hbuf.putInt(0);          // axis_length
        // axis omitted (length 0)
        hbuf.put((byte) 1);      // is_continuous
        hbuf.putShort((short) 0); // title_length
        hbuf.putShort((short) 0); // isa_id_length
        hbuf.putShort((short) 0); // modality_extras_length

        // Build IMAGE_PIXEL payload (continuous, 1 float64 intensity).
        ByteBuffer pbuf = ByteBuffer.allocate(4 + 4 + 1 + 1 + 4 + 8)
            .order(ByteOrder.LITTLE_ENDIAN);
        pbuf.putInt(0);          // x
        pbuf.putInt(0);          // y
        pbuf.put((byte) 1);      // precision (FLOAT64)
        pbuf.put((byte) 0);      // compression (NONE)
        pbuf.putInt(8);          // payload_length
        pbuf.putDouble(42.0);    // single intensity

        // END_OF_IMAGE payload.
        ByteBuffer ebuf = ByteBuffer.allocate(4)
            .order(ByteOrder.LITTLE_ENDIAN);
        ebuf.putInt(1);

        try (TransportWriter w = new TransportWriter(baos)) {
            w.writeStreamHeader("1.2", "unknown_mod", "", List.of(), 0);
            w.emitRawPacket(PacketType.IMAGE_HEADER, 0, 0, 0, hbuf.array());
            w.emitRawPacket(PacketType.IMAGE_PIXEL,  0, 0, 0, pbuf.array());
            w.emitRawPacket(PacketType.END_OF_IMAGE, 0, 0, 0, ebuf.array());
            w.writeEndOfStream();
        }
        Files.write(tis, baos.toByteArray());

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        // materializeTo must NOT throw on the unknown modality; the
        // image block is silently dropped.
        Path rt = tmp.resolve("rt.tio");
        try (SpectralDataset materialised = r.materializeTo(rt.toString())) {
            assertNull(materialised.image(),
                "unknown-modality stream must produce no MSImage");
            assertNull(materialised.ramanImage(),
                "unknown-modality stream must produce no RamanImage");
            assertNull(materialised.irImage(),
                "unknown-modality stream must produce no IRImage");
        }
    }
}
