"""M98 AssemblyGraph acceptance tests.

GFA parse/emit byte-exactness, the ``/study/assembly_graphs`` storage
round-trip, the ``opt_assembly_graph`` feature flag, and the
sequences-channel codec selection.

Mirrors:
    objc/Tests/TestM98AssemblyGraph.m
    java/src/test/java/.../M98AssemblyGraphTest.java
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest

# The synthetic full-surface GFA the Phase 0 proof used: every GFA 1.x
# line type, sequence-less S records, tag stacks, a comment, a
# hifiasm-style A extension, interleaved ordering. Kept in lockstep
# with the ObjC and Java fixtures.
_SYNTH_LINES = [
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
    "L\tutg000003c\t+\tutg000001l\t+\t0M",
]


def _synth_gfa() -> bytes:
    return ("\n".join(_SYNTH_LINES) + "\n").encode()


# ---------------------------------------------------------------- parse/emit


def test_gfa_parse_emit_byte_exact():
    from ttio.exporters.gfa import GfaWriter
    from ttio.importers.gfa import GfaReader

    src = _synth_gfa()
    g = GfaReader.graph_from_bytes(src)
    assert (len(g.segments), len(g.links), len(g.paths), len(g.extras)) \
        == (3, 3, 1, 4)
    assert g.gfa_version == "1.0"
    assert g.segments[1].sequence is None  # '*' parses as None
    assert GfaWriter.data_for_graph(g) == src

    # The no-final-newline variant round-trips too.
    no_nl = src[:-1]
    g2 = GfaReader.graph_from_bytes(no_nl)
    assert g2.final_newline is False
    assert GfaWriter.data_for_graph(g2) == no_nl


# ------------------------------------- storage round-trip (memory provider)


def test_storage_round_trip_memory_provider():
    from ttio.assembly import AssemblyGraph, write_assembly_graph
    from ttio.importers.gfa import GfaReader
    from ttio.providers import open_provider

    src = _synth_gfa()
    g = GfaReader.graph_from_bytes(src)
    sp = open_provider(
        f"memory://m98-{os.getpid()}", provider="memory", mode="w")
    try:
        study = sp.root_group().create_group("study")
        write_assembly_graph(g, "g0", study)

        # Duplicate names are rejected.
        with pytest.raises(ValueError, match="already exists"):
            write_assembly_graph(g, "g0", study)

        gg = study.open_group("assembly_graphs").open_group("g0")
        opened = AssemblyGraph.open(gg, "g0")
        assert opened.gfa_bytes() == src
    finally:
        sp.close()


# ------------------------------------ write_minimal + reopen + feature flag


def test_write_minimal_flag_and_accessor(tmp_path: Path):
    from ttio.importers.gfa import GfaReader
    from ttio.spectral_dataset import SpectralDataset

    src = _synth_gfa()
    g = GfaReader.graph_from_bytes(src)
    p = tmp_path / "m98.tio"
    SpectralDataset.write_minimal(
        p, title="M98", isa_investigation_id="ISA-M98", runs={},
        assembly_graphs={"graph_0001": g},
    )

    ds = SpectralDataset.open(p)
    try:
        assert "opt_assembly_graph" in ds.feature_flags.features
        opened = ds.assembly_graphs["graph_0001"]
        assert opened.gfa_version == "1.0"
        assert opened.final_newline is True
        assert opened.gfa_bytes() == src
    finally:
        ds.close()


def test_write_minimal_graphless_has_no_flag(tmp_path: Path):
    # A file without graphs has neither the flag nor the subtree.
    from ttio.spectral_dataset import SpectralDataset

    p = tmp_path / "plain.tio"
    SpectralDataset.write_minimal(
        p, title="M98", isa_investigation_id="ISA-M98", runs={})
    ds = SpectralDataset.open(p)
    try:
        assert "opt_assembly_graph" not in ds.feature_flags.features
        assert ds.assembly_graphs == {}
    finally:
        ds.close()


# ---------------------------------------- sequences-channel codec selection


def test_sequences_channel_base_pack_engaged():
    """Mechanism check: the ACGT channel is BASE_PACK-encoded in the
    store (``@compression`` = 6 and stored < raw), not merely
    round-tripped -- a raw pass-through would satisfy a byte-compare."""
    from ttio.assembly import AssemblyGraph, write_assembly_graph
    from ttio.importers.gfa import GfaReader
    from ttio.providers import open_provider

    bases = "ACGT" * 2048  # 8,192 bases
    src = (f"S\tu1\t{bases}\nL\tu1\t+\tu1\t-\t0M\n").encode()
    g = GfaReader.graph_from_bytes(src)
    sp = open_provider(
        f"memory://m98c-{os.getpid()}", provider="memory", mode="w")
    try:
        study = sp.root_group().create_group("study")
        write_assembly_graph(g, "g0", study)

        seq_ds = (
            study.open_group("assembly_graphs").open_group("g0")
            .open_group("segments").open_dataset("sequences"))
        assert int(seq_ds.get_attribute("compression")) == 6  # BASE_PACK
        stored = seq_ds.read()
        assert 0 < len(stored) < 8192

        opened = AssemblyGraph.open(
            study.open_group("assembly_graphs").open_group("g0"), "g0")
        assert opened.gfa_bytes() == src
    finally:
        sp.close()
