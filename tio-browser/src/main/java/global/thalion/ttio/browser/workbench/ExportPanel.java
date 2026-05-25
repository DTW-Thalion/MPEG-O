/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.browser.exporters.ExportConfig;
import global.thalion.ttio.browser.exporters.ExportFormatRegistry;
import global.thalion.ttio.browser.exporters.ExportFormatSpec;
import global.thalion.ttio.browser.model.DatasetOpenTask;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.exporters.ExportTask;
import javafx.collections.FXCollections;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.Label;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.io.File;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Locale;

/**
 * "Workbench -> Export container..." dialog. Client-side export
 * of a local {@code .tio} (typically one just downloaded via the
 * W5.3 download manager) to a target format via the existing
 * {@link ExportTask}.
 *
 * <p>v1.0 scope: client-side export only. The download-first step
 * is the W5.3 download dialog; server-side export (running an
 * export pipeline on the daemon, W5.5) is a follow-up. The panel
 * states this explicitly so the operator knows the v1.0 path.</p>
 */
public final class ExportPanel {

    private final Window owner;
    private final Stage stage = new Stage();

    private final TextField sourceTioField = new TextField();
    private final Button browseSourceBtn = new Button("Browse...");
    private final ChoiceBox<String> formatBox = new ChoiceBox<>();
    private final TextField targetField = new TextField();
    private final Button browseTargetBtn = new Button("Browse...");
    private final Button exportBtn = new Button("Export");
    private final Button cancelBtn = new Button("Cancel");
    private final Label statusLabel = new Label("");
    private final global.thalion.ttio.browser.progress.ProgressDisplay progressDisplay =
        new global.thalion.ttio.browser.progress.ProgressDisplay();

    public ExportPanel(Window owner) {
        this.owner = owner;
        buildUi();
        wireActions();
    }

    public void show() { stage.show(); }

    // ---- TestFX accessors ----

    Stage stage()                  { return stage; }
    TextField sourceTioField()      { return sourceTioField; }
    ChoiceBox<String> formatBox()   { return formatBox; }
    TextField targetField()         { return targetField; }
    Button exportButton()           { return exportBtn; }
    Button cancelButton()           { return cancelBtn; }
    Label statusLabel()             { return statusLabel; }
    javafx.scene.control.ProgressBar progressBar() { return progressDisplay.progressBar(); }

    // ---- static helpers (pure -- testable without FX) ----

    /** Derive a sensible export target path from the source .tio
     *  path + the chosen format's conventional extension. */
    public static Path deriveExportTarget(String sourceTio, String format) {
        String base = sourceTio == null ? "export" : sourceTio;
        int slash = Math.max(base.lastIndexOf('/'), base.lastIndexOf('\\'));
        String dir = slash >= 0 ? base.substring(0, slash + 1) : "";
        String name = slash >= 0 ? base.substring(slash + 1) : base;
        int dot = name.lastIndexOf('.');
        if (dot > 0) name = name.substring(0, dot);
        if (name.isEmpty()) name = "export";
        return Paths.get(dir + name + "." + extensionFor(format));
    }

    /** Conventional file extension for an export format name. */
    public static String extensionFor(String format) {
        if (format == null) return "out";
        return switch (format.toLowerCase(Locale.ROOT)) {
            case "mzml"     -> "mzML";
            case "mztab"    -> "mzTab";
            case "imzml"    -> "imzML";
            case "nmrml"    -> "nmrML";
            case "jcamp-dx" -> "jdx";
            case "bam"      -> "bam";
            case "sam"      -> "sam";
            case "cram"     -> "cram";
            case "fasta"    -> "fasta";
            case "fastq"    -> "fastq";
            default          -> "out";
        };
    }

    public static boolean isValidTioPath(String s) {
        return s != null && s.trim().toLowerCase(Locale.ROOT).endsWith(".tio");
    }

    // ---- UI ----

