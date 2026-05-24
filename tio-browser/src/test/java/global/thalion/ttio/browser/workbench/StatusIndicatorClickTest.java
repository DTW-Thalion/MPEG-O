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
    }

    @Test
    void clickOnNodeFiresHandler() {
        clickOn(indicator.node());
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
