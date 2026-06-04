# Shared `Image` Base — Python (PR-1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Python slice of P2.5: extract a shared `Image` base (lift the common fields/logic out of `MSImage`/`RamanImage`/`IRImage`), add an `ImageKind` discriminator + generic `spectral_axis`, and **replace** `SpectralDataset`'s three typed accessors (`image`/`raman_image`/`ir_image`) with a uniform `images` collection + `image_for_kind`. Migrate every Python consumer.

**Architecture:** `Image` is an in-memory abstraction only — each subclass keeps its own on-disk group (`/study/image_cube`, `/study/raman_image_cube`, `/study/ir_image_cube`) + its own `read_from`/`write_to`. No `.tio` wire change, no transport protocol change.

**Tech Stack:** Python 3.12, dataclasses (`slots=True`), numpy. Test: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args>`.

**Hard invariants:**
- **No `.tio` wire change** — each image's `read_from`/`write_to` bytes + group names byte-identical (the base just holds the common fields the same attributes already named). Guarded by image round-trip fences.
- **No transport protocol change** — the Python transport walker/visitor `visit_image`/`visit_raman_image`/`visit_ir_image` stay; the walker sources images via `image_for_kind` instead of the removed accessor. Transport conformance fixtures unchanged.
- **Breaking accessor swap is total** — a missed `ds.image`/`ds.raman_image`/`ds.ir_image` site fails tests (no silent pass).

**Reference:** spec `docs/superpowers/specs/2026-06-04-shared-image-base-design.md`. Classes: `python/src/ttio/{ms_image,raman_image,ir_image}.py`. Accessors: `spectral_dataset.py:~473-535`. Enums: `enums.py` (IRMode at `:167`).

**Verified facts:**
- `MSImage` (`ms_image.py:9`) is `@dataclass(slots=True)`, ALL fields default: `width,height,spectral_points,pixel_size_x,pixel_size_y,intensity,mz_axis,scan_pattern,tile_size,title,isa_investigation_id,identifications,quantifications,provenance_records`. Field name is `intensity` (NOT `intensity_cube`). `__post_init__` validates shape. `RamanImage`/`IRImage` mirror with distinct fields (Raman: `wavenumbers,excitation_wavelength_nm,laser_power_mw`; IR: `wavenumbers,mode,resolution_cm_inv`).
- `SpectralDataset` accessors are lazy properties caching per kind (`_image_cache`/`_raman_image_cache`/`_ir_image_cache` + `_..._loaded` flags), reading via `MSImage.read_from(study)` etc. (`spectral_dataset.py:473-535`).
- Python consumers of the dataset accessors (verified): `exporters/writers.py:49` (`ds.image`), `tools/transport_encode_cli.py:51` (`ds.image`), `transport/codec.py:804` (docstring), the Python transport **walker** (find it — Java's is `DatasetWalker`; Python equiv in `transport/`), and tests. NOTE: `importers/imported_dataset.py:50-52` (`self.image`/`raman_image`/`ir_image`) are the DRAFT's OWN fields feeding `write_minimal(image=…)` — they are NOT dataset accessors and STAY. `transport/server.py:359-367` uses `event.image` (transport event, not the dataset accessor) — verify, likely STAYS.

---

### Task IPT1: `ImageKind` enum + `Image` base + subclass the three image classes

**Files:**
- Create: `python/src/ttio/image.py`
- Modify: `python/src/ttio/enums.py`, `python/src/ttio/{ms_image,raman_image,ir_image}.py`
- Test: `python/tests/test_image_base.py`

- [ ] **Step 1: Study** the full bodies of `ms_image.py`, `raman_image.py`, `ir_image.py` — fields, `__post_init__`, `read_from`/`write_to`/`to_pixel_spectra`, and any shared helper logic. Grep ALL construction sites: `grep -rn "MSImage(\|RamanImage(\|IRImage(" python/src python/tests` — confirm they construct by KEYWORD (all-defaults dataclasses); flag any positional construction (would break under field reordering).
- [ ] **Step 2: Write the fence test** `test_image_base.py`:
  - For each kind, construct a populated image, `write_to(study)` into an in-memory/HDF5 group, `read_from(study)`, assert the round-trip is byte/field-identical (cube, axis, all metadata) — establishes the no-wire-change baseline. Run against CURRENT code first (must pass).
  - Assert (after impl) `isinstance(MSImage(...), Image)`, `MSImage(...).kind == ImageKind.MS`, `.spectral_axis is .mz_axis` (MS) / `is .wavenumbers` (Raman/IR), `.spectral_axis_kind == SpectralAxisKind.MZ`/`WAVENUMBER`.
- [ ] **Step 3: Add enums** to `enums.py`:
  ```python
  class ImageKind(IntEnum):
      MS = 0
      RAMAN = 1
      IR = 2

  class SpectralAxisKind(IntEnum):
      MZ = 0
      WAVENUMBER = 1
  ```
- [ ] **Step 4: Create `image.py`** — the base dataclass holding the COMMON fields (all default; same names/order the subclasses use for the common ones):
  ```python
  from __future__ import annotations
  from dataclasses import dataclass, field
  from typing import ClassVar
  import numpy as np
  from .enums import ImageKind, SpectralAxisKind

  @dataclass(slots=True)
  class Image:
      """Shared base for MSImage/RamanImage/IRImage: common geometry,
      intensity cube, and dataset-level metadata. Each subclass adds its
      distinct fields + its own on-disk group + read_from/write_to."""
      width: int = 0
      height: int = 0
      spectral_points: int = 0
      pixel_size_x: float = 0.0
      pixel_size_y: float = 0.0
      intensity: np.ndarray = field(default_factory=lambda: np.zeros((0, 0, 0)))
      scan_pattern: str = ""
      tile_size: int = 0
      title: str = ""
      isa_investigation_id: str = ""
      identifications: list = field(default_factory=list)
      quantifications: list = field(default_factory=list)
      provenance_records: list = field(default_factory=list)

      # Subclasses set these.
      kind: ClassVar[ImageKind]
      @property
      def spectral_axis(self) -> np.ndarray: raise NotImplementedError
      @property
      def spectral_axis_kind(self) -> SpectralAxisKind: raise NotImplementedError
  ```
  (Confirm the common field set + order exactly matches what the three classes currently declare for those fields; `intensity` stays the name.)
- [ ] **Step 5: Subclass the three image classes** — each `@dataclass(slots=True) class MSImage(Image):` adding ONLY its distinct fields (`mz_axis` for MS; `wavenumbers`+`excitation_wavelength_nm`+`laser_power_mw` for Raman; `wavenumbers`+`mode`+`resolution_cm_inv` for IR), removing the now-inherited common fields. Add `kind: ClassVar = ImageKind.MS` (etc.) and override `spectral_axis`/`spectral_axis_kind` (MS → `mz_axis`/MZ; Raman/IR → `wavenumbers`/WAVENUMBER). Keep each class's `__post_init__`, `read_from`, `write_to`, `to_pixel_spectra`, and group name UNCHANGED (they reference the same attribute names, now inherited). VERIFY the dataclass-inheritance field order doesn't break keyword construction (all defaults → fine; positional sites from Step 1 fixed to keyword).
- [ ] **Step 6: Run** the fence + existing image tests:
  `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_image_base.py -q -k "image" ` and the existing image round-trip tests (`grep -rln "MSImage\|RamanImage\|IRImage" python/tests | head`). All green, byte-identical round-trips.
- [ ] **Step 7: Commit** `refactor(py-image): extract Image base + ImageKind from MS/Raman/IR images`.

---

### Task IPT2: `SpectralDataset` collection + migrate all Python consumers

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py` (remove 3 accessors; add `images`/`image_for_kind`)
- Modify: the Python consumers (transport walker, `exporters/writers.py`, `tools/transport_encode_cli.py`, docstrings)
- Test: `python/tests/test_spectral_dataset_images.py` + migrate existing tests

