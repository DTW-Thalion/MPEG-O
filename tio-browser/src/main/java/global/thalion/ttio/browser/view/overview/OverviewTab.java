package global.thalion.ttio.browser.view.overview;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import javafx.scene.Node;
import javafx.scene.control.Label;
import javafx.scene.layout.VBox;
import javafx.scene.text.Text;

public class OverviewTab implements AbstractDetailTab {

    private final VBox root = new VBox(8);
    private String summaryText = "";

    public OverviewTab() {
        root.setStyle("-fx-padding: 16;");
    }

    @Override public String title() { return "Overview"; }
    @Override public Node content() { return root; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.DATASET_ROOT;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        root.getChildren().clear();
        StringBuilder sb = new StringBuilder();
        sb.append("Title: ").append(safeTitle(d)).append('\n');
        sb.append("ISA Investigation: ")
          .append(orDash(d.dataset().isaInvestigationId())).append('\n');
        sb.append("Format Version: v").append(d.formatVersion()).append('\n');
        sb.append("Path: ").append(d.path()).append('\n');
        sb.append("Read-only: ").append(d.readOnly() ? "yes" : "no").append('\n');
        sb.append('\n');
        sb.append("Counts:\n");
        sb.append("  · MS=").append(d.msRunCount()).append('\n');
        sb.append("  · Genomic=").append(d.genomicRunCount()).append('\n');
        sb.append("  · References=").append(d.referenceCount()).append('\n');
        sb.append("  · Identifications=").append(d.identificationCount()).append('\n');
        sb.append("  · Quantifications=").append(d.quantificationCount()).append('\n');
        sb.append("  · Provenance=").append(d.provenanceCount()).append('\n');
        sb.append('\n');
        sb.append("Feature flags: ");
        d.dataset().featureFlags().features().forEach(f -> sb.append(f).append(' '));
        sb.append('\n');
        if (d.isEncrypted()) {
            sb.append('\n').append("🔒 ENCRYPTED — algorithm: ")
              .append(d.encryptionAlgorithm()).append('\n');
        }
        this.summaryText = sb.toString();

        Text txt = new Text(summaryText);
        txt.setStyle("-fx-font-family: monospace;");
        root.getChildren().add(new Label("Dataset overview"));
        root.getChildren().add(txt);
    }

    public String summaryText() { return summaryText; }

    private static String safeTitle(OpenDataset d) {
        String t = d.dataset().title();
        return (t == null || t.isEmpty()) ? "(untitled)" : t;
    }

    private static String orDash(String s) {
        return (s == null || s.isEmpty()) ? "—" : s;
    }
}
