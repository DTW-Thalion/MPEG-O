package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.Chromatogram;
import javafx.scene.Node;
import javafx.scene.chart.LineChart;
import javafx.scene.chart.NumberAxis;
import javafx.scene.chart.XYChart;
import javafx.scene.control.Alert;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.ToggleButton;
import javafx.scene.image.PixelReader;
import javafx.scene.image.WritableImage;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;

/**
 * Renders a {@link Chromatogram} as a time-vs-intensity line chart with
 * the same downsampler / log-Y / reset / PNG export controls as
 * {@link SpectrumPlotView}. Stem mode is intentionally omitted —
 * chromatograms are continuous traces.
 */
public class ChromatogramPlotView {

    private static final int RENDER_TARGET_POINTS = 5000;

    private final NumberAxis xAxis = new NumberAxis();
    private final NumberAxis yAxis = new NumberAxis();
    private final LineChart<Number, Number> chart = new LineChart<>(xAxis, yAxis);
    private final ToggleButton logToggle = new ToggleButton("log Y");
    private final Button resetZoom = new Button("Reset zoom");
    private final Button savePng = new Button("Save PNG…");
    private final HBox controls = new HBox(8, logToggle, resetZoom, savePng);
    private final VBox root = new VBox(4, controls, chart);

    private double[] currentX, currentY;

    public ChromatogramPlotView() {
        chart.setCreateSymbols(false);
        chart.setLegendVisible(false);
        chart.setAnimated(false);
        controls.setStyle("-fx-padding: 4 8 0 8;");
        xAxis.setLabel("time (s)");
        yAxis.setLabel("intensity");

        logToggle.selectedProperty().addListener((obs, was, now) -> rerender());
        resetZoom.setOnAction(e -> {
            xAxis.setAutoRanging(true);
            yAxis.setAutoRanging(true);
        });
        savePng.setOnAction(e -> chooseAndSavePng());
    }

    public Node content() { return root; }
    public LineChart<Number, Number> chart() { return chart; }

    public void render(Chromatogram chrom) {
        if (chrom == null) {
            currentX = currentY = null;
            chart.getData().clear();
            return;
        }
        currentX = chrom.timeValues();
        currentY = chrom.intensityValues();
        rerender();
    }

    public void clear() {
        currentX = currentY = null;
        chart.getData().clear();
    }

    private void rerender() {
        if (currentX == null || currentY == null) {
            chart.getData().clear();
            return;
        }
        double[] y = currentY;
        if (logToggle.isSelected()) {
            y = new double[currentY.length];
            for (int i = 0; i < currentY.length; i++) {
                y[i] = currentY[i] > 0 ? Math.log10(currentY[i]) : 0;
            }
        }
        XYChart.Series<Number, Number> series = new XYChart.Series<>();
        MinMaxBucketDownsampler.Result r =
            MinMaxBucketDownsampler.reduce(currentX, y, RENDER_TARGET_POINTS);
        for (int i = 0; i < r.x().length; i++) {
            series.getData().add(new XYChart.Data<>(r.x()[i], r.y()[i]));
        }
        chart.getData().setAll(series);
    }

    private void chooseAndSavePng() {
        FileChooser ch = new FileChooser();
        ch.setTitle("Save plot as PNG");
        ch.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("PNG", "*.png"));
        File target = ch.showSaveDialog(root.getScene().getWindow());
        if (target == null) return;
        try {
            saveAsPng(target);
        } catch (IOException ex) {
            Alert err = new Alert(Alert.AlertType.ERROR,
                "Save failed: " + ex.getMessage(), ButtonType.OK);
            err.setHeaderText("PNG export failed");
            err.showAndWait();
        }
    }

    /** Test seam — snapshot the chart and write a PNG. */
    public void saveAsPng(File target) throws IOException {
        WritableImage img = chart.snapshot(null, null);
        BufferedImage buf = toBufferedImage(img);
        ImageIO.write(buf, "png", target);
    }

    private static BufferedImage toBufferedImage(WritableImage img) {
        int w = (int) img.getWidth();
        int h = (int) img.getHeight();
        BufferedImage out = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
        PixelReader reader = img.getPixelReader();
        int[] row = new int[w];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                row[x] = reader.getArgb(x, y);
            }
            out.setRGB(0, y, w, 1, row, 0, w);
        }
        return out;
    }
}
