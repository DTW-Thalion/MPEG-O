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
 * op is timed as the minimum of N reps (--reps, default 7) with a
 * per-op warmup discarded, to reduce run-to-run variance. Results
 * are emitted as a formatted table on stdout and optionally as JSON.
 *
 * Usage:
 *   javac -d _build -cp ... ProfileHarnessFull.java
 *   java  -cp ... tools.perf.ProfileHarnessFull [--n 10000] [--reps 5] [--only ms.hdf5,...]
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
import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.importers.MzMLReader;
import global.thalion.ttio.importers.NmrMLReader;
import global.thalion.ttio.protection.PerAUFile;
import global.thalion.ttio.protection.SignatureManager;
import global.thalion.ttio.transport.TransportReader;
import global.thalion.ttio.transport.TransportWriter;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Polarity;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.StreamReader;
import global.thalion.ttio.StreamWriter;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.protection.EncryptionManager;

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

    /** Number of timed repetitions per op (the minimum is reported). Default 7. */
    static int REPS = 7;

    /**
     * Run {@code op} once (warmup, discarded) then {@code reps} times;
     * return the MINIMUM elapsed milliseconds. The min is the
     * least-interfered sample (contention only ever makes an op slower),
     * so it is the most reproducible estimate of true cost and cuts
     * run-to-run variance far more than the median did. Mirrors the
     * Python harness (warmup + min).
     */
    static double timedMinMs(int reps, Runnable op) {
        op.run(); // warmup, discarded
        double best = Double.POSITIVE_INFINITY;
        for (int i = 0; i < reps; i++) {
            long s = System.nanoTime();
            op.run();
            double ms = (System.nanoTime() - s) / 1e6;
            if (ms < best) best = ms;
        }
        return best;
    }

    /**
     * Sum of on-disk (compressed) storage over every dataset in a .tio.
     *
     * Reports the real allocated byte cost of the data, not the HDF5 FILE
     * size — Java's HDF5 layer adds an ~8 MB metadata-aggregation block to
     * every file, so {@code Files.size} massively overstates the "source
     * size" and is not comparable to the Python/ObjC harnesses. Walking the
     * file with {@code H5Ovisit} and summing {@code H5Dget_storage_size}
     * (compressed allocated bytes per dataset) gives an honest,
     * methodologically-identical size across all three SDKs. See issue #251.
     *
     * @return total compressed dataset storage in BYTES.
     */
    static long compressedStorageBytes(Path path) throws Exception {
        long fid = hdf.hdf5lib.H5.H5Fopen(
                path.toString(),
                hdf.hdf5lib.HDF5Constants.H5F_ACC_RDONLY,
                hdf.hdf5lib.HDF5Constants.H5P_DEFAULT);
        final long[] total = {0};
        try {
            hdf.hdf5lib.callbacks.H5O_iterate_t cb =
                (long objId, String name,
                 hdf.hdf5lib.structs.H5O_info_t info,
                 hdf.hdf5lib.callbacks.H5O_iterate_opdata_t op) -> {
                    if (info.type == hdf.hdf5lib.HDF5Constants.H5O_TYPE_DATASET) {
                        long did = -1;
                        try {
                            did = hdf.hdf5lib.H5.H5Oopen(
                                    objId, name,
                                    hdf.hdf5lib.HDF5Constants.H5P_DEFAULT);
                            total[0] += hdf.hdf5lib.H5.H5Dget_storage_size(did);
                        } catch (Exception e) {
                            // ignore unreadable object; keep walking
                        } finally {
                            if (did >= 0) {
                                try { hdf.hdf5lib.H5.H5Oclose(did); }
                                catch (Exception ignore) {}
                            }
                        }
                    }
                    return 0; // H5_ITER_CONT
                };
            hdf.hdf5lib.callbacks.H5O_iterate_opdata_t opData =
                new hdf.hdf5lib.callbacks.H5O_iterate_opdata_t() {};
            hdf.hdf5lib.H5.H5Ovisit(fid,
                    hdf.hdf5lib.HDF5Constants.H5_INDEX_NAME,
                    hdf.hdf5lib.HDF5Constants.H5_ITER_NATIVE,
                    cb, opData);
        } finally {
            hdf.hdf5lib.H5.H5Fclose(fid);
        }
        return total[0];
    }

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
        void timingMs(String phase, double ms) {
            timings.put(phase, ms);
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

        final AcquisitionRun run = makeRun(n, peaks);
        final String fUrl = url;
        final int fN = n;

        // write: HDF5/sqlite/zarr create truncates; memory:// re-creates.
        // try-with-resources closes the dataset each rep -> rep-safe.
        r.timingMs("write", timedMinMs(REPS, () -> {
            try (SpectralDataset ds = SpectralDataset.create(
                    fUrl, "stress", "ISA-PERF",
                    List.of(run), List.of(), List.of(), List.of())) {
                // written on close
            } catch (Exception e) { throw new RuntimeException(e); }
        }));

        // read: pure open + sample, rep-safe.
        final long[] sampledBox = {0};
        r.timingMs("read", timedMinMs(REPS, () -> {
            long sampled = 0;
            try (SpectralDataset ds = SpectralDataset.open(fUrl)) {
                AcquisitionRun back = ds.msRuns().get("r");
                int step = Math.max(1, fN / 100);
                for (int i = 0; i < fN; i += step) {
                    Spectrum sp = back.objectAtIndex(i);
                    sampled += sp.signalArrays().get("mz").length();
                }
            } catch (Exception e) { throw new RuntimeException(e); }
            sampledBox[0] = sampled;
        }));
        if (sampledBox[0] <= 0) throw new IllegalStateException("no data sampled");
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
        // src_mb: sum of compressed dataset storage, not container file size
        // (which includes Java HDF5's ~8 MB meta-block). See issue #251.
        r.size("src_mb", compressedStorageBytes(src));

        final Path motsPath = tmp.resolve(useCompression ? "xport-c.mots" : "xport.mots");
        final Path fSrc = src;
        final boolean fComp = useCompression;
        // encode: newOutputStream truncates the .mots each rep; src opened
        // read-only and closed via try-with-resources -> rep-safe.
        r.timingMs("encode", timedMinMs(REPS, () -> {
            try (SpectralDataset srcDs = SpectralDataset.open(fSrc.toString())) {
                try (java.io.OutputStream out = Files.newOutputStream(motsPath);
                     TransportWriter tw = new TransportWriter(out)) {
                    tw.setUseCompression(fComp);
                    tw.writeDataset(srcDs);
                }
            } catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.size("mots_mb", Files.size(motsPath));

        final Path rtPath = tmp.resolve(useCompression ? "rt-c.tio" : "rt.tio");
        final byte[] motsBytes = Files.readAllBytes(motsPath);
        // decode: materializeTo returns an open dataset (closed each rep via
        // try-with-resources); rtPath is HDF5-truncated each rep -> rep-safe.
        r.timingMs("decode", timedMinMs(REPS, () -> {
            try (TransportReader tr = new TransportReader(motsBytes)) {
                try (SpectralDataset rtDs = tr.materializeTo(rtPath.toString())) {
                    // close writes
                }
            } catch (Exception e) { throw new RuntimeException(e); }
        }));

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
        // bytes_mb: sum of compressed dataset storage, not container file
        // size (which includes Java HDF5's ~8 MB meta-block). See issue #251.
        r.size("bytes_mb", compressedStorageBytes(src));

        final byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;

        // encrypt: encryptFile mutates the file in place (consumes plaintext),
        // so it is NOT re-runnable on the same path. Re-target a fresh copy
        // of the plaintext src per rep so each rep encrypts virgin input.
        // The per-rep copy is staged OUTSIDE the timed window so only the
        // encrypt op is measured (inlined min; the helper would time the
        // copy too). Includes a discarded warmup rep, matching timedMinMs.
        final Path encCopy = tmp.resolve("enc-copy.tio");
        double encBest = Double.POSITIVE_INFINITY;
        for (int rep = -1; rep < REPS; rep++) {
            Files.copy(src, encCopy, StandardCopyOption.REPLACE_EXISTING);
            long es = System.nanoTime();
            PerAUFile.encryptFile(encCopy.toString(), key, false, "hdf5");
            double elapsed = (System.nanoTime() - es) / 1e6;
            if (rep >= 0 && elapsed < encBest) encBest = elapsed; // rep == -1 is warmup
        }
        r.timingMs("encrypt", encBest);

        // decrypt: read-only over a stable encrypted file -> rep-safe.
        // (encCopy is left encrypted by the last encrypt rep above.)
        final Path decCopy = tmp.resolve("dec-copy.tio");
        Files.copy(encCopy, decCopy, StandardCopyOption.REPLACE_EXISTING);
        final Map<String, PerAUFile.DecryptedRun>[] plainBox =
                new Map[]{ java.util.Map.of() };
        r.timingMs("decrypt", timedMinMs(REPS, () -> {
            plainBox[0] = PerAUFile.decryptFile(decCopy.toString(), key, "hdf5");
        }));
        if (plainBox[0].isEmpty()) throw new IllegalStateException("decrypt empty");
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
        final byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;

        final byte[] fData = data;
        final String[] sigBox = {null};
        r.timingMs("sign", timedMinMs(REPS, () -> {
            sigBox[0] = SignatureManager.sign(fData, key);
        }));
        final String sig = sigBox[0];

        final boolean[] okBox = {false};
        r.timingMs("verify", timedMinMs(REPS, () -> {
            okBox[0] = SignatureManager.verify(fData, sig, key);
        }));
        if (!okBox[0]) throw new IllegalStateException("verify failed");
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
        final IRSpectrum ir = new IRSpectrum(wn, yAbs, 0, 0.0,
                IRMode.ABSORBANCE, 4.0, 32L);
        final Path jdxIr = tmp.resolve("ir.jdx");
        // writes overwrite the same path (truncate-safe); reads pure -> rep-safe.
        r.timingMs("ir_write", timedMinMs(REPS, () -> {
            try { JcampDxWriter.writeIRSpectrum(ir, jdxIr, "perf IR"); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.timingMs("ir_read", timedMinMs(REPS, () -> {
            try { JcampDxReader.readSpectrum(jdxIr); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));

        double[] wnR = new double[n];
        double[] yR = new double[n];
        for (int i = 0; i < n; i++) {
            wnR[i] = 100.0 + (3100.0 / (n - 1)) * i;
            double diff = wnR[i] - 1500.0;
            yR[i] = 10.0 + 100.0 * Math.exp(-diff * diff / (300.0 * 300.0));
        }
        final RamanSpectrum raman = new RamanSpectrum(wnR, yR, 0, 0.0,
                785.0, 20.0, 5.0);
        final Path jdxR = tmp.resolve("raman.jdx");
        r.timingMs("raman_write", timedMinMs(REPS, () -> {
            try { JcampDxWriter.writeRamanSpectrum(raman, jdxR, "perf Raman"); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.timingMs("raman_read", timedMinMs(REPS, () -> {
            try { JcampDxReader.readSpectrum(jdxR); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));

        double[] wl = new double[n];
        double[] abs = new double[n];
        for (int i = 0; i < n; i++) {
            wl[i] = 200.0 + (600.0 / (n - 1)) * i;
            double diff = wl[i] - 450.0;
            abs[i] = Math.exp(-diff * diff / (40.0 * 40.0));
        }
        final UVVisSpectrum uvvis = new UVVisSpectrum(wl, abs, 0, 0.0, 1.0, "methanol");
        final Path jdxU = tmp.resolve("uvvis.jdx");
        r.timingMs("uvvis_write", timedMinMs(REPS, () -> {
            try { JcampDxWriter.writeUVVisSpectrum(uvvis, jdxU, "perf UV-Vis"); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.timingMs("uvvis_read", timedMinMs(REPS, () -> {
            try { JcampDxReader.readSpectrum(jdxU); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));

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
        final Path jdxC = tmp.resolve("compressed.jdx");
        Files.writeString(jdxC, jdx);
        r.timingMs("compressed_read", timedMinMs(REPS, () -> {
            try { JcampDxReader.readSpectrum(jdxC); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));

        return r;
    }

    // ── Spectrum build-only (no I/O) ────────────────────────────────

    private static Result benchSpectra(int n) {
        Result r = new Result();
        final double[] wn = new double[n];
        final double[] y = new double[n];
        for (int i = 0; i < n; i++) {
            wn[i] = 4000.0 - i;
            y[i] = 0.5;
        }
        // pure constructors -> rep-safe.
        r.timingMs("ir_build", timedMinMs(REPS, () ->
            new IRSpectrum(wn, y, 0, 0.0, IRMode.ABSORBANCE, 4.0, 32L)));

        r.timingMs("raman_build", timedMinMs(REPS, () ->
            new RamanSpectrum(wn, y, 0, 0.0, 785.0, 20.0, 5.0)));

        r.timingMs("uvvis_build", timedMinMs(REPS, () ->
            new UVVisSpectrum(wn, y, 0, 0.0, 1.0, "methanol")));

        final int m = Math.max(8, (int) Math.sqrt(n));
        final double[] sync = new double[m * m];
        final double[] asyncM = new double[m * m];
        for (int i = 0; i < m * m; i++) { sync[i] = Math.cos(i); asyncM[i] = Math.sin(i); }
        r.timingMs("2dcos_build", timedMinMs(REPS, () ->
            new TwoDimensionalCorrelationSpectrum(
                sync, asyncM, m,
                new AxisDescriptor("wavenumber", "1/cm",
                        new ValueRange(400.0, 4000.0), SamplingMode.UNIFORM),
                "temperature", "K", "IR")));
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
        final byte[] ransIn = new byte[oneMiB];
        rng.nextBytes(ransIn);

        Result r = new Result();
        // All codec ops below are pure (no shared mutable state) -> rep-safe.

        final byte[][] o0Box = new byte[1][];
        r.timingMs("rans_o0_encode", timedMinMs(REPS, () ->
            o0Box[0] = global.thalion.ttio.codecs.Rans.encode(ransIn, 0)));
        final byte[] o0 = o0Box[0];
        r.timingMs("rans_o0_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.Rans.decode(o0)));

        final byte[][] o1Box = new byte[1][];
        r.timingMs("rans_o1_encode", timedMinMs(REPS, () ->
            o1Box[0] = global.thalion.ttio.codecs.Rans.encode(ransIn, 1)));
        final byte[] o1 = o1Box[0];
        r.timingMs("rans_o1_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.Rans.decode(o1)));

        // BASE_PACK on pure ACGT.
        byte[] alphabet = {(byte) 'A', (byte) 'C', (byte) 'G', (byte) 'T'};
        final byte[] bpIn = new byte[oneMiB];
        for (int i = 0; i < oneMiB; i++) bpIn[i] = alphabet[rng.nextInt(4)];
        final byte[][] bpBox = new byte[1][];
        r.timingMs("base_pack_encode", timedMinMs(REPS, () ->
            bpBox[0] = global.thalion.ttio.codecs.BasePack.encode(bpIn)));
        final byte[] bpEnc = bpBox[0];
        r.timingMs("base_pack_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.BasePack.decode(bpEnc)));

        // QUALITY_BINNED on random Phred bytes.
        final byte[] qbIn = new byte[oneMiB];
        for (int i = 0; i < oneMiB; i++) qbIn[i] = (byte) rng.nextInt(94);
        final byte[][] qbBox = new byte[1][];
        r.timingMs("quality_binned_encode", timedMinMs(REPS, () ->
            qbBox[0] = global.thalion.ttio.codecs.Quality.encode(qbIn)));
        final byte[] qbEnc = qbBox[0];
        r.timingMs("quality_binned_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.Quality.decode(qbEnc)));

        // NAME_TOKENIZED: 10K Illumina-style names.
        final java.util.List<String> names = new java.util.ArrayList<>(10_000);
        for (int i = 0; i < 10_000; i++) {
            names.add(String.format("M88_%08d:%03d:%02d",
                    i, rng.nextInt(1000), rng.nextInt(100)));
        }
        final byte[][] ntBox = new byte[1][];
        r.timingMs("name_tokenized_encode", timedMinMs(REPS, () ->
            ntBox[0] = global.thalion.ttio.codecs.NameTokenizerV2.encode(names)));
        final byte[] ntEnc = ntBox[0];
        r.timingMs("name_tokenized_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.NameTokenizerV2.decode(ntEnc)));

        return r;
    }

    private static Result benchCodecsGenomic(int n) {
        Result r = new Result();
        // All genomic codec ops below are pure -> rep-safe.

        // ── REF_DIFF: 100K reads × 100bp ──
        int refLen = 100_000;
        int readLen = 100;
        int nReadsRd = 100_000;
        java.util.Random rdRng = new java.util.Random(42);
        byte[] refSeq = new byte[refLen];
        byte[] alpha = {(byte) 'A', (byte) 'C', (byte) 'G', (byte) 'T'};
        for (int i = 0; i < refLen; i++) refSeq[i] = alpha[rdRng.nextInt(4)];
        byte[] refMd5;
        try {
            refMd5 = java.security.MessageDigest.getInstance("MD5").digest(refSeq);
        } catch (Exception e) { throw new RuntimeException(e); }

        java.util.List<byte[]> seqsRd = new java.util.ArrayList<>(nReadsRd);
        long[] positionsRd = new long[nReadsRd];
        // Generate sorted positions within reference range (matches Python).
        java.util.Random posRng = new java.util.Random(42);
        for (int i = 0; i < nReadsRd; i++) {
            positionsRd[i] = 1 + (long)(posRng.nextDouble() * (refLen - readLen - 1));
        }
        java.util.Arrays.sort(positionsRd);
        for (int i = 0; i < nReadsRd; i++) {
            int start = (int) (positionsRd[i] % (refLen - readLen));
            if (start < 0) start = 0;
            byte[] seq = java.util.Arrays.copyOfRange(refSeq, start, start + readLen);
            for (int j = 0; j < readLen; j++) {
                if (rdRng.nextDouble() < 0.02) seq[j] = alpha[rdRng.nextInt(4)];
            }
            seqsRd.add(seq);
        }
        java.util.List<String> cigarsRd = new java.util.ArrayList<>(nReadsRd);
        for (int i = 0; i < nReadsRd; i++) cigarsRd.add(readLen + "M");

        // REF_DIFF v2 wants a flat concatenated sequences buffer plus an
        // offsets table of n_reads + 1 cumulative read starts.
        long totalBasesRd = 0;
        for (byte[] seq : seqsRd) totalBasesRd += seq.length;
        byte[] seqsFlat = new byte[(int) totalBasesRd];
        long[] offsetsRd = new long[nReadsRd + 1];
        int flatPos = 0;
        for (int i = 0; i < nReadsRd; i++) {
            byte[] seq = seqsRd.get(i);
            System.arraycopy(seq, 0, seqsFlat, flatPos, seq.length);
            flatPos += seq.length;
            offsetsRd[i + 1] = flatPos;
        }
        final String[] cigarsArr = cigarsRd.toArray(new String[0]);
        final String refUri = "synthetic://perf-ref";
        final byte[] fSeqsFlat = seqsFlat;
        final long[] fOffsetsRd = offsetsRd;
        final long[] fPositionsRd = positionsRd;
        final byte[] fRefSeq = refSeq;
        final byte[] fRefMd5 = refMd5;
        final int fNReadsRd = nReadsRd;
        final long fTotalBasesRd = totalBasesRd;

        final byte[][] rdBox = new byte[1][];
        r.timingMs("ref_diff_encode", timedMinMs(REPS, () ->
            rdBox[0] = global.thalion.ttio.codecs.RefDiffV2.encode(
                fSeqsFlat, fOffsetsRd, fPositionsRd, cigarsArr,
                fRefSeq, fRefMd5, refUri, 10_000)));
        final byte[] rdEnc = rdBox[0];
        r.timingMs("ref_diff_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.RefDiffV2.decode(
                rdEnc, fPositionsRd, cigarsArr, fRefSeq, fNReadsRd, fTotalBasesRd)));

        // ── Quality test data: 100K × 100bp quality strings ──
        int nQual = 100_000 * 100;
        byte[] quals = new byte[nQual];
        long qs = 0xBEEFL;
        for (int i = 0; i < nQual; i++) {
            qs = (qs * 6364136223846793005L + 1442695040888963407L);
            quals[i] = (byte) (33 + 20 + (int) (((qs >>> 32) & 0xFFFFFFFFL) % 21));
        }
        final int[] readLengths = new int[100_000];
        java.util.Arrays.fill(readLengths, 100);
        final byte[] fQuals = quals;

        // ── FQZCOMP_NX16_Z: same qualities, with revcomp flags ──
        final int[] revcompZ = new int[100_000];
        for (int i = 0; i < 100_000; i++) revcompZ[i] = ((i & 7) == 0) ? 1 : 0;

        final byte[][] fqzBox = new byte[1][];
        r.timingMs("fqzcomp_nx16_z_encode", timedMinMs(REPS, () ->
            fqzBox[0] = global.thalion.ttio.codecs.FqzcompNx16Z.encode(
                fQuals, readLengths, revcompZ)));
        final byte[] fqzZEnc = fqzBox[0];
        r.timingMs("fqzcomp_nx16_z_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.FqzcompNx16Z.decode(fqzZEnc, revcompZ)));

        // ── DELTA_RANS: 1.25M sorted int64 positions ──
        int nPos = 1_250_000;
        ByteBuffer bb = ByteBuffer.allocate(nPos * 8).order(ByteOrder.LITTLE_ENDIAN);
        long dpos = 1000;
        long ds = 0xBEEFL;
        for (int i = 0; i < nPos; i++) {
            bb.putLong(dpos);
            ds = (ds * 6364136223846793005L + 1442695040888963407L);
            long dd = 100 + (((ds >>> 32) & 0xFFFFFFFFL) % 401);
            dpos += dd;
        }
        final byte[] drInput = bb.array();

        final byte[][] drBox = new byte[1][];
        r.timingMs("delta_rans_encode", timedMinMs(REPS, () ->
            drBox[0] = global.thalion.ttio.codecs.DeltaRans.encode(drInput, 8)));
        final byte[] drEnc = drBox[0];
        r.timingMs("delta_rans_decode", timedMinMs(REPS, () ->
            global.thalion.ttio.codecs.DeltaRans.decode(drEnc)));

        return r;
    }

    // -- B2/B3/B4: Genomic pipeline: write, read, random access

    private static WrittenGenomicRun makeGenomicRun() {
        java.util.Random rng = new java.util.Random(42);
        int n = 100_000;
        int rl = 100;
        char[] bases = {'A', 'C', 'G', 'T'};
        long[] positions = new long[n];
        long pos = 1_000;
        long lcg = 0xBEEFL;
        for (int i = 0; i < n; i++) {
            positions[i] = pos;
            lcg = lcg * 6364136223846793005L + 1442695040888963407L;
            long delta = 100 + (((lcg >>> 32) & 0xFFFFFFFFL) % 401);
            pos += delta;
        }
        Arrays.sort(positions);
        int[] flagValues = {0, 16, 83, 99, 163};
        int[] flags = new int[n];
        for (int i = 0; i < n; i++) flags[i] = flagValues[i % flagValues.length];
        byte[] mapqs = new byte[n];
        for (int i = 0; i < n; i++) mapqs[i] = (byte)(i % 61);
        byte[] sequences = new byte[n * rl];
        for (int i = 0; i < n * rl; i++) sequences[i] = (byte) bases[i % 4];
        for (int i = 0; i < n * rl; i++) {
            if (rng.nextDouble() < 0.02) sequences[i] = (byte) bases[rng.nextInt(4)];
        }
        byte[] qualities = new byte[n * rl];
        long qlcg = 0xBEEFL;
        for (int i = 0; i < n * rl; i++) {
            qlcg = qlcg * 6364136223846793005L + 1442695040888963407L;
            qualities[i] = (byte)(20 + (int)(((qlcg >>> 32) & 0xFFFFFFFFL) % 21));
        }
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        List<String> cigars = new java.util.ArrayList<>(n);
        List<String> readNames = new java.util.ArrayList<>(n);
        List<String> mateChroms = new java.util.ArrayList<>(n);
        long[] matePos = new long[n];
        int[] tlens = new int[n];
        List<String> chroms = new java.util.ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * rl;
            lengths[i] = rl;
            cigars.add(rl + "M");
            readNames.add(String.format("M88_%08d:001:01", i));
            chroms.add("chr1");
            mateChroms.add("chr1");
            matePos[i] = positions[i] + 200L;
            tlens[i] = 200;
        }
        return new WrittenGenomicRun(
            AcquisitionMode.GENOMIC_WGS,
            "GRCh38.p14", "ILLUMINA", "NA12878",
            positions, mapqs, flags, sequences, qualities,
            offsets, lengths, cigars, readNames, mateChroms,
            matePos, tlens, chroms, Compression.ZLIB);
    }

    private static Result benchGenomic(Path tmp) throws Exception {
        Result r = new Result();
        final Path tio = tmp.resolve("genomic.tio");
        final int n = 100_000;
        final WrittenGenomicRun gr = makeGenomicRun();
        // write: HDF5 create truncates each rep; dataset closed -> rep-safe.
        r.timingMs("write", timedMinMs(REPS, () -> {
            try (SpectralDataset ds = SpectralDataset.create(
                    tio.toString(), "perf-genomic", "ISA-GENOMIC-PERF",
                    List.of(), List.of(gr),
                    List.of(), List.of(), List.of(),
                    FeatureFlags.defaultCurrent())) {
                // written on close
            } catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.size("write_mb", Files.size(tio));
        // read: open + sequential readAt, closed each rep -> rep-safe.
        r.timingMs("read", timedMinMs(REPS, () -> {
            try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
                GenomicRun run = ds.genomicRuns().get("genomic_0001");
                for (int i = 0; i < n; i++) {
                    run.readAt(i);
                }
            } catch (Exception e) { throw new RuntimeException(e); }
        }));
        java.util.Random raRng = new java.util.Random(99);
        int nRa = 1000;
        long[] latencies = new long[nRa];
        try (SpectralDataset ds = SpectralDataset.open(tio.toString())) {
            GenomicRun run = ds.genomicRuns().get("genomic_0001");
            for (int i = 0; i < nRa; i++) {
                int idx = raRng.nextInt(n);
                long t0 = System.nanoTime();
                run.readAt(idx);
                latencies[i] = System.nanoTime() - t0;
            }
        }
        Arrays.sort(latencies);
        r.timing("random_access_p50", latencies[nRa / 2]);
        r.timing("random_access_p99", latencies[(int)(nRa * 0.99)]);
        return r;
    }

    // -- B5: AES-256-GCM encrypt/decrypt on 64 MiB payload

    private static Result benchEncryptionGenomic() {
        Result r = new Result();
        // 64 MiB (P1d): keeps the op well above the 5ms jitter floor so the
        // min-of-N timing is stable (10 MiB was a sub-20ms op that swung
        // +/-25-85% run-to-run).
        final int sixtyFourMiB = 64 * 1024 * 1024;
        final byte[] plaintext = new byte[sixtyFourMiB];
        new java.util.Random(42).nextBytes(plaintext);
        final byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;
        // pure AES-GCM encrypt/decrypt (no shared state) -> rep-safe.
        // NOTE: EncryptionManager.encrypt/decrypt call Cipher.getInstance
        // internally (product code), so the provider-lookup cost is inside
        // the timed window. We cannot hoist it without editing product code,
        // which is out of scope for the perf harness; at 64 MiB the
        // getInstance overhead is a negligible fraction of the doFinal cost.
        final EncryptionManager.EncryptResult[] erBox =
                new EncryptionManager.EncryptResult[1];
        r.timingMs("encrypt", timedMinMs(REPS, () ->
            erBox[0] = EncryptionManager.encrypt(plaintext, key)));
        final EncryptionManager.EncryptResult er = erBox[0];
        final byte[][] decBox = new byte[1][];
        r.timingMs("decrypt", timedMinMs(REPS, () ->
            decBox[0] = EncryptionManager.decrypt(
                er.ciphertext(), er.iv(), er.tag(), key)));
        if (decBox[0].length != sixtyFourMiB) throw new IllegalStateException("decrypt length mismatch");
        r.size("bytes_mb", sixtyFourMiB);
        return r;
    }

    // -- B6: StreamWriter/StreamReader throughput

    private static Result benchStreaming(Path tmp) throws Exception {
        Result r = new Result();
        final Path tio = tmp.resolve("stream.tio");
        final int nSpectra = 1_000;
        final int peaksPerSpectrum = 100;
        final InstrumentConfig ic = new InstrumentConfig("", "", "", "", "", "");
        // write: StreamWriter create truncates the .tio each rep; closed via
        // flushAndClose + try-with-resources -> rep-safe.
        r.timingMs("write", timedMinMs(REPS, () -> {
            try (StreamWriter sw = new StreamWriter(
                    tio.toString(), "stream_run",
                    AcquisitionMode.MS1_DDA, ic)) {
                for (int i = 0; i < nSpectra; i++) {
                    double[] mz = new double[peaksPerSpectrum];
                    double[] intensity = new double[peaksPerSpectrum];
                    for (int j = 0; j < peaksPerSpectrum; j++) {
                        mz[j] = 100.0 + i + j * 0.5;
                        intensity[j] = 1000.0 + ((i * 31 + j) % 1000);
                    }
                    sw.appendSpectrum(new MassSpectrum(
                        mz, intensity, i, i * 0.06,
                        0.0, 0, 1, Polarity.POSITIVE, null));
                }
                sw.flushAndClose();
            } catch (Exception e) { throw new RuntimeException(e); }
        }));
        // read: StreamReader open + drain, closed each rep -> rep-safe.
        r.timingMs("read", timedMinMs(REPS, () -> {
            try (StreamReader sr = new StreamReader(tio.toString(), "stream_run")) {
                while (!sr.atEnd()) {
                    sr.nextSpectrum();
                }
            } catch (Exception e) { throw new RuntimeException(e); }
        }));
        return r;
    }

    // -- P1c: real-format import benches (read committed fixtures)

    /**
     * Locate the repo root by walking up from the working directory until
     * {@code objc/Tests/Fixtures} is found. The harness may be launched
     * from the perf scratch dir or the repo root, so we probe rather than
     * assume a fixed relative depth.
     */
    private static Path fixturesDir() {
        Path p = Paths.get("").toAbsolutePath();
        for (int i = 0; i < 8 && p != null; i++) {
            Path cand = p.resolve("objc").resolve("Tests").resolve("Fixtures");
            if (Files.isDirectory(cand)) return cand;
            p = p.getParent();
        }
        throw new IllegalStateException(
            "could not locate objc/Tests/Fixtures from "
            + Paths.get("").toAbsolutePath());
    }

    /**
     * Read committed vendor fixtures through the public importer API.
     * Java's BAM path uses htsjdk (no external samtools dependency), so
     * import.bam always produces a number. Fixtures are fixed-size (do not
     * scale with --n); the heavy decoders are import.mzml_1min and
     * import.nmrml. All reads are pure -> rep-safe under timedMinMs.
     */
    private static Result benchImport() {
        Result r = new Result();
        Path fx = fixturesDir();
        final Path bam = fx.resolve("genomic").resolve("m87_test.bam");
        final String mzmlTiny = fx.resolve("tiny.pwiz.1.1.mzML").toString();
        final String mzml1min = fx.resolve("1min.mzML").toString();
        final String nmrml = fx.resolve("bmse000325.nmrML").toString();

        r.timingMs("bam", timedMinMs(REPS, () -> {
            try { new BamReader(bam).toGenomicRun("r"); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.timingMs("mzml_tiny", timedMinMs(REPS, () -> {
            try { MzMLReader.read(mzmlTiny); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.timingMs("mzml_1min", timedMinMs(REPS, () -> {
            try { MzMLReader.read(mzml1min); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        r.timingMs("nmrml", timedMinMs(REPS, () -> {
            try { NmrMLReader.read(nmrml); }
            catch (Exception e) { throw new RuntimeException(e); }
        }));
        return r;
    }

    // ── Driver ──────────────────────────────────────────────────────

    private static final String[] BENCH_ORDER = {
        "ms.hdf5", "ms.memory", "ms.sqlite", "ms.zarr",
        "transport.plain", "transport.compressed",
        "encryption", "signatures", "jcamp", "spectra.build",
        "codecs",
        "codecs.genomic",
        "genomic",
        "encryption.genomic",
        "streaming",
        "import",
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
            case "codecs.genomic": return benchCodecsGenomic(n);
            case "genomic":            return benchGenomic(tmp);
            case "encryption.genomic": return benchEncryptionGenomic();
            case "streaming":          return benchStreaming(tmp);
            case "import":             return benchImport();
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
                case "--reps":  REPS = Integer.parseInt(args[++i]); break;
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
        System.out.printf("Java multi-function perf  n=%d  peaks=%d  reps=%d%n",
                n, peaks, REPS);
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
