/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.assembly.GraphLink;
import global.thalion.ttio.assembly.GraphPath;
import global.thalion.ttio.assembly.GraphSegment;
import global.thalion.ttio.assembly.WrittenAssemblyGraph;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * GFA 1.x exporter.
 *
 * <p>Re-emits a {@link WrittenAssemblyGraph} as GFA bytes. Emission
 * replays {@code line_index} so the output is byte-exact against the
 * parsed input: extras verbatim, {@code *} for a missing sequence,
 * tags appended with a TAB only when non-empty, and the final newline
 * restored from the graph's {@code finalNewline} flag.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGfaWriter}, Python {@code ttio.exporters.gfa.GfaWriter}.</p>
 */
public final class GfaWriter {

    private GfaWriter() {}

    private static void append(ByteArrayOutputStream out, String s) {
        out.writeBytes(s.getBytes(StandardCharsets.UTF_8));
    }

    public static byte[] dataForGraph(WrittenAssemblyGraph graph) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int n = graph.lineCount();
        for (int i = 0; i < n; i++) {
            if (i > 0) out.write('\n');
            int row = (int) graph.lineRowAt(i);
            switch (graph.lineTypeAt(i)) {
            case WrittenAssemblyGraph.LINE_TYPE_SEGMENT: {
                GraphSegment s = graph.segments().get(row);
                append(out, "S\t");
                append(out, s.name());
                out.write('\t');
                if (s.sequence() != null) {
                    out.writeBytes(s.sequence());
                } else {
                    out.write('*');
                }
                if (!s.tags().isEmpty()) {
                    out.write('\t');
                    append(out, s.tags());
                }
                break;
            }
            case WrittenAssemblyGraph.LINE_TYPE_LINK: {
                GraphLink l = graph.links().get(row);
                append(out, "L\t" + l.fromSegment() + "\t" + l.fromOrient()
                    + "\t" + l.toSegment() + "\t" + l.toOrient()
                    + "\t" + l.overlap());
                if (!l.tags().isEmpty()) {
                    out.write('\t');
                    append(out, l.tags());
                }
                break;
            }
            case WrittenAssemblyGraph.LINE_TYPE_PATH: {
                GraphPath p = graph.paths().get(row);
                append(out, "P\t" + p.name() + "\t" + p.segmentList()
                    + "\t" + p.overlaps());
                if (!p.tags().isEmpty()) {
                    out.write('\t');
                    append(out, p.tags());
                }
                break;
            }
            default:
                append(out, graph.extras().get(row));
                break;
            }
        }
        if (graph.finalNewline()) out.write('\n');
        return out.toByteArray();
    }

    public static void writeGraph(WrittenAssemblyGraph graph, Path path) {
        try {
            Files.write(path, dataForGraph(graph));
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
