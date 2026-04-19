"""Synthetic .mpgo fixture generator.

Produces deterministic small-to-medium ``.mpgo`` containers for
integration, security, anonymization and stress tests.

All randomness uses ``np.random.default_rng(SEED)`` so benchmark
runs and round-trip comparisons are stable across machines.

Files emitted (default destination ``tests/fixtures/_generated/``):

* ``synth_bsa.mpgo``         — 500 MS1 + 200 MS2, 50 BSA peptide IDs
* ``synth_multimodal.mpgo``  — 100 MS + 10 NMR spectra, linked IDs
* ``synth_100k.mpgo``        — 100 000 MS spectra (for stress tests)
* ``synth_saav.mpgo``        — 5 SAAV-flagged IDs for anonymization
* ``synth_metabolites.mpgo`` — 5 rare-metabolite IDs for masking

CLI: ``python generate.py [--out DIR] [--include name [name ...]]``.
"""
from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable

import numpy as np

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.identification import Identification

SEED = 42
DEFAULT_OUT = Path(__file__).resolve().parent / "_generated"

_PEAKS_PER_SPECTRUM = 64
_MS1_BASELINE_RT_S = 0.5
_RT_RAMP_S = 60.0


def _ms_run(
    *,
    n_spectra: int,
    n_peaks: int = _PEAKS_PER_SPECTRUM,
    ms_level_pattern: np.ndarray | None = None,
    rt_total_s: float = _RT_RAMP_S,
    rng: np.random.Generator,
) -> WrittenRun:
    """Build one WrittenRun with concatenated mz/intensity channels."""
    mz_template = np.linspace(100.0, 1000.0, n_peaks, dtype=np.float64)
    mz = np.tile(mz_template, n_spectra)
    intensity = rng.uniform(0.0, 1e6, size=n_spectra * n_peaks).astype(np.float64)
    offsets = (np.arange(n_spectra, dtype=np.uint64) * n_peaks)
    lengths = np.full(n_spectra, n_peaks, dtype=np.uint32)
    rts = np.linspace(_MS1_BASELINE_RT_S, rt_total_s, n_spectra, dtype=np.float64)
    if ms_level_pattern is None:
        ms_levels = np.ones(n_spectra, dtype=np.int32)
    else:
        ms_levels = np.asarray(ms_level_pattern, dtype=np.int32)
        if ms_levels.shape != (n_spectra,):
            raise ValueError("ms_level_pattern shape must match n_spectra")
    polarities = np.ones(n_spectra, dtype=np.int32)
    precursor_mz = np.where(
        ms_levels == 2,
        rng.uniform(300.0, 900.0, size=n_spectra).astype(np.float64),
        0.0,
    )
    precursor_charge = np.where(ms_levels == 2, 2, 0).astype(np.int32)
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mz,
        precursor_charges=precursor_charge,
        base_peak_intensities=intensity.reshape(n_spectra, n_peaks).max(axis=1),
    )


def _nmr_run(*, n_spectra: int, n_points: int, rng: np.random.Generator) -> WrittenRun:
    """Build a 1H NMR-style WrittenRun (real + imag channels)."""
    real = rng.normal(0.0, 1.0, size=n_spectra * n_points).astype(np.float64)
    imag = rng.normal(0.0, 1.0, size=n_spectra * n_points).astype(np.float64)
    offsets = (np.arange(n_spectra, dtype=np.uint64) * n_points)
    lengths = np.full(n_spectra, n_points, dtype=np.uint32)
    return WrittenRun(
        spectrum_class="MPGONMRSpectrum",
        acquisition_mode=0,
        channel_data={"fid_real": real, "fid_imag": imag},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.zeros(n_spectra, dtype=np.float64),
        ms_levels=np.zeros(n_spectra, dtype=np.int32),
        polarities=np.zeros(n_spectra, dtype=np.int32),
        precursor_mzs=np.zeros(n_spectra, dtype=np.float64),
        precursor_charges=np.zeros(n_spectra, dtype=np.int32),
        base_peak_intensities=np.zeros(n_spectra, dtype=np.float64),
        nucleus_type="1H",
    )


