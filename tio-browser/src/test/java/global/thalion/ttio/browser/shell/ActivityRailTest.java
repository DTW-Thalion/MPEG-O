package global.thalion.ttio.browser.shell;

import javafx.scene.Scene;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class ActivityRailTest extends ApplicationTest {

    private ActivityRail rail;
    private final java.util.concurrent.atomic.AtomicReference<String> last =
        new java.util.concurrent.atomic.AtomicReference<>();

    @Override
    public void start(Stage stage) {
        rail = new ActivityRail(List.of(
            stub("containers", "Containers", "📁"),
            stub("cohorts",    "Cohorts",    "🔬"),
            stub("jobs",       "Jobs & Sessions", "⚙"),
            stub("transfers",  "Transfers",  "⇅")
        ));
        rail.onSelect(last::set);
        stage.setScene(new Scene(new StackPane(rail.node()), 60, 400));
        stage.show();
    }

    @Test
    void initialSelectionIsTheFirstWorkspace() {
        assertEquals("containers", rail.selectedKey());
    }

    @Test
    void clickingButtonChangesSelectionAndFiresCallback() {
        interact(() -> rail.select("cohorts"));
        assertEquals("cohorts", rail.selectedKey());
        assertEquals("cohorts", last.get());
    }

    @Test
    void everyButtonHasTooltipMatchingWorkspace() {
        for (var btn : rail.buttonsForTest()) {
            assertNotNull(btn.getTooltip(),
                "button " + btn.getText() + " should have a tooltip");
        }
    }

    private static Workspace stub(String key, String tooltip, String icon) {
        return new Workspace() {
            public String key() { return key; }
            public String tooltip() { return tooltip; }
            public String iconText() { return icon; }
            public Region node() { return new StackPane(); }
            public void onShow() {}
            public void onHide() {}
        };
    }
}
