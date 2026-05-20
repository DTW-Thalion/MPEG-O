/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.sessions.Session;
import global.thalion.ttio.workbench.sessions.SessionsClient;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.Label;
import javafx.scene.control.TextArea;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * "Workbench -> Sessions -> Launch..." dialog. Engine + project +
 * image + command + bind-mounts form; on submit, calls
 * {@code SessionsClient.create(...)} and surfaces the resulting
 * session id + attach URL.
 *
 * <p>Per the W5-plan open-question 2 decision: the attach happens
 * via the operator's own terminal / browser (option b -- robust,
 * engine-agnostic), not an embedded WebView. The launcher shows
 * the {@code wss://} attach URL and offers a "Copy attach URL"
 * button; {@link SessionList} re-surfaces it for running
 * sessions.</p>
 */
public final class SessionLauncher {

    private final Window owner;
    private final ConnectionManager manager;
    private final Stage stage = new Stage();

    private final TextField projectField = new TextField();
    private final TextField engineField = new TextField("shell");
    private final TextField imageField = new TextField();
    private final TextField commandField = new TextField();
    private final TextArea bindMountsArea = new TextArea();
    private final TextArea envArea = new TextArea();
    private final Button submitBtn = new Button("Launch");
    private final Button cancelBtn = new Button("Cancel");
    private final Label statusLabel = new Label("");

    public SessionLauncher(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests. */
    public SessionLauncher(Window owner, ConnectionManager manager) {
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
    }

    // ---- TestFX accessors ----

    Stage stage()              { return stage; }
    TextField projectField()    { return projectField; }
    TextField engineField()     { return engineField; }
    TextField imageField()      { return imageField; }
    TextField commandField()    { return commandField; }
    TextArea bindMountsArea()   { return bindMountsArea; }
    TextArea envArea()          { return envArea; }
    Button submitButton()       { return submitBtn; }
    Button cancelButton()       { return cancelBtn; }
    Label statusLabel()         { return statusLabel; }

    // ---- static helpers (pure -- testable without FX) ----

    /** Split a command line into argv. Whitespace-delimited; empty
     *  / null returns an empty list (server uses the image default). */
    public static List<String> parseCommand(String raw) {
        List<String> out = new ArrayList<>();
        if (raw == null) return out;
        for (String part : raw.trim().split("\\s+")) {
            if (!part.isEmpty()) out.add(part);
        }
        return out;
    }

    /** Parse a multi-line {@code host:container[:mode]} bind-mount
     *  spec into a host-path -> container-path map. Blank lines are
     *  skipped; malformed lines (no colon) throw
     *  {@link IllegalArgumentException}. The optional {@code :mode}
     *  suffix (ro / rw) is dropped -- the server applies its own
     *  default; v1.0 carries only the path mapping. */
    public static Map<String, String> parseBindMounts(String raw) {
        Map<String, String> out = new LinkedHashMap<>();
        if (raw == null) return out;
        for (String line : raw.split("\\R")) {
            String t = line.trim();
            if (t.isEmpty()) continue;
            int firstColon = t.indexOf(':');
            if (firstColon <= 0 || firstColon == t.length() - 1) {
                throw new IllegalArgumentException(
                    "bind-mount must be host:container; got '" + t + "'");
            }
            String host = t.substring(0, firstColon);
            String rest = t.substring(firstColon + 1);
            // Drop an optional :mode suffix.
            int modeColon = rest.indexOf(':');
            String container = modeColon < 0 ? rest : rest.substring(0, modeColon);
            if (container.isEmpty()) {
                throw new IllegalArgumentException(
                    "bind-mount container path empty in '" + t + "'");
            }
            out.put(host, container);
        }
        return out;
    }

    /** Parse a multi-line {@code KEY=VALUE} env spec. Blank lines
     *  skipped; lines without {@code =} throw. */
    public static Map<String, String> parseEnv(String raw) {
        Map<String, String> out = new LinkedHashMap<>();
        if (raw == null) return out;
        for (String line : raw.split("\\R")) {
            String t = line.trim();
            if (t.isEmpty()) continue;
            int eq = t.indexOf('=');
            if (eq <= 0) {
                throw new IllegalArgumentException(
                    "env entry must be KEY=VALUE; got '" + t + "'");
            }
            out.put(t.substring(0, eq), t.substring(eq + 1));
        }
        return out;
    }

    public static boolean isValidProject(String s) {
        return s != null && !s.isBlank();
    }

    // ---- UI ----

    private void buildUi() {
        projectField.setPromptText("alpha");
        engineField.setPromptText("shell");
        imageField.setPromptText("debian:12 (optional)");
        commandField.setPromptText("/bin/bash -l (optional)");
        bindMountsArea.setPromptText("/host/path:/container/path  (one per line)");
        bindMountsArea.setPrefRowCount(3);
        envArea.setPromptText("KEY=VALUE  (one per line)");
        envArea.setPrefRowCount(3);

        GridPane grid = new GridPane();
        grid.setHgap(8); grid.setVgap(6); grid.setPadding(new Insets(12));
        int row = 0;
        grid.add(new Label("Project:"), 0, row);
        grid.add(projectField, 1, row); row++;
        grid.add(new Label("Engine pin:"), 0, row);
        grid.add(engineField, 1, row); row++;
        grid.add(new Label("Image:"), 0, row);
        grid.add(imageField, 1, row); row++;
        grid.add(new Label("Command:"), 0, row);
        grid.add(commandField, 1, row); row++;
        grid.add(new Label("Bind mounts:"), 0, row);
        grid.add(bindMountsArea, 1, row); row++;
        grid.add(new Label("Environment:"), 0, row);
        grid.add(envArea, 1, row); row++;

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox buttons = new HBox(8, statusLabel, spacer, submitBtn, cancelBtn);
        buttons.setPadding(new Insets(0, 12, 12, 12));

        VBox root = new VBox(grid, buttons);
        Scene scene = new Scene(root, 540, 420);
        stage.setScene(scene);
        stage.setTitle("Workbench: launch session");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireActions() {
        cancelBtn.setOnAction(e -> stage.close());
        submitBtn.setOnAction(e -> submit());
    }

    private void submit() {
        String project = projectField.getText() == null
            ? "" : projectField.getText().trim();
        if (!isValidProject(project)) {
            new Alert(AlertType.ERROR, "Project required.",
                ButtonType.OK).showAndWait();
            return;
        }
        String engine = engineField.getText() == null
            ? "" : engineField.getText().trim();
        List<String> command;
        Map<String, String> bindMounts;
        Map<String, String> env;
        try {
            command = parseCommand(commandField.getText());
            bindMounts = parseBindMounts(bindMountsArea.getText());
            env = parseEnv(envArea.getText());
        } catch (IllegalArgumentException ex) {
            new Alert(AlertType.ERROR, ex.getMessage(),
                ButtonType.OK).showAndWait();
            return;
        }

        SessionsClient.CreateRequest req = new SessionsClient.CreateRequest()
            .project(project)
            .enginePin(engine.isEmpty() ? null : engine);
        String image = imageField.getText() == null ? "" : imageField.getText().trim();
        if (!image.isEmpty()) req.image(image);
        if (!command.isEmpty()) req.command(command);
        if (!bindMounts.isEmpty()) req.bindMounts(bindMounts);
        if (!env.isEmpty()) req.env(env);

        submitBtn.setDisable(true);
        statusLabel.setText("Launching...");
        Task<Session> task = new Task<>() {
            @Override protected Session call() {
                return manager.client().sessions().create(req);
            }
        };
        task.setOnSucceeded(ev -> {
            submitBtn.setDisable(false);
            Session s = task.getValue();
            statusLabel.setText("Launched: " + s.sessionId());
            new Alert(AlertType.INFORMATION,
                "Launched session " + s.sessionId() + " (status: "
                + s.status() + ").\n\nUse Workbench -> Sessions -> List to "
                + "attach once it is running.",
                ButtonType.OK).showAndWait();
            stage.close();
        });
        task.setOnFailed(ev -> {
            submitBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Session launch failed" : t.getMessage(),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-create-session");
        th.setDaemon(true);
        th.start();
    }
}
