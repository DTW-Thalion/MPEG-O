package global.thalion.ttio;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * C2c — value-class + small-class coverage gaps.
 *
 * <p>Targets:</p>
 * <ul>
 *   <li>{@link StreamReader} — was 0% (16 lines)</li>
 *   <li>{@link TransitionList} — was 29% (17 lines)</li>
 *   <li>{@link NMR2DSpectrum} — was 65% (17 lines)</li>
 *   <li>{@link SignalArray} — was 65% (43 lines)</li>
 * </ul>
 *
 * <p>Per docs/coverage-workplan.md (C-series leftover gaps).</p>
 */
public class C2cValueClassesGapsTest {

    /** Build the standard MS fixture used by the other C-series tests. */
    private Path buildFixture(Path dir) {
        String path = dir.resolve("c2c.tio").toString();
        int nSpectra = 3;
        double[] mz = { 100, 101, 102, 103, 200, 201, 202, 203, 300, 301, 302, 303 };
        double[] intensity = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 };
        long[] offsets = { 0, 4, 8 };
        int[] lengths = { 4, 4, 4 };
        double[] rts = { 1.0, 2.0, 3.0 };
        int[] msLevels = { 1, 2, 1 };
        int[] pols = { 1, 1, 1 };
        double[] pmzs = { 0, 500, 0 };
        int[] pcs = { 0, 2, 0 };
        double[] bpis = { 40, 80, 120 };

        SpectrumIndex idx = new SpectrumIndex(nSpectra, offsets, lengths,
            rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        AcquisitionRun run = new AcquisitionRun(
            "run_0001",
            Enums.AcquisitionMode.MS1_DDA,
            idx,
            new InstrumentConfig("","","","","",""),
            channels, List.of(), List.of(), null, 0.0);

        try (SpectralDataset ds = SpectralDataset.create(path,
                "C2c fixture", "ISA-C2C",
                List.of(run), List.of(), List.of(), List.of())) {
        }
        return Path.of(path);
    }

    // ── StreamReader ───────────────────────────────────────────────────

    @Test
    @DisplayName("C2c #1: StreamReader sequential read + reset")
    void streamReaderRoundTrip(@TempDir Path tmp) {
        Path src = buildFixture(tmp);
        try (StreamReader sr = new StreamReader(src.toString(), "run_0001")) {
            assertEquals(3, sr.totalCount(), "fixture has 3 spectra");
            assertEquals(0, sr.currentPosition());
            assertFalse(sr.atEnd());
            Spectrum s1 = sr.nextSpectrum();
            assertNotNull(s1);
            Spectrum s2 = sr.nextSpectrum();
            assertNotNull(s2);
            Spectrum s3 = sr.nextSpectrum();
            assertNotNull(s3);
            assertTrue(sr.atEnd(), "after 3 reads should be atEnd");
            sr.reset();
            assertEquals(0, sr.currentPosition(),
                "reset should reset position to 0");
            assertFalse(sr.atEnd());
        }
    }

    @Test
    @DisplayName("C2c #2: StreamReader can be closed twice without crashing")
    void streamReaderDoubleClose(@TempDir Path tmp) {
        Path src = buildFixture(tmp);
        StreamReader sr = new StreamReader(src.toString(), "run_0001");
        sr.close();
        // Second close — close() guards against double-close internally.
        assertDoesNotThrow(sr::close);
    }

    // ── TransitionList ────────────────────────────────────────────────

    @Test
    @DisplayName("C2c #3: TransitionList round-trip with empty + populated lists")
    void transitionListBasic() {
        // Empty list is allowed by the canonicalising constructor.
        TransitionList empty = new TransitionList(List.of());
        assertEquals(0, empty.count());
        // Null promotes to empty list (covers the null-check branch).
        TransitionList fromNull = new TransitionList(null);
        assertEquals(0, fromNull.count());

        TransitionList.Transition t1 =
            new TransitionList.Transition(500.0, 200.0, 25.0, null);
        TransitionList.Transition t2 =
            new TransitionList.Transition(700.0, 350.0, 30.0,
                new ValueRange(1.5, 2.5));
        TransitionList tl = new TransitionList(List.of(t1, t2));
        assertEquals(2, tl.count());
        assertEquals(t1, tl.transitionAtIndex(0));
        assertEquals(t2, tl.transitionAtIndex(1));
        assertEquals(500.0, t1.precursorMz());
        assertEquals(200.0, t1.productMz());
        assertEquals(25.0, t1.collisionEnergy());
        assertNull(t1.retentionTimeWindow());
        assertNotNull(t2.retentionTimeWindow());
    }

