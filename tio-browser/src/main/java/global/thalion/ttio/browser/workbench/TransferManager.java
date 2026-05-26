/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.progress.ProgressTracker;
import global.thalion.ttio.workbench.WorkbenchClient;
import global.thalion.ttio.workbench.transport.TransferProgress;
import global.thalion.ttio.workbench.transport.WorkbenchHandshake.OutputMode;
import global.thalion.ttio.workbench.transport.WorkbenchTransportClient;
import global.thalion.ttio.browser.transport.DownloadTask;
import global.thalion.ttio.browser.transport.UploadTask;
import javafx.application.Platform;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
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
 * {@link global.thalion.ttio.browser.shell.workspaces.TransfersWorkspace}
 * cells re-render automatically as the worker reports state.</p>
 *
 * <p>v1.0 scope: fire-and-forget. The W1 client does not expose a
 * cancellation primitive, so the queue tolerates outstanding
 * tasks at shutdown by letting the daemon executor's
 * {@code shutdownNow} interrupt them; pending transfers are
 * dropped.</p>
 */
public final class TransferManager {

    /**
     * Callback fired whenever the transfer queue changes (items added,
     * state transitions to COMPLETED or FAILED). Invoked on the
     * JavaFX application thread.
     */
    public interface QueueListener {
        void onQueueChanged();
    }

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
        this.transfers.addListener(
            (javafx.collections.ListChangeListener<Transfer>) change ->
                queueListeners.forEach(QueueListener::onQueueChanged));
    }

    private final ObservableList<Transfer> transfers =
        FXCollections.observableArrayList();
    private final ExecutorService executor;
    private final AtomicInteger threadCounter = new AtomicInteger(0);

    private final List<QueueListener> queueListeners = new CopyOnWriteArrayList<>();
    private final List<ProgressListener> progressListeners = new CopyOnWriteArrayList<>();

    /** Register a listener that is called whenever the queue list changes. */
    public void addQueueListener(QueueListener l) { queueListeners.add(l); }

    /** Register a listener that receives every {@link global.thalion.ttio.browser.progress.ProgressReport}
     *  emitted across all active transfers. Called on the transport thread. */
    public void addProgressListener(ProgressListener l) { progressListeners.add(l); }

    /** Backing list for {@link global.thalion.ttio.browser.shell.workspaces.TransfersWorkspace}. */
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


    /** Enqueue an anonymous (no workbench session) upload of {@code source}
     *  to {@code url}. {@code bearerToken} may be blank. Returns the queued Transfer. */
    public Transfer enqueueAnonymousUpload(String url, String bearerToken, Path source) {
        long size;
        try { size = Files.size(source); }
        catch (Exception e) { size = -1L; }
        Transfer t = new Transfer(TransferKind.UPLOAD, url,
            source.toString(), size, Map.of());
        addToQueue(t);
        executor.submit(() -> runAnonymousUpload(url, bearerToken, source, t));
        return t;
    }

    /** Enqueue an anonymous download from {@code url} to {@code destination}.
     *  {@code filter} may be empty. Returns the queued Transfer. */
    public Transfer enqueueAnonymousDownload(String url, Path destination,
                                               Map<String, Object> filter) {
        Transfer t = new Transfer(TransferKind.DOWNLOAD, url,
            destination.toString(), 0, filter);
        addToQueue(t);
        executor.submit(() -> runAnonymousDownload(url, destination, filter, t));
        return t;
    }

    private void runAnonymousUpload(String url, String bearerToken,
                                     Path source, Transfer t) {
        try {
            setState(t, TransferState.RUNNING, "Uploading...");
            UploadTask task = new UploadTask(source.toString(), url, bearerToken, false);
            ProgressListener forward = r -> {
                t.setLastReport(r);
                ProgressListener tl = t.progressListener();
                if (tl != null) tl.onProgress(r);
                fanOutProgress(r);
                Platform.runLater(() -> {
                    t.setBytesTransferred(r.bytesDone());
                    if (r.bytesTotal() > 0) {
                        long pct = Math.min(100, r.bytesDone() * 100 / r.bytesTotal());
                        t.setMessage("Uploading... " + pct + "%");
                    }
                });
            };
            task.setProgressListener(forward);
            task.run();
            task.get();  // throws if it failed
            setState(t, TransferState.COMPLETED, "Uploaded to " + url);
        } catch (Throwable ex) {
            setState(t, TransferState.FAILED,
                ex.getMessage() == null ? ex.getClass().getSimpleName() : ex.getMessage());
        }
    }

    private void runAnonymousDownload(String url, Path destination,
                                        Map<String, Object> filter, Transfer t) {
        try {
            setState(t, TransferState.RUNNING, "Downloading...");
            DownloadTask task = new DownloadTask(url,
                filter == null ? Map.of() : filter,
                destination.toString(), "hdf5", 120);
            ProgressListener forward = r -> {
                t.setLastReport(r);
                ProgressListener tl = t.progressListener();
                if (tl != null) tl.onProgress(r);
                fanOutProgress(r);
                Platform.runLater(() -> {
                    t.setBytesTransferred(r.bytesDone());
                    if (r.unitsTotal() > 0 && r.unitsDone() >= r.unitsTotal()) {
                        t.setMessage("Downloaded " + r.bytesDone() + " bytes");
                    } else {
                        t.setMessage("Downloading...");
                    }
                });
            };
            task.setProgressListener(forward);
            task.run();
            String resultPath = task.get();
            long bytes;
            try { bytes = Files.size(destination); } catch (Exception e) { bytes = 0L; }
            setBytes(t, bytes);
            setState(t, TransferState.COMPLETED, "Saved " + bytes + " bytes to " + resultPath);
        } catch (Throwable ex) {
            setState(t, TransferState.FAILED,
                ex.getMessage() == null ? ex.getClass().getSimpleName() : ex.getMessage());
        }
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
        Path tis = null;
        try {
            // WorkbenchTransportClient.upload expects a .tis transport
            // stream (StreamHeader + DatasetHeader + AccessUnit + ...
            // + EndOfStream). The server rejects raw .tio HDF5 bytes
            // with "binary frame outside ReceivingAU". Encode .tio to
            // .tis up front, then stream the .tis file (TTI-O #130 —
            // we no longer Files.readAllBytes the .tis into a heap
            // byte[], so multi-GB uploads no longer pin heap to
            // payload size).
            setState(t, TransferState.RUNNING, "Encoding .tio → .tis...");
            System.err.println("[TransferManager.runUpload] encoding "
                + source + " → .tis temp file");
            tis = global.thalion.ttio.browser.transport
                .TisEncoder.encodeToTempFile(source.toString(), false);
            long tisSize = Files.size(tis);
            System.err.println("[TransferManager.runUpload] tis size="
                + tisSize + " bytes; streaming to " + containerUri);
            setState(t, TransferState.RUNNING, "Uploading...");
            WorkbenchTransportClient.UploadResult result =
                client.upload(project, containerUri, tis,
                              progressFor(t, "Uploading", "uploading"));
            setBytes(t, tisSize);
            setState(t, TransferState.COMPLETED,
                "Uploaded " + result.containerUri()
                + " (au_seq=" + result.lastAckedAuSequence() + ")");
            System.err.println("[TransferManager.runUpload] completed: "
                + result.containerUri());
        } catch (Throwable ex) {
            String msg = ex.getMessage() == null
                ? ex.getClass().getSimpleName() : ex.getMessage();
            System.err.println("[TransferManager.runUpload] FAILED: " + msg);
            ex.printStackTrace();
            setState(t, TransferState.FAILED, msg);
        } finally {
            if (tis != null) {
                try { Files.deleteIfExists(tis); }
                catch (Exception ignored) {}
            }
        }
    }

    private void runDownload(WorkbenchClient client,
                              String containerUri,
                              Path destination,
                              Map<String, Object> filter,
                              Transfer t) {
        try {
            setState(t, TransferState.RUNNING, "Downloading...");
            TransferProgress progress = progressFor(t, "Downloading", "downloading");
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

    /** Fan out a {@link global.thalion.ttio.browser.progress.ProgressReport} to all
     *  registered manager-level {@link ProgressListener}s. Called on the transport thread. */
    private void fanOutProgress(global.thalion.ttio.browser.progress.ProgressReport r) {
        for (var l : progressListeners) l.onProgress(r);
    }

    /** Build a progress callback that drives {@code t}'s byte count + message and
     *  emits {@link global.thalion.ttio.browser.progress.ProgressReport} snapshots to
     *  per-transfer and manager-level listeners.
     *
     *  <p>UI updates are coalesced onto the FX thread (at most one pending update) so
     *  a fast transfer can't flood the event loop. ProgressReport emissions happen
     *  synchronously on the transport thread.</p>
     */
    private TransferProgress progressFor(Transfer t, String verb, String phase) {
        var tracker = new ProgressTracker(
            phase,
            t.sizeBytes() > 0 ? t.sizeBytes() : -1L,
            -1L,
            System.currentTimeMillis());
        AtomicLong latest = new AtomicLong(0);
        AtomicBoolean scheduled = new AtomicBoolean(false);
        return (done, total) -> {
            latest.set(done);
            // emit ProgressReport synchronously on the transport thread:
            var r = tracker.sample(done, 0L, System.currentTimeMillis());
            t.setLastReport(r);
            var tl = t.progressListener();
            if (tl != null) tl.onProgress(r);
            fanOutProgress(r);
            // existing UI-coalescing path:
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

    private void setState(Transfer t, TransferState s, String msg) {
        Runnable r = () -> {
            TransferState prev = t.state();
            // Synthesize a final 100% ProgressReport on terminal-state
            // transitions BEFORE flipping the state, so when downstream
            // listeners observe COMPLETED they also see a coherent
            // progress sample (instead of the last partial-byte snapshot
            // from mid-upload — which on a fast localhost transfer leaves
            // the UI showing e.g. "0.1% — 128 kB" forever).
            if ((s == TransferState.COMPLETED || s == TransferState.FAILED)
                    && prev != s) {
                long size = t.sizeBytes();
                if (size > 0) {
                    long elapsedSec = Math.max(0L,
                        (System.currentTimeMillis() - t.createdAtEpochMs()) / 1000L);
                    t.setLastReport(new ProgressReport(
                        s == TransferState.COMPLETED ? "complete" : "failed",
                        size, size,           // bytesDone == bytesTotal => 100%
                        0L, 0L,               // unitsDone, unitsTotal
                        0.0, 0.0,             // rates
                        0L,                    // etaSeconds
                        elapsedSec,
                        System.currentTimeMillis()));
                }
            }
            t.setState(s);
            t.setMessage(msg);
            // The observable-list listener (transfers.addListener at
            // construction) only fires on add/remove. State transitions
            // inside a Transfer don't propagate to queueListeners by
            // default — TransfersWorkspace would never refresh on
            // PENDING -> RUNNING -> COMPLETED. Fire the listeners
            // explicitly here so every state change re-renders the row.
            for (QueueListener l : queueListeners) {
                try { l.onQueueChanged(); }
                catch (Exception ignored) {}
            }
        };
        if (Platform.isFxApplicationThread()) r.run();
        else Platform.runLater(r);
    }

    private static void setBytes(Transfer t, long n) {
        if (Platform.isFxApplicationThread()) t.setBytesTransferred(n);
        else Platform.runLater(() -> t.setBytesTransferred(n));
    }

    // ---- test helpers ----

    /** Visible for tests only. Remove every transfer from the queue. */
    public void clearAllForTest() {
        transfers.clear();
    }

    /** Visible for tests only. Build an upload-flavoured Transfer with
     *  a fake size; does not start a real upload. */
    public Transfer newFakeUploadForTest(long bytesTotal) {
        return new Transfer(TransferKind.UPLOAD,
            "uri:tio:test/fake-" + System.nanoTime(),
            "/tmp/fake.tio", bytesTotal, java.util.Map.of());
    }

    /** Visible for tests only. Add to queue and mark RUNNING.
     *  Does not launch a worker thread. */
    public void startForTest(Transfer t) {
        Runnable add = () -> {
            if (!transfers.contains(t)) transfers.add(t);
            t.setState(TransferState.RUNNING);
            t.setMessage("Running (test fixture)");
        };
        if (javafx.application.Platform.isFxApplicationThread()) add.run();
        else javafx.application.Platform.runLater(add);
    }

    /** Visible for tests only. Push a synthetic ProgressReport through
     *  the same fan-out path as a real transfer would. */
    public void fakeProgress(Transfer t, global.thalion.ttio.browser.progress.ProgressReport r) {
        t.setLastReport(r);
        var tl = t.progressListener();
        if (tl != null) tl.onProgress(r);
        fanOutProgress(r);
    }

    /** Returns the snapshot of transfers currently in state RUNNING. */
    public java.util.List<Transfer> activeTransfers() {
        return transfers.stream()
            .filter(t -> t.state() == TransferState.RUNNING)
            .toList();
    }

    /** Remove all transfers in COMPLETED state from the queue. Safe to call from any thread. */
    public void clearCompleted() {
        Runnable r = () -> transfers.removeIf(t -> t.state() == TransferState.COMPLETED);
        if (Platform.isFxApplicationThread()) r.run();
        else Platform.runLater(r);
    }

    /** Visible for tests only. Force a Transfer into a given state from any thread. */
    public void fakeStateForTest(Transfer t, TransferState s) {
        Runnable r = () -> t.setState(s);
        if (Platform.isFxApplicationThread()) r.run();
        else Platform.runLater(r);
    }
}
