# Importer / Exporter Registry — Python Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Python importer/exporter subsystem onto real `Reader`/`Writer` interfaces dispatching through a normalized `ImportedDataset` draft, deleting the registry's adapter callables — the first ("Python-first proof") PR of the 3-SDK P2.6 parity effort.

**Architecture:** A `Reader` produces an in-memory `ImportedDataset` (the universal draft); a single `ImportedDataset.write()` is the lone `SpectralDataset.write_minimal` call site. A `Writer` takes an opened `SpectralDataset` + layer. The two registries hold `Reader`/`Writer` instances instead of adapter lambdas; their public surface (`normalize`/`spec_for`/`registry_keys`/`supported_*_formats`/`encode`/`export`/`UnknownFormatError`/`FormatSpec.display_name`) is preserved verbatim so `tools/workbench_cli.py` and the existing tests are untouched.

**Tech Stack:** Python 3.12, `dataclasses`, `typing.Protocol` (`@runtime_checkable`), numpy, pytest. Build/test in WSL: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest`.

**Hard invariants (verify continuously):**
- No `.tio` wire/on-disk change — `write_minimal` output byte-identical.
- No change to supported formats, aliases, extensions, required tools, or how each maps. The registry key/alias/extension tables are copied verbatim.
- `registry.encode(...)` / `registry.export(...)` keep their exact signatures; `tests/workbench/test_encode_formats.py` + `test_export_formats.py` pass **unchanged**.
- External-tool errors still surface from the importer/writer at run time (not the registry).

**Scope note:** This is the Python slice only. The Java (incl. tio-browser delegation) and ObjC slices are separate PRs with their own plans, written after this proof merges (per the spec's delivery section).

---

### Task P1: `ImportedDataset` normalized draft

**Files:**
- Create: `python/src/ttio/importers/imported_dataset.py`
- Test: `python/tests/test_imported_dataset.py`

The universal draft every reader returns. Holds already-built run objects + dataset-level metadata and owns the single `write_minimal` call.

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_imported_dataset.py
from __future__ import annotations

import numpy as np

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.importers.imported_dataset import ImportedDataset


def _run() -> WrittenRun:
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.linspace(100.0, 105.0, 6),
                      "intensity": np.linspace(1.0, 60.0, 6)},
        offsets=np.zeros(1, dtype=np.uint64),
        lengths=np.full(1, 6, dtype=np.uint32),
        retention_times=np.zeros(1, dtype=np.float64),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.ones(1, dtype=np.int32),
        precursor_mzs=np.zeros(1, dtype=np.float64),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.full(1, 60.0, dtype=np.float64),
    )


def test_write_round_trips(tmp_path):
    out = tmp_path / "d.tio"
    draft = ImportedDataset(title="t", isa_investigation_id="TTIO:t",
                            runs={"run_0001": _run()})
    returned = draft.write(out)
    assert returned == out
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs


def test_empty_genomic_runs_pass_none(tmp_path):
    # genomic_runs / images default empty and must reach write_minimal as
    # None (not {}), preserving the pre-refactor call shape.
    out = tmp_path / "e.tio"
    ImportedDataset(title="g", isa_investigation_id="",
                    runs={"run_0001": _run()}).write(out)
    assert out.exists()
```

- [ ] **Step 2: Run it — expect ImportError (`imported_dataset` missing)**

Run: `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_imported_dataset.py -q`
Expected: collection error / ModuleNotFoundError.

- [ ] **Step 3: Implement the draft**

