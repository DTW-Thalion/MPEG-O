package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.browser.util.CigarParser;
import global.thalion.ttio.genomics.AlignedRead;
import javafx.scene.Node;
import javafx.scene.chart.BarChart;
import javafx.scene.chart.CategoryAxis;
import javafx.scene.chart.NumberAxis;
import javafx.scene.chart.XYChart;
import javafx.scene.control.Label;
import javafx.scene.control.ScrollPane;
import javafx.scene.layout.FlowPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.scene.paint.Color;
import javafx.scene.text.Font;
import javafx.scene.text.Text;
import javafx.scene.text.TextFlow;

import java.util.List;

/**
 * Single-read inspector. Displays:
 * - metadata footer (read name, position, MAPQ, flags, lengths…)
 * - colour-coded sequence (A=green, C=blue, G=orange, T=red, N=grey)
 * - per-base quality bar chart (downsampled to ≤2000 bars for long reads)
 * - CIGAR pills (one styled label per op, capped at 200)
 *
 * <p>Pure-Java helpers ({@link #formatMetadata}) are unit-testable;
 * the full FX wiring is verified by visual inspection in the running
 * app and via TestFX smoke tests.</p>
 */
public class ReadInspectorView {

    private static final int SEQ_PAGE_BASES_PER_LINE = 50;
    private static final int SEQ_PAGE_LINES = 50;
    /** Plot every Nth quality value when the read length exceeds this. */
    private static final int QUAL_BAR_LIMIT = 2000;
    /** Maximum CIGAR pills to render inline; overflow becomes a count badge. */
    private static final int CIGAR_PILL_CAP = 200;

    private final Label metadataLabel = new Label();
    private final TextFlow sequenceFlow = new TextFlow();
    private final ScrollPane sequenceScroll = new ScrollPane(sequenceFlow);
    private final FlowPane cigarPane = new FlowPane(4, 4);
    private final CategoryAxis qualX = new CategoryAxis();
    private final NumberAxis qualY = new NumberAxis(0, 41, 5);
    private final BarChart<String, Number> qualChart = new BarChart<>(qualX, qualY);
    private final VBox root;

    public ReadInspectorView() {
        metadataLabel.setStyle("-fx-font-family: monospace; -fx-padding: 8;");
        sequenceFlow.setStyle("-fx-font-family: monospace; -fx-font-size: 11pt;"
            + " -fx-padding: 8;");
        sequenceScroll.setFitToWidth(true);
        sequenceScroll.setPrefViewportHeight(160);
        cigarPane.setStyle("-fx-padding: 4 8 4 8;");
        qualChart.setLegendVisible(false);
        qualChart.setAnimated(false);
        qualChart.setPrefHeight(160);
        qualY.setLabel("Phred");
        qualX.setLabel("base");

        root = new VBox(8,
            new Label("Metadata"), metadataLabel,
            new Label("CIGAR"),    cigarPane,
            new Label("Sequence"), sequenceScroll,
            new Label("Qualities"), qualChart);
        root.setStyle("-fx-padding: 8;");
        VBox.setVgrow(qualChart, javafx.scene.layout.Priority.SOMETIMES);
    }

    public Node content() { return root; }

    public Label metadataLabel() { return metadataLabel; }
    public TextFlow sequenceFlow() { return sequenceFlow; }
    public FlowPane cigarPane() { return cigarPane; }
    public BarChart<String, Number> qualityChart() { return qualChart; }

    public void render(AlignedRead read) {
        if (read == null) {
            clear();
            return;
        }
        metadataLabel.setText(formatMetadata(read));
        renderSequence(read.sequence());
        renderCigar(read.cigar());
        renderQualities(read.qualities());
    }

    public void clear() {
        metadataLabel.setText("");
        sequenceFlow.getChildren().clear();
        cigarPane.getChildren().clear();
        qualChart.getData().clear();
    }

    /**
     * Display a free-form placeholder message in the metadata pane and
     * blank out the sequence / CIGAR / quality regions. Used by
     * {@link ReadInspectorTab} when the row's native codec path is
     * unavailable and {@code AlignedRead} can't be materialised.
     */
    public void renderPlaceholder(String message) {
        metadataLabel.setText(message == null ? "" : message);
        sequenceFlow.getChildren().clear();
        cigarPane.getChildren().clear();
        qualChart.getData().clear();
    }

