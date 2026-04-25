/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.ttio.importers;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Bruker timsTOF {@code .d} importer — v0.8 M53.
 *
 * <p>Bruker's {@code .d} directory holds two files:
 * <ul>
 *   <li>{@code analysis.tdf} — a plain SQLite database with metadata
 *       tables ({@code Frames}, {@code GlobalMetadata},
 *       {@code Properties}, {@code Precursors}, ...).</li>
 *   <li>{@code analysis.tdf_bin} or {@code analysis.tdf_raw} — a
 *       binary blob with ZSTD-compressed frame data and a
 *       scan-to-ion index.</li>
 * </ul>
 *
 * <p>This Java reader consumes the SQLite metadata directly via
 * {@code java.sql} + {@code sqlite-jdbc} (already a dependency for
 * the SqliteProvider). Binary frame decompression is delegated to
 * the Python {@code ttio.importers.bruker_tdf.read} helper through
 * a subprocess, matching the ThermoRawReader → ThermoRawFileParser
 * pattern established in M38.</p>
 *
 * <p>A native Java port of the frame decoder (ZSTD + Bruker's
 * scan-to-ion index) is a v0.9 concern. For now, callers that want
 * binary extraction must have Python + {@code opentimspy} reachable
 * on {@code PATH} or via the {@code TTIO_PYTHON} env var.</p>
 *
 * <p>API status: Provisional (v0.8 M53).</p>
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.importers.bruker_tdf}, Objective-C
 * {@code TTIOBrukerTDFReader}.</p>
 *
 * @since 0.8
 */
public final class BrukerTDFReader {

    /** SQLite-level metadata snapshot — no binary extraction required. */
    public record Metadata(
        int frameCount,
        int ms1FrameCount,
        int ms2FrameCount,
        double retentionTimeMin,
        double retentionTimeMax,
        String instrumentVendor,
        String instrumentModel,
        String acquisitionSoftware,
        Map<String, String> properties,
        Map<String, String> globalMetadata
    ) {}

    /** Raised when the binary extraction path is requested but the
     *  Python delegate cannot be located or execution fails. */
    public static final class BrukerTDFException extends IOException {
        private static final long serialVersionUID = 1L;
        public BrukerTDFException(String msg) { super(msg); }
        public BrukerTDFException(String msg, Throwable cause) {
            super(msg, cause);
        }
    }

    private BrukerTDFReader() {}

    /**
     * Read the SQLite metadata from a Bruker {@code .d} directory
     * without touching the binary blob. No external tooling required.
     *
     * @throws BrukerTDFException if the directory is malformed.
     */
    public static Metadata readMetadata(Path dDir) throws BrukerTDFException {
        Path tdf = locateTdf(dDir);
        int frameCount = 0, ms1 = 0, ms2 = 0;
        double rtMin = 0.0, rtMax = 0.0;
        Map<String, String> properties = new LinkedHashMap<>();
        Map<String, String> globalMd  = new LinkedHashMap<>();

        try (Connection conn = DriverManager.getConnection(
                    "jdbc:sqlite:" + tdf.toAbsolutePath());
             Statement st = conn.createStatement()) {
            try (ResultSet rs = st.executeQuery("SELECT COUNT(*) FROM Frames")) {
                if (rs.next()) frameCount = rs.getInt(1);
            }
            try (ResultSet rs = st.executeQuery(
                    "SELECT COUNT(*) FROM Frames WHERE MsMsType = 0")) {
                if (rs.next()) ms1 = rs.getInt(1);
            }
            try (ResultSet rs = st.executeQuery(
                    "SELECT COUNT(*) FROM Frames WHERE MsMsType != 0")) {
                if (rs.next()) ms2 = rs.getInt(1);
            }
            try (ResultSet rs = st.executeQuery(
                    "SELECT MIN(Time), MAX(Time) FROM Frames")) {
                if (rs.next()) {
                    rtMin = rs.getDouble(1);
                    rtMax = rs.getDouble(2);
                }
            }
            // GlobalMetadata may not exist on very old fixtures.
            try (ResultSet rs = st.executeQuery(
                    "SELECT Key, Value FROM GlobalMetadata")) {
                while (rs.next()) {
                    globalMd.put(rs.getString(1), rs.getString(2));
                }
            } catch (SQLException ignore) {
                // table missing — silent fallback.
            }
            try (ResultSet rs = st.executeQuery(
                    "SELECT Key, Value FROM Properties")) {
                while (rs.next()) {
                    properties.put(rs.getString(1), rs.getString(2));
                }
            } catch (SQLException ignore) {
                // table missing — silent fallback.
            }
        } catch (SQLException e) {
            throw new BrukerTDFException(
                    "failed to read analysis.tdf metadata: " + tdf, e);
        }

        String vendor = pick(globalMd, "InstrumentVendor", "Vendor");
        if (vendor.isEmpty()) vendor = "Bruker";
        String model = pick(globalMd, "InstrumentName", "Model",
                            "MaldiApplicationType");
        String software = pick(globalMd, "AcquisitionSoftware",
                                "OperatingSystem");

        return new Metadata(frameCount, ms1, ms2, rtMin, rtMax,
                vendor, model, software, properties, globalMd);
    }

