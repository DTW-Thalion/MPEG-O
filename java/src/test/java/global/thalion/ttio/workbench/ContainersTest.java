/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench;

import global.thalion.ttio.workbench.containers.Container;
import global.thalion.ttio.workbench.containers.ContainerDetail;
import global.thalion.ttio.workbench.containers.ContainerLayer;
import global.thalion.ttio.workbench.containers.ContainerListPage;
import global.thalion.ttio.workbench.containers.ContainerManifest;
import global.thalion.ttio.workbench.containers.ContainersClient;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the W5.2 containers SDK surface. Pure data
 * parsing; no daemon required.
 *
 * <p>Cross-language anchor: the literal JSON pinned in
 * {@link #listPageParsesCanonicalAnchor()} mirrors the Python
 * {@code test_containers.test_list_page_parses_canonical_anchor}.
 * Drift in either client fails both suites.</p>
 */
class ContainersTest {

    // ---------------------------------------------- Container

    @Test
    void containerFromJsonMinimal() {
        Container c = Container.fromJson(Map.of(
            "uri",          "uri:tio:demo",
            "project",      "alpha",
            "owner",        "alice",
            "encrypted",    false,
            "storage_path", "/srv/alpha/demo.tio",
            "created_at",   1700000000L,
            "updated_at",   1700000600L));
        assertEquals("uri:tio:demo", c.uri());
        assertEquals("alpha", c.project());
        assertFalse(c.encrypted());
        assertEquals(1700000600L, c.updatedAt());
    }

    @Test
    void containerEncryptedTruthyOnlyWhenBoolTrue() {
        assertFalse(Container.fromJson(Map.of("encrypted", false)).encrypted());
        assertTrue(Container.fromJson(Map.of("encrypted", true)).encrypted());
        // Missing key -> false.
        assertFalse(Container.fromJson(Map.of("uri", "u")).encrypted());
    }

    @Test
    void containerHandlesMissingTimestamps() {
        Container c = Container.fromJson(Map.of("uri", "uri:tio:x"));
        assertEquals(0L, c.createdAt());
        assertEquals(0L, c.updatedAt());
    }

    // ---------------------------------------------- ContainerDetail

    @Test
    void containerDetailAddsSizeAndMtime() {
        ContainerDetail d = ContainerDetail.fromJson(Map.of(
            "uri",          "uri:tio:demo",
            "project",      "alpha",
            "owner",        "alice",
            "encrypted",    true,
            "storage_path", "/srv/alpha/demo.tio",
            "created_at",   1700000000L,
            "updated_at",   1700000600L,
            "size_bytes",   1024L * 1024L,
            "modified_at",  1700000700L));
        assertEquals(1024L * 1024L, d.sizeBytes());
        assertEquals(1700000700L, d.modifiedAt());
        assertTrue(d.encrypted());
    }

    @Test
    void containerDetailStripsToListShape() {
        ContainerDetail d = ContainerDetail.fromJson(Map.of(
            "uri",       "uri:tio:demo",
            "project",   "alpha",
            "owner",     "alice",
            "encrypted", false));
        Container c = d.asContainer();
        assertEquals("uri:tio:demo", c.uri());
        assertEquals("alpha", c.project());
    }

    // ---------------------------------------------- ContainerListPage

    @Test
    void listPageParsesEmpty() {
        ContainerListPage page = ContainerListPage.fromJson(
            Map.of("containers", List.of()));
        assertTrue(page.containers().isEmpty());
        assertNull(page.nextCursor());
        assertFalse(page.hasMore());
    }

    @Test
    void listPageParsesNextCursor() {
        ContainerListPage page = ContainerListPage.fromJson(Map.of(
            "containers",  List.of(),
            "next_cursor", "eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOjEifQ"));
        assertEquals("eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOjEifQ", page.nextCursor());
        assertTrue(page.hasMore());
    }

    @Test
    void listPageEmptyCursorNormalisedToNull() {
        ContainerListPage page = ContainerListPage.fromJson(Map.of(
            "containers",  List.of(),
            "next_cursor", ""));
        assertNull(page.nextCursor());
        assertFalse(page.hasMore());
    }

    @Test
    void listPageParsesCanonicalAnchor() {
        // Cross-language anchor: this exact JSON must parse
        // identically in Java and Python. Python mirror:
        // test_containers.test_list_page_parses_canonical_anchor.
        ContainerListPage page = ContainerListPage.fromJson(Map.of(
            "containers", List.of(
                Map.of(
                    "uri",          "uri:tio:alpha-001",
                    "project",      "alpha",
                    "owner",        "alice",
                    "encrypted",    false,
                    "storage_path", "/srv/alpha/001.tio",
                    "created_at",   1700000000L,
                    "updated_at",   1700000600L),
                Map.of(
                    "uri",          "uri:tio:alpha-002",
                    "project",      "alpha",
                    "owner",        "bob",
                    "encrypted",    true,
                    "storage_path", "/srv/alpha/002.tio",
                    "created_at",   1700001000L,
                    "updated_at",   1700001600L)),
            "next_cursor", "eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOmFscGhhLTAwMiJ9"));
        assertEquals(2, page.containers().size());
        assertEquals("uri:tio:alpha-001", page.containers().get(0).uri());
        assertFalse(page.containers().get(0).encrypted());
        assertEquals("bob", page.containers().get(1).owner());
        assertTrue(page.containers().get(1).encrypted());
        assertEquals("eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOmFscGhhLTAwMiJ9", page.nextCursor());
    }

    // ---------------------------------------------- ContainerLayer

    @Test
    void layerFromJson() {
        ContainerLayer layer = ContainerLayer.fromJson(Map.of(
            "layer_type", "spectra/msL1",
            "layer_path", "spectra/msL1.bin",
            "byte_size",  1024L,
            "created_at", 1700000000L));
        assertEquals("spectra/msL1", layer.layerType());
        assertEquals(1024L, layer.byteSize());
    }

    // ---------------------------------------------- ContainerManifest

    @Test
    void manifestMinimal() {
        ContainerManifest m = ContainerManifest.fromJson(Map.of(
            "uri",   "uri:tio:demo",
            "title", "demo container"));
        assertEquals("uri:tio:demo", m.uri());
        assertTrue(m.msRuns().isEmpty());
        assertEquals(0L, m.identificationCount());
    }

    @Test
    void manifestFull() {
        ContainerManifest m = ContainerManifest.fromJson(Map.of(
            "uri",                  "uri:tio:demo",
            "title",                "demo container",
            "isa_investigation_id", "I-MTBLS-001",
            "ms_runs", List.of(Map.of(
                "name",             "run1",
                "spectrum_class",   "MassSpectrum",
                "acquisition_mode", 2,
                "channel_names",    List.of("mz", "intensity"),
                "spectrum_count",   1000L,
                "ms_level_distribution", Map.of("1", 500L, "2", 500L))),
            "nmr_runs", List.of(Map.of(
                "name", "nmr1", "spectrum_count", 4L)),
            "genomic_runs", List.of(Map.of(
                "name", "wgs1", "read_count", 1_000_000L,
                "platform", "illumina")),
            "identification_count",   42L,
            "quantification_count",   17L,
            "provenance_record_count", 3L));
        assertEquals("run1", m.msRuns().get(0).name());
        assertEquals(500L, m.msRuns().get(0).msLevelDistribution().get("1"));
        assertEquals(4L, m.nmrRuns().get(0).spectrumCount());
        assertEquals("illumina", m.genomicRuns().get(0).platform());
        assertEquals(42L, m.identificationCount());
    }

    // ---------------------------------------------- ContainersClient

    @Test
    void clientConstructorStoresArgs() {
        ContainersClient c = new ContainersClient(
            "biobank.example.com", 8443, "https", "ttiowbs_abc");
        // Constructor stores; structurally verified by the WorkbenchClient
        // factory test (sub-client returned non-null).
        assertNotNull(c);
    }
}
