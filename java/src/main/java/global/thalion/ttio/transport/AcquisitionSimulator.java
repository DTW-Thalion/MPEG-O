/*
 * TTI-O Java Implementation — v0.10 M69.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Enums;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * Synthetic LC-MS acquisition simulator.
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.transport.simulator.AcquisitionSimulator}, ObjC
 * {@code TTIOAcquisitionSimulator}.</p>
 *
 * <p>The output packet sequence (StreamHeader, DatasetHeader, N
 * AccessUnits, EndOfDataset, EndOfStream) is deterministic under
 * a fixed seed, but byte-identity across languages is NOT a goal —
 * each language's RNG differs. Use this for reproducibility within
 * a single language, not for cross-language fixture generation.</p>
 */
public final class AcquisitionSimulator {

    public static final String RUN_NAME = "simulated_run";
    public static final int DATASET_ID = 1;
    public static final String FORMAT_VERSION = "1.2";
    public static final String TITLE = "Simulated acquisition";
    public static final String ISA_INVESTIGATION_ID = "ISA-SIMULATOR";
    public static final String INSTRUMENT_JSON =
            "{\"analyzer_type\": \"\", \"detector_type\": \"\", "
          + "\"manufacturer\": \"TTI-O simulator\", \"model\": \"synthetic-v1\", "
          + "\"serial_number\": \"\", \"source_type\": \"\"}";

    private final double scanRate;
    private final double duration;
    private final double ms1Fraction;
    private final double mzMin;
    private final double mzMax;
    private final int nPeaks;
    private final long seed;

    public AcquisitionSimulator(double scanRate, double duration, double ms1Fraction,
                                 double mzMin, double mzMax, int nPeaks, long seed) {
        this.scanRate = scanRate;
        this.duration = duration;
        this.ms1Fraction = ms1Fraction;
        this.mzMin = mzMin;
        this.mzMax = mzMax;
        this.nPeaks = nPeaks;
        this.seed = seed;
    }

    /** Convenience constructor with scan_rate=10, duration=10s, ms1_fraction=0.3, defaults. */
    public static AcquisitionSimulator withDefaults(long seed) {
        return new AcquisitionSimulator(10.0, 10.0, 0.3, 100.0, 2000.0, 200, seed);
    }

    public int scanCount() {
        return Math.max(1, (int) (scanRate * duration));
    }

    public double scanInterval() { return 1.0 / scanRate; }

    // ---------------------------------------------------------- sync

    /** Emit every packet to {@code writer} with no wall-clock pacing. */
    public int streamToWriter(TransportWriter writer) throws IOException {
        Random rng = new Random(seed);
        writer.writeStreamHeader(FORMAT_VERSION, TITLE, ISA_INVESTIGATION_ID,
                List.of("base_v1"), 1);
        int count = scanCount();
        writer.writeDatasetHeader(DATASET_ID, RUN_NAME,
                Enums.AcquisitionMode.MS1_DDA.ordinal(),
                "TTIOMassSpectrum",
                List.of("mz", "intensity"),
                INSTRUMENT_JSON, count);
        double lastMs1Peak = 0.0;
        for (int i = 0; i < count; i++) {
            AUGenResult r = generateAu(rng, i, lastMs1Peak);
            writer.writeAccessUnit(DATASET_ID, i, r.au);
            lastMs1Peak = r.lastMs1Peak;
        }
        writer.writeEndOfDataset(DATASET_ID, count);
        writer.writeEndOfStream();
        return count;
    }

    // ---------------------------------------------------------- async

