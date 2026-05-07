package global.thalion.ttio.browser.view;

import global.thalion.ttio.Identification;
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

public class IdentificationsTab implements AbstractDetailTab {

    private final TableView<Row> table = new TableView<>();
    private final ObservableList<Row> rows = FXCollections.observableArrayList();

    public IdentificationsTab() {
        table.setItems(rows);
        TableColumn<Row, String> run = new TableColumn<>("run");
        run.setCellValueFactory(new PropertyValueFactory<>("run"));
        run.setMinWidth(140);
        TableColumn<Row, Integer> idx = new TableColumn<>("spectrum idx");
        idx.setCellValueFactory(new PropertyValueFactory<>("spectrumIndex"));
        TableColumn<Row, String> entity = new TableColumn<>("chemical entity");
        entity.setCellValueFactory(new PropertyValueFactory<>("chemicalEntity"));
        entity.setMinWidth(180);
        TableColumn<Row, Double> score = new TableColumn<>("confidence");
        score.setCellValueFactory(new PropertyValueFactory<>("confidenceScore"));
        TableColumn<Row, Integer> evidence = new TableColumn<>("evidence");
        evidence.setCellValueFactory(new PropertyValueFactory<>("evidenceCount"));
        table.getColumns().setAll(List.of(run, idx, entity, score, evidence));
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY_FLEX_LAST_COLUMN);
    }

    @Override public String title() { return "Identifications"; }
    @Override public Node content() { return table; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.IDENTIFICATIONS;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        rows.clear();
        for (Identification id : d.dataset().identifications()) {
            rows.add(new Row(id.runName(), id.spectrumIndex(),
                id.chemicalEntity(), id.confidenceScore(),
                id.evidenceChain().size()));
        }
    }

    public TableView<Row> table() { return table; }

    public static class Row {
        private final String run;
        private final int spectrumIndex;
        private final String chemicalEntity;
        private final double confidenceScore;
        private final int evidenceCount;

        public Row(String run, int spectrumIndex, String chemicalEntity,
                   double confidenceScore, int evidenceCount) {
            this.run = run;
            this.spectrumIndex = spectrumIndex;
            this.chemicalEntity = chemicalEntity;
            this.confidenceScore = confidenceScore;
            this.evidenceCount = evidenceCount;
        }

        public String getRun()             { return run; }
        public int getSpectrumIndex()      { return spectrumIndex; }
        public String getChemicalEntity()  { return chemicalEntity; }
        public double getConfidenceScore() { return confidenceScore; }
        public int getEvidenceCount()      { return evidenceCount; }
    }
}
