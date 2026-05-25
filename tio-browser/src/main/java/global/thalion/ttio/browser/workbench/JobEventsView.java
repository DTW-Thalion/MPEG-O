/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.jobs.Job;
import global.thalion.ttio.workbench.jobs.JobEvent;
import javafx.application.Platform;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.Label;
import javafx.scene.control.TextArea;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.util.Map;

/**
 * SSE tail viewer for a single job. Opens
 * {@code GET /v1/jobs/{id}/events} and appends each frame as a
 * formatted line until the stream closes (terminal job state) or
 * the user clicks Close.
 *
 * <p>The W3 {@code JobsClient.events(jobId, consumer)} drives the
 * SSE long-poll on a worker thread; this view's consumer marshals
 * each frame to the FX thread via {@code Platform.runLater}.</p>
 *
 * <p>This class retains its {@link #show()} entry point (used from
 * {@code JobMonitor.buildContent} tail-events button) and exposes a
 * {@link #buildContent(ConnectionManager, Window, String)} static
 * method for embedded use.</p>
 */
public final class JobEventsView {

    private final Window owner;
    private final ConnectionManager manager;
    private final String jobId;
    private final Stage stage = new Stage();

    public JobEventsView(Window owner, String jobId) {
        this(owner, ConnectionManager.instance(), jobId);
    }

    /** Visible for tests. */
    public JobEventsView(Window owner, ConnectionManager manager, String jobId) {
        this.owner = owner;
        this.manager = manager;
        this.jobId = jobId;
    }

    /** Show the events view as a floating Stage (used from tail-events button). */
    public void show() {
        Region content = buildContent(manager, owner, jobId);
        Scene scene = new Scene(content, 820, 480);
        stage.setScene(scene);
        stage.setTitle("Workbench events: " + jobId);
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
        stage.show();
    }

    // ---- static helpers ----

    /** Format a single SSE frame for display. Stable order so
     *  the test suite can pin the output shape. */
    public static String formatFrame(JobEvent event) {
        StringBuilder sb = new StringBuilder();
        sb.append('[').append(event.event() == null ? "?" : event.event()).append("] ");
        for (Map.Entry<String, Object> e : event.data().entrySet()) {
            sb.append(e.getKey()).append('=')
              .append(String.valueOf(e.getValue())).append(' ');
        }
        return sb.toString().trim();
    }

    /** {@code true} when the event is a terminal-state transition
     *  (the stream should close after rendering). */
    public static boolean isTerminalEvent(JobEvent event) {
        if (event == null || !event.isStateEvent()) return false;
        Object status = event.data().get("status");
        return status instanceof String s
            && Job.TERMINAL_STATUSES.contains(s);
    }

    /**
     * Build the embeddable content region for the job events viewer.
     *
     * <p>Starts the SSE stream immediately. The returned region contains
     * a Close button that stops the stream.</p>
     *
     * @param manager the {@link ConnectionManager} whose client provides
     *                the events stream
     * @param owner   owning window (unused currently, reserved for future
     *                child dialogs)
     * @param jobId   the job whose events are streamed
     * @return the root {@link Region} of the events-viewer content
     */
    public static Region buildContent(ConnectionManager manager,
            Window owner, String jobId) {
        TextArea logArea = new TextArea();
        logArea.setEditable(false);
        logArea.setStyle("-fx-font-family: monospace;");
        Label statusLabel = new Label("Streaming...");
        Button closeBtn = new Button("Close");

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox toolbar = new HBox(8,
            new Label("Tailing job " + jobId),
            spacer, statusLabel, closeBtn);
        toolbar.setPadding(new Insets(8));

        VBox root = new VBox(toolbar, logArea);
        VBox.setVgrow(logArea, Priority.ALWAYS);

        // Stream state
        boolean[] closed = {false};
        Thread[] streamThread = {null};

        Runnable closeStream = () -> {
            closed[0] = true;
            Thread t = streamThread[0];
            if (t != null) t.interrupt();
            statusLabel.setText("Closed");
        };

        closeBtn.setOnAction(e -> closeStream.run());

        // Begin streaming
        Thread th = new Thread(() -> {
            try {
                manager.client().jobs().events(jobId, event -> {
                    if (closed[0]) return;
                    String line = formatFrame(event);
                    boolean terminal = isTerminalEvent(event);
                    Platform.runLater(() -> {
                        logArea.appendText(line + "\n");
                        if (terminal) {
                            statusLabel.setText("Terminal state: "
                                + event.data().get("status"));
                            closed[0] = true;
                        }
                    });
                });
                if (!closed[0]) {
                    Platform.runLater(() -> statusLabel.setText("Stream ended"));
                }
            } catch (Throwable t) {
                if (closed[0]) return;
                final String msg = t.getMessage() == null
                    ? t.getClass().getSimpleName() : t.getMessage();
                Platform.runLater(() -> {
                    statusLabel.setText("Error");
                    new Alert(AlertType.ERROR,
                        "SSE stream failed: " + msg,
                        ButtonType.OK).showAndWait();
                });
            }
        }, "ttio-workbench-events-" + jobId);
        th.setDaemon(true);
        streamThread[0] = th;
        th.start();

        return root;
    }
}