- [ ] **Step 1: Inventory** every consumer: `grep -rn "\.image\b\|\.raman_image\b\|\.ir_image\b" python/src/ttio python/tests | grep -vE "def (image|raman_image|ir_image)|imported_dataset|event\.image|self\.image =|write_minimal|ms_image\.py|raman_image\.py|ir_image\.py|\.image_cube"` — classify each as a `SpectralDataset` accessor (migrate) vs the draft/event field (leave). Find the Python transport walker (`grep -rln "visit_image\|DatasetWalker\|walk" python/src/ttio/transport`).
- [ ] **Step 2: Write the test** `test_spectral_dataset_images.py`: build/open a `.tio` with an MSImage (+ optionally raman/ir); assert `ds.image_for_kind(ImageKind.MS)` returns the image (and `None` for absent kinds), `ds.images` is a dict containing only present kinds, lazy materialization works (no error before access). Also assert the OLD accessors are GONE (`assert not hasattr(ds, "image")` — or that calling them raises AttributeError) to prove the replacement.
- [ ] **Step 3: Implement on `SpectralDataset`** — remove the `image`/`raman_image`/`ir_image` properties; add:
  ```python
  def image_for_kind(self, kind: "ImageKind") -> "Image | None":
      # reuse the existing per-kind lazy caches; dispatch by kind
      if kind == ImageKind.MS: return self._lazy_ms_image()
      if kind == ImageKind.RAMAN: return self._lazy_raman_image()
      if kind == ImageKind.IR: return self._lazy_ir_image()
      raise ValueError(...)

  @property
  def images(self) -> "dict[ImageKind, Image]":
      out = {}
      for k in (ImageKind.MS, ImageKind.RAMAN, ImageKind.IR):
          img = self.image_for_kind(k)
          if img is not None: out[k] = img
      return out
  ```
  Move the existing lazy-read bodies into private `_lazy_ms_image()`/etc. helpers (preserving the `_image_cache`/loaded-flag logic verbatim). Keep behavior identical.
