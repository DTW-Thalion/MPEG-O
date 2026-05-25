package global.thalion.ttio.browser.transport;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.browser.progress.ProgressTracker;
import global.thalion.ttio.transport.TransportClient;
import javafx.concurrent.Task;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Map;

/**
 * Background {@link Task} that connects to a TTI-O WebSocket transport
 * server, downloads a filtered dataset, and materialises it as a local
 * {@code .tio} file via {@link TransportClient#streamToFile}.
 *
 * <p>Returns the output path on success. The {@code provider} and
 * {@code timeoutSeconds} fields are kept for forward-compatibility;
 * {@code streamToFile} always materialises via HDF5 internally.</p>
 */
public final class DownloadTask extends Task<String> {

    private final String url;
    private final Map<String, Object> filters;
    private final String outputPath;
    private final String provider;
    private final int timeoutSeconds;
    private volatile ProgressListener progressListener;
    private ProgressTracker tracker;

    /**
     * @param url            WebSocket URL, e.g. {@code ws://host:8080/}
     * @param filters        filter map forwarded as the JSON query body
     * @param outputPath     local path for the materialised {@code .tio}
     * @param provider       storage provider hint (kept for forward-compat;
     *                       {@code streamToFile} always uses HDF5 internally)
     * @param timeoutSeconds maximum allowed wall-clock seconds; enforce via
     *                       {@code task.get(timeoutSeconds, TimeUnit.SECONDS)}
     *                       since {@code streamToFile} has no timeout param
     */
    public DownloadTask(String url, Map<String, Object> filters,
                        String outputPath, String provider,
                        int timeoutSeconds) {
        this.url = url;
        this.filters = filters;
        this.outputPath = outputPath;
        this.provider = provider;
        this.timeoutSeconds = timeoutSeconds;
    }

    public void setProgressListener(ProgressListener listener) {
        this.progressListener = listener;
    }

    @Override
    protected String call() throws Exception {
        updateMessage("Connecting to " + url + " …");
        long startMs = System.currentTimeMillis();
        tracker = new ProgressTracker(
            "downloading", -1L, 1L, startMs);
        emit(0L, 0L);

        TransportClient client = new TransportClient(url);
        java.util.function.LongConsumer onBytes = bytesDone -> emit(bytesDone, 0L);
        // streamToFile does not accept a timeout parameter; the caller
        // enforces the wall-clock bound via task.get(timeoutSeconds, ...).
        try (SpectralDataset materialised =
                client.streamToFile(outputPath, filters, onBytes)) {
            // Close immediately — the GUI re-opens via loadDataset(...).
        }

        long finalSize;
        try { finalSize = Files.size(Paths.get(outputPath)); }
        catch (Exception e) { finalSize = 0L; }
        emit(finalSize, 1L);
        updateMessage("Done.");
        return outputPath;
    }

    private void emit(long bytesDone, long unitsDone) {
        ProgressListener l = progressListener;
        if (l == null || tracker == null) return;
        l.onProgress(tracker.sample(bytesDone, unitsDone, System.currentTimeMillis()));
    }

    /** Timeout hint for use by the caller’s {@code task.get(...)} call. */
    public int timeoutSeconds() { return timeoutSeconds; }
}