```python
# python/src/ttio/importers/imported_dataset.py
"""``ImportedDataset`` — the normalized in-memory draft every importer
produces. The single call site of :meth:`SpectralDataset.write_minimal`,
collapsing the per-format adapter normalization the registry used to do.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from ..identification import Identification
from ..provenance import ProvenanceRecord
from ..quantification import Quantification
from ..spectral_dataset import SpectralDataset, WrittenRun

if TYPE_CHECKING:
    from ..genomic_run import WrittenGenomicRun


@dataclass(slots=True)
class ImportedDataset:
    """In-memory bundle of built runs + dataset metadata, ready to write."""

    title: str = ""
    isa_investigation_id: str = ""
    runs: dict[str, WrittenRun] = field(default_factory=dict)
    genomic_runs: dict = field(default_factory=dict)  # name -> WrittenGenomicRun
    identifications: list[Identification] = field(default_factory=list)
    quantifications: list[Quantification] = field(default_factory=list)
    provenance: list[ProvenanceRecord] = field(default_factory=list)
    image: object | None = None
    raman_image: object | None = None
    ir_image: object | None = None
    subjects: list = field(default_factory=list)
    samples: list = field(default_factory=list)

    def write(self, path: str | Path, *, features: list[str] | None = None,
              provider: str = "hdf5", progress=None) -> Path:
        return SpectralDataset.write_minimal(
            path,
            title=self.title or "imported",
            isa_investigation_id=self.isa_investigation_id,
            runs=self.runs,
            genomic_runs=self.genomic_runs or None,
            identifications=self.identifications or None,
            quantifications=self.quantifications or None,
            provenance=self.provenance or None,
            features=features,
            provider=provider,
            image=self.image,
            raman_image=self.raman_image,
            ir_image=self.ir_image,
            subjects=self.subjects or None,
            samples=self.samples or None,
            progress=progress,
        )
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_imported_dataset.py -q`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/importers/imported_dataset.py python/tests/test_imported_dataset.py
git commit -m "feat(py-importers): add ImportedDataset normalized draft"
```

---

### Task P2: `Reader` / `Writer` protocols

**Files:**
- Create: `python/src/ttio/importers/base.py`
- Create: `python/src/ttio/exporters/base.py`
- Test: `python/tests/test_reader_writer_protocols.py`

`@runtime_checkable` protocols matching the existing `protocols/run.py` idiom.

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_reader_writer_protocols.py
from __future__ import annotations

from ttio.importers.base import Reader
from ttio.importers.imported_dataset import ImportedDataset
from ttio.exporters.base import Writer


class _OkReader:
    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        return ImportedDataset()


class _OkWriter:
    def write(self, ds, layer, output, opts) -> None:
        pass


class _NotReader:
    pass


def test_reader_protocol_membership():
    assert isinstance(_OkReader(), Reader)
    assert not isinstance(_NotReader(), Reader)


def test_writer_protocol_membership():
    assert isinstance(_OkWriter(), Writer)
    assert not isinstance(_NotReader(), Writer)
```

- [ ] **Step 2: Run it — expect ImportError**

Run: `.venv/bin/pytest tests/test_reader_writer_protocols.py -q`
Expected: ModuleNotFoundError (`importers.base`).

- [ ] **Step 3: Implement the protocols**

```python
# python/src/ttio/importers/base.py
"""``Reader`` — uniform importer interface. A reader parses one or more
source files into an in-memory :class:`ImportedDataset`; it does NOT
write any `.tio` file (the registry / caller calls ``.write()``).

Cross-language equivalents: Java ``importers.Reader``, Objective-C
``TTIOReader``.
"""
from __future__ import annotations

from typing import Mapping, Protocol, runtime_checkable

from .imported_dataset import ImportedDataset


@runtime_checkable
class Reader(Protocol):
    def read(self, inputs: list, opts: Mapping, progress=None) -> ImportedDataset:
        """Parse ``inputs`` into a draft. ``inputs[0]`` is the primary
        source; extra entries carry secondary files (e.g. imzML ``.ibd``).
        ``opts`` carries format-specific knobs (``reference``, ``ms2``,
        ``name``, ``sample``, ``encoding``)."""
        ...
```

```python
# python/src/ttio/exporters/base.py
"""``Writer`` — uniform exporter interface. A writer serializes one
layer of an *opened* :class:`SpectralDataset` to an output path. The
registry / caller owns opening the `.tio` and selecting the run.

Cross-language equivalents: Java ``exporters.Writer``, Objective-C
``TTIOWriter``.
"""
from __future__ import annotations

from typing import Mapping, Protocol, runtime_checkable

from ..spectral_dataset import SpectralDataset


@runtime_checkable
class Writer(Protocol):
    def write(self, ds: SpectralDataset, layer: str | None, output: str,
              opts: Mapping) -> None:
        ...
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `.venv/bin/pytest tests/test_reader_writer_protocols.py -q`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/importers/base.py python/src/ttio/exporters/base.py python/tests/test_reader_writer_protocols.py
git commit -m "feat(py): add Reader/Writer protocols"
```

---

### Task P3: `ImportResult` → `ImportedDataset` bridge

**Files:**
- Modify: `python/src/ttio/importers/import_result.py`
- Test: `python/tests/test_import_result_bridge.py`

