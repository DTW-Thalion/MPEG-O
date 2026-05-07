package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class RamanHeadersTableTest {

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS), "JavaFX toolkit did not start");
    }

    @Test
    void appliesToRamanIrAndUvVisRunsOnly() {
        RamanHeadersTable t = new RamanHeadersTable();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.RAMAN_RUN, "r", "r")));
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.IR_RUN, "i", "i")));
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.UV_VIS_RUN, "u", "u")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "m", "m")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.NMR_RUN, "n", "n")));
    }
}
