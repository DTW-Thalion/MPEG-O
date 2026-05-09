/*
 * tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

import javafx.beans.value.ChangeListener;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.CheckBox;
import javafx.scene.control.Label;
import javafx.scene.control.PasswordField;
import javafx.scene.control.ProgressBar;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.io.File;
import java.net.ConnectException;
import java.net.UnknownHostException;

/**
 * Modal dialog for uploading a local {@code .tio} dataset to a transport server.
 *
 * <p>Supports {@code http://}, {@code https://}, {@code ws://}, and
 * {@code wss://} destination URLs. An optional Bearer token may be supplied
 * for HTTP(S) endpoints (silently ignored for WebSocket).</p>
 */
public final class UploadDialog {

    private final Window owner;
    private final Stage stage = new Stage();
    private final TextField localPathField = new TextField();
    private final TextField urlField = new TextField();
    private final Label urlErrorLabel = new Label();
    private final PasswordField tokenField = new PasswordField();
    private final CheckBox checksumBox = new CheckBox("Per-packet CRC-32C checksum");
    private final ProgressBar progress = new ProgressBar(0.0);
    private final Label statusLabel = new Label("");
    private final Button uploadBtn = new Button("Upload");
    private final Button cancelBtn = new Button("Cancel");

    private Runnable onSuccess;

    /**
     * @param owner       parent window (for modality)
     * @param defaultPath pre-populated local {@code .tio} path; may be empty
     */
    public UploadDialog(Window owner, String defaultPath) {
        this.owner = owner;
        if (defaultPath != null && !defaultPath.isBlank()) {
            localPathField.setText(defaultPath);
        }
        checksumBox.setSelected(true);
        buildUi();
        wireValidation();
    }

    /**
     * Show the dialog; invoke {@code onSuccess} on successful upload.
     *
     * @param onSuccess callback invoked on successful upload; may be null
     */
    public void showAndUpload(Runnable onSuccess) {
        this.onSuccess = onSuccess;
        stage.show();
    }

    // ---------------------------------------------------------- static validators

    /**
     * Returns {@code true} if {@code url} starts with a supported transport
     * scheme ({@code http://}, {@code https://}, {@code ws://}, {@code wss://}).
     */
    public static boolean isValidUrl(String url) {
        if (url == null || url.isEmpty()) return false;
        return url.startsWith("http://")
            || url.startsWith("https://")
            || url.startsWith("ws://")
            || url.startsWith("wss://");
    }

    // ---------------------------------------------------------- test accessors (pkg-private)

    Stage stage() { return stage; }
    TextField localPathField() { return localPathField; }
    TextField urlField() { return urlField; }
    PasswordField tokenField() { return tokenField; }
    CheckBox checksumBox() { return checksumBox; }
    Button uploadButton() { return uploadBtn; }

    // ---------------------------------------------------------- UI construction

    private void buildUi() {
        urlErrorLabel.setStyle("-fx-text-fill: red; -fx-font-size: 10;");

        Button browseSrc = new Button("Browse...");
        browseSrc.setOnAction(e -> chooseLocalFile());

        GridPane grid = new GridPane();
        grid.setHgap(8); grid.setVgap(6);
        grid.setPadding(new Insets(12));

        int row = 0;
        grid.add(new Label("Local .tio:"), 0, row);
        grid.add(localPathField, 1, row);
        grid.add(browseSrc, 2, row); row++;

        grid.add(new Label("Destination URL:"), 0, row);
        grid.add(urlField, 1, row, 2, 1); row++;

        grid.add(urlErrorLabel, 1, row, 2, 1); row++;

        grid.add(new Label("Bearer token (HTTP only):"), 0, row);
        grid.add(tokenField, 1, row, 2, 1); row++;

        grid.add(checksumBox, 1, row, 2, 1); row++;

        grid.add(progress, 0, row, 3, 1);
        progress.setMaxWidth(Double.MAX_VALUE); row++;

        grid.add(statusLabel, 0, row, 3, 1);

        uploadBtn.setDisable(true);
        uploadBtn.setOnAction(e -> runUpload());
        cancelBtn.setOnAction(e -> stage.close());

        HBox buttons = new HBox(8, uploadBtn, cancelBtn);
        VBox root = new VBox(8, grid, buttons);
        root.setPadding(new Insets(8));

        stage.setTitle("Upload to transport server");
        stage.initOwner(owner);
        stage.initModality(Modality.WINDOW_MODAL);
        stage.setScene(new Scene(root, 580, 340));
    }

