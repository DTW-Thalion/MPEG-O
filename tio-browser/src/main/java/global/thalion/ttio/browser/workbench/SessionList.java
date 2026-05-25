/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.WorkbenchClient;
import global.thalion.ttio.workbench.sessions.Session;
import global.thalion.ttio.workbench.sessions.SessionProxy;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.Label;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.control.TextInputDialog;
import javafx.scene.input.Clipboard;
import javafx.scene.input.ClipboardContent;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Window;

import java.util.List;

/**
 * Workbench session list content builder. TableView<Session> with refresh /
 * copy-attach-URL / terminate controls.
 *
 * <p>Attach is via the operator's own WS-capable client (CLI
 * {@code ttio sessions attach} or a terminal) -- the list copies
 * the {@code wss://} URL to the clipboard rather than embedding a
 * terminal (W5-plan open-question 2 decision b).</p>
 *
 * <p>This class no longer manages a Stage; call
 * {@link #buildContent(ConnectionManager, Window)} to obtain an embeddable
 * {@link Region} suitable for use inside {@code JobsWorkspace}.</p>
 */
public final class SessionList {

    private SessionList() {}

    // ---- static helpers (pure) ----

    /** Build the WS proxy attach URL for a running session, or
     *  return null when the session is not attachable. */
    public static String attachUrl(Session session, WorkbenchClient client) {
        if (session == null || client == null) return null;
        if (!session.isAttachable()) return null;
        return SessionProxy.url(client.host(), client.port(),
            session.sessionId(), client.wsScheme());
    }

    /**
     * Build the embeddable content region for the session list.
     *
     * <p>All UI state (table, rows, toolbar) is wired and live; the
     * returned {@code VBox} can be placed directly into any container.</p>
     *
     * @param manager the {@link ConnectionManager} to poll for sessions
     * @param owner   the owning {@link Window} for any child dialogs
     * @return the root {@link Region} of the session-list content
     */
    public static Region buildContent(ConnectionManager manager, Window owner) {
        Button refreshBtn = new Button("Refresh");
        Button copyUrlBtn = new Button("Copy attach URL");
        Button terminateBtn = new Button("Terminate selected");
        Label statusLabel = new Label("");
        TableView<Session> table = new TableView<>();
        ObservableList<Session> rows = FXCollections.observableArrayList();

        TableColumn<Session, String> idCol = new TableColumn<>("Session ID");
        idCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().sessionId() == null ? "" : cd.getValue().sessionId()));
        idCol.setPrefWidth(220);
        TableColumn<Session, String> statusCol = new TableColumn<>("Status");
        statusCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().status() == null ? "" : cd.getValue().status()));
        statusCol.setPrefWidth(100);
        TableColumn<Session, String> projectCol = new TableColumn<>("Project");
        projectCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().project() == null ? "" : cd.getValue().project()));
        projectCol.setPrefWidth(100);
        TableColumn<Session, String> engineCol = new TableColumn<>("Engine");
        engineCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().engineIdentifier() == null
                ? "" : cd.getValue().engineIdentifier()));
        engineCol.setPrefWidth(120);
        TableColumn<Session, String> portCol = new TableColumn<>("Host port");
        portCol.setCellValueFactory(cd -> new SimpleStringProperty(
            cd.getValue().hostPort() == null
                ? "" : String.valueOf(cd.getValue().hostPort())));
        portCol.setPrefWidth(90);
        table.getColumns().addAll(idCol, statusCol, projectCol, engineCol, portCol);
        table.setItems(rows);

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox toolbar = new HBox(8, refreshBtn, spacer, copyUrlBtn, terminateBtn);
        toolbar.setPadding(new Insets(8));

        HBox bottom = new HBox(statusLabel);
        bottom.setPadding(new Insets(0, 8, 8, 8));

        VBox root = new VBox(toolbar, table, bottom);
        VBox.setVgrow(table, Priority.ALWAYS);

        Runnable doRefresh = () -> beginRefresh(manager, refreshBtn, statusLabel, rows);
        refreshBtn.setOnAction(e -> doRefresh.run());
        copyUrlBtn.setOnAction(e -> copyAttachUrl(manager, table, owner));
        terminateBtn.setOnAction(e -> terminateSelected(manager, table, rows,
            refreshBtn, statusLabel));

        return root;
    }

    // ---- private helpers used by buildContent ----

    private static void beginRefresh(ConnectionManager manager,
            Button refreshBtn, Label statusLabel, ObservableList<Session> rows) {
        refreshBtn.setDisable(true);
        statusLabel.setText("Loading sessions...");
        Task<List<Session>> task = new Task<>() {
            @Override protected List<Session> call() {
                return manager.client().sessions().list(null, 200);
            }
        };
        task.setOnSucceeded(ev -> {
            refreshBtn.setDisable(false);
            rows.setAll(task.getValue());
            statusLabel.setText(rows.size() + " session(s)");
        });
        task.setOnFailed(ev -> {
            refreshBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Session list failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-list-sessions");
        th.setDaemon(true);
        th.start();
    }

    private static void copyAttachUrl(ConnectionManager manager,
            TableView<Session> table, Window owner) {
        Session s = table.getSelectionModel().getSelectedItem();
        if (s == null) return;
        String url = attachUrl(s, manager.client());
        if (url == null) {
            new Alert(AlertType.INFORMATION,
                "Session " + s.sessionId() + " is " + s.status()
                + "; only running sessions have an attach URL.",
                ButtonType.OK).showAndWait();
            return;
        }
        ClipboardContent content = new ClipboardContent();
        content.putString(url);
        Clipboard.getSystemClipboard().setContent(content);
        TextInputDialog dlg = new TextInputDialog(url);
        dlg.setTitle("Attach URL");
        dlg.setHeaderText("Attach URL for " + s.sessionId()
            + " (copied to clipboard)");
        dlg.setContentText("URL:");
        dlg.initOwner(owner);
        dlg.showAndWait();
    }

    private static void terminateSelected(ConnectionManager manager,
            TableView<Session> table, ObservableList<Session> rows,
            Button refreshBtn, Label statusLabel) {
        Session s = table.getSelectionModel().getSelectedItem();
        if (s == null) return;
        if (s.isTerminal()) {
            new Alert(AlertType.INFORMATION,
                "Session " + s.sessionId() + " is already " + s.status() + ".",
                ButtonType.OK).showAndWait();
            return;
        }
        Alert confirm = new Alert(AlertType.CONFIRMATION,
            "Terminate session " + s.sessionId() + "?",
            ButtonType.OK, ButtonType.CANCEL);
        if (confirm.showAndWait().orElse(ButtonType.CANCEL) != ButtonType.OK) {
            return;
        }
        Task<Void> task = new Task<>() {
            @Override protected Void call() {
                manager.client().sessions().terminate(s.sessionId());
                return null;
            }
        };
        task.setOnSucceeded(ev -> beginRefresh(manager, refreshBtn, statusLabel, rows));
        task.setOnFailed(ev -> {
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Terminate failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-terminate-session");
        th.setDaemon(true);
        th.start();
    }
}
