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
 */
public final class JobEventsView {

    private final Window owner;
    private final ConnectionManager manager;
    private final String jobId;
    private final Stage stage = new Stage();
    private final TextArea logArea = new TextArea();
    private final Label statusLabel = new Label("Streaming...");
    private final Button closeBtn = new Button("Close");

    private volatile boolean closed = false;
    private volatile Thread streamThread;

    public JobEventsView(Window owner, String jobId) {
        this(owner, ConnectionManager.instance(), jobId);
    }

    /** Visible for tests. */
    public JobEventsView(Window owner, ConnectionManager manager, String jobId) {
        this.owner = owner;
        this.manager = manager;
        this.jobId = jobId;
        buildUi();
        wireActions();
    }

    public void show() {
        stage.show();
        beginStream();
    }

    // ---- TestFX accessors ----

    Stage stage()             { return stage; }
    TextArea logArea()        { return logArea; }
    Label statusLabel()       { return statusLabel; }
    Button closeButton()      { return closeBtn; }

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

    // ---- UI ----

    private void buildUi() {
        logArea.setEditable(false);
        logArea.setStyle("-fx-font-family: monospace;");

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox toolbar = new HBox(8,
            new Label("Tailing job " + jobId),
            spacer, statusLabel, closeBtn);
        toolbar.setPadding(new Insets(8));

        VBox root = new VBox(toolbar, logArea);
        VBox.setVgrow(logArea, Priority.ALWAYS);

        Scene scene = new Scene(root, 820, 480);
        stage.setScene(scene);
        stage.setTitle("Workbench events: " + jobId);
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        closeBtn.setOnAction(e -> closeStream());
        stage.setOnCloseRequest(e -> closeStream());
    }

    private void closeStream() {
        closed = true;
        Thread t = streamThread;
        if (t != null) t.interrupt();
        statusLabel.setText("Closed");
        stage.close();
    }

    private void beginStream() {
        streamThread = new Thread(() -> {
            try {
                manager.client().jobs().events(jobId, event -> {
                    if (closed) return;
                    String line = formatFrame(event);
                    boolean terminal = isTerminalEvent(event);
                    Platform.runLater(() -> {
                        logArea.appendText(line + "\n");
                        if (terminal) {
                            statusLabel.setText("Terminal state: "
                                + event.data().get("status"));
                            closed = true;
                        }
                    });
                });
                if (!closed) {
                    Platform.runLater(() -> statusLabel.setText("Stream ended"));
                }
            } catch (Throwable t) {
                if (closed) return;
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
        streamThread.setDaemon(true);
        streamThread.start();
    }
}
