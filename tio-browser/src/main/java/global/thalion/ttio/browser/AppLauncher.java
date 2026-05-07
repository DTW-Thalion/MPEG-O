package global.thalion.ttio.browser;

import global.thalion.ttio.browser.util.NativeLibraryLoader;

/**
 * Non-FX entry point for the fat JAR. JavaFX module-system constraints
 * mean the manifest main class can't be a {@link javafx.application.Application}
 * subclass when JavaFX is on the classpath (not the module path) as
 * happens in a shaded JAR. This shim sidesteps the issue.
 *
 * <p>Also ensures the {@code ttio_rans_jni} native is loaded before
 * any genomic-codec call paths trigger {@code System.loadLibrary} on
 * a shaded jar without {@code java.library.path} set.</p>
 */
public final class AppLauncher {
    public static void main(String[] args) {
        // Best-effort: load bundled native if present. Failure is
        // non-fatal — the genomic UI degrades gracefully with a
        // placeholder via NativeLibraryLoader.lastError().
        NativeLibraryLoader.ensureRansJni();
        App.main(args);
    }
}
