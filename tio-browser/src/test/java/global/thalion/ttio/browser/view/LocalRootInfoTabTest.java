/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.view;

import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;

class LocalRootInfoTabTest extends ApplicationTest {

    private LocalRootInfoTab tab;
    private final AtomicBoolean openFired = new AtomicBoolean(false);

    @Override
    public void start(Stage stage) {
        tab = new LocalRootInfoTab();
        tab.onOpen(() -> openFired.set(true));
        stage.setScene(new Scene(tab.node(), 400, 300));
        stage.show();
    }

    @Test
    void hasThreeButtons() {
        assertNotNull(tab.openButton());
        assertNotNull(tab.encodeButton());
        assertNotNull(tab.importButton());
    }

    @Test
    void openButtonFiresHandler() {
        interact(() -> tab.openButton().fire());
        assertTrue(openFired.get());
    }
}