`ImportResult` stays the spectral-parse intermediate; give it `to_imported_dataset()` and reroute its `to_ttio()` through it (back-compat preserved). Do the same for `mztab.MzTabImport` and `imzml.ImzMLImport`, which carry their own `to_ttio`.

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_import_result_bridge.py
from __future__ import annotations

import numpy as np

from ttio.importers.import_result import ImportResult, ImportedSpectrum
from ttio.importers.imported_dataset import ImportedDataset


def _result() -> ImportResult:
    r = ImportResult(title="x", isa_investigation_id="TTIO:x")
    r.ms_spectra.append(ImportedSpectrum(
        mz_or_chemical_shift=np.linspace(100.0, 105.0, 5),
        intensity=np.linspace(1.0, 50.0, 5), retention_time=0.5, ms_level=1))
    return r


def test_to_imported_dataset_carries_runs():
    ds = _result().to_imported_dataset()
    assert isinstance(ds, ImportedDataset)
    assert "run_0001" in ds.runs
    assert ds.title == "x"


def test_to_ttio_still_round_trips(tmp_path):
    from ttio import SpectralDataset
    out = tmp_path / "r.tio"
    _result().to_ttio(out)
    with SpectralDataset.open(out) as d:
        assert d.ms_runs
```

- [ ] **Step 2: Run it — expect AttributeError (`to_imported_dataset` missing)**

Run: `.venv/bin/pytest tests/test_import_result_bridge.py -q`
Expected: FAIL — `ImportResult` has no `to_imported_dataset`.

- [ ] **Step 3: Add `to_imported_dataset()` and reroute `to_ttio()`**

In `python/src/ttio/importers/import_result.py`, add the import and method, and replace the body of `to_ttio` to delegate. Insert this method on `ImportResult` (above `to_ttio`):

```python
    def to_imported_dataset(self) -> "ImportedDataset":
        from .imported_dataset import ImportedDataset
        return ImportedDataset(
            title=self.title or "imported",
            isa_investigation_id=self.isa_investigation_id,
            runs=self.build_runs(),
            identifications=list(self.identifications),
            quantifications=list(self.quantifications),
            provenance=list(self.provenance),
        )
```

Then replace the existing `to_ttio` body (the `runs = self.build_runs()` … `return SpectralDataset.write_minimal(...)` block) with:

```python
        return self.to_imported_dataset().write(path, features=features,
                                                provider=provider)
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `.venv/bin/pytest tests/test_import_result_bridge.py -q`
Expected: 2 passed.

- [ ] **Step 5: Repeat the bridge for `MzTabImport` and `ImzMLImport`**

In `python/src/ttio/importers/mztab.py` (`MzTabImport`, `to_ttio` at ~:101) and `python/src/ttio/importers/imzml.py` (`ImzMLImport`, `to_ttio` at ~:130), add a `to_imported_dataset(self) -> ImportedDataset` that builds the draft from the same fields their current `to_ttio` passes to `write_minimal` (runs/genomic_runs/image/metadata), then reduce their `to_ttio` to `return self.to_imported_dataset().write(path, ...)`. Preserve every keyword they currently pass (imzML passes `image=`; mzTab passes identifications/quantifications). Keep their existing per-class round-trip tests green.

- [ ] **Step 6: Run the affected existing tests**

Run: `.venv/bin/pytest tests/test_mztab_writer.py tests/test_imzml_writer.py tests/integration/test_mztab_import.py tests/integration/test_imzml_import.py -q`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add python/src/ttio/importers/import_result.py python/src/ttio/importers/mztab.py python/src/ttio/importers/imzml.py python/tests/test_import_result_bridge.py
git commit -m "feat(py-importers): bridge result objects to ImportedDataset"
```

---

### Task P4: Bruker reader returns a draft (the one inline-writing importer)

**Files:**
- Modify: `python/src/ttio/importers/bruker_tdf.py`
- Test: `python/tests/test_bruker_reader_dataset.py` (skipped if no fixture/tool)

Bruker is the spec's top risk: `read(input, output, ms2=)` currently calls `write_minimal` inline (~:256). Extract the run-building into `read_dataset(input, *, ms2=False, progress=None) -> ImportedDataset`; make `read` delegate.

- [ ] **Step 1: Read `bruker_tdf.py` around the `write_minimal` call**

Run: `sed -n '230,270p' python/src/ttio/importers/bruker_tdf.py`
Identify the run-dict + metadata assembled just before `SpectralDataset.write_minimal(...)`.

- [ ] **Step 2: Add `read_dataset` and delegate `read`**

Introduce `def read_dataset(path, *, ms2=False, progress=None) -> ImportedDataset:` containing everything up to (but not including) the `write_minimal` call, returning `ImportedDataset(title=..., isa_investigation_id=..., runs=..., genomic_runs=...)` with the exact same field values currently passed to `write_minimal`. Then:

```python
def read(path, output, *, ms2=False, progress=None):
    return read_dataset(path, ms2=ms2, progress=progress).write(output, progress=progress)
