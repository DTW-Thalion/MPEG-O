# P3.8 — `SpectrumKind` enum + factory (replace stringly-typed dispatch) — Design

> OO-assessment (`docs/architecture/2026-06-02-oo-design-assessment.md`) P3.8.
> **NO `.tio` wire / transport change.** The persisted `@spectrum_class` string
> stays the source of truth; this is a purely in-code dispatch refactor across the
> three SDKs. Cross-language conformance is the gate.

## Goal

Replace the stringly-typed `spectrum_class` dispatch (`if spectrum_class ==
"TTIOIRSpectrum"` / `switch (spectrumClassOverride)` / `[s isEqualToString:
@"TTIORamanSpectrum"]` chains) with a `SpectrumKind` enum + a factory, in Python,
Java, and ObjC. The OO win: dispatch becomes type-safe and the per-kind knowledge
(which Spectrum subclass, which channel axes) lives in ONE place per SDK instead of
scattered string comparisons.

## The decisive constraint — wire/persisted form is UNCHANGED

The 8-ish `spectrum_class` strings (`TTIOMassSpectrum`, `TTIONMRSpectrum`,
`TTIONMR2DSpectrum`, `TTIORamanSpectrum`, `TTIOIRSpectrum`, `TTIOUVVisSpectrum`,
`TTIOFreeInductionDecay`, `TTIOMSImagePixel`) are BOTH a persisted HDF5 attribute
(`format-spec.md:136`) AND consumed by a transport wire map. We change NEITHER:

- **Persisted `@spectrum_class` HDF5 attribute** — the run keeps storing the exact
  string. On read it remains the stored field; on write it is emitted **verbatim**
  (never reconstructed from the enum). So round-trip is byte-exact even for an
  unknown/future string → forward-compat preserved.
- **Transport `_SPECTRUM_CLASS_TO_WIRE`** (`transport/_common.py`: Mass→0, NMR→1,
  NMR2D→2, FID→3, MSImagePixel→4, Genomic→5, and the ObjC/Java equivalents) — this
  is a *separate, already-clean* string→int wire mapping and is the wire format. It
  is **out of scope / untouched**.

Because the wire is unchanged, there is **no Phase-0 wire-proof and no migration
shim** — the only gate is a round-trip-fidelity test (the bytes are literally
preserved) plus dispatch-equivalence.

## Architecture

**Keep the persisted string as the source of truth; derive a `SpectrumKind` enum
from it for dispatch.** Per SDK:

1. **`SpectrumKind` enum** — one member per known spectrum-class string
   (`MASS`, `NMR`, `NMR_2D`, `RAMAN`, `IR`, `UVVIS`, `FREE_INDUCTION_DECAY`,
   `MS_IMAGE_PIXEL`) + an `UNKNOWN`/`OTHER` sentinel. Each known member carries its
   canonical persisted string. The exact member set = the union of every persisted
   string each SDK's dispatch actually recognizes (the implementer enumerates per
   SDK from the existing comparisons; do not invent members not currently
   dispatched on).
2. **Boundary mapper** — `SpectrumKind.from_persisted(s) -> kind` (recognized
   strings → their member; absent → `MASS` per the v0.1 fallback in
   `format-spec.md:154`; unrecognized → `UNKNOWN`). The run keeps the raw
   `spectrum_class` string field for write-back; the enum is a *derived* dispatch
   key.
3. **Factory / per-kind table** — replaces the dispatch chains. Maps a kind to its
   Spectrum subclass + the channel axes it reads (e.g. IR/Raman → `wavenumber` +
   `intensity`; UV-Vis → `wavelength` + `absorbance`; MS → `mz` + `intensity`; NMR
   → `chemical_shift` + `intensity`). This is the single place per-kind knowledge
   lives.

The materialization/dispatch code calls `self.kind` (computed once from the stored
string) and the factory, instead of comparing strings. Write paths emit the stored
string unchanged.

### Dispatch sites to migrate (verified)
- **Python** `acquisition_run.py:726-742` (`if self.spectrum_class == "TTIONMRSpectrum"`
  / IR / Raman / UVVis), plus the spectrum-materialization path that selects channels.
  Write site `spectral_dataset.py:1181` (`write_fixed_string_attr(g, "spectrum_class",
  run.spectrum_class)`) stays — emits the stored string.
- **Java** `AcquisitionRun.java:303` `switch (spectrumClassOverride)` + the
  `"TTIOIRSpectrum".equals(...)` chains at `:596` and `:696`.
- **ObjC** `Run/TTIOAcquisitionRun.m:340-359` and `:1003-1033`
  (`[_spectrumClassName isEqualToString:@"..."]` chains).
- **Opportunistic (convert if clean, same PR):** selection/filter sites that compare
  the class string — Java `exporters/RunSelection.java`, ObjC `Export/TTIORunSelection.m`
  / `TTIOMzMLWriter.m`, Python equivalents — may use the enum for clarity. The
  string field still exists, so these are non-breaking either way; do them where it
  reads cleanly, skip if it widens the diff unduly.

### Explicitly out of scope
- The transport wire map (`_SPECTRUM_CLASS_TO_WIRE` and the ObjC/Java
  `isEqualToString → wireClass` ladders in `*EncryptedTransport`/`*TransportReader`)
  — that is the wire; leave it. (A future item could route it through the enum too,
  but that risks the wire and isn't this refactor.)
- `TTIOGenomicRead` (genomic runs are a separate run type, not a spectrum kind) —
  not a `SpectrumKind`.
- Any `.tio`/transport byte change; any migration shim.

## Hard invariants
- No `.tio`/wire/transport change; `@spectrum_class` written verbatim from the
  stored string. No public API-shape change (the persisted string field/accessor
  stays; the enum is additive).
- Round-trip byte-exact for every persisted string incl. unknown.
- Dispatch results identical to the old string comparisons for all known values +
  the absent/unknown fallbacks.
- Cross-language conformance + each SDK's full suite green.

## Testing (the "fidelity gate" — replaces a Phase-0 wire-proof)
Per PR:
- **Round-trip byte-exact:** read a run with each persisted `@spectrum_class` value
  (incl. an injected unknown like `"TTIOFutureSpectrum"`), write it back, assert the
  emitted string is identical.
- **Dispatch equivalence:** for every known value + absent + unknown, the enum/
  factory path produces the same Spectrum subclass + channel selection the old
  string chain did.
- Full SDK suite; cross-language conformance (wire unchanged → trivially green).
- Java jacoco ≥0.84; ObjC `./build.sh check`; Python coverage gate.

## PR sequence
PR-1 (Python) → PR-2 (Java) → PR-3 (ObjC). Each its own branch off main, CI-green,
merged before the next.
