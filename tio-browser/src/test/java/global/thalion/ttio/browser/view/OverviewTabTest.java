package global.thalion.ttio.browser.view;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.overview.OverviewTab;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class OverviewTabTest {

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
    void overviewAppliesToRootNotToRunNodes() {
        OverviewTab t = new OverviewTab();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, "x", null)));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
    }

    @Test
    void overviewPopulatesFromMinimalMsFixture() throws Exception {
        OverviewTab t = new OverviewTab();
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
                    .toAbsolutePath().toString())) {
            OpenDataset open = new OpenDataset("minimal.tio", true, ds);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.DATASET_ROOT, "minimal.tio", null));
            String summary = t.summaryText();
            assertTrue(summary.contains("MS=1"), "summary: " + summary);
            assertTrue(summary.contains("Format Version: v"),
                "format version: " + summary);
        }
    }
}
