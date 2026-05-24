package global.thalion.ttio.browser.progress;

import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class ProgressDisplayTest extends ApplicationTest {

    private ProgressDisplay display;
    private static final long NOW = 1_000_000L;

    @Override
    public void start(Stage stage) {
        display = new ProgressDisplay();
        stage.setScene(new Scene(new StackPane(display.node()), 400, 80));
        stage.show();
    }

    @Test
    void updateDeterminateSetsBarAndLabel() {
        interact(() -> display.update(new ProgressReport("uploading",
            500L, 1000L, -1L, -1L,
            100.0, Double.NaN, 5L, 5L, NOW), NOW));
        assertEquals(0.5, display.progressBar().getProgress(), 1e-9);
        assertEquals(
            "50.0% · 500 B / 1000 B · 100 B/s · ETA 5s",
            display.label().getText());
    }

    @Test
    void updateIndeterminateSetsBarToIndeterminateState() {
        interact(() -> display.update(new ProgressReport("streaming",
            500L, -1L, -1L, -1L,
            100.0, Double.NaN, -1L, 5L, NOW), NOW));
        assertEquals(-1.0, display.progressBar().getProgress(), 1e-9,
            "JavaFX uses -1 for indeterminate");
    }
}
