/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.auth.AuthProvider;
import global.thalion.ttio.workbench.auth.PasswordTotpAuth;
import global.thalion.ttio.workbench.auth.Session;
import javafx.beans.binding.Bindings;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.PasswordField;
import javafx.scene.control.ProgressIndicator;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.util.function.Consumer;

/**
 * Modal "Connect to workbench server..." dialog.
 *
 * <p>Collects server URL + username + password + TOTP, calls
 * {@link ConnectionManager#connect(String, AuthProvider)} on a
 * worker thread, and fires the supplied {@code onConnected}
 * callback with the resulting {@link Session} on success. On
 * failure, an error {@link Alert} is shown and the dialog stays
 * open so the operator can retry without re-entering everything.</p>
 *
 * <p>Pattern mirrors {@code transport/DownloadDialog} (Phase 10):
 * a {@link Stage} wraps a {@link GridPane}, validation runs
 * inline, and the "Connect" button is bound disabled until the
 * inputs are syntactically valid.</p>
 */
public final class LoginDialog {

    private final Window owner;
    private final ConnectionManager manager;
    private final Stage stage = new Stage();
    private final TextField urlField = new TextField("http://localhost:18443");
    private final TextField usernameField = new TextField();
    private final PasswordField passwordField = new PasswordField();
    private final TextField totpField = new TextField();
    private final Label statusLabel = new Label("");
    private final ProgressIndicator progress = new ProgressIndicator();
    private final Button connectBtn = new Button("Connect");
    private final Button cancelBtn = new Button("Cancel");

    // Drives the Connect button's disabled state during an in-flight
    // login. The button's disableProperty is BOUND (see
    // wireValidation), so setBusy cannot setDisable() it directly --
    // it flips this property and the binding recomputes.
    private final javafx.beans.property.BooleanProperty busy =
        new javafx.beans.property.SimpleBooleanProperty(false);

    private Consumer<Session> onConnected;

