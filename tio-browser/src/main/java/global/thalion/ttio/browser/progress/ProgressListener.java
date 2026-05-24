package global.thalion.ttio.browser.progress;

/**
 * Callback invoked when an operation reports progress. Implementations may be invoked from any thread
 * (callers wrap with {@code Platform.runLater} if the listener touches JavaFX state); implementations
 * should return quickly and not block.
 */
@FunctionalInterface
public interface ProgressListener {
    void onProgress(ProgressReport report);
}
