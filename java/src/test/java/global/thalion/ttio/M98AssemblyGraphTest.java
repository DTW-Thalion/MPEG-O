/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.assembly.AssemblyGraph;
import global.thalion.ttio.assembly.WrittenAssemblyGraph;
import global.thalion.ttio.exporters.GfaWriter;
import global.thalion.ttio.importers.GfaReader;
import global.thalion.ttio.providers.MemoryProvider;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/**
 * M98: GFA parse/emit byte-exactness, the {@code /study/assembly_graphs}
 * storage round-trip, the {@code opt_assembly_graph} feature flag, and
 * the sequences-channel codec selection.
 *
 * <p>Mirrors ObjC {@code TestM98AssemblyGraph.m} and Python
 * {@code test_m98_assembly_graph.py}.</p>
 */
public class M98AssemblyGraphTest {

    /** The synthetic full-surface GFA the Phase 0 proof used: every
     *  GFA 1.x line type, sequence-less S records, tag stacks, a
     *  comment, a hifiasm-style A extension, interleaved ordering.
     *  Kept in lockstep with the ObjC and Python fixtures. */
    private static byte[] synthGfa() {
        List<String> lines = List.of(
            "H\tVN:Z:1.0",
            "# produced by the m98 synthetic generator",
            "S\tutg000001l\tACGTACGTACGTNNNACGT\tLN:i:19\trd:i:12",
            "A\tutg000001l\t0\t+\tread_00001\t0\t19\tid:i:0\tHG:A:a",
            "S\tutg000002l\t*\tLN:i:5000",
            "L\tutg000001l\t+\tutg000002l\t-\t15M\tL1:i:4985",
            "S\tutg000003c\tGGGGCCCCTTTTAAAA\tLN:i:16",
            "L\tutg000002l\t-\tutg000003c\t+\t*",
            "C\tutg000001l\t+\tutg000003c\t-\t2\t14M\tNM:i:0",
            "P\tscaffold_1\tutg000001l+,utg000002l-,utg000003c+\t15M,*\tXX:Z:demo",
            "L\tutg000003c\t+\tutg000001l\t+\t0M");
        return (String.join("\n", lines) + "\n")
            .getBytes(StandardCharsets.UTF_8);
    }

    private static StorageGroup memStudy(String url) {
        MemoryProvider.discardStore(url);
        return new MemoryProvider()
            .open(url, StorageProvider.Mode.CREATE)
            .rootGroup()
            .createGroup("study");
    }

    // ── parse + emit byte-exactness ───────────────────────────────

    @Test
    void gfaParseEmitByteExact() {
        byte[] src = synthGfa();
        WrittenAssemblyGraph g = GfaReader.graphFromBytes(src);
        assertEquals(3, g.segments().size());
        assertEquals(3, g.links().size());
        assertEquals(1, g.paths().size());
        assertEquals(4, g.extras().size());
        assertEquals("1.0", g.gfaVersion());
        assertNull(g.segments().get(1).sequence(),
            "'*' sequence parses as null");
        assertArrayEquals(src, GfaWriter.dataForGraph(g),
            "emit(parse(x)) == x");

        // The no-final-newline variant round-trips too.
        byte[] noNl = Arrays.copyOf(src, src.length - 1);
        WrittenAssemblyGraph g2 = GfaReader.graphFromBytes(noNl);
        assertFalse(g2.finalNewline());
        assertArrayEquals(noNl, GfaWriter.dataForGraph(g2));
    }

    // ── storage round-trip (memory provider) ──────────────────────

