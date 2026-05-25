/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import javafx.collections.FXCollections;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class ProjectListingTabTest extends ApplicationTest {

    private ProjectListingTab tab;

    @Override
    public void start(Stage stage) {
        tab = new ProjectListingTab();
        stage.setScene(new Scene(tab.node(), 600, 400));
        stage.show();
    }

    @Test
    void populatesTableWhenSetContainersCalled() {
        var list = FXCollections.observableArrayList(
            new UnifiedContainerNode.ServerContainer("uri:tio:a/1", "A-001", 1024L),
            new UnifiedContainerNode.ServerContainer("uri:tio:a/2", "A-002", 2048L));
        interact(() -> tab.setContainers(list));
        assertEquals(2, tab.tableForTest().getItems().size());
    }

    @Test
    void loadMoreButtonIsPresent() {
        assertNotNull(tab.loadMoreButtonForTest());
    }
}
