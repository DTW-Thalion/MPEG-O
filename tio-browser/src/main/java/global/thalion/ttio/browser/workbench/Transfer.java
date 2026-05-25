/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.browser.progress.ProgressReport;
import javafx.beans.property.LongProperty;
import javafx.beans.property.ObjectProperty;
import javafx.beans.property.SimpleLongProperty;
import javafx.beans.property.SimpleObjectProperty;
import javafx.beans.property.SimpleStringProperty;
import javafx.beans.property.StringProperty;

import java.util.Map;
import java.util.UUID;

/**
 * Mutable entry in the {@link TransferManager}'s queue. JavaFX
 * properties drive the {@link global.thalion.ttio.browser.shell.workspaces.TransfersWorkspace}
 * table cells.
 *
 * <p>The transfer-kind / URI / payload-size are fixed at
 * construction; the state / bytes-transferred / error-message
 * mutate as the worker thread reports progress.</p>
 */
public final class Transfer {

    private final String id;
    private final TransferKind kind;
    private final String containerUri;
    private final String localPath;
    private final long sizeBytes;
    private final Map<String, Object> filter;

    private final ObjectProperty<TransferState> state =
        new SimpleObjectProperty<>(TransferState.PENDING);
    private final LongProperty bytesTransferred = new SimpleLongProperty(0);
    private final StringProperty message = new SimpleStringProperty("");

    private volatile ProgressListener progressListener;
    private volatile ProgressReport lastReport;

    private final long createdAtEpochMs = System.currentTimeMillis();
    private volatile Long finishedAtEpochMs;

    public Transfer(TransferKind kind, String containerUri,
                     String localPath, long sizeBytes,
                     Map<String, Object> filter) {
        this.id           = UUID.randomUUID().toString();
        this.kind         = kind;
        this.containerUri = containerUri;
        this.localPath    = localPath;
        this.sizeBytes    = sizeBytes;
        this.filter       = filter == null ? Map.of() : Map.copyOf(filter);
    }

    public String       id()           { return id; }
    public TransferKind kind()         { return kind; }
    public String       containerUri() { return containerUri; }
    public String       localPath()    { return localPath; }
    public long         sizeBytes()    { return sizeBytes; }
    public Map<String, Object> filter() { return filter; }

    public ObjectProperty<TransferState> stateProperty()  { return state; }
    public LongProperty bytesTransferredProperty()         { return bytesTransferred; }
    public StringProperty messageProperty()                 { return message; }

    public TransferState state()         { return state.get(); }
    public long bytesTransferred()        { return bytesTransferred.get(); }
    public String message()               { return message.get(); }

    void setState(TransferState s) {
        this.state.set(s);
        if (finishedAtEpochMs == null
            && (s == TransferState.COMPLETED || s == TransferState.FAILED)) {
            finishedAtEpochMs = System.currentTimeMillis();
        }
    }
    void setBytesTransferred(long n)      { this.bytesTransferred.set(n); }
    void setMessage(String m)             { this.message.set(m == null ? "" : m); }

    /** Set a listener that receives {@link ProgressReport} snapshots on the transport thread. */
    public void setProgressListener(ProgressListener listener) {
        this.progressListener = listener;
    }

    /** The listener registered via {@link #setProgressListener}, or {@code null}. */
    public ProgressListener progressListener() { return progressListener; }

    /** The most-recent {@link ProgressReport} sampled for this transfer, or {@code null}. */
    public ProgressReport lastReport() { return lastReport; }

    /** Package-private: called by {@link TransferManager} on the transport thread. */
    void setLastReport(ProgressReport r) { this.lastReport = r; }

    /** Human-readable label for the queue-view "kind" column. */
    public String kindLabel() {
        return kind == TransferKind.UPLOAD ? "Upload" : "Download";
    }

    /** Epoch ms when this Transfer was constructed (queued). */
    public long createdAtEpochMs() { return createdAtEpochMs; }

    /** Epoch ms when state first transitioned to a terminal value
     *  (COMPLETED or FAILED), or {@code null} if not yet finished. */
    public Long finishedAtEpochMs() { return finishedAtEpochMs; }

    /** Formats an epoch-ms timestamp as a local-time HH:mm:ss string,
     *  or "—" if null. */
    public static String formatTimestamp(Long epochMs) {
        if (epochMs == null) return "—";
        return java.time.LocalTime.ofInstant(
            java.time.Instant.ofEpochMilli(epochMs),
            java.time.ZoneId.systemDefault())
            .format(java.time.format.DateTimeFormatter.ofPattern("HH:mm:ss"));
    }
}
