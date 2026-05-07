package global.thalion.ttio.browser.view;

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

class QuantificationsTabTest extends ApplicationTest {

    @Override
    public void start(Stage stage) {
        stage.setScene(new Scene(new StackPane(), 100, 100));
    }

    @Test
    void appliesOnlyToQuantificationsNode() {
        QuantificationsTab t = new QuantificationsTab();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.QUANTIFICATIONS, "quantifications", null)));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.IDENTIFICATIONS, "identifications", null)));
    }

    @Test
    void rowCountMatchesDatasetQuantifications() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            int expected = ds.quantifications().size();
            QuantificationsTab t = new QuantificationsTab();
            OpenDataset open = new OpenDataset("full_ms.tio", true, ds);
            t.update(open, new DatasetTreeNode(
                TreeNodeKind.QUANTIFICATIONS, "quantifications", null));
            assertEquals(expected, t.table().getItems().size());
            assertEquals(5, t.table().getColumns().size(),
                "expected 5 columns: entity, sample, abundance, unit, normalization");
        }
    }
}
