package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import global.thalion.ttio.genomics.GenomicIndex;
import global.thalion.ttio.genomics.GenomicRun;
import javafx.scene.Node;
import javafx.scene.chart.BarChart;
import javafx.scene.chart.CategoryAxis;
import javafx.scene.chart.NumberAxis;
import javafx.scene.chart.XYChart;
import javafx.scene.layout.VBox;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Bar chart of read counts per chromosome for a {@link GenomicRun}.
 * The {@code *} bucket aggregates unmapped reads. Counts are computed
 * from {@link GenomicIndex#chromosomeAt(int)} — no full-payload load.
 */
public class ChromDistributionView implements AbstractDetailTab {

    private final CategoryAxis xAxis = new CategoryAxis();
    private final NumberAxis yAxis = new NumberAxis();
    private final BarChart<String, Number> chart = new BarChart<>(xAxis, yAxis);
    private final VBox root = new VBox(chart);

    public ChromDistributionView() {
        chart.setLegendVisible(false);
        chart.setAnimated(false);
        xAxis.setLabel("chromosome");
        yAxis.setLabel("read count");
        VBox.setVgrow(chart, javafx.scene.layout.Priority.ALWAYS);
    }

    @Override public String title() { return "Chromosome Distribution"; }
    @Override public Node content() { return root; }

    @Override
    public boolean appliesTo(DatasetTreeNode s) {
        return s.kind() == TreeNodeKind.GENOMIC_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        GenomicRun run = d.dataset().genomicRuns().get(selection.key());
        if (run == null) {
            chart.getData().clear();
            return;
        }
        Map<String, Integer> counts = computeCounts(run);
        XYChart.Series<String, Number> series = new XYChart.Series<>();
        for (Map.Entry<String, Integer> e : counts.entrySet()) {
            series.getData().add(new XYChart.Data<>(e.getKey(), e.getValue()));
        }
        chart.getData().setAll(series);
    }

    public BarChart<String, Number> chart() { return chart; }

    /** Pure-Java helper: compute read counts per chromosome.
     *  Unmapped reads (chromosome null/empty/"*") are bucketed under "*". */
    public static Map<String, Integer> computeCounts(GenomicRun run) {
        Map<String, Integer> counts = new LinkedHashMap<>();
        GenomicIndex idx = run.index();
        for (int i = 0; i < idx.count(); i++) {
            String c = idx.chromosomeAt(i);
            if (c == null || c.isEmpty()) c = "*";
            counts.merge(c, 1, Integer::sum);
        }
        return counts;
    }
}
