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
import javafx.scene.control.Separator;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.io.File;
import java.util.Map;

/**
 * Modal "Download from workbench..." dialog. Container URI +
 * output path + embedded {@link SelectiveAccessPanel} for
 * filter construction. On Submit, enqueues a download via
 * {@link TransferManager}.
 */
public final class DownloadStartDialog {

    private final Window owner;
    private final ConnectionManager manager;
    private final TransferManager transfers;
    private final Stage stage = new Stage();

    private final TextField uriField = new TextField();
    private final TextField destField = new TextField();
    private final Button browseBtn = new Button("Browse...");
    private final SelectiveAccessPanel filterPanel = new SelectiveAccessPanel();
    private final Button submitBtn = new Button("Submit download");
    private final Button cancelBtn = new Button("Cancel");

    public DownloadStartDialog(Window owner) {
        this(owner, ConnectionManager.instance(), TransferManager.instance());
    }

    /** Visible for tests. */
    public DownloadStartDialog(Window owner, ConnectionManager manager,
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

    Stage stage()                    { return stage; }
    TextField uriField()              { return uriField; }
    TextField destField()             { return destField; }
    SelectiveAccessPanel filterPanel() { return filterPanel; }
    Button submitButton()             { return submitBtn; }
    Button cancelButton()             { return cancelBtn; }

    // ---- static validators ----

    public static boolean isValidContainerUri(String s) {
        return UploadStartDialog.isValidContainerUri(s);
    }

    // ---- UI ----

    private void buildUi() {
        uriField.setPromptText("uri:tio:<safe-id>");
        destField.setPromptText("/path/to/download.tio");

        GridPane head = new GridPane();
        head.setHgap(8); head.setVgap(6); head.setPadding(new Insets(12));
        int row = 0;
        head.add(new Label("Container URI:"), 0, row);
        head.add(uriField, 1, row, 2, 1); row++;
        head.add(new Label("Save to:"), 0, row);
        head.add(destField, 1, row); head.add(browseBtn, 2, row); row++;

        VBox body = new VBox(8,
            head,
            new Separator(),
            new Label("Selective-access filter (optional)"),
            filterPanel.node());

        HBox buttons = new HBox(8, submitBtn, cancelBtn);
        buttons.setPadding(new Insets(0, 12, 12, 12));

        VBox root = new VBox(body, buttons);
        Scene scene = new Scene(root, 520, 520);
        stage.setScene(scene);
        stage.setTitle("Download from workbench");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        browseBtn.setOnAction(e -> {
            FileChooser chooser = new FileChooser();
            chooser.setTitle("Save downloaded .tio as");
            chooser.getExtensionFilters().add(
                new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
            File picked = chooser.showSaveDialog(stage);
            if (picked != null) destField.setText(picked.toString());
        });
        cancelBtn.setOnAction(e -> stage.close());
        submitBtn.setOnAction(e -> submit());
    }

    private void submit() {
        String uri = uriField.getText() == null ? "" : uriField.getText().trim();
        String dest = destField.getText() == null ? "" : destField.getText().trim();
        if (!isValidContainerUri(uri)) {
            showError("Container URI must start with 'uri:tio:'.");
            return;
        }
        if (dest.isEmpty()) {
            showError("Choose a destination path.");
            return;
        }
        Map<String, Object> filter;
        try {
            filter = filterPanel.buildFilter();
        } catch (RuntimeException ex) {
            showError("Filter invalid: " + ex.getMessage());
            return;
        }
        java.nio.file.Path destPath = java.nio.file.Paths.get(dest);
        transfers.enqueueDownload(manager.client(), uri, destPath, filter);
        stage.close();
    }

    private void showError(String message) {
        Alert a = new Alert(AlertType.ERROR, message, ButtonType.OK);
        a.initOwner(stage);
        a.showAndWait();
    }
}
