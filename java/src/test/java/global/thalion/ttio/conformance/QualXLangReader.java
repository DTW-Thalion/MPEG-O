/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.GenomicRun;

/**
 * Qualities V5 cross-language reader helper: opens a .tio, takes the
 * first genomic run, concatenates the qualities of its first 3 reads
 * (decoding through the codec-12 dispatch, V4 or V5), and prints one
 * JSON line:
 *
 *   {"read_count": N, "qualities_hex": "..."}
 *
 * Usage: QualXLangReader &lt;in.tio&gt;
 */
public final class QualXLangReader {

    private QualXLangReader() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: QualXLangReader <in.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            String name = ds.genomicRuns().keySet().stream().sorted()
                    .findFirst().orElseThrow();
            GenomicRun gr = ds.genomicRuns().get(name);
            StringBuilder hex = new StringBuilder();
            for (int i = 0; i < 3; i++) {
                for (byte b : gr.readAt(i).qualities()) {
                    hex.append(String.format("%02x", b));
                }
            }
            System.out.println("{\"read_count\":" + gr.readCount()
                    + ",\"qualities_hex\":\"" + hex + "\"}");
        }
    }
}
