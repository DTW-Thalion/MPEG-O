/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import java.util.OptionalInt;

/**
 * Base class for workbench-transport client failures. Subclasses
 * distinguish handshake-time failures, mid-stream upload failures,
 * and mid-stream download failures.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.transport.errors.TransportError}.</p>
 */
public class WorkbenchTransportException extends RuntimeException {

    private final OptionalInt closeCode;
    private final String reason;

    public WorkbenchTransportException(String message) {
        super(message);
        this.closeCode = OptionalInt.empty();
        this.reason = null;
    }

    public WorkbenchTransportException(String message, Throwable cause) {
        super(message, cause);
        this.closeCode = OptionalInt.empty();
        this.reason = null;
    }

    public WorkbenchTransportException(String message,
                                         OptionalInt closeCode,
                                         String reason) {
        super(message);
        this.closeCode = closeCode;
        this.reason = reason;
    }

    public WorkbenchTransportException(String message, Throwable cause,
                                         OptionalInt closeCode,
                                         String reason) {
        super(message, cause);
        this.closeCode = closeCode;
        this.reason = reason;
    }

    public OptionalInt closeCode() { return closeCode; }
    public String reason() { return reason; }

    /** Handshake-time failure (WS open, first-frame send, post-handshake ack). */
    public static class Handshake extends WorkbenchTransportException {
        public Handshake(String message) { super(message); }
        public Handshake(String message, Throwable cause) { super(message, cause); }
        public Handshake(String message, OptionalInt closeCode, String reason) {
            super(message, closeCode, reason);
        }
    }

    /** Upload failed mid-stream. */
    public static class Upload extends WorkbenchTransportException {
        private final long lastAckedAuSequence;
        private final String resumeHandle;
        public Upload(String message,
                      OptionalInt closeCode, String reason,
                      long lastAckedAuSequence, String resumeHandle) {
            super(message, closeCode, reason);
            this.lastAckedAuSequence = lastAckedAuSequence;
            this.resumeHandle = resumeHandle;
        }
        public long lastAckedAuSequence() { return lastAckedAuSequence; }
        public String resumeHandle() { return resumeHandle; }
    }

    /** Download failed mid-stream (cross-project, container missing, etc.). */
    public static class Download extends WorkbenchTransportException {
        public Download(String message,
                        OptionalInt closeCode, String reason) {
            super(message, closeCode, reason);
        }
    }
}