    /**
     * Import a Bruker {@code .d} directory into an {@code .tio} file
     * by delegating binary extraction to the Python helper
     * {@code ttio.importers.bruker_tdf}.
     *
     * <p>The Python interpreter is resolved in this order:
     * {@code TTIO_PYTHON} env var → {@code python3} on {@code PATH} →
     * {@code python} on {@code PATH}. The interpreter must have
     * {@code mpeg-o[bruker]} installed.</p>
     *
     * @param dDir   Bruker {@code .d} directory.
     * @param output target {@code .tio} output path.
     * @throws BrukerTDFException if the helper is unreachable or
     *         exits non-zero.
     */
    public static Path read(Path dDir, Path output) throws BrukerTDFException {
        // Metadata read is always performed locally — catches a
        // malformed directory before we spawn a subprocess.
        readMetadata(dDir);

        String python = resolvePython();
        String[] cmd = {
            python, "-m", "ttio.importers.bruker_tdf_cli",
            "--input", dDir.toAbsolutePath().toString(),
            "--output", output.toAbsolutePath().toString(),
        };
        ProcessBuilder pb = new ProcessBuilder(cmd).redirectErrorStream(true);
        try {
            Process proc = pb.start();
            int exit = proc.waitFor();
            if (exit != 0) {
                byte[] out = proc.getInputStream().readAllBytes();
                throw new BrukerTDFException(
                        "Python bruker_tdf helper exited " + exit + ": "
                        + new String(out).trim());
            }
        } catch (IOException | InterruptedException e) {
            throw new BrukerTDFException(
                    "failed to invoke Python bruker_tdf helper "
                    + "(install mpeg-o[bruker] and ensure python is on PATH)",
                    e);
        }
        if (!Files.isRegularFile(output)) {
            throw new BrukerTDFException(
                    "bruker_tdf helper reported success but produced no "
                    + "output: " + output);
        }
        return output;
    }

    // ── Internals ────────────────────────────────────────────────

    private static Path locateTdf(Path d) throws BrukerTDFException {
        if (!Files.isDirectory(d)) {
            throw new BrukerTDFException(
                    "No analysis.tdf found under " + d
                    + " — is this a Bruker .d directory?");
        }
        Path candidate = d.resolve("analysis.tdf");
        if (Files.isRegularFile(candidate)) return candidate;
        // Allow nested .d one level down.
        try (var stream = Files.list(d)) {
            var hit = stream.filter(Files::isDirectory)
                    .map(p -> p.resolve("analysis.tdf"))
                    .filter(Files::isRegularFile)
                    .findFirst();
            if (hit.isPresent()) return hit.get();
        } catch (IOException ignore) {}
        throw new BrukerTDFException(
                "No analysis.tdf found under " + d
                + " — is this a Bruker .d directory?");
    }

    private static String pick(Map<String, String> map, String... keys) {
        for (String k : keys) {
            String v = map.get(k);
            if (v != null && !v.isEmpty()) return v;
        }
        return "";
    }

    private static String resolvePython() throws BrukerTDFException {
        String env = System.getenv("TTIO_PYTHON");
        if (env != null && !env.isEmpty()) return env;
        for (String candidate : new String[]{"python3", "python"}) {
            if (isOnPath(candidate)) return candidate;
        }
        throw new BrukerTDFException(
                "No Python interpreter found — set TTIO_PYTHON or put "
                + "python3 on PATH to use the Bruker TDF binary helper.");
    }

    private static boolean isOnPath(String cmd) {
        String path = System.getenv("PATH");
        if (path == null) return false;
        String sep = System.getProperty("path.separator", ":");
        for (String dir : path.split(sep)) {
            Path candidate = Path.of(dir, cmd);
            if (Files.isExecutable(candidate)) return true;
            if (System.getProperty("os.name", "").toLowerCase().contains("win")) {
                Path winExe = Path.of(dir, cmd + ".exe");
                if (Files.isExecutable(winExe)) return true;
            }
        }
        return false;
    }
}
