package global.thalion.ttio.tools;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Test-only utility for running TTI-O CLI mains as a subprocess.
 *
 * <p>Replaces the legacy in-process {@code SecurityManager}-based exit-trap
 * pattern that became unusable in Java 21 (where
 * {@code System.setSecurityManager} throws
 * {@code UnsupportedOperationException}).</p>
 *
 * <p>Spawns a fresh JVM with the same classpath, the
 * {@code -Djava.library.path}/{@code -Dhdf5.jar=} system properties
 * inherited from the parent, and {@code --enable-native-access=ALL-UNNAMED}
 * for the FFM API (used by the HDF5 1.14 VL_BYTES path).</p>
 */
public final class CliSubprocessRunner {

    public static final class CliResult {
        public final int exitCode;
        public final String stdout;
        public final String stderr;

        public CliResult(int exitCode, String stdout, String stderr) {
            this.exitCode = exitCode;
            this.stdout = stdout;
            this.stderr = stderr;
        }
    }

    private CliSubprocessRunner() {}

    /** Run {@code mainClass.main(args)} in a fresh JVM. Inherits the parent's
     *  classpath plus key TTI-O system properties. Default 60s timeout. */
    public static CliResult run(Class<?> mainClass, String... args)
            throws IOException, InterruptedException {
        return runWithEnv(mainClass, Collections.emptyMap(), args);
    }

    /** Variant that lets callers pass extra environment variables. */
    public static CliResult runWithEnv(Class<?> mainClass,
                                        Map<String, String> extraEnv,
                                        String... args)
            throws IOException, InterruptedException {
        List<String> cmd = new ArrayList<>();
        cmd.add(javaBinary());
        cmd.add("-cp");
        cmd.add(System.getProperty("java.class.path"));
        cmd.add("--enable-native-access=ALL-UNNAMED");
        cmd.add("--enable-preview");
        String libPath = System.getProperty("java.library.path");
        if (libPath != null && !libPath.isEmpty()) {
            cmd.add("-Djava.library.path=" + libPath);
        }
        String hdf5Jar = System.getProperty("hdf5.jar");
        if (hdf5Jar != null && !hdf5Jar.isEmpty()) {
            cmd.add("-Dhdf5.jar=" + hdf5Jar);
        }
        cmd.add(mainClass.getName());
        for (String a : args) cmd.add(a);

        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.environment().putAll(extraEnv);
        pb.redirectErrorStream(false);
        Process p = pb.start();
        ByteArrayOutputStream outBuf = new ByteArrayOutputStream();
        ByteArrayOutputStream errBuf = new ByteArrayOutputStream();
        Thread tOut = drainAsync(p.getInputStream(), outBuf);
        Thread tErr = drainAsync(p.getErrorStream(), errBuf);
        boolean exited = p.waitFor(60, TimeUnit.SECONDS);
        if (!exited) {
            p.destroyForcibly();
            throw new IOException("CLI subprocess timed out: " + cmd);
        }
        tOut.join(2000);
        tErr.join(2000);
        return new CliResult(p.exitValue(),
            outBuf.toString(StandardCharsets.UTF_8),
            errBuf.toString(StandardCharsets.UTF_8));
    }

    private static Thread drainAsync(InputStream in, OutputStream sink) {
        Thread t = new Thread(() -> {
            try { in.transferTo(sink); }
            catch (IOException ignored) {}
        }, "cli-drain");
        t.setDaemon(true);
        t.start();
        return t;
    }

    private static String javaBinary() {
        String home = System.getProperty("java.home");
        return home + "/bin/java";
    }
}
