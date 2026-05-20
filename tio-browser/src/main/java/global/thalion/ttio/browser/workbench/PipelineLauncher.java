/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.MiniJson;
import global.thalion.ttio.workbench.jobs.Job;
import global.thalion.ttio.workbench.pipeline.Pipeline;
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
import javafx.scene.control.TextArea;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.util.List;
import java.util.Map;

/**
 * "Workbench -> Pipelines -> Launch..." dialog. Pipeline picker
 * loaded from {@code GET /v1/pipelines}, inputs + params JSON
 * textareas, submit button calling {@code JobsClient.submit}.
 *
 * <p>v1.0 scope: raw JSON textareas instead of a schema-driven
 * form. The pipeline's {@code inputsSchema} / {@code outputsSchema}
 * are surfaced in the read-only schema preview pane so the operator
 * knows what shape to enter. Schema-rendered field generation is a
 * v1.1 enhancement.</p>
 */
public final class PipelineLauncher {

    private final Window owner;
    private final ConnectionManager manager;
    private final Stage stage = new Stage();

    private final ChoiceBox<String> pipelineBox = new ChoiceBox<>();
    private final TextArea schemaPreview = new TextArea();
    private final TextArea inputsField = new TextArea("{}");
    private final TextArea paramsField = new TextArea("{}");
    private final Button refreshBtn = new Button("Refresh");
    private final Button submitBtn = new Button("Submit");
    private final Button cancelBtn = new Button("Cancel");
    private final Label statusLabel = new Label("");
    private final ObservableList<Pipeline> pipelines =
        FXCollections.observableArrayList();

