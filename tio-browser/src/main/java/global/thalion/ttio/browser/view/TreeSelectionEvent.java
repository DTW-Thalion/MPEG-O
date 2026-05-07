package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;

@FunctionalInterface
public interface TreeSelectionEvent {
    void onSelected(DatasetTreeNode node);
}
