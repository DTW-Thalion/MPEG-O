/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.genomics.ReferenceImport;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * tio-browser Phase 0 Task 0.10c — round-trip tests for
 * {@link ReferenceImport#writeToDataset(SpectralDataset, boolean)},
 * the public Java write counterpart to Python's
 * {@code ReferenceImport.write_to_dataset} (added in commit
 * {@code 586d6bd}).
 *
 * <p>The method must produce the same on-disk layout
 * (3-level {@code /study/references/<uri>/chromosomes/<name>/data}
 * with {@code @md5}, {@code @reference_uri}, and per-chromosome
 * {@code @length}) that the canonical embed-helper writer
 * (see {@link SpectralDataset#embedReferencesForRuns}) emits and that
 * {@link ReferenceImport#readFromGroup} consumes.</p>
 */
class WriteToDatasetTest {

    @Test
    void writeToDatasetRoundTripsThroughReferences(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("write_round_trip.tio");

        ReferenceImport ri = new ReferenceImport(
            "round-trip-v1",
            List.of("chr1", "chr2"),
            List.of("ACGTACGTACGT".getBytes(), "TTTTAAAACCCC".getBytes()));

        // Create a minimal dataset (no genomic runs => no auto-embed
        // of references) then explicitly write the reference through
        // the new public API. The provider stays open after create()
        // so writeToDataset can navigate /study/references.
        try (SpectralDataset ds = SpectralDataset.create(
                tio.toString(), "ref-test", "REFTEST001",
                List.of(), List.of(),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent())) {
            ri.writeToDataset(ds);
        }

        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            Map<String, ReferenceImport> refs = opened.references();
            assertNotNull(refs, "references() must not return null");
            assertEquals(1, refs.size(), "exactly one embedded reference expected");
            ReferenceImport r = refs.get("round-trip-v1");
            assertNotNull(r, "reference 'round-trip-v1' must be present");
            assertEquals(List.of("chr1", "chr2"), r.chromosomes());
            assertArrayEquals("ACGTACGTACGT".getBytes(), r.chromosome("chr1"));
            assertArrayEquals("TTTTAAAACCCC".getBytes(), r.chromosome("chr2"));
            assertEquals(24L, r.totalBases());
            // MD5 stored verbatim; recompute path also yields the same
            // 16-byte digest for byte-equal content.
            assertArrayEquals(ri.md5(), r.md5(),
                "MD5 must be preserved verbatim from @md5 attribute");
        }
    }

    @Test
    void writeToDatasetRejectsDuplicateUriWithoutOverwrite(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("duplicate_uri.tio");

        ReferenceImport ri = new ReferenceImport(
            "dup-v1",
            List.of("chr1"),
            List.of("ACGT".getBytes()));

        try (SpectralDataset ds = SpectralDataset.create(
                tio.toString(), "ref-test", "REFTEST002",
                List.of(), List.of(),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent())) {
            ri.writeToDataset(ds);
            // Second write with overwrite=false must throw.
            IllegalStateException ex = assertThrows(
                IllegalStateException.class,
                () -> ri.writeToDataset(ds, false),
                "second write of same URI without overwrite must throw");
            assertTrue(ex.getMessage().contains("already embedded"),
                "exception message should mention 'already embedded'; got: "
                    + ex.getMessage());
        }
    }

    @Test
    void writeToDatasetOverwriteReplacesExistingReference(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("overwrite.tio");

        ReferenceImport ri1 = new ReferenceImport(
            "overwrite-v1",
            List.of("chr1"),
            List.of("AAAA".getBytes()));

        ReferenceImport ri2 = new ReferenceImport(
            "overwrite-v1",  // same URI
            List.of("chr1", "chr2"),
            List.of("CCCC".getBytes(), "GGGG".getBytes()));

        try (SpectralDataset ds = SpectralDataset.create(
                tio.toString(), "ref-test", "REFTEST003",
                List.of(), List.of(),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent())) {
            ri1.writeToDataset(ds);
            // Overwrite with a different content under the same URI.
            ri2.writeToDataset(ds, true);
        }

        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            Map<String, ReferenceImport> refs = opened.references();
            assertEquals(1, refs.size());
            ReferenceImport r = refs.get("overwrite-v1");
            assertNotNull(r);
            assertEquals(List.of("chr1", "chr2"), r.chromosomes());
            assertArrayEquals("CCCC".getBytes(), r.chromosome("chr1"));
            assertArrayEquals("GGGG".getBytes(), r.chromosome("chr2"));
            assertArrayEquals(ri2.md5(), r.md5(),
                "after overwrite, MD5 must reflect the new content");
        }
    }
}
