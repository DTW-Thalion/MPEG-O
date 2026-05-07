package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import javafx.scene.control.TreeCell;
import javafx.scene.control.TreeItem;
import javafx.scene.control.TreeView;

public class DatasetTreeView {

    private final TreeView<DatasetTreeNode> control = new TreeView<>();
    private TreeSelectionEvent listener;

    public DatasetTreeView() {
        control.setShowRoot(true);
        control.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && listener != null) {
                    listener.onSelected(sel.getValue());
                }
            });
        control.setCellFactory(tv -> new TreeCell<>() {
            @Override
            protected void updateItem(DatasetTreeNode item, boolean empty) {
                super.updateItem(item, empty);
                setText(empty || item == null ? null : item.label());
            }
        });
    }

    public TreeView<DatasetTreeNode> control() { return control; }

    public void setRoot(DatasetTreeNode root) {
        if (root == null) {
            control.setRoot(null);
            return;
        }
        control.setRoot(buildTreeItem(root));
        control.getRoot().setExpanded(true);
    }

    public void clear() { control.setRoot(null); }

    public void onSelected(TreeSelectionEvent l) { this.listener = l; }

    private TreeItem<DatasetTreeNode> buildTreeItem(DatasetTreeNode n) {
        TreeItem<DatasetTreeNode> item = new TreeItem<>(n);
        for (DatasetTreeNode c : n.children()) {
            item.getChildren().add(buildTreeItem(c));
        }
        if (!n.children().isEmpty() && n.children().size() <= 12) {
            item.setExpanded(true);
        }
        return item;
    }
}