```

(Match the current `read` signature exactly — adjust the example to the real one found in Step 1.)

- [ ] **Step 3: Guarded test (tool/fixture may be absent)**

```python
# python/tests/test_bruker_reader_dataset.py
import pytest
from ttio.importers import bruker_tdf
from ttio.importers.imported_dataset import ImportedDataset

pytestmark = pytest.mark.skipif(
    not hasattr(bruker_tdf, "read_dataset"), reason="read_dataset not present")


def test_read_dataset_signature_exists():
    assert callable(bruker_tdf.read_dataset)
```

- [ ] **Step 4: Run the existing Bruker tests (whatever exists)**

Run: `.venv/bin/pytest -q -k bruker`
Expected: pass or skipped (no regression).

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/importers/bruker_tdf.py python/tests/test_bruker_reader_dataset.py
git commit -m "refactor(py-importers): Bruker read_dataset returns a draft"
```

---

### Task P5: Reader classes for every format

**Files:**
- Create: `python/src/ttio/importers/readers.py`
- Test: `python/tests/test_format_readers.py`

One small `Reader`-conforming class per format, each returning `ImportedDataset`. These replace the registry's adapter lambdas (Task P7 wires them in). Lazy imports keep optional deps out of import time (matching the current adapters).

- [ ] **Step 1: Write the failing test (mzML round-trip via the class)**

```python
# python/tests/test_format_readers.py
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.importers.base import Reader
from ttio.importers.imported_dataset import ImportedDataset
from ttio.importers import readers


def _write_mzml(tmp_path: Path) -> Path:
    from ttio.exporters import mzml as w
    src = tmp_path / "s.tio"
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.tile(np.linspace(100.0, 102.5, 6), 3),
                      "intensity": np.tile(np.linspace(1.0, 100.0, 6), 3)},
        offsets=np.arange(3, dtype=np.uint64) * 6,
        lengths=np.full(3, 6, dtype=np.uint32),
        retention_times=np.linspace(0.0, 2.0, 3, dtype=np.float64),
        ms_levels=np.ones(3, dtype=np.int32),
        polarities=np.ones(3, dtype=np.int32),
        precursor_mzs=np.zeros(3, dtype=np.float64),
        precursor_charges=np.zeros(3, dtype=np.int32),
        base_peak_intensities=np.full(3, 100.0, dtype=np.float64))
    SpectralDataset.write_minimal(src, title="t", isa_investigation_id="",
                                  runs={"run_0001": run})
    p = tmp_path / "s.mzML"
    with SpectralDataset.open(src) as ds:
        w.write_dataset(ds, p, zlib_compression=False)
    return p


def test_mzml_reader_returns_draft(tmp_path):
    r = readers.MzMLReader()
    assert isinstance(r, Reader)
    ds = r.read([_write_mzml(tmp_path)], {})
    assert isinstance(ds, ImportedDataset)
    assert ds.runs


def test_mzml_reader_round_trips(tmp_path):
    out = tmp_path / "o.tio"
    readers.MzMLReader().read([_write_mzml(tmp_path)], {}).write(out)
    with SpectralDataset.open(out) as ds:
        assert ds.ms_runs
```

- [ ] **Step 2: Run it — expect ImportError (`readers` missing)**

Run: `.venv/bin/pytest tests/test_format_readers.py -q`
Expected: ModuleNotFoundError.

- [ ] **Step 3: Implement the reader classes**

Each wraps the existing module exactly as the current adapter did (see `importers/registry.py` for the canonical per-format call). `progress` flows from `opts`.

