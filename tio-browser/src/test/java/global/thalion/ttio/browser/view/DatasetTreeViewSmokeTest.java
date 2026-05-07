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

class DatasetTreeViewSmokeTest extends ApplicationTest {

    private MainWindow win;

    @Override
    public void start(Stage stage) {
        win = new MainWindow();
        win.show(stage);
    }

    @Test
    void treePopulatesAfterOpen() throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
        Platform.runLater(() -> win.loadDataset(fixture.toString(), true));

        long deadline = System.nanoTime() + (long) 10e9;
        TreeItem<DatasetTreeNode> root = null;
        while (System.nanoTime() < deadline) {
            if (win.tree() != null) {
                root = win.tree().control().getRoot();
                if (root != null && !root.getChildren().isEmpty()) break;
            }
            Thread.sleep(50);
        }
        assertNotNull(root, "tree root should be set within 10s");
        assertEquals(TreeNodeKind.DATASET_ROOT, root.getValue().kind());
        assertTrue(root.getChildren().size() >= 3,
            "root should have at least study/feature_flags/encryption; was: "
            + root.getChildren().size());
    }

    @Test
    void selectionEventFiresOnSelect() throws Exception {
        Path fixture = Paths.get(
            "../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();
        Platform.runLater(() -> win.loadDataset(fixture.toString(), true));

        long deadline = System.nanoTime() + (long) 10e9;
        while (System.nanoTime() < deadline) {
            if (win.tree() != null && win.tree().control().getRoot() != null) break;
            Thread.sleep(50);
        }
        assertNotNull(win.tree().control().getRoot(),
            "tree should be populated before selection test");

        // Replace the listener with a capturing one
        java.util.concurrent.atomic.AtomicReference<DatasetTreeNode> seen =
            new java.util.concurrent.atomic.AtomicReference<>();
        win.tree().onSelected(seen::set);

        Platform.runLater(() ->
            win.tree().control().getSelectionModel().select(
                win.tree().control().getRoot()));

        long sel_deadline = System.nanoTime() + (long) 5e9;
        while (System.nanoTime() < sel_deadline) {
            if (seen.get() != null) break;
            Thread.sleep(20);
        }
        assertNotNull(seen.get(), "listener should fire on selection");
        assertEquals(TreeNodeKind.DATASET_ROOT, seen.get().kind());
    }
}
