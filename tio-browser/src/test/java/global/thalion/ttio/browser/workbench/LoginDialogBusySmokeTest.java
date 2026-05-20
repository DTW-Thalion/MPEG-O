/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.application.Platform;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Regression guard for the "Connect button bound-value crash".
 *
 * <p>The Connect button's {@code disableProperty} is bound to the
 * field-validation binding. An earlier {@code setBusy} called
 * {@code connectBtn.setDisable(...)} directly, which JavaFX rejects
 * with {@code RuntimeException: A bound value cannot be set} -- so
 * every click on Connect threw on the FX thread before the login
 * task started, and the user saw no feedback (no request ever left
 * the client). Caught by running the win-x64 build against a live
 * WSL daemon.</p>
 *
 * <p>This test drives the exact busy toggle through the bound
 * button and asserts it does not throw + that the binding still
 * tracks the busy state.</p>
 */
class LoginDialogBusySmokeTest extends ApplicationTest {

    private LoginDialog dialog;

    @Override
    public void start(Stage stage) {
        dialog = new LoginDialog(null, new ConnectionManager());
        dialog.stage().show();
    }

    @Test
    void setBusyDoesNotThrowWithBoundConnectButton() throws Exception {
        // Valid inputs so the validation binding would otherwise
        // enable the button -- isolates the busy toggle.
        AtomicReference<Throwable> thrown = new AtomicReference<>();
        Platform.runLater(() -> {
            try {
                dialog.urlField().setText("ws://localhost:8443/transport");
                dialog.usernameField().setText("alice");
                dialog.passwordField().setText("pw");
                dialog.totpField().setText("123456");
                // The exact call that used to crash:
                dialog.setBusyForTest(true);
            } catch (Throwable t) {
                thrown.set(t);
            }
        });
        waitForFxEvents();
        assertNull(thrown.get(),
            "setBusy(true) must not throw with a bound Connect button; got: "
            + thrown.get());

        // Busy => button disabled via the binding.
        assertTrue(dialog.isBusyForTest());
        assertTrue(dialog.connectButton().isDisabled(),
            "Connect button should be disabled while busy");

        // Clearing busy with valid inputs re-enables the button.
        AtomicReference<Throwable> thrown2 = new AtomicReference<>();
        Platform.runLater(() -> {
            try { dialog.setBusyForTest(false); }
            catch (Throwable t) { thrown2.set(t); }
        });
        waitForFxEvents();
        assertNull(thrown2.get(), "setBusy(false) must not throw");
        assertFalse(dialog.isBusyForTest());
        assertFalse(dialog.connectButton().isDisabled(),
            "Connect button should re-enable when not busy + inputs valid");
    }

    private void waitForFxEvents() throws Exception {
        // Drain the FX event queue.
        for (int i = 0; i < 3; i++) {
            final Object lock = new Object();
            synchronized (lock) {
                Platform.runLater(() -> {
                    synchronized (lock) { lock.notifyAll(); }
                });
                lock.wait(2000);
            }
        }
    }
}