    /**
     * Pure-Java metadata formatter. Returns a multi-line, monospace
     * footer describing the read. Unmapped reads (flag &amp; 0x4 set,
     * or chromosome empty/&quot;*&quot;) get a "(unmapped)" tag and
     * have their position field omitted.
     */
    public static String formatMetadata(AlignedRead read) {
        if (read == null) return "";
        boolean unmapped = !read.isMapped()
            || read.chromosome() == null
            || read.chromosome().isEmpty()
            || "*".equals(read.chromosome());

        StringBuilder sb = new StringBuilder();
        sb.append("read_name: ").append(orDash(read.readName())).append('\n');
        if (unmapped) {
            sb.append("(unmapped)\n");
        } else {
            sb.append("chrom: ").append(read.chromosome())
              .append("    pos: ").append(read.position()).append('\n');
        }
        sb.append("MAPQ: ").append(read.mappingQuality())
          .append("    flags: 0x").append(Integer.toHexString(read.flags()))
          .append(" (").append(read.flags()).append(")")
          .append("    length: ").append(read.readLength()).append('\n');
        sb.append("paired: ").append(read.isPaired())
          .append("    reverse: ").append(read.isReverse())
          .append("    secondary: ").append(read.isSecondary())
          .append("    supplementary: ").append(read.isSupplementary()).append('\n');
        if (read.mateChromosome() != null && !read.mateChromosome().isEmpty()
                && !"*".equals(read.mateChromosome())) {
            sb.append("mate: ").append(read.mateChromosome())
              .append(":").append(read.matePosition())
              .append("    template_length: ").append(read.templateLength())
              .append('\n');
        }
        return sb.toString();
    }

    private void renderSequence(String seq) {
        sequenceFlow.getChildren().clear();
        if (seq == null || seq.isEmpty()) return;
        // Pagination: cap inline display at SEQ_PAGE_LINES * SEQ_PAGE_BASES_PER_LINE.
        int limit = SEQ_PAGE_LINES * SEQ_PAGE_BASES_PER_LINE;
        int show = Math.min(seq.length(), limit);
        for (int i = 0; i < show; i += SEQ_PAGE_BASES_PER_LINE) {
            int end = Math.min(i + SEQ_PAGE_BASES_PER_LINE, show);
            String line = seq.substring(i, end);
            for (int j = 0; j < line.length(); j++) {
                char b = line.charAt(j);
                Text t = new Text(String.valueOf(b));
                t.setFill(colourForBase(b));
                t.setFont(Font.font("monospace", 11));
                sequenceFlow.getChildren().add(t);
            }
            sequenceFlow.getChildren().add(new Text("\n"));
        }
        if (seq.length() > limit) {
            Text more = new Text("\n... " + (seq.length() - limit)
                + " more bases (truncated for display)");
            more.setFill(Color.GRAY);
            sequenceFlow.getChildren().add(more);
        }
    }

    private static Color colourForBase(char b) {
        switch (Character.toUpperCase(b)) {
            case 'A': return Color.GREEN;
            case 'C': return Color.BLUE;
            case 'G': return Color.ORANGE;
            case 'T': return Color.RED;
            case 'N': return Color.GRAY;
            default:  return Color.BLACK;
        }
    }

    private void renderCigar(String cigarStr) {
        cigarPane.getChildren().clear();
        if (cigarStr == null || cigarStr.isEmpty() || "*".equals(cigarStr)) {
            cigarPane.getChildren().add(new Label("(no CIGAR)"));
            return;
        }
        CigarParser.CappedResult capped;
        try {
            capped = CigarParser.parseCapped(cigarStr, CIGAR_PILL_CAP);
        } catch (IllegalArgumentException ex) {
            cigarPane.getChildren().add(new Label("(invalid CIGAR: " + ex.getMessage() + ")"));
            return;
        }
        for (CigarParser.CigarOp op : capped.ops()) {
            Label pill = new Label(op.length() + op.op().name().replace("EQ", "="));
            pill.setStyle(pillStyle(op.op()));
            cigarPane.getChildren().add(pill);
        }
        if (capped.truncated()) {
            Label overflow = new Label("…+" + (capped.totalOps() - capped.ops().size())
                + " more ops");
            overflow.setStyle(
                "-fx-padding: 2 6 2 6; -fx-background-color: #888;"
                + " -fx-text-fill: white; -fx-background-radius: 8;");
            cigarPane.getChildren().add(overflow);
        }
    }

    private static String pillStyle(CigarParser.Op op) {
        String bg = switch (op) {
            case M  -> "#4caf50";  // green
            case I  -> "#2196f3";  // blue
            case D  -> "#f44336";  // red
            case N  -> "#9e9e9e";  // grey
            case S  -> "#ff9800";  // orange
            case H  -> "#795548";  // brown
            case P  -> "#9c27b0";  // purple
            case EQ -> "#388e3c";  // dark green
            case X  -> "#c62828";  // dark red
        };
        return "-fx-padding: 2 6 2 6; -fx-background-color: " + bg
            + "; -fx-text-fill: white; -fx-background-radius: 8;"
            + " -fx-font-family: monospace; -fx-font-size: 10pt;";
    }

    private void renderQualities(byte[] qualities) {
        qualChart.getData().clear();
        if (qualities == null || qualities.length == 0) return;
        int n = qualities.length;
        int stride = (n > QUAL_BAR_LIMIT) ? (int) Math.ceil((double) n / QUAL_BAR_LIMIT) : 1;
        XYChart.Series<String, Number> series = new XYChart.Series<>();
        for (int i = 0; i < n; i += stride) {
            // Phred byte: 0..93 typical; render as int.
            series.getData().add(new XYChart.Data<>(
                String.valueOf(i), (qualities[i] & 0xff)));
        }
        qualChart.getData().add(series);
    }

    private static String orDash(String s) {
        return (s == null || s.isEmpty()) ? "—" : s;
    }
}
