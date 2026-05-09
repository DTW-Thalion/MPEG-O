package global.thalion.ttio.browser.diag;

import javafx.application.Platform;
import javafx.scene.control.Button;
import javafx.scene.control.TableView;
import javafx.stage.Stage;
import javafx.stage.Window;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

/**
 * TestFX smoke test for {@link DiagnosticsDialog}: open it, confirm
 * five rows populate (one per registered probe), click Re-probe, and
 * confirm the rows still populate to five after the async refresh.
 */
class DiagnosticsDialogTest extends ApplicationTest {

    private Stage owner;

    @Override
    public void start(Stage stage) {
        this.owner = stage;
        stage.show();
    }

    @SuppressWarnings("unchecked")
    @Test
    void dialogOpensAndPopulatesFiveRows() throws Exception {
        // Prime the cache so the dialog has something to show synchronously.
        Diagnostics.probeAll();

        AtomicReference<Stage> dialogRef = new AtomicReference<>();
        CountDownLatch shown = new CountDownLatch(1);
        Platform.runLater(() -> {
            DiagnosticsDialog.show(owner);
            for (Window w : Window.getWindows()) {
                if (w instanceof Stage s
                        && "Diagnostics".equals(s.getTitle())) {
                    dialogRef.set(s);
                    break;
                }
            }
            shown.countDown();
        });
        assertTrue(shown.await(5, TimeUnit.SECONDS),
            "DiagnosticsDialog.show must complete on FX thread");
        Stage dialog = dialogRef.get();
        assertNotNull(dialog, "Diagnostics stage must be locatable by title");

        // Wait for the async re-probe Task to finish populating.
        TableView<ProbeResult> table = findTable(dialog);
        assertNotNull(table, "DiagnosticsDialog must contain a TableView");
        assertTrue(awaitRowCount(table, 5, 5_000),
            "Diagnostics dialog should show 5 probe rows; saw " + table.getItems().size());

        // Click Re-probe; rows must still be 5 after the refresh.
        Button reprobe = findButton(dialog, "Re-probe");
        assertNotNull(reprobe, "Re-probe button must be present");
        CountDownLatch fired = new CountDownLatch(1);
        Platform.runLater(() -> {
            reprobe.fire();
            fired.countDown();
        });
        fired.await(5, TimeUnit.SECONDS);
        assertTrue(awaitRowCount(table, 5, 5_000),
            "Diagnostics dialog should still show 5 rows after Re-probe; saw "
            + table.getItems().size());

        // Cleanup
        CountDownLatch closed = new CountDownLatch(1);
        Platform.runLater(() -> { dialog.close(); closed.countDown(); });
        closed.await(2, TimeUnit.SECONDS);
    }

    private static TableView<ProbeResult> findTable(Stage dialog) {
        return dialog.getScene().getRoot().lookupAll("*").stream()
            .filter(n -> n instanceof TableView)
            .map(n -> (TableView<ProbeResult>) n)
            .findFirst()
            .orElse(null);
    }

    private static Button findButton(Stage dialog, String text) {
        return dialog.getScene().getRoot().lookupAll("*").stream()
            .filter(n -> n instanceof Button b && text.equals(b.getText()))
            .map(n -> (Button) n)
            .findFirst()
            .orElse(null);
    }

    private static boolean awaitRowCount(TableView<ProbeResult> table,
                                         int expected, long timeoutMs)
            throws InterruptedException {
        long deadline = System.nanoTime() + (long) (timeoutMs * 1e6);
        while (System.nanoTime() < deadline) {
            if (table.getItems().size() == expected) return true;
            Thread.sleep(50);
        }
        return false;
    }

    @Test
    void cacheRefreshListenerFiresAndCanDeregister() {
        int[] counter = {0};
        Runnable listener = () -> counter[0]++;
        Diagnostics.addCacheRefreshListener(listener);
        try {
            Diagnostics.probeAll();
            assertEquals(1, counter[0],
                "registered listener must be invoked once per probeAll");
            Diagnostics.probeAll();
            assertEquals(2, counter[0]);
        } finally {
            Diagnostics.removeCacheRefreshListener(listener);
        }
        Diagnostics.probeAll();
        assertEquals(2, counter[0],
            "removed listener must not be invoked");
    }

    @Test
    void listenerExceptionDoesNotBreakProbe() {
        Runnable bad = () -> { throw new RuntimeException("listener boom"); };
        Diagnostics.addCacheRefreshListener(bad);
        try {
            List<ProbeResult> results = Diagnostics.probeAll();
            assertEquals(5, results.size(),
                "probeAll must complete even when a listener throws");
        } finally {
            Diagnostics.removeCacheRefreshListener(bad);
        }
    }
}
