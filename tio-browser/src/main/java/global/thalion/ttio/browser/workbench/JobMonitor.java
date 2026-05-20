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
import javafx.scene.Scene;
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
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;

/**
 * Workbench job-monitor window. TableView<Job> with refresh /
 * filter-by-status / cancel-selected / tail-events controls.
 *
 * <p>Drives the W3 {@link global.thalion.ttio.workbench.jobs.JobsClient};
 * SSE tail-events are opened in a separate {@link JobEventsView}
 * window.</p>
 */
public final class JobMonitor {

    private static final List<String> STATUS_FILTERS = List.of(
        "(all)", "queued", "starting", "running",
        "completed", "failed", "cancelled");

    private final Window owner;
    private final ConnectionManager manager;
    private final Stage stage = new Stage();

    private final ChoiceBox<String> statusFilterBox = new ChoiceBox<>();
    private final Button refreshBtn = new Button("Refresh");
    private final Button cancelJobBtn = new Button("Cancel selected");
    private final Button tailEventsBtn = new Button("Tail events");
    private final Label statusLabel = new Label("");
    private final TableView<Job> table = new TableView<>();
    private final ObservableList<Job> rows = FXCollections.observableArrayList();

    public JobMonitor(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests. */
    public JobMonitor(Window owner, ConnectionManager manager) {
        this.owner = owner;
        this.manager = manager;
        buildUi();
        wireActions();
    }

    public void show() {
        if (!manager.isConnected()) {
            new Alert(AlertType.WARNING,
                "Connect to a workbench server first "
                + "(Workbench -> Connect...).",
                ButtonType.OK).showAndWait();
            return;
        }
        stage.show();
        beginRefresh();
    }

    // ---- TestFX accessors ----

    Stage stage()                       { return stage; }
    ChoiceBox<String> statusFilterBox() { return statusFilterBox; }
    Button refreshButton()              { return refreshBtn; }
    Button cancelJobButton()            { return cancelJobBtn; }
    Button tailEventsButton()           { return tailEventsBtn; }
    Label statusLabel()                 { return statusLabel; }
    TableView<Job> table()              { return table; }
    ObservableList<Job> rows()          { return rows; }

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

    // ---- UI ----

    private void buildUi() {
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

        Scene scene = new Scene(root, 1180, 520);
        stage.setScene(scene);
        stage.setTitle("Workbench jobs");
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        refreshBtn.setOnAction(e -> beginRefresh());
        statusFilterBox.setOnAction(e -> beginRefresh());
        cancelJobBtn.setOnAction(e -> cancelSelected());
        tailEventsBtn.setOnAction(e -> tailEventsForSelected());
    }

    private void beginRefresh() {
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

    private Job selectedJob() {
        return table.getSelectionModel().getSelectedItem();
    }

    private void cancelSelected() {
        Job job = selectedJob();
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
        task.setOnSucceeded(ev -> beginRefresh());
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

    private void tailEventsForSelected() {
        Job job = selectedJob();
        if (job == null) return;
        new JobEventsView(stage, job.jobId()).show();
    }
}