    @Test
    @DisplayName("C2c #4: TransitionList.toJson produces well-formed JSON for both shapes")
    void transitionListJson() {
        TransitionList empty = new TransitionList(List.of());
        String emptyJson = empty.toJson();
        assertTrue(emptyJson.startsWith("[") && emptyJson.endsWith("]"));

        TransitionList tl = new TransitionList(List.of(
            new TransitionList.Transition(500.0, 200.0, 25.0, null),
            new TransitionList.Transition(700.0, 350.0, 30.0,
                new ValueRange(1.5, 2.5))));
        String json = tl.toJson();
        assertTrue(json.contains("500"), "JSON should mention precursor 500");
        assertTrue(json.contains("700"), "JSON should mention precursor 700");
        assertTrue(json.startsWith("[") && json.endsWith("]"));
    }

    // ── NMR2DSpectrum ─────────────────────────────────────────────────

    @Test
    @DisplayName("C2c #5: NMR2DSpectrum stores matrix + axes + valueAt grid lookup")
    void nmr2DSpectrumBasic() {
        // 3×4 matrix (height=3, width=4). row-major: 12 values.
        double[] m = { 1, 2, 3, 4,
                       5, 6, 7, 8,
                       9, 10, 11, 12 };
        AxisDescriptor f1 = new AxisDescriptor("F1", "ppm",
            null, Enums.SamplingMode.UNIFORM);
        AxisDescriptor f2 = new AxisDescriptor("F2", "ppm",
            null, Enums.SamplingMode.UNIFORM);
        NMR2DSpectrum spec = new NMR2DSpectrum(m, 4, 3, f1, f2, "1H", "13C");
        assertEquals(4, spec.width());
        assertEquals(3, spec.height());
        assertEquals(f1, spec.f1Axis());
        assertEquals(f2, spec.f2Axis());
        assertEquals("1H", spec.nucleusF1());
        assertEquals("13C", spec.nucleusF2());
        assertSame(m, spec.intensityMatrix());

        // valueAt(row, col): row*width + col layout.
        assertEquals(1.0, spec.valueAt(0, 0));
        assertEquals(4.0, spec.valueAt(0, 3));
        assertEquals(5.0, spec.valueAt(1, 0));
        assertEquals(12.0, spec.valueAt(2, 3));
    }

    // ── SignalArray ───────────────────────────────────────────────────

    @Test
    @DisplayName("C2c #6: SignalArray.ofDoubles + asDoubles round-trip")
    void signalArrayDoublesRoundTrip() {
        double[] mz = { 100.0, 200.0, 300.0 };
        SignalArray arr = SignalArray.ofDoubles(mz);
        assertEquals(3, arr.length());
        assertNotNull(arr.encoding());
        // asDoubles round-trips.
        double[] back = arr.asDoubles();
        assertArrayEquals(mz, back, 1e-12);
    }

    @Test
    @DisplayName("C2c #7: SignalArray.ofFloats + asFloats round-trip")
    void signalArrayFloatsRoundTrip() {
        float[] data = { 1.5f, 2.5f, 3.5f };
        SignalArray arr = SignalArray.ofFloats(data);
        assertEquals(3, arr.length());
        float[] back = arr.asFloats();
        assertArrayEquals(data, back, 1e-6f);
    }

    @Test
    @DisplayName("C2c #8: SignalArray cvParams add/remove + getter")
    void signalArrayCvParams() {
        SignalArray arr = SignalArray.ofDoubles(new double[]{1.0, 2.0});
        assertNotNull(arr.cvParams());
        assertTrue(arr.cvParams().isEmpty(),
            "fresh SignalArray should have no CV params");
        CVParam p = new CVParam("MS", "MS:1000523",
            "64-bit float", "", "");
        arr.addCvParam(p);
        assertEquals(1, arr.cvParams().size());
        arr.removeCvParam(p);
        assertEquals(0, arr.cvParams().size());
    }

    @Test
    @DisplayName("C2c #9: SignalArray full constructor produces valid object")
    void signalArrayFullConstructor() {
        double[] data = { 1.0, 2.0, 3.0 };
        AxisDescriptor axis = new AxisDescriptor("m/z", "Th",
            null, Enums.SamplingMode.UNIFORM);
        EncodingSpec enc = new EncodingSpec(
            Enums.Precision.FLOAT64, Enums.Compression.NONE,
            Enums.ByteOrder.LITTLE_ENDIAN);
        SignalArray arr = new SignalArray(data, 3, enc, axis, null);
        assertEquals(3, arr.length());
        assertEquals(axis, arr.axis());
        assertEquals(enc, arr.encoding());
        assertNotNull(arr.cvParams());  // null promotes to empty list
        assertSame(data, arr.buffer());
    }
}
