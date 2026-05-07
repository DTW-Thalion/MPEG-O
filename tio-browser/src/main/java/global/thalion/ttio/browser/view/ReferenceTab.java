package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.genomics.ReferenceImport;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.geometry.Insets;
import javafx.scene.Node;
import javafx.scene.control.Label;
import javafx.scene.control.ListView;
import javafx.scene.control.SplitPane;
import javafx.scene.control.TextArea;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.VBox;

import java.util.Map;

/**
 * Detail tab for an embedded reference (Phase 0 {@code references()}
 * accessor). Top: GridPane with URI / chromosome count / total bases /
 * MD5 hex. Bottom: chromosome list (left) + sequence preview (right,
 * first 4 KiB as plain text).
 */
public class ReferenceTab implements AbstractDetailTab {

    private static final int SEQ_PREVIEW_BYTES = 4096;

    private final GridPane grid = new GridPane();
    private final ListView<String> chromList = new ListView<>();
    private final TextArea sequencePreview = new TextArea();
    private final SplitPane chromSplit = new SplitPane(chromList, sequencePreview);
    private final VBox root = new VBox(8, new Label("Reference"), grid,
        new Label("Chromosomes"), chromSplit);

    private ReferenceImport currentImport;
    private String shownUri = "";
    private int shownChromosomeCount = 0;
    private long shownTotalBases = 0;

    public ReferenceTab() {
        root.setPadding(new Insets(8));
        grid.setHgap(12);
        grid.setVgap(6);
        sequencePreview.setEditable(false);
        sequencePreview.setStyle("-fx-font-family: monospace; -fx-font-size: 10pt;");
        chromList.setMinWidth(180);
        chromSplit.setDividerPositions(0.25);
        VBox.setVgrow(chromSplit, javafx.scene.layout.Priority.ALWAYS);
        chromList.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> renderSequencePreview(sel));
    }

    @Override public String title() { return "Reference"; }
    @Override public Node content() { return root; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.REFERENCE;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        Map<String, ReferenceImport> refs = d.dataset().references();
        ReferenceImport ref = refs.get(selection.key());
        currentImport = ref;
        rebuildGrid(ref);
        if (ref == null) {
            shownUri = ""; shownChromosomeCount = 0; shownTotalBases = 0;
            chromList.setItems(FXCollections.observableArrayList());
            sequencePreview.clear();
            return;
        }
        shownUri = ref.uri();
        shownChromosomeCount = ref.chromosomes().size();
        shownTotalBases = ref.totalBases();
        ObservableList<String> chroms = FXCollections.observableArrayList(ref.chromosomes());
        chromList.setItems(chroms);
        sequencePreview.clear();
        if (!chroms.isEmpty()) {
            chromList.getSelectionModel().select(0);
        }
    }

    private void rebuildGrid(ReferenceImport ref) {
        grid.getChildren().clear();
        addRow(0, "URI:",              ref == null ? "—" : ref.uri());
        addRow(1, "Chromosomes:",      ref == null ? "0" : String.valueOf(ref.chromosomes().size()));
        addRow(2, "Total bases:",      ref == null ? "0" : String.valueOf(ref.totalBases()));
        addRow(3, "MD5 (hex):",        ref == null ? "—" : ref.md5Hex());
    }

    private void addRow(int r, String k, String v) {
        Label key = new Label(k);
        key.setStyle("-fx-font-weight: bold;");
        grid.add(key, 0, r);
        grid.add(new Label(v), 1, r);
    }

    private void renderSequencePreview(String chromName) {
        if (currentImport == null || chromName == null) {
            sequencePreview.clear();
            return;
        }
        byte[] seq = currentImport.chromosome(chromName);
        if (seq == null) {
            sequencePreview.setText("(chromosome " + chromName + " not found)");
            return;
        }
        int show = Math.min(seq.length, SEQ_PREVIEW_BYTES);
        StringBuilder sb = new StringBuilder();
        sb.append(chromName).append(" — ").append(seq.length).append(" bases\n\n");
        for (int i = 0; i < show; i += 60) {
            int end = Math.min(i + 60, show);
            sb.append(new String(seq, i, end - i,
                java.nio.charset.StandardCharsets.US_ASCII));
            sb.append('\n');
        }
        if (seq.length > show) {
            sb.append("\n... ").append(seq.length - show)
              .append(" more bases (truncated for display)\n");
        }
        sequencePreview.setText(sb.toString());
    }

    public String shownUri() { return shownUri; }
    public int shownChromosomeCount() { return shownChromosomeCount; }
    public long shownTotalBases() { return shownTotalBases; }
    public ListView<String> chromList() { return chromList; }
    public TextArea sequencePreview() { return sequencePreview; }
}
