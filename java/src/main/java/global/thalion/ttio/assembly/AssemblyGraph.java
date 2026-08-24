/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.assembly;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.codecs.registry.ChannelPayload;
import global.thalion.ttio.codecs.registry.Codec;
import global.thalion.ttio.codecs.registry.CodecContext;
import global.thalion.ttio.codecs.registry.CodecRegistry;
import global.thalion.ttio.codecs.registry.DecodedChannel;
import global.thalion.ttio.codecs.registry.EncodedChannel;
import global.thalion.ttio.exporters.GfaWriter;
import global.thalion.ttio.providers.CompoundField;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Read-side handle for one assembly graph stored at
 * {@code /study/assembly_graphs/<name>/}, plus the storage writer
 * (M98, format-spec §11a).
 *
 * <p>Layout: {@code @gfa_version} / {@code @producer} /
 * {@code @final_newline} attributes, {@code segments/records} plus a
 * concatenated {@code segments/sequences} byte channel (BASE_PACK
 * when the alphabet is ACGTN upper or lower case, RANS_ORDER1
 * otherwise, {@code @compression} on the dataset), {@code links},
 * {@code paths}, {@code extras}, and {@code line_index} which replays
 * the original line order on emission. Empty tables are ABSENT: 0-row
 * non-extendable compounds do not round-trip on every provider, and
 * readers in all 3 SDKs treat a missing table as empty.</p>
 *
 * <p>Unlike the ObjC and Python handles this reads eagerly (the Java
 * open paths close their groups on exit, the {@link
 * global.thalion.ttio.genomics.GenomicRun#readFrom} precedent).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOAssemblyGraph} + {@code TTIOSpectralDataset
 * (AssemblyWrite)}, Python {@code ttio.assembly.AssemblyGraph} +
 * {@code ttio.assembly.write_assembly_graph}.</p>
 */
public final class AssemblyGraph {

    private final String name;
    private final WrittenAssemblyGraph graph;

    private AssemblyGraph(String name, WrittenAssemblyGraph graph) {
        this.name = name;
        this.graph = graph;
    }

    public String name() { return name; }
    public String gfaVersion() { return graph.gfaVersion(); }
    public String producer() { return graph.producer(); }
    public boolean finalNewline() { return graph.finalNewline(); }
    public WrittenAssemblyGraph writtenGraph() { return graph; }

    /** Re-emit the stored graph as GFA bytes (byte-exact). */
    public byte[] gfaBytes() { return GfaWriter.dataForGraph(graph); }

    // ── storage writer ────────────────────────────────────────────

    private static final List<CompoundField> SEGMENT_FIELDS = List.of(
        new CompoundField("name", CompoundField.Kind.VL_STRING),
        new CompoundField("length", CompoundField.Kind.UINT64),
        new CompoundField("seq_offset", CompoundField.Kind.UINT64),
        new CompoundField("seq_missing", CompoundField.Kind.UINT32),
        new CompoundField("tags", CompoundField.Kind.VL_STRING));

    private static final List<CompoundField> LINK_FIELDS = List.of(
        new CompoundField("from", CompoundField.Kind.VL_STRING),
        new CompoundField("from_orient", CompoundField.Kind.VL_STRING),
        new CompoundField("to", CompoundField.Kind.VL_STRING),
        new CompoundField("to_orient", CompoundField.Kind.VL_STRING),
        new CompoundField("overlap", CompoundField.Kind.VL_STRING),
        new CompoundField("tags", CompoundField.Kind.VL_STRING));

    private static final List<CompoundField> PATH_FIELDS = List.of(
        new CompoundField("name", CompoundField.Kind.VL_STRING),
        new CompoundField("segment_list", CompoundField.Kind.VL_STRING),
        new CompoundField("overlaps", CompoundField.Kind.VL_STRING),
        new CompoundField("tags", CompoundField.Kind.VL_STRING));

    private static final List<CompoundField> EXTRA_FIELDS = List.of(
        new CompoundField("line", CompoundField.Kind.VL_STRING));

    private static final List<CompoundField> INDEX_FIELDS = List.of(
        new CompoundField("line_type", CompoundField.Kind.UINT32),
        new CompoundField("row", CompoundField.Kind.UINT64));

    private static final boolean[] SEQ_ALPHABET = new boolean[256];
    static {
        for (byte b : "ACGTNacgtn".getBytes()) {
            SEQ_ALPHABET[b & 0xFF] = true;
        }
    }

    /** Codec for a concatenated segment-sequences buffer: BASE_PACK
     *  when every byte is ACGTN (upper or lower case), RANS_ORDER1
     *  otherwise, NONE when empty. The same rule holds in the ObjC
     *  and Python writers so the 3 SDKs emit identical channels. */
    private static Compression sequencesCodec(byte[] data) {
        if (data.length == 0) return Compression.NONE;
        for (byte b : data) {
            if (!SEQ_ALPHABET[b & 0xFF]) return Compression.RANS_ORDER1;
        }
        return Compression.BASE_PACK;
    }

    private static void writeBytesChannel(StorageGroup group, String name,
                                          byte[] data) {
        Compression codec = sequencesCodec(data);
        byte[] stored = data;
        if (codec != Compression.NONE) {
            Codec c = CodecRegistry.CODEC_REGISTRY.get(codec);
            EncodedChannel enc = c.encode(
                new DecodedChannel.Bytes(data), CodecContext.empty());
            if (!(enc instanceof EncodedChannel.DatasetBytes db)) {
                throw new IllegalStateException(
                    "assembly sequences channel encode failed");
            }
            stored = db.bytes();
        }
        StorageDataset ds = group.createDataset(name, Precision.UINT8,
            stored.length, 65536, Compression.NONE, 0);
        if (stored.length > 0) ds.writeAll(stored);
        if (codec != Compression.NONE) {
            ds.setAttribute("compression", codec.ordinal());
        }
    }

    private static void writeCompound(StorageGroup group, String name,
                                      List<CompoundField> fields,
                                      List<Map<String, Object>> rows) {
        // Empty tables are ABSENT (format-spec §11a).
        if (rows.isEmpty()) return;
        group.createCompoundDataset(name, fields, rows.size())
             .writeAll(rows);
    }

    /** Write {@code graph} under
     *  {@code /study/assembly_graphs/<name>/}. {@code study} is the
     *  dataset's study group on any provider.
     *
     *  @throws IllegalArgumentException when {@code name} already
     *          exists */
    public static void write(WrittenAssemblyGraph graph, String name,
                             StorageGroup study) {
        StorageGroup ag;
        if (study.hasChild("assembly_graphs")) {
            ag = study.openGroup("assembly_graphs");
        } else {
            ag = study.createGroup("assembly_graphs");
            ag.setAttribute("_graph_names", "");
        }

        if (ag.hasChild(name)) {
            throw new IllegalArgumentException(
                "assembly graph '" + name + "' already exists");
        }
        String namesValue = "";
        if (ag.hasAttribute("_graph_names")
                && ag.getAttribute("_graph_names") instanceof String s) {
            namesValue = s;
        }
        StringBuilder names = new StringBuilder(namesValue);
        if (names.length() > 0) names.append(",");
        names.append(name);
        ag.setAttribute("_graph_names", names.toString());

        StorageGroup g = ag.createGroup(name);
        g.setAttribute("gfa_version",
            graph.gfaVersion() != null ? graph.gfaVersion() : "1.0");
        g.setAttribute("producer",
            graph.producer() != null ? graph.producer() : "");
        g.setAttribute("final_newline",
            graph.finalNewline() ? 1L : 0L);

        // segments/: records compound + concatenated sequences channel.
        StorageGroup segG = g.createGroup("segments");
        ByteArrayOutputStream seqs = new ByteArrayOutputStream();
        List<Map<String, Object>> segRows = new ArrayList<>();
        for (GraphSegment s : graph.segments()) {
            long off = seqs.size();
            long length = s.sequence() != null ? s.sequence().length : 0L;
            if (s.sequence() != null) {
                seqs.writeBytes(s.sequence());
            }
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("name", s.name());
            row.put("length", length);
            row.put("seq_offset", off);
            row.put("seq_missing", s.sequence() == null ? 1 : 0);
            row.put("tags", s.tags());
            segRows.add(row);
        }
        writeCompound(segG, "records", SEGMENT_FIELDS, segRows);
        if (seqs.size() > 0) {
            writeBytesChannel(segG, "sequences", seqs.toByteArray());
        }

        List<Map<String, Object>> linkRows = new ArrayList<>();
        for (GraphLink l : graph.links()) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("from", l.fromSegment());
            row.put("from_orient", l.fromOrient());
            row.put("to", l.toSegment());
            row.put("to_orient", l.toOrient());
            row.put("overlap", l.overlap());
            row.put("tags", l.tags());
            linkRows.add(row);
        }
        writeCompound(g, "links", LINK_FIELDS, linkRows);

        List<Map<String, Object>> pathRows = new ArrayList<>();
        for (GraphPath p : graph.paths()) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("name", p.name());
            row.put("segment_list", p.segmentList());
            row.put("overlaps", p.overlaps());
            row.put("tags", p.tags());
            pathRows.add(row);
        }
        writeCompound(g, "paths", PATH_FIELDS, pathRows);

        List<Map<String, Object>> extraRows = new ArrayList<>();
        for (String line : graph.extras()) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("line", line);
            extraRows.add(row);
        }
        writeCompound(g, "extras", EXTRA_FIELDS, extraRows);

        List<Map<String, Object>> idxRows = new ArrayList<>();
        for (int i = 0; i < graph.lineCount(); i++) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("line_type", graph.lineTypeAt(i));
            row.put("row", graph.lineRowAt(i));
            idxRows.add(row);
        }
        writeCompound(g, "line_index", INDEX_FIELDS, idxRows);
    }

    // ── read side ─────────────────────────────────────────────────

    private static String attrStr(StorageGroup group, String name) {
        if (!group.hasAttribute(name)) return "";
        Object v = group.getAttribute(name);
        return v instanceof String s ? s : "";
    }

    private static String rowStr(Object v) {
        if (v instanceof byte[] b) return new String(b,
            java.nio.charset.StandardCharsets.UTF_8);
        return v != null ? v.toString() : "";
    }

    private static long rowLong(Object v) {
        return v instanceof Number n ? n.longValue() : 0L;
    }

    /** Decode a byte channel written with an optional
     *  {@code @compression} codec attribute (0 or absent = raw).
     *  Public because the per-AU encryption walker decodes the
     *  channel before slicing it into per-segment AUs. */
    public static byte[] decodeBytesChannel(StorageDataset ds) {
        byte[] raw = (byte[]) ds.readAll();
        int codec = 0;
        if (ds.hasAttribute("compression")
                && ds.getAttribute("compression") instanceof Number n) {
            codec = n.intValue();
        }
        if (codec == 0) return raw;
        Compression[] all = Compression.values();
        Codec c = codec < all.length
            ? CodecRegistry.CODEC_REGISTRY.get(all[codec]) : null;
        if (c == null) {
            throw new IllegalStateException(
                "sequences channel names unregistered codec " + codec);
        }
        DecodedChannel dec = c.decode(
            new ChannelPayload.BytesPayload(raw), CodecContext.empty());
        return ((DecodedChannel.Bytes) dec).data();
    }

    /** readRows on a table that is absent-when-empty. */
    private static List<Map<String, Object>> rowsOrEmpty(
            StorageGroup group, String name) {
        if (!group.hasChild(name)) return List.of();
        return group.openDataset(name).readRows();
    }

    /** Materialise the graph stored in {@code group} (which is
     *  {@code /study/assembly_graphs/<name>/}). The
     *  {@code final_newline} attribute is the structural marker of an
     *  M98 graph group.
     *
     *  @throws IllegalArgumentException when the attribute is absent
     *          or a record is inconsistent */
    public static AssemblyGraph readFrom(StorageGroup group, String name) {
        if (!group.hasAttribute("final_newline")) {
            throw new IllegalArgumentException(
                "assembly graph '" + name + "' lacks the final_newline "
                + "attribute");
        }
        boolean finalNewline = true;
        if (group.getAttribute("final_newline") instanceof Number n) {
            finalNewline = n.longValue() != 0;
        }
        String gfaVersion = attrStr(group, "gfa_version");
        String producer = attrStr(group, "producer");

        List<Map<String, Object>> segRows = List.of();
        byte[] seqBytes = new byte[0];
        if (group.hasChild("segments")) {
            StorageGroup segG = group.openGroup("segments");
            segRows = rowsOrEmpty(segG, "records");
            if (segG.hasChild("sequences")) {
                seqBytes = decodeBytesChannel(
                    segG.openDataset("sequences"));
            }
        }

        List<GraphSegment> segments = new ArrayList<>(segRows.size());
        for (Map<String, Object> row : segRows) {
            byte[] seq = null;
            if (rowLong(row.get("seq_missing")) == 0) {
                long off = rowLong(row.get("seq_offset"));
                long length = rowLong(row.get("length"));
                if (off + length > seqBytes.length) {
                    throw new IllegalArgumentException(
                        "segment record points outside the sequences "
                        + "channel");
                }
                seq = java.util.Arrays.copyOfRange(
                    seqBytes, (int) off, (int) (off + length));
            }
            segments.add(new GraphSegment(rowStr(row.get("name")), seq,
                rowStr(row.get("tags"))));
        }

        List<GraphLink> links = new ArrayList<>();
        for (Map<String, Object> row : rowsOrEmpty(group, "links")) {
            links.add(new GraphLink(
                rowStr(row.get("from")), rowStr(row.get("from_orient")),
                rowStr(row.get("to")), rowStr(row.get("to_orient")),
                rowStr(row.get("overlap")), rowStr(row.get("tags"))));
        }
        List<GraphPath> paths = new ArrayList<>();
        for (Map<String, Object> row : rowsOrEmpty(group, "paths")) {
            paths.add(new GraphPath(
                rowStr(row.get("name")), rowStr(row.get("segment_list")),
                rowStr(row.get("overlaps")), rowStr(row.get("tags"))));
        }
        List<String> extras = new ArrayList<>();
        for (Map<String, Object> row : rowsOrEmpty(group, "extras")) {
            extras.add(rowStr(row.get("line")));
        }
        List<Map<String, Object>> idxRows = rowsOrEmpty(group, "line_index");
        int[] lineTypes = new int[idxRows.size()];
        long[] lineRows = new long[idxRows.size()];
        for (int i = 0; i < idxRows.size(); i++) {
            lineTypes[i] = (int) rowLong(idxRows.get(i).get("line_type"));
            lineRows[i] = rowLong(idxRows.get(i).get("row"));
        }

        return new AssemblyGraph(name, new WrittenAssemblyGraph(
            gfaVersion, producer, finalNewline, segments, links, paths,
            extras, lineTypes, lineRows));
    }

    /** Read every graph under {@code study}'s
     *  {@code assembly_graphs/} subtree, keyed by name. Unreadable
     *  graphs are skipped the way unreadable genomic runs are; the
     *  map is empty when the subtree is absent. */
    public static Map<String, AssemblyGraph> readAll(StorageGroup study) {
        Map<String, AssemblyGraph> out = new LinkedHashMap<>();
        if (!study.hasChild("assembly_graphs")) return out;
        StorageGroup ag = study.openGroup("assembly_graphs");
        if (!ag.hasAttribute("_graph_names")
                || !(ag.getAttribute("_graph_names") instanceof String names)) {
            return out;
        }
        for (String gn : names.split(",", -1)) {
            String trimmed = gn.trim();
            if (trimmed.isEmpty() || !ag.hasChild(trimmed)) continue;
            try {
                out.put(trimmed,
                    readFrom(ag.openGroup(trimmed), trimmed));
            } catch (IllegalArgumentException e) {
                // skip unreadable graph
            }
        }
        return out;
    }
}
