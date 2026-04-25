/*
 * Java profiling harness for TTI-O. Matches the Python + ObjC
 * harnesses: 10K spectra, 16 peaks, HDF5 backend.
 *
 * Run with JFR enabled:
 *   java -XX:StartFlightRecording=duration=20s,filename=/tmp/mpgo_java.jfr \
 *        -cp ... tools.perf.ProfileHarness
 *
 * Phase timings are emitted on stdout; JFR file can be parsed with
 *   jfr print --events jdk.ExecutionSample /tmp/mpgo_java.jfr
 */
package tools.perf;

import com.dtwthalion.ttio.AcquisitionRun;
import com.dtwthalion.ttio.SignalArray;
import com.dtwthalion.ttio.SpectralDataset;
import com.dtwthalion.ttio.Spectrum;
import com.dtwthalion.ttio.SpectrumIndex;
import com.dtwthalion.ttio.Enums.AcquisitionMode;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class ProfileHarness {

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

    private static void workload(Path ttio, int n, int peaks, long[] t) throws Exception {
        long s = System.nanoTime();
        AcquisitionRun run = makeRun(n, peaks);
        t[0] = System.nanoTime() - s;                               // build

        s = System.nanoTime();
        try (SpectralDataset ds = SpectralDataset.create(
                ttio.toString(), "stress", "ISA-STRESS",
                List.of(run), List.of(), List.of(), List.of())) {
            // written on close
        }
        t[1] = System.nanoTime() - s;                               // write

        s = System.nanoTime();
        long sampled = 0;
        try (SpectralDataset ds = SpectralDataset.open(ttio.toString())) {
            AcquisitionRun back = ds.msRuns().get("r");
            if (back.spectrumCount() != n) {
                throw new IllegalStateException("expected " + n + " got " + back.spectrumCount());
            }
            for (int i = 0; i < n; i += 100) {
                Spectrum spec = back.objectAtIndex(i);
                sampled += spec.signalArrays().get("mz").length();
            }
        }
        t[2] = System.nanoTime() - s;                               // read
        long expected = ((long)(n + 99) / 100L) * peaks;
        if (sampled != expected) {
            throw new IllegalStateException("sampled=" + sampled + " expected=" + expected);
        }
    }

    public static void main(String[] args) throws Exception {
        int n = 10_000;
        int peaks = 16;
        int warmups = 2;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--n": n = Integer.parseInt(args[++i]); break;
                case "--peaks": peaks = Integer.parseInt(args[++i]); break;
                case "--warmups": warmups = Integer.parseInt(args[++i]); break;
                default: throw new IllegalArgumentException("unknown arg " + args[i]);
            }
        }

        Path outDir = Paths.get(System.getProperty("user.home"),
                                 "mpgo_profile_java_out");
        Files.createDirectories(outDir);

        // Warm up — gives HotSpot time to compile hot methods.
        for (int i = 0; i < warmups; i++) {
            Path warm = outDir.resolve("warm_" + i + ".tio");
            Files.deleteIfExists(warm);
            workload(warm, n, peaks, new long[3]);
            Files.deleteIfExists(warm);
        }

        Path ttio = outDir.resolve("stress.tio");
        Files.deleteIfExists(ttio);

        long[] t = new long[3];
        workload(ttio, n, peaks, t);

        long size = Files.size(ttio);
        System.out.println("=".repeat(78));
        System.out.printf("Java profile: n=%d, peaks=%d, file=%.2f MB, warmups=%d%n",
                          n, peaks, size / 1e6, warmups);
        System.out.println("=".repeat(78));
        System.out.printf("  phase build     : %8.1f ms%n", t[0] / 1e6);
        System.out.printf("  phase write     : %8.1f ms%n", t[1] / 1e6);
        System.out.printf("  phase read      : %8.1f ms%n", t[2] / 1e6);
        double total = (t[0] + t[1] + t[2]) / 1e6;
        System.out.printf("  phase TOTAL     : %8.1f ms%n", total);
    }
}
