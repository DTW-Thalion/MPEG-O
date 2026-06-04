/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Enums;
import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.IRImage;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.RamanImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.providers.Hdf5Provider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 5.3 (Deferral 1, transport-spec §4.16): exercise the
 * IMAGE pipeline for {@link IRImage} (modality=2) plus the
 * three-modality writeDataset path (MS + Raman + IR populated on
 * the same dataset, image blocks emitted in deterministic order).
 *
 * <p>The IMAGE_HEADER carries a {@code modality_extras} slot at
 * its tail with the IR-specific fields {@code ir_mode (u8)} and
 * {@code resolution_cm_inv (f64)} (9 bytes total).</p>
 */
class TransportIRImageTest {

    /** Build a small 3x3x4 IR image fixture in a freshly-created
     *  .tio under {@code target}. Returns the path for fluent use. */
    private static Path buildIRFixture(Path target) throws Exception {
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
        for (int i = 0; i < s; i++) wn[i] = 800.0 + i * 100.0;
        IRImage img = new IRImage(
            w, h, s, 0,
            8.0, 8.0, "raster",
            IRMode.ABSORBANCE, 4.0,
            cube, wn,
            "ir_fixture", "",
            List.of(), List.of(), List.of());

        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "ir_fixture", "",
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

    /** Build a .tio that carries one of EACH image modality
     *  (MS + Raman + IR) — used to verify the three-block emit
     *  ordering in writeDataset. */
    private static Path buildAllThreeImageModalities(Path target)
            throws Exception {
        final int w = 2;
        final int h = 2;
        final int s = 3;

        double[] msCube = new double[w * h * s];
        double[] msMz = new double[s];
        for (int i = 0; i < s; i++) msMz[i] = 100.0 + i * 10.0;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int base = (y * w + x) * s;
                for (int k = 0; k < s; k++) {
                    msCube[base + k] = (k + 1.0) * (x + y * w);
                }
            }
        }
        MSImage ms = new MSImage(w, h, s, 0,
            5.0, 5.0, "raster", msCube, msMz,
            "all_three", "", List.of(), List.of(), List.of());

        double[] ramanCube = new double[w * h * s];
        double[] ramanWn = new double[s];
        for (int i = 0; i < s; i++) ramanWn[i] = 500.0 + i * 50.0;
        for (int k = 0; k < ramanCube.length; k++) ramanCube[k] = k;
        RamanImage raman = new RamanImage(w, h, s, 0,
            6.0, 6.0, "raster",
            785.0, 50.0,
            ramanCube, ramanWn,
            "all_three", "", List.of(), List.of(), List.of());

        double[] irCube = new double[w * h * s];
        double[] irWn = new double[s];
        for (int i = 0; i < s; i++) irWn[i] = 1500.0 + i * 200.0;
        for (int k = 0; k < irCube.length; k++) irCube[k] = 2 * k;
        IRImage ir = new IRImage(w, h, s, 0,
            7.0, 7.0, "raster",
            IRMode.TRANSMITTANCE, 2.0,
            irCube, irWn,
            "all_three", "", List.of(), List.of(), List.of());

        try (SpectralDataset ignore = SpectralDataset.create(
                target.toString(), "all_three", "",
                List.of(), List.of(), List.of(), List.of())) {
            // create() persists /study/; images layered on next.
        }
        try (Hdf5File f = Hdf5File.open(target.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            ms.writeTo(Hdf5Provider.adapterForGroup(study));
            raman.writeTo(Hdf5Provider.adapterForGroup(study));
            ir.writeTo(Hdf5Provider.adapterForGroup(study));
        }
        return target;
    }

