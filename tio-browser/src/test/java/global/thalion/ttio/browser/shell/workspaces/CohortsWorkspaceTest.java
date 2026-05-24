/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class CohortsWorkspaceTest extends ApplicationTest {

    private CohortsWorkspace ws;

    @Override
    public void start(Stage stage) {
        ConnectionManager.instance().disconnect();
        ws = new CohortsWorkspace(stage);
        stage.setScene(new Scene(ws.node(), 1000, 700));
        stage.show();
    }

    @Test
    void offlineStateShowsConnectCta() {
        assertTrue(ws.connectCtaForTest().isVisible(),
            "offline state should display the connect CTA");
        assertFalse(ws.builderRegionForTest().isVisible(),
            "builder should be hidden when offline");
    }
}
