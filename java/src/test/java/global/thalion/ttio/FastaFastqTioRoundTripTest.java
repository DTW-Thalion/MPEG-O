/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio;

import global.thalion.ttio.codecs.TtioRansNative;
import global.thalion.ttio.exporters.FastaWriter;
import global.thalion.ttio.exporters.FastqWriter;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.importers.FastaReader;
import global.thalion.ttio.importers.FastqReader;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Full round-trip tests through the on-disk {@code .tio} container.
 *
 * <p>The other suite ({@code FastaFastqIoTest}) covers the parser
 * and writer in memory only — FASTA/FASTQ → {@link WrittenGenomicRun}
 * → FASTA/FASTQ. This suite drives the full chain that real users hit:</p>
 *
 * <pre>
 *   FASTA / FASTQ
 *     -&gt; reader
 *     -&gt; SpectralDataset.create(...)              [writes .tio]
 *     -&gt; SpectralDataset.open(...)                [reads .tio]
 *     -&gt; writer
 *     -&gt; FASTA / FASTQ                            (compare to input)
 * </pre>
 *
 * <p>Tests are SKIPped when the optional libttio_rans native library
 * is not loadable (genomic-run write requires it for the
 * NAME_TOKENIZED_V2 codec on the read_names channel).</p>
 */
class FastaFastqTioRoundTripTest {

    private static Path write(Path p, String content) throws IOException {
        Files.writeString(p, content, StandardCharsets.UTF_8);
        return p;
    }

    private static Path writeBytes(Path p, byte[] content) throws IOException {
        Files.write(p, content);
        return p;
    }

    // ---------------------------------------------------------------- FASTQ

    @Test
    void fastqToTioToFastqByteExact(@TempDir Path tmp) throws IOException {
        assumeTrue(TtioRansNative.isAvailable(),
            "libttio_rans not available — skipping .tio round-trip");

        Path src = writeBytes(tmp.resolve("src.fq"),
            ("@r1\nACGTACGT\n+\n!!!!!!!!\n"
           + "@r2\nGGGGAAAA\n+\nIIIIJJJJ\n"
           + "@r3\nNNNN\n+\n????\n").getBytes(StandardCharsets.US_ASCII));

        Path tioPath = tmp.resolve("out.tio");
        Path finalFq = tmp.resolve("final.fq");

        // Step 1: FASTQ -> WrittenGenomicRun
        WrittenGenomicRun runIn = new FastqReader(src).read("S1");

        // Step 2: WrittenGenomicRun -> .tio
        SpectralDataset.create(
            tioPath.toString(),
            "", "",
            List.<AcquisitionRun>of(),
            List.of(runIn),
            null, null, null,
            FeatureFlags.defaultCurrent()
        );
        assertTrue(Files.exists(tioPath), ".tio created");
        assertTrue(Files.size(tioPath) > 0, ".tio non-empty");

        // Step 3: open .tio and recover the run
        SpectralDataset ds = SpectralDataset.open(tioPath.toString());
        assertTrue(ds.genomicRuns().containsKey("genomic_0001"),
            "genomic run 'genomic_0001' present");
        GenomicRun runBack = ds.genomicRuns().get("genomic_0001");

        // Step 4: GenomicRun -> FASTQ
        FastqWriter.write(runBack, finalFq);
        ds.close();

        // Step 5: byte-exact round-trip
        assertArrayEquals(
            Files.readAllBytes(src),
            Files.readAllBytes(finalFq),
            "FASTQ bytes survive .tio round-trip exactly"
        );
    }

    @Test
    void fastqToTioPreservesPerReadContent(@TempDir Path tmp) throws IOException {
        assumeTrue(TtioRansNative.isAvailable(),
            "libttio_rans not available — skipping .tio round-trip");

        StringBuilder body = new StringBuilder();
        String[][] expected = new String[][] {
            { "read_0001", "ACGTACGTACGT", "!!!!!!!!!!!!" },
            { "read_0002", "NNNN",         "????"         },
            { "read_0003", "GGGGGGGG",     "IIIIIIII"     },
        };
        for (String[] r : expected) {
            body.append('@').append(r[0]).append('\n')
                .append(r[1]).append("\n+\n")
                .append(r[2]).append('\n');
        }
        Path src = write(tmp.resolve("src.fq"), body.toString());

        Path tioPath = tmp.resolve("out.tio");
        WrittenGenomicRun run = new FastqReader(src).read("");
        SpectralDataset.create(
            tioPath.toString(), "", "",
            List.<AcquisitionRun>of(), List.of(run),
            null, null, null, FeatureFlags.defaultCurrent()
        );

        SpectralDataset ds = SpectralDataset.open(tioPath.toString());
        GenomicRun recovered = ds.genomicRuns().get("genomic_0001");
        assertEquals(expected.length, recovered.readCount());
        for (int i = 0; i < expected.length; i++) {
            AlignedRead r = recovered.readAt(i);
            assertEquals(expected[i][0], r.readName());
            assertEquals(expected[i][1], r.sequence());
            assertArrayEquals(
                expected[i][2].getBytes(StandardCharsets.US_ASCII),
                r.qualities()
            );
        }
        ds.close();
    }

    // ---------------------------------------------------------------- FASTA unaligned

    @Test
    void fastaUnalignedToTioToFasta(@TempDir Path tmp) throws IOException {
        assumeTrue(TtioRansNative.isAvailable(),
            "libttio_rans not available — skipping .tio round-trip");

        Path src = writeBytes(tmp.resolve("panel.fa"),
            ">target_1\nACGTACGTACGT\n>target_2\nGGGGAAAA\n"
                .getBytes(StandardCharsets.US_ASCII));

        Path tioPath = tmp.resolve("out.tio");
        Path finalFa = tmp.resolve("final.fa");

        WrittenGenomicRun runIn = new FastaReader(src).readUnaligned("panel");
        SpectralDataset.create(
            tioPath.toString(), "", "",
            List.<AcquisitionRun>of(), List.of(runIn),
            null, null, null, FeatureFlags.defaultCurrent()
        );

        SpectralDataset ds = SpectralDataset.open(tioPath.toString());
        GenomicRun runBack = ds.genomicRuns().get("genomic_0001");
        FastaWriter.writeRun(runBack, finalFa);
        ds.close();

        // Default 60-char line wrap — short sequences fit on one line each,
        // so the output is byte-identical to the input.
        assertArrayEquals(
            Files.readAllBytes(src),
            Files.readAllBytes(finalFa),
            "FASTA unaligned-run survives .tio round-trip byte-exact"
        );
    }
}
