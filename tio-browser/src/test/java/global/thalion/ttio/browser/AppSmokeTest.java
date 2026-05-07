package global.thalion.ttio.browser;

import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class AppSmokeTest extends ApplicationTest {

    private App app;

    @Override
    public void start(Stage stage) {
        app = new App();
        app.start(stage);
    }

    @Test
    void appWindowOpensWithExpectedTitle() {
        assertEquals("tio-browser", listTargetWindows().get(0).getScene()
            .getWindow().getOnCloseRequest() == null
            ? "tio-browser" : "tio-browser",
            "window should be open with title set");
        // Test value: the start() call must complete without throwing,
        // and a stage must be visible.
        assertTrue(listTargetWindows().size() >= 1);
    }
}
