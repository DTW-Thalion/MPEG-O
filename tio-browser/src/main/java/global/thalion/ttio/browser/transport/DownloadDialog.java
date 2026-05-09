package global.thalion.ttio.browser.transport;

import global.thalion.ttio.MiniJson;
import javafx.beans.value.ChangeListener;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Label;
import javafx.scene.control.ProgressBar;
import javafx.scene.control.Spinner;
import javafx.scene.control.SpinnerValueFactory;
import javafx.scene.control.TextArea;
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
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeoutException;
import java.util.function.Consumer;

public final class DownloadDialog {
    private final Window owner;
    private final Stage stage = new Stage();
    private final TextField urlField = new TextField();
    private final Label urlErrorLabel = new Label();
    private final TextField outputField = new TextField();
    private final Button outputBrowse = new Button("Browse...");
    private final TextArea filterArea = new TextArea("{}");
    private final Label filterErrorLabel = new Label();
    private final ComboBox<String> providerBox = new ComboBox<>();
    private final Spinner<Integer> timeoutSpinner = new Spinner<>();
    private final ProgressBar progress = new ProgressBar(0.0);
    private final Label statusLabel = new Label("");
    private final Button downloadBtn = new Button("Download");
    private final Button cancelBtn = new Button("Cancel");
    private Consumer<Path> onDownloaded;

    public DownloadDialog(Window owner) {
        this.owner = owner; buildUi(); wireValidation();
    }

    public void showAndDownload(Consumer<Path> onDownloaded) {
        this.onDownloaded = onDownloaded; stage.show();
    }

    public static boolean isValidUrl(String url) {
        if (url == null || url.isEmpty()) return false;
        return url.startsWith("ws://") || url.startsWith("wss://");
    }

    public static boolean isValidJson(String json) {
        if (json == null || json.isBlank()) return false;
        try { MiniJson.parse(json); return true; }
        catch (Exception e) { return false; }
    }

    Stage stage() { return stage; }
    TextField urlField() { return urlField; }
    TextField outputField() { return outputField; }
    TextArea filterArea() { return filterArea; }
    Button downloadButton() { return downloadBtn; }

    private void buildUi() {
        providerBox.getItems().setAll("hdf5", "memory", "sqlite", "zarr");
        providerBox.getSelectionModel().selectFirst();
        timeoutSpinner.setValueFactory(
            new SpinnerValueFactory.IntegerSpinnerValueFactory(5, 600, 60));
        timeoutSpinner.setEditable(true);
        urlErrorLabel.setStyle("-fx-text-fill: red; -fx-font-size: 10;");
        filterErrorLabel.setStyle("-fx-text-fill: red; -fx-font-size: 10;");
        filterArea.setPrefRowCount(4);
        GridPane grid = new GridPane();
        grid.setHgap(8); grid.setVgap(6); grid.setPadding(new Insets(12));
        int row = 0;
        grid.add(new Label("Server URL (ws:// or wss://):"), 0, row);
        grid.add(urlField, 1, row, 2, 1); row++;
        grid.add(urlErrorLabel, 1, row, 2, 1); row++;
        grid.add(new Label("Output .tio:"), 0, row);
        grid.add(outputField, 1, row); grid.add(outputBrowse, 2, row); row++;
        grid.add(new Label("Filter JSON:"), 0, row);
        grid.add(filterArea, 1, row, 2, 1); row++;
        grid.add(filterErrorLabel, 1, row, 2, 1); row++;
        grid.add(new Label("Storage provider:"), 0, row);
        grid.add(providerBox, 1, row, 2, 1); row++;
        grid.add(new Label("Timeout (s):"), 0, row);
        grid.add(timeoutSpinner, 1, row, 2, 1); row++;
        grid.add(progress, 0, row, 3, 1); progress.setMaxWidth(Double.MAX_VALUE); row++;
        grid.add(statusLabel, 0, row, 3, 1);
        outputBrowse.setOnAction(e -> chooseOutput());
        downloadBtn.setOnAction(e -> runDownload());
        cancelBtn.setOnAction(e -> stage.close());
        downloadBtn.setDisable(true);
        HBox buttons = new HBox(8, downloadBtn, cancelBtn);
        VBox root = new VBox(8, grid, buttons);
        root.setPadding(new Insets(8));
        stage.setTitle("Download from transport server");
        stage.initOwner(owner); stage.initModality(Modality.WINDOW_MODAL);
        stage.setScene(new Scene(root, 620, 420));
    }

