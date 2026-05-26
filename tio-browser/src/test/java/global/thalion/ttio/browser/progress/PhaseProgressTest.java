package global.thalion.ttio.browser.progress;

import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage E tests: two-phase progress wrapper. Reader callbacks
 * scale to 0..50%; writer callbacks scale to 50..100%; the phase
 * label flips from {@code "reading"} to the configured write label
 * at the boundary; percent is strictly monotonic.
 */
class PhaseProgressTest {

    private static final long T0 = 1_000_000L;

    private static List<ProgressReport> capture(
            java.util.function.Function<ProgressListener, ProgressSink[]>
                attach) {
        List<ProgressReport> got = new ArrayList<>();
        ProgressListener listener = got::add;
        ProgressSink[] sinks = attach.apply(listener);
        // unused -- the lambda already wired through
        assertNotNull(sinks);
        return got;
    }

    @Test
    void readerPhaseScalesToBottomHalf() {
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        ProgressSink reader = pp.readerSink();
        reader.onProgress(25L, 100L);    // 25% of read half -> 12.5% overall
        reader.onProgress(50L, 100L);    // 50% of read half -> 25% overall
        reader.onProgress(75L, 100L);    // 75% of read half -> 37.5% overall

        assertEquals(3, got.size());
        assertEquals(0.125, got.get(0).percent(), 0.001);
        assertEquals(0.25,  got.get(1).percent(), 0.001);
        assertEquals(0.375, got.get(2).percent(), 0.001);
        for (ProgressReport r : got) {
            assertEquals("reading", r.phase());
            assertTrue(r.percent() <= 0.5,
                "reader phase must not exceed 50%, got " + r.percent());
        }
    }

    @Test
    void readerTerminalSampleAdvancesToFiftyPercentAndFlipsPhase() {
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        ProgressSink reader = pp.readerSink();
        reader.onProgress(50L, 100L);
        reader.onProgress(100L, 100L);    // terminal -> 50% + phase flip

        assertEquals(2, got.size());
        assertEquals(0.5, got.get(1).percent(), 0.001,
            "reader terminal sample renders at exactly 50%");
        assertEquals("encoding", got.get(1).phase(),
            "phase label flips to writer's at read-end");
        assertTrue(pp.writeStarted(),
            "writeStarted flag is set after reader's terminal sample");
    }

    @Test
    void writerPhaseScalesToTopHalf() {
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        // skip the reader phase entirely (some formats have no reader-
        // side instrumentation); the writer's first sample flips
        // phase by itself.
        ProgressSink writer = pp.writerSink();
        writer.onProgress(2L, 8L);     // 25% of write half -> 62.5% overall
        writer.onProgress(4L, 8L);     // 50% of write half -> 75% overall
        writer.onProgress(8L, 8L);     // 100% of write half -> 100% overall

        assertEquals(3, got.size());
        assertEquals(0.625, got.get(0).percent(), 0.001);
        assertEquals(0.75,  got.get(1).percent(), 0.001);
        assertEquals(1.0,   got.get(2).percent(), 0.001);
        for (ProgressReport r : got) {
            assertEquals("encoding", r.phase(),
                "writer phase label is the configured write label");
            assertTrue(r.percent() >= 0.5,
                "writer phase must stay at or above 50%, got " + r.percent());
        }
    }

    @Test
    void fullPipelineProducesStrictlyMonotonicPercent() {
        // End-to-end: reader fires 25%, 50%, 75%, 100% then writer
        // fires 25%, 50%, 75%, 100% of its half. Assert percent is
        // strictly non-decreasing across the whole sequence.
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        ProgressSink reader = pp.readerSink();
        ProgressSink writer = pp.writerSink();

        reader.onProgress(25L, 100L);
        reader.onProgress(50L, 100L);
        reader.onProgress(75L, 100L);
        reader.onProgress(100L, 100L);
        writer.onProgress(2L, 8L);
        writer.onProgress(4L, 8L);
        writer.onProgress(6L, 8L);
        writer.onProgress(8L, 8L);

        double prev = -1.0;
        for (ProgressReport r : got) {
            assertTrue(r.percent() >= prev,
                "percent regressed: " + prev + " -> " + r.percent());
            prev = r.percent();
        }
        assertEquals(1.0, got.get(got.size() - 1).percent(), 0.001,
            "final sample renders at 100%");
    }

    @Test
    void unitsChannelReflectsCurrentPhaseRecords() {
        // The numeric line should show the current phase's records
        // count, not the synthesised abstract scale. Reader fires
        // (25/100 reads); writer fires (3/8 sections).
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        pp.readerSink().onProgress(25L, 100L);
        ProgressReport readerReport = got.get(got.size() - 1);
        assertEquals(25L, readerReport.unitsDone());
        assertEquals(100L, readerReport.unitsTotal());

        pp.writerSink().onProgress(3L, 8L);
        ProgressReport writerReport = got.get(got.size() - 1);
        assertEquals(3L, writerReport.unitsDone(),
            "after phase flip the units channel reflects writer's records");
        assertEquals(8L, writerReport.unitsTotal());
    }

    @Test
    void lateReaderSampleAfterWriterStartsIsIgnored() {
        // Some readers fire a heartbeat after the writer has begun
        // (e.g. async event-loop). Guard percent monotonicity by
        // dropping late reader emits.
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        pp.writerSink().onProgress(4L, 8L);     // -> 75% overall
        int before = got.size();
        pp.readerSink().onProgress(50L, 100L); // would regress to 25%
        assertEquals(before, got.size(),
            "late reader emit after writer started must be dropped");
        assertEquals(0.75, got.get(got.size() - 1).percent(), 0.001);
    }

    @Test
    void emitFinalAlwaysReachesOneHundredPercent() {
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        // No samples emitted -- final still drives the bar to 100%.
        pp.emitFinal();
        assertEquals(1.0, got.get(got.size() - 1).percent(), 0.001);
        assertEquals("encoding", got.get(got.size() - 1).phase(),
            "emitFinal flips phase even without any prior samples");
    }

    @Test
    void emitInitialFiresZeroPercentSampleWithReaderPhase() {
        List<ProgressReport> got = new ArrayList<>();
        PhaseProgress pp = new PhaseProgress(
            got::add, "reading", "encoding", T0);
        pp.emitInitial();
        assertEquals(1, got.size());
        assertEquals(0.0, got.get(0).percent(), 0.001);
        assertEquals("reading", got.get(0).phase());
    }

    @Test
    void nullListenerIsHandledGracefully() {
        // Don't NPE when no listener attached.
        PhaseProgress pp = new PhaseProgress(
            null, "reading", "encoding", T0);
        pp.emitInitial();
        pp.readerSink().onProgress(50L, 100L);
        pp.writerSink().onProgress(4L, 8L);
        pp.emitFinal();
        // No assertion -- if any of the above NPE'd, the test would
        // fail. The wrapper must be defensive against a null listener.
    }
}
