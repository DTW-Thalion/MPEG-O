/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.genomics.ReferenceImport;
import global.thalion.ttio.genomics.WrittenGenomicRun;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * tio-browser Phase 0 Task 0.1 — failing test for the additive
 * read-back accessor {@code SpectralDataset.references()} on the Java
 * library.
 *
 * <p>The library already writes embedded references at
 * {@code /study/references/<uri>/} when a {@link WrittenGenomicRun} is
 * built with {@code embedReference=true} and a non-null
 * {@code referenceChromSeqs} map (see {@link SpectralDataset}'s
 * {@code embedReferencesForRuns}). What is missing is a public
 * read-back path: this test drives that addition.</p>
 *
 * <p>Phase 0 Task 0.2 implements
 * {@code ReferenceImport.readFromGroup(StorageGroup)}; Task 0.3 adds
 * {@code SpectralDataset.references()}. Both are needed for the two
 * tests below to compile and pass.</p>
 *
 * <p>Test isolation note: a {@link WrittenGenomicRun} with zero reads
 * but {@code embedReference=true} and {@code referenceChromSeqs}
 * populated triggers the embed-references writer (which only checks
 * the embed flags, signal-compression, and codec-override surface) yet
 * skips the native ref-diff-v2 encode (no reads → no chromosome
 * inferred → BASE_PACK fallback on empty bytes). This keeps the test
 * runnable without the JNI rANS native library.</p>
 */
class ReferencesAccessorTest {

    @Test
    void freshlyOpenedDatasetExposesEmbeddedReferences(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("with_refs.tio");

        Map<String, byte[]> refSeqs = new LinkedHashMap<>();
        refSeqs.put("chr1", "ACGTACGTACGT".getBytes());
        refSeqs.put("chr2", "TTTTAAAACCCC".getBytes());

        // An empty-read run with embedReference=true is enough to
        // populate /study/references/<uri>/ without triggering the
        // native ref-diff-v2 encode. The 21-arg ctor is the M93 form
        // (no provenance, no bulk-v2 blobs).
        WrittenGenomicRun run = new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "test-ref-v1",
            "ILLUMINA",
            "REF_TEST",
            new long[0], new byte[0], new int[0],
            new byte[0], new byte[0],
            new long[0], new int[0],
            List.of(), List.of(), List.of(),
            new long[0], new int[0],
            List.of(),
            Compression.ZLIB, Map.of(), List.of(),
            true, refSeqs, null);

        SpectralDataset.create(tio.toString(), "ref-test", "REFTEST001",
            List.of(), List.of(run),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            Map<String, ReferenceImport> refs = opened.references();
            assertNotNull(refs, "references() must not return null");
            assertEquals(1, refs.size(), "exactly one embedded reference expected");
            ReferenceImport r = refs.get("test-ref-v1");
            assertNotNull(r, "reference 'test-ref-v1' must be present");
            // The embed writer sorts chromosome names alphabetically
            // before persisting, so the read-back order is alphabetic.
            assertEquals(List.of("chr1", "chr2"), r.chromosomes());
            assertArrayEquals("ACGTACGTACGT".getBytes(), r.chromosome("chr1"));
            assertArrayEquals("TTTTAAAACCCC".getBytes(), r.chromosome("chr2"));
            assertEquals(24L, r.totalBases());
        }
    }

    @Test
    void datasetWithNoReferencesReturnsEmptyMap(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("no_refs.tio");
        SpectralDataset.create(tio.toString(), "no-ref", "NOREF001",
            List.of(), List.of(),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            Map<String, ReferenceImport> refs = opened.references();
            assertNotNull(refs);
            assertTrue(refs.isEmpty());
        }
    }
}
