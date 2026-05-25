/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.PasswordField;
import javafx.scene.control.RadioButton;
import javafx.scene.control.TextField;
import javafx.scene.control.ToggleGroup;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.io.File;
import java.nio.file.Paths;

/**
 * Single unified dialog for starting a transfer. Replaces four
 * legacy dialogs (transport.UploadDialog, transport.DownloadDialog,
 * workbench.UploadStartDialog, workbench.DownloadStartDialog).
 *
 * <p>Direction selects upload vs download; scope selects connected
 * workbench (default when an authenticated session exists) vs
 * anonymous URL (default when offline, behind "Advanced" when
 * connected). Anonymous transfers are routed through
 * {@link TransferManager#enqueueAnonymousUpload} and
 * {@link TransferManager#enqueueAnonymousDownload}.</p>
 */
public final class TransferStartDialog {

    public enum Direction { UPLOAD, DOWNLOAD }
    public enum Scope { CONNECTED, ANONYMOUS_URL }

    private final Window owner;
    private final Stage stage = new Stage();
    private final ToggleGroup dirGroup = new ToggleGroup();
    private final RadioButton uploadRadio = new RadioButton("Upload");
    private final RadioButton downloadRadio = new RadioButton("Download");
    private final ToggleGroup scopeGroup = new ToggleGroup();
    private final RadioButton connectedRadio = new RadioButton("Connected workbench");
    private final RadioButton anonymousRadio = new RadioButton("Anonymous URL");
    private final TextField sourceField = new TextField();
    private final Button browseBtn = new Button("Browse…");
    private final TextField projectField = new TextField();
    private final TextField uriField = new TextField();
    private final TextField urlField = new TextField();
    private final PasswordField tokenField = new PasswordField();
    private final SelectiveAccessPanel selectiveAccess = new SelectiveAccessPanel();
    private final VBox connectedFields;
    private final VBox anonymousFields;
    private final Button submitBtn = new Button("Submit");
    private final Button cancelBtn = new Button("Cancel");
    private final Label hintLabel = new Label("");

    private Direction direction;
    private Scope scope;
    private static final String DEFAULT_PROJECT = "default";

    public TransferStartDialog(Window owner, boolean connected) {
        this.owner = owner;
        uploadRadio.setToggleGroup(dirGroup);
        downloadRadio.setToggleGroup(dirGroup);
        connectedRadio.setToggleGroup(scopeGroup);
        anonymousRadio.setToggleGroup(scopeGroup);

        uploadRadio.setSelected(true);
        direction = Direction.UPLOAD;
        if (connected) {
            connectedRadio.setSelected(true);
            scope = Scope.CONNECTED;
            // Pre-fill the project with a sensible default — the user
            // can override before submit. URI defaults are generated
            // when a source file is picked (see fileChosen()).
            projectField.setText(DEFAULT_PROJECT);
        } else {
            anonymousRadio.setSelected(true);
            scope = Scope.ANONYMOUS_URL;
        }

        connectedFields = new VBox(6,
            labelled("Project:", projectField),
            labelled("Container URI:", uriField));
        anonymousFields = new VBox(6,
            labelled("URL:", urlField),
            labelled("Bearer token (optional):", tokenField));

        dirGroup.selectedToggleProperty().addListener((o, a, b) -> {
            direction = uploadRadio.isSelected() ? Direction.UPLOAD : Direction.DOWNLOAD;
            refresh();
        });
        scopeGroup.selectedToggleProperty().addListener((o, a, b) -> {
            scope = connectedRadio.isSelected() ? Scope.CONNECTED : Scope.ANONYMOUS_URL;
            refresh();
        });
        sourceField.textProperty().addListener((o, a, b) -> {
            refresh();
            // When the source field is populated and the URI field is
            // empty, auto-generate a unique default URI by listing the
            // server's existing containers and picking the lowest
            // unused suffix.
            if (scope == Scope.CONNECTED
                && !sourceField.getText().isBlank()
                && uriField.getText().isBlank()) {
                generateDefaultUri();
            }
        });
        projectField.textProperty().addListener((o, a, b) -> refresh());
        uriField.textProperty().addListener((o, a, b) -> refresh());
        urlField.textProperty().addListener((o, a, b) -> refresh());
        browseBtn.setOnAction(e -> browseForSource());
        cancelBtn.setOnAction(e -> stage.close());
        submitBtn.setOnAction(e -> submit());

        HBox sourceRow = new HBox(8, new Label("Source:"), sourceField, browseBtn);
        HBox dirRow = new HBox(12, new Label("Direction:"), uploadRadio, downloadRadio);
        HBox scopeRow = new HBox(12, new Label("Server scope:"), connectedRadio, anonymousRadio);
        HBox actions = new HBox(8, submitBtn, cancelBtn);

        VBox body = new VBox(12,
            dirRow, scopeRow,
            sourceRow,
            connectedFields, anonymousFields,
            selectiveAccess.node(),
            hintLabel,
            actions);
        body.setPadding(new Insets(16));

        stage.initOwner(owner);
        stage.initModality(Modality.WINDOW_MODAL);
        stage.setScene(new Scene(body, 620, 540));
        stage.setTitle("Start new transfer");

        refresh();
    }

