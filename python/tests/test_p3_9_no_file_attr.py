"""P3.9 — the raw-h5py SpectralDataset.file leak is retired.

The HDF5 open path is routed through _from_provider so the dataclass
no longer carries a raw h5py.File field. These tests assert the
attribute is gone and that provider-based construction yields a dataset
equivalent to the old _from_open_file path.
"""
from __future__ import annotations

from pathlib import Path

from ttio import SpectralDataset, Subject


def test_no_file_attr_and_provider_present(tmp_path: Path) -> None:
    out = tmp_path / "no_file_attr.tio"
    SpectralDataset.write_minimal(
        out,
        title="p3.9",
        isa_investigation_id="TTIO:p39",
        runs={},
    )
    with SpectralDataset.open(out) as ds:
        # The leaky raw-h5py field is gone.
        assert not hasattr(ds, "file")
        # The dataset is provider-backed and reachable through the protocol.
        assert ds.provider is not None
        assert ds.provider.root_group().has_child("study")


def test_from_provider_round_trips_content(tmp_path: Path) -> None:
    out = tmp_path / "content.tio"
    subjects = [Subject(external_id="S1", project="P", sex="M", birth_year=1990)]
    SpectralDataset.write_minimal(
        out,
        title="round trip title",
        isa_investigation_id="TTIO:rt",
        runs={},
        subjects=subjects,
    )
    with SpectralDataset.open(out) as ds:
        assert ds.title == "round trip title"
        assert ds.isa_investigation_id == "TTIO:rt"
        assert ds.is_encrypted is False
        got = ds.subjects
        assert len(got) == 1
        assert got[0].external_id == "S1"
        assert got[0].project == "P"
        assert got[0].birth_year == 1990
