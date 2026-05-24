/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.workbench.Transfer;
import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class TransferStripTest extends ApplicationTest {

    private TransferStrip strip;
    private TransferManager tm;
    private final java.util.concurrent.atomic.AtomicBoolean clicked =
        new java.util.concurrent.atomic.AtomicBoolean(false);

    @Override
    public void start(Stage stage) {
        tm = TransferManager.instance();
        tm.clearAllForTest();
        strip = new TransferStrip(tm);
        strip.onViewAll(() -> clicked.set(true));
        stage.setScene(new Scene(new StackPane(strip.node()), 600, 40));
        stage.show();
    }

    @Test
    void hiddenWhenNoTransfers() {
        assertFalse(strip.node().isVisible(),
            "strip should be hidden when no transfers exist");
    }

    @Test
    void visibleAndShowsSummaryWhenTransferStarts() throws Exception {
        Transfer t = tm.newFakeUploadForTest(/*bytesTotal=*/1000L);
        interact(() -> {
            tm.startForTest(t);
            tm.fakeProgress(t, new ProgressReport("uploading",
                500L, 1000L, -1L, -1L, 100.0, Double.NaN, 5L, 5L,
                System.currentTimeMillis()));
        });
        assertTrue(strip.node().isVisible(),
            "strip should be visible while a transfer is active");
        String text = strip.label().getText();
        assertTrue(text.contains("50.0%") || text.contains("↑")
            || text.contains("uploading"),
            "label should describe the active transfer: " + text);
    }

    @Test
    void viewAllClickFiresCallback() {
        Transfer t = tm.newFakeUploadForTest(1000L);
        interact(() -> tm.startForTest(t));
        clickOn(strip.viewAllButtonForTest());
        assertTrue(clicked.get(),
            "onViewAll callback should fire when [view all] is clicked");
    }
}
