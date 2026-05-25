package global.thalion.ttio.browser.view;

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

class DetailPaneIntegrationTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void selectingRootShowsOverviewTab() throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
        Platform.runLater(() -> win.loadDataset(fixture.toString(), true));

        long deadline = System.nanoTime() + (long) 10e9;
        TreeItem<DatasetTreeNode> root = null;
        while (System.nanoTime() < deadline) {
            if (win.tree() != null && win.tree().control().getRoot() != null) {
                root = win.tree().control().getRoot();
                break;
            }
            Thread.sleep(50);
        }
        assertNotNull(root, "tree should populate within 10s");

        final TreeItem<DatasetTreeNode> treeRoot = root;
        Platform.runLater(() ->
            win.tree().control().getSelectionModel().select(treeRoot));

        long sel_deadline = System.nanoTime() + (long) 5e9;
        while (System.nanoTime() < sel_deadline) {
            if (!win.detail().control().getTabs().isEmpty()) break;
            Thread.sleep(20);
        }
        var tabsList = win.detail().control().getTabs();
        assertFalse(tabsList.isEmpty(), "selecting root should produce at least one tab");
        assertEquals("Overview", tabsList.get(0).getText(),
            "first tab for DATASET_ROOT should be Overview");
    }

    @Test
    void selectingFeatureFlagsShowsFeatureFlagsTab() throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
        Platform.runLater(() -> win.loadDataset(fixture.toString(), true));

        long deadline = System.nanoTime() + (long) 10e9;
        TreeItem<DatasetTreeNode> root = null;
        while (System.nanoTime() < deadline) {
            if (win.tree() != null && win.tree().control().getRoot() != null) {
                root = win.tree().control().getRoot();
                break;
            }
            Thread.sleep(50);
        }
        assertNotNull(root, "tree should populate within 10s");

        final TreeItem<DatasetTreeNode> treeRoot = root;
        Platform.runLater(() -> {
            for (TreeItem<DatasetTreeNode> child : treeRoot.getChildren()) {
                if (child.getValue() != null
                        && child.getValue().kind() == TreeNodeKind.FEATURE_FLAGS) {
                    win.tree().control().getSelectionModel().select(child);
                    break;
                }
            }
        });

        long sel_deadline = System.nanoTime() + (long) 5e9;
        while (System.nanoTime() < sel_deadline) {
            if (!win.detail().control().getTabs().isEmpty()) break;
            Thread.sleep(20);
        }
        var tabs = win.detail().control().getTabs();
        assertFalse(tabs.isEmpty(), "FEATURE_FLAGS selection should produce a tab");
        assertEquals("Feature Flags", tabs.get(0).getText());
    }
}
