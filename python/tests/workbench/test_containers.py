"""
Unit tests for `ttio.workbench.containers` -- pure-data parsing
of /v1/containers responses. No daemon.

Cross-language anchor: the literal list-page JSON pinned in
`test_list_page_parses_canonical_anchor` is mirrored in the
Java `ContainersClientTest.listPageParsesCanonicalAnchor`. Drift
in either client fails both suites.
"""
from __future__ import annotations

import pytest

from ttio.workbench.containers import (
    Container,
    ContainerDetail,
    ContainerLayer,
    ContainerListPage,
    ContainerManifest,
    ContainersClient,
    GenomicRunSummary,
    MsRunSummary,
    NmrRunSummary,
)


# ---------------------------------------------------- Container

def test_container_from_json_minimal():
    c = Container.from_json({
        "uri":          "uri:tio:demo",
        "project":      "alpha",
        "owner":        "alice",
        "encrypted":    False,
        "storage_path": "/srv/alpha/demo.tio",
        "created_at":   1700000000,
        "updated_at":   1700000600,
    })
    assert c.uri == "uri:tio:demo"
    assert c.project == "alpha"
    assert c.owner == "alice"
    assert c.encrypted is False
    assert c.storage_path == "/srv/alpha/demo.tio"
    assert c.created_at == 1700000000
    assert c.updated_at == 1700000600


def test_container_encrypted_truthy_only_when_bool_true():
    # The server sends booleans; falsy strings/ints must not flip the flag.
    assert Container.from_json({"encrypted": False}).encrypted is False
    assert Container.from_json({"encrypted": True}).encrypted is True


def test_container_handles_missing_timestamps():
    c = Container.from_json({"uri": "uri:tio:x"})
    assert c.created_at == 0
    assert c.updated_at == 0


# ---------------------------------------------------- ContainerDetail

def test_container_detail_adds_size_and_mtime():
    d = ContainerDetail.from_json({
        "uri":          "uri:tio:demo",
        "project":      "alpha",
        "owner":        "alice",
        "encrypted":    True,
        "storage_path": "/srv/alpha/demo.tio",
        "created_at":   1700000000,
        "updated_at":   1700000600,
        "size_bytes":   1024 * 1024,
        "modified_at":  1700000700,
    })
    assert d.size_bytes == 1024 * 1024
    assert d.modified_at == 1700000700
    assert d.encrypted is True


def test_container_detail_strips_to_list_shape():
    d = ContainerDetail.from_json({
        "uri":          "uri:tio:demo",
        "project":      "alpha",
        "owner":        "alice",
        "encrypted":    False,
        "storage_path": "/srv/alpha/demo.tio",
        "created_at":   1700000000,
        "updated_at":   1700000600,
        "size_bytes":   1024,
        "modified_at":  1700000700,
    })
    c = d.as_container()
    assert isinstance(c, Container)
    assert c.uri == "uri:tio:demo"
    assert not hasattr(c, "size_bytes")


# ---------------------------------------------------- ContainerListPage

def test_list_page_parses_empty():
    page = ContainerListPage.from_json({"containers": []})
    assert page.containers == []
    assert page.next_cursor is None
    assert page.has_more is False


def test_list_page_parses_next_cursor():
    page = ContainerListPage.from_json({
        "containers":  [],
        "next_cursor": "eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOjEifQ",
    })
    assert page.next_cursor == "eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOjEifQ"
    assert page.has_more is True


def test_list_page_empty_cursor_normalised_to_none():
    page = ContainerListPage.from_json({
        "containers":  [],
        "next_cursor": "",
    })
    assert page.next_cursor is None
    assert page.has_more is False


def test_list_page_parses_canonical_anchor():
    """Cross-language anchor: this exact list-page JSON must parse
    identically in Python and Java.

    Java mirror: `ContainersClientTest.listPageParsesCanonicalAnchor`.
    """
    page = ContainerListPage.from_json({
        "containers": [
            {
                "uri":          "uri:tio:alpha-001",
                "project":      "alpha",
                "owner":        "alice",
                "encrypted":    False,
                "storage_path": "/srv/alpha/001.tio",
                "created_at":   1700000000,
                "updated_at":   1700000600,
            },
            {
                "uri":          "uri:tio:alpha-002",
                "project":      "alpha",
                "owner":        "bob",
                "encrypted":    True,
                "storage_path": "/srv/alpha/002.tio",
                "created_at":   1700001000,
                "updated_at":   1700001600,
            },
        ],
        "next_cursor": "eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOmFscGhhLTAwMiJ9",
    })
    assert len(page.containers) == 2
    assert page.containers[0].uri == "uri:tio:alpha-001"
    assert page.containers[0].encrypted is False
    assert page.containers[1].owner == "bob"
    assert page.containers[1].encrypted is True
    assert page.next_cursor == "eyJsYXN0X3VyaSI6ICJ1cmk6dGlvOmFscGhhLTAwMiJ9"


# ---------------------------------------------------- ContainerLayer

def test_layer_from_json():
    layer = ContainerLayer.from_json({
        "layer_type":  "spectra/msL1",
        "layer_path":  "spectra/msL1.bin",
        "byte_size":   1024,
        "created_at":  1700000000,
    })
    assert layer.layer_type == "spectra/msL1"
    assert layer.byte_size == 1024


# ---------------------------------------------------- ContainerManifest

def test_manifest_minimal():
    m = ContainerManifest.from_json({
        "uri":   "uri:tio:demo",
        "title": "demo container",
    })
    assert m.uri == "uri:tio:demo"
    assert m.title == "demo container"
    assert m.ms_runs == []
    assert m.identification_count == 0


def test_manifest_full():
    m = ContainerManifest.from_json({
        "uri":   "uri:tio:demo",
        "title": "demo container",
        "isa_investigation_id": "I-MTBLS-001",
        "ms_runs": [{
            "name":             "run1",
            "spectrum_class":   "MassSpectrum",
            "acquisition_mode": 2,
            "channel_names":    ["mz", "intensity"],
            "spectrum_count":   1000,
            "ms_level_distribution": {"1": 500, "2": 500},
        }],
        "nmr_runs": [{"name": "nmr1", "spectrum_count": 4}],
        "genomic_runs": [
            {"name": "wgs1", "read_count": 1_000_000, "platform": "illumina"},
        ],
        "identification_count":   42,
        "quantification_count":   17,
        "provenance_record_count": 3,
    })
    assert m.ms_runs[0].name == "run1"
    assert m.ms_runs[0].ms_level_distribution == {"1": 500, "2": 500}
    assert m.nmr_runs[0].spectrum_count == 4
    assert m.genomic_runs[0].platform == "illumina"
    assert m.identification_count == 42


# ---------------------------------------------------- ContainersClient structural

def test_client_constructor_stores_args():
    c = ContainersClient("biobank.example.com", 8443, "https", "ttiowbs_abc")
    assert c.host == "biobank.example.com"
    assert c.port == 8443
    assert c.scheme == "https"
    assert c.token == "ttiowbs_abc"