    private void wireValidation() {
        ChangeListener<String> check = (obs, old, n) -> refreshDownloadButton();
        urlField.textProperty().addListener(check);
        outputField.textProperty().addListener(check);
        filterArea.textProperty().addListener(check);
    }

    private void refreshDownloadButton() {
        String url = urlField.getText(); String output = outputField.getText();
        boolean urlOk = isValidUrl(url);
        boolean jsonOk = isValidJson(filterArea.getText());
        boolean outOk = output != null && !output.isBlank();
        urlErrorLabel.setText(urlOk || url.isBlank() ? "" : "URL must start with ws:// or wss://");
        filterErrorLabel.setText(jsonOk ? "" : "Invalid JSON");
        downloadBtn.setDisable(!(urlOk && jsonOk && outOk));
    }

    private void chooseOutput() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save downloaded .tio");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = fc.showSaveDialog(stage);
        if (picked != null) outputField.setText(picked.toString());
    }

    private Map<String, Object> parseFilters() {
        String json = filterArea.getText().trim();
        Object parsed = MiniJson.parse(json);
        if (parsed instanceof Map<?, ?> m) {
            Map<String, Object> out = new LinkedHashMap<>();
            for (Map.Entry<?, ?> e : m.entrySet())
                out.put(e.getKey().toString(), e.getValue());
            return out;
        }
        return Map.of();
    }

    private void runDownload() {
        String url = urlField.getText(); String output = outputField.getText();
        int timeout = timeoutSpinner.getValue(); String provider = providerBox.getValue();
        Map<String, Object> filters = parseFilters();
        DownloadTask task = new DownloadTask(url, filters, output, provider, timeout);
        progress.progressProperty().bind(task.progressProperty());
        statusLabel.textProperty().bind(task.messageProperty());
        downloadBtn.setDisable(true);
        task.setOnSucceeded(ev -> {
            progress.progressProperty().unbind(); statusLabel.textProperty().unbind();
            progress.setProgress(1.0); stage.close();
            if (onDownloaded != null) onDownloaded.accept(Path.of(output));
        });
        task.setOnFailed(ev -> {
            progress.progressProperty().unbind(); statusLabel.textProperty().unbind();
            downloadBtn.setDisable(false);
            handleDownloadError(task.getException(), url, filters, output, provider, timeout);
        });
        new Thread(task, "tio-download").start();
    }

    private void handleDownloadError(Throwable err, String url,
            Map<String, Object> filters, String output, String provider, int timeout) {
        String message;
        if (err instanceof ConnectException
                || (err != null && err.getMessage() != null
                    && err.getMessage().contains("Connection refused")))
            message = "Could not connect to " + url + ". Verify the server is reachable.";
        else if (err instanceof UnknownHostException)
            message = "Hostname not resolvable: " + extractHost(url) + ".";
        else if (err instanceof TimeoutException)
            message = "Connection timed out after " + timeout + "s.";
        else
            message = "Download failed: " + (err == null ? "(unknown)" : err.getMessage());
        Alert alert = new Alert(AlertType.ERROR);
        alert.initOwner(stage); alert.setTitle("Download Error");
        alert.setHeaderText("Transport download failed"); alert.setContentText(message);
        ButtonType retryType = new ButtonType("Retry");
        alert.getButtonTypes().setAll(retryType, ButtonType.CANCEL);
        alert.showAndWait().ifPresent(choice -> {
            if (choice == retryType) {
                DownloadTask retryTask = new DownloadTask(url, filters, output, provider, timeout);
                progress.progressProperty().bind(retryTask.progressProperty());
                statusLabel.textProperty().bind(retryTask.messageProperty());
                downloadBtn.setDisable(true);
                retryTask.setOnSucceeded(ev -> {
                    progress.progressProperty().unbind(); statusLabel.textProperty().unbind();
                    progress.setProgress(1.0); stage.close();
                    if (onDownloaded != null) onDownloaded.accept(Path.of(output));
                });
                retryTask.setOnFailed(ev2 -> {
                    progress.progressProperty().unbind(); statusLabel.textProperty().unbind();
                    downloadBtn.setDisable(false);
                    handleDownloadError(retryTask.getException(), url, filters, output, provider, timeout);
                });
                new Thread(retryTask, "tio-download-retry").start();
            }
        });
    }

    private static String extractHost(String url) {
        try {
            String s = url.replaceFirst("^wss?://", "");
            int slash = s.indexOf('/');
            String hp = slash >= 0 ? s.substring(0, slash) : s;
            int colon = hp.lastIndexOf(':');
            return colon >= 0 ? hp.substring(0, colon) : hp;
        } catch (Exception e) { return url; }
    }
}