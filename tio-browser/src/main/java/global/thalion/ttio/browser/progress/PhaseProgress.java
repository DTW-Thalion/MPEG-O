package global.thalion.ttio.browser.progress;

import global.thalion.ttio.io.ProgressSink;

/**
 * Two-phase progress wrapper used by {@code ImportTask} + {@code
 * ExportTask}: a reader phase that maps onto 0..50% and a writer
 * phase that maps onto 50..100%.
 *
 * <p>Pre-Stage-E behavior: the reader emitted {@code (N of M reads)},
 * the writer then emitted {@code (X of Y sections)}, and both drove
 * the same single {@link ProgressTracker} — so the dialog's units
 * count visibly "restarted" at the read/write boundary and the
 * percent could even regress when {@code X*total/Y} was less than
 * the reader's last fraction.</p>
 *
 * <p>Stage E maps each phase to a fixed half of the bar via the bytes
 * channel (a synthesised 0..{@link #PHASE_SCALE} "abstract units"
 * domain). Reader callbacks scale to {@code [0, PHASE_SCALE/2]};
 * writer callbacks scale to {@code [PHASE_SCALE/2, PHASE_SCALE]}.
 * The units channel reflects whichever phase is currently emitting
 * (so the numeric line still shows the format-specific records
 * count), and the phase label transitions from {@code "reading"} to
 * the configured write-phase label when the reader's terminal
 * {@code (M, M)} fires.</p>
 *
 * <p>Percent is therefore strictly monotonic across the boundary:
 * the reader's last sample renders 50%, and the writer's first
 * sample renders 50% + (recDone/recTotal)*50%.</p>
 *
 * <p>Not thread-safe per-sink call, but the two sinks may be invoked
 * from different threads (reader thread vs writer thread) without
 * external synchronisation: the underlying {@link ProgressTracker}
 * is created fresh on each phase transition and updates a volatile
 * field. In practice readers/writers in {@code ImportTask} /
 * {@code ExportTask} run sequentially on the JavaFX worker thread.</p>
 */
public final class PhaseProgress {

    /** Total span of the synthesised bytes-domain progress. Half is
     *  used for the read phase and half for the write phase. The
     *  numeric value is arbitrary — any value that gives sub-percent
     *  resolution is fine; 10_000 ⇒ 0.01% granularity. */
    public static final long PHASE_SCALE = 10_000L;
    private static final long HALF = PHASE_SCALE / 2L;

    private final ProgressListener listener;
    private final String readLabel;
    private final String writeLabel;
    private final long startEpochMs;

    /** Tracker for the bytes-domain "abstract" 0..PHASE_SCALE
     *  progress. Driven by both phases (each scaled to its half) so
     *  percent is strictly monotonic across the boundary. */
    private final ProgressTracker overall;

    /** Volatile phase string used when emitting a fresh
     *  {@link ProgressReport} — flipped when the reader fires its
     *  terminal sample. */
    private volatile String currentPhase;

    /** Latest units (records) seen, mirrored into the report's units
     *  channel so the formatter's "N / M AUs" line stays
     *  meaningful. Resets to (0, writerTotal) at the read/write
     *  boundary. */
    private volatile long currentUnitsDone = 0L;
    private volatile long currentUnitsTotal = -1L;

    /** Set true on the reader's terminal {@code (M, M)} sample, or
     *  on the first writer sample — whichever comes first. Guards
     *  against late reader emits after the writer has started. */
    private volatile boolean writeStarted = false;

    public PhaseProgress(ProgressListener listener,
                         String readLabel,
                         String writeLabel,
                         long startEpochMs) {
        this.listener = listener;
        this.readLabel = readLabel;
        this.writeLabel = writeLabel;
        this.startEpochMs = startEpochMs;
        this.currentPhase = readLabel;
        // Drive the bytes channel as the unified percent source; the
        // units channel is repopulated per-phase on each emit.
        this.overall = new ProgressTracker(
            readLabel, PHASE_SCALE, -1L, startEpochMs);
    }

