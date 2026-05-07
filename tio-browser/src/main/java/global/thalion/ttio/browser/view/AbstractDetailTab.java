package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import javafx.scene.Node;

public interface AbstractDetailTab {
    String title();
    Node content();
    void update(OpenDataset dataset, DatasetTreeNode selection);
    boolean appliesTo(DatasetTreeNode selection);
}
