package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.SpectralDataset;
import javafx.application.Platform;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

class SpectrumPlotViewTest extends ApplicationTest {

    private SpectrumPlotView view;

    @Override
    public void start(Stage stage) {
        view = new SpectrumPlotView();
        stage.setScene(new Scene(new StackPane(view.content()), 800, 600));
        stage.show();
    }

    @Test
    void plotRendersFromMassSpectrumWithoutThrowing() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            AcquisitionRun run = ds.msRuns().values().iterator().next();
            assertFalse(run.spectra().isEmpty(), "fixture must have ≥1 spectrum");
            MassSpectrum s0 = (MassSpectrum) run.spectra().get(0);

            CountDownLatch done = new CountDownLatch(1);
            Platform.runLater(() -> {
                view.render(s0);
                done.countDown();
            });
            assertTrue(done.await(5, TimeUnit.SECONDS), "render must complete");

            CountDownLatch checked = new CountDownLatch(1);
            AtomicReference<Integer> seriesCount = new AtomicReference<>(0);
            Platform.runLater(() -> {
                seriesCount.set(view.chart().getData().size());
                checked.countDown();
            });
            assertTrue(checked.await(2, TimeUnit.SECONDS));
            assertEquals(1, (int) seriesCount.get(),
                "render must produce exactly one series");
        }
    }

    @Test
    void saveAsPngWritesNonEmptyFile(@org.junit.jupiter.api.io.TempDir Path tmp)
            throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            AcquisitionRun run = ds.msRuns().values().iterator().next();
            MassSpectrum s0 = (MassSpectrum) run.spectra().get(0);

            CountDownLatch rendered = new CountDownLatch(1);
            Platform.runLater(() -> {
                view.render(s0);
                rendered.countDown();
            });
            assertTrue(rendered.await(5, TimeUnit.SECONDS));

            File png = tmp.resolve("plot.png").toFile();
            CountDownLatch saved = new CountDownLatch(1);
            AtomicReference<Exception> err = new AtomicReference<>();
            Platform.runLater(() -> {
                try {
                    view.saveAsPng(png);
                } catch (Exception ex) {
                    err.set(ex);
                } finally {
                    saved.countDown();
                }
            });
            assertTrue(saved.await(5, TimeUnit.SECONDS));
            if (err.get() != null) throw err.get();
            assertTrue(png.exists(), "PNG file should exist");
            assertTrue(Files.size(png.toPath()) > 0, "PNG should be non-empty");
        }
    }

    @Test
    void stemToggleAutoSelectsForCentroidedMs() throws Exception {
        // Synthesize centroided + profile MS spectra directly so we don't
        // depend on a fixture carrying the centroideds column on disk.
        global.thalion.ttio.MassSpectrum centroidedMs =
            new global.thalion.ttio.MassSpectrum(
                new double[]{100, 200, 300}, new double[]{1, 5, 2},
                0, 0.0, 0.0, 0,
                1, global.thalion.ttio.Enums.Polarity.POSITIVE, null,
                global.thalion.ttio.Enums.ActivationMethod.NONE, null,
                /* centroided= */ true);
        global.thalion.ttio.MassSpectrum profileMs =
            new global.thalion.ttio.MassSpectrum(
                new double[]{100, 200, 300}, new double[]{1, 5, 2},
                0, 0.0, 0.0, 0,
                1, global.thalion.ttio.Enums.Polarity.POSITIVE, null,
                global.thalion.ttio.Enums.ActivationMethod.NONE, null,
                /* centroided= */ false);

        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<Boolean> stemAfterCentroid = new AtomicReference<>();
        AtomicReference<Boolean> stemAfterProfile = new AtomicReference<>();
        Platform.runLater(() -> {
            view.render(centroidedMs);
            stemAfterCentroid.set(view.stemToggle().isSelected());
            view.render(profileMs);
            stemAfterProfile.set(view.stemToggle().isSelected());
            done.countDown();
        });
        assertTrue(done.await(5, TimeUnit.SECONDS));
        assertEquals(Boolean.TRUE, stemAfterCentroid.get(),
            "centroided MS should auto-select stem mode");
        assertEquals(Boolean.FALSE, stemAfterProfile.get(),
            "profile MS should default to line mode");
    }

    @Test
    void clearEmptiesChartData() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            AcquisitionRun run = ds.msRuns().values().iterator().next();
            MassSpectrum s0 = (MassSpectrum) run.spectra().get(0);

            CountDownLatch done = new CountDownLatch(1);
            Platform.runLater(() -> {
                view.render(s0);
                view.clear();
                done.countDown();
            });
            assertTrue(done.await(5, TimeUnit.SECONDS));

            CountDownLatch checked = new CountDownLatch(1);
            AtomicReference<Integer> seriesCount = new AtomicReference<>(0);
            Platform.runLater(() -> {
                seriesCount.set(view.chart().getData().size());
                checked.countDown();
            });
            assertTrue(checked.await(2, TimeUnit.SECONDS));
            assertEquals(0, (int) seriesCount.get());
        }
    }
}
