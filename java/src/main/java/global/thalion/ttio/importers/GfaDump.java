/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.assembly.AssemblyGraph;
import global.thalion.ttio.assembly.GraphLink;
import global.thalion.ttio.assembly.GraphPath;
import global.thalion.ttio.assembly.GraphSegment;
import global.thalion.ttio.assembly.WrittenAssemblyGraph;
import global.thalion.ttio.exporters.GfaWriter;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * GfaDump — canonical-JSON dump of a GFA 1.x file or a stored
 * assembly graph, plus the M98 conformance write/emit modes.
 *
 * <p>Usage:</p>
 * <pre>
 *   GfaDump &lt;input.gfa|input.tio&gt; [--graph NAME]
 *   GfaDump &lt;input.gfa&gt; --write-tio &lt;out.tio&gt; [--graph NAME]
 *   GfaDump &lt;input.tio&gt; --emit-gfa &lt;out.gfa&gt; [--graph NAME]
 * </pre>
 *
 * <p>The JSON document is byte-identical to Python's
 * {@code json.dumps(payload, sort_keys=True, indent=2)} plus a
 * trailing newline; the same shape is produced by the Python
 * {@code python -m ttio.importers.gfa_dump} CLI and the ObjC
 * {@code TtioGfaDump} tool. The M98 conformance harness diffs the
 * three outputs and drives the 3x3 container matrix through the
 * write/emit modes.</p>
 */
public final class GfaDump {

    private GfaDump() {}

    private static WrittenAssemblyGraph load(String pathStr, String graph) {
        if (pathStr.toLowerCase().endsWith(".tio")) {
            try (SpectralDataset ds = SpectralDataset.open(pathStr)) {
                AssemblyGraph g = ds.assemblyGraphs().get(graph);
                if (g == null) {
                    throw new IllegalArgumentException(
                        "no assembly graph '" + graph + "' in " + pathStr);
                }
                return g.writtenGraph();
            }
        }
        return GfaReader.graphFromPath(Path.of(pathStr));
    }

    public static int run(String[] args, Writer out) throws IOException {
        String pathStr = null;
        String graph = "graph_0001";
        String writeTio = null;
        String emitGfa = null;
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--graph".equals(a) && i + 1 < args.length) {
                graph = args[++i];
            } else if (a.startsWith("--graph=")) {
                graph = a.substring("--graph=".length());
            } else if ("--write-tio".equals(a) && i + 1 < args.length) {
                writeTio = args[++i];
            } else if (a.startsWith("--write-tio=")) {
                writeTio = a.substring("--write-tio=".length());
            } else if ("--emit-gfa".equals(a) && i + 1 < args.length) {
                emitGfa = args[++i];
            } else if (a.startsWith("--emit-gfa=")) {
                emitGfa = a.substring("--emit-gfa=".length());
            } else if ("-h".equals(a) || "--help".equals(a)) {
                out.write("Usage: GfaDump <input.gfa|input.tio> "
                    + "[--graph NAME] [--write-tio OUT] [--emit-gfa OUT]\n");
                return 0;
            } else if (pathStr == null) {
                pathStr = a;
            } else {
                throw new IllegalArgumentException(
                    "Unexpected positional argument: " + a);
            }
        }
        if (pathStr == null) {
            throw new IllegalArgumentException(
                "Usage: GfaDump <input.gfa|input.tio> [--graph NAME] "
                + "[--write-tio OUT] [--emit-gfa OUT]");
        }

        if (writeTio != null) {
            WrittenAssemblyGraph g =
                GfaReader.graphFromPath(Path.of(pathStr));
            SpectralDataset.create(writeTio, "M98", "M98",
                List.of(), List.of(), Map.of(graph, g),
                List.of(), List.of(), List.of(),
                FeatureFlags.defaultCurrent()).close();
            return 0;
        }
        if (emitGfa != null) {
            GfaWriter.writeGraph(load(pathStr, graph), Path.of(emitGfa));
            return 0;
        }

        WrittenAssemblyGraph g = load(pathStr, graph);
        ByteArrayOutputStream seqs = new ByteArrayOutputStream();
        for (GraphSegment s : g.segments()) {
            if (s.sequence() != null) seqs.writeBytes(s.sequence());
        }

        Map<String, Object> payload = new TreeMap<>();
        payload.put("extra_count", g.extras().size());
        payload.put("extras", g.extras());
        payload.put("final_newline", g.finalNewline() ? 1 : 0);
        payload.put("gfa_version", g.gfaVersion());
        List<Long> lineRows = new ArrayList<>(g.lineCount());
        List<Integer> lineTypes = new ArrayList<>(g.lineCount());
        for (int i = 0; i < g.lineCount(); i++) {
            lineTypes.add(g.lineTypeAt(i));
            lineRows.add(g.lineRowAt(i));
        }
        payload.put("line_rows", lineRows);
        payload.put("line_types", lineTypes);
        payload.put("link_count", g.links().size());
        List<Object> links = new ArrayList<>();
        for (GraphLink l : g.links()) {
            Map<String, Object> m = new TreeMap<>();
            m.put("from", l.fromSegment());
            m.put("from_orient", l.fromOrient());
            m.put("overlap", l.overlap());
            m.put("tags", l.tags());
            m.put("to", l.toSegment());
            m.put("to_orient", l.toOrient());
            links.add(m);
        }
        payload.put("links", links);
        payload.put("path_count", g.paths().size());
        List<Object> paths = new ArrayList<>();
        for (GraphPath p : g.paths()) {
            Map<String, Object> m = new TreeMap<>();
            m.put("name", p.name());
            m.put("overlaps", p.overlaps());
            m.put("segment_list", p.segmentList());
            m.put("tags", p.tags());
            paths.add(m);
        }
        payload.put("paths", paths);
        payload.put("producer", g.producer());
        payload.put("segment_count", g.segments().size());
        List<Object> segments = new ArrayList<>();
        for (GraphSegment s : g.segments()) {
            Map<String, Object> m = new TreeMap<>();
            m.put("length", s.sequence() != null ? s.sequence().length : 0);
            m.put("name", s.name());
            m.put("seq_missing", s.sequence() == null ? 1 : 0);
            m.put("tags", s.tags());
            segments.add(m);
        }
        payload.put("segments", segments);
        payload.put("sequences_md5", BamDump.md5Hex(seqs.toByteArray()));

        StringBuilder sb = new StringBuilder(4096);
        BamDump.writeJson(sb, payload, 0);
        sb.append('\n');
        out.write(sb.toString());
        out.flush();
        return 0;
    }

    public static void main(String[] args) throws IOException {
        Writer w = new OutputStreamWriter(System.out, StandardCharsets.UTF_8);
        int code = run(args, w);
        w.flush();
        if (code != 0) System.exit(code);
    }
}