```python
# python/src/ttio/importers/readers.py
"""Per-format :class:`Reader` implementations. Each parses its source
into an :class:`ImportedDataset`; lazy module imports keep optional
dependencies off the import path.
"""
from __future__ import annotations

from typing import Mapping

from .imported_dataset import ImportedDataset


def _progress(opts: Mapping):
    p = opts.get("progress")
    return {"progress": p} if p is not None else {}


class _ImportResultReader:
    """mzML / mzTab / nmrML / Thermo / Waters: module ``read()`` returns a
    result object exposing ``to_imported_dataset()``."""
    _module = ""

    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        import importlib
        mod = importlib.import_module(f"ttio.importers.{self._module}")
        opts = {**dict(opts), **({"progress": progress} if progress else {})}
        result = mod.read(inputs[0], **_progress(opts))
        return result.to_imported_dataset()


class MzMLReader(_ImportResultReader):
    _module = "mzml"


class MzTabReader(_ImportResultReader):
    _module = "mztab"


class NmrMLReader(_ImportResultReader):
    _module = "nmrml"


class ThermoRawReader(_ImportResultReader):
    _module = "thermo_raw"


class WatersMassLynxReader(_ImportResultReader):
    _module = "waters_masslynx"


class ImzMLReader:
    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        from . import imzml
        ibd = opts.get("ibd")
        if ibd is None and len(inputs) > 1:
            ibd = inputs[1]
        kwargs = _progress({**dict(opts), **({"progress": progress} if progress else {})})
        return imzml.read(inputs[0], ibd_path=ibd, **kwargs).to_imported_dataset()


class BrukerReader:
    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        from . import bruker_tdf
        return bruker_tdf.read_dataset(
            inputs[0], ms2=bool(opts.get("ms2", False)), progress=progress)


class JcampDxReader:
    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        from pathlib import Path

        from . import jcamp_dx
        kwargs = _progress({**dict(opts), **({"progress": progress} if progress else {})})
        spectrum = jcamp_dx.read_spectrum(inputs[0], **kwargs)
        run = jcamp_dx.build_written_run(spectrum)
        return ImportedDataset(title=Path(inputs[0]).stem,
                               isa_investigation_id="",
                               runs={"run_0001": run})


class _GenomicReader:
    _attr = ""

    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        from . import bam, cram, sam
        cls = {"BamReader": bam.BamReader, "SamReader": sam.SamReader,
               "CramReader": cram.CramReader}[self._attr]
        name = opts.get("name", "genomic_0001")
        kwargs = {"progress": progress} if progress else {}
        run = cls(inputs[0]).to_genomic_run(
            name=name, sample_name=opts.get("sample"), **kwargs)
        return ImportedDataset(title="", isa_investigation_id="",
                               genomic_runs={name: run})


class BamReader(_GenomicReader):
    _attr = "BamReader"


class SamReader(_GenomicReader):
    _attr = "SamReader"


class CramReader(_GenomicReader):
    _attr = "CramReader"
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `.venv/bin/pytest tests/test_format_readers.py -q`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/importers/readers.py python/tests/test_format_readers.py
git commit -m "feat(py-importers): per-format Reader classes"
```

---

### Task P6: Writer classes for every exporter

**Files:**
- Create: `python/src/ttio/exporters/writers.py`
- Test: `python/tests/test_format_writers.py`

One `Writer`-conforming class per export format. They take an **opened** `SpectralDataset` + layer (the registry opens it in Task P7). The run-selection helpers (`_analytical_run`/`_nmr_run`/`_genomic_run`) move from `exporters/registry.py` into a shared `exporters/_select.py` so writers and the registry share one copy.

- [ ] **Step 1: Move run-selection helpers to `exporters/_select.py`**

Cut `_analytical_run`, `_nmr_run`, `_genomic_run` verbatim from `exporters/registry.py` into a new `python/src/ttio/exporters/_select.py` (module-level functions, same bodies). Leave the registry importing them from there in Task P7.

- [ ] **Step 2: Write the failing test (mzML writer via the class)**

