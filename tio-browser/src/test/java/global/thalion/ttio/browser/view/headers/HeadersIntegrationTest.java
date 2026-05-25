package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.browser.MainWindow;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.application.Platform;
import javafx.scene.control.TreeItem;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class HeadersIntegrationTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void selectingMsRunShowsMsHeadersTab() throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/full_ms.tio").toAbsolutePath();
        Platform.runLater(() -> win.loadDataset(fixture.toString(), true));

        long deadline = System.nanoTime() + (long) 10e9;
        while (System.nanoTime() < deadline) {
            if (win.tree() != null
                    && win.tree().control().getRoot() != null
                    && !win.tree().control().getRoot().getChildren().isEmpty()) break;
            Thread.sleep(50);
        }
        assertNotNull(win.tree().control().getRoot(),
            "tree root should be set before selection test");
        assertFalse(win.tree().control().getRoot().getChildren().isEmpty(),
            "tree root should have children within 10s");

        Platform.runLater(() -> selectFirstNodeOfKind(TreeNodeKind.MS_RUN));

        long sel_deadline = System.nanoTime() + (long) 5e9;
        while (System.nanoTime() < sel_deadline) {
            var tabs = win.detail().control().getTabs();
            boolean hasMsHeaders = tabs.stream().anyMatch(t -> "MS Headers".equals(t.getText()));
            boolean hasProvenance = tabs.stream().anyMatch(t -> "Provenance".equals(t.getText()));
            if (hasMsHeaders && hasProvenance) break;
            Thread.sleep(20);
        }
        var tabs = win.detail().control().getTabs();
        assertTrue(tabs.stream().anyMatch(t -> "MS Headers".equals(t.getText())),
            "MS_RUN selection should show MS Headers tab");
        assertTrue(tabs.stream().anyMatch(t -> "Provenance".equals(t.getText())),
            "MS_RUN selection should show Provenance tab");
    }

    private void selectFirstNodeOfKind(TreeNodeKind kind) {
        TreeItem<DatasetTreeNode> root = win.tree().control().getRoot();
        TreeItem<DatasetTreeNode> match = findDescendant(root, kind);
        if (match != null) { win.tree().control().getSelectionModel().select(match); }
    }

    private static TreeItem<DatasetTreeNode> findDescendant(
            TreeItem<DatasetTreeNode> node, TreeNodeKind kind) {
        if (node.getValue() != null && node.getValue().kind() == kind) return node;
        for (TreeItem<DatasetTreeNode> child : node.getChildren()) {
            TreeItem<DatasetTreeNode> found = findDescendant(child, kind);
            if (found != null) return found;
        }
        return null;
    }
}
