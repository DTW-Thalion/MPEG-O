# tools/perf/compression_suite/formats/mzml.py
"""mzML comparators: zlib arrays (lossless) and numpress (lossy), gzip -6 outer."""
from __future__ import annotations

import subprocess
from pathlib import Path

from formats import register
import common


def rewrite(inp: Path, out: Path, mz_compression: str, it_compression: str) -> None:
    from psims.mzml import MzMLWriter
    from pyteomics import mzml as pmz
    with pmz.MzML(str(inp)) as reader, MzMLWriter(str(out)) as w:
        w.controlled_vocabularies()
        with w.run(id="run"):
            spectra = list(reader)
            with w.spectrum_list(count=len(spectra)):
                for sp in spectra:
                    ms_level = int(sp.get("ms level", 1))
                    w.write_spectrum(sp["m/z array"], sp["intensity array"],
                                     id=sp["id"], centroided=("centroid spectrum" in sp),
                                     scan_start_time=None,
                                     params=[{"ms level": ms_level}],
                                     compression={"m/z array": mz_compression,
                                                  "intensity array": it_compression})


class _Mzml:
    tier = "ms"

    def __init__(self, key: str, mz_comp: str, it_comp: str, lossy: bool):
        self.key, self.mz_comp, self.it_comp, self.lossy = key, mz_comp, it_comp, lossy

    def encode(self, inp: Path, out_dir: Path, ref: Path | None) -> Path:
        plain = out_dir / f"{inp.stem}.{self.key}.mzML"
        rewrite(inp, plain, self.mz_comp, self.it_comp)
        out = out_dir / f"{plain.name}.gz"
        with open(plain, "rb") as fi, open(out, "wb") as fo:
            subprocess.run(["gzip", "-6", "-c"], stdin=fi, stdout=fo, check=True)
        plain.unlink()
        return out

    def decode(self, enc: Path, out_dir: Path, ref: Path | None) -> Path:
        out = out_dir / f"{enc.name}.decoded.mzML"
        with open(out, "wb") as fo:
            subprocess.run(["gzip", "-dc", str(enc)], stdout=fo, check=True)
        return out

    def version(self) -> str:
        import psims
        return f"psims {psims.__version__}, gzip"


register(_Mzml("mzml_gz", "zlib", "zlib", lossy=False))
register(_Mzml("mzml_numpress_gz", "MS-Numpress linear prediction compression",
               "MS-Numpress short logged float compression", lossy=True))