```python
# python/tests/test_format_writers.py
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode
from ttio.exporters.base import Writer
from ttio.exporters import writers


def _ds(tmp_path: Path) -> Path:
    src = tmp_path / "s.tio"
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.linspace(100.0, 105.0, 6),
                      "intensity": np.linspace(1.0, 60.0, 6)},
        offsets=np.zeros(1, dtype=np.uint64),
        lengths=np.full(1, 6, dtype=np.uint32),
        retention_times=np.zeros(1, dtype=np.float64),
        ms_levels=np.ones(1, dtype=np.int32),
        polarities=np.ones(1, dtype=np.int32),
        precursor_mzs=np.zeros(1, dtype=np.float64),
        precursor_charges=np.zeros(1, dtype=np.int32),
        base_peak_intensities=np.full(1, 60.0, dtype=np.float64))
    SpectralDataset.write_minimal(src, title="t", isa_investigation_id="",
                                  runs={"run_0001": run})
    return src


def test_mzml_writer(tmp_path):
    w = writers.MzMLWriter()
    assert isinstance(w, Writer)
    out = tmp_path / "o.mzML"
    with SpectralDataset.open(_ds(tmp_path)) as ds:
        w.write(ds, None, str(out), {})
    assert out.exists() and out.stat().st_size > 0
```

- [ ] **Step 3: Run it — expect ImportError**

Run: `.venv/bin/pytest tests/test_format_writers.py -q`
Expected: ModuleNotFoundError (`exporters.writers`).

- [ ] **Step 4: Implement the writer classes**

Each body is the *inside* of the corresponding `_adapt_*` in the current `exporters/registry.py` (minus the `with SpectralDataset.open(...)`, which the registry now does). Bodies copied verbatim; only the dataset source changes from `open(tio_path)` to the passed `ds`.

```python
# python/src/ttio/exporters/writers.py
"""Per-format :class:`Writer` implementations. Each serializes one layer
of an opened :class:`SpectralDataset`. Run selection is shared via
``_select``."""
from __future__ import annotations

from typing import Mapping

from ..spectral_dataset import SpectralDataset
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
```

> Note: rename the moved helpers to public `analytical_run`/`nmr_run`/`genomic_run` in `_select.py` (drop the leading underscore) so writers + registry call the same names.

- [ ] **Step 5: Run the test — expect PASS**

Run: `.venv/bin/pytest tests/test_format_writers.py -q`
Expected: 1 passed.

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/exporters/_select.py python/src/ttio/exporters/writers.py python/tests/test_format_writers.py
git commit -m "feat(py-exporters): per-format Writer classes + shared run selection"
```

---

### Task P7: Rewire both registries onto the interfaces

**Files:**
- Modify: `python/src/ttio/importers/registry.py`
- Modify: `python/src/ttio/exporters/registry.py`

Replace the `adapter` callable field with a `Reader`/`Writer` instance; `encode`/`export` dispatch through it. **Preserve every public name and the key/alias/extension/required-tool tables verbatim.**

- [ ] **Step 1: Confirm the existing registry tests pass first (baseline)**

Run: `.venv/bin/pytest tests/workbench/test_encode_formats.py tests/workbench/test_export_formats.py -q`
Expected: all pass (pre-change baseline).

- [ ] **Step 2: Rewire `importers/registry.py`**

- Change `FormatSpec.adapter: Callable[..., None]` → `reader: "Reader"`.
- Replace each `_SPECS` entry's adapter with the matching `readers.*()` instance (keep `key`, `display_name`, `extensions`, `required_tool` identical):

```python
from .readers import (BamReader, BrukerReader, CramReader, ImzMLReader,
                      JcampDxReader, MzMLReader, MzTabReader, NmrMLReader,
                      SamReader, ThermoRawReader, WatersMassLynxReader)

_SPECS = (
    FormatSpec("mzml", "mzML", (".mzML", ".mzML.gz"), None, MzMLReader()),
    FormatSpec("mztab", "mzTab", (".mzTab", ".mztab"), None, MzTabReader()),
    FormatSpec("imzml", "imzML", (".imzML",), None, ImzMLReader()),
    FormatSpec("nmrml", "nmrML", (".nmrML",), None, NmrMLReader()),
    FormatSpec("jcamp-dx", "JCAMP-DX", (".jdx", ".dx", ".jcm"), None, JcampDxReader()),
    FormatSpec("bruker-timstof", "Bruker timsTOF", (".d",), "Bruker Python helper", BrukerReader()),
    FormatSpec("waters-masslynx", "Waters MassLynx", (".raw",), "masslynxraw", WatersMassLynxReader()),
    FormatSpec("thermo-raw", "Thermo .raw", (".raw",), "ThermoRawFileParser", ThermoRawReader()),
    FormatSpec("bam", "BAM", (".bam",), "samtools", BamReader()),
    FormatSpec("sam", "SAM", (".sam",), "samtools", SamReader()),
    FormatSpec("cram", "CRAM", (".cram",), "samtools", CramReader()),
)
```

- Replace `encode`'s body:

```python
def encode(fmt: str, inputs, output, **opts) -> None:
    spec = spec_for(fmt)
    progress = opts.pop("progress", None)
    spec.reader.read(list(inputs), opts, progress=progress).write(output)
