# Shared `Image` Base + Uniform Image Collection — Design (P2.5)

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending implementation plan(s)
**Scope owner:** image subsystem, all three SDKs + tio-browser
**Origin:** Recommendation **P2.5** of the OO design assessment
(`docs/architecture/2026-06-02-oo-design-assessment.md`) — the audit's named
**#2 highest-value abstraction win** (after the codec registry). Follows the
codec-registry (P1.1) and importer/exporter-registry (P2.6) parity sweeps.

## Background

`MSImage` / `RamanImage` / `IRImage` share **no base** in any SDK, yet they
overlap heavily. Java field audit (Python/ObjC mirror it):

- **Common to all three** (the shared-base candidate): `width`, `height`,
  `spectralPoints`, `tileSize`, `pixelSizeX`, `pixelSizeY`, `scanPattern`,
  `intensityCube` (`double[]`), the **spectral axis** (`mzAxis` for MS,
  `wavenumbers` for Raman/IR — both `double[]`), and the metadata block
  (`title`, `isaInvestigationId`, `identifications`, `quantifications`,
  `provenanceRecords`).
- **Distinct:** MS adds `mzAxis`; Raman adds `excitationWavelengthNm` +
  `laserPowerMw`; IR adds `mode` (`IRMode`) + `resolutionCmInv`. Raman and IR
  are ~75% identical.

They are surfaced as **three parallel accessors** on `SpectralDataset`
(`image()`/`raman_image()`/`ir_image()`; ObjC `msImage`/`ramanImage`/`irImage`)
rather than a uniform collection, and each is consumed pointwise across the
transport, exporter, GUI, and CLI layers.

Each image writes to a **distinct on-disk group** — `/study/image_cube`,
`/study/raman_image_cube`, `/study/ir_image_cube`. **This is the wire contract
and does not change**: the shared base is an in-memory abstraction only; each
subclass keeps its own group name + `writeTo`/`readFrom`.

## Goals

1. Extract a shared abstract **`Image`** base in each SDK holding the common
   geometry + cube + spectral axis + metadata, with a `kind()` discriminator and
   a generic `spectralAxis()` accessor. `MSImage`/`RamanImage`/`IRImage` extend
   it, retaining their distinct fields and their own on-disk group + I/O.
2. **Replace** the three typed `SpectralDataset` accessors with a **uniform
   image collection** + a typed get-by-kind, across all three SDKs.
3. Migrate every consumer (transport walker/writer, exporter adapters, GUI, CLI,
   importer draft, tests) to the new surface — mechanically, with no behavior
   change.

## Non-goals / hard invariants

- **No `.tio` wire/on-disk change.** Each image's group name, dataset layout,
  attributes, and bytes are byte-identical; `writeTo`/`readFrom` per subclass
  unchanged. Verified by image round-trip + cross-language conformance fixtures.
- **No transport wire/protocol change.** The transport **Visitor contract stays
  as-is** — `visitImage` / `visitRamanImage` / `visitIRImage` remain three
  methods; the `DatasetWalker` simply sources each image via the new collection
  (`imageForKind(...)`) instead of the removed typed accessor. The
  AccessUnit/packet bytes are unchanged.
- **No new image semantics** — the base is pure extraction; no field added to
  the on-disk form. `spectralAxisKind` is an in-memory label only.
- Out of scope: a `VibrationalImage` Raman/IR intermediate (brainstorm chose a
  single base → all three); `PixelSpectrum`/imzML pixel types; the codec/importer
  subsystems (done).

## Architecture

### The `Image` abstract base (per SDK)

- **Common state** (held/abstracted by the base): width, height, spectralPoints,
  tileSize, pixelSizeX, pixelSizeY, scanPattern, intensityCube, the spectral
  axis, and the metadata block.
- **Discriminator:** `ImageKind` enum — `MS`, `RAMAN`, `IR`. `image.kind()`
  returns it. Used for the collection key + typed get.