    public void show()         { stage.showAndWait(); }
    public void showForTest()  { stage.show(); }

    public Direction direction() { return direction; }
    public Scope scope()         { return scope; }
    public boolean selectiveAccessVisible() { return selectiveAccess.node().isVisible(); }
    public Button submitButton() { return submitBtn; }

    public void setDirection(Direction d) {
        direction = d;
        (d == Direction.UPLOAD ? uploadRadio : downloadRadio).setSelected(true);
    }

    public void setScopeForTest(Scope s) {
        scope = s;
        (s == Scope.CONNECTED ? connectedRadio : anonymousRadio).setSelected(true);
    }

    public void setSourceForTest(String s)  { sourceField.setText(s); }
    public void setProjectForTest(String s) { projectField.setText(s); }
    public void setUriForTest(String s)     { uriField.setText(s); }
    public void setUrlForTest(String s)     { urlField.setText(s); }
    public void setTokenForTest(String s)   { tokenField.setText(s); }

    private void refresh() {
        boolean dl = direction == Direction.DOWNLOAD;
        selectiveAccess.node().setVisible(dl);
        selectiveAccess.node().setManaged(dl);
        boolean connectedScope = scope == Scope.CONNECTED;
        connectedFields.setVisible(connectedScope);
        connectedFields.setManaged(connectedScope);
        anonymousFields.setVisible(!connectedScope);
        anonymousFields.setManaged(!connectedScope);

        // Submit-enabled rules:
        boolean haveSource = !sourceField.getText().isBlank();
        boolean haveConnectedTarget =
            !projectField.getText().isBlank() && !uriField.getText().isBlank();
        boolean canSubmit;
        if (scope == Scope.CONNECTED) {
            canSubmit = haveSource && haveConnectedTarget;
            hintLabel.setText(canSubmit ? "" :
                "Select a source file and fill in Project + Container URI.");
        } else {  // ANONYMOUS_URL
            boolean haveUrl = !urlField.getText().isBlank();
            canSubmit = haveSource && haveUrl;
            hintLabel.setText(canSubmit ? "" :
                "Select a source file and fill in URL.");
        }
        submitBtn.setDisable(!canSubmit);
    }

    private void browseForSource() {
        FileChooser chooser = new FileChooser();
        chooser.setTitle(direction == Direction.UPLOAD
            ? "Pick local .tio to upload"
            : "Pick output location for downloaded .tio");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = direction == Direction.UPLOAD
            ? chooser.showOpenDialog(stage)
            : chooser.showSaveDialog(stage);
        if (picked != null) sourceField.setText(picked.toString());
    }

    /** Pre-fill the source field (used by callers who already know
     *  which file should be uploaded, e.g. the currently-open dataset). */
    public void prefillSource(java.nio.file.Path path) {
        if (path != null) sourceField.setText(path.toString());
    }

