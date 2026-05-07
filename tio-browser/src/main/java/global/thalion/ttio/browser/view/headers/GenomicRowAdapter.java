package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;

/**
 * Wraps a {@code (GenomicRun, index)} pair so that {@link
 * GenomicHeadersTable} columns can read per-row data via
 * {@link GenomicRun#index()} accessors without materialising the
 * full payload. Calling {@link #full()} eagerly loads the
 * {@link AlignedRead} via {@link GenomicRun#objectAtIndex(int)} —
 * used by the row-selection bridge to drive {@code ReadInspectorView}.
 */
public final class GenomicRowAdapter {

    private final GenomicRun run;
    private final int idx;

    public GenomicRowAdapter(GenomicRun run, int idx) {
        this.run = run;
        this.idx = idx;
    }

    public int index()         { return idx; }
    public String chromosome() { return run.index().chromosomeAt(idx); }
    public long position()     { return run.index().positionAt(idx); }
    public int flag()          { return run.index().flagsAt(idx); }
    public int mapq()          { return run.index().mappingQualityAt(idx); }
    public String cigar()      { return run.cigarAt(idx); }
    public int length()        { return run.index().lengthAt(idx); }
    public String readName()   { return run.readNameAt(idx); }

    /** Eagerly materialise the full {@link AlignedRead} for this row. */
    public AlignedRead full()  { return run.objectAtIndex(idx); }
}
