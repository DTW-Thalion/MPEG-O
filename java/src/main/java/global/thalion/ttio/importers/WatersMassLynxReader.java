/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.AcquisitionRun;

import java.io.File;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;

/**
 * Waters MassLynx {@code .raw} directory importer — v0.9 M63.
 *
 * <p>Delegates to the user-installed {@code masslynxraw} converter (a
 * proprietary Waters tool). The converter reads a {@code .raw}
 * directory and writes mzML, which TTIO parses via
 * {@link MzMLReader}. No Waters proprietary code ships in TTI-O.</p>
 *
 * <p>Binary resolution order:</p>
 * <ol>
 *   <li>Explicit path via {@link #read(String, String)}.</li>
 *   <li>{@code MASSLYNXRAW} environment variable.</li>
 *   <li>{@code masslynxraw} on {@code PATH}.</li>
 *   <li>{@code MassLynxRaw.exe} on {@code PATH} — invoked via {@code mono}.</li>
 * </ol>
 *
 * <p>Waters {@code .raw} inputs are <b>directories</b>, not files.</p>
 *
 * <p><b>API status:</b> Provisional (v0.9 M63).</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code TTIOWatersMassLynxReader} &middot;
 * Python: {@code ttio.importers.waters_masslynx}</p>
 *
 * @since 0.9
 */
public final class WatersMassLynxReader {

    /** Raised when the converter exits non-zero or produces no mzML. */
    public static final class WatersMassLynxException extends IOException {
        private static final long serialVersionUID = 1L;
        public WatersMassLynxException(String msg) { super(msg); }
        public WatersMassLynxException(String msg, Throwable cause) { super(msg, cause); }
    }

    private WatersMassLynxReader() {}

    public static AcquisitionRun read(String dirPath) throws IOException {
        return read(dirPath, null);
    }

    public static AcquisitionRun read(String dirPath, String converter)
            throws IOException {
        Path raw = Path.of(dirPath);
        if (!Files.isDirectory(raw)) {
            throw new IOException("Waters .raw directory not found: " + raw);
        }

        List<String> cmdPrefix = resolveBinary(converter);

        Path tmpDir = Files.createTempDirectory("ttio_masslynx_");
        try {
            List<String> argv = new ArrayList<>(cmdPrefix);
            argv.addAll(List.of("-i", raw.toString(), "-o", tmpDir.toString()));

            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectErrorStream(true);
            Process proc = pb.start();
            String output;
            try (var in = proc.getInputStream()) {
                output = new String(in.readAllBytes());
            }
            int rc;
            try {
                rc = proc.waitFor();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted waiting for MassLynx converter");
            }
            if (rc != 0) {
                String head = output.length() > 500 ? output.substring(0, 500) : output;
                throw new WatersMassLynxException("MassLynx converter exited " + rc
                        + ": " + head.trim());
            }

            String stem = raw.getFileName().toString();
            if (stem.toLowerCase().endsWith(".raw")) {
                stem = stem.substring(0, stem.length() - 4);
            }
            Path mzml = tmpDir.resolve(stem + ".mzML");
            if (!Files.isRegularFile(mzml)) {
                try (Stream<Path> s = Files.list(tmpDir)) {
                    mzml = s.filter(p -> p.getFileName().toString()
                                        .toLowerCase().endsWith(".mzml"))
                           .findFirst().orElse(null);
                }
                if (mzml == null) {
                    throw new WatersMassLynxException(
                            "MassLynx converter produced no mzML in " + tmpDir);
                }
            }

            try {
                return MzMLReader.read(mzml.toString());
            } catch (MzMLParseException e) {
                throw new WatersMassLynxException(
                        "MzMLReader failed on MassLynx converter output: "
                        + e.getMessage(), e);
            }
        } finally {
            deleteRecursively(tmpDir);
        }
    }

    private static List<String> resolveBinary(String explicit) throws IOException {
        if (explicit != null) {
            if (!isExecutable(explicit)) {
                throw new IOException(
                        "MassLynx converter not found or not executable: " + explicit);
            }
            return wrapIfDotNet(explicit);
        }

        String env = System.getenv("MASSLYNXRAW");
        if (env != null && !env.isBlank()) {
            if (!isExecutable(env)) {
                throw new IOException(
                        "MASSLYNXRAW env var points to missing/"
                        + "non-executable binary: " + env);
            }
            return wrapIfDotNet(env);
        }

        String native_ = lookupOnPath("masslynxraw");
        if (native_ != null) return List.of(native_);

        String winExe = lookupOnPath("MassLynxRaw.exe");
        if (winExe != null) {
            String mono = lookupOnPath("mono");
            if (mono == null) {
                throw new IOException(
                        "Found MassLynxRaw.exe but mono is not on PATH.");
            }
            return List.of(mono, winExe);
        }

        throw new IOException(
                "MassLynx converter ('masslynxraw' or 'MassLynxRaw.exe') not "
                + "found on PATH and MASSLYNXRAW not set. "
                + "See docs/vendor-formats.md for installation instructions.");
    }

    private static List<String> wrapIfDotNet(String path) throws IOException {
        if (path.toLowerCase().endsWith(".exe")) {
            String mono = lookupOnPath("mono");
            if (mono == null) {
                throw new IOException(path + " requires mono, which is not on PATH.");
            }
            return List.of(mono, path);
        }
        return List.of(path);
    }

    private static boolean isExecutable(String path) {
        File f = new File(path);
        return f.isFile() && f.canExecute();
    }

    private static String lookupOnPath(String name) {
        String pathEnv = System.getenv("PATH");
        if (pathEnv == null) return null;
        for (String dir : pathEnv.split(File.pathSeparator)) {
            if (dir.isEmpty()) continue;
            File candidate = new File(dir, name);
            if (candidate.isFile() && candidate.canExecute()) {
                return candidate.getAbsolutePath();
            }
        }
        return null;
    }

    private static void deleteRecursively(Path p) {
        if (p == null || !Files.exists(p)) return;
        try (Stream<Path> s = Files.walk(p)) {
            s.sorted(Comparator.reverseOrder()).forEach(x -> {
                try { Files.deleteIfExists(x); } catch (IOException ignored) {}
            });
        } catch (IOException ignored) {}
    }
}
