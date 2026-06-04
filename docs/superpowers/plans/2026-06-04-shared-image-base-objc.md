# Shared `TTIOImage` Base — Objective-C (PR-3, final) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** ObjC slice of P2.5 (the **final** SDK; mirrors merged Python #219 + Java #220). Extract an abstract `TTIOImage` base from `TTIOMSImage`/`TTIORamanImage`/`TTIOIRImage` (+ `TTIOImageKind`/`TTIOSpectralAxisKind`, a generic `spectralAxis`), replace `TTIOSpectralDataset`'s `msImage`/`ramanImage`/`irImage` properties with `-imageForKind:` + `-images`, and migrate the ObjC consumers. No `.tio` wire / transport-protocol change. Completes 3-SDK P2.5 parity.

**Architecture:** `TTIOImage` is a base class holding the common readonly properties + a designated initializer + `kind`/`spectralAxis`/`spectralAxisKind`; the three subclasses extend it (their initializers delegate common fields to `[super initWith…]`) and keep their own on-disk group + `writeToFilePath:`/`readFromFilePath:`/study-group I/O. `-[TTIOSpectralDataset imageForKind:]` returns the `TTIOImage` base; consumers cast (`(TTIOMSImage *)[ds imageForKind:TTIOImageKindMS]`).

**Tech Stack:** GNUstep + clang, ARC, `Testing.h` PASS macros. Build/test: `cd ~/TTI-O/objc && ./build.sh check`. Triple-surface manual registration (Source/GNUmakefile ×2, Tests/GNUmakefile, TTIOTestRunner.m extern+call). Push from Windows git.

**Hard invariants:**
- **No `.tio` wire change** — each subclass's `writeToFilePath:`/`readFromFilePath:`/study-group bytes + group names (`image_cube`/`raman_image_cube`/`ir_image_cube`) untouched; the base only relocates the common properties (read via the same getters). Round-trip fence.
- **No transport protocol change** — `TTIODatasetWalker`'s visit emission + `TTIOTransportWriter`'s image write order/methods stay; only the accessor they read changes to `imageForKind:`. Transport conformance unchanged.
- **Initializer signatures unchanged** (subclass inits delegate to a base designated init) — no construction churn.

**Reference:** spec `docs/superpowers/specs/2026-06-04-shared-image-base-design.md`; merged Python #219 + Java #220. Classes: `objc/Source/Image/TTIO{MSImage,RamanImage,IRImage}.{h,m}`. Accessors: `TTIOSpectralDataset.h:411/419/429` (lazy in `.m:~4299-4341`). The codec-registry ObjC idioms (#211) for base-class/registration patterns.

**Verified facts:**
- Common props (all three, same names): `title,isaInvestigationId,identifications,quantifications,provenanceRecords,width,height,spectralPoints,tileSize,cube(NSData),pixelSizeX,pixelSizeY,scanPattern`. (ObjC names the cube `cube`, NOT intensityCube.) Distinct: MS `mzAxis(NSData)`; Raman `wavenumbers,excitationWavelengthNm,laserPowerMw`; IR `wavenumbers,mode(TTIOIRMode),resolutionCmInv`. Each has `initWith…` initializers + `writeToFilePath:error:` + study-group `writeTo`/`readFrom` + `GROUP_NAME`/`+readFrom…`.
- `TTIOSpectralDataset` `msImage`/`ramanImage`/`irImage` are lazy nullable properties (materialize on first access, `.m:~4299-4341`).
- ObjC consumers of the DATASET accessors (migrate): `Export/TTIOWriterAdapters.m:177` (`dataset.msImage`), `Transport/TTIODatasetWalker.m:341/347/353` (msImage/ramanImage/irImage), `Transport/TTIOTransportWriter.m:1474/1479/1484`. LEAVE (NOT a dataset accessor): `Import/TTIOReaderAdapters.m:266` `d.msImage = image` — that is the `TTIOImportedDataset` DRAFT's own property (mirrors Python's draft). No `TTIOImageKind` enum exists yet.

---

### Task OIT1: `TTIOImage` base + enums + subclass MS/Raman/IR

**Files:**
- Create: `objc/Source/Image/TTIOImage.{h,m}`
- Modify: `objc/Source/Image/TTIO{MSImage,RamanImage,IRImage}.{h,m}`, `objc/Source/GNUmakefile`
- Test: `objc/Tests/TestImageBase.m` (register 3 surfaces)