- [ ] **Step 4: Migrate consumers** — each `ds.image` → `ds.image_for_kind(ImageKind.MS)`, `.raman_image` → `image_for_kind(ImageKind.RAMAN)`, `.ir_image` → `image_for_kind(ImageKind.IR)`: `exporters/writers.py:49`, `tools/transport_encode_cli.py:51`, the transport walker (Step 1), and any docstring (`transport/codec.py:804`). Do NOT touch `imported_dataset.py` (draft fields) or `transport/server.py` event fields (verify they're events, not dataset accessors).
- [ ] **Step 5: Migrate tests** — every test asserting `ds.image`/`ds.raman_image`/`ds.ir_image` → `ds.image_for_kind(...)`.
- [ ] **Step 6: Run** the dataset/transport/exporter image tests + the transport conformance:
  `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_spectral_dataset_images.py tests/ -q -k "image or transport or imzml"` — green; the transport conformance (walker/visitor) unchanged.
- [ ] **Step 7: Commit** `refactor(py): replace SpectralDataset image accessors with images()/image_for_kind`.

---

### Task IPT3: Full regression + CHANGELOG

- [ ] **Step 1: Full Python suite** (codec + genomic + transport + image + importer/exporter):
  `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q 2>&1 | tail -25`
  Green except the known cross-language Java/ObjC integration failures (JDK 21-vs-22 `UnsupportedClassVersionError` — confirm every failure is that signature, NOT an image regression). A non-Java-version failure = STOP/BLOCKED.
- [ ] **Step 2: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Changed — Shared Image base + uniform image collection (Python)

  `MSImage`/`RamanImage`/`IRImage` now share an `Image` base (common geometry,
  intensity cube, metadata) with an `ImageKind` discriminator and a generic
  `spectral_axis`. `SpectralDataset`'s `image`/`raman_image`/`ir_image` accessors
  are replaced by `images` (collection) + `image_for_kind(kind)`. No `.tio`
  wire/format change; each image keeps its own on-disk group + I/O. First of the
  3-SDK P2.5 ports (Java + tio-browser and ObjC follow). (OO-assessment P2.5.)
  ```
- [ ] **Step 3: Commit** `docs: changelog for Python shared Image base (P2.5)`.

---

## Self-review notes (author)
- **No wire change** — the base extraction only relocates the common dataclass fields; each subclass's `read_from`/`write_to`/group name is untouched. The IPT1 round-trip fence (byte/field-identical) proves it.
- **No transport protocol change** — the walker/visitor methods stay; only the dataset accessor the walker calls changes (`image_for_kind`). Transport conformance fixtures are the fence.
- **Breaking swap is safe** — Python tests fail on any missed accessor (Step 2's `hasattr` assertion + the migrated consumers). The draft (`imported_dataset`) + transport events are intentionally NOT migrated (they're not dataset accessors).
- **Field-order/positional risk** — all-defaults dataclasses + keyword construction make base-extraction non-breaking; IPT1 Step 1 greps for + fixes any positional construction.
- This is the Python PR; Java+tio-browser and ObjC are separate follow-on PRs (own plans).
