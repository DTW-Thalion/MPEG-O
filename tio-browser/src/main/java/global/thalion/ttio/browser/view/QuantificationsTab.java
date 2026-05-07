package global.thalion.ttio.browser.view;

import global.thalion.ttio.Quantification;
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

public class QuantificationsTab implements AbstractDetailTab {

    private final TableView<Row> table = new TableView<>();
    private final ObservableList<Row> rows = FXCollections.observableArrayList();

    public QuantificationsTab() {
        table.setItems(rows);
        TableColumn<Row, String> entity = new TableColumn<>("chemical entity");
        entity.setCellValueFactory(new PropertyValueFactory<>("chemicalEntity"));
        entity.setMinWidth(200);
        TableColumn<Row, String> sample = new TableColumn<>("sample");
        sample.setCellValueFactory(new PropertyValueFactory<>("sampleRef"));
        sample.setMinWidth(140);
        TableColumn<Row, Double> abundance = new TableColumn<>("abundance");
        abundance.setCellValueFactory(new PropertyValueFactory<>("abundance"));
        TableColumn<Row, String> norm = new TableColumn<>("normalization");
        norm.setCellValueFactory(new PropertyValueFactory<>("normalizationMethod"));
        table.getColumns().setAll(List.of(entity, sample, abundance, norm));
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY_FLEX_LAST_COLUMN);
    }

    @Override public String title() { return "Quantifications"; }
    @Override public Node content() { return table; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.QUANTIFICATIONS;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        rows.clear();
        for (Quantification q : d.dataset().quantifications()) {
            rows.add(new Row(q.chemicalEntity(), q.sampleRef(),
                q.abundance(), nullSafe(q.normalizationMethod())));
        }
    }

    public TableView<Row> table() { return table; }

    private static String nullSafe(String s) { return s == null ? "" : s; }

    public static class Row {
        private final String chemicalEntity;
        private final String sampleRef;
        private final double abundance;
        private final String normalizationMethod;

        public Row(String chemicalEntity, String sampleRef,
                   double abundance, String normalizationMethod) {
            this.chemicalEntity = chemicalEntity;
            this.sampleRef = sampleRef;
            this.abundance = abundance;
            this.normalizationMethod = normalizationMethod;
        }

        public String getChemicalEntity()       { return chemicalEntity; }
        public String getSampleRef()            { return sampleRef; }
        public double getAbundance()            { return abundance; }
        public String getNormalizationMethod()  { return normalizationMethod; }
    }
}
