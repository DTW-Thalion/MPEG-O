/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.application.Platform;
import javafx.geometry.Pos;
import javafx.scene.control.Label;
import javafx.scene.control.Tooltip;
import javafx.scene.layout.HBox;
import javafx.scene.paint.Color;
import javafx.scene.shape.Circle;

/**
 * Small status-bar widget showing the current workbench connection
 * state: a coloured circle + a label. Subscribes to
 * {@link ConnectionManager} on construction and marshals state
 * updates to the FX thread.
 *
 * <p>Used by {@code MainWindow} on the right edge of the status
 * bar, mirroring the existing {@code statusBarLabel} on the left
 * (which carries dataset-open state).</p>
 */
public final class StatusIndicator {

    private static final double RADIUS = 5.5;

    private final ConnectionManager manager;
    private final HBox container;
    private final Circle swatch;
    private final Label label;
    private final Tooltip tooltip;
    private final ConnectionListener listener;

    public StatusIndicator() { this(ConnectionManager.instance()); }

    /** Visible for tests. */
    public StatusIndicator(ConnectionManager manager) {
        this.manager = manager;
        this.swatch = new Circle(RADIUS);
        this.label = new Label();
        this.tooltip = new Tooltip();
        this.container = new HBox(6, swatch, label);
        this.container.setAlignment(Pos.CENTER_LEFT);
        Tooltip.install(container, tooltip);

        render(manager.state(), manager.lastMessage());
        this.listener = (state, message) -> {
            if (Platform.isFxApplicationThread()) {
                render(state, message);
            } else {
                Platform.runLater(() -> render(state, message));
            }
        };
        manager.addListener(listener);
    }

    /** Detach from the manager. The host should call this when the
     *  containing window closes so the listener doesn't pin the
     *  indicator after the window is gone. */
    public void dispose() { manager.removeListener(listener); }

    /** Backing node for insertion into the status bar. */
    public HBox node() { return container; }

    /** Visible for tests. */
    Circle swatch() { return swatch; }
    Label label() { return label; }
    Tooltip tooltip() { return tooltip; }

    private void render(ConnectionState state, String message) {
        switch (state) {
            case DISCONNECTED -> {
                swatch.setFill(Color.web("#888888"));
                label.setText("workbench: disconnected");
                tooltip.setText("Not connected to a workbench server.");
            }
            case CONNECTING -> {
                swatch.setFill(Color.web("#d4a000"));
                label.setText("workbench: connecting...");
                tooltip.setText(message == null ? "" : message);
            }
            case CONNECTED -> {
                swatch.setFill(Color.web("#1d8a3b"));
                String detail = "";
                if (manager.session() != null) {
                    detail = manager.session().username();
                    if (manager.client() != null) {
                        detail += " @ " + manager.client().host();
                    }
                }
                label.setText("workbench: connected"
                    + (detail.isEmpty() ? "" : " (" + detail + ")"));
                tooltip.setText(detail.isEmpty()
                    ? "Connected."
                    : "Connected as " + detail + ".");
            }
            case FAILED -> {
                swatch.setFill(Color.web("#c0392b"));
                label.setText("workbench: failed");
                tooltip.setText(message == null || message.isEmpty()
                    ? "Last login attempt failed."
                    : message);
            }
        }
    }
}
