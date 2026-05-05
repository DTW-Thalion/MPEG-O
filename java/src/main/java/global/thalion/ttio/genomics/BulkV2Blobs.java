/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import java.util.List;
import java.util.Objects;

/**
 * Phase 2c-T (v1.0): verbatim v2 codec blobs for direct on-disk
 * write. Set on a {@link WrittenGenomicRun} via the bulk-mode
 * constructor or {@link WrittenGenomicRun#withBulkV2Blobs} to
 * bypass the v2 codec encode step in the writer and write the
 * blob bytes directly to the matching HDF5 paths. Used by the
 * transport bulk-mode receiver (see
 * {@code docs/transport-spec.md} §6.4).
 *
 * <p>Each field is independently optional. When
 * {@code mateInfoBlob} is set, {@code mateInfoChromNames} MUST also
 * be supplied. {@code refDiffBlob} requires
 * {@code refDiffReferenceUri} which the writer validates against
 * the run's {@code referenceUri}.
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.written_genomic_run.BulkV2Blobs}, Objective-C
 * {@code TTIOBulkV2Blobs}.
 */
public record BulkV2Blobs(
    byte[] mateInfoBlob,
    List<String> mateInfoChromNames,
    byte[] nameTokBlob,
    byte[] refDiffBlob,
    String refDiffReferenceUri
) {
    public BulkV2Blobs {
        if (mateInfoBlob != null) {
            Objects.requireNonNull(mateInfoChromNames,
                "mateInfoBlob requires mateInfoChromNames");
            mateInfoChromNames = List.copyOf(mateInfoChromNames);
        }
        if (refDiffBlob != null) {
            Objects.requireNonNull(refDiffReferenceUri,
                "refDiffBlob requires refDiffReferenceUri");
        }
    }
}
