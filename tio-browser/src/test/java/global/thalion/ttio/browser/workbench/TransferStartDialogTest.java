/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;


class TransferStartDialogTest extends ApplicationTest {

    private TransferStartDialog dlg;
    private Stage owner;

    @Override
    public void start(Stage stage) {
        owner = stage;
        stage.setScene(new Scene(new StackPane(), 100, 100));
        stage.show();
    }

    @Test
    void defaultDirectionIsUpload() {
        interact(() -> {
            dlg = new TransferStartDialog(owner, /*connected=*/false);
            dlg.showForTest();
        });
        assertEquals(TransferStartDialog.Direction.UPLOAD, dlg.direction());
    }

    @Test
    void switchingToDownloadShowsSelectiveAccessSection() {
        interact(() -> { dlg = new TransferStartDialog(owner, false); dlg.showForTest(); });
        assertFalse(dlg.selectiveAccessVisible(),
            "selective access hidden by default (upload selected)");
        interact(() -> dlg.setDirection(TransferStartDialog.Direction.DOWNLOAD));
        assertTrue(dlg.selectiveAccessVisible(),
            "selective access visible when direction = download");
    }

    @Test
    void scopeDefaultsToConnectedWhenSessionExists() {
        interact(() -> { dlg = new TransferStartDialog(owner, /*connected=*/true); dlg.showForTest(); });
        assertEquals(TransferStartDialog.Scope.CONNECTED, dlg.scope());
    }

    @Test
    void scopeDefaultsToAnonymousWhenOffline() {
        interact(() -> { dlg = new TransferStartDialog(owner, /*connected=*/false); dlg.showForTest(); });
        assertEquals(TransferStartDialog.Scope.ANONYMOUS_URL, dlg.scope());
    }

    @Test
    void submitDisabledWhenNoSourceSelected() {
        interact(() -> { dlg = new TransferStartDialog(owner, true); dlg.showForTest(); });
        assertTrue(dlg.submitButton().isDisabled(),
            "submit must be disabled with empty source");
    }

    @Test
    void submitEnabledForAnonymousWhenUrlAndSourcePresent() {
        interact(() -> {
            dlg = new TransferStartDialog(owner, false);
            dlg.showForTest();
            dlg.setSourceForTest("/tmp/x.tio");
            dlg.setUrlForTest("https://example.com/up");
        });
        assertFalse(dlg.submitButton().isDisabled(),
            "anonymous scope submit must be enabled when URL + source filled");
    }

    @Test
    void anonymousUploadSubmitEnqueuesIntoTransferManager() {
        var tm = TransferManager.instance();
        tm.clearAllForTest();
        interact(() -> {
            dlg = new TransferStartDialog(owner, false);
            dlg.showForTest();
            dlg.setSourceForTest("/tmp/x.tio");
            dlg.setUrlForTest("https://example.com/no-real-server");
            dlg.setTokenForTest("");
        });
        interact(() -> dlg.submitButton().fire());
        assertEquals(1, tm.transfers().size());
        var t = tm.transfers().get(0);
        assertEquals(TransferKind.UPLOAD, t.kind());
        assertEquals("https://example.com/no-real-server", t.containerUri());
        // The transfer will FAIL almost immediately because the URL is fake;
        // we do not assert state here (it depends on timing).
    }
}