```

Leave `CLI_DELEGATED`, `_ALIASES`, `normalize`, `is_registry_format`, `spec_for`, `registry_keys`, `supported_encode_formats`, `UnknownFormatError` exactly as-is.

- [ ] **Step 3: Rewire `exporters/registry.py`**

- Change `ExportSpec.adapter` → `writer: "Writer"`; import from `.writers`; replace each `_SPECS` entry with the matching writer instance (same keys/extensions/required_tool).
- Import the moved selection helpers from `._select` (delete the now-duplicated local copies).
- Replace `export`'s body to open the dataset once:

```python
def export(fmt: str, tio_path, layer, output, **opts) -> None:
    spec = spec_for(fmt)
    with SpectralDataset.open(tio_path) as ds:
        spec.writer.write(ds, layer, output, opts)
```

- [ ] **Step 4: Run the preserved registry + CLI tests — expect unchanged PASS**

Run: `.venv/bin/pytest tests/workbench/test_encode_formats.py tests/workbench/test_export_formats.py -q`
Expected: all pass, no edits to those test files.

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/importers/registry.py python/src/ttio/exporters/registry.py
git commit -m "refactor(py): registries dispatch via Reader/Writer interfaces"
```

---

### Task P8: Full-suite regression + CHANGELOG

**Files:**
- Modify: `python/CHANGELOG.md` *(if a Python-local changelog exists; otherwise root `CHANGELOG.md`)*

- [ ] **Step 1: Run the full importer/exporter + integration suite**

Run:
```bash
TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest \
  tests/test_importers.py tests/integration -q \
  tests/test_mzml_writer.py tests/test_mztab_writer.py tests/test_imzml_writer.py \
  tests/test_jcamp_tio_roundtrip.py tests/test_m88_cram_bam_round_trip.py \
  tests/test_m87_bam_importer.py tests/test_milestone27_isa_exporter.py \
  tests/workbench
```
Expected: all pass. Fix any regression in the implementation (not the tests) before proceeding.

- [ ] **Step 2: Run the whole Python suite**

Run: `TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q`
Expected: green (modulo pre-existing tool-gated skips).

- [ ] **Step 3: Add the `[Unreleased]` CHANGELOG entry**

Add under `## [Unreleased]`:

```markdown
### Changed — Importer/exporter dispatch unified behind Reader/Writer interfaces (Python)

Python importers now implement a uniform `Reader` protocol returning an
`ImportedDataset` draft (the single `SpectralDataset.write_minimal` call site),
and exporters a uniform `Writer` protocol over an opened dataset. The
importer/exporter registries dispatch through these interfaces instead of
per-format adapter callables; run-selection helpers are shared. No `.tio`
wire/on-disk change; supported formats, aliases, and the `ttio encode`/`export`
CLI are unchanged. First of the 3-SDK P2.6 parity ports (Java + ObjC follow).
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for Python importer/exporter registry refactor"
```

---

## Self-review notes (author)

- **Spec coverage:** ImportedDataset draft (P1) ✓ · Reader/Writer interfaces (P2) ✓ · collapse adapter callables (P5/P6/P7) ✓ · preserve registry surface + CLI (P7) ✓ · invariants guarded by the unchanged workbench + integration tests (P8) ✓. CLI *addition* and tio-browser delegation are Java-PR scope (correctly deferred per the spec's per-language delivery).
- **Type consistency:** `ImportedDataset` fields match `write_minimal` kwargs; `Reader.read(inputs, opts, progress)` / `Writer.write(ds, layer, output, opts)` used identically in readers/writers (P5/P6) and registries (P7); `_select.{analytical_run,nmr_run,genomic_run}` names consistent between P6 and P7.
- **Risk watch:** Bruker (P4) is the only behavior-bearing extraction — its existing tests gate it. `ImportResult`/`MzTabImport`/`ImzMLImport` keep working `to_ttio` (back-compat). If any importer's `read()` does not return an object with `to_imported_dataset()` (or build a draft directly), the implementer must BLOCK rather than silently change write output.
