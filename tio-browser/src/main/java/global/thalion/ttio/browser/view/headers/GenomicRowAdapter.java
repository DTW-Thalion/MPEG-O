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
 *
 * <p>{@link #cigar()}, {@link #readName()}, and {@link #full()} can
 * trigger native (JNI) codec paths for files that store CIGAR /
 * read-name / sequence streams in {@code NAME_TOKENIZED_V2} or
 * {@code REF_DIFF_V2} format. When the native lib isn't loadable
 * (e.g. fat-jar on a platform we didn't bundle for), those accessors
 * return a placeholder string and {@link #full()} returns
 * {@code null}; the rest of the row is still usable. Diagnostic state
 * lives in {@link global.thalion.ttio.browser.util.NativeLibraryLoader}.</p>
 */
public final class GenomicRowAdapter {

    private static final String JNI_PLACEHOLDER = "(JNI unavailable)";

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
    public int length()        { return run.index().lengthAt(idx); }

    public String cigar() {
        try { return run.cigarAt(idx); }
        catch (UnsatisfiedLinkError | RuntimeException e) { return JNI_PLACEHOLDER; }
    }

    public String readName() {
        try { return run.readNameAt(idx); }
        catch (UnsatisfiedLinkError | RuntimeException e) { return JNI_PLACEHOLDER; }
    }

    /**
     * Materialise the full {@link AlignedRead}. Returns {@code null}
     * when the native codec path is unavailable; callers (notably
     * {@code ReadInspectorTab}) detect null and render a placeholder.
     */
    public AlignedRead full() {
        try { return run.objectAtIndex(idx); }
        catch (UnsatisfiedLinkError | RuntimeException e) { return null; }
    }
}