def gen_synth_bsa(out: Path) -> Path:
    rng = np.random.default_rng(SEED)
    pattern = np.empty(700, dtype=np.int32)
    pattern[:500] = 1  # MS1
    pattern[500:] = 2  # MS2
    rng.shuffle(pattern)
    run = _ms_run(n_spectra=700, ms_level_pattern=pattern, rng=rng)
    ids = [
        Identification(
            run_name="run_0001",
            spectrum_index=int(i * 10),
            chemical_entity=f"BSA_PEPTIDE_{i:03d}",
            confidence_score=0.7 + (i % 30) / 100.0,
            evidence_chain=["X!Tandem v1.0"],
        )
        for i in range(50)
    ]
    path = out / "synth_bsa.mpgo"
    SpectralDataset.write_minimal(
        path,
        title="Synthetic BSA tryptic digest",
        isa_investigation_id="ISA-SYNTH-BSA",
        runs={"run_0001": run},
        identifications=ids,
    )
    return path


def gen_synth_multimodal(out: Path) -> Path:
    rng = np.random.default_rng(SEED + 1)
    ms_run = _ms_run(n_spectra=100, rng=rng)
    nmr_run = _nmr_run(n_spectra=10, n_points=2048, rng=rng)
    ids = [
        Identification("ms_run", i * 10, f"CHEBI:{1000+i}", 0.9, []) for i in range(5)
    ] + [
        Identification("nmr_run", i, f"CHEBI:{2000+i}", 0.8, []) for i in range(3)
    ]
    path = out / "synth_multimodal.mpgo"
    SpectralDataset.write_minimal(
        path,
        title="Synthetic multimodal MS + NMR study",
        isa_investigation_id="ISA-SYNTH-MULTI",
        runs={"ms_run": ms_run, "nmr_run": nmr_run},
        identifications=ids,
    )
    return path


def gen_synth_100k(out: Path) -> Path:
    rng = np.random.default_rng(SEED + 2)
    run = _ms_run(n_spectra=100_000, n_peaks=16, rt_total_s=3600.0, rng=rng)
    path = out / "synth_100k.mpgo"
    SpectralDataset.write_minimal(
        path,
        title="Synthetic 100K-spectrum stress fixture",
        isa_investigation_id="ISA-SYNTH-100K",
        runs={"run_0001": run},
    )
    return path


def gen_synth_saav(out: Path) -> Path:
    rng = np.random.default_rng(SEED + 3)
    run = _ms_run(n_spectra=20, rng=rng)
    ids = [
        Identification("run_0001", i, f"p.Ala{100+i}Thr SAAV", 0.85, [])
        for i in range(5)
    ]
    path = out / "synth_saav.mpgo"
    SpectralDataset.write_minimal(
        path,
        title="Synthetic SAAV anonymization fixture",
        isa_investigation_id="ISA-SYNTH-SAAV",
        runs={"run_0001": run},
        identifications=ids,
    )
    return path


def gen_synth_metabolites(out: Path) -> Path:
    rng = np.random.default_rng(SEED + 4)
    run = _ms_run(n_spectra=20, rng=rng)
    ids = [
        Identification("run_0001", i, f"CHEBI:9999{i}", 0.95, [])
        for i in range(5)
    ]
    path = out / "synth_metabolites.mpgo"
    SpectralDataset.write_minimal(
        path,
        title="Synthetic rare-metabolite anonymization fixture",
        isa_investigation_id="ISA-SYNTH-METABOLITES",
        runs={"run_0001": run},
        identifications=ids,
    )
    return path


GENERATORS: dict[str, callable[[Path], Path]] = {
    "synth_bsa": gen_synth_bsa,
    "synth_multimodal": gen_synth_multimodal,
    "synth_100k": gen_synth_100k,
    "synth_saav": gen_synth_saav,
    "synth_metabolites": gen_synth_metabolites,
}


def generate_all(out: Path, *, names: Iterable[str] | None = None) -> dict[str, Path]:
    out.mkdir(parents=True, exist_ok=True)
    selected = list(names) if names else list(GENERATORS)
    paths: dict[str, Path] = {}
    for name in selected:
        if name not in GENERATORS:
            raise KeyError(f"unknown generator: {name}")
        paths[name] = GENERATORS[name](out)
    return paths


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="MPEG-O synthetic fixture generator")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output directory")
    parser.add_argument("--include", nargs="*", default=None, help="subset of fixtures to generate")
    ns = parser.parse_args(argv)
    paths = generate_all(ns.out, names=ns.include)
    for name, path in paths.items():
        size_kb = path.stat().st_size / 1024.0
        print(f"  {name:20s} {size_kb:>9.1f} KB  {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
