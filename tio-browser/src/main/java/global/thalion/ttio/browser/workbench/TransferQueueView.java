/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.beans.binding.Bindings;
import javafx.beans.property.SimpleStringProperty;
import javafx.beans.value.ObservableValue;
import javafx.scene.Scene;
import javafx.scene.control.ProgressBar;
import javafx.scene.control.TableCell;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

/**
 * Non-modal window showing the live {@link TransferManager} queue.
 * Each row binds to a {@link Transfer}'s JavaFX properties; cells
 * re-render automatically when the worker thread mutates state.
 *
 * <p>Columns: kind / URI / state / progress / message.</p>
 *
 * <p>Progress is shown as an indeterminate bar while
 * {@link TransferState#RUNNING}; full bar on COMPLETED; empty on
 * PENDING / FAILED. The W1 transport client doesn't expose
 * intermediate byte-count callbacks, so a true percentage is a
 * v1.1 enhancement (tracked as a W5.3 follow-up).</p>
 */
public final class TransferQueueView {

    private final Window owner;
    private final TransferManager manager;
    private final Stage stage = new Stage();
    private final TableView<Transfer> table = new TableView<>();

    public TransferQueueView(Window owner) {
        this(owner, TransferManager.instance());
    }

    /** Visible for tests. */
    public TransferQueueView(Window owner, TransferManager manager) {
        this.owner = owner;
        this.manager = manager;
        buildUi();
    }

    public void show() { stage.show(); }

    // ---- TestFX accessors ----

    Stage stage()                  { return stage; }
    TableView<Transfer> table()    { return table; }

    private void buildUi() {
        TableColumn<Transfer, String> kindCol = new TableColumn<>("Kind");
        kindCol.setCellValueFactory(cd ->
            new SimpleStringProperty(cd.getValue().kindLabel()));
        kindCol.setPrefWidth(80);

        TableColumn<Transfer, String> uriCol = new TableColumn<>("URI / file");
        uriCol.setCellValueFactory(cd -> {
            Transfer t = cd.getValue();
            return new SimpleStringProperty(
                t.kind() == TransferKind.UPLOAD
                    ? t.localPath() + "  ->  " + t.containerUri()
                    : t.containerUri() + "  ->  " + t.localPath());
        });
        uriCol.setPrefWidth(420);

        TableColumn<Transfer, String> stateCol = new TableColumn<>("State");
        stateCol.setCellValueFactory(cd ->
            cd.getValue().stateProperty().asString());
        stateCol.setPrefWidth(100);

        TableColumn<Transfer, Transfer> progressCol = new TableColumn<>("Progress");
        progressCol.setCellValueFactory(cd ->
            new javafx.beans.property.SimpleObjectProperty<>(cd.getValue()));
        progressCol.setCellFactory(col -> new TableCell<>() {
            private final ProgressBar bar = new ProgressBar(0);
            @Override
            protected void updateItem(Transfer t, boolean empty) {
                super.updateItem(t, empty);
                if (empty || t == null) {
                    setGraphic(null);
                    return;
                }
                bar.progressProperty().unbind();
                bar.progressProperty().bind(Bindings.createDoubleBinding(() ->
                    switch (t.state()) {
                        case PENDING   -> 0.0;
                        case RUNNING   -> ProgressBar.INDETERMINATE_PROGRESS;
                        case COMPLETED -> 1.0;
                        case FAILED    -> 0.0;
                    }, t.stateProperty()));
                setGraphic(bar);
            }
        });
        progressCol.setPrefWidth(160);

        TableColumn<Transfer, String> msgCol = new TableColumn<>("Message");
        msgCol.setCellValueFactory((TableColumn.CellDataFeatures<Transfer, String> cd) ->
            (ObservableValue<String>) cd.getValue().messageProperty());
        msgCol.setPrefWidth(280);

        table.getColumns().addAll(kindCol, uriCol, stateCol, progressCol, msgCol);
        table.setItems(manager.transfers());

        Scene scene = new Scene(table, 1080, 420);
        stage.setScene(scene);
        stage.setTitle("Workbench transfers");
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
    }
}
