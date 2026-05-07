package global.thalion.ttio.browser.view;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.SpectralDataset;
import javafx.application.Platform;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

class ChannelHexViewTest extends ApplicationTest {

    private ChannelHexView view;

    @Override
    public void start(Stage stage) {
        view = new ChannelHexView();
        stage.setScene(new Scene(new StackPane(view.content()), 800, 600));
        stage.show();
    }

    @Test
    void renderPopulatesChannelListAndHexFromMassSpectrum() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            AcquisitionRun run = ds.msRuns().values().iterator().next();
            MassSpectrum s0 = (MassSpectrum) run.spectra().get(0);

            CountDownLatch done = new CountDownLatch(1);
            AtomicReference<Integer> channelCount = new AtomicReference<>();
            AtomicReference<String> hexText = new AtomicReference<>();
            Platform.runLater(() -> {
                view.render(s0);
                channelCount.set(view.channelList().getItems().size());
                hexText.set(view.hexArea().getText());
                done.countDown();
            });
            assertTrue(done.await(5, TimeUnit.SECONDS));
            assertTrue(channelCount.get() >= 2,
                "MS spectrum must expose at least mz + intensity channels; got "
                + channelCount.get());
            assertNotNull(hexText.get());
            assertFalse(hexText.get().isEmpty(),
                "auto-selecting first channel should populate hex pane");
            assertTrue(hexText.get().contains("Channel:"),
                "hex pane header should label the channel");
        }
    }

    @Test
    void clearEmptiesViewState() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/full_ms.tio")
                    .toAbsolutePath().toString())) {
            AcquisitionRun run = ds.msRuns().values().iterator().next();
            MassSpectrum s0 = (MassSpectrum) run.spectra().get(0);

            CountDownLatch done = new CountDownLatch(1);
            AtomicReference<Integer> channelCount = new AtomicReference<>();
            Platform.runLater(() -> {
                view.render(s0);
                view.clear();
                channelCount.set(view.channelList().getItems().size());
                done.countDown();
            });
            assertTrue(done.await(5, TimeUnit.SECONDS));
            assertEquals(0, (int) channelCount.get());
        }
    }
}
