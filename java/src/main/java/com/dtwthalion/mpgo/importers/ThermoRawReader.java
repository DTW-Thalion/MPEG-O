/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.AcquisitionRun;

import java.io.File;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;

/**
 * Thermo {@code .raw} importer — M38.
 *
 * <p>Delegates to the user-installed <a href="https://github.com/compomics/ThermoRawFileParser">
 * ThermoRawFileParser</a> binary: {@code <raw>} → mzML in a temp dir,
 * then parses the mzML via {@link MzMLReader}. No proprietary code is
 * shipped.</p>
 *
 * <p>Binary resolution order:</p>
 * <ol>
 *   <li>Explicit path via {@link #read(String, String)}.</li>
 *   <li>{@code THERMORAWFILEPARSER} environment variable.</li>
 *   <li>{@code ThermoRawFileParser} on {@code PATH}.</li>
 *   <li>{@code ThermoRawFileParser.exe} on {@code PATH} — invoked via {@code mono}.</li>
 * </ol>
 *
 * <p><b>API status:</b> Stable (M38 shipped; delegates to ThermoRawFileParser
 * binary).</p>
 *
 * <p><b>Cross-language equivalents:</b><br>
 * Objective-C: {@code MPGOThermoRawReader} (v0.4 stub; delegation to
 * ThermoRawFileParser is a future milestone in ObjC) &middot;
 * Python: {@code mpeg_o.importers.thermo_raw} (M38 shipped)</p>
 *
 * @since 0.6
 */
public final class ThermoRawReader {

    private ThermoRawReader() {}

    public static AcquisitionRun read(String path) throws IOException {
        return read(path, null);
    }

    public static AcquisitionRun read(String path, String thermoRawFileParser)
            throws IOException {
        Path raw = Path.of(path);
        if (!Files.isRegularFile(raw)) {
            throw new IOException("Thermo .raw file not found: " + raw);
        }

        List<String> cmdPrefix = resolveBinary(thermoRawFileParser);

        Path tmpDir = Files.createTempDirectory("mpgo_thermo_");
        try {
            List<String> argv = new ArrayList<>(cmdPrefix);
            argv.addAll(List.of("-i", raw.toString(),
                                "-o", tmpDir.toString(),
                                "-f", "2"));

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
                throw new IOException("interrupted waiting for ThermoRawFileParser");
            }
            if (rc != 0) {
                String head = output.length() > 500 ? output.substring(0, 500) : output;
                throw new ThermoRawException("ThermoRawFileParser exited " + rc
                        + ": " + head.trim());
            }

            String stem = raw.getFileName().toString();
            int dot = stem.lastIndexOf('.');
            if (dot > 0) stem = stem.substring(0, dot);
            Path mzml = tmpDir.resolve(stem + ".mzML");
            if (!Files.isRegularFile(mzml)) {
                try (Stream<Path> s = Files.list(tmpDir)) {
                    mzml = s.filter(p -> p.getFileName().toString()
                                        .toLowerCase().endsWith(".mzml"))
                           .findFirst().orElse(null);
                }
                if (mzml == null) {
                    throw new ThermoRawException(
                            "ThermoRawFileParser produced no mzML in " + tmpDir);
                }
            }

            try {
                return MzMLReader.read(mzml.toString());
            } catch (MzMLParseException e) {
                throw new ThermoRawException("MzMLReader failed on "
                        + "ThermoRawFileParser output: " + e.getMessage(), e);
            }
        } finally {
            deleteRecursively(tmpDir);
        }
    }

    private static List<String> resolveBinary(String explicit) throws IOException {
        if (explicit != null) {
            if (!isExecutable(explicit)) {
                throw new IOException(
                        "ThermoRawFileParser binary not found or not executable: "
                        + explicit);
            }
            return wrapIfDotNet(explicit);
        }

        String env = System.getenv("THERMORAWFILEPARSER");
        if (env != null && !env.isBlank()) {
            if (!isExecutable(env)) {
                throw new IOException(
                        "THERMORAWFILEPARSER env var points to missing/"
                        + "non-executable binary: " + env);
            }
            return wrapIfDotNet(env);
        }

        String native_ = lookupOnPath("ThermoRawFileParser");
        if (native_ != null) return List.of(native_);

        String dotnet = lookupOnPath("ThermoRawFileParser.exe");
        if (dotnet != null) {
            String mono = lookupOnPath("mono");
            if (mono == null) {
                throw new IOException(
                        "Found ThermoRawFileParser.exe but mono is not on PATH.");
            }
            return List.of(mono, dotnet);
        }

        throw new IOException(
                "ThermoRawFileParser not found on PATH and THERMORAWFILEPARSER "
                + "not set. See docs/vendor-formats.md for installation.");
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
