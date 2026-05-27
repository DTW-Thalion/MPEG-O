/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.progress.ProgressFormatter;
import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.util.Units;
import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.Transfer;
import global.thalion.ttio.browser.workbench.TransferKind;
import global.thalion.ttio.browser.workbench.TransferManager;
import global.thalion.ttio.browser.workbench.TransferStartDialog;
import global.thalion.ttio.browser.workbench.TransferState;
import javafx.beans.property.ReadOnlyStringWrapper;
import javafx.collections.transformation.FilteredList;
import javafx.geometry.Insets;
import javafx.geometry.Pos;
import javafx.scene.control.Button;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Region;
import javafx.stage.Window;

/**
 * Workspace panel that displays the in-flight / queued / completed
 * transfer queue. Replaces the Stage-2 placeholder label.
 *
 * <p>Layout: a toolbar row at the top (Start new transfer, filter
 * ChoiceBox, Clear completed) and a {@link TableView} bound to
 * {@link TransferManager#transfers()} in the centre.</p>
 */
public final class TransfersWorkspace implements Workspace {

    private final BorderPane root = new BorderPane();
    private final Button startNew = new Button("Start new transfer…");
    private final ChoiceBox<String> filterChoice = new ChoiceBox<>();
    private final Button clearCompleted = new Button("Clear completed");
    private final TableView<Transfer> table = new TableView<>();
    private final FilteredList<Transfer> filtered;
    private final Window owner;
    /** Optional: when set, supplies the currently-open local .tio path
     *  so the Start-new-transfer dialog can pre-fill the source field
     *  with the file the user is most likely about to upload. */
    private java.util.function.Supplier<java.nio.file.Path> sourceSupplier =
        () -> null;

    public TransfersWorkspace(Window owner) {
        this.owner = owner;

        filterChoice.getItems().addAll("All", "Active", "Completed", "Failed");
        filterChoice.setValue("All");
        filterChoice.valueProperty().addListener((o, a, b) -> applyFilter());

        this.filtered = new FilteredList<>(TransferManager.instance().transfers(), t -> true);
        table.setItems(filtered);
        buildColumns();

        HBox topRow = new HBox(8, startNew, filterChoice, clearCompleted);
        topRow.setAlignment(Pos.CENTER_LEFT);
        topRow.setPadding(new Insets(8));
        root.setTop(topRow);
        root.setCenter(table);

        startNew.setOnAction(e -> {
            TransferStartDialog dlg = new TransferStartDialog(owner,
                ConnectionManager.instance().isConnected());
            java.nio.file.Path suggested = sourceSupplier.get();
            if (suggested != null) dlg.prefillSource(suggested);
            dlg.show();
        });
        clearCompleted.setOnAction(e -> TransferManager.instance().clearCompleted());

        // The Progress / State / Finished columns expose plain
        // (non-observable) Transfer fields via ReadOnlyStringWrapper
        // factories. JavaFX TableView only re-invokes cellValueFactory
        // when the items list changes, not when fields inside an item
        // mutate — so per-byte progress updates never reach the row
        // without a manual refresh. Subscribe to the manager's
        // progress and queue listeners, coalesce, and refresh().
        java.util.concurrent.atomic.AtomicBoolean refreshPending =
            new java.util.concurrent.atomic.AtomicBoolean(false);
        Runnable scheduleRefresh = () -> {
            if (refreshPending.compareAndSet(false, true)) {
                javafx.application.Platform.runLater(() -> {
                    refreshPending.set(false);
                    table.refresh();
                });
            }
        };
        TransferManager.instance().addProgressListener(r -> scheduleRefresh.run());
        TransferManager.instance().addQueueListener(scheduleRefresh::run);
    }

    /** Wires a supplier the workspace consults on Start-new-transfer
     *  to pre-fill the source field with a sensible default. */
    public void setSourceSupplier(
            java.util.function.Supplier<java.nio.file.Path> supplier) {
        this.sourceSupplier = supplier == null ? () -> null : supplier;
    }

    // ---- Workspace contract ----

