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

class MsHeadersTableTest {

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
    void msHeadersAppliesOnlyToMsRunNode() {
        MsHeadersTable t = new MsHeadersTable();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.NMR_RUN, "run", "run")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, "root", null)));
    }

    @Test
    void msHeadersPopulatesFromFullMsFixture() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            String runKey = ds.msRuns().keySet().iterator().next();
            int expected = ds.msRuns().get(runKey).count();

            MsHeadersTable t = new MsHeadersTable();
            OpenDataset open = new OpenDataset("full_ms.tio", true, ds);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.MS_RUN, runKey, runKey));
            assertEquals(expected, t.table().getItems().size(),
                "row count must match run.count()");
            assertEquals(8, t.table().getColumns().size(),
                "MS Headers expects 8 columns: idx, scan time, MS level, "
                + "polarity, precursor m/z, precursor charge, base peak int., activation");
        }
    }
}
