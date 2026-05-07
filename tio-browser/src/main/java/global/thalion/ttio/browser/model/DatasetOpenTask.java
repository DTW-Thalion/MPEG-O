package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;
import javafx.concurrent.Task;

public final class DatasetOpenTask extends Task<OpenDataset> {

    private final String path;
    private final boolean readOnly;

    public DatasetOpenTask(String path, boolean readOnly) {
        this.path = path;
        this.readOnly = readOnly;
    }

    @Override
    protected OpenDataset call() throws Exception {
        updateMessage("Opening " + path);
        SpectralDataset ds = SpectralDataset.open(path);
        return new OpenDataset(path, readOnly, ds);
    }
}
