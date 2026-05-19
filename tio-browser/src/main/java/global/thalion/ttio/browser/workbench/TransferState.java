/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

/**
 * State of a {@link Transfer} entry in the
 * {@link TransferManager}'s queue.
 *
 * <p>v1.0 state machine: {@code PENDING -> RUNNING ->
 * (COMPLETED | FAILED)}. The W1 {@code WorkbenchTransportClient}
 * does not expose progress callbacks (uploads / downloads block
 * until completion), so the queue view shows indeterminate
 * progress while RUNNING and a final outcome cell otherwise.</p>
 *
 * <p>{@code PAUSED} and {@code CANCELLED} are reserved for a
 * follow-up once the transport client gains a cancellation
 * primitive.</p>
 */
public enum TransferState {
    PENDING,
    RUNNING,
    COMPLETED,
    FAILED;

    public boolean isTerminal() {
        return this == COMPLETED || this == FAILED;
    }
}