- [ ] **Step 1: Study** the three image classes fully — common vs distinct properties, ALL `initWith…` initializers, `writeToFilePath:`/`readFromFilePath:`/the study-group `writeTo`/`+readFrom`/`GROUP_NAME`/`toPixelSpectra`. Note how the I/O reads properties (`self.cube` etc.). Find where `TTIOIRMode` is declared (for the enum-style reference).
- [ ] **Step 2: Write the fence test** `TestImageBase.m`: for each kind, build a populated image, write to a `.tio` (`writeToFilePath:`), read it back (`+readFromFilePath:` / the study-group reader), PASS field-identical round-trip (cube `isEqualToData:`, axis, all common + distinct props). PASS `[img isKindOfClass:[TTIOImage class]]`, `img.kind == TTIOImageKindMS/...`, `img.spectralAxis` equals the mz/wavenumber data, `img.spectralAxisKind == TTIOSpectralAxisKindMZ/WAVENUMBER`. Reuse the existing image-test fixture (`grep -rn "TTIOMSImage\|writeToFilePath\|image_cube" objc/Tests | head`). Register the test (3 surfaces). Run the round-trip portion against CURRENT code → PASS baseline.
- [ ] **Step 3: Create `TTIOImage.{h,m}`** (ARC):
  - `TTIOImage.h`: `typedef NS_ENUM(NSInteger, TTIOImageKind) { TTIOImageKindMS, TTIOImageKindRaman, TTIOImageKindIR };` and `typedef NS_ENUM(NSInteger, TTIOSpectralAxisKind) { TTIOSpectralAxisKindMZ, TTIOSpectralAxisKindWavenumber };`. `@interface TTIOImage : NSObject` with the 13 common readonly properties (copying the exact declarations from the subclasses), a designated `- (instancetype)initWith…(common params)…`, and `@property(readonly) TTIOImageKind kind;`, `@property(readonly, nullable) NSData *spectralAxis;`, `@property(readonly) TTIOSpectralAxisKind spectralAxisKind;` (these three are overridden/implemented by subclasses).
  - `TTIOImage.m`: synthesize/back the common properties in the designated init; `kind`/`spectralAxis`/`spectralAxisKind` may be `@dynamic`/abstract (subclasses implement) — or provide a base that raises if called directly. Match the subclasses' defensive-copy semantics (the props are `copy` for NSData/NSString/NSArray).
- [ ] **Step 4: Subclass the three** — `@interface TTIOMSImage : TTIOImage`: remove the now-common property declarations (inherited), keep only `mzAxis`. Each `initWith…` keeps its IDENTICAL signature but calls `[super initWith…(common)…]` and sets the distinct ivar(s). Implement `kind`→`TTIOImageKindMS`, `spectralAxis`→`self.mzAxis`, `spectralAxisKind`→`TTIOSpectralAxisKindMZ`. Keep `writeToFilePath:`/`readFromFilePath:`/study-group I/O/`GROUP_NAME`/`toPixelSpectra` UNCHANGED (they read inherited properties). Same for Raman (`wavenumbers`/excitation/power → WAVENUMBER) and IR (`wavenumbers`/mode/resolution → WAVENUMBER). Register `TTIOImage.h`/`.m` in `Source/GNUmakefile` (both lists).
- [ ] **Step 5: `cd ~/TTI-O/objc && ./build.sh check`** → green, byte-identical round-trips. (Remove stray build-check.log.)
- [ ] **Step 6: Commit** `refactor(objc-image): extract TTIOImage base + TTIOImageKind from MS/Raman/IR images`.

---

### Task OIT2: `TTIOSpectralDataset` collection + migrate consumers

