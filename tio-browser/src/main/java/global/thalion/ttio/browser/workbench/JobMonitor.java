/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.jobs.Job;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.Label;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Window;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;

/**
 * Workbench job-monitor content builder. TableView<Job> with refresh /
 * filter-by-status / cancel-selected / tail-events controls.
 *
 * <p>Drives the W3 {@link global.thalion.ttio.workbench.jobs.JobsClient};
 * SSE tail-events are opened in a separate {@link JobEventsView}
 * window.</p>
 *
 * <p>This class no longer manages a Stage; call
 * {@link #buildContent(ConnectionManager, Window)} to obtain an embeddable
 * {@link Region} suitable for use inside {@code JobsWorkspace}.</p>
 */
public final class JobMonitor {

    private static final List<String> STATUS_FILTERS = List.of(
        "(all)", "queued", "starting", "running",
        "completed", "failed", "cancelled");

    private JobMonitor() {}

    // ---- static helpers ----

    /** Format a Unix-epoch-seconds timestamp as ISO-8601 UTC.
     *  Null / 0 renders as blank. */
    public static String formatTimestamp(Long epochSeconds) {
        if (epochSeconds == null || epochSeconds <= 0) return "";
        return DateTimeFormatter.ISO_INSTANT
            .format(Instant.ofEpochSecond(epochSeconds)
                .atOffset(ZoneOffset.UTC));
    }

    /** Resolve the status filter for the SDK call: "(all)" -> null,
     *  anything else -> that string. */
    public static String filterValue(String box) {
        if (box == null || box.isEmpty() || "(all)".equals(box)) return null;
        return box;
    }

    /**
     * Build the embeddable content region for the job monitor.
     *
     * <p>All UI state (table, rows, toolbar) is wired and live; the
     * returned {@code VBox} can be placed directly into any container.</p>
     *
     * @param manager the {@link ConnectionManager} to poll for jobs
     * @param owner   the owning {@link Window} for any child dialogs
     * @return the root {@link Region} of the job-monitor content
     */
    public static Region buildContent(ConnectionManager manager, Window owner) {
        ChoiceBox<String> statusFilterBox = new ChoiceBox<>();
        Button refreshBtn = new Button("Refresh");
        Button cancelJobBtn = new Button("Cancel selected");
        Button tailEventsBtn = new Button("Tail events");
        Label statusLabel = new Label("");
        TableView<Job> table = new TableView<>();
        ObservableList<Job> rows = FXCollections.observableArrayList();

        TableColumn<Job, String> idCol = new TableColumn<>("Job ID");
        idCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().jobId() == null ? "" : cd.getValue().jobId()));
        idCol.setPrefWidth(220);
        TableColumn<Job, String> pipeCol = new TableColumn<>("Pipeline");
        pipeCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().pipelineId() == null ? "" : cd.getValue().pipelineId()));
        pipeCol.setPrefWidth(180);
        TableColumn<Job, String> statusCol = new TableColumn<>("Status");
        statusCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().status() == null ? "" : cd.getValue().status()));
        statusCol.setPrefWidth(100);
        TableColumn<Job, String> projectCol = new TableColumn<>("Project");
        projectCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().project() == null ? "" : cd.getValue().project()));
        projectCol.setPrefWidth(100);
        TableColumn<Job, String> queuedCol = new TableColumn<>("Queued (UTC)");
        queuedCol.setCellValueFactory(cd -> new SimpleStringProperty(
            formatTimestamp(cd.getValue().queuedAt())));
        queuedCol.setPrefWidth(180);
        TableColumn<Job, String> startedCol = new TableColumn<>("Started (UTC)");
        startedCol.setCellValueFactory(cd -> new SimpleStringProperty(
            formatTimestamp(cd.getValue().startedAt())));
        startedCol.setPrefWidth(180);
        TableColumn<Job, String> completedCol = new TableColumn<>("Completed (UTC)");
        completedCol.setCellValueFactory(cd -> new SimpleStringProperty(
            formatTimestamp(cd.getValue().completedAt())));
        completedCol.setPrefWidth(180);
        table.getColumns().addAll(idCol, pipeCol, statusCol, projectCol,
                                   queuedCol, startedCol, completedCol);
        table.setItems(rows);

        statusFilterBox.setItems(FXCollections.observableArrayList(STATUS_FILTERS));
        statusFilterBox.setValue("(all)");

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox toolbar = new HBox(8,
            new Label("Status:"), statusFilterBox, refreshBtn,
            spacer,
            tailEventsBtn, cancelJobBtn);
        toolbar.setPadding(new Insets(8));

        HBox bottom = new HBox(statusLabel);
        bottom.setPadding(new Insets(0, 8, 8, 8));

        VBox root = new VBox(toolbar, table, bottom);
        VBox.setVgrow(table, Priority.ALWAYS);

        // Wire actions using local captures
        Runnable doRefresh = () -> beginRefresh(manager, statusFilterBox,
            refreshBtn, statusLabel, rows);
        refreshBtn.setOnAction(e -> doRefresh.run());
        statusFilterBox.setOnAction(e -> doRefresh.run());
        cancelJobBtn.setOnAction(e -> cancelSelected(manager, table, rows,
            statusFilterBox, refreshBtn, statusLabel));
        tailEventsBtn.setOnAction(e -> {
            Job job = table.getSelectionModel().getSelectedItem();
            if (job == null) return;
            new JobEventsView(owner, job.jobId()).show();
        });

        return root;
    }

    // ---- private helpers used by buildContent ----

    private static void beginRefresh(ConnectionManager manager,
            ChoiceBox<String> statusFilterBox, Button refreshBtn,
            Label statusLabel, ObservableList<Job> rows) {
        refreshBtn.setDisable(true);
        statusLabel.setText("Loading jobs...");
        final String filter = filterValue(statusFilterBox.getValue());
        Task<List<Job>> task = new Task<>() {
            @Override protected List<Job> call() {
                return manager.client().jobs().list(filter, 200);
            }
        };
        task.setOnSucceeded(ev -> {
            refreshBtn.setDisable(false);
            rows.setAll(task.getValue());
            statusLabel.setText(rows.size() + " job(s)"
                + (filter == null ? "" : " (filter: " + filter + ")"));
        });
        task.setOnFailed(ev -> {
            refreshBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Job list failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-list-jobs");
        th.setDaemon(true);
        th.start();
    }

    private static void cancelSelected(ConnectionManager manager,
            TableView<Job> table, ObservableList<Job> rows,
            ChoiceBox<String> statusFilterBox, Button refreshBtn,
            Label statusLabel) {
        Job job = table.getSelectionModel().getSelectedItem();
        if (job == null) return;
        if (job.isTerminal()) {
            new Alert(AlertType.INFORMATION,
                "Job " + job.jobId() + " is already " + job.status()
                + "; nothing to cancel.",
                ButtonType.OK).showAndWait();
            return;
        }
        Alert confirm = new Alert(AlertType.CONFIRMATION,
            "Cancel job " + job.jobId() + "?",
            ButtonType.OK, ButtonType.CANCEL);
        if (confirm.showAndWait().orElse(ButtonType.CANCEL) != ButtonType.OK) {
            return;
        }
        Task<Void> task = new Task<>() {
            @Override protected Void call() {
                manager.client().jobs().cancel(job.jobId());
                return null;
            }
        };
        task.setOnSucceeded(ev -> beginRefresh(manager, statusFilterBox,
            refreshBtn, statusLabel, rows));
        task.setOnFailed(ev -> {
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Cancel failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-cancel-job");
        th.setDaemon(true);
        th.start();
    }
}
