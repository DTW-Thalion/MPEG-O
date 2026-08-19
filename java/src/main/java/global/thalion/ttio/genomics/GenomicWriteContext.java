/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import java.util.Map;

/**
 * Writer state shared across the blocks of one {@code blocks_v1} run
 * (format-spec 10.12): the chromosome-name to id map, which grows in
 * place as blocks are written so ids are stable across blocks, and the
 * reference MD5 computed once per run. {@link #none()} gives the
 * per-run behaviour of the whole-channel writer.
 *
 * @param chromNameToId shared map, mutated by the writer; {@code null}
 *                      means assign ids per run
 * @param referenceMd5  precomputed reference digest; {@code null} means
 *                      compute from the run's reference
 * @param qualStrategyHint qualities strategy for FQZCOMP_NX16_Z blocks:
 *                      -1 auto (the 3-way tune), 5/6 forced V5,
 *                      {@link global.thalion.ttio.codecs.FqzcompNx16Z#HINT_V4_AUTO}
 *                      V4 with internal preset selection; the stream
 *                      writer passes its per-run pin
 */
public record GenomicWriteContext(Map<String, Integer> chromNameToId,
                                  byte[] referenceMd5,
                                  int qualStrategyHint) {

    public GenomicWriteContext(Map<String, Integer> chromNameToId,
                               byte[] referenceMd5) {
        this(chromNameToId, referenceMd5, -1);
    }

    /** No shared state: the whole-channel writer's behaviour. */
    public static GenomicWriteContext none() {
        return new GenomicWriteContext(null, null, -1);
    }
}
