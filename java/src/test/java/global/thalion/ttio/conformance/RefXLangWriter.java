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
 * tio-browser Phase 0 Task 0.6 — standalone CLI helper that writes the
 * canonical embedded-reference fixture to a single {@code .tio} file.
 *
 * <p>Phase 0 Task 0.12 (tio-browser) upgrades this helper from the
 * direct-graft pattern (used in Task 0.6) to the production
 * {@link ReferenceImport#writeToDataset(SpectralDataset)} entry
 * point added in Task 0.10c. {@link SpectralDataset#create} returns
 * an open writable dataset; {@code writeToDataset} writes the
 * canonical {@code /study/references/<uri>/} subtree purely through
 * the {@code StorageProvider} abstraction — no native FQZCOMP needed,
 * because the only-references-no-runs case never traverses the
 * genomic-run quality codec.</p>
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

        // Production writer path: create() returns an open writable
        // dataset; writeToDataset embeds /study/references/<uri>/.
        // No genomic runs → FQZCOMP_NX16_Z gate never fires.
        try (SpectralDataset ds = SpectralDataset.create(
                outPath, "xlang", "XLANG001",
                List.of(), List.of(),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent())) {
            ri.writeToDataset(ds);
        }
    }
}
