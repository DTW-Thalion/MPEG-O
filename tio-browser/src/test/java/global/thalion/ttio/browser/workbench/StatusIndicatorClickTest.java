/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class StatusIndicatorClickTest extends ApplicationTest {

    private StatusIndicator indicator;
    private final java.util.concurrent.atomic.AtomicBoolean clicked =
        new java.util.concurrent.atomic.AtomicBoolean(false);

    @Override
    public void start(Stage stage) {
        ConnectionManager.instance().disconnect();
        indicator = new StatusIndicator();
        indicator.onClick(() -> clicked.set(true));
        stage.setScene(new Scene(new StackPane(indicator.node()), 400, 40));
        stage.show();
        stage.toFront();
        stage.requestFocus();
    }

    @Test
    void clickOnNodeFiresHandler() {
        // Use interact() + fire() instead of clickOn() to avoid TestFX
        // focus/window-ordering flakiness when the full suite is run.
        interact(() -> indicator.node().fireEvent(
            new javafx.scene.input.MouseEvent(
                javafx.scene.input.MouseEvent.MOUSE_CLICKED,
                0, 0, 0, 0,
                javafx.scene.input.MouseButton.PRIMARY, 1,
                false, false, false, false,
                true, false, false, true, false, false, null)));
        assertTrue(clicked.get(),
            "onClick handler should fire when the StatusIndicator node is clicked");
    }

    @Test
    void labelStillShowsDisconnectedText() {
        // sanity: existing render behaviour is unchanged
        assertTrue(indicator.label().getText().contains("disconnected"),
            "label should still show disconnected: " + indicator.label().getText());
    }
}
