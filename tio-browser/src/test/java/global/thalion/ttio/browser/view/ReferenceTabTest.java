package global.thalion.ttio.browser.view;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.genomics.ReferenceImport;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.testfx.framework.junit5.ApplicationTest;

import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class ReferenceTabTest extends ApplicationTest {

    @Override
    public void start(Stage stage) {
        stage.setScene(new Scene(new StackPane(), 100, 100));
    }

    @Test
    void appliesOnlyToReferenceNode() {
        ReferenceTab t = new ReferenceTab();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.REFERENCE, "test", "test-ref-v1")));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.GENOMIC_RUN, "g1", "g1")));
    }

    @Test
    void populatesFromEmbeddedReference(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("with_ref.tio");

        // Build a minimal SpectralDataset, attach a reference via the
        // 1.1.0 ReferenceImport.writeToDataset API, then close+reopen.
        SpectralDataset ds = SpectralDataset.create(
            tio.toString(), "ref-tab-test", null,
            List.of(), List.of(), List.of(), List.of());
        ReferenceImport ref = new ReferenceImport(
            "test-ref-v1",
            List.of("chr1", "chr2"),
            List.of("ACGTACGT".getBytes(),
                    "TTTTAAAA".getBytes()));
        ref.writeToDataset(ds);
        ds.close();

        try (SpectralDataset opened = SpectralDataset.open(tio.toString())) {
            assertTrue(opened.references().containsKey("test-ref-v1"),
                "reference must round-trip via references() accessor");

            ReferenceTab t = new ReferenceTab();
            OpenDataset open = new OpenDataset(tio.toString(), true, opened);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.REFERENCE, "test-ref-v1", "test-ref-v1"));

            assertEquals("test-ref-v1", t.shownUri());
            assertEquals(2, t.shownChromosomeCount());
            assertEquals(16L, t.shownTotalBases());
            assertEquals(2, t.chromList().getItems().size());
        }
    }
}
