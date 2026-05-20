/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

/**
 * Progress callback for {@link WorkbenchTransportClient} uploads and
 * downloads. Invoked as bytes are sent / received so callers (the
 * tio-browser transfer view, a CLI progress bar, etc.) can show a
 * determinate progress indicator instead of an indeterminate
 * spinner.
 *
 * <p>Cross-language equivalent: the Python SDK accepts a
 * {@code progress: Callable[[int, int], None]} with the same
 * {@code (bytes_done, bytes_total)} contract.</p>
 *
 * <p>Threading: invoked on the transport client's send/receive
 * thread, NOT the caller's thread. A GUI consumer must marshal to
 * its UI thread (e.g. {@code Platform.runLater}). Implementations
 * must be cheap and must not throw — a throwing callback is
 * swallowed so it cannot abort the transfer.</p>
 */
@FunctionalInterface
public interface TransferProgress {

    /** Sentinel for {@code bytesTotal} when the total is not known
     *  ahead of time (e.g. a filtered/streamed download). Consumers
     *  should show bytes-so-far rather than a percentage. */
    long UNKNOWN_TOTAL = -1L;

    /**
     * @param bytesDone  bytes transferred so far (monotonic).
     * @param bytesTotal total bytes when known, else
     *                   {@link #UNKNOWN_TOTAL}.
     */
    void onProgress(long bytesDone, long bytesTotal);
}
