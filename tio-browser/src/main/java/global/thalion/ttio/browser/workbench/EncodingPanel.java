/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.browser.importers.FormatSniffer;
import global.thalion.ttio.browser.importers.ImportConfig;
import global.thalion.ttio.browser.importers.ImportFormatRegistry;
import global.thalion.ttio.browser.importers.ImportFormatSpec;
import global.thalion.ttio.browser.importers.ImportTask;
import global.thalion.ttio.browser.progress.ProgressListener;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.Label;
import javafx.scene.control.ProgressBar;
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
 * "Workbench -> Encode + upload..." dialog. Chains the existing
 * local {@link ImportTask} (Phase 8) with the W5.3
 * {@link TransferManager} upload: pick a source file, detect its
 * format, encode to a temp {@code .tio}, then enqueue an upload to
 * the workbench under a derived container URI.
 *
 * <p>The rich per-format import options (FASTA-treat-as, CRAM
 * reference, etc.) stay in the standalone {@code ImportDialog};
 * this panel targets the common "encode a single file and push it
 * to the workbench" flow with sensible defaults.</p>
 */
public final class EncodingPanel {

    private final Window owner;
    private final ConnectionManager manager;
    private final TransferManager transfers;
    private final Stage stage = new Stage();

    private final TextField sourceField = new TextField();
    private final Button browseBtn = new Button("Browse...");
    private final Label detectedFormatLabel = new Label("(no file)");
    private final TextField projectField = new TextField();
    private final TextField uriField = new TextField();
    private final Button submitBtn = new Button("Encode + upload");
    private final Button cancelBtn = new Button("Cancel");
    private final Label statusLabel = new Label("");
    private final ProgressBar progressBar = new ProgressBar(0);

    private volatile ProgressListener externalProgressListener;

    public EncodingPanel(Window owner) {
        this(owner, ConnectionManager.instance(), TransferManager.instance());
    }

    /** Visible for tests. */
    public EncodingPanel(Window owner, ConnectionManager manager,
                          TransferManager transfers) {
        this.owner = owner;
        this.manager = manager;
        this.transfers = transfers;
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
    }

    // ---- TestFX accessors ----

    Stage stage()                  { return stage; }
    TextField sourceField()         { return sourceField; }
    Label detectedFormatLabel()     { return detectedFormatLabel; }
    TextField projectField()        { return projectField; }
    TextField uriField()            { return uriField; }
    Button submitButton()           { return submitBtn; }
    Button cancelButton()           { return cancelBtn; }
    Label statusLabel()             { return statusLabel; }
    ProgressBar progressBar()       { return progressBar; }

    /**
     * Set an external listener to receive progress reports from encoding operations.
     * The listener will be invoked from the worker thread and should return quickly.
     */
    public void setProgressListener(ProgressListener listener) {
        this.externalProgressListener = listener;
    }

    // ---- static helpers (pure -- testable without FX) ----

