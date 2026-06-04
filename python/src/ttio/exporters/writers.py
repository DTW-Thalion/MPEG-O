"""Per-format :class:`~ttio.exporters.base.Writer` implementations. Each
serializes one layer of an *opened* :class:`SpectralDataset`. Run selection
is shared via :mod:`._select`."""
from __future__ import annotations

from . import _select


class MzMLWriter:
    def write(self, ds, layer, output, opts) -> None:
        from . import mzml
        mzml.write_dataset(ds, output)


class MzTabWriter:
    def write(self, ds, layer, output, opts) -> None:
        from . import mztab
        mztab.write_dataset(ds, output)


class IsaWriter:
    def write(self, ds, layer, output, opts) -> None:
        from . import isa
        isa.write_bundle_for_dataset(ds, output)


class NmrMLWriter:
    def write(self, ds, layer, output, opts) -> None:
        from ..nmr_spectrum import NMRSpectrum
        from . import nmrml
        run = _select.nmr_run(ds, layer)
        spectra = run.spectra()
        if not spectra:
            raise ValueError(f"run {layer or '(only)'!r} has no spectra")
        spectrum = spectra[0]
        if not isinstance(spectrum, NMRSpectrum):
            raise ValueError(
                f"run {layer or '(only)'!r} is {type(spectrum).__name__}, "
                "not an NMR spectrum; pass --layer to select an NMR run")
        # nmrML is one spectrum per file; export the run's first spectrum.
        nmrml.write_spectrum(spectrum, output)


class ImzMLWriter:
    def write(self, ds, layer, output, opts) -> None:
        from pathlib import Path

        from . import imzml
        img = ds.image
        if img is None:
            raise ValueError("dataset has no MS image to export as imzML")
        ibd = Path(output).with_suffix(".ibd")
        imzml.write(img.to_pixel_spectra(), output, ibd)


class JcampDxWriter:
    def write(self, ds, layer, output, opts) -> None:
        from ..ir_spectrum import IRSpectrum
        from ..raman_spectrum import RamanSpectrum
        from ..uv_vis_spectrum import UVVisSpectrum
        from . import jcamp_dx
        encoding = opts.get("encoding", "affn")
        run = _select.analytical_run(ds, layer)
        spectra = run.spectra()
        if not spectra:
            raise ValueError(f"run {layer or '(only)'!r} has no spectra")
        spectrum = spectra[0]
        if isinstance(spectrum, IRSpectrum):
            jcamp_dx.write_ir_spectrum(spectrum, output, encoding=encoding)
        elif isinstance(spectrum, RamanSpectrum):
            jcamp_dx.write_raman_spectrum(spectrum, output, encoding=encoding)
        elif isinstance(spectrum, UVVisSpectrum):
            jcamp_dx.write_uv_vis_spectrum(spectrum, output, encoding=encoding)
        else:
            raise ValueError(
                f"run {layer or '(only)'!r} is {type(spectrum).__name__}, "
                "not a vibrational (IR/Raman/UV-Vis) spectrum")


class BamWriter:
    def write(self, ds, layer, output, opts) -> None:
        from .bam import BamWriter as _W
        _W(output).write(_select.genomic_run(ds, layer))


class CramWriter:
    def write(self, ds, layer, output, opts) -> None:
        from .cram import CramWriter as _W
        reference = opts.get("reference")
        if not reference:
            raise ValueError(
                "CRAM export is reference-compressed; pass the reference FASTA "
                "via --extra --reference <path>")
        _W(output, reference).write(_select.genomic_run(ds, layer))
