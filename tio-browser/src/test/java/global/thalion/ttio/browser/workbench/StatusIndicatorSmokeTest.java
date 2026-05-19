/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.auth.InvalidCredentialsException;
import global.thalion.ttio.workbench.auth.Session;
import javafx.application.Platform;
import javafx.scene.Scene;
import javafx.scene.layout.StackPane;
import javafx.scene.paint.Color;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class StatusIndicatorSmokeTest extends ApplicationTest {

    private ConnectionManager manager;
    private StatusIndicator indicator;

    @Override
    public void start(Stage stage) {
        manager = new ConnectionManager();
        indicator = new StatusIndicator(manager);
        stage.setScene(new Scene(new StackPane(indicator.node()), 240, 60));
        stage.show();
    }

    @Test
    void disconnectedRendersGreyAndDescriptiveLabel() {
        // No connection has happened yet -- indicator starts disconnected.
        assertEquals(ConnectionState.DISCONNECTED, manager.state());
        assertTrue(indicator.label().getText().contains("disconnected"));
        assertEquals(Color.web("#888888"), indicator.swatch().getFill());
    }

    @Test
    void connectedTransitionsRenderToGreen() throws Exception {
        Session fake = new Session(
            "ttiowbs_" + "x".repeat(43),
            "alice", "01HXYUSR",
            Set.of("containers.read.own_project"),
            List.of("alpha"),
            2_000_000_000L,
            "password-totp",
            "01HXYSES");
        AuthProvider auth = new AuthProvider() {
            @Override public String username() { return "alice"; }
            @Override public Session authenticate(String h, int p, String s) { return fake; }
        };

        Platform.runLater(() -> manager.connect("ws://localhost:8443", auth));

        long deadline = System.nanoTime() + (long) 3e9;
        while (System.nanoTime() < deadline) {
            if (indicator.swatch().getFill().equals(Color.web("#1d8a3b"))) break;
            Thread.sleep(20);
        }
        assertEquals(Color.web("#1d8a3b"), indicator.swatch().getFill());
        assertTrue(indicator.label().getText().contains("connected"),
            "label was: " + indicator.label().getText());
        assertTrue(indicator.label().getText().contains("alice"),
            "label should include username; was: " + indicator.label().getText());
    }

    @Test
    void failedTransitionsRenderToRedWithTooltip() throws Exception {
        AuthProvider auth = new AuthProvider() {
            @Override public String username() { return "alice"; }
            @Override public Session authenticate(String h, int p, String s) {
                throw new InvalidCredentialsException("invalid TOTP");
            }
        };

        Platform.runLater(() -> {
            try {
                manager.connect("ws://localhost:8443", auth);
            } catch (RuntimeException ignored) {
                // Expected -- FAILED transition fires before rethrow.
            }
        });

        long deadline = System.nanoTime() + (long) 3e9;
        while (System.nanoTime() < deadline) {
            if (indicator.swatch().getFill().equals(Color.web("#c0392b"))) break;
            Thread.sleep(20);
        }
        assertEquals(Color.web("#c0392b"), indicator.swatch().getFill());
        assertTrue(indicator.tooltip().getText().contains("invalid TOTP"),
            "tooltip should carry the error message; was: "
            + indicator.tooltip().getText());
    }
}
