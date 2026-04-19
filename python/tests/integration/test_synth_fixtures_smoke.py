"""Smoke test verifying the M57 fixture infrastructure works.

Real integration tests land in M58-M64. This file exists so pytest
collects the new ``tests/integration/`` package and so CI catches
breakage in the synthetic-fixture pipeline.
"""
from __future__ import annotations

from pathlib import Path

from mpeg_o import SpectralDataset


def test_synth_bsa_round_trips(synth_fixture) -> None:
    path: Path = synth_fixture("synth_bsa")
    with SpectralDataset.open(path) as ds:
        run = ds.ms_runs["run_0001"]
        assert len(run) == 700
        assert len(ds.identifications()) == 50


def test_synth_multimodal_has_two_runs(synth_fixture) -> None:
    path: Path = synth_fixture("synth_multimodal")
    with SpectralDataset.open(path) as ds:
        # write_minimal places every run under ms_runs and uses the
        # spectrum_class attribute to distinguish — see test_importers.
        assert set(ds.all_runs.keys()) == {"ms_run", "nmr_run"}
        assert len(ds.ms_runs["ms_run"]) == 100
        nmr = ds.ms_runs["nmr_run"]
        assert nmr.spectrum_class == "MPGONMRSpectrum"
        assert len(nmr) == 10


def test_synth_saav_identifications(synth_fixture) -> None:
    path: Path = synth_fixture("synth_saav")
    with SpectralDataset.open(path) as ds:
        ids = ds.identifications()
        assert len(ids) == 5
        assert all("SAAV" in i.chemical_entity for i in ids)
