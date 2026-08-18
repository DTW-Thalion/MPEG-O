/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.exporters.ExporterRegistry;
import global.thalion.ttio.exporters.UnknownFormatError;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Emit one layer of a {@code .tio} container in a supported external
 * format, dispatching through {@link ExporterRegistry}.
 *
 * <p>Parallel to Python {@code ttio.tools.workbench_cli} {@code cmd_export}.
 *
 * <p>Usage:
 * <pre>
 *   ExportCli --input &lt;in.tio&gt; --format &lt;fmt&gt; --output &lt;out&gt; \
 *             [--layer &lt;layer&gt;] [--extra k=v ...]
 *   ExportCli --list-formats
 * </pre>
 *
 * <p>Exit codes (mirroring Python {@code cmd_export}): {@code 0} success,
 * {@code 2} exporter failure or bad/missing args, {@code 3} unsupported or
 * delegated ({@code fasta}/{@code fastq}) format.
 */
public final class ExportCli {

    private static final String PROG = "ExportCli";

    private ExportCli() {
    }

    public static void main(String[] args) {
        System.exit(run(args));
    }

    /** Testable entry point: returns the process exit code. */
    public static int run(String[] args) {
        String input = null;
        String rawFormat = null;
        String output = null;
        String layer = null;
        Map<String, Object> opts = new LinkedHashMap<>();

        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            switch (a) {
                case "--list-formats" -> {
                    for (String f : ExporterRegistry.supportedExportFormats()) {
                        System.out.println(f);
                    }
                    return 0;
                }
                case "--threads" -> System.setProperty("ttio.threads", args[++i]);
                case "--input" -> {
                    if (i + 1 >= args.length) {
                        return usage();
                    }
                    input = args[++i];
                }
                case "--format" -> {
                    if (i + 1 >= args.length) {
                        return usage();
                    }
                    rawFormat = args[++i];
                }
                case "--output" -> {
                    if (i + 1 >= args.length) {
                        return usage();
                    }
                    output = args[++i];
                }
                case "--layer" -> {
                    if (i + 1 >= args.length) {
                        return usage();
                    }
                    layer = args[++i];
                }
                case "--extra" -> {
                    if (i + 1 >= args.length) {
                        return usage();
                    }
                    String kv = args[++i];
                    int eq = kv.indexOf('=');
                    if (eq < 0) {
                        System.err.println(
                            PROG + ": --extra expects key=value, got: " + kv);
                        return usage();
                    }
                    opts.put(kv.substring(0, eq), kv.substring(eq + 1));
                }
                default -> {
                    System.err.println(PROG + ": unknown argument: " + a);
                    return usage();
                }
            }
        }

        if (input == null || rawFormat == null || output == null) {
            return usage();
        }

        String fmt = ExporterRegistry.normalize(rawFormat);

        // fasta / fastq keep their richer dedicated CLIs; not yet wired
        // through this command (Python delegates them — here we report).
        if (ExporterRegistry.CLI_DELEGATED.contains(fmt)) {
            System.err.println(PROG + ": format '" + fmt
                + "' is delegated to the dedicated fasta/fastq tools");
            return 3;
        }

        if (!ExporterRegistry.isRegistryFormat(fmt)) {
            return unsupported(rawFormat);
        }

        try {
            ExporterRegistry.export(
                fmt, Path.of(input), layer, Path.of(output), opts);
        } catch (UnknownFormatError e) {
            return unsupported(rawFormat);
        } catch (Exception e) {
            System.err.println(PROG + ": export failed (" + rawFormat + "): "
                + e.getMessage());
            return 2;
        }
        System.out.println("exported " + output);
        return 0;
    }

    private static int unsupported(String rawFormat) {
        System.err.println(PROG + ": unsupported --format: " + rawFormat
            + ". Supported: "
            + String.join(", ", ExporterRegistry.supportedExportFormats())
            + ".");
        return 3;
    }

    private static int usage() {
        System.err.println(
            "usage: ExportCli --input <in.tio> --format <fmt> "
            + "--output <out> [--layer <layer>] [--extra k=v ...]\n"
            + "       ExportCli --list-formats");
        return 2;
    }
}
