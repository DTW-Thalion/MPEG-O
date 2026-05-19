/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

/**
 * Resume bookkeeping for a partial workbench upload.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.transport.resume.ResumeState}.</p>
 *
 * @param resumeHandle          opaque server-issued handle
 *                               ({@code stg-<uuid>}). Retained for
 *                               24 hours after last activity by the
 *                               daemon's staging GC.
 * @param lastAckedAuSequence   highest {@code au_sequence} the
 *                               client observed in a per-AU ack
 *                               during the prior attempt. The daemon
 *                               replays from {@code +1}; client must
 *                               NOT re-send AUs at or below this value.
 *                               {@code -1} = no AU was ack'd yet.
 */
public record ResumeState(String resumeHandle, long lastAckedAuSequence) {

    public ResumeState {
        if (resumeHandle == null || resumeHandle.isEmpty()) {
            throw new IllegalArgumentException("resumeHandle required");
        }
    }

    /** Fresh resume state with no AU yet acknowledged. */
    public static ResumeState fresh(String resumeHandle) {
        return new ResumeState(resumeHandle, -1L);
    }
}