- **Generic spectral axis:** `spectralAxis()` → `double[]` (returns `mzAxis` for
  MS, `wavenumbers` for Raman/IR) + `spectralAxisKind` → enum (`MZ` /
  `WAVENUMBER`). Subclasses keep their semantic accessor names too (`mzAxis()`,
  `wavenumbers()`) for clarity / existing callers within a subclass.
- **Per-SDK form:**
  - **Java:** `public abstract class Image` (in `genomics`-style package — place
    next to the image classes) with the common final fields + protected
    constructor + `abstract ImageKind kind()` (or a concrete field). `MSImage`/
    `RamanImage`/`IRImage extends Image`. Each keeps its own `GROUP_NAME` +
    `writeTo`/`readFrom`. `ImageKind` is a new top-level enum.
  - **Python:** a base `Image` class in `ttio/image.py` (plain base class; the
    three modules `ms_image.py`/`raman_image.py`/`ir_image.py` subclass it).
    `ImageKind` an `IntEnum`/`Enum` in `ttio/enums.py`. `spectral_axis` property
    + `spectral_axis_kind`.
  - **ObjC:** `@interface TTIOImage : NSObject` base in `Image/TTIOImage.{h,m}`
    with the common readonly props + a `kind` (typedef `TTIOImageKind` enum) +
    `spectralAxis`. `TTIOMSImage`/`TTIORamanImage`/`TTIOIRImage : TTIOImage`.
    Triple-surface GNUmakefile/test registration.

### `SpectralDataset` collection (breaking — replaces the typed accessors)

Remove `image()`/`raman_image()`/`ir_image()` (ObjC `msImage`/`ramanImage`/
`irImage`); add:

- `images()` — the present images as a collection. Shape per SDK: Java
  `Map<ImageKind, Image>` (or `List<Image>`); Python `dict[ImageKind, Image]`;
  ObjC `NSArray<TTIOImage *> *` (or `NSDictionary<NSNumber*, TTIOImage*>`). Only
  present images appear (lazily materialized like the current accessors).
- `imageForKind(kind)` — typed getter returning the `Image` of that kind or
  null/None/nil. (Java may add typed convenience casts if ergonomic, but the
  canonical API is `imageForKind`.)

Lazy materialization preserved (the current accessors lazily read the group on
first access — the collection does the same; cache per kind).

### Consumer migration (mechanical, no behavior change)

Every `dataset.image()` → `dataset.imageForKind(MS)`, `.ramanImage()` →
`imageForKind(RAMAN)`, `.irImage()` → `imageForKind(IR)`. Inventory (verified):

- **Transport** (each SDK): `DatasetWalker` (visits each image then calls the
  unchanged `visit{Image,RamanImage,IRImage}`), `TransportWriter` (the
  has-image checks + `writeImage`/`writeRamanImage`/`writeIRImage`).
- **Exporters/adapters:** Python `exporters/writers.py` (imzML `img = ds.image`),
  Java `exporters/writers/ImzMLWriterAdapter` (`ds.image()`), ObjC
  `Export/TTIOWriterAdapters.m` (`dataset.msImage`).
- **Importer draft:** Python `importers/imported_dataset.py` builds the draft
  from `image`/`raman_image`/`ir_image` fields — these are draft fields written
  via `write_minimal(image=, raman_image=, ir_image=)`, NOT `SpectralDataset`
  accessors, so they stay (the draft is a separate in-memory bundle). Confirm
  `write_minimal`/`create`'s image params are unaffected (they take image
  objects, not the dataset accessors).
- **tio-browser:** `ExportTask` (imzML eligibility `dataset.image() == null`),
  `ExportEligibility` (`d.dataset().image() != null`).
- **CLI:** Python `transport_encode_cli.py` (`ds.image`), Java
  `TransportEncodeCli` (`ds.image()`); ObjC equivalents.
