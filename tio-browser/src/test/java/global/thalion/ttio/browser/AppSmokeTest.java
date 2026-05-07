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
        assertTrue(listTargetWindows().size() >= 1,
            "primary stage should be visible after start()");
        Stage primary = (Stage) listTargetWindows().get(0);
        assertEquals("tio-browser", primary.getTitle(),
            "primary stage title should be 'tio-browser'");
    }
}
