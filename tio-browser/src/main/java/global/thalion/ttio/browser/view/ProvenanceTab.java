package global.thalion.ttio.browser.view;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.genomics.GenomicRun;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.scene.Node;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.control.cell.PropertyValueFactory;

import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.List;

public class ProvenanceTab implements AbstractDetailTab {

    private static final DateTimeFormatter ISO =
        DateTimeFormatter.ISO_INSTANT.withZone(ZoneId.of("UTC"));

    private final TableView<Row> table = new TableView<>();
    private final ObservableList<Row> rows = FXCollections.observableArrayList();

    public ProvenanceTab() {
        table.setItems(rows);
        TableColumn<Row, String> ts = new TableColumn<>("timestamp");
        ts.setCellValueFactory(new PropertyValueFactory<>("timestamp"));
        ts.setMinWidth(180);
        TableColumn<Row, String> sw = new TableColumn<>("software");
        sw.setCellValueFactory(new PropertyValueFactory<>("software"));
        sw.setMinWidth(160);
        TableColumn<Row, String> params = new TableColumn<>("parameters");
        params.setCellValueFactory(new PropertyValueFactory<>("parameters"));
        params.setMinWidth(220);
        TableColumn<Row, Integer> ins = new TableColumn<>("inputs");
        ins.setCellValueFactory(new PropertyValueFactory<>("inputs"));
        TableColumn<Row, Integer> outs = new TableColumn<>("outputs");
        outs.setCellValueFactory(new PropertyValueFactory<>("outputs"));
        table.getColumns().setAll(List.of(ts, sw, params, ins, outs));
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY_FLEX_LAST_COLUMN);
    }

    @Override public String title() { return "Provenance"; }
    @Override public Node content() { return table; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        TreeNodeKind k = selection.kind();
        return k == TreeNodeKind.PROVENANCE
            || k == TreeNodeKind.MS_RUN || k == TreeNodeKind.NMR_RUN
            || k == TreeNodeKind.RAMAN_RUN || k == TreeNodeKind.IR_RUN
            || k == TreeNodeKind.UV_VIS_RUN || k == TreeNodeKind.GENOMIC_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        rows.clear();
        List<ProvenanceRecord> chain;
        if (selection.kind() == TreeNodeKind.PROVENANCE) {
            chain = d.dataset().provenanceRecords();
        } else if (selection.kind() == TreeNodeKind.GENOMIC_RUN) {
            GenomicRun run = d.dataset().genomicRuns().get(selection.key());
            chain = (run == null) ? List.of() : run.provenanceChain();
        } else {
            AcquisitionRun run = d.dataset().msRuns().get(selection.key());
            chain = (run == null) ? List.of() : run.provenanceChain();
        }
        for (ProvenanceRecord r : chain) {
            rows.add(new Row(
                ISO.format(Instant.ofEpochSecond(r.timestampUnix())),
                r.software(),
                truncate(r.parametersJson(), 80),
                r.inputRefs().size(),
                r.outputRefs().size()));
        }
    }

    private static String truncate(String s, int n) {
        if (s == null) return "";
        return s.length() <= n ? s : s.substring(0, n - 1) + "…";
    }

    public static class Row {
        private final String timestamp;
        private final String software;
        private final String parameters;
        private final int inputs;
        private final int outputs;

        public Row(String timestamp, String software, String parameters,
                   int inputs, int outputs) {
            this.timestamp = timestamp;
            this.software = software;
            this.parameters = parameters;
            this.inputs = inputs;
            this.outputs = outputs;
        }

        public String getTimestamp()  { return timestamp; }
        public String getSoftware()   { return software; }
        public String getParameters() { return parameters; }
        public int getInputs()        { return inputs; }
        public int getOutputs()       { return outputs; }
    }
}
