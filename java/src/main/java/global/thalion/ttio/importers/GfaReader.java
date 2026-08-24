/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.assembly.GraphLink;
import global.thalion.ttio.assembly.GraphPath;
import global.thalion.ttio.assembly.GraphSegment;
import global.thalion.ttio.assembly.WrittenAssemblyGraph;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * GFA 1.x importer.
 *
 * <p>Parses a GFA assembly-graph file (hifiasm, miniasm, ...) into a
 * {@link WrittenAssemblyGraph} that re-emits the input byte-exactly
 * (format-spec §11a).</p>
 *
 * <p>Structural rules (identical in the 3 SDKs): split on LF after
 * final-newline detection, fields split on TAB. {@code S} needs
 * &ge; 3 fields, {@code L} &ge; 6, {@code P} &ge; 4; every other
 * line (H, C, comments, hifiasm {@code A} lines, short S/L/P) goes
 * verbatim into the extras table. Tags are the tab-joined verbatim
 * remainder, {@code ""} when none. A {@code *} sequence parses as
 * {@code null}. {@code gfa_version} is the {@code VN:Z:} value of
 * the first header line routed to extras, else {@code "1.0"}. An
 * empty file has 0 lines; {@code "\n"} is one empty extras line.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGfaReader}, Python {@code ttio.importers.gfa.GfaReader}.</p>
 */
public final class GfaReader {

    private GfaReader() {}

    /** The {@code VN:Z:} value of a header line's fields, or null. */
    private static String versionFromHeaderFields(String[] fields) {
        for (int i = 1; i < fields.length; i++) {
            if (fields[i].startsWith("VN:Z:")) {
                return fields[i].substring(5);
            }
        }
        return null;
    }

    private static String joinTail(String[] f, int from) {
        if (f.length <= from) return "";
        return String.join("\t",
            java.util.Arrays.copyOfRange(f, from, f.length));
    }

    public static WrittenAssemblyGraph graphFromBytes(byte[] data) {
        String text = new String(data, StandardCharsets.UTF_8);
        boolean finalNewline = data.length > 0
            && data[data.length - 1] == '\n';
        String[] all = text.split("\n", -1);
        int lineCount = all.length;
        if (finalNewline) lineCount--;  // drop the empty tail element
        if (data.length == 0) lineCount = 0;

        List<GraphSegment> segments = new ArrayList<>();
        List<GraphLink> links = new ArrayList<>();
        List<GraphPath> paths = new ArrayList<>();
        List<String> extras = new ArrayList<>();
        int[] lineTypes = new int[lineCount];
        long[] lineRows = new long[lineCount];
        String gfaVersion = null;

        for (int li = 0; li < lineCount; li++) {
            String line = all[li];
            String[] f = line.split("\t", -1);
            String t = f.length > 0 ? f[0] : "";
            int type;
            long row;
            if ("S".equals(t) && f.length >= 3) {
                byte[] seq = "*".equals(f[2])
                    ? null
                    : f[2].getBytes(StandardCharsets.UTF_8);
                segments.add(new GraphSegment(f[1], seq, joinTail(f, 3)));
                type = WrittenAssemblyGraph.LINE_TYPE_SEGMENT;
                row = segments.size() - 1;
            } else if ("L".equals(t) && f.length >= 6) {
                links.add(new GraphLink(f[1], f[2], f[3], f[4], f[5],
                    joinTail(f, 6)));
                type = WrittenAssemblyGraph.LINE_TYPE_LINK;
                row = links.size() - 1;
            } else if ("P".equals(t) && f.length >= 4) {
                paths.add(new GraphPath(f[1], f[2], f[3], joinTail(f, 4)));
                type = WrittenAssemblyGraph.LINE_TYPE_PATH;
                row = paths.size() - 1;
            } else {
                if (gfaVersion == null && "H".equals(t)) {
                    gfaVersion = versionFromHeaderFields(f);
                }
                extras.add(line);
                type = WrittenAssemblyGraph.LINE_TYPE_EXTRA;
                row = extras.size() - 1;
            }
            lineTypes[li] = type;
            lineRows[li] = row;
        }

        return new WrittenAssemblyGraph(
            gfaVersion != null ? gfaVersion : "1.0", "", finalNewline,
            segments, links, paths, extras, lineTypes, lineRows);
    }

    public static WrittenAssemblyGraph graphFromPath(Path path) {
        try {
            return graphFromBytes(Files.readAllBytes(path));
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
