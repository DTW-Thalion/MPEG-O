package global.thalion.ttio.browser.transport;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.TransportClient;
import javafx.concurrent.Task;

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

    @Override
    protected String call() throws Exception {
        updateMessage("Connecting to " + url + " …");
        TransportClient client = new TransportClient(url);
        // streamToFile does not accept a timeout parameter; the caller
        // enforces the wall-clock bound via task.get(timeoutSeconds, ...).
        try (SpectralDataset materialised = client.streamToFile(outputPath, filters)) {
            // Close immediately — the GUI re-opens via loadDataset(...).
        }
        updateMessage("Done.");
        return outputPath;
    }

    /** Timeout hint for use by the caller’s {@code task.get(...)} call. */
    public int timeoutSeconds() { return timeoutSeconds; }
}
