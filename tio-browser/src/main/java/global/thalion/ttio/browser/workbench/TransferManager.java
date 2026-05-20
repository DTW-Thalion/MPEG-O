/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.WorkbenchClient;
import global.thalion.ttio.workbench.transport.TransferProgress;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.OutputMode;
import global.thalion.ttio.workbench.transport.WorkbenchTransportClient;
import javafx.application.Platform;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Observable in-memory queue of upload / download transfers.
 *
 * <p>Drives the W1 {@link WorkbenchTransportClient} from a daemon
 * thread pool; each {@link Transfer} carries JavaFX properties so
 * {@link TransferQueueView} cells re-render automatically as the
 * worker reports state.</p>
 *
 * <p>v1.0 scope: fire-and-forget. The W1 client does not expose a
 * cancellation primitive, so the queue tolerates outstanding
 * tasks at shutdown by letting the daemon executor's
 * {@code shutdownNow} interrupt them; pending transfers are
 * dropped.</p>
 */
public final class TransferManager {

    private static final TransferManager INSTANCE = new TransferManager();

    /** Process-wide singleton (one queue per running tio-browser). */
    public static TransferManager instance() { return INSTANCE; }

    /** Visible for tests. */
    public TransferManager() {
        this.executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "ttio-transfer-"
                + threadCounter.incrementAndGet());
            t.setDaemon(true);
            return t;
        });
    }

    private final ObservableList<Transfer> transfers =
        FXCollections.observableArrayList();
    private final ExecutorService executor;
    private final AtomicInteger threadCounter = new AtomicInteger(0);

    /** Backing list for {@link TransferQueueView}. */
    public ObservableList<Transfer> transfers() { return transfers; }

    /** Enqueue an upload of {@code source} into {@code project} at
     *  {@code containerUri}. Returns the queued transfer. */
    public Transfer enqueueUpload(WorkbenchClient client,
                                    String project,
                                    String containerUri,
                                    Path source) {
        long size;
        try { size = Files.size(source); }
        catch (Exception e) { size = -1L; }
        Transfer t = new Transfer(TransferKind.UPLOAD, containerUri,
            source.toString(), size, Map.of());
        addToQueue(t);
        executor.submit(() -> runUpload(client, project, containerUri,
                                          source, t));
        return t;
    }

    /** Enqueue a download from {@code containerUri} to
     *  {@code destination}. {@code filter} may be empty for an
     *  unfiltered fetch. */
    public Transfer enqueueDownload(WorkbenchClient client,
                                      String containerUri,
                                      Path destination,
                                      Map<String, Object> filter) {
        Transfer t = new Transfer(TransferKind.DOWNLOAD, containerUri,
            destination.toString(), 0, filter);
        addToQueue(t);
        executor.submit(() -> runDownload(client, containerUri,
                                            destination, filter, t));
        return t;
    }

    /** Stop the executor. Outstanding tasks are interrupted; pending
     *  ones are dropped. Idempotent. */
    public void shutdown() {
        executor.shutdownNow();
    }

    // ---- internals ----

    private void addToQueue(Transfer t) {
        if (Platform.isFxApplicationThread()) {
            transfers.add(t);
        } else {
            Platform.runLater(() -> transfers.add(t));
        }
    }

    private void runUpload(WorkbenchClient client,
                            String project,
                            String containerUri,
                            Path source,
                            Transfer t) {
        try {
            setState(t, TransferState.RUNNING, "Uploading...");
            byte[] payload = Files.readAllBytes(source);
            WorkbenchTransportClient.UploadResult result =
                client.upload(project, containerUri, payload,
                              progressFor(t, "Uploading"));
            setBytes(t, payload.length);
            setState(t, TransferState.COMPLETED,
                "Uploaded " + result.containerUri()
                + " (au_seq=" + result.lastAckedAuSequence() + ")");
        } catch (Throwable ex) {
            setState(t, TransferState.FAILED,
                ex.getMessage() == null ? ex.getClass().getSimpleName()
                                          : ex.getMessage());
        }
    }

    private void runDownload(WorkbenchClient client,
                              String containerUri,
                              Path destination,
                              Map<String, Object> filter,
                              Transfer t) {
        try {
            setState(t, TransferState.RUNNING, "Downloading...");
            TransferProgress progress = progressFor(t, "Downloading");
            WorkbenchTransportClient.DownloadResult result;
            if (filter == null || filter.isEmpty()) {
                result = client.download(containerUri, progress);
            } else {
                result = client.download(containerUri, filter,
                    OutputMode.BINARY, 0, progress);
            }
            Files.write(destination, result.payload());
            setBytes(t, result.payload().length);
            setState(t, TransferState.COMPLETED,
                "Saved " + result.payload().length + " bytes to "
                + destination);
        } catch (Throwable ex) {
            setState(t, TransferState.FAILED,
                ex.getMessage() == null ? ex.getClass().getSimpleName()
                                          : ex.getMessage());
        }
    }

    /** Build a progress callback that drives {@code t}'s byte count
     *  + message. The transport thread fires this per chunk; we
     *  coalesce onto the FX thread (at most one pending update) so a
     *  fast transfer can't flood the event loop. */
    private static TransferProgress progressFor(Transfer t, String verb) {
        AtomicLong latest = new AtomicLong(0);
        AtomicBoolean scheduled = new AtomicBoolean(false);
        return (done, total) -> {
            latest.set(done);
            if (scheduled.compareAndSet(false, true)) {
                Platform.runLater(() -> {
                    scheduled.set(false);
                    long n = latest.get();
                    t.setBytesTransferred(n);
                    long size = t.sizeBytes();
                    if (size > 0) {
                        long pct = Math.min(100, n * 100 / size);
                        t.setMessage(verb + "... " + pct + "%");
                    } else {
                        t.setMessage(verb + "... " + humanBytes(n));
                    }
                });
            }
        };
    }

    private static String humanBytes(long n) {
        if (n < 1024) return n + " B";
        if (n < 1024 * 1024) return (n / 1024) + " KB";
        if (n < 1024L * 1024 * 1024) return (n / (1024 * 1024)) + " MB";
        return (n / (1024L * 1024 * 1024)) + " GB";
    }

    private static void setState(Transfer t, TransferState s, String msg) {
        Runnable r = () -> { t.setState(s); t.setMessage(msg); };
        if (Platform.isFxApplicationThread()) r.run();
        else Platform.runLater(r);
    }

    private static void setBytes(Transfer t, long n) {
        if (Platform.isFxApplicationThread()) t.setBytesTransferred(n);
        else Platform.runLater(() -> t.setBytesTransferred(n));
    }
}
