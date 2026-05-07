package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.NMRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.UVVisSpectrum;
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
 * Renders a single spectrum as a line chart, with min/max-bucket
 * downsampling for series wider than {@link #RENDER_TARGET_POINTS}.
 *
 * <p>Controls: stem-vs-line mode toggle, log-Y, reset zoom, save PNG.
 * The PNG export uses a manual {@link WritableImage} → {@link
 * BufferedImage} conversion so we don't pull in the {@code
 * javafx.swing} module just for {@code SwingFXUtils}.
 */
public class SpectrumPlotView {

    private static final int RENDER_TARGET_POINTS = 5000;

    private final NumberAxis xAxis = new NumberAxis();
    private final NumberAxis yAxis = new NumberAxis();
    private final LineChart<Number, Number> chart = new LineChart<>(xAxis, yAxis);
    private final ToggleButton stemToggle = new ToggleButton("stems");
    private final ToggleButton logToggle = new ToggleButton("log Y");
    private final Button resetZoom = new Button("Reset zoom");
    private final Button savePng = new Button("Save PNG…");
    private final HBox controls = new HBox(8, stemToggle, logToggle, resetZoom, savePng);
    private final VBox root = new VBox(4, controls, chart);

    private double[] currentX, currentY;

    public SpectrumPlotView() {
        chart.setCreateSymbols(false);
        chart.setLegendVisible(false);
        chart.setAnimated(false);
        controls.setStyle("-fx-padding: 4 8 0 8;");

        stemToggle.selectedProperty().addListener((obs, was, now) -> rerender());
        logToggle.selectedProperty().addListener((obs, was, now) -> rerender());
        resetZoom.setOnAction(e -> {
            xAxis.setAutoRanging(true);
            yAxis.setAutoRanging(true);
        });
        savePng.setOnAction(e -> chooseAndSavePng());
    }

    public Node content() { return root; }
    public LineChart<Number, Number> chart() { return chart; }
    public ToggleButton stemToggle() { return stemToggle; }
    public ToggleButton logToggle() { return logToggle; }

    public void render(Spectrum spec) {
        if (spec == null) {
            currentX = currentY = null;
            chart.getData().clear();
            return;
        }
        configureAxesFor(spec);
        // Default stem mode for centroided MS spectra (mzML MS:1000127)
        // and line mode for everything else. The toggle is still
        // available for override on the next render.
        if (spec instanceof MassSpectrum ms) {
            stemToggle.setSelected(ms.isCentroided());
        } else {
            stemToggle.setSelected(false);
        }
        currentX = xValuesFor(spec);
        currentY = yValuesFor(spec);
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
        if (stemToggle.isSelected()) {
            for (int i = 0; i < currentX.length; i++) {
                series.getData().add(new XYChart.Data<>(currentX[i], 0));
                series.getData().add(new XYChart.Data<>(currentX[i], y[i]));
                series.getData().add(new XYChart.Data<>(currentX[i], 0));
            }
        } else {
            MinMaxBucketDownsampler.Result r =
                MinMaxBucketDownsampler.reduce(currentX, y, RENDER_TARGET_POINTS);
            for (int i = 0; i < r.x().length; i++) {
                series.getData().add(new XYChart.Data<>(r.x()[i], r.y()[i]));
            }
        }
        chart.getData().setAll(series);
    }

    private void configureAxesFor(Spectrum spec) {
        if (spec instanceof MassSpectrum) {
            xAxis.setLabel("m/z"); yAxis.setLabel("intensity");
            xAxis.setForceZeroInRange(false);
        } else if (spec instanceof NMRSpectrum) {
            // NMR convention: chemical shift increases right→left. JavaFX
            // NumberAxis has no native reversed-axis flag; documenting as a
            // known v0.1 limitation.
            xAxis.setLabel("ppm"); yAxis.setLabel("intensity");
        } else if (spec instanceof RamanSpectrum) {
            xAxis.setLabel("wavenumber (1/cm)"); yAxis.setLabel("intensity");
        } else if (spec instanceof IRSpectrum) {
            xAxis.setLabel("wavenumber (1/cm)"); yAxis.setLabel("absorbance");
        } else if (spec instanceof UVVisSpectrum) {
            xAxis.setLabel("wavelength (nm)"); yAxis.setLabel("absorbance");
        }
    }

    private static double[] xValuesFor(Spectrum spec) {
        if (spec instanceof MassSpectrum ms)  return ms.mzValues();
        if (spec instanceof NMRSpectrum nmr)  return nmr.chemicalShiftValues();
        if (spec instanceof RamanSpectrum r)  return r.wavenumberValues();
        if (spec instanceof IRSpectrum ir)    return ir.wavenumberValues();
        if (spec instanceof UVVisSpectrum uv) return uv.wavelengthValues();
        return new double[0];
    }

    private static double[] yValuesFor(Spectrum spec) {
        if (spec instanceof MassSpectrum ms)  return ms.intensityValues();
        if (spec instanceof NMRSpectrum nmr)  return nmr.intensityValues();
        if (spec instanceof RamanSpectrum r)  return r.intensityValues();
        if (spec instanceof IRSpectrum ir)    return ir.intensityValues();
        if (spec instanceof UVVisSpectrum uv) return uv.absorbanceValues();
        return new double[0];
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