    public PipelineLauncher(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests. */
    public PipelineLauncher(Window owner, ConnectionManager manager) {
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
    ChoiceBox<String> pipelineBox()     { return pipelineBox; }
    TextArea schemaPreview()             { return schemaPreview; }
    TextArea inputsField()               { return inputsField; }
    TextArea paramsField()               { return paramsField; }
    Button submitButton()                { return submitBtn; }
    Button cancelButton()                { return cancelBtn; }
    Button refreshButton()               { return refreshBtn; }
    Label statusLabel()                  { return statusLabel; }
    ObservableList<Pipeline> pipelines() { return pipelines; }

    // ---- static validators (pure) ----

    public static boolean isValidJsonObject(String raw) {
        if (raw == null || raw.isBlank()) return false;
        try {
            Object parsed = MiniJson.parse(raw);
            return parsed instanceof Map<?, ?>;
        } catch (Exception ex) {
            return false;
        }
    }

    /** Build a human-readable preview of a pipeline's schemas. */
    public static String renderSchemaPreview(Pipeline p) {
        StringBuilder sb = new StringBuilder();
        sb.append("Pipeline:    ").append(p.identifier());
        if (p.version() != null && !p.version().isEmpty()) {
            sb.append(" v").append(p.version());
        }
        sb.append('\n');
        sb.append("Project:     ").append(safe(p.project())).append('\n');
        sb.append("Owner:       ").append(safe(p.owner())).append('\n');
        if (p.enginePin() != null && !p.enginePin().isEmpty()) {
            sb.append("Engine pin:  ").append(p.enginePin()).append('\n');
        }
        sb.append('\n');
        sb.append("Inputs schema:\n");
        sb.append(p.inputsSchema().isEmpty()
            ? "  (none)\n"
            : "  " + p.inputsSchema().toString() + "\n");
        sb.append('\n');
        sb.append("Outputs schema:\n");
        sb.append(p.outputsSchema().isEmpty()
            ? "  (none)\n"
            : "  " + p.outputsSchema().toString() + "\n");
        return sb.toString();
    }

    private static String safe(String s) { return s == null ? "" : s; }

    // ---- UI ----

    private void buildUi() {
        pipelineBox.setPrefWidth(360);
        schemaPreview.setEditable(false);
        schemaPreview.setPrefRowCount(8);
        schemaPreview.setStyle("-fx-font-family: monospace;");
        inputsField.setPrefRowCount(6);
        inputsField.setStyle("-fx-font-family: monospace;");
        paramsField.setPrefRowCount(6);
        paramsField.setStyle("-fx-font-family: monospace;");

        GridPane head = new GridPane();
        head.setHgap(8); head.setVgap(6); head.setPadding(new Insets(12));
        int row = 0;
        head.add(new Label("Pipeline:"), 0, row);
        head.add(pipelineBox, 1, row);
        head.add(refreshBtn, 2, row);
        row++;

        VBox body = new VBox(8,
            head,
            new Label("Pipeline metadata + schemas:"),
            schemaPreview,
            new Label("Inputs JSON:"),
            inputsField,
            new Label("Params JSON (optional):"),
            paramsField);
        body.setPadding(new Insets(0, 12, 0, 12));

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox buttons = new HBox(8, statusLabel, spacer, submitBtn, cancelBtn);
        buttons.setPadding(new Insets(12));

        VBox root = new VBox(body, buttons);
        Scene scene = new Scene(root, 720, 640);
        stage.setScene(scene);
        stage.setTitle("Workbench: launch pipeline");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        cancelBtn.setOnAction(e -> stage.close());
        refreshBtn.setOnAction(e -> beginRefresh());
        submitBtn.setOnAction(e -> submit());
        pipelineBox.getSelectionModel().selectedIndexProperty()
            .addListener((obs, oldVal, newVal) -> {
                int idx = newVal.intValue();
                if (idx >= 0 && idx < pipelines.size()) {
                    schemaPreview.setText(renderSchemaPreview(pipelines.get(idx)));
                } else {
                    schemaPreview.setText("");
                }
            });
    }

    private void beginRefresh() {
        refreshBtn.setDisable(true);
        statusLabel.setText("Loading pipelines...");
        Task<List<Pipeline>> task = new Task<>() {
            @Override protected List<Pipeline> call() {
                return manager.client().pipelines().list();
            }
        };
        task.setOnSucceeded(ev -> {
            refreshBtn.setDisable(false);
            pipelines.setAll(task.getValue());
            pipelineBox.getItems().setAll(pipelines.stream()
                .map(p -> p.identifier()
                    + (p.version() == null || p.version().isEmpty()
                        ? "" : " (v" + p.version() + ")"))
                .toList());
            if (!pipelines.isEmpty()) {
                pipelineBox.getSelectionModel().selectFirst();
            }
            statusLabel.setText(pipelines.size() + " pipeline(s) loaded");
        });
        task.setOnFailed(ev -> {
            refreshBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Pipeline list failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-list-pipelines");
        th.setDaemon(true);
        th.start();
    }

    private void submit() {
        int idx = pipelineBox.getSelectionModel().getSelectedIndex();
        if (idx < 0 || idx >= pipelines.size()) {
            new Alert(AlertType.ERROR,
                "Pick a pipeline first.", ButtonType.OK).showAndWait();
            return;
        }
        Pipeline picked = pipelines.get(idx);
        String inputsRaw = inputsField.getText();
        String paramsRaw = paramsField.getText();
        if (!isValidJsonObject(inputsRaw)) {
            new Alert(AlertType.ERROR,
                "Inputs JSON must be a non-empty object.",
                ButtonType.OK).showAndWait();
            return;
        }
        if (!isValidJsonObject(paramsRaw)) {
            new Alert(AlertType.ERROR,
                "Params JSON must be a non-empty object.",
                ButtonType.OK).showAndWait();
            return;
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> inputs = (Map<String, Object>) MiniJson.parse(inputsRaw);
        @SuppressWarnings("unchecked")
        Map<String, Object> params = (Map<String, Object>) MiniJson.parse(paramsRaw);

        submitBtn.setDisable(true);
        statusLabel.setText("Submitting...");
        Task<Job> task = new Task<>() {
            @Override protected Job call() {
                return manager.client().jobs().submit(
                    picked.pipelineId(), inputs, params);
            }
        };
        task.setOnSucceeded(ev -> {
            submitBtn.setDisable(false);
            Job job = task.getValue();
            statusLabel.setText("Submitted: " + job.jobId());
            new Alert(AlertType.INFORMATION,
                "Submitted job " + job.jobId() + " (status: "
                + job.status() + ").",
                ButtonType.OK).showAndWait();
            stage.close();
        });
        task.setOnFailed(ev -> {
            submitBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Job submit failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-submit-job");
        th.setDaemon(true);
        th.start();
    }
}
