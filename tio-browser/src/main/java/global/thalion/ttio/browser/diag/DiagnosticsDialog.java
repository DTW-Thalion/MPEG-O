package global.thalion.ttio.browser.diag;

import java.util.List;

import javafx.application.Platform;
import javafx.beans.property.ReadOnlyObjectWrapper;
import javafx.collections.FXCollections;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.TableCell;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;

/**
 * Modal stage showing the {@link Diagnostics} probe results in a
 * {@link TableView}, with a Re-probe button that re-runs
 * {@link Diagnostics#probeAll()} on a background thread.
 *
 * <p>The status column renders a coloured glyph
 * (green check / red X / grey dash) using {@link Label#setStyle text-fill}
 * — no external icon resources are required.</p>
 */
public final class DiagnosticsDialog {

    private DiagnosticsDialog() {}

    /** Show modal diagnostics dialog over the given owner stage. */
    public static void show(Stage owner) {
        Stage dialog = new Stage();
        dialog.setTitle("Diagnostics");
        dialog.initOwner(owner);
        dialog.initModality(Modality.WINDOW_MODAL);

        TableView<ProbeResult> table = buildTable();
        Button reprobeBtn = new Button("Re-probe");
        Button closeBtn = new Button("Close");
        Label statusLabel = new Label("Probing…");

        reprobeBtn.setOnAction(e -> reprobe(table, reprobeBtn, statusLabel));
        closeBtn.setOnAction(e -> dialog.close());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox buttons = new HBox(8, statusLabel, spacer, reprobeBtn, closeBtn);
        buttons.setPadding(new Insets(8, 0, 0, 0));

        VBox root = new VBox(8, table, buttons);
        root.setPadding(new Insets(12));
        VBox.setVgrow(table, Priority.ALWAYS);

        dialog.setScene(new Scene(root, 880, 360));
        // Populate with cached results immediately if any, then re-probe async.
        List<ProbeResult> cached = Diagnostics.cached();
        if (!cached.isEmpty()) {
            table.setItems(FXCollections.observableArrayList(cached));
        }
        dialog.show();
        reprobe(table, reprobeBtn, statusLabel);
    }

    private static TableView<ProbeResult> buildTable() {
        TableView<ProbeResult> table = new TableView<>();
        table.setPlaceholder(new Label("(no probes yet)"));

        TableColumn<ProbeResult, String> nameCol = new TableColumn<>("Name");
        nameCol.setPrefWidth(200);
        nameCol.setCellValueFactory(c ->
            new ReadOnlyObjectWrapper<>(c.getValue().name()));

        TableColumn<ProbeResult, String> pathCol = new TableColumn<>("Path");
        pathCol.setPrefWidth(300);
        pathCol.setCellValueFactory(c ->
            new ReadOnlyObjectWrapper<>(
                c.getValue().resolvedPath() == null ? "" : c.getValue().resolvedPath()));

        TableColumn<ProbeResult, ProbeResult.Status> statusCol = new TableColumn<>("Status");
        statusCol.setPrefWidth(80);
        statusCol.setCellValueFactory(c ->
            new ReadOnlyObjectWrapper<>(c.getValue().status()));
        statusCol.setCellFactory(col -> new TableCell<>() {
            @Override
            protected void updateItem(ProbeResult.Status s, boolean empty) {
                super.updateItem(s, empty);
                if (empty || s == null) {
                    setText(null);
                    setStyle("");
                    return;
                }
                switch (s) {
                    case OK:
                        setText("✓ OK");
                        setStyle("-fx-text-fill: #2e7d32; -fx-font-weight: bold;");
                        break;
                    case ERROR:
                        setText("✗ ERROR");
                        setStyle("-fx-text-fill: #c62828; -fx-font-weight: bold;");
                        break;
                    case NOT_FOUND:
                        setText("— NOT FOUND");
                        setStyle("-fx-text-fill: #757575;");
                        break;
                }
            }
        });

        TableColumn<ProbeResult, String> detailCol = new TableColumn<>("Detail");
        detailCol.setPrefWidth(250);
        detailCol.setCellValueFactory(c ->
            new ReadOnlyObjectWrapper<>(c.getValue().detail()));

        table.getColumns().add(nameCol);
        table.getColumns().add(pathCol);
        table.getColumns().add(statusCol);
        table.getColumns().add(detailCol);
        return table;
    }

    /**
     * Run {@link Diagnostics#probeAll()} on a background daemon thread
     * and refresh the dialog's table on the JavaFX thread when done.
     *
     * <p><b>Task lifetime policy:</b> the Task intentionally outlives the
     * dialog. When the user clicks Re-probe and immediately closes, the
     * Task still completes, fires the listener bus, and any <em>other</em>
     * still-open Import/Export dialog refreshes its format-list cell
     * factory. The cost is one stale
     * {@code Platform.runLater(() -> table.setItems(...))} call after the
     * dialog's scene is hidden, which JavaFX silently no-ops.</p>
     */
    private static void reprobe(TableView<ProbeResult> table,
                                Button reprobeBtn, Label statusLabel) {
        reprobeBtn.setDisable(true);
        statusLabel.setText("Probing…");
        Task<List<ProbeResult>> task = new Task<>() {
            @Override
            protected List<ProbeResult> call() {
                return Diagnostics.probeAll();
            }
        };
        task.setOnSucceeded(ev -> Platform.runLater(() -> {
            table.setItems(FXCollections.observableArrayList(task.getValue()));
            reprobeBtn.setDisable(false);
            statusLabel.setText("");
        }));
        task.setOnFailed(ev -> Platform.runLater(() -> {
            reprobeBtn.setDisable(false);
            Throwable err = task.getException();
            statusLabel.setText("Probe failed: "
                + (err == null ? "(unknown)" : err.getMessage()));
        }));
        Thread th = new Thread(task, "diagnostics-probe");
        th.setDaemon(true);
        th.start();
    }
}
