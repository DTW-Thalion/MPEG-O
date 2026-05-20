/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser;

import javafx.scene.Parent;
import javafx.scene.control.Menu;
import javafx.scene.control.MenuBar;
import javafx.scene.control.MenuItem;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * W5.7 end-to-end smoke: assemble the full MainWindow with every
 * W5 panel wired, and verify the Workbench menu exposes all the
 * W5.1-W5.7 actions. This is the GUI-assembly half of the W5
 * acceptance gate; the live-daemon round-trip (login -> browse ->
 * upload -> submit -> download) is a shared cross-W follow-up
 * that needs the workbench-server Docker image vendored in CI.
 */
class WorkbenchMenuSmokeTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void workbenchMenuExposesEveryW5Action() {
        MenuBar bar = findMenuBar(win.root());
        assertNotNull(bar, "MainWindow should have a MenuBar");

        Menu workbench = bar.getMenus().stream()
            .filter(m -> "Workbench".equals(m.getText()))
            .findFirst()
            .orElse(null);
        assertNotNull(workbench, "a Workbench menu should exist");

        List<String> labels = new ArrayList<>();
        for (MenuItem item : workbench.getItems()) {
            if (item.getText() != null) labels.add(item.getText());
        }

        // W5.1 connection + status
        assertTrue(labels.contains("Connect…"), labels.toString());
        assertTrue(labels.contains("Disconnect"), labels.toString());
        assertTrue(labels.contains("Status…"), labels.toString());
        // W5.2 container browser
        assertTrue(labels.contains("Browse containers…"), labels.toString());
        // W5.3 transfers
        assertTrue(labels.contains("Upload to workbench…"), labels.toString());
        assertTrue(labels.contains("Download from workbench…"), labels.toString());
        assertTrue(labels.contains("Transfers…"), labels.toString());
        // W5.4 cohort
        assertTrue(labels.contains("Cohort query…"), labels.toString());
        // W5.5 pipelines + jobs
        assertTrue(labels.contains("Launch pipeline…"), labels.toString());
        assertTrue(labels.contains("Jobs…"), labels.toString());
        // W5.6 sessions
        assertTrue(labels.contains("Launch session…"), labels.toString());
        assertTrue(labels.contains("Sessions…"), labels.toString());
        // W5.7 encode + export
        assertTrue(labels.contains("Encode + upload…"), labels.toString());
        assertTrue(labels.contains("Export container…"), labels.toString());
    }

    @Test
    void everyWorkbenchActionHasAnOnActionHandler() {
        MenuBar bar = findMenuBar(win.root());
        Menu workbench = bar.getMenus().stream()
            .filter(m -> "Workbench".equals(m.getText()))
            .findFirst().orElseThrow();
        for (MenuItem item : workbench.getItems()) {
            // Separators have null text; skip them.
            if (item.getText() == null) continue;
            assertNotNull(item.getOnAction(),
                "menu item '" + item.getText() + "' should be wired");
        }
    }

    private static MenuBar findMenuBar(Parent root) {
        if (root == null) return null;
        for (var node : root.getChildrenUnmodifiable()) {
            if (node instanceof MenuBar mb) return mb;
            if (node instanceof Parent p) {
                MenuBar found = findMenuBar(p);
                if (found != null) return found;
            }
        }
        return null;
    }
}
