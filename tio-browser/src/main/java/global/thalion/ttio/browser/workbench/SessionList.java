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
import javafx.scene.Scene;
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
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.util.List;

/**
 * Workbench session list. TableView<Session> with refresh /
 * copy-attach-URL / terminate controls.
 *
 * <p>Attach is via the operator's own WS-capable client (CLI
 * {@code ttio sessions attach} or a terminal) -- the list copies
 * the {@code wss://} URL to the clipboard rather than embedding a
 * terminal (W5-plan open-question 2 decision b).</p>
 */
public final class SessionList {

    private final Window owner;
    private final ConnectionManager manager;
    private final Stage stage = new Stage();

    private final Button refreshBtn = new Button("Refresh");
    private final Button copyUrlBtn = new Button("Copy attach URL");
    private final Button terminateBtn = new Button("Terminate selected");
    private final Label statusLabel = new Label("");
    private final TableView<Session> table = new TableView<>();
    private final ObservableList<Session> rows = FXCollections.observableArrayList();

    public SessionList(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests. */
    public SessionList(Window owner, ConnectionManager manager) {
        this.owner = owner;
        this.manager = manager;
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
        beginRefresh();
    }

    // ---- TestFX accessors ----

    Stage stage()                  { return stage; }
    Button refreshButton()         { return refreshBtn; }
    Button copyUrlButton()         { return copyUrlBtn; }
    Button terminateButton()       { return terminateBtn; }
    Label statusLabel()            { return statusLabel; }
    TableView<Session> table()     { return table; }
    ObservableList<Session> rows() { return rows; }

    // ---- static helpers (pure) ----

    /** Build the WS proxy attach URL for a running session, or
     *  return null when the session is not attachable. */
    public static String attachUrl(Session session, WorkbenchClient client) {
        if (session == null || client == null) return null;
        if (!session.isAttachable()) return null;
        return SessionProxy.url(client.host(), client.port(),
            session.sessionId(), client.wsScheme());
    }

    // ---- UI ----

    private void buildUi() {
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

        Scene scene = new Scene(root, 720, 440);
        stage.setScene(scene);
        stage.setTitle("Workbench sessions");
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        refreshBtn.setOnAction(e -> beginRefresh());
        copyUrlBtn.setOnAction(e -> copyAttachUrl());
        terminateBtn.setOnAction(e -> terminateSelected());
    }

    private void beginRefresh() {
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

    private Session selectedSession() {
        return table.getSelectionModel().getSelectedItem();
    }

    private void copyAttachUrl() {
        Session s = selectedSession();
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
        // Also surface it so the operator can copy manually if the
        // system clipboard is unavailable (e.g. headless).
        TextInputDialog dlg = new TextInputDialog(url);
        dlg.setTitle("Attach URL");
        dlg.setHeaderText("Attach URL for " + s.sessionId()
            + " (copied to clipboard)");
        dlg.setContentText("URL:");
        dlg.initOwner(stage);
        dlg.showAndWait();
    }

    private void terminateSelected() {
        Session s = selectedSession();
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
        task.setOnSucceeded(ev -> beginRefresh());
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
