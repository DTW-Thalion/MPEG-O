package global.thalion.ttio.browser;

/**
 * Non-FX entry point for the fat JAR. JavaFX module-system constraints
 * mean the manifest main class can't be a {@link javafx.application.Application}
 * subclass when JavaFX is on the classpath (not the module path) as
 * happens in a shaded JAR. This shim sidesteps the issue.
 */
public final class AppLauncher {
    public static void main(String[] args) {
        App.main(args);
    }
}
