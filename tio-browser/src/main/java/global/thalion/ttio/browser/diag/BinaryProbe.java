package global.thalion.ttio.browser.diag;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;
import java.util.function.Supplier;

/**
 * Probe descriptor for one external dependency. Two modes:
 *
 * <ol>
 *   <li><b>Subprocess mode</b> (regular constructor): resolve an executable via
 *       env-var or PATH, exec it with version arguments, parse first stdout line.
 *   <li><b>In-process mode</b> (Supplier constructor): call a {@code Supplier<String>}
 *       directly. Used for JNI-loaded libraries (e.g. HDF5) where a version
 *       string can be obtained without forking.
 * </ol>
 *
 * Subprocess timeout is 2s; on timeout the process is destroyed and the probe
 * returns {@link ProbeResult.Status#ERROR}.
 */
public final class BinaryProbe {

    private static final long TIMEOUT_SECONDS = 2L;

    private static final boolean IS_WINDOWS =
        System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");

    public final String name;
    public final String envVar;
    public final String execName;
    public final List<String> versionArgs;
    public final Function<String, String> firstLineParser;

    private final Supplier<String> probeFn;

    /**
     * Subprocess-mode probe.
     *
     * @param name             human-readable label
     * @param envVar           environment variable to consult first; may be {@code null}
     * @param execName         executable name (no extension); resolved against PATH
     * @param versionArgs      arguments passed to the executable (e.g. {@code ["--version"]})
     * @param firstLineParser  function applied to the first stdout line to produce
     *                         the {@code detail} of an OK ProbeResult
     */
    public BinaryProbe(String name,
                       String envVar,
                       String execName,
                       List<String> versionArgs,
                       Function<String, String> firstLineParser) {
        this.name = name;
        this.envVar = envVar;
        this.execName = execName;
        this.versionArgs = List.copyOf(versionArgs);
        this.firstLineParser = firstLineParser;
        this.probeFn = null;
    }

    /**
     * In-process-mode probe. The supplier is invoked on every {@link #probe()}
     * call; throwing turns into a {@link ProbeResult.Status#ERROR} result.
     */
    public BinaryProbe(String name, Supplier<String> probeFn) {
        this.name = name;
        this.envVar = null;
        this.execName = null;
        this.versionArgs = List.of();
        this.firstLineParser = null;
        this.probeFn = probeFn;
    }

    public ProbeResult probe() {
        if (probeFn != null) {
            try {
                String detail = probeFn.get();
                return new ProbeResult(name, "(in-process)",
                    ProbeResult.Status.OK, detail == null ? "" : detail);
            } catch (Throwable t) {
                String msg = t.getMessage();
                return new ProbeResult(name, null, ProbeResult.Status.ERROR,
                    msg == null ? t.getClass().getSimpleName() : msg);
            }
        }

        Path resolved = resolvePath();
        if (resolved == null) {
            return new ProbeResult(name, null, ProbeResult.Status.NOT_FOUND, "");
        }

        List<String> cmd = new ArrayList<>(1 + versionArgs.size());
        cmd.add(resolved.toString());
        cmd.addAll(versionArgs);

        Process proc = null;
        try {
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.redirectErrorStream(true);
            proc = pb.start();

            String firstLine;
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(proc.getInputStream(), StandardCharsets.UTF_8))) {
                firstLine = r.readLine();
            }

            boolean exited = proc.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!exited) {
                proc.destroyForcibly();
                return new ProbeResult(name, resolved.toString(),
                    ProbeResult.Status.ERROR,
                    "timed out after " + TIMEOUT_SECONDS + "s");
            }

            if (firstLine == null) firstLine = "";
            String parsed;
            try {
                parsed = firstLineParser.apply(firstLine);
            } catch (RuntimeException parseEx) {
                String msg = parseEx.getMessage();
                return new ProbeResult(name, resolved.toString(),
                    ProbeResult.Status.ERROR,
                    "parse error: " + (msg == null
                        ? parseEx.getClass().getSimpleName() : msg));
            }
            return new ProbeResult(name, resolved.toString(),
                ProbeResult.Status.OK, parsed == null ? "" : parsed);

        } catch (IOException ioe) {
            return new ProbeResult(name, resolved.toString(),
                ProbeResult.Status.ERROR,
                ioe.getMessage() == null ? ioe.getClass().getSimpleName() : ioe.getMessage());
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            return new ProbeResult(name, resolved.toString(),
                ProbeResult.Status.ERROR, "interrupted");
        } finally {
            if (proc != null && proc.isAlive()) {
                proc.destroyForcibly();
            }
        }
    }

    /** @return absolute path to executable, or {@code null} if unresolved. */
    private Path resolvePath() {
        if (envVar != null) {
            String env = System.getenv(envVar);
            if (env != null && !env.isBlank()) {
                Path p = Paths.get(env);
                if (Files.isExecutable(p)) return p.toAbsolutePath();
                // Try with .exe on Windows if env-var pointed at the bare name
                if (IS_WINDOWS && !env.toLowerCase(Locale.ROOT).endsWith(".exe")) {
                    Path pe = Paths.get(env + ".exe");
                    if (Files.isExecutable(pe)) return pe.toAbsolutePath();
                }
            }
        }
        if (execName == null) return null;

        String pathEnv = System.getenv("PATH");
        if (pathEnv == null || pathEnv.isEmpty()) return null;

        for (String dir : pathEnv.split(java.util.regex.Pattern.quote(File.pathSeparator))) {
            if (dir.isEmpty()) continue;
            Path candidate;
            try {
                candidate = Paths.get(dir).resolve(execName);
            } catch (RuntimeException ex) {
                continue;
            }
            if (Files.isExecutable(candidate)) return candidate.toAbsolutePath();
            if (IS_WINDOWS) {
                Path withExe = Paths.get(dir).resolve(execName + ".exe");
                if (Files.isExecutable(withExe)) return withExe.toAbsolutePath();
            }
        }
        return null;
    }
}
