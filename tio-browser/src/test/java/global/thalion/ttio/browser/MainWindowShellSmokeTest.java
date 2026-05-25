package global.thalion.ttio.browser;

import javafx.scene.Parent;
import javafx.scene.control.Menu;
import javafx.scene.control.MenuBar;
import javafx.scene.control.MenuItem;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class MainWindowShellSmokeTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void menuBarHasOnlyFileAndHelp() {
        MenuBar bar = findMenuBar(win.root());
        assertNotNull(bar);
        List<String> menus = bar.getMenus().stream()
            .map(Menu::getText).toList();
        assertEquals(List.of("File", "Help"), menus,
            "menu bar should be exactly [File, Help]; got " + menus);
    }

    @Test
    void fileMenuHasExpectedItems() {
        Menu file = findMenu(win.root(), "File");
        List<String> labels = file.getItems().stream()
            .map(MenuItem::getText).filter(s -> s != null).toList();
        assertTrue(labels.contains("Open…"), labels.toString());
        assertTrue(labels.contains("Open Recent"), labels.toString());
        assertTrue(labels.contains("Encode…"), labels.toString());
        assertTrue(labels.contains("Import…"), labels.toString());
        assertTrue(labels.contains("Export…"), labels.toString());
        assertTrue(labels.contains("Save As…"), labels.toString());
        assertTrue(labels.contains("Close"), labels.toString());
        assertTrue(labels.contains("Exit"), labels.toString());
    }

    @Test
    void helpMenuHasDiagnostics() {
        Menu help = findMenu(win.root(), "Help");
        List<String> labels = help.getItems().stream()
            .map(MenuItem::getText).filter(s -> s != null).toList();
        assertTrue(labels.contains("Diagnostics…"),
            "Help menu should contain Diagnostics: " + labels);
    }

    @Test
    void shellExposesAllFourWorkspaces() {
        assertNotNull(win.shell());
        assertEquals("containers", win.shell().rail().selectedKey());
        interact(() -> win.shell().rail().select("cohorts"));
        assertEquals("cohorts", win.shell().rail().selectedKey());
        interact(() -> win.shell().rail().select("jobs"));
        assertEquals("jobs", win.shell().rail().selectedKey());
        interact(() -> win.shell().rail().select("transfers"));
        assertEquals("transfers", win.shell().rail().selectedKey());
    }

    private static MenuBar findMenuBar(Parent root) {
        for (var node : root.getChildrenUnmodifiable()) {
            if (node instanceof MenuBar mb) return mb;
            if (node instanceof Parent p) {
                MenuBar m = findMenuBar(p);
                if (m != null) return m;
            }
        }
        return null;
    }

    private static Menu findMenu(Parent root, String name) {
        return findMenuBar(root).getMenus().stream()
            .filter(m -> name.equals(m.getText()))
            .findFirst().orElseThrow();
    }
}
