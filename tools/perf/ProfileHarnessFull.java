/*
 * Multi-function Java perf harness for TTI-O.
 *
 * Mirrors profile_python_full.py so cross-language deltas are
 * comparable. Covers: MS write/read across all 4 providers,
 * .mots transport codec (plain + compressed), per-AU encryption,
 * HMAC signatures, JCAMP-DX write/read (AFFN + compressed),
 * and spectrum-class construction (Raman/IR/UV-Vis/2D-COS).
 *
 * Runs are warmed up once to let HotSpot compile, then each
 * benchmark is timed in a single iteration. Results are emitted
 * as a formatted table on stdout and optionally as JSON.
 *
 * Usage:
 *   javac -d _build -cp ... ProfileHarnessFull.java
 *   java  -cp ... tools.perf.ProfileHarnessFull [--n 10000] [--only ms.hdf5,...]
 */
package tools.perf;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.SignalArray;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.TwoDimensionalCorrelationSpectrum;
import global.thalion.ttio.UVVisSpectrum;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.Enums.IRMode;
import global.thalion.ttio.Enums.SamplingMode;
import global.thalion.ttio.AxisDescriptor;
import global.thalion.ttio.ValueRange;
import global.thalion.ttio.exporters.JcampDxWriter;
import global.thalion.ttio.importers.JcampDxReader;
import global.thalion.ttio.protection.PerAUFile;
import global.thalion.ttio.protection.SignatureManager;
import global.thalion.ttio.transport.TransportReader;
import global.thalion.ttio.transport.TransportWriter;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

public final class ProfileHarnessFull {

    // ── Workload builders ────────────────────────────────────────────

    private static SpectrumIndex makeIndex(int n, int peaks) {
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        double[] rts = new double[n];
        int[] mls = new int[n];
        int[] pols = new int[n];
        double[] pmzs = new double[n];
        int[] pcs = new int[n];
        double[] bps = new double[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * peaks;
            lengths[i] = peaks;
            rts[i] = i * 0.06;
            mls[i] = 1;
            pols[i] = 1;
            pmzs[i] = 0.0;
            pcs[i] = 0;
            bps[i] = 1000.0;
        }
        return new SpectrumIndex(n, offsets, lengths, rts, mls, pols, pmzs, pcs, bps);
    }

