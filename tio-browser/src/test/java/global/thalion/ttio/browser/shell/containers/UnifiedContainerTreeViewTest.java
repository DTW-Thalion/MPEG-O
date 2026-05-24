/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.containers;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.scene.Scene;
import javafx.scene.control.TreeItem;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class UnifiedContainerTreeViewTest extends ApplicationTest {

    private UnifiedContainerTreeView view;

    @Override
    public void start(Stage stage) {
        ConnectionManager.instance().disconnect();
        view = new UnifiedContainerTreeView();
        stage.setScene(new Scene(view.control(), 320, 600));
        stage.show();
    }

    @Test
    void rootHasLocalAndServersBranches() {
        TreeItem<UnifiedContainerNode> root = view.control().getRoot();
        assertEquals(2, root.getChildren().size());
        assertInstanceOf(UnifiedContainerNode.LocalRoot.class,
            root.getChildren().get(0).getValue());
        assertInstanceOf(UnifiedContainerNode.ServersRoot.class,
            root.getChildren().get(1).getValue());
    }

    @Test
    void localBranchHasOpenAndEncodeAndImportActionNodes() {
        TreeItem<UnifiedContainerNode> local = view.control().getRoot().getChildren().get(0);
        boolean hasOpen = local.getChildren().stream()
            .anyMatch(i -> i.getValue() instanceof UnifiedContainerNode.OpenLocalAction);
        boolean hasEncode = local.getChildren().stream()
            .anyMatch(i -> i.getValue() instanceof UnifiedContainerNode.EncodeLocalAction);
        boolean hasImport = local.getChildren().stream()
            .anyMatch(i -> i.getValue() instanceof UnifiedContainerNode.ImportLocalAction);
        assertTrue(hasOpen && hasEncode && hasImport,
            "all three action nodes present");
    }

    @Test
    void serversBranchOfflineShowsConnectAction() {
        TreeItem<UnifiedContainerNode> servers = view.control().getRoot().getChildren().get(1);
        assertEquals(1, servers.getChildren().size());
        assertInstanceOf(UnifiedContainerNode.ServerConnectAction.class,
            servers.getChildren().get(0).getValue());
    }
}
