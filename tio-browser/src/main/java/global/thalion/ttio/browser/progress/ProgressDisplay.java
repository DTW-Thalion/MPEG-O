package global.thalion.ttio.browser.progress;

import javafx.scene.control.Label;
import javafx.scene.control.ProgressBar;
import javafx.scene.layout.VBox;

/**
 * Reusable progress bar + numeric line. Update by calling
 * {@link #update(ProgressReport, long)} on the JavaFX application
 * thread (callers running off-thread must wrap with
 * {@code Platform.runLater(...)}).
 */
public final class ProgressDisplay {

    private final ProgressBar bar = new ProgressBar(0.0);
    private final Label numericLine = new Label("");
    private final VBox root = new VBox(4, bar, numericLine);

    public ProgressDisplay() {
        bar.setMaxWidth(Double.MAX_VALUE);
        numericLine.getStyleClass().add("progress-numeric-line");
    }

    public VBox node() { return root; }

    public ProgressBar progressBar() { return bar; }

    public Label label() { return numericLine; }

    public void update(ProgressReport r, long nowEpochMs) {
        if (r.isDeterminate()) {
            bar.setProgress(r.percent());
        } else {
            bar.setProgress(-1.0); // indeterminate
        }
        numericLine.setText(ProgressFormatter.line(r, nowEpochMs));
    }
}