    @Override public String key()      { return "transfers"; }
    @Override public String tooltip()  { return "Transfers"; }
    @Override public String iconText() { return "⇅"; }   // ⇅
    @Override public Region node()     { return root; }
    @Override public void onShow()     {}
    @Override public void onHide()     {}

    // ---- Test-only accessors ----

    /** Returns the "Start new transfer…" button (for test assertions). */
    public Button startNewButtonForTest()       { return startNew; }

    /** Returns the "Clear completed" button (for test interaction). */
    public Button clearCompletedButtonForTest() { return clearCompleted; }

    /** Returns the raw TableView (for test assertions on item count). */
    public TableView<Transfer> tableForTest()   { return table; }

    /** Programmatically set the filter choice (for test interaction). */
    public void setFilterForTest(String value)  { filterChoice.setValue(value); }

    // ---- internals ----

    private void applyFilter() {
        String v = filterChoice.getValue();
        filtered.setPredicate(t -> switch (v) {
            case "Active"    -> t.state() == TransferState.RUNNING
                                || t.state() == TransferState.PENDING;
            case "Completed" -> t.state() == TransferState.COMPLETED;
            case "Failed"    -> t.state() == TransferState.FAILED;
            default          -> true;
        });
    }

    private void buildColumns() {
        TableColumn<Transfer, String> dirCol = new TableColumn<>("Dir");
        dirCol.setCellValueFactory(c -> new ReadOnlyStringWrapper(
            c.getValue().kind() == TransferKind.UPLOAD ? "↑" : "↓")); // ↑ / ↓
        dirCol.setPrefWidth(40);

        TableColumn<Transfer, String> nameCol = new TableColumn<>("Name");
        nameCol.setCellValueFactory(c ->
            new ReadOnlyStringWrapper(basename(c.getValue().localPath())));
        nameCol.setPrefWidth(200);

        TableColumn<Transfer, String> uriCol = new TableColumn<>("URI");
        uriCol.setCellValueFactory(c ->
            new ReadOnlyStringWrapper(c.getValue().containerUri()));
        uriCol.setPrefWidth(280);

        TableColumn<Transfer, String> progCol = new TableColumn<>("Progress");
        progCol.setCellValueFactory(c -> {
            ProgressReport r = c.getValue().lastReport();
            String text = r == null ? "" : ProgressFormatter.line(r, System.currentTimeMillis());
            return new ReadOnlyStringWrapper(text);
        });
        progCol.setPrefWidth(260);

        TableColumn<Transfer, String> sizeCol = new TableColumn<>("Size");
        sizeCol.setCellValueFactory(c -> {
            Transfer t = c.getValue();
            long done = t.bytesTransferred();
            long total = t.sizeBytes();
            String text;
            if (total > 0L) {
                text = Units.humanBytes(done) + " / " + Units.humanBytes(total);
            } else if (done > 0L) {
                text = Units.humanBytes(done);
            } else {
                text = "—";
            }
            return new ReadOnlyStringWrapper(text);
        });
        sizeCol.setPrefWidth(140);

        TableColumn<Transfer, String> stateCol = new TableColumn<>("State");
        stateCol.setCellValueFactory(c ->
            new ReadOnlyStringWrapper(c.getValue().state().name()));
        stateCol.setPrefWidth(100);

        TableColumn<Transfer, String> startedCol = new TableColumn<>("Started");
        startedCol.setCellValueFactory(c ->
            new ReadOnlyStringWrapper(Transfer.formatTimestamp(c.getValue().createdAtEpochMs())));
        startedCol.setPrefWidth(90);

        TableColumn<Transfer, String> finishedCol = new TableColumn<>("Finished");
        finishedCol.setCellValueFactory(c ->
            new ReadOnlyStringWrapper(Transfer.formatTimestamp(c.getValue().finishedAtEpochMs())));
        finishedCol.setPrefWidth(90);

        table.getColumns().setAll(dirCol, nameCol, uriCol, progCol, sizeCol, stateCol, startedCol, finishedCol);
    }

    private static String basename(String path) {
        if (path == null || path.isEmpty()) return "(unknown)";
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash >= 0 ? path.substring(slash + 1) : path;
    }
}
