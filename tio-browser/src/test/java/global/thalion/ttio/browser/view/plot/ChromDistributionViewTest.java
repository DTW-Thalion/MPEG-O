package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.genomics.GenomicRun;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.nio.file.Paths;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class ChromDistributionViewTest extends ApplicationTest {

    @Override
    public void start(Stage stage) {
        stage.setScene(new Scene(new StackPane(), 100, 100));
    }

    @Test
    void appliesOnlyToGenomicRun() {
        ChromDistributionView v = new ChromDistributionView();
        assertTrue(v.appliesTo(new DatasetTreeNode(
            TreeNodeKind.GENOMIC_RUN, "g1", "g1")));
        assertFalse(v.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
    }

    @Test
    void chromCountsForM82FixtureSumTo100() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../python/tests/fixtures/genomic/m82_100reads.tio")
                    .toAbsolutePath().toString())) {
            GenomicRun run = ds.genomicRuns().values().iterator().next();
            Map<String, Integer> counts = ChromDistributionView.computeCounts(run);
            int total = counts.values().stream().mapToInt(Integer::intValue).sum();
            assertEquals(100, total,
                "fixture has 100 reads; counts must sum to 100");
            assertFalse(counts.isEmpty(),
                "computeCounts must populate at least one chromosome bucket");
        }
    }
}
