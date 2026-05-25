package global.thalion.ttio.browser;

import java.util.List;
import java.util.Optional;

import javafx.application.Application;
import javafx.stage.Stage;

public class App extends Application {

    private MainWindow mainWindow;

    @Override
    public void start(Stage primaryStage) {
        try {
            Hdf5NativeLoader.ensureLoaded();
        } catch (Hdf5NativeLoadException e) {
            // Detect headless test mode via TestFX's marker system property
            // (set in surefire argLine) or Monocle's glass.platform marker.
            // Either signals "we're in a unit test, don't pop alerts or exit".
            boolean headless = "true".equalsIgnoreCase(System.getProperty("testfx.headless", ""))
                || "Monocle".equalsIgnoreCase(System.getProperty("glass.platform", ""));
            if (headless) {
                java.util.logging.Logger.getLogger(App.class.getName())
                    .warning("Hdf5NativeLoader failed (headless test mode): " + e.getMessage());
            } else {
                new javafx.scene.control.Alert(
                    javafx.scene.control.Alert.AlertType.ERROR,
                    e.getMessage(),
                    javafx.scene.control.ButtonType.CLOSE
                ).showAndWait();
                System.exit(1);
            }
        }
        mainWindow = new MainWindow();
        mainWindow.show(primaryStage);
        // getParameters() is null when App is constructed directly
        // (e.g., by TestFX's ApplicationTest harness) instead of via
        // Application.launch(). Treat that as "no args".
        // TODO(Stage 2.8): re-enable --open flag once ContainersWorkspace owns
        // dataset loading. Until then, the argument is parsed but not acted on.
        Application.Parameters params = getParameters();
        if (params != null) {
            parseOpenPath(params.getRaw()).ifPresent(p ->
                java.util.logging.Logger.getLogger(App.class.getName())
                    .info("--open flag received (will be wired in Stage 2.8): " + p));
        }
    }

    @Override
    public void stop() {
        // dispose() removed in Task 2.7; workbench cleanup will be
        // re-introduced via AppShell/ConnectionManager listeners in Stage 3+.
    }

    /**
     * Parse the {@code --open <path>} CLI flag from the given args list.
     *
     * <p>Returns the path as an {@link Optional} string if the args contain
     * {@code --open} followed by a non-empty value. Returns
     * {@link Optional#empty()} otherwise (no flag, flag without value, or
     * empty value).</p>
     *
     * <p>Package-private to permit unit-testing without spinning up a full
     * JavaFX runtime.</p>
     */
    static Optional<String> parseOpenPath(List<String> args) {
        if (args == null) {
            return Optional.empty();
        }
        for (int i = 0; i < args.size(); i++) {
            if ("--open".equals(args.get(i))) {
                if (i + 1 < args.size()) {
                    String v = args.get(i + 1);
                    if (v != null && !v.isEmpty()) {
                        return Optional.of(v);
                    }
                }
                return Optional.empty();
            }
        }
        return Optional.empty();
    }

    public static void main(String[] args) {
        launch(args);
    }
}