    /** Writer emits IMAGE_HEADER + N IMAGE_PIXEL + END_OF_IMAGE
     *  with modality=2 (IR) and the modality_extras slot carrying
     *  the IR-specific tail (u8 ir_mode + f64 resolution_cm_inv). */
    @Test
    void writeIRImage_emits_header_pixels_eoi_with_modality_2(
            @TempDir Path tmp) throws Exception {
        Path src = buildIRFixture(tmp.resolve("ir.tio"));
        Path tis = tmp.resolve("ir.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            IRImage irImg = (IRImage) ds.imageForKind(Enums.ImageKind.IR);
            assertNotNull(irImg,
                "fixture precondition: dataset must carry an IRImage");
            try (OutputStream out = Files.newOutputStream(tis);
                 TransportWriter w = new TransportWriter(out)) {
                w.writeStreamHeader("1.2", ds.title(), ds.isaInvestigationId(),
                    List.of(), 0);
                w.writeIRImage(irImg);
                w.writeEndOfStream();
            }
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        // 1 StreamHeader + 1 IMAGE_HEADER + 9 IMAGE_PIXEL + 1 EOI + 1 EOS
        assertEquals(13, records.size());
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
        assertEquals(2, modality, "IRImage maps to modality 2");
        assertEquals(3, width);
        assertEquals(3, height);
        assertEquals(4, bins);
        assertEquals(8.0, pxX, 1e-12);
        assertEquals(8.0, pxY, 1e-12);
        assertEquals(1, axisKind, "IRImage axis_kind is wavenumber=1");
        assertEquals(4, axisLen);
        assertEquals(1, continuous, "fixture is continuous mode");
        assertEquals(9, extrasLen,
            "modality=2 extras = 1B ir_mode + 8B resolution = 9B");
        int irMode = hdr.get() & 0xFF;
        double resolutionCmInv = hdr.getDouble();
        assertEquals(1, irMode, "ABSORBANCE maps to wire ir_mode=1");
        assertEquals(4.0, resolutionCmInv, 1e-12);

        ByteBuffer eoi = ByteBuffer.wrap(records.get(11).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        assertEquals(9, eoi.getInt());
    }

    /** End-to-end: writeDataset → materializeTo → re-read; the
     *  round-tripped IRImage matches byte-equal (cube, wavenumbers,
     *  ir_mode, resolution). */
    @Test
    void irImage_round_trips_via_writeDataset_materializeTo(
            @TempDir Path tmp) throws Exception {
        Path src = buildIRFixture(tmp.resolve("src.tio"));
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
            IRImage imgA = (IRImage) a.imageForKind(Enums.ImageKind.IR);
            IRImage imgB = (IRImage) b.imageForKind(Enums.ImageKind.IR);
            assertNotNull(imgA);
            assertNotNull(imgB);
            assertEquals(imgA.width(),                imgB.width());
            assertEquals(imgA.height(),               imgB.height());
            assertEquals(imgA.spectralPoints(),       imgB.spectralPoints());
            assertEquals(imgA.pixelSizeX(),           imgB.pixelSizeX(), 1e-12);
            assertEquals(imgA.pixelSizeY(),           imgB.pixelSizeY(), 1e-12);
            assertEquals(imgA.scanPattern(),          imgB.scanPattern());
            assertEquals(imgA.mode(),                 imgB.mode());
            assertEquals(imgA.resolutionCmInv(),      imgB.resolutionCmInv(), 1e-12);
            assertArrayEquals(imgA.wavenumbers(),     imgB.wavenumbers(),     1e-12);
            assertArrayEquals(imgA.intensityCube(),   imgB.intensityCube(),   1e-12);
        }
    }

    /** writeDataset on a .tio carrying MS + Raman + IR images emits
     *  exactly THREE IMAGE_HEADER blocks, in MS, Raman, IR order. */
    @Test
    void writeDataset_emits_all_three_image_modalities_in_order(
            @TempDir Path tmp) throws Exception {
        Path src = buildAllThreeImageModalities(tmp.resolve("all.tio"));
        Path tis = tmp.resolve("all.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            assertNotNull(ds.imageForKind(Enums.ImageKind.MS),
                "MS image must be present");
            assertNotNull(ds.imageForKind(Enums.ImageKind.RAMAN),
                "Raman image must be present");
            assertNotNull(ds.imageForKind(Enums.ImageKind.IR),
                "IR image must be present");
            w.writeDataset(ds);
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        // Walk the records and collect the IMAGE_HEADER modality bytes
        // in order of appearance.
        java.util.List<Integer> modalities = new java.util.ArrayList<>();
        for (var rec : records) {
            if (rec.header.packetType == PacketType.IMAGE_HEADER) {
                ByteBuffer bb = ByteBuffer.wrap(rec.payload)
                    .order(ByteOrder.LITTLE_ENDIAN);
                modalities.add(bb.get() & 0xFF);
            }
        }
        assertEquals(List.of(0, 1, 2), modalities,
            "writeDataset must emit MS (0), then Raman (1), then IR (2)");
    }
}
