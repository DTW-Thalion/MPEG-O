/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.Label;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.io.File;

/**
 * Modal "Upload to workbench..." dialog. Collects source path +
 * project + container URI; on Submit, enqueues an upload via
 * {@link TransferManager} and closes.
 */
public final class UploadStartDialog {

    private final Window owner;
    private final ConnectionManager manager;
    private final TransferManager transfers;
    private final Stage stage = new Stage();

    private final TextField sourceField = new TextField();
    private final Button browseBtn = new Button("Browse...");
    private final TextField projectField = new TextField();
    private final TextField uriField = new TextField();
    private final Button submitBtn = new Button("Submit upload");
    private final Button cancelBtn = new Button("Cancel");

    public UploadStartDialog(Window owner) {
        this(owner, ConnectionManager.instance(), TransferManager.instance());
    }

    /** Visible for tests. */
    public UploadStartDialog(Window owner, ConnectionManager manager,
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

    Stage stage()             { return stage; }
    TextField sourceField()    { return sourceField; }
    TextField projectField()   { return projectField; }
    TextField uriField()       { return uriField; }
    Button submitButton()      { return submitBtn; }
    Button cancelButton()      { return cancelBtn; }

    // ---- static validators ----

    public static boolean isValidProject(String s) {
        return s != null && !s.isBlank();
    }

    public static boolean isValidContainerUri(String s) {
        if (s == null) return false;
        String t = s.trim();
        return t.startsWith("uri:tio:") && t.length() > "uri:tio:".length();
    }

    // ---- UI ----

    private void buildUi() {
        sourceField.setPromptText("/path/to/file.tio");
        projectField.setPromptText("alpha");
        uriField.setPromptText("uri:tio:<safe-id>");

        GridPane grid = new GridPane();
        grid.setHgap(8); grid.setVgap(6); grid.setPadding(new Insets(12));
        int row = 0;
        grid.add(new Label("Source .tio:"), 0, row);
        grid.add(sourceField, 1, row); grid.add(browseBtn, 2, row); row++;
        grid.add(new Label("Project:"), 0, row);
        grid.add(projectField, 1, row, 2, 1); row++;
        grid.add(new Label("Container URI:"), 0, row);
        grid.add(uriField, 1, row, 2, 1); row++;

        HBox buttons = new HBox(8, submitBtn, cancelBtn);
        buttons.setPadding(new Insets(0, 12, 12, 12));

        VBox root = new VBox(grid, buttons);
        Scene scene = new Scene(root, 480, 200);
        stage.setScene(scene);
        stage.setTitle("Upload to workbench");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        browseBtn.setOnAction(e -> {
            FileChooser chooser = new FileChooser();
            chooser.setTitle("Choose .tio file to upload");
            chooser.getExtensionFilters().add(
                new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
            File picked = chooser.showOpenDialog(stage);
            if (picked != null) sourceField.setText(picked.toString());
        });
        cancelBtn.setOnAction(e -> stage.close());
        submitBtn.setOnAction(e -> submit());
    }

    private void submit() {
        String source = sourceField.getText() == null
            ? "" : sourceField.getText().trim();
        String project = projectField.getText() == null
            ? "" : projectField.getText().trim();
        String uri = uriField.getText() == null
            ? "" : uriField.getText().trim();
        if (source.isEmpty()) { showError("Choose a source file."); return; }
        if (!isValidProject(project)) { showError("Project required."); return; }
        if (!isValidContainerUri(uri)) {
            showError("Container URI must start with 'uri:tio:'.");
            return;
        }
        java.nio.file.Path src = java.nio.file.Paths.get(source);
        if (!java.nio.file.Files.exists(src)) {
            showError("Source file does not exist: " + src);
            return;
        }
        transfers.enqueueUpload(manager.client(), project, uri, src);
        stage.close();
    }

    private void showError(String message) {
        Alert a = new Alert(AlertType.ERROR, message, ButtonType.OK);
        a.initOwner(stage);
        a.showAndWait();
    }
}
