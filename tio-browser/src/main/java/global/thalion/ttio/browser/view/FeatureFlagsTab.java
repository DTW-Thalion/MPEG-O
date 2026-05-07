package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.scene.Node;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.control.cell.PropertyValueFactory;

import java.util.List;
import java.util.TreeSet;

public class FeatureFlagsTab implements AbstractDetailTab {

    private final TableView<Row> table = new TableView<>();
    private final ObservableList<Row> rows = FXCollections.observableArrayList();

    public FeatureFlagsTab() {
        table.setItems(rows);
        TableColumn<Row, String> flag = new TableColumn<>("flag");
        flag.setCellValueFactory(new PropertyValueFactory<>("flag"));
        flag.setMinWidth(280);
        TableColumn<Row, String> value = new TableColumn<>("value");
        value.setCellValueFactory(new PropertyValueFactory<>("value"));
        value.setMinWidth(160);
        table.getColumns().setAll(List.of(flag, value));
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY_FLEX_LAST_COLUMN);
    }

    @Override public String title() { return "Feature Flags"; }
    @Override public Node content() { return table; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.FEATURE_FLAGS;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        rows.clear();
        rows.add(new Row("ttio_format_version", d.formatVersion()));
        for (String f : new TreeSet<>(d.dataset().featureFlags().features())) {
            rows.add(new Row(f, "enabled"));
        }
    }

    public static class Row {
        private final String flag;
        private final String value;

        public Row(String flag, String value) {
            this.flag = flag;
            this.value = value;
        }

        public String getFlag()  { return flag; }
        public String getValue() { return value; }
    }
}
