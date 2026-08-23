/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.codecs.FloatDeltaZstd;
import global.thalion.ttio.importers.MzMLReader;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/** {@link SpectralStreamWriter} writes what {@link AcquisitionRun#writeTo}
 *  writes; {@link AcquisitionRun} reads channel ranges without whole
 *  decodes. */
class SpectralStreamWriterTest {

    static AcquisitionRun mzml() throws Exception {
        return MzMLReader.read(SpectralStreamWriterTest.class.getClassLoader()
                .getResource("1min.mzML").getPath());
    }

    static Path writeEager(Path tmp, AcquisitionRun run) {
        Path out = tmp.resolve("eager.tio");
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            StorageGroup ms = study.createGroup("ms_runs");
            ms.setAttribute("_run_names", run.name());
            run.writeTo(ms);
        }
        return out;
    }

    static Path writeStreamed(Path tmp, AcquisitionRun run, int batch) {
        Path out = tmp.resolve("streamed.tio");
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            try (SpectralStreamWriter w = new SpectralStreamWriter(study, "run_0001",
                    SpectralStreamWriter.Options.ms(run.acquisitionMode(), run.channelNames(),
                        run.instrumentConfig()).withBatchSpectra(batch))) {
                int n = run.spectrumCount();
                for (int i = 0; i < n; i += batch) {
                    w.appendBatch(WrittenSpectralBatch.fromRun(run, i, Math.min(n, i + batch)));
                }
                w.setChromatograms(run.chromatograms());
            }
        }
        return out;
    }

    static AcquisitionRun open(Path p) { return open(p, "run_0001"); }

    static AcquisitionRun open(Path p, String name) {
        StorageProvider prov = ProviderRegistry.open(p.toString(), StorageProvider.Mode.READ, "hdf5");
        return AcquisitionRun.readFrom(prov.rootGroup().openGroup("study").openGroup("ms_runs"), name);
    }

    @Test
    void streamedFileEqualsEagerFile(@TempDir Path tmp) throws Exception {
        AcquisitionRun run = mzml();
        Path eager = writeEager(tmp, run);
        Path streamed = writeStreamed(tmp, run, 7);
        AcquisitionRun a = open(eager, run.name()), b = open(streamed);
        assertEquals(a.spectrumCount(), b.spectrumCount());
        assertEquals(run.spectrumCount(), b.spectrumCount());
        SpectrumIndex ia = a.spectrumIndex(), ib = b.spectrumIndex();
        assertArrayEquals(ia.lengths(), ib.lengths());
        assertArrayEquals(ia.retentionTimes(), ib.retentionTimes(), 0.0);
        assertArrayEquals(ia.msLevels(), ib.msLevels());
        assertArrayEquals(ia.precursorMzs(), ib.precursorMzs(), 0.0);
        assertEquals(a.channelNames(), b.channelNames());
        for (String c : a.channelNames()) {
            assertArrayEquals(a.channels().get(c), b.channels().get(c), 0.0, c);
        }
        assertEquals(a.chromatograms().size(), b.chromatograms().size());
        for (int i = 0; i < a.spectrumCount(); i++) {
            MassSpectrum sa = (MassSpectrum) a.objectAtIndex(i), sb = (MassSpectrum) b.objectAtIndex(i);
            assertArrayEquals(sa.mzValues(), sb.mzValues(), 0.0);
            assertArrayEquals(sa.intensityValues(), sb.intensityValues(), 0.0);
            assertEquals(sa.msLevel(), sb.msLevel());
        }
        // codec 17 with a finalised header
        try (StorageProvider p = ProviderRegistry.open(streamed.toString(), StorageProvider.Mode.READ, "hdf5")) {
            StorageGroup sc = p.rootGroup().openGroup("study").openGroup("ms_runs").openGroup("run_0001")
                    .openGroup("signal_channels");
            try (StorageDataset ds = sc.openDataset("mz_values")) {
                assertEquals(Enums.Compression.FLOAT_DELTA_ZSTD.ordinal(), ((Number) ds.getAttribute("compression")).intValue());
                assertTrue(ds.extendable());
                FloatDeltaZstd.BlockTable t = FloatDeltaZstd.readBlockTable((off, n) -> (byte[]) ds.readSlice(off, n));
                assertEquals(run.channels().get("mz").length, t.nValues());
                assertEquals((t.nValues() + FloatDeltaZstd.BLOCK_SIZE - 1) / FloatDeltaZstd.BLOCK_SIZE, t.nBlocks());
            }
            StorageGroup rg = p.rootGroup().openGroup("study").openGroup("ms_runs").openGroup("run_0001");
            assertEquals((long) run.spectrumCount(), ((Number) rg.getAttribute("spectrum_count")).longValue());
            assertEquals("run_0001", p.rootGroup().openGroup("study").openGroup("ms_runs").getAttribute("_run_names").toString());
        }
        a.close();
        b.close();
    }

    @Test
    void appendSingleSpectraEqualsBatches(@TempDir Path tmp) throws Exception {
        AcquisitionRun run = mzml();
        Path out = tmp.resolve("single.tio");
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            try (SpectralStreamWriter w = new SpectralStreamWriter(study, "run_0001",
                    SpectralStreamWriter.Options.ms(run.acquisitionMode(), run.channelNames(), null)
                        .withBatchSpectra(5))) {
                Iterator<Spectrum> it = run.iterSpectra(4);
                while (it.hasNext()) w.append(it.next());
            }
        }
        AcquisitionRun b = open(out);
        assertEquals(run.spectrumCount(), b.spectrumCount());
        assertArrayEquals(run.channels().get("mz"), b.channels().get("mz"), 0.0);
        assertArrayEquals(run.spectrumIndex().msLevels(), b.spectrumIndex().msLevels());
        b.close();
    }

    @Test
    void lazyChannelRangesMatchWholeDecode(@TempDir Path tmp) throws Exception {
        AcquisitionRun run = mzml();
        AcquisitionRun b = open(writeStreamed(tmp, run, 9));
        double[] mz = run.channels().get("mz");
        assertArrayEquals(Arrays.copyOfRange(mz, 5, 45), b.channelRange("mz", 5, 40), 0.0);
        assertArrayEquals(Arrays.copyOfRange(mz, 0, 3), b.channelRange("mz", 0, 3), 0.0);
        assertNull(b.channelRange("nope", 0, 1));
        assertTrue(b.hasChannel("intensity"));
        assertFalse(b.hasChannel("nope"));
        List<Spectrum> viaIter = new java.util.ArrayList<>();
        Iterator<Spectrum> it = b.iterSpectra(3);
        while (it.hasNext()) viaIter.add(it.next());
        assertEquals(run.spectrumCount(), viaIter.size());
        for (int i = 0; i < viaIter.size(); i++) {
            assertArrayEquals(((MassSpectrum) run.objectAtIndex(i)).mzValues(),
                    ((MassSpectrum) viaIter.get(i)).mzValues(), 0.0);
        }
        // channels() materialises the whole channel once and agrees
        assertArrayEquals(mz, b.channels().get("mz"), 0.0);
        b.close();
    }

    /** blocks/index on an MS run: the spectral counterpart of the
     *  genomic block table. Every row must name bytes that are the
     *  block for the value range it claims. */
    @Test
    void blocksIndexDescribesEveryFdzBlock(@TempDir Path tmp) throws Exception {
        AcquisitionRun run = mzml();
        Path out = writeStreamed(tmp, run, 64);
        try (StorageProvider p = ProviderRegistry.open(out.toString(),
                StorageProvider.Mode.READ, "hdf5")) {
            StorageGroup rg = p.rootGroup().openGroup("study")
                .openGroup("ms_runs").openGroup("run_0001");
            assertTrue(rg.hasChild("blocks"), "no blocks group on an FDZ-compressed run");
            StorageDataset idx = rg.openGroup("blocks").openDataset("index");
            List<java.util.Map<String, Object>> rows = idx.readRows();
            assertFalse(rows.isEmpty(), "blocks/index is empty");

            long total = 0;
            for (int i = 0; i < run.spectrumCount(); i++) total += run.spectrumIndex().lengthAt(i);
            long expectedRows = (total + FloatDeltaZstd.BLOCK_SIZE - 1) / FloatDeltaZstd.BLOCK_SIZE;
            assertEquals(expectedRows, rows.size(), "one row per FDZ block");

            long cursor = 0;
            for (java.util.Map<String, Object> r : rows) {
                assertEquals(cursor, ((Number) r.get("value_start")).longValue(),
                    "block value ranges must tile the channel");
                cursor += ((Number) r.get("n_values")).longValue();
            }
            assertEquals(total, cursor, "rows account for every value");

            // Each recorded extent must be exactly one self-describing
            // block: a 5-byte header whose length field accounts for
            // the rest, and a transform within the defined bits.
            for (String ch : run.channelNames()) {
                byte[] raw = (byte[]) rg.openGroup("signal_channels")
                    .openDataset(ch + "_values").readAll();
                for (java.util.Map<String, Object> r : rows) {
                    int off = ((Number) r.get(ch + "_off")).intValue();
                    long len = ((Number) r.get(ch + "_len")).longValue();
                    int bodyLen = (raw[off + 1] & 0xFF) | ((raw[off + 2] & 0xFF) << 8)
                        | ((raw[off + 3] & 0xFF) << 16) | ((raw[off + 4] & 0xFF) << 24);
                    assertEquals(len, 5L + bodyLen, "extent must match the block header");
                    assertEquals(0, raw[off] & ~0x03, "transform must be a defined one");
                    assertEquals(Enums.Compression.FLOAT_DELTA_ZSTD.ordinal(),
                        ((Number) r.get(ch + "_codec")).intValue());
                }
            }
        }
    }
}
