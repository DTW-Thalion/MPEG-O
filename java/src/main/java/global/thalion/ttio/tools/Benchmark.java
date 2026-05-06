/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.TransportWriter;
import global.thalion.ttio.transport.TransportReader;

import java.io.IOException;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Java microbenchmark harness for transport encode + decode.
 *
 * <p>Pairs with the Python stress runner
 * ({@code python/tests/stress/test_provider_benchmark.py},
 * {@code .../test_fasta_fastq_benchmark.py},
 * {@code .../test_production_corpus_benchmark.py}) to give
 * release-to-release perf tracking parity across Python and Java.
 * The cross-language perf table in
 * {@code docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md}
 * §3 is now reproducible from this binary.
 *
 * <p>Inputs: an existing source {@code .tio} file (built by any of
 * the language-specific writers; the Python {@code BamReader} or
 * the FASTQ harness fixtures are convenient). The bench times:
 *
 * <ul>
 *   <li>Transport encode in per-AU mode</li>
 *   <li>Transport encode in Phase 2c-T bulk mode</li>
 *   <li>Transport decode of each produced {@code .tis}
 *       back into a {@code .tio}</li>
 * </ul>
 *
 * <p>Records timings + on-disk sizes to a JSON file. Default output
 * path: {@code java/target/benchmark_results.json}.
 *
 * <p>Usage:
 * <pre>
 *   mvn -DskipTests package
 *   java -Djava.library.path=$REPO/native/_build \
 *        -cp target/classes:&lt;deps&gt; \
 *        global.thalion.ttio.tools.Benchmark \
 *          &lt;source.tio&gt; [output.json]
 * </pre>
 *
 * <p>Cross-language equivalents: the Python harness writes results
 * to {@code python/tests/stress/benchmark_results.json}; the ObjC
 * harness writes to {@code objc/Tests/benchmark_results.json}.
 */
public final class Benchmark {

    public static void main(String[] args) throws IOException {
        if (args.length < 1) {
            System.err.println(
                "usage: Benchmark <source.tio> [output.json]\n"
                + "Times transport encode + decode (per-AU and Phase 2c-T bulk)\n"
                + "and writes a JSON summary suitable for release-to-release diffs.");
            System.exit(2);
        }
        Path src = Path.of(args[0]);
        Path out = Path.of(args.length > 1 ? args[1] : "target/benchmark_results.json");
        if (out.getParent() != null) Files.createDirectories(out.getParent());
        if (!Files.isRegularFile(src)) {
            System.err.println("source .tio not found: " + src);
            System.exit(1);
        }

        Map<String, Object> results = new LinkedHashMap<>();
        results.put("language", "java");
        results.put("source_tio", src.toString());
        results.put("source_bytes", Files.size(src));
        results.put("timestamp_unix", System.currentTimeMillis() / 1000);
        results.put("scenarios", runAll(src));

        try (PrintWriter pw = new PrintWriter(Files.newBufferedWriter(out))) {
            writeJson(pw, results, 0);
            pw.println();
        }
        System.err.println("benchmark results written to " + out);
    }

    private static Map<String, Object> runAll(Path src) throws IOException {
        Map<String, Object> scenarios = new LinkedHashMap<>();
        Path tmpRoot = Files.createTempDirectory("ttio_java_bench_");
        try {
            scenarios.put("transport_encode_per_au", encodeOne(src, tmpRoot, false));
            scenarios.put("transport_encode_bulk",   encodeOne(src, tmpRoot, true));
            scenarios.put("transport_decode_per_au",
                decodeOne(tmpRoot.resolve("per_au.tis"), tmpRoot.resolve("per_au_rt.tio")));
            scenarios.put("transport_decode_bulk",
                decodeOne(tmpRoot.resolve("bulk.tis"), tmpRoot.resolve("bulk_rt.tio")));
        } finally {
            try {
                Files.walk(tmpRoot)
                     .sorted(java.util.Comparator.reverseOrder())
                     .map(Path::toFile)
                     .forEach(java.io.File::delete);
            } catch (IOException ignore) {}
        }
        return scenarios;
    }

    private static Map<String, Object> encodeOne(
        Path src, Path tmp, boolean bulk
    ) throws IOException {
        Path tis = tmp.resolve(bulk ? "bulk.tis" : "per_au.tis");
        long t0 = System.nanoTime();
        try (var ds = SpectralDataset.open(src.toString());
             TransportWriter tw = new TransportWriter(tis)) {
            tw.setUseBulkMode(bulk);
            tw.writeDataset(ds);
        }
        long elapsed = System.nanoTime() - t0;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("seconds", roundSeconds(elapsed));
        m.put("tis_bytes", Files.size(tis));
        m.put("bulk", bulk);
        return m;
    }

    private static Map<String, Object> decodeOne(
        Path tis, Path rt
    ) throws IOException {
        long t0 = System.nanoTime();
        try (TransportReader tr = new TransportReader(tis)) {
            tr.materializeTo(rt.toString()).close();
        }
        long elapsed = System.nanoTime() - t0;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("seconds", roundSeconds(elapsed));
        m.put("rt_tio_bytes", Files.size(rt));
        return m;
    }

    private static double roundSeconds(long nanos) {
        return Math.round((nanos / 1.0e9) * 10000.0) / 10000.0;
    }

    @SuppressWarnings({"rawtypes"})
    private static void writeJson(PrintWriter pw, Object value, int indent) {
        String pad = "  ".repeat(indent);
        String inner = "  ".repeat(indent + 1);
        if (value instanceof Map<?, ?> map) {
            pw.print("{");
            int n = map.size(), i = 0;
            for (Map.Entry e : ((Map<?, ?>) map).entrySet()) {
                if (i == 0) pw.println();
                pw.print(inner);
                pw.print("\"" + e.getKey() + "\": ");
                writeJson(pw, e.getValue(), indent + 1);
                pw.println(i == n - 1 ? "" : ",");
                i++;
            }
            if (n > 0) pw.print(pad);
            pw.print("}");
        } else if (value instanceof Number || value instanceof Boolean) {
            pw.print(value);
        } else if (value == null) {
            pw.print("null");
        } else {
            pw.print("\"" + value.toString().replace("\"", "\\\"") + "\"");
        }
    }
}