    private void wireValidation() {
        ChangeListener<String> check = (obs, old, n) -> refreshUploadButton();
        localPathField.textProperty().addListener(check);
        urlField.textProperty().addListener(check);
    }

    private void refreshUploadButton() {
        String url = urlField.getText();
        String src = localPathField.getText();
        boolean urlOk = isValidUrl(url);
        boolean srcOk = src != null && !src.isBlank();
        urlErrorLabel.setText(
            urlOk || url == null || url.isBlank()
                ? ""
                : "URL must start with http://, https://, ws://, or wss://");
        uploadBtn.setDisable(!(urlOk && srcOk));
    }

    private void chooseLocalFile() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Select .tio to upload");
        fc.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = fc.showOpenDialog(stage);
        if (picked != null) localPathField.setText(picked.toString());
    }

    private void runUpload() {
        String src   = localPathField.getText();
        String url   = urlField.getText();
        String token = tokenField.getText();
        boolean chk  = checksumBox.isSelected();

        UploadTask task = new UploadTask(src, url, token, chk);
        progress.progressProperty().bind(task.progressProperty());
        statusLabel.textProperty().bind(task.messageProperty());
        uploadBtn.setDisable(true);

        task.setOnSucceeded(ev -> {
            progress.progressProperty().unbind();
            statusLabel.textProperty().unbind();
            progress.setProgress(1.0);
            stage.close();
            if (onSuccess != null) onSuccess.run();
        });
        task.setOnFailed(ev -> {
            progress.progressProperty().unbind();
            statusLabel.textProperty().unbind();
            uploadBtn.setDisable(false);
            handleUploadError(task.getException(), src, url, token, chk);
        });
        new Thread(task, "tio-upload").start();
    }

    private void handleUploadError(Throwable err, String src, String url,
                                   String token, boolean chk) {
        String message;
        if (err instanceof ConnectException
                || (err != null && err.getMessage() != null
                    && err.getMessage().contains("Connection refused")))
            message = "Could not connect to " + url + ". Verify the server is reachable.";
        else if (err instanceof UnknownHostException)
            message = "Hostname not resolvable: " + extractHost(url) + ".";
        else if (err instanceof IllegalArgumentException)
            message = err.getMessage();
        else
            message = "Upload failed: " + (err == null ? "(unknown)" : err.getMessage());

        Alert alert = new Alert(AlertType.ERROR);
        alert.initOwner(stage);
        alert.setTitle("Upload Error");
        alert.setHeaderText("Transport upload failed");
        alert.setContentText(message);

        ButtonType retryType = new ButtonType("Retry");
        alert.getButtonTypes().setAll(retryType, ButtonType.CANCEL);
        alert.showAndWait().ifPresent(choice -> {
            if (choice == retryType) {
                UploadTask retryTask = new UploadTask(src, url, token, chk);
                progress.progressProperty().bind(retryTask.progressProperty());
                statusLabel.textProperty().bind(retryTask.messageProperty());
                uploadBtn.setDisable(true);
                retryTask.setOnSucceeded(ev -> {
                    progress.progressProperty().unbind();
                    statusLabel.textProperty().unbind();
                    progress.setProgress(1.0);
                    stage.close();
                    if (onSuccess != null) onSuccess.run();
                });
                retryTask.setOnFailed(ev2 -> {
                    progress.progressProperty().unbind();
                    statusLabel.textProperty().unbind();
                    uploadBtn.setDisable(false);
                    handleUploadError(retryTask.getException(), src, url, token, chk);
                });
                new Thread(retryTask, "tio-upload-retry").start();
            }
        });
    }

    private static String extractHost(String url) {
        try {
            String s = url.replaceFirst("^(https?|wss?)://", "");
            int slash = s.indexOf('/');
            String hp = slash >= 0 ? s.substring(0, slash) : s;
            int colon = hp.lastIndexOf(':');
            return colon >= 0 ? hp.substring(0, colon) : hp;
        } catch (Exception e) { return url; }
    }
}