    private void buildUi() {
        sourceTioField.setPromptText("/path/to/downloaded.tio");
        targetField.setPromptText("/path/to/output");
        formatBox.setItems(FXCollections.observableArrayList(
            ExportFormatRegistry.all().stream().map(s -> s.name).toList()));
        if (!formatBox.getItems().isEmpty()) {
            formatBox.getSelectionModel().selectFirst();
        }

        GridPane grid = new GridPane();
        grid.setHgap(8); grid.setVgap(6); grid.setPadding(new Insets(12));
        int row = 0;
        grid.add(new Label("Source .tio:"), 0, row);
        grid.add(sourceTioField, 1, row); grid.add(browseSourceBtn, 2, row); row++;
        grid.add(new Label("Target format:"), 0, row);
        grid.add(formatBox, 1, row, 2, 1); row++;
        grid.add(new Label("Output path:"), 0, row);
        grid.add(targetField, 1, row); grid.add(browseTargetBtn, 2, row); row++;

        Label note = new Label(
            "v1.0: client-side export. Download a container first via "
            + "Workbench -> Download from workbench. Server-side export "
            + "(export pipeline on the daemon) is a follow-up.");
        note.setWrapText(true);
        note.setMaxWidth(520);
        note.setStyle("-fx-text-fill: #555; -fx-font-size: 10;");

        // Hidden until an export starts. ProgressDisplay (bar + numeric
        // line) is driven by ProgressReport listeners on both DatasetOpenTask
        // and ExportTask; ExportTask's heartbeat ticker polls the target
        // file's size so the user sees continuous bytes-processed + rate.
        progressDisplay.node().setVisible(false);
        progressDisplay.node().setManaged(false);
        progressDisplay.node().setPrefWidth(220);

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox buttons = new HBox(8, progressDisplay.node(), statusLabel, spacer,
                                exportBtn, cancelBtn);
        buttons.setPadding(new Insets(0, 12, 12, 12));

        VBox root = new VBox(grid, note, buttons);
        VBox.setMargin(note, new Insets(0, 12, 8, 12));
        Scene scene = new Scene(root, 560, 260);
        stage.setScene(scene);
        stage.setTitle("Workbench: export container");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        browseSourceBtn.setOnAction(e -> {
            FileChooser chooser = new FileChooser();
            chooser.setTitle("Choose downloaded .tio to export");
            chooser.getExtensionFilters().add(
                new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
            File picked = chooser.showOpenDialog(stage);
            if (picked != null) {
                sourceTioField.setText(picked.toString());
                deriveTarget();
            }
        });
        browseTargetBtn.setOnAction(e -> {
            FileChooser chooser = new FileChooser();
            chooser.setTitle("Save export as");
            File picked = chooser.showSaveDialog(stage);
            if (picked != null) targetField.setText(picked.toString());
        });
        formatBox.setOnAction(e -> deriveTarget());
        cancelBtn.setOnAction(e -> stage.close());
        exportBtn.setOnAction(e -> export());
    }

    private void deriveTarget() {
        String src = sourceTioField.getText();
        if (src == null || src.isBlank()) return;
        targetField.setText(
            deriveExportTarget(src, formatBox.getValue()).toString());
    }

    private void export() {
        String src = sourceTioField.getText() == null
            ? "" : sourceTioField.getText().trim();
        String target = targetField.getText() == null
            ? "" : targetField.getText().trim();
        String format = formatBox.getValue();
        if (!isValidTioPath(src)) { showError("Source must be a .tio file."); return; }
        if (target.isEmpty()) { showError("Choose an output path."); return; }
        if (format == null) { showError("Pick a target format."); return; }
        Path srcPath = Paths.get(src);
        if (!java.nio.file.Files.exists(srcPath)) {
            showError("Source .tio does not exist: " + srcPath);
            return;
        }
        ExportFormatSpec spec = ExportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(format))
            .findFirst()
            .orElse(null);
        if (spec == null) { showError("Unknown format: " + format); return; }

        exportBtn.setDisable(true);
        statusLabel.setText("Opening source...");
        progressDisplay.node().setVisible(true);
        progressDisplay.node().setManaged(true);
        DatasetOpenTask openTask = new DatasetOpenTask(src, true);
        openTask.setProgressListener(r -> javafx.application.Platform.runLater(
            () -> progressDisplay.update(r, System.currentTimeMillis())));
        openTask.setOnSucceeded(ev -> {
            OpenDataset open = openTask.getValue();
            statusLabel.setText("Exporting...");
            ExportConfig config = ExportConfig.basic(Paths.get(target));
            ExportTask exportTask = new ExportTask(spec, config, open.dataset());
            exportTask.setProgressListener(r -> javafx.application.Platform.runLater(
                () -> progressDisplay.update(r, System.currentTimeMillis())));
            exportTask.setOnSucceeded(e2 -> {
                open.close();
                finishProgress();
                exportBtn.setDisable(false);
                statusLabel.setText("Exported to " + target);
                new Alert(AlertType.INFORMATION,
                    "Exported to " + target + ".", ButtonType.OK).showAndWait();
                stage.close();
            });
            exportTask.setOnFailed(e2 -> {
                open.close();
                finishProgress();
                exportBtn.setDisable(false);
                statusLabel.setText("");
                Throwable t = exportTask.getException();
                showError("Export failed: "
                    + (t == null ? "unknown" : t.getMessage()));
            });
            Thread th = new Thread(exportTask, "ttio-workbench-export");
            th.setDaemon(true);
            th.start();
        });
        openTask.setOnFailed(ev -> {
            finishProgress();
            exportBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = openTask.getException();
            showError("Could not open source .tio: "
                + (t == null ? "unknown" : t.getMessage()));
        });
        Thread th = new Thread(openTask, "ttio-workbench-export-open");
        th.setDaemon(true);
        th.start();
    }

    private void finishProgress() {
        progressDisplay.progressBar().setProgress(1.0);
        progressDisplay.node().setVisible(false);
        progressDisplay.node().setManaged(false);
    }

    private void showError(String message) {
        Alert a = new Alert(AlertType.ERROR, message, ButtonType.OK);
        a.initOwner(stage);
        a.showAndWait();
    }
}