    /** Emit packets at {@code scanRate} Hz in wall-clock time.
     * Blocks on {@code Thread.sleep} between scans. Returns the
     * total AU count. */
    public int streamPaced(TransportWriter writer) throws IOException, InterruptedException {
        Random rng = new Random(seed);
        writer.writeStreamHeader(FORMAT_VERSION, TITLE, ISA_INVESTIGATION_ID,
                List.of("base_v1"), 1);
        int count = scanCount();
        writer.writeDatasetHeader(DATASET_ID, RUN_NAME,
                Enums.AcquisitionMode.MS1_DDA.ordinal(),
                "TTIOMassSpectrum",
                List.of("mz", "intensity"),
                INSTRUMENT_JSON, 0);  // 0 = real-time
        long start = System.nanoTime();
        long intervalNs = (long) (scanInterval() * 1_000_000_000.0);
        double lastMs1Peak = 0.0;
        for (int i = 0; i < count; i++) {
            AUGenResult r = generateAu(rng, i, lastMs1Peak);
            writer.writeAccessUnit(DATASET_ID, i, r.au);
            lastMs1Peak = r.lastMs1Peak;
            long target = start + (long) (i + 1) * intervalNs;
            long delay = target - System.nanoTime();
            if (delay > 0) Thread.sleep(delay / 1_000_000L, (int) (delay % 1_000_000L));
        }
        writer.writeEndOfDataset(DATASET_ID, count);
        writer.writeEndOfStream();
        return count;
    }

    // ---------------------------------------------------------- internals

    private static final class AUGenResult {
        final AccessUnit au;
        final double lastMs1Peak;
        AUGenResult(AccessUnit au, double lastMs1Peak) {
            this.au = au; this.lastMs1Peak = lastMs1Peak;
        }
    }

    private AUGenResult generateAu(Random rng, int i, double lastMs1Peak) {
        double rt = i * scanInterval();
        boolean isMs1 = rng.nextDouble() < ms1Fraction;
        int msLevel = isMs1 ? 1 : 2;

        int jitter = rng.nextInt(Math.max(1, nPeaks / 2 + 1)) - nPeaks / 4;
        int n = Math.max(1, nPeaks + jitter);

        double[] mzs = new double[n];
        double[] intensities = new double[n];
        for (int k = 0; k < n; k++) mzs[k] = uniform(rng, mzMin, mzMax);
        java.util.Arrays.sort(mzs);
        for (int k = 0; k < n; k++) intensities[k] = uniform(rng, 10.0, 1.0e6);

        double basePeakIntensity = 0.0;
        int basePeakIndex = 0;
        for (int k = 0; k < n; k++) {
            if (intensities[k] > basePeakIntensity) {
                basePeakIntensity = intensities[k];
                basePeakIndex = k;
            }
        }

        double precursorMz;
        int precursorCharge;
        double newLastMs1 = lastMs1Peak;
        if (isMs1) {
            newLastMs1 = mzs[basePeakIndex];
            precursorMz = 0.0;
            precursorCharge = 0;
        } else {
            precursorMz = lastMs1Peak > 0 ? lastMs1Peak : uniform(rng, mzMin, mzMax);
            precursorCharge = rng.nextBoolean() ? 2 : 3;
        }

        byte[] mzBytes = packF64(mzs);
        byte[] intBytes = packF64(intensities);

        List<ChannelData> channels = new ArrayList<>(2);
        channels.add(new ChannelData("mz",
                Enums.Precision.FLOAT64.ordinal(),
                Enums.Compression.NONE.ordinal(),
                n, mzBytes));
        channels.add(new ChannelData("intensity",
                Enums.Precision.FLOAT64.ordinal(),
                Enums.Compression.NONE.ordinal(),
                n, intBytes));

        AccessUnit au = new AccessUnit(
                0,  // MassSpectrum wire
                Enums.AcquisitionMode.MS1_DDA.ordinal(),
                msLevel,
                0,  // wire POSITIVE
                rt, precursorMz, precursorCharge, 0.0,
                basePeakIntensity,
                channels,
                0, 0, 0);
        return new AUGenResult(au, newLastMs1);
    }

    private static double uniform(Random rng, double lo, double hi) {
        return lo + rng.nextDouble() * (hi - lo);
    }

    private static byte[] packF64(double[] arr) {
        ByteBuffer buf = ByteBuffer.allocate(arr.length * 8).order(ByteOrder.LITTLE_ENDIAN);
        for (double v : arr) buf.putDouble(v);
        return buf.array();
    }
}
