package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.workbench.Transfer;
import global.thalion.ttio.browser.workbench.TransferManager;
import global.thalion.ttio.browser.workbench.TransferState;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class TransfersWorkspaceTest extends ApplicationTest {

    private TransfersWorkspace ws;
    private Stage stage;

    @Override
    public void start(Stage stage) {
        this.stage = stage;
        TransferManager.instance().clearAllForTest();
        ws = new TransfersWorkspace(stage);
        stage.setScene(new Scene(ws.node(), 1000, 600));
        stage.show();
    }

    @Test
    void emptyStateShowsStartNewTransferButton() {
        assertNotNull(ws.startNewButtonForTest());
        assertEquals(0, ws.tableForTest().getItems().size());
    }

    @Test
    void newTransferAppearsInTable() {
        var t = TransferManager.instance().newFakeUploadForTest(1000L);
        interact(() -> TransferManager.instance().startForTest(t));
        assertEquals(1, ws.tableForTest().getItems().size());
    }

    @Test
    void filterActiveShowsOnlyRunning() {
        var running   = TransferManager.instance().newFakeUploadForTest(1000L);
        var completed = TransferManager.instance().newFakeUploadForTest(1000L);
        interact(() -> {
            TransferManager.instance().startForTest(running);
            TransferManager.instance().startForTest(completed);
            TransferManager.instance().fakeStateForTest(completed, TransferState.COMPLETED);
            ws.setFilterForTest("Active");
        });
        assertEquals(1, ws.tableForTest().getItems().size(),
            "Active filter should show only RUNNING/PENDING transfers");
    }

    @Test
    void clearCompletedRemovesCompletedTransfers() {
        var completed = TransferManager.instance().newFakeUploadForTest(1000L);
        interact(() -> {
            TransferManager.instance().startForTest(completed);
            TransferManager.instance().fakeStateForTest(completed, TransferState.COMPLETED);
            ws.clearCompletedButtonForTest().fire();
        });
        assertFalse(TransferManager.instance().transfers().contains(completed),
            "Completed transfer should be removed from the queue");
    }
}
