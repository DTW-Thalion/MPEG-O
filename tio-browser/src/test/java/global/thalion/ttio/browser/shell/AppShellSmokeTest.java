package global.thalion.ttio.browser.shell;

import javafx.scene.Scene;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class AppShellSmokeTest extends ApplicationTest {

    private AppShell shell;

    @Override
    public void start(Stage stage) {
        shell = AppShell.create(
            List.of(stub("containers", "Containers", "📁"),
                    stub("cohorts",    "Cohorts",    "🔬"),
                    stub("jobs",       "Jobs & Sessions", "⚙"),
                    stub("transfers",  "Transfers",  "⇅")));
        stage.setScene(new Scene(shell.root(), 1280, 800));
        stage.show();
    }

    @Test
    void shellHasHeaderRailCenterAndStrip() {
        assertNotNull(shell.header());
        assertNotNull(shell.rail());
        assertNotNull(shell.transferStrip());
        assertEquals("containers", shell.rail().selectedKey(),
            "default selection is first workspace");
    }

    @Test
    void switchingRailReplacesCenter() {
        Region beforeCenter = (Region) shell.root().getCenter();
        interact(() -> shell.rail().select("cohorts"));
        Region afterCenter = (Region) shell.root().getCenter();
        assertNotSame(beforeCenter, afterCenter);
    }

    @Test
    void currentWorkspaceByKeyReturnsExpected() {
        interact(() -> shell.rail().select("jobs"));
        assertEquals("jobs", shell.currentWorkspaceByKey("jobs").key());
    }

    private static Workspace stub(String key, String tooltip, String icon) {
        return new Workspace() {
            private final Region n = new StackPane();
            public String key() { return key; }
            public String tooltip() { return tooltip; }
            public String iconText() { return icon; }
            public Region node() { return n; }
            public void onShow() {}
            public void onHide() {}
        };
    }
}
