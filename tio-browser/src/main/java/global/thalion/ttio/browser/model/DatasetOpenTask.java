package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.progress.ProgressListener;
import global.thalion.ttio.browser.progress.ProgressTracker;
import javafx.concurrent.Task;

public final class DatasetOpenTask extends Task<OpenDataset> {

    private final String path;
    private final boolean readOnly;
    private volatile ProgressListener progressListener;
    private ProgressTracker tracker;

    public DatasetOpenTask(String path, boolean readOnly) {
        this.path = path;
        this.readOnly = readOnly;
    }

    public void setProgressListener(ProgressListener listener) {
        this.progressListener = listener;
    }

    @Override
    protected OpenDataset call() throws Exception {
        updateMessage("Opening " + path);
        long startMs = System.currentTimeMillis();
        tracker = new ProgressTracker("opening", -1L, 1L, startMs);
        emit(0L);
        SpectralDataset ds = SpectralDataset.open(path);
        OpenDataset result = new OpenDataset(path, readOnly, ds);
        emit(1L);
        return result;
    }

    private void emit(long unitsDone) {
        ProgressListener l = progressListener;
        if (l == null) return;
        l.onProgress(tracker.sample(0L, unitsDone, System.currentTimeMillis()));
    }
}
