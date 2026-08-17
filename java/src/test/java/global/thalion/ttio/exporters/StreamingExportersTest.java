/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.GenomicStreamWriter;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.importers.MzMLReader;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import htsjdk.samtools.SAMRecord;
import htsjdk.samtools.SamInputResource;
import htsjdk.samtools.SamReader;
import htsjdk.samtools.SamReaderFactory;
import htsjdk.samtools.ValidationStringency;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/** Exporters stream out of a {@code blocks_v1} run and a lazily read
 *  MS run and produce what the whole-run paths produce. */
class StreamingExportersTest {

    static final Path BAM = Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic", "m87_test.bam");
    static final Path SAM = Paths.get("src", "test", "resources", "ttio", "fixtures", "genomic", "m87_test.sam");
    static final File MZML = new File(StreamingExportersTest.class.getClassLoader().getResource("1min.mzML").getPath());

    static Path blocksFile(Path tmp) throws Exception {
        WrittenGenomicRun run = new BamReader(BAM).toGenomicRun("genomic_0001");
        Path out = tmp.resolve("blocks.tio");
        try (StorageProvider p = ProviderRegistry.open(out.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            try (GenomicStreamWriter w = new GenomicStreamWriter(study, "genomic_0001",
                    GenomicStreamWriter.Options.fromRun(run).withBlockPolicy(3, Long.MAX_VALUE))) {
                w.appendBatch(run);
            }
        }
        return out;
    }

    static String md5Lines(List<String> lines) throws Exception {
        List<String> sorted = new ArrayList<>(lines);
        Collections.sort(sorted);
        MessageDigest md = MessageDigest.getInstance("MD5");
        for (String l : sorted) { md.update(l.getBytes(StandardCharsets.UTF_8)); md.update((byte) '\n'); }
        StringBuilder sb = new StringBuilder();
        for (byte b : md.digest()) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    static String sam11FromSamText(Path sam) throws Exception {
        List<String> lines = new ArrayList<>();
        for (String line : Files.readAllLines(sam)) {
            if (line.startsWith("@") || line.isEmpty()) continue;
            String[] c = line.split("\t", 12);
            String[] cols = new String[11];
            System.arraycopy(c, 0, cols, 0, 11);
            if (cols[6].equals("=")) cols[6] = cols[2];
            lines.add(String.join("\t", cols));
        }
        return md5Lines(lines);
    }

    static String sam11FromBam(Path bam) throws Exception {
        List<String> lines = new ArrayList<>();
        try (SamReader r = SamReaderFactory.makeDefault().validationStringency(ValidationStringency.LENIENT)
                .open(SamInputResource.of(bam.toFile()))) {
            for (SAMRecord rec : r) {
                String rnext = rec.getMateReferenceName() == null ? "*" : rec.getMateReferenceName();
                String seq = rec.getReadString();
                String qual = rec.getBaseQualityString();
                lines.add(String.join("\t", rec.getReadName(), Integer.toString(rec.getFlags()),
                    rec.getReferenceName() == null ? "*" : rec.getReferenceName(),
                    Integer.toString(rec.getAlignmentStart()), Integer.toString(rec.getMappingQuality()),
                    rec.getCigarString(), rnext, Integer.toString(rec.getMateAlignmentStart()),
                    Integer.toString(rec.getInferredInsertSize()), seq, qual));
            }
        }
        return md5Lines(lines);
    }

    @Test
    void bamExportFromBlocksMatchesTheSourceSam(@TempDir Path tmp) throws Exception {
        Path f = blocksFile(tmp);
        Path out = tmp.resolve("out.bam");
        try (SpectralDataset ds = SpectralDataset.open(f.toString())) {
            GenomicRun g = ds.genomicRuns().get("genomic_0001");
            new BamWriter(out).write(g, ds.provenanceRecords(), true, null);
        }
        assertEquals(sam11FromSamText(SAM), sam11FromBam(out));
    }

    @Test
    void fastqExportFromBlocksEqualsTheWholeRunExport(@TempDir Path tmp) throws Exception {
        Path f = blocksFile(tmp);
        Path streamed = tmp.resolve("s.fq");
        Path whole = tmp.resolve("w.fq");
        try (SpectralDataset ds = SpectralDataset.open(f.toString())) {
            GenomicRun g = ds.genomicRuns().get("genomic_0001");
            FastqWriter.write(g, streamed, false, 33, null);
            FastqWriter.write(RunSelection.toWritten(g), whole, false, 33, null);
        }
        assertArrayEquals(Files.readAllBytes(whole), Files.readAllBytes(streamed));
        assertTrue(Files.size(streamed) > 0);
    }

    @Test
    void mzmlExportFromLazyRunEqualsTheEagerExport(@TempDir Path tmp) throws Exception {
        AcquisitionRun eager = MzMLReader.read(MZML);
        Path eagerOut = tmp.resolve("eager.mzML");
        MzMLWriter.write(eager, eagerOut.toString(), true, null);
        Path tio = tmp.resolve("ms.tio");
        try (StorageProvider p = ProviderRegistry.open(tio.toString(), StorageProvider.Mode.CREATE, "hdf5")) {
            StorageGroup study = p.rootGroup().createGroup("study");
            MzMLReader.stream(MZML, eager.name(), 5, null).writeInto(study, null);
        }
        Path lazyOut = tmp.resolve("lazy.mzML");
        try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
            AcquisitionRun lazy = ds.msRuns().get(eager.name());
            MzMLWriter.write(lazy, lazyOut.toString(), true, null);
        }
        assertArrayEquals(Files.readAllBytes(eagerOut), Files.readAllBytes(lazyOut));
        AcquisitionRun back = MzMLReader.read(lazyOut.toFile());
        assertEquals(eager.spectrumCount(), back.spectrumCount());
        assertArrayEquals(eager.channels().get("mz"), back.channels().get("mz"), 0.0);
    }
}