    @Test
    void storageRoundTripMemoryProvider() {
        byte[] src = synthGfa();
        WrittenAssemblyGraph g = GfaReader.graphFromBytes(src);
        String url = "memory://m98-" + ProcessHandle.current().pid();
        StorageGroup study = memStudy(url);
        try {
            AssemblyGraph.write(g, "g0", study);

            // Duplicate names are rejected.
            IllegalArgumentException e =
                assertThrows(IllegalArgumentException.class,
                    () -> AssemblyGraph.write(g, "g0", study));
            assertTrue(e.getMessage().contains("already exists"));

            AssemblyGraph opened = AssemblyGraph.readFrom(
                study.openGroup("assembly_graphs").openGroup("g0"), "g0");
            assertArrayEquals(src, opened.gfaBytes(),
                "memory-provider re-emission byte-exact");
        } finally {
            MemoryProvider.discardStore(url);
        }
    }

    // ── create + reopen + feature flag ────────────────────────────

    @Test
    void createReopenFlagAndAccessor(@TempDir Path tmp) {
        byte[] src = synthGfa();
        WrittenAssemblyGraph g = GfaReader.graphFromBytes(src);
        Path file = tmp.resolve("m98.tio");
        SpectralDataset.create(file.toString(), "M98", "ISA-M98",
            List.of(), List.of(), Map.of("graph_0001", g),
            List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertTrue(ds.featureFlags().has("opt_assembly_graph"),
                "opt_assembly_graph flag set");
            AssemblyGraph opened = ds.assemblyGraphs().get("graph_0001");
            assertNotNull(opened, "accessor finds the graph");
            assertEquals("1.0", opened.gfaVersion());
            assertTrue(opened.finalNewline());
            assertArrayEquals(src, opened.gfaBytes(),
                "HDF5 re-emission byte-exact");
        }
    }

    @Test
    void graphlessFileHasNeitherFlagNorSubtree(@TempDir Path tmp) {
        Path file = tmp.resolve("plain.tio");
        SpectralDataset.create(file.toString(), "M98", "ISA-M98",
            List.of(), List.of(), List.of(), List.of(),
            FeatureFlags.defaultCurrent()).close();

        try (SpectralDataset ds = SpectralDataset.open(file.toString())) {
            assertFalse(ds.featureFlags().has("opt_assembly_graph"),
                "flag absent without graphs");
            assertTrue(ds.assemblyGraphs().isEmpty(),
                "graph-less file reads back an empty map");
        }
    }

    // ── sequences-channel codec selection ─────────────────────────

    /** Mechanism check: the ACGT channel is BASE_PACK-encoded in the
     *  store ({@code @compression} = 6 and stored &lt; raw), not merely
     *  round-tripped — a raw pass-through would satisfy a
     *  byte-compare. */
    @Test
    void sequencesChannelBasePackEngaged() {
        StringBuilder bases = new StringBuilder();
        for (int i = 0; i < 2048; i++) bases.append("ACGT");  // 8,192
        byte[] src = ("S\tu1\t" + bases + "\nL\tu1\t+\tu1\t-\t0M\n")
            .getBytes(StandardCharsets.UTF_8);
        WrittenAssemblyGraph g = GfaReader.graphFromBytes(src);
        String url = "memory://m98c-" + ProcessHandle.current().pid();
        StorageGroup study = memStudy(url);
        try {
            AssemblyGraph.write(g, "g0", study);

            StorageDataset seqDs = study.openGroup("assembly_graphs")
                .openGroup("g0").openGroup("segments")
                .openDataset("sequences");
            assertEquals(6,
                ((Number) seqDs.getAttribute("compression")).intValue(),
                "ACGT channel stored as BASE_PACK (@compression=6)");
            byte[] stored = (byte[]) seqDs.readAll();
            assertTrue(stored.length > 0 && stored.length < 8192,
                "8,192 bases pack below 8,192 stored bytes (got "
                + stored.length + ")");

            AssemblyGraph opened = AssemblyGraph.readFrom(
                study.openGroup("assembly_graphs").openGroup("g0"), "g0");
            assertArrayEquals(src, opened.gfaBytes(),
                "BASE_PACK channel round-trips byte-exact");
        } finally {
            MemoryProvider.discardStore(url);
        }
    }
}