    /** Suggest a container URI from the source file name + project.
     *  Lower-cases, strips the extension, replaces unsafe chars with
     *  hyphens, and prefixes {@code uri:tio:<project>-}. */
    public static String deriveContainerUri(String project, String sourceFileName) {
        String base = sourceFileName == null ? "" : sourceFileName;
        int slash = Math.max(base.lastIndexOf('/'), base.lastIndexOf('\\'));
        if (slash >= 0) base = base.substring(slash + 1);
        int dot = base.indexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        base = base.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "-");
        base = base.replaceAll("(^-+|-+$)", "");
        String proj = project == null ? "" : project.trim();
        String prefix = proj.isEmpty() ? "uri:tio:" : "uri:tio:" + proj + "-";
        return prefix + (base.isEmpty() ? "container" : base);
    }

    /** Derive a temp {@code .tio} path next to the system temp dir
     *  for the encode step. */
    public static Path deriveTempTio(String sourceFileName) {
        String base = sourceFileName == null ? "encoded" : sourceFileName;
        int slash = Math.max(base.lastIndexOf('/'), base.lastIndexOf('\\'));
        if (slash >= 0) base = base.substring(slash + 1);
        int dot = base.indexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        if (base.isEmpty()) base = "encoded";
        String tmp = System.getProperty("java.io.tmpdir", ".");
        return Paths.get(tmp, "ttio-encode-" + base + ".tio");
    }

    public static boolean isValidProject(String s) {
        return s != null && !s.isBlank();
    }

    // ---- UI ----

    private void buildUi() {
        sourceField.setPromptText("/path/to/source.bam");
        projectField.setPromptText("alpha");
        uriField.setPromptText("uri:tio:<derived>");

        GridPane grid = new GridPane();
        grid.setHgap(8); grid.setVgap(6); grid.setPadding(new Insets(12));
        int row = 0;
        grid.add(new Label("Source file:"), 0, row);
        grid.add(sourceField, 1, row); grid.add(browseBtn, 2, row); row++;
        grid.add(new Label("Detected format:"), 0, row);
        grid.add(detectedFormatLabel, 1, row, 2, 1); row++;
        grid.add(new Label("Project:"), 0, row);
        grid.add(projectField, 1, row, 2, 1); row++;
        grid.add(new Label("Container URI:"), 0, row);
        grid.add(uriField, 1, row, 2, 1); row++;

        // Hidden until a run starts; indeterminate during encode (the
        // local import doesn't report granular progress -- see #114),
        // then handed off to the determinate Transfers queue on upload.
        progressBar.setVisible(false);
        progressBar.setManaged(false);
        progressBar.setPrefWidth(140);

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox buttons = new HBox(8, progressBar, statusLabel, spacer,
                                submitBtn, cancelBtn);
        buttons.setPadding(new Insets(0, 12, 12, 12));

        VBox root = new VBox(grid, buttons);
        Scene scene = new Scene(root, 560, 240);
        stage.setScene(scene);
        stage.setTitle("Workbench: encode + upload");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        browseBtn.setOnAction(e -> chooseSource());
        cancelBtn.setOnAction(e -> stage.close());
        submitBtn.setOnAction(e -> submit());
        // Re-derive the URI when the project changes (if not hand-edited).
        projectField.textProperty().addListener((obs, o, n) -> maybeDeriveUri());
    }

    private void chooseSource() {
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Choose source file to encode");
        File picked = chooser.showOpenDialog(stage);
        if (picked == null) return;
        sourceField.setText(picked.toString());
        String fmt;
        try {
            fmt = FormatSniffer.sniffFile(picked.toPath());
        } catch (Exception ex) {
            fmt = "(unknown)";
        }
        detectedFormatLabel.setText(fmt == null ? "(unknown)" : fmt);
        maybeDeriveUri();
    }

    private void maybeDeriveUri() {
        // Only auto-fill if the user hasn't typed their own URI.
        String src = sourceField.getText();
        if (src == null || src.isBlank()) return;
        uriField.setText(deriveContainerUri(projectField.getText(), src));
    }

    private void submit() {
        String source = sourceField.getText() == null ? "" : sourceField.getText().trim();
        String project = projectField.getText() == null ? "" : projectField.getText().trim();
        String uri = uriField.getText() == null ? "" : uriField.getText().trim();
        if (source.isEmpty()) { showError("Choose a source file."); return; }
        if (!isValidProject(project)) { showError("Project required."); return; }
        if (!uri.startsWith("uri:tio:")) {
            showError("Container URI must start with 'uri:tio:'.");
            return;
        }
        Path src = Paths.get(source);
        if (!java.nio.file.Files.exists(src)) {
            showError("Source file does not exist: " + src);
            return;
        }
        String format = detectedFormatLabel.getText();
        ImportFormatSpec spec = ImportFormatRegistry.all().stream()
            .filter(s -> s.name.equals(format))
            .findFirst()
            .orElse(null);
        if (spec == null) {
            showError("Unsupported / undetected format: " + format);
            return;
        }
        Path targetTio = deriveTempTio(source);
        String runName = src.getFileName().toString();
        ImportConfig config = ImportConfig.basic(
            src, targetTio, "hdf5", runName, runName);

        submitBtn.setDisable(true);
        ImportTask task = new ImportTask(spec, config);
        task.setProgressListener(r -> {
            javafx.application.Platform.runLater(() -> {
                if (r.isDeterminate()) progressBar.setProgress(r.percent());
                else progressBar.setProgress(-1.0);
            });
            var ext = externalProgressListener;
            if (ext != null) ext.onProgress(r);
        });
        // Encode phase: indeterminate bar + live task message. The
        // upload phase gets a determinate % in the Transfers queue.
        progressBar.setVisible(true);
        progressBar.setManaged(true);
        progressBar.progressProperty().bind(task.progressProperty());
        statusLabel.textProperty().bind(task.messageProperty());
        task.setOnSucceeded(ev -> {
            statusLabel.textProperty().unbind();
            progressBar.progressProperty().unbind();
            progressBar.setVisible(false);
            progressBar.setManaged(false);
            statusLabel.setText("Encoded; enqueuing upload...");
            transfers.enqueueUpload(manager.client(), project, uri, targetTio);
            new Alert(AlertType.INFORMATION,
                "Encoded " + src.getFileName() + " and queued upload to "
                + uri + ".\n\nWatch progress in Workbench -> Transfers.",
                ButtonType.OK).showAndWait();
            stage.close();
        });
        task.setOnFailed(ev -> {
            statusLabel.textProperty().unbind();
            progressBar.progressProperty().unbind();
            progressBar.setVisible(false);
            progressBar.setManaged(false);
            submitBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            showError("Encode failed: "
                + (t == null ? "unknown" : t.getMessage()));
        });
        Thread th = new Thread(task, "ttio-workbench-encode");
        th.setDaemon(true);
        th.start();
    }

    private void showError(String message) {
        Alert a = new Alert(AlertType.ERROR, message, ButtonType.OK);
        a.initOwner(stage);
        a.showAndWait();
    }
}
