package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import javafx.beans.property.SimpleObjectProperty;
import javafx.scene.Node;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;

import java.util.function.Consumer;
import java.util.function.Function;

public abstract class HeadersTableBase<R> implements AbstractDetailTab {

    protected final TableView<R> table = new TableView<>();
    private Consumer<R> rowSelectedListener;

    protected HeadersTableBase() {
        table.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && rowSelectedListener != null) {
                    rowSelectedListener.accept(sel);
                }
            });
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY_FLEX_LAST_COLUMN);
    }

    @Override public Node content() { return table; }

    public TableView<R> table() { return table; }

    public void onRowSelected(Consumer<R> l) { this.rowSelectedListener = l; }

    protected final <T> TableColumn<R, T> col(String header, Function<R, T> getter) {
        TableColumn<R, T> c = new TableColumn<>(header);
        c.setCellValueFactory(cd -> new SimpleObjectProperty<>(getter.apply(cd.getValue())));
        c.setSortable(true);
        return c;
    }

    @Override
    public abstract void update(OpenDataset d, DatasetTreeNode selection);
}
