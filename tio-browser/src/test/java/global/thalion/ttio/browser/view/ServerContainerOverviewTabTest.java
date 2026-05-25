/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class ServerContainerOverviewTabTest extends ApplicationTest {

    private ServerContainerOverviewTab tab;

    @Override
    public void start(Stage stage) {
        tab = new ServerContainerOverviewTab();
        stage.setScene(new Scene(tab.node(), 600, 200));
        stage.show();
    }

    @Test
    void updateDisplaysContainerMetadata() {
        var c = new UnifiedContainerNode.ServerContainer(
            "uri:tio:adni/x", "X-001", 134_217_728L);
        interact(() -> tab.update(c));
        boolean foundUri = false;
        for (var node : tab.node().lookupAll(".label")) {
            if (node instanceof javafx.scene.control.Label l
                    && l.getText().contains("uri:tio:adni/x")) {
                foundUri = true;
                break;
            }
        }
        assertTrue(foundUri, "URI label should appear after update()");
    }

    @Test
    void allFourActionButtonsPresent() {
        assertNotNull(tab.downloadButton());
        assertNotNull(tab.selectiveDownloadButton());
        assertNotNull(tab.serverExportButton());
        assertNotNull(tab.runPipelineButton());
    }
}
