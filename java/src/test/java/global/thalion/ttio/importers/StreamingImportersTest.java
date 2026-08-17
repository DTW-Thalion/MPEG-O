/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.GenomicBlocks;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** The batch iterators and stream sources of the BAM, FASTQ and mzML
 *  importers, and their write-through in {@link ImportedDataset}. */
class StreamingImportersTest {

    static final Path BAM = Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic", "m87_test.bam");
    static final File MZML = new File(StreamingImportersTest.class.getClassLoader().getResource("1min.mzML").getPath());

    @Test
    void bamBatchesConcatenateToTheWholeRun() throws Exception {
        BamReader r = new BamReader(BAM);
        WrittenGenomicRun whole = r.toGenomicRun("g");
        List<WrittenGenomicRun> parts = new ArrayList<>();
        Iterator<WrittenGenomicRun> it = r.iterBatches("g", null, null, 3);
        it.forEachRemaining(parts::add);
        assertEquals(4, parts.size());
        WrittenGenomicRun back = GenomicBlocks.concatRuns(parts);
        assertEquals(whole.readNames(), back.readNames());
        assertArrayEquals(whole.sequences(), back.sequences());
        assertArrayEquals(whole.qualities(), back.qualities());
        assertEquals(whole.chromosomes(), back.chromosomes());
        assertEquals(whole.referenceUri(), parts.get(0).referenceUri());
        assertEquals(whole.sampleName(), parts.get(0).sampleName());
        assertEquals(r.lastProvenance().size(), parts.get(0).provenanceRecords().size());
    }

    static Path fastq(Path tmp, int n) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) {
            sb.append("@r").append(i).append(" extra\n").append("ACGT".repeat(5 + (i % 3))).append("\n+\n")
              .append("#II5".repeat(5 + (i % 3))).append("\n");
        }
        Path p = tmp.resolve("reads.fq");
        Files.writeString(p, sb.toString(), StandardCharsets.ISO_8859_1);
        return p;
    }

    @Test
    void fastqBatchesConcatenateToTheWholeRun(@TempDir Path tmp) throws Exception {
        Path fq = fastq(tmp, 11);
        WrittenGenomicRun whole = new FastqReader(fq).read("s");
        FastqReader r = new FastqReader(fq);
        List<WrittenGenomicRun> parts = new ArrayList<>();
        r.iterBatches("s", "", "", global.thalion.ttio.Enums.AcquisitionMode.GENOMIC_WGS, 4).forEachRemaining(parts::add);
        assertEquals(3, parts.size());
        WrittenGenomicRun back = GenomicBlocks.concatRuns(parts);
        assertEquals(whole.readNames(), back.readNames());
        assertArrayEquals(whole.sequences(), back.sequences());
        assertArrayEquals(whole.qualities(), back.qualities());
        assertArrayEquals(whole.lengths(), back.lengths());
        assertEquals(33, r.detectedPhredOffset());
    }

    @Test
    void mzmlStreamMatchesWholeRead(@TempDir Path tmp) throws Exception {
        AcquisitionRun whole = MzMLReader.read(MZML);
        SpectralStreamSource src = MzMLReader.stream(MZML, "run_0001", 5, null);
        Path out = tmp.resolve("s.tio");
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            assertEquals(whole.spectrumCount(), src.writeInto(study, null));
        }
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            AcquisitionRun got = ds.msRuns().get("run_0001");
            assertEquals(whole.spectrumCount(), got.spectrumCount());
            assertArrayEquals(whole.channels().get("mz"), got.channels().get("mz"), 0.0);
            assertArrayEquals(whole.channels().get("intensity"), got.channels().get("intensity"), 0.0);
            assertArrayEquals(whole.spectrumIndex().msLevels(), got.spectrumIndex().msLevels());
            assertArrayEquals(whole.spectrumIndex().retentionTimes(), got.spectrumIndex().retentionTimes(), 0.0);
            assertEquals(whole.chromatograms().size(), got.chromatograms().size());
        }
    }

    @Test
    void mzmlStreamClosedEarlyStopsTheProducer() {
        SpectralStreamSource src = MzMLReader.stream(MZML, "run_0001", 3, null);
        Iterator<global.thalion.ttio.WrittenSpectralBatch> it = src.batches().get();
        assertTrue(it.hasNext());
        it.next();
        ((AutoCloseable) it).getClass();
        try { ((AutoCloseable) it).close(); } catch (Exception e) { fail(e); }
    }

    @Test
    void importedDatasetWritesStreams(@TempDir Path tmp) throws Exception {
        ImportedDataset d = new ImportedDataset();
        d.genomicStreams.put("genomic_0001", new BamReader(BAM).stream("genomic_0001", null, null, null, false, 3)
            .withPolicy(4, null, false));
        d.spectralStreams.put("run_0001", MzMLReader.stream(MZML, "run_0001", 5, null));
        Path out = d.write(tmp.resolve("d.tio"));
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            GenomicRun g = ds.genomicRuns().get("genomic_0001");
            assertEquals("blocks_v1", g.layout());
            assertEquals(10, g.readCount());
            assertTrue(g.blockCount() >= 3);
            AcquisitionRun run = ds.msRuns().get("run_0001");
            assertEquals(MzMLReader.read(MZML).spectrumCount(), run.spectrumCount());
        }
    }

    @Test
    void importerRegistryEncodesBamThroughStreams(@TempDir Path tmp) throws Exception {
        Path out = tmp.resolve("r.tio");
        ImporterRegistry.encode("bam", List.of(BAM.toString()), out, Map.of("block_reads", "3"));
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            GenomicRun g = ds.genomicRuns().values().iterator().next();
            assertEquals("blocks_v1", g.layout());
            assertEquals(10, g.readCount());
        }
        Path legacy = tmp.resolve("l.tio");
        ImporterRegistry.encode("bam", List.of(BAM.toString()), legacy, Map.of("legacy_whole_channel", "1"));
        try (SpectralDataset ds = SpectralDataset.open(legacy.toString())) {
            assertEquals("whole", ds.genomicRuns().values().iterator().next().layout());
        }
        Path mz = tmp.resolve("m.tio");
        ImporterRegistry.encode("mzml", List.of(MZML.getPath()), mz, Map.of());
        try (SpectralDataset ds = SpectralDataset.open(mz.toString())) {
            assertEquals(1, ds.msRuns().size());
        }
    }
}