    public LoginDialog(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests; production code should use the one-arg
     *  constructor. */
    public LoginDialog(Window owner, ConnectionManager manager) {
        this.owner = owner;
        this.manager = manager;
        buildUi();
        wireValidation();
        wireActions();
    }

    /** Show the dialog and invoke {@code onConnected} with the
     *  established session on successful login. The callback fires
     *  on the JavaFX thread. */
    public void showAndConnect(Consumer<Session> onConnected) {
        this.onConnected = onConnected;
        stage.show();
    }

    // ---- static validators (pure, no FX toolkit required) ----

    /** Accept {@code ws://}, {@code wss://}, {@code http://},
     *  {@code https://} and bare {@code host:port}. */
    public static boolean isValidUrl(String url) {
        if (url == null || url.isEmpty()) return false;
        if (url.startsWith("ws://") || url.startsWith("wss://")
            || url.startsWith("http://") || url.startsWith("https://")) {
            return true;
        }
        // bare host[:port] -- at least one char and no leading colon
        return !url.startsWith(":") && !url.contains(" ");
    }

    /** TOTP per RFC 6238: exactly 6 ASCII digits. */
    public static boolean isValidTotp(String totp) {
        if (totp == null || totp.length() != 6) return false;
        for (int i = 0; i < 6; i++) {
            char c = totp.charAt(i);
            if (c < '0' || c > '9') return false;
        }
        return true;
    }

    public static boolean isValidUsername(String username) {
        return username != null && !username.isBlank();
    }

    public static boolean isValidPassword(String password) {
        // Workbench server enforces strength server-side; the UI
        // only blocks completely empty entries.
        return password != null && !password.isEmpty();
    }

    // ---- package-private accessors for TestFX ----

    Stage stage() { return stage; }
    TextField urlField() { return urlField; }
    TextField usernameField() { return usernameField; }
    PasswordField passwordField() { return passwordField; }
    TextField totpField() { return totpField; }
    Button connectButton() { return connectBtn; }
    Button cancelButton() { return cancelBtn; }
    Label statusLabel() { return statusLabel; }

    /** Test seam: drive the busy state through the exact path the
     *  Connect handler uses. Regression guard for the bound-value
     *  crash (setDisable on a bound disableProperty). */
    void setBusyForTest(boolean busyState) { setBusy(busyState, busyState ? "..." : ""); }
    boolean isBusyForTest() { return busy.get(); }

    // ---- internals ----

    private void buildUi() {
        urlField.setPromptText("http://biobank.example.com:18443");
        urlField.setPrefColumnCount(48);
        usernameField.setPromptText("alice");
        usernameField.setPrefColumnCount(20);
        passwordField.setPromptText("(password)");
        passwordField.setPrefColumnCount(32);
        totpField.setPromptText("123456");
        totpField.setPrefColumnCount(6);
        statusLabel.setWrapText(true);
        statusLabel.setMaxWidth(420);
        progress.setMaxSize(20, 20);
        progress.setVisible(false);

        GridPane grid = new GridPane();
        grid.setHgap(8);
        grid.setVgap(6);
        grid.setPadding(new Insets(12));
        int row = 0;
        grid.add(new Label("Server URL:"), 0, row);
        grid.add(urlField, 1, row, 2, 1); row++;
        grid.add(new Label("Username:"), 0, row);
        grid.add(usernameField, 1, row, 2, 1); row++;
        grid.add(new Label("Password:"), 0, row);
        grid.add(passwordField, 1, row, 2, 1); row++;
        grid.add(new Label("TOTP (6 digits):"), 0, row);
        grid.add(totpField, 1, row); row++;
        grid.add(new HBox(8, progress, statusLabel), 0, row, 3, 1); row++;

        HBox buttons = new HBox(8, connectBtn, cancelBtn);
        buttons.setPadding(new Insets(0, 12, 12, 12));

        VBox root = new VBox(grid, buttons);
        Scene scene = new Scene(root);
        stage.setScene(scene);
        stage.setTitle("Connect to workbench server");
        stage.initModality(Modality.WINDOW_MODAL);
        if (owner != null) stage.initOwner(owner);
    }

    private void wireValidation() {
        connectBtn.disableProperty().bind(Bindings.createBooleanBinding(() ->
                busy.get()
                || !isValidUrl(urlField.getText())
                || !isValidUsername(usernameField.getText())
                || !isValidPassword(passwordField.getText())
                || !isValidTotp(totpField.getText()),
            busy,
            urlField.textProperty(),
            usernameField.textProperty(),
            passwordField.textProperty(),
            totpField.textProperty()));
    }

    private void wireActions() {
        cancelBtn.setOnAction(e -> stage.close());
        connectBtn.setOnAction(e -> beginConnect());
        stage.setOnCloseRequest(e -> {
            // Cancel any in-flight task by leaving it to GC; the
            // worker thread holds no FX references and the daemon
            // is already through the HTTP round-trip by then.
        });
    }

    private void beginConnect() {
        final String url = urlField.getText().trim();
        final String username = usernameField.getText().trim();
        final String password = passwordField.getText();
        final String totp = totpField.getText().trim();

        AuthProvider auth;
        try {
            auth = new PasswordTotpAuth(username, password, totp);
        } catch (IllegalArgumentException iae) {
            showError(iae.getMessage());
            return;
        }

        setBusy(true, "Connecting to " + url + "...");
        Task<Session> task = new Task<>() {
            @Override protected Session call() {
                return manager.connect(url, auth);
            }
        };
        task.setOnSucceeded(ev -> {
            setBusy(false, "");
            Session s = task.getValue();
            stage.close();
            if (onConnected != null) onConnected.accept(s);
        });
        task.setOnFailed(ev -> {
            setBusy(false, "");
            Throwable t = task.getException();
            showError(t == null
                ? "Login failed (unknown error)"
                : friendlyMessage(t));
        });
        Thread thread = new Thread(task, "ttio-workbench-login");
        thread.setDaemon(true);
        thread.start();
    }

    private void setBusy(boolean busy, String message) {
        progress.setVisible(busy);
        statusLabel.setText(message);
        // connectBtn.disableProperty() is bound to the validation
        // binding (which includes `this.busy`); flip the property
        // rather than setDisable() it, or JavaFX throws
        // "A bound value cannot be set."
        this.busy.set(busy);
        cancelBtn.setDisable(busy);
        urlField.setDisable(busy);
        usernameField.setDisable(busy);
        passwordField.setDisable(busy);
        totpField.setDisable(busy);
    }

    private void showError(String message) {
        Alert alert = new Alert(AlertType.ERROR, message);
        alert.setHeaderText("Login failed");
        alert.initOwner(stage);
        alert.showAndWait();
    }

    private static String friendlyMessage(Throwable t) {
        String msg = t.getMessage();
        if (msg == null || msg.isEmpty()) return t.getClass().getSimpleName();
        return msg;
    }
}
