/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.assembly;

import java.util.List;

/**
 * Write-side container for one assembly graph (M98, format-spec §11a).
 *
 * <p>{@code lineTypes} / {@code lineRows} replay the original file's
 * line order on emission; the constructor validates that the index is
 * a complete, in-range cover of the four tables (same checks as the
 * ObjC validating init).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOWrittenAssemblyGraph}, Python
 * {@code ttio.assembly.WrittenAssemblyGraph}.</p>
 */
public final class WrittenAssemblyGraph {

    /** line_index codes (format-spec §11a). */
    public static final int LINE_TYPE_SEGMENT = 0;
    public static final int LINE_TYPE_LINK = 1;
    public static final int LINE_TYPE_PATH = 2;
    public static final int LINE_TYPE_EXTRA = 3;

    private final String gfaVersion;
    private final String producer;
    private final boolean finalNewline;
    private final List<GraphSegment> segments;
    private final List<GraphLink> links;
    private final List<GraphPath> paths;
    private final List<String> extras;
    private final int[] lineTypes;
    private final long[] lineRows;

    public WrittenAssemblyGraph(String gfaVersion, String producer,
                                boolean finalNewline,
                                List<GraphSegment> segments,
                                List<GraphLink> links,
                                List<GraphPath> paths,
                                List<String> extras,
                                int[] lineTypes, long[] lineRows) {
        if (lineRows.length != lineTypes.length) {
            throw new IllegalArgumentException(
                "lineRows must hold one entry per lineTypes entry ("
                + lineTypes.length + " lines, " + lineRows.length
                + " rows)");
        }
        long[] counts = { segments.size(), links.size(),
                          paths.size(), extras.size() };
        long[] seen = new long[4];
        for (int i = 0; i < lineTypes.length; i++) {
            int t = lineTypes[i];
            long r = lineRows[i];
            if (t < 0 || t > LINE_TYPE_EXTRA || r < 0 || r >= counts[t]) {
                throw new IllegalArgumentException(
                    "line_index entry " + i + " (type " + t + ", row "
                    + r + ") is out of range");
            }
            seen[t]++;
        }
        for (int t = 0; t < 4; t++) {
            if (seen[t] != counts[t]) {
                throw new IllegalArgumentException(
                    "line_index covers " + seen[t] + " rows of type "
                    + t + ", table has " + counts[t]);
            }
        }
        this.gfaVersion = gfaVersion != null ? gfaVersion : "1.0";
        this.producer = producer != null ? producer : "";
        this.finalNewline = finalNewline;
        this.segments = List.copyOf(segments);
        this.links = List.copyOf(links);
        this.paths = List.copyOf(paths);
        this.extras = List.copyOf(extras);
        this.lineTypes = lineTypes.clone();
        this.lineRows = lineRows.clone();
    }

    public String gfaVersion() { return gfaVersion; }
    public String producer() { return producer; }
    public boolean finalNewline() { return finalNewline; }
    public List<GraphSegment> segments() { return segments; }
    public List<GraphLink> links() { return links; }
    public List<GraphPath> paths() { return paths; }
    public List<String> extras() { return extras; }
    public int[] lineTypes() { return lineTypes.clone(); }
    public long[] lineRows() { return lineRows.clone(); }
    public int lineCount() { return lineTypes.length; }

    /** The line type code at index {@code i} (0=S 1=L 2=P 3=X). */
    public int lineTypeAt(int i) { return lineTypes[i]; }

    /** The table row the line at index {@code i} points to. */
    public long lineRowAt(int i) { return lineRows[i]; }
}
