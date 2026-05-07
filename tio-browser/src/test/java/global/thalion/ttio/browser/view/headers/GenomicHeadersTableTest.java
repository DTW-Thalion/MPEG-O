package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class GenomicHeadersTableTest extends ApplicationTest {

    @Override
    public void start(Stage stage) {
        stage.setScene(new Scene(new StackPane(), 100, 100));
    }

    @Test
    void appliesOnlyToGenomicRunNode() {
        GenomicHeadersTable t = new GenomicHeadersTable();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.GENOMIC_RUN, "g1", "g1")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.MS_RUN, "run", "run")));
    }

    @Test
    void m82FixturePopulates100Rows() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../python/tests/fixtures/genomic/m82_100reads.tio")
                    .toAbsolutePath().toString())) {
            String runKey = ds.genomicRuns().keySet().iterator().next();
            GenomicHeadersTable t = new GenomicHeadersTable();
            t.update(new OpenDataset("m82.tio", true, ds),
                new DatasetTreeNode(TreeNodeKind.GENOMIC_RUN, runKey, runKey));
            assertEquals(100, t.table().getItems().size());
            // Spot-check first row's chromosome is non-null
            GenomicRowAdapter row0 = t.table().getItems().get(0);
            assertNotNull(row0.chromosome());
            // 8-column layout: idx, chrom, pos, flag, MAPQ, CIGAR, length, read_name
            assertEquals(8, t.table().getColumns().size());
            // Filter ChoiceBox should expose at least the (all) entry
            assertNotNull(t.chromFilter().getValue());
        }
    }
}
