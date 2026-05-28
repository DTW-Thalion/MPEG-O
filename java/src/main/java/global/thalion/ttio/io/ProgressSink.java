/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.io;

/**
 * Receives progress updates from long-running SDK readers + writers.
 *
 * <p>Implementations should be cheap and non-blocking; they may be
 * called many times per second from the worker thread. Callers
 * needing to update JavaFX state should wrap in
 * {@code Platform.runLater(...)} or buffer/coalesce upstream.</p>
 *
 * <p>{@code total} is {@code -1} when the producer can't predict the
 * final count (e.g. streaming reads with no header). {@code done}
 * is always monotonically non-decreasing within a single operation.
 * Producers fire at meaningful chunk boundaries (per chromosome,
 * per N reads, per spectrum) — not per byte — to keep the rate
 * manageable.</p>
 */
@FunctionalInterface
public interface ProgressSink {

    /** Notify a progress update.
     *
     * @param done  records (chromosomes / reads / spectra) processed so far
     * @param total expected total, or {@code -1} when unknown
     */
    void onProgress(long done, long total);

    /** A no-op sink. Use when a caller doesn't care about progress;
     *  saves a null check at every emit site. */
    static ProgressSink discard() {
        return (done, total) -> {};
    }
}