    private static AcquisitionRun makeRun(int n, int peaks) {
        SpectrumIndex idx = makeIndex(n, peaks);
        Map<String, double[]> channels = new LinkedHashMap<>();
        double[] mz = new double[n * peaks];
        double[] intensity = new double[n * peaks];
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < peaks; j++) {
                int pos = i * peaks + j;
                mz[pos] = 100.0 + i + j * 0.1;
                intensity[pos] = 1000.0 + ((i * 31 + j) % 1000);
            }
        }
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        return new AcquisitionRun("r", AcquisitionMode.MS1_DDA,
                idx, null, channels, List.of(), List.of(), null, 0);
    }

    // ── Benchmark result holder ──────────────────────────────────────

    static final class Result {
        final Map<String, Double> timings = new LinkedHashMap<>();
        final Map<String, Double> sizes = new LinkedHashMap<>();
        String error = null;
        void timing(String phase, long nanos) {
            timings.put(phase, nanos / 1e6);
        }
        void size(String label, long bytes) {
            sizes.put(label, bytes / 1e6);
        }
    }

    // ── MS write + read on each provider ─────────────────────────────

    private static Result benchMs(Path tmp, int n, int peaks,
                                   String provider) throws Exception {
        Result r = new Result();
        String url;
        switch (provider) {
            case "hdf5":   url = tmp.resolve("ms-hdf5.tio").toString(); break;
            case "memory": url = "memory://ms-bench-" + UUID.randomUUID(); break;
            case "sqlite": url = "sqlite://" + tmp.resolve("ms-sqlite.tio.sqlite"); break;
            case "zarr":   url = "zarr://" + tmp.resolve("ms-zarr.tio.zarr"); break;
            default: throw new IllegalArgumentException(provider);
        }

        AcquisitionRun run = makeRun(n, peaks);

        long s = System.nanoTime();
        try (SpectralDataset ds = SpectralDataset.create(
                url, "stress", "ISA-PERF",
                List.of(run), List.of(), List.of(), List.of())) {
            // written on close
        }
        r.timing("write", System.nanoTime() - s);

        s = System.nanoTime();
        long sampled = 0;
        try (SpectralDataset ds = SpectralDataset.open(url)) {
            AcquisitionRun back = ds.msRuns().get("r");
            int step = Math.max(1, n / 100);
            for (int i = 0; i < n; i += step) {
                Spectrum sp = back.objectAtIndex(i);
                sampled += sp.signalArrays().get("mz").length();
            }
        }
        r.timing("read", System.nanoTime() - s);
        if (sampled <= 0) throw new IllegalStateException("no data sampled");
        return r;
    }

    // ── Transport .mots codec ────────────────────────────────────────

    private static Result benchTransport(Path tmp, int n, int peaks,
                                          boolean useCompression) throws Exception {
        Result r = new Result();
        Path src = tmp.resolve(useCompression ? "xport-c.tio" : "xport.tio");
        try (SpectralDataset ds = SpectralDataset.create(
                src.toString(), "xport", "ISA-XPORT",
                List.of(makeRun(n, peaks)), List.of(), List.of(), List.of())) {
            // close writes
        }
        r.size("src_mb", Files.size(src));

        Path motsPath = tmp.resolve(useCompression ? "xport-c.mots" : "xport.mots");
        long s = System.nanoTime();
        try (SpectralDataset srcDs = SpectralDataset.open(src.toString())) {
            try (java.io.OutputStream out = Files.newOutputStream(motsPath);
                 TransportWriter tw = new TransportWriter(out)) {
                tw.setUseCompression(useCompression);
                tw.writeDataset(srcDs);
            }
        }
        r.timing("encode", System.nanoTime() - s);
        r.size("mots_mb", Files.size(motsPath));

        Path rtPath = tmp.resolve(useCompression ? "rt-c.tio" : "rt.tio");
        s = System.nanoTime();
        byte[] motsBytes = Files.readAllBytes(motsPath);
        try (TransportReader tr = new TransportReader(motsBytes)) {
            try (SpectralDataset rtDs = tr.materializeTo(rtPath.toString())) {
                // close writes
            }
        }
        r.timing("decode", System.nanoTime() - s);

        return r;
    }

    // ── Per-AU encryption ────────────────────────────────────────────

    private static Result benchEncryption(Path tmp, int n, int peaks) throws Exception {
        Result r = new Result();
        Path src = tmp.resolve("enc.tio");
        try (SpectralDataset ds = SpectralDataset.create(
                src.toString(), "enc", "ISA-ENC",
                List.of(makeRun(n, peaks)), List.of(), List.of(), List.of())) {
        }
        r.size("bytes_mb", Files.size(src));

        Path copy = tmp.resolve("enc-copy.tio");
        Files.copy(src, copy, StandardCopyOption.REPLACE_EXISTING);
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;

        long s = System.nanoTime();
        PerAUFile.encryptFile(copy.toString(), key, false, "hdf5");
        r.timing("encrypt", System.nanoTime() - s);

        s = System.nanoTime();
        Map<String, PerAUFile.DecryptedRun> plain =
                PerAUFile.decryptFile(copy.toString(), key, "hdf5");
        r.timing("decrypt", System.nanoTime() - s);
        if (plain.isEmpty()) throw new IllegalStateException("decrypt empty");
        return r;
    }

    // ── HMAC signature on intensity channel ─────────────────────────

    private static Result benchSignature(Path tmp, int n, int peaks) throws Exception {
        Result r = new Result();
        // Raw-bytes HMAC is Java's API shape: canonical bytes -> sign/verify.
        int nBytes = n * peaks * 8;
        byte[] data = new byte[nBytes];
        ByteBuffer bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < n * peaks; i++) {
            bb.putDouble(1000.0 + (i * 31L % 1000));
        }
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;

        long s = System.nanoTime();
        String sig = SignatureManager.sign(data, key);
        r.timing("sign", System.nanoTime() - s);

        s = System.nanoTime();
        boolean ok = SignatureManager.verify(data, sig, key);
        r.timing("verify", System.nanoTime() - s);
        if (!ok) throw new IllegalStateException("verify failed");
        return r;
    }

    // ── JCAMP-DX write + read ───────────────────────────────────────

    private static Result benchJcamp(Path tmp, int n) throws Exception {
        Result r = new Result();

        double[] wn = new double[n];
        double[] yAbs = new double[n];
        for (int i = 0; i < n; i++) {
            wn[i] = 4000.0 - (3600.0 / (n - 1)) * i;
            yAbs[i] = 0.5 + 0.4 * Math.sin(wn[i] / 50.0);
        }
        IRSpectrum ir = new IRSpectrum(wn, yAbs, 0, 0.0,
                IRMode.ABSORBANCE, 4.0, 32L);
        Path jdxIr = tmp.resolve("ir.jdx");
        long s = System.nanoTime();
        JcampDxWriter.writeIRSpectrum(ir, jdxIr, "perf IR");
        r.timing("ir_write", System.nanoTime() - s);
        s = System.nanoTime();
        JcampDxReader.readSpectrum(jdxIr);
        r.timing("ir_read", System.nanoTime() - s);

        double[] wnR = new double[n];
        double[] yR = new double[n];
        for (int i = 0; i < n; i++) {
            wnR[i] = 100.0 + (3100.0 / (n - 1)) * i;
            double diff = wnR[i] - 1500.0;
            yR[i] = 10.0 + 100.0 * Math.exp(-diff * diff / (300.0 * 300.0));
        }
        RamanSpectrum raman = new RamanSpectrum(wnR, yR, 0, 0.0,
                785.0, 20.0, 5.0);
        Path jdxR = tmp.resolve("raman.jdx");
        s = System.nanoTime();
        JcampDxWriter.writeRamanSpectrum(raman, jdxR, "perf Raman");
        r.timing("raman_write", System.nanoTime() - s);
        s = System.nanoTime();
        JcampDxReader.readSpectrum(jdxR);
        r.timing("raman_read", System.nanoTime() - s);

        double[] wl = new double[n];
        double[] abs = new double[n];
        for (int i = 0; i < n; i++) {
            wl[i] = 200.0 + (600.0 / (n - 1)) * i;
            double diff = wl[i] - 450.0;
            abs[i] = Math.exp(-diff * diff / (40.0 * 40.0));
        }
        UVVisSpectrum uvvis = new UVVisSpectrum(wl, abs, 0, 0.0, 1.0, "methanol");
        Path jdxU = tmp.resolve("uvvis.jdx");
        s = System.nanoTime();
        JcampDxWriter.writeUVVisSpectrum(uvvis, jdxU, "perf UV-Vis");
        r.timing("uvvis_write", System.nanoTime() - s);
        s = System.nanoTime();
        JcampDxReader.readSpectrum(jdxU);
        r.timing("uvvis_read", System.nanoTime() - s);

        // Hand-rolled SQZ fixture.
        String sqz = "@ABCDEFGHI";
        StringBuilder body = new StringBuilder(n * 2);
        int lineX = 100;
        for (int i = 0; i < n; i += 10) {
            body.append(lineX).append(' ');
            for (int j = i; j < Math.min(i + 10, n); j++) {
                body.append(sqz.charAt(j % 10));
            }
            body.append('\n');
            lineX += 10;
        }
        String jdx =
            "##TITLE=perf-compressed\n"
          + "##JCAMP-DX=5.01\n"
          + "##DATA TYPE=INFRARED ABSORBANCE\n"
          + "##XUNITS=1/CM\n##YUNITS=ABSORBANCE\n"
          + "##FIRSTX=100\n##LASTX=" + (100 + n - 1) + "\n##NPOINTS=" + n + "\n"
          + "##XFACTOR=1\n##YFACTOR=1\n"
          + "##XYDATA=(X++(Y..Y))\n"
          + body.toString()
          + "##END=\n";
        Path jdxC = tmp.resolve("compressed.jdx");
        Files.writeString(jdxC, jdx);
        s = System.nanoTime();
        JcampDxReader.readSpectrum(jdxC);
        r.timing("compressed_read", System.nanoTime() - s);

        return r;
    }

    // ── Spectrum build-only (no I/O) ────────────────────────────────

    private static Result benchSpectra(int n) {
        Result r = new Result();
        double[] wn = new double[n];
        double[] y = new double[n];
        for (int i = 0; i < n; i++) {
            wn[i] = 4000.0 - i;
            y[i] = 0.5;
        }
        long s = System.nanoTime();
        new IRSpectrum(wn, y, 0, 0.0, IRMode.ABSORBANCE, 4.0, 32L);
        r.timing("ir_build", System.nanoTime() - s);

        s = System.nanoTime();
        new RamanSpectrum(wn, y, 0, 0.0, 785.0, 20.0, 5.0);
        r.timing("raman_build", System.nanoTime() - s);

        s = System.nanoTime();
        new UVVisSpectrum(wn, y, 0, 0.0, 1.0, "methanol");
        r.timing("uvvis_build", System.nanoTime() - s);

        int m = Math.max(8, (int) Math.sqrt(n));
        double[] sync = new double[m * m];
        double[] asyncM = new double[m * m];
        for (int i = 0; i < m * m; i++) { sync[i] = Math.cos(i); asyncM[i] = Math.sin(i); }
        s = System.nanoTime();
        new TwoDimensionalCorrelationSpectrum(
                sync, asyncM, m,
                new AxisDescriptor("wavenumber", "1/cm",
                        new ValueRange(400.0, 4000.0), SamplingMode.UNIFORM),
                "temperature", "K", "IR");
        r.timing("2dcos_build", System.nanoTime() - s);
        return r;
    }

    // P4 (perf workplan): isolated codec microbenchmarks on
    // fixed-size payloads (1 MiB byte codecs, 10K names for the
    // tokenizer). Mirrors profile_python_full.py bench_codecs so
    // cross-language deltas are meaningful.
    private static Result benchCodecs(int n) {
        java.util.Random rng = new java.util.Random(42);
        int oneMiB = 1024 * 1024;

        // rANS: random bytes.
        byte[] ransIn = new byte[oneMiB];
        rng.nextBytes(ransIn);

        Result r = new Result();
        long t;
        byte[] tmp;

        t = System.nanoTime();
        byte[] o0 = global.thalion.ttio.codecs.Rans.encode(ransIn, 0);
        r.timings.put("rans_o0_encode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        global.thalion.ttio.codecs.Rans.decode(o0);
        r.timings.put("rans_o0_decode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        byte[] o1 = global.thalion.ttio.codecs.Rans.encode(ransIn, 1);
        r.timings.put("rans_o1_encode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        global.thalion.ttio.codecs.Rans.decode(o1);
        r.timings.put("rans_o1_decode", (System.nanoTime() - t) / 1e6);

        // BASE_PACK on pure ACGT.
        byte[] alphabet = {(byte) 'A', (byte) 'C', (byte) 'G', (byte) 'T'};
        byte[] bpIn = new byte[oneMiB];
        for (int i = 0; i < oneMiB; i++) bpIn[i] = alphabet[rng.nextInt(4)];
        t = System.nanoTime();
        byte[] bpEnc = global.thalion.ttio.codecs.BasePack.encode(bpIn);
        r.timings.put("base_pack_encode", (System.nanoTime() - t) / 1e6);
        t = System.nanoTime();
        global.thalion.ttio.codecs.BasePack.decode(bpEnc);
        r.timings.put("base_pack_decode", (System.nanoTime() - t) / 1e6);

        // QUALITY_BINNED on random Phred bytes.
        byte[] qbIn = new byte[oneMiB];
        for (int i = 0; i < oneMiB; i++) qbIn[i] = (byte) rng.nextInt(94);
        t = System.nanoTime();
        byte[] qbEnc = global.thalion.ttio.codecs.Quality.encode(qbIn);
        r.timings.put("quality_binned_encode", (System.nanoTime() - t) / 1e6);
        t = System.nanoTime();
        global.thalion.ttio.codecs.Quality.decode(qbEnc);
        r.timings.put("quality_binned_decode", (System.nanoTime() - t) / 1e6);

        // NAME_TOKENIZED: 10K Illumina-style names.
        java.util.List<String> names = new java.util.ArrayList<>(10_000);
        for (int i = 0; i < 10_000; i++) {
            names.add(String.format("M88_%08d:%03d:%02d",
                    i, rng.nextInt(1000), rng.nextInt(100)));
        }
        t = System.nanoTime();
        byte[] ntEnc = global.thalion.ttio.codecs.NameTokenizer.encode(names);
        r.timings.put("name_tokenized_encode", (System.nanoTime() - t) / 1e6);
        t = System.nanoTime();
        global.thalion.ttio.codecs.NameTokenizer.decode(ntEnc);
        r.timings.put("name_tokenized_decode", (System.nanoTime() - t) / 1e6);

        return r;
    }

    // ── Driver ──────────────────────────────────────────────────────

    private static final String[] BENCH_ORDER = {
        "ms.hdf5", "ms.memory", "ms.sqlite", "ms.zarr",
        "transport.plain", "transport.compressed",
        "encryption", "signatures", "jcamp", "spectra.build",
        "codecs",
    };

    private static Result runOne(String name, Path tmpRoot,
                                  int n, int peaks) throws Exception {
        Path tmp = Files.createTempDirectory(tmpRoot,
                "ttio-" + name.replace('.', '-') + "-");
        switch (name) {
            case "ms.hdf5":   return benchMs(tmp, n, peaks, "hdf5");
            case "ms.memory": return benchMs(tmp, n, peaks, "memory");
            case "ms.sqlite": return benchMs(tmp, n, peaks, "sqlite");
            case "ms.zarr":   return benchMs(tmp, n, peaks, "zarr");
            case "transport.plain":      return benchTransport(tmp, n, peaks, false);
            case "transport.compressed": return benchTransport(tmp, n, peaks, true);
            case "encryption":   return benchEncryption(tmp, n, peaks);
            case "signatures":   return benchSignature(tmp, n, peaks);
            case "jcamp":        return benchJcamp(tmp, n);
            case "spectra.build": return benchSpectra(n);
            case "codecs":       return benchCodecs(n);
            default: throw new IllegalArgumentException(name);
        }
    }

    public static void main(String[] args) throws Exception {
        int n = 10_000;
        int peaks = 16;
        Set<String> only = new HashSet<>();
        Set<String> skip = new HashSet<>();
        Path jsonPath = null;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--n":     n = Integer.parseInt(args[++i]); break;
                case "--peaks": peaks = Integer.parseInt(args[++i]); break;
                case "--only":  only.addAll(Arrays.asList(args[++i].split(","))); break;
                case "--skip":  skip.addAll(Arrays.asList(args[++i].split(","))); break;
                case "--json":  jsonPath = Paths.get(args[++i]); break;
                default: throw new IllegalArgumentException("unknown " + args[i]);
            }
        }

        Path tmpRoot = Paths.get(System.getProperty("java.io.tmpdir"),
                "mpgo_profile_java_full");
        Files.createDirectories(tmpRoot);

        System.out.println("=".repeat(78));
        System.out.printf("Java multi-function perf  n=%d  peaks=%d%n", n, peaks);
        System.out.println("=".repeat(78));

        // Warm up with a small MS run so HotSpot compiles the hot
        // path before we measure.
        Path warm = Files.createTempDirectory(tmpRoot, "warmup-");
        for (int i = 0; i < 2; i++) {
            benchMs(warm, 500, peaks, "hdf5");
        }

        Map<String, Result> results = new LinkedHashMap<>();
        for (String name : BENCH_ORDER) {
            if (!only.isEmpty() && !only.contains(name)) continue;
            if (skip.contains(name)) continue;
            try {
                Result r = runOne(name, tmpRoot, n, peaks);
                results.put(name, r);
                System.out.println("\n[" + name + "]");
                for (var e : r.timings.entrySet()) {
                    System.out.printf("  %-20s %10.1f ms%n",
                            e.getKey(), e.getValue());
                }
                for (var e : r.sizes.entrySet()) {
                    System.out.printf("  %-20s %10.2f MB%n",
                            e.getKey(), e.getValue());
                }
            } catch (Throwable t) {
                Result r = new Result();
                r.error = t.getClass().getSimpleName() + ": " + t.getMessage();
                results.put(name, r);
                System.out.println("\n[" + name + "] FAILED: " + r.error);
            }
        }

        System.out.println("\n" + "=".repeat(78));
        System.out.println("SUMMARY (milliseconds)");
        System.out.println("=".repeat(78));
        for (var e : results.entrySet()) {
            Result r = e.getValue();
            if (r.error != null) {
                System.out.printf("  %-28s FAILED: %s%n", e.getKey(), r.error);
                continue;
            }
            double total = r.timings.values().stream().mapToDouble(Double::doubleValue).sum();
            StringBuilder phases = new StringBuilder();
            for (var t : r.timings.entrySet()) {
                if (phases.length() > 0) phases.append("  ");
                phases.append(t.getKey()).append('=')
                      .append(String.format("%.1f", t.getValue()));
            }
            System.out.printf("  %-28s total=%7.1f   %s%n",
                    e.getKey(), total, phases.toString());
        }

        // V2.1 (verification workplan): emit JSON matching the
        // Python + ObjC harness schema so tools/perf/compare_baseline.py
        // can diff Java against tools/perf/baseline.json["java"].
        // Timings are converted ms → seconds so the units match the
        // other harnesses; sizes (MB) are passed through as-is.
        if (jsonPath != null) {
            Files.createDirectories(jsonPath.getParent() == null
                ? Paths.get(".") : jsonPath.getParent());
            StringBuilder json = new StringBuilder();
            json.append("{\n");
            json.append("  \"n\": ").append(n).append(",\n");
            json.append("  \"peaks\": ").append(peaks).append(",\n");
            json.append("  \"results\": {");
            boolean firstBench = true;
            for (var e : results.entrySet()) {
                if (!firstBench) json.append(",");
                firstBench = false;
                json.append("\n    \"").append(e.getKey()).append("\": {");
                Result r = e.getValue();
                if (r.error != null) {
                    json.append("\"error\": \"")
                        .append(r.error.replace("\\", "\\\\").replace("\"", "\\\""))
                        .append("\"");
                } else {
                    boolean firstField = true;
                    for (var t : r.timings.entrySet()) {
                        if (!firstField) json.append(", ");
                        firstField = false;
                        // ms → seconds (divide by 1000) to match Python/ObjC.
                        json.append("\"").append(t.getKey()).append("\": ")
                            .append(String.format(java.util.Locale.ROOT,
                                "%.7f", t.getValue() / 1000.0));
                    }
                    for (var s : r.sizes.entrySet()) {
                        if (!firstField) json.append(", ");
                        firstField = false;
                        json.append("\"").append(s.getKey()).append("\": ")
                            .append(String.format(java.util.Locale.ROOT,
                                "%.6f", s.getValue()));
                    }
                }
                json.append("}");
            }
            json.append("\n  }\n");
            json.append("}\n");
            Files.writeString(jsonPath, json.toString());
            System.out.println("\nJSON dump: " + jsonPath);
        }
    }
}
