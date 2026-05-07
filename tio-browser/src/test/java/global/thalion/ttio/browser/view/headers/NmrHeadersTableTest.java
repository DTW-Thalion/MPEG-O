package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class NmrHeadersTableTest {

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
    void nmrHeadersAppliesOnlyToNmrRunNode() {
        NmrHeadersTable t = new NmrHeadersTable();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.NMR_RUN, "run", "run")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
    }

    @Test
    void nmrHeadersPopulatesFromNmr1dFixture() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/nmr_1d.tio")
                    .toAbsolutePath().toString())) {
            String runKey = ds.msRuns().keySet().iterator().next();
            int expected = ds.msRuns().get(runKey).count();

            NmrHeadersTable t = new NmrHeadersTable();
            OpenDataset open = new OpenDataset("nmr_1d.tio", true, ds);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.NMR_RUN, runKey, runKey));
            assertEquals(expected, t.table().getItems().size());
            assertEquals(5, t.table().getColumns().size(),
                "NMR Headers expects 5 columns: idx, nucleus, freq, scan time, solvent");
        }
    }
}