- **Tests:** every test asserting `ds.image()`/etc. migrates to `imageForKind`.

## Cross-language parity

- Identical `ImageKind` value set (`MS`/`RAMAN`/`IR`) + `spectralAxisKind`
  (`MZ`/`WAVENUMBER`) across SDKs; identical `images()`/`imageForKind` surface
  shape (allowing for idiomatic container types). A small parity note/test
  asserts the kind set matches.
- The base's common-field accessor names match the existing per-type accessor
  names (width/height/spectralPoints/…), so subclass callers are unaffected.

## Testing

- **Per SDK:** an image round-trip test per kind (write → reopen → assert
  byte-identical cube/axis/metadata) — already exists in spirit; ensure it runs
  through the new base + collection. A `SpectralDataset.images()` /
  `imageForKind` test (present/absent kinds, all three, lazy materialization).
- **Transport conformance:** the existing AccessUnit/walker/visitor cross-language
  fixtures must stay green unchanged (the Visitor contract + wire bytes are
  untouched) — this is the no-protocol-change fence.
- **No-wire-change fence:** existing image `.tio` fixtures reopen byte-identical;
  cross-language image conformance unchanged.

## Delivery

Per-SDK PRs (mirrors the registry sweeps), each independently green:

1. **Python** — `Image` base + `ImageKind` + `images()`/`image_for_kind`;
   migrate Python consumers (transport, exporters, CLI, tests). (This PR also
   carries this spec.)
2. **Java + tio-browser** — `Image` base + `ImageKind` + `images()`/
   `imageForKind`; migrate Java consumers (transport, exporter adapter, CLI) AND
   tio-browser (`ExportTask`/`ExportEligibility`); keep the jacoco ≥0.84 gate.
3. **Objective-C** — `TTIOImage` base + `TTIOImageKind` + `images`/
   `imageForKind:`; migrate ObjC consumers (transport, exporter adapter); triple-
   surface registration.

Each: build/test in the SDK's toolchain (Python pytest with `TTIO_RANS_LIB_PATH`;
`JAVA_HOME=~/jdk25 mvn` — full `verify` for the gate; `objc/build.sh check`),
push from Windows git, CI cross-language conformance is the gate. Subagent-driven,
two-stage review per task.

## Risks

- **Breaking accessor removal** (highest blast radius): many mechanical call-site
  migrations across transport/exporter/GUI/CLI/tests in 3 SDKs. Mitigation:
  per-SDK PRs; the transport **Visitor contract is preserved** (walker sources
  images differently, no protocol change); compiler/tests catch every missed
  site (Java/ObjC fail to build; Python tests fail) — a missed accessor cannot
  silently pass.
- **Lazy-materialization equivalence:** `images()`/`imageForKind` must preserve
  the current lazy-read + per-kind caching so behavior + handle usage are
  unchanged.
- **No-wire-change:** the base extraction must not alter any subclass's
  `writeTo`/`readFrom` bytes or group names — guarded by image round-trip +
  conformance fences.

## File structure (Python PR, indicative)

| File | Change | Responsibility |
|---|---|---|
| `python/src/ttio/image.py` | Create | `Image` base (+ `spectral_axis`) |
| `python/src/ttio/enums.py` | Modify | `ImageKind`, `SpectralAxisKind` |
| `python/src/ttio/{ms_image,raman_image,ir_image}.py` | Modify | subclass `Image`; add `kind`/`spectral_axis` |
| `python/src/ttio/spectral_dataset.py` | Modify | remove 3 accessors; add `images`/`image_for_kind` |
| `python/src/ttio/transport/{codec,server}.py`, `tools/transport_encode_cli.py`, `exporters/writers.py` | Modify | migrate to `image_for_kind` |
| tests touching `ds.image`/etc. | Modify | migrate |
| `CHANGELOG.md` | Modify | `[Unreleased]` |
