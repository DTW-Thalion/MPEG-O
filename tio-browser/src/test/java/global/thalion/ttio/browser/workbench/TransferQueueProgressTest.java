/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.scene.control.ProgressBar;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the W6.1b determinate-progress fraction used by the
 * {@link TransferQueueView} progress column. Pure logic -- exercises
 * {@link TransferQueueView#runningFraction} without spinning up FX.
 */
class TransferQueueProgressTest {

    private static Transfer upload(long size, long done) {
        Transfer t = new Transfer(TransferKind.UPLOAD,
            "uri:tio:x", "/src.tio", size, Map.of());
        t.setBytesTransferred(done);
        return t;
    }

    @Test
    void knownSizeYieldsDeterminateFraction() {
        assertEquals(0.0, TransferQueueView.runningFraction(upload(1000, 0)));
        assertEquals(0.5, TransferQueueView.runningFraction(upload(1000, 500)));
        assertEquals(1.0, TransferQueueView.runningFraction(upload(1000, 1000)));
    }

    @Test
    void fractionIsClampedToUnitInterval() {
        // Defensive: never exceed 1.0 even if the callback over-reports.
        assertEquals(1.0, TransferQueueView.runningFraction(upload(1000, 1500)));
        assertEquals(0.0, TransferQueueView.runningFraction(upload(1000, -10)));
    }

    @Test
    void unknownSizeIsIndeterminate() {
        // Downloads stream without a known total (sizeBytes == 0).
        Transfer dn = new Transfer(TransferKind.DOWNLOAD,
            "uri:tio:x", "/dl.tio", 0L, Map.of());
        dn.setBytesTransferred(4096);
        assertEquals(ProgressBar.INDETERMINATE_PROGRESS,
            TransferQueueView.runningFraction(dn));
    }
}
