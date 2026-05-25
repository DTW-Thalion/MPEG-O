package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class ContainersWorkspaceUnifiedTreeTest extends ApplicationTest {
    private ContainersWorkspace ws;

    @Override
    public void start(Stage stage) {
        ws = new ContainersWorkspace(stage);
        stage.setScene(new Scene(ws.node(), 1280, 800));
        stage.show();
    }

    @Test
    void hasUnifiedTreeOnTheLeft() {
        assertNotNull(ws.unifiedTreeForTest());
        assertEquals(2, ws.unifiedTreeForTest().control().getRoot().getChildren().size(),
            "unified tree has Local + Servers root branches");
    }

    @Test
    void preservesExistingTreeAndDetailAccessors() {
        // Backward compat: existing tests still get a DatasetTreeView and DetailPane.
        assertNotNull(ws.tree());
        assertNotNull(ws.detail());
    }
}