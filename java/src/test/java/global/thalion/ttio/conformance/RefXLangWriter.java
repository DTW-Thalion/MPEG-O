/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;

import java.util.List;

/**
 * Standalone CLI helper that writes the canonical embedded-reference
 * fixture to a single {@code .tio} file.
 *
 * <p>Drives the production writable-open path (M100): create a
 * minimal dataset, close it, reopen it with
 * {@link SpectralDataset#open(String, boolean)}, then embed the
 * reference through
 * {@link ReferenceImport#writeToDataset(SpectralDataset)} — the
 * same three steps as the Python and Objective-C writers.
 * {@code writeToDataset}
 * goes purely through the {@code StorageProvider} abstraction; no
 * native FQZCOMP needed, because the only-references-no-runs case
 * never traverses the genomic-run quality codec.</p>
 *
 * <p>Usage: {@code java ... RefXLangWriter <out.tio>}.
 */
public final class RefXLangWriter {

    private RefXLangWriter() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: RefXLangWriter <out.tio>");
            System.exit(2);
        }
        String outPath = args[0];

        ReferenceImport ri = new ReferenceImport(
            "xlang-test-v1",
            List.of("chr1", "chr2"),
            List.of("ACGTACGTACGT".getBytes(), "TTTTAAAACCCC".getBytes()));

        // Seed a minimal dataset, then embed through the writable
        // reopen — the M100 production path.
        try (SpectralDataset seed = SpectralDataset.create(
                outPath, "xlang", "XLANG001",
                List.of(), List.of(),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent())) {
            // created empty; closed by try-with-resources
        }
        try (SpectralDataset ds = SpectralDataset.open(outPath, true)) {
            ri.writeToDataset(ds);
        }
    }
}