    /** Sink to hand to the reader. Maps the reader's {@code (done,
     *  total)} reports onto {@code [0, HALF]} of the unified bar.
     *  Terminal {@code (M, M)} fires advance percent to exactly
     *  50% and flip the phase label to the writer's so the dialog
     *  shows "encoding…" even before the writer's first emit. */
    public ProgressSink readerSink() {
        return (recDone, recTotal) -> {
            if (writeStarted) {
                // A late reader emit after the writer has already
                // started. Ignore — percent must stay monotonic.
                return;
            }
            long bytesDone;
            if (recTotal > 0L && recDone >= recTotal) {
                bytesDone = HALF;
                // Reader completed: flip the phase label so the
                // dialog shows the writer's phase even before the
                // writer's first emit.
                writeStarted = true;
                currentPhase = writeLabel;
                // Reset units to (0, writerTotal=-1 until known) so
                // the dialog doesn't carry the reader's units count
                // into the writer half.
                currentUnitsDone = 0L;
                currentUnitsTotal = -1L;
            } else if (recTotal > 0L) {
                bytesDone = (recDone * HALF) / recTotal;
                currentUnitsDone = recDone;
                currentUnitsTotal = recTotal;
            } else {
                // Unknown total: best-effort partial fill of the
                // read half. Map by min(recDone, HALF) to keep the
                // bar moving without overshooting 50%.
                bytesDone = Math.min(recDone, HALF);
                currentUnitsDone = recDone;
                currentUnitsTotal = -1L;
            }
            emit(bytesDone);
        };
    }

    /** Sink to hand to the writer. Maps the writer's {@code (done,
     *  total)} reports onto {@code [HALF, PHASE_SCALE]} of the
     *  unified bar. The first non-zero emit also flips the phase
     *  label (in case the reader never fired a terminal sample). */
    public ProgressSink writerSink() {
        return (recDone, recTotal) -> {
            if (!writeStarted) {
                writeStarted = true;
                currentPhase = writeLabel;
                currentUnitsDone = 0L;
                currentUnitsTotal = recTotal > 0L ? recTotal : -1L;
            }
            long bytesDone;
            if (recTotal > 0L) {
                bytesDone = HALF + (recDone * HALF) / recTotal;
                currentUnitsDone = recDone;
                currentUnitsTotal = recTotal;
            } else {
                // Unknown total: best-effort partial fill of the
                // write half. Keep the bar between 50% and 100% by
                // clamping the offset.
                bytesDone = HALF + Math.min(recDone, HALF);
                currentUnitsDone = recDone;
                currentUnitsTotal = -1L;
            }
            emit(bytesDone);
        };
    }

    /** Emit a synthetic initial 0% so the UI clears any prior state
     *  before the first reader callback. */
    public void emitInitial() {
        emit(0L);
    }

    /** Emit a final 100% sample (writer phase, full bar). Useful when
     *  the writer SDK doesn't fire a terminal {@code (T, T)}. */
    public void emitFinal() {
        if (!writeStarted) {
            writeStarted = true;
            currentPhase = writeLabel;
        }
        emit(PHASE_SCALE);
    }

    private void emit(long bytesDone) {
        if (listener == null) return;
        // The overall tracker is the source of percent + rate +
        // ETA, computed over the synthesised bytes domain. We then
        // splice in the current phase's units fields so the numeric
        // line still reads "N / M AUs" against the actual records.
        ProgressReport base = overall.sample(
            bytesDone, 0L, System.currentTimeMillis());
        ProgressReport spliced = new ProgressReport(
            currentPhase,
            base.bytesDone(),
            base.bytesTotal(),
            currentUnitsDone,
            currentUnitsTotal,
            base.rateBytesPerSec(),
            // The bytes-domain rate is in abstract units/sec and
            // not user-facing; hide units-rate (NaN) so the
            // formatter falls back to the bytes-rate path, which
            // is what the dialog actually shows.
            Double.NaN,
            base.etaSeconds(),
            base.elapsedSeconds(),
            base.lastActivityEpochMs());
        listener.onProgress(spliced);
    }

    /** Visible for tests. */
    public String currentPhase() { return currentPhase; }

    /** Visible for tests. */
    public boolean writeStarted() { return writeStarted; }
}