**Files:**
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.{h,m}` (remove 3 props; add `imageForKind:`/`images`)
- Modify: `Export/TTIOWriterAdapters.m`, `Transport/TTIODatasetWalker.m`, `Transport/TTIOTransportWriter.m`
- Test: `objc/Tests/TestSpectralDatasetImages.m` (register 3 surfaces) + migrate existing tests

- [ ] **Step 1: Study** the lazy `msImage`/`ramanImage`/`irImage` getters (`TTIOSpectralDataset.m:~4299-4341`). Inventory the 3 consumer files. CONFIRM `TTIOReaderAdapters.m:266 d.msImage = image` is the `TTIOImportedDataset` draft setter (leave it).
- [ ] **Step 2: Failing test** `TestSpectralDatasetImages.m`: open a `.tio` with an MSImage; PASS `[ds imageForKind:TTIOImageKindMS]` returns it (`isKindOfClass:[TTIOMSImage class]`), `[ds imageForKind:TTIOImageKindRaman]` is nil, `[ds images]` contains only present kinds. (Removal of old props enforced by the compiler — migrated consumers won't compile against the old names.)
- [ ] **Step 3: Implement on `TTIOSpectralDataset`** — remove the `msImage`/`ramanImage`/`irImage` public properties (from the .h; keep the lazy backing logic, now reached via the new method). Add `- (nullable TTIOImage *)imageForKind:(TTIOImageKind)kind;` (switch dispatching to the existing per-kind lazy getters) and `- (NSArray<TTIOImage *> *)images;` (present kinds only, MS→Raman→IR order). Preserve the lazy materialization (move the property bodies into private helpers if needed).
- [ ] **Step 4: Migrate the 3 consumers** (cast to the typed image):
  - `TTIOWriterAdapters.m:177`: `TTIOMSImage *img = (TTIOMSImage *)[dataset imageForKind:TTIOImageKindMS];`.
  - `TTIODatasetWalker.m:341/347/353`: `TTIOMSImage *msImg = (TTIOMSImage *)[dataset imageForKind:TTIOImageKindMS];` (+ raman/ir); the visit emission UNCHANGED.
  - `TTIOTransportWriter.m:1474/1479/1484`: capture `(TTIOMSImage *)[dataset imageForKind:TTIOImageKindMS]` etc. in locals once, reuse for the gate + write calls; write order/methods UNCHANGED.
- [ ] **Step 5: Migrate tests** — every test using `ds.msImage`/`.ramanImage`/`.irImage` → `(TTIOXImage *)[ds imageForKind:TTIOImageKind…]`. (`grep -rn "\.msImage\b\|\.ramanImage\b\|\.irImage\b" objc/Tests` — EXCLUDING any `TTIOImportedDataset` draft `.msImage` uses, which stay.)
- [ ] **Step 6: `cd ~/TTI-O/objc && ./build.sh check`** → green; transport conformance unchanged. (Remove stray build-check.log.)
- [ ] **Step 7: Commit** `refactor(objc): replace TTIOSpectralDataset image accessors with imageForKind:/images`.

---

### Task OIT3: Registration audit + full check + CHANGELOG

- [ ] **Step 1: Triple-surface audit** — `TTIOImage.{h,m}` in `Source/GNUmakefile` (both lists); the 2 new tests (`TestImageBase`, `TestSpectralDatasetImages`) in `Tests/GNUmakefile` + extern+call in `TTIOTestRunner.m`. Grep to confirm none dropped.
- [ ] **Step 2: Full `cd ~/TTI-O/objc && ./build.sh check`** → "all tests passed". Remove any stray `objc/build-check.log` (must NOT be committed).
- [ ] **Step 3: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Changed — Shared Image base + uniform image collection (Objective-C)

  `TTIOMSImage`/`TTIORamanImage`/`TTIOIRImage` now share a `TTIOImage` base
  (common geometry, intensity cube, metadata) with a `TTIOImageKind` discriminator
  and a generic `spectralAxis`. `TTIOSpectralDataset`'s `msImage`/`ramanImage`/
  `irImage` are replaced by `-imageForKind:` + `-images`; the transport
  writer/walker and exporter adapter migrated. No `.tio` wire/format or
  transport-protocol change; initializer signatures unchanged. Completes the
  3-SDK P2.5 importer/exporter-independent image-abstraction sweep (Python #219,
  Java #220). (OO-assessment P2.5.)
  ```
- [ ] **Step 4: Commit** `docs: changelog for ObjC shared Image base (P2.5)`.

---

## Self-review notes (author)
- **No wire change** — base extraction relocates common properties only; subclass `writeToFilePath:`/`readFromFilePath:`/group untouched (round-trip fence). **No transport protocol change** — walker/writer emission stays; only the accessor read changes.
- **No init churn** — initializer signatures kept (delegate to base designated init); the compiler catches any accessor-removal miss (ObjC won't build).
- **Draft NOT migrated** — `TTIOReaderAdapters.m d.msImage = image` is the `TTIOImportedDataset` draft property (mirrors Python/Java); leave it.
- **Triple-surface registration** is the ObjC footgun — audited in OIT3.
- This completes P2.5 across all three SDKs.