    /**
     * Async-fetch the server's existing container URIs for the chosen
     * project and pick the lowest unused suffix of
     * {@code uri:tio:<project>/<basename>[-N]}. Runs on a daemon
     * thread so the dialog stays responsive; assigns to {@code uriField}
     * on the FX thread only when the field is still empty (so a
     * user-typed value isn't overwritten).
     */
    private void generateDefaultUri() {
        var client = ConnectionManager.instance().client();
        if (client == null) return;
        String src = sourceField.getText();
        if (src.isBlank()) return;
        String rawBase = java.nio.file.Paths.get(src).getFileName().toString();
        if (rawBase.endsWith(".tio")) {
            rawBase = rawBase.substring(0, rawBase.length() - 4);
        }
        final String basename = rawBase.replaceAll("[^A-Za-z0-9._-]", "_");
        final String project = projectField.getText().isBlank()
            ? DEFAULT_PROJECT : projectField.getText().trim();
        System.err.println("[TransferStartDialog] generating default URI: "
            + "project=" + project + " basename=" + basename);
        Thread t = new Thread(() -> {
            String candidate;
            try {
                var page = client.containers().list(project, null, 200, null);
                java.util.Set<String> existing = new java.util.HashSet<>();
                for (var c : page.containers()) existing.add(c.uri());
                String prefix = "uri:tio:" + project + "/" + basename;
                candidate = prefix;
                int n = 2;
                while (existing.contains(candidate) && n < 10_000) {
                    candidate = prefix + "-" + n++;
                }
                System.err.println("[TransferStartDialog] default URI = "
                    + candidate + " (after checking " + existing.size()
                    + " existing in project)");
            } catch (Throwable ex) {
                candidate = "uri:tio:" + project + "/" + basename
                    + "-" + System.currentTimeMillis();
                System.err.println("[TransferStartDialog] container list failed ("
                    + ex.getClass().getSimpleName() + "); using timestamped fallback: "
                    + candidate);
            }
            final String finalCandidate = candidate;
            javafx.application.Platform.runLater(() -> {
                if (uriField.getText().isBlank()) {
                    uriField.setText(finalCandidate);
                }
            });
        }, "transfer-default-uri");
        t.setDaemon(true);
        t.start();
    }

    private void submit() {
        var tm = TransferManager.instance();
        System.err.println("[TransferStartDialog] submit: direction=" + direction
            + " scope=" + scope + " source=" + sourceField.getText()
            + " project=" + projectField.getText() + " uri=" + uriField.getText()
            + " url=" + urlField.getText());
        Transfer t;
        if (scope == Scope.CONNECTED) {
            var client = ConnectionManager.instance().client();
            if (client == null) {
                hintLabel.setText("Not connected — reconnect via the header chip and try again.");
                return;
            }
            if (direction == Direction.UPLOAD) {
                t = tm.enqueueUpload(client, projectField.getText(),
                    uriField.getText(), Paths.get(sourceField.getText()));
            } else {
                t = tm.enqueueDownload(client, uriField.getText(),
                    Paths.get(sourceField.getText()), selectiveAccess.buildFilter());
            }
        } else {
            // ANONYMOUS_URL
            if (direction == Direction.UPLOAD) {
                t = tm.enqueueAnonymousUpload(urlField.getText(),
                    tokenField.getText(), Paths.get(sourceField.getText()));
            } else {
                t = tm.enqueueAnonymousDownload(urlField.getText(),
                    Paths.get(sourceField.getText()), selectiveAccess.buildFilter());
            }
        }
        System.err.println("[TransferStartDialog] enqueued transfer id="
            + (t == null ? "null" : t.id())
            + " state=" + (t == null ? "n/a" : t.state())
            + " queueSize=" + tm.transfers().size());
        stage.close();
    }

    private static HBox labelled(String label, javafx.scene.Node field) {
        Label l = new Label(label);
        HBox box = new HBox(8, l, field);
        if (field instanceof Region r) {
            HBox.setHgrow(r, Priority.ALWAYS);
        }
        return box;
    }
}
