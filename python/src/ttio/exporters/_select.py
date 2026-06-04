"""Run-selection helpers shared by the export registry and the per-format
:class:`~ttio.exporters.base.Writer` classes. Each picks the right
:class:`AcquisitionRun` (or genomic run) from an opened
:class:`~ttio.spectral_dataset.SpectralDataset` given an optional ``layer``.
"""
from __future__ import annotations


def analytical_run(ds, layer):
    """Select an analytical run (any spectrum_class) by layer, or the
    single run when unambiguous. Used by the JCAMP exporter, which
    accepts any of the vibrational subclasses."""
    runs = {**ds.ms_runs, **ds.nmr_runs}
    if not runs:
        raise KeyError("no analytical runs in dataset")
    if layer:
        if layer not in runs:
            raise KeyError(
                f"run {layer!r} not found; have: " + ", ".join(sorted(runs)))
        return runs[layer]
    if len(runs) == 1:
        return next(iter(runs.values()))
    raise KeyError("multiple runs present; pass --layer <name>")


def nmr_run(ds, layer):
    # Analytical runs (MS / NMR / vibrational) live in /study/ms_runs;
    # /study/nmr_runs is a separate group some writers use. Search both
    # and distinguish by spectrum_class (matches the Java exporter,
    # which reads NMR runs out of dataset.msRuns()).
    runs = {**ds.ms_runs, **ds.nmr_runs}
    if not runs:
        raise KeyError("no analytical runs in dataset")
    if layer:
        if layer not in runs:
            raise KeyError(
                f"run {layer!r} not found; have: " + ", ".join(sorted(runs)))
        return runs[layer]
    nmr = [r for r in runs.values() if r.spectrum_class == "TTIONMRSpectrum"]
    if len(nmr) == 1:
        return nmr[0]
    if len(nmr) > 1:
        raise KeyError("multiple NMR runs present; pass --layer <name>")
    if len(runs) == 1:
        return next(iter(runs.values()))
    raise KeyError("multiple runs present; pass --layer <name>")


def genomic_run(ds, layer):
    runs = ds.genomic_runs
    if not runs:
        raise KeyError("no genomic runs in dataset")
    if layer:
        if layer not in runs:
            raise KeyError(
                f"genomic run {layer!r} not found; have: "
                + ", ".join(sorted(runs)))
        return runs[layer]
    if len(runs) == 1:
        return next(iter(runs.values()))
    raise KeyError(
        "multiple genomic runs present; pass --layer <name>: "
        + ", ".join(sorted(runs)))
