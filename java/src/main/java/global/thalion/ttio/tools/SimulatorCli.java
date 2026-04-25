/*
 * TTI-O Java Implementation — v0.10 M69.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.transport.AcquisitionSimulator;
import global.thalion.ttio.transport.TransportWriter;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;
import java.util.Objects;

/**
 * Command-line simulator entrypoint.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/ttio.jar global.thalion.ttio.tools.SimulatorCli \
 *        output.tis [--scan-rate 10] [--duration 10] [--ms1-fraction 0.3] \
 *        [--mz-min 100] [--mz-max 2000] [--n-peaks 200] [--seed 42]
 * </pre>
 *
 * <p>Parallel to Python {@code ttio.tools.simulator_cli} and
 * ObjC {@code TtioSimulator}.</p>
 */
public final class SimulatorCli {

    public static void main(String[] args) throws IOException {
        Map<String, String> parsed = parse(args);
        if (parsed == null) {
            System.err.println("usage: SimulatorCli <output.tis> "
                    + "[--scan-rate N] [--duration N] [--ms1-fraction N] "
                    + "[--mz-min N] [--mz-max N] [--n-peaks N] [--seed N]");
            System.exit(2);
            return;
        }
        String output = Objects.requireNonNull(parsed.get("__output"),
                "output path required");
        double scanRate = Double.parseDouble(parsed.getOrDefault("scan-rate", "10"));
        double duration = Double.parseDouble(parsed.getOrDefault("duration", "10"));
        double ms1 = Double.parseDouble(parsed.getOrDefault("ms1-fraction", "0.3"));
        double mzMin = Double.parseDouble(parsed.getOrDefault("mz-min", "100"));
        double mzMax = Double.parseDouble(parsed.getOrDefault("mz-max", "2000"));
        int nPeaks = Integer.parseInt(parsed.getOrDefault("n-peaks", "200"));
        long seed = Long.parseLong(parsed.getOrDefault("seed", "42"));

        AcquisitionSimulator sim = new AcquisitionSimulator(
                scanRate, duration, ms1, mzMin, mzMax, nPeaks, seed);
        int n;
        try (TransportWriter tw = new TransportWriter(Path.of(output))) {
            n = sim.streamToWriter(tw);
        }
        System.out.println(n + " access units written to " + output);
    }

    /** Flag parser: ``--key value`` + one positional ``__output``. */
    static Map<String, String> parse(String[] args) {
        java.util.LinkedHashMap<String, String> out = new java.util.LinkedHashMap<>();
        int i = 0;
        while (i < args.length) {
            String a = args[i];
            if (a.startsWith("--")) {
                if (i + 1 >= args.length) return null;
                out.put(a.substring(2), args[i + 1]);
                i += 2;
            } else if (!out.containsKey("__output")) {
                out.put("__output", a);
                i += 1;
            } else {
                return null;
            }
        }
        if (!out.containsKey("__output")) return null;
        return out;
    }
}
