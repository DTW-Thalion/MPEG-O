# CHANGELOG

All notable changes to the MPEG-O multi-omics data standard reference
implementation. Dates are release dates; the repository commits record
the actual timeline.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/) — the
leading `0.` means the public API is still stabilising; see
`docs/api-stability-v0.8.md` for the per-symbol stability tags.

---

## [Unreleased] — v0.12.0 work-in-progress

Accumulating scope for v0.12.0. All five milestones have landed:
must-haves M74 + M75, plus nice-to-haves M76, M77, and M78.

### Added

- **M74 — `activation_method` + `isolation_window` data-model
  extension (2026-04-22).** Closes the last "must-fix for v1.0" item
  in `docs/v1.0-gaps.md`. Shipped as five sequential slices across
  Python / Java / Objective-C:

    - `ActivationMethod` enum — `NONE / CID / HCD / ETD / UVPD / ECD
      / EThcD`, int32-stable across all three languages.
    - `IsolationWindow` value class — `target_mz`, `lower_offset`,
      `upper_offset`, plus `lower_bound`, `upper_bound`, `width`
      derived accessors.
    - `MassSpectrum` gains `activation_method` + `isolation_window`
      fields; the legacy initializer still works and defaults them to
      `NONE` / `None` for backward compatibility.
    - `spectrum_index` compound gains four parallel optional columns
      (`activation_methods` int32, `isolation_target_mzs` /
      `isolation_lower_offsets` / `isolation_upper_offsets` float64).
      All-or-nothing: the writer refuses partial population.
    - mzML reader maps PSI-MS activation accessions (MS:1000133 CID,
      MS:1000422 HCD, MS:1000598 ETD, MS:1000250 ECD, MS:1003246
      UVPD, MS:1003181 EThcD) and reconstructs `IsolationWindow`
      from MS:1000827 / 828 / 829.
    - mzML writer emits the preserved method inside `<activation>`
      and a complete `<isolationWindow>` block in the XSD-required
      order (`isolationWindow` → `selectedIonList` → `activation`).
    - `opt_ms2_activation_detail` feature flag registered in all
      three languages; the writer bumps `@mpeg_o_format_version`
      from `1.1` to `1.3` only on files that actually carry the
      columns, so legacy-content files keep byte-parity with earlier
      releases.

  Commits: `beb2bc7` (A) · `736ecef` (B) · `9340007` (C) · `c502d68`
  (D) · `e96105f` (E).

- **M75 — Python CLI parity polish (2026-04-23).** Three new
  `console_scripts` registered in `python/pyproject.toml` close the
  last CLI-surface gap with the Java (`com.dtwthalion.mpgo.tools.*`)
  and Objective-C (`objc/Tools/Mpgo*`) tool families:

    - `mpgo-sign` — HMAC-SHA256 canonical-byte signer. Mirrors ObjC
      `MpgoSign`. Exit: 0 signed / 1 I/O or dataset-missing / 2 usage.
    - `mpgo-verify` — canonical HMAC verifier backed by
      `mpeg_o.verifier.Verifier`. Stdout prints
      `VerificationStatus.name` (`VALID` / `INVALID` / `NOT_SIGNED` /
      `ERROR`); exit code = `int(status)` (0 / 1 / 2 / 3).
    - `mpgo-pqc` — post-quantum CLI mirroring the ObjC `MpgoPQCTool`
      and Java `PQCTool` subcommand grammar 1:1 across 10 verbs:
      `sig-keygen` / `sig-sign` / `sig-verify` / `kem-keygen` /
      `kem-encaps` / `kem-decaps` / `hdf5-sign` / `hdf5-verify` /
      `provider-sign` / `provider-verify`. Gated on the `[pqc]`
      extra (liboqs-python); verify subcommands return 0 valid / 1
      invalid / 2 error.

  Commit: `e9f2d2b`.

- **M76 — JCAMP-DX compressed-writer emission (2026-04-23).** The
  JCAMP-DX 5.01 §5.9 compression dialects (PAC / SQZ / DIF) become
  an opt-in writer mode in all three languages. AFFN stays the
  default for bit-accurate round-trips; compressed output is
  selected via a keyword (`encoding="pac"`), enum
  (`JcampDxEncoding.PAC`), or NS_ENUM (`MPGOJcampDxEncodingPAC`)
  value on the existing `write*Spectrum` surfaces:

    - **Byte-parity across languages.** A single reference encoder
      lives in Python (`mpeg_o.exporters._jcamp_encode`) and is
      mirrored verbatim in Java (`JcampDxEncode`) and Objective-C
      (`MPGOJcampDxEncode`). Rounding is explicit half-away-from-zero
      (portable across Python / Java / C); YFACTOR is chosen as
      `10 ** (ceil(log10(max_abs)) - 7)` for ~7 significant digits of
      integer-scaled Y precision; lines break every 10 Y values.
    - **Explicit Y-check on every non-first line.** The compressed
      decoder unconditionally drops any line-start value equal to
      the previous line's last Y within 1e-9 (the JCAMP-DX Y-check
      rule). Plateaus at the line boundary would silently steal data
      points without a prepended sentinel, so the encoder emits an
      explicit SQZ (or PAC) of the previous last Y on every line
      N > 0 for all three modes.
    - **Python reader PAC detection.** `has_compression()` now also
      matches the `\d[+\-]\d` digit-sign-digit adjacency that
      distinguishes a PAC body. Scientific notation is safe because
      the character before a `+`/`-` is always `e`/`E`, never a
      digit.
    - **Cross-language conformance gate.** `conformance/jcamp_dx/`
      ships three golden `.jdx` fixtures (one per compressed mode)
      plus a `generate.py` regenerator. Python
      (`test_m76_jcamp_conformance.py`), Java
      (`JcampDxM76ConformanceTest`), and Objective-C
      (`TestM76JcampConformance`) each re-run the writer in-process
      and assert byte-for-byte equality against the same bytes.
      All 9 checks (3 modes × 3 languages) are green.

  Commits: `9437a1b` (A: Python encoder + reader fix + 37 unit
  tests) · `de377d6` (B: conformance fixtures + regenerator +
  Python conformance test) · `d889b19` (C: Java writer,
  `JcampDxEncoding` enum, 3/3 conformance, 345/345 suite) ·
  `4787aa2` (D: ObjC writer, `MPGOJcampDxEncoding` NS_ENUM, 3/3
  conformance, 1637/0 suite) · this docs flip (E).

- **M77 — 2D-COS computation primitives (2026-04-23).** Noda's
  generalised synchronous / asynchronous decomposition from a
  perturbation series (Hilbert-transform approach) ships as a shared
  library API in all three languages. The output value class,
  `TwoDimensionalCorrelationSpectrum`, was added in v0.11.1; M77
  fills in the missing *compute* side.

    - **API surface.** Three functions per language, identical
      semantics: `hilbert_noda_matrix(m)` returns the discrete
      `(m, m)` transform with `N[j, k] = 1 / (π · (k − j))` (zero
      on diagonal, antisymmetric); `compute(dynamic_spectra,
      reference=None, …)` returns a
      `TwoDimensionalCorrelationSpectrum` containing synchronous
      `Φ = (1/(m−1)) · Ãᵀ · Ã` and asynchronous
      `Ψ = (1/(m−1)) · Ãᵀ · N · Ã` matrices, with `Ã = A −
      reference` mean-centered dynamic spectra; reference defaults
      to the column-wise mean (classical mean-centered 2D-COS) and
      accepts an explicit baseline for difference 2D-COS.
      `disrelation_spectrum(sync, async)` returns `|Φ|/(|Φ|+|Ψ|)`
      element-wise in `[0, 1]` as the significance metric, NaN
      where both matrices vanish.
    - **Cross-language parity.** Python
      (`mpeg_o.analysis.two_d_cos`) uses NumPy BLAS; Java
      (`com.dtwthalion.mpgo.analysis.TwoDCos`) and Objective-C
      (`Analysis/MPGOTwoDCos`) use plain nested loops with the
      Hilbert-Noda weight folded into the asynchronous multiply.
      Because BLAS accumulation order differs across
      implementations, the conformance gate is float-tolerance
      (`rtol=1e-9, atol=1e-12`) rather than byte-parity.
    - **Shared reference fixture.** `conformance/two_d_cos/` ships
      `dynamic.csv` (24×16 perturbation series built from drifting
      Gaussian bands) plus `sync.csv` and `async.csv` from the
      Python reference implementation. A regenerator
      (`generate.py`) is committed alongside for when reference
      semantics intentionally change. All three languages run the
      same fixture through their own compute path and assert
      closeness to the shared expected matrices; 3/3 language
      gates are green.
    - **Structural invariants verified per language.** Synchronous
      matrix is symmetric; asynchronous matrix is antisymmetric;
      constant perturbation yields zero sync + async (sanity);
      pure-sinusoid 2×2 case exhibits the expected
      synchronous-autocorrelation / asynchronous-phase-offset
      pattern.

  Commits: `df321d5` (A: Python `mpeg_o.analysis.two_d_cos` + 15
  unit tests) · `2dfe27d` (B: `conformance/two_d_cos/` fixtures +
  Python conformance gate) · `6f4f115` (C: Java `TwoDCos` + 13
  unit tests + conformance, 359/359 suite) · `2f02ffa` (D: ObjC
  `MPGOTwoDCos` + 27 new pass() cases, 1664/0 suite) · `9e4b367`
  (E: docs flip).

- **M78 — mzTab PEH/PEP + SFH/SMF + SEH/SME support (2026-04-23).**
  Closes the last "deferred further" item called out in
  `docs/v1.0-gaps.md`. A new `Feature` value class ships beside
  `Identification` and `Quantification` in all three languages, and
  the mzTab importer + exporter round-trips peptide-level features
  (mzTab-P 1.0) and small-molecule features + evidence
  (mzTab-M 2.0.0-M):

    - **`Feature` value class.** Nine fields —  `feature_id`,
      `run_name`, `chemical_entity`, `retention_time_seconds`,
      `exp_mass_to_charge`, `charge`, `adduct_ion`, `abundances`
      (sample→abundance map), `evidence_refs` (list of spectrum or
      SME refs). Immutable across all three languages: Python
      `dataclass(frozen=True)`, Java `record` with compact-constructor
      null-coercion + `Map.copyOf` / `List.copyOf` defensive copies,
      Objective-C `MPGOFeature` with readonly copy properties.
    - **Reader.** Parses PEH/PEP rows into `Feature` records
      (sequence, charge, m/z, RT, spectra_ref, per-assay or
      per-study-variable abundance columns) and SFH/SMF rows with
      adduct + SME_ID_REFS. SEH/SME parsing then back-fills the
      feature's `chemical_entity` from `SME_ID` placeholder to the
      SME row's `database_identifier`, `chemical_name`, or
      `chemical_formula` (first non-null).
    - **Writer.** Emits PEH/PEP after PRH/PRT (1.0 branch) and
      SFH/SMF after SMH/SML (2.0.0-M branch). SEH/SME is gated on
      `features present && (idents with SME_ID tag OR plain idents)`
      so plain-SML metabolomics round-trips stay unchanged from
      pre-M78. Rank ↔ confidence mapping is symmetric: reader
      converts rank N → confidence `1/N`; writer converts
      confidence c → `max(1, round(1/c))` for the emitted rank
      column.
    - **Cross-language conformance fixture.**
      `conformance/mztab_features/{proteomics,metabolomics}.mztab`
      with the Python, Java, and Objective-C suites each reading it
      and asserting identical feature counts, adducts, charges, m/z
      values (float-tolerance), and SME-derived confidence scores.
      Byte-level parity is intentionally not required — Java
      `Double.toString` vs Python `{:g}` differ on some edge values,
      but both round-trip through parsing at `1e-3` float tolerance.

  Commits: `9b76096` (A+B: Python `Feature` + reader/writer +
  conformance fixture, 11 new unit tests + 3 conformance) ·
  `c1286f0` (C: Java `Feature` record + reader/writer, 373/0 suite;
  +4 value-class + 7 writer + 3 conformance) · `073335f` (D: ObjC
  `MPGOFeature` + reader/writer, 1704/0 suite; +3 value-class + 7
  writer + 3 conformance) · this docs flip (E).

### Test totals (post-M78)

- Python: 875 tests collected (M78 adds +11 unit + 3 conformance
  over M77; remaining delta from intervening M74/M75/M76/M77
  scaffold that landed beyond the core parity lines).
- Java: 373 tests (+14 over M77).
- Objective-C: 1704 passed / 0 failed (+40 over M77).

### Docs

- `docs/v1.0-gaps.md` — "Must-fix for v1.0" list now empty; status
  table row for activation/isolation flipped to ✅; mzML writer
  defect table updated to show item #2 shipped; "deferred further"
  mzTab Feature item also now shipped.
- `WORKPLAN.md` — M74, M75, M76, M77, and M78 checkboxes all ticked
  with their shipped commits.

---

## [v0.11.1] — 2026-04-21

Patch release completing the three M73 items that landed as deferred
notes in v0.11.0. All three languages gain the same surfaces and remain
bit-identical on the round-trip path.

### Added

- **JCAMP-DX 5.01 PAC / SQZ / DIF / DUP compression reader** in all
  three languages. Auto-detects compressed bodies via a sentinel-char
  scan that excludes `e`/`E` (so AFFN scientific notation doesn't
  false-trigger), then delegates to a per-language decoder:

    - Python: `mpeg_o.importers._jcamp_decode.decode_xydata`
    - Java: `com.dtwthalion.mpgo.importers.JcampDxDecode.decode`
    - Objective-C: `MPGOJcampDxDecode +decodeLines:…`

  Implements the full SQZ alphabet (`@`, `A–I`, `a–i`), DIF alphabet
  (`%`, `J–R`, `j–r`), DUP alphabet (`S–Z`, `s`), the DIF Y-check
  convention (repeated leading Y within 1e-9 of the previous line's
  last Y is dropped), and X-reconstruction from `FIRSTX` / `LASTX` /
  `NPOINTS`. Writers remain AFFN-only — bit-accurate round-trips are
  worth more than the byte savings at this stage.

- **`UVVisSpectrum` class** in all three languages — 1-D UV/visible
  absorption spectrum keyed by `"wavelength"` (nm) + `"absorbance"`,
  with `pathLengthCm` and `solvent` metadata. JCAMP-DX reader
  dispatches `UV/VIS SPECTRUM`, `UV-VIS SPECTRUM`, and
  `UV/VISIBLE SPECTRUM` to this class; writer emits `##DATA TYPE=UV/VIS
  SPECTRUM` with `##XUNITS=NANOMETERS`, `##YUNITS=ABSORBANCE`, and
  `##$PATH LENGTH CM` / `##$SOLVENT` custom LDRs.

- **`TwoDimensionalCorrelationSpectrum` class** in all three
  languages — Noda 2D-COS representation with rank-2 synchronous
  (in-phase) and asynchronous (quadrature) correlation matrices
  sharing a single variable axis (`nu_1 == nu_2`). Matrices are
  row-major `float64`, size-by-size; construction validates rank,
  matching shape, and squareness. Gated behind the new
  `opt_native_2d_cos` feature flag.

### Test totals

- Python: 765 tests (was 695; 26 new for M73.1 = 20 compression/UV-Vis +
  6 2D-COS + misc).
- Java: 331 tests (was 307; 24 new for M73.1).
- Objective-C: 1536 tests (was 1443; 45 new for M73.1).

### Removed from "Deferred to v1.0+" / v0.11 scope

- `PAC / SQZ / DIF JCAMP-DX compression` — shipped here (reader only).
- `UVVisSpectrum / UV-Vis JCAMP-DX dispatch` — shipped here.
- `2D-COS / TwoDimensionalCorrelationSpectrum class` — shipped here.

---

## [v0.11.0] — 2026-04-21

Vibrational spectroscopy (M73): Raman and IR are now first-class
modalities alongside MS and NMR. Three-language parity is
preserved — every surface ships in Python, Objective-C, and Java
and round-trips byte-for-byte between them.

### Added

- **Four new domain classes per language.**
  `RamanSpectrum` and `IRSpectrum` extend the `Spectrum` base
  (keyed by `"wavenumber"` + `"intensity"`). Raman carries
  `excitationWavelengthNm`, `laserPowerMw`,
  `integrationTimeSec`; IR carries `mode` (the new `IRMode` enum:
  `TRANSMITTANCE=0`, `ABSORBANCE=1`), `resolutionCmInv`, and
  `numberOfScans`.

  `RamanImage` and `IRImage` hold rank-3 intensity cubes with a
  shared rank-1 wavenumber axis. HDF5 layout documented in
  `docs/format-spec.md` §7a — `/study/raman_image_cube/` and
  `/study/ir_image_cube/` mirror the MSImage chunking convention
  (`(tile_size, tile_size, spectral_points)` tiles, `zlib -6`).

- **JCAMP-DX 5.01 AFFN reader + writer** (`##XYDATA=(X++(Y..Y))`).
  All three writers emit LDRs in identical order with `%.10g`
  formatting — byte-identical output for identical input. Readers
  dispatch on `##DATA TYPE=` (`RAMAN SPECTRUM` /
  `INFRARED ABSORBANCE` / `INFRARED TRANSMITTANCE`, with
  `INFRARED SPECTRUM` falling back to `##YUNITS=`). Compression
  variants (PAC / SQZ / DIF) and 2-D NTUPLES are deferred; the
  reader rejects them rather than guessing. See
  `docs/vendor-formats.md` for details.

- **Cross-language conformance harness.**
  `python/tests/integration/test_raman_ir_cross_language.py`
  writes a Python JCAMP-DX file, feeds it to small subprocess
  drivers built on the ObjC and Java readers
  (`objc/Tools/MpgoJcampDxDump` + a `/tmp/` ad-hoc Java driver),
  and compares the parsed arrays bit-for-bit. Tests skip on dev
  boxes where the ObjC / Java sides are unbuilt and run in full
  in CI. A companion test locks the LDR emission order so format
  drift between implementations is caught in code review.

- **ObjC CLI tool `MpgoJcampDxDump`** — tiny driver that reads a
  `.jdx` via `MPGOJcampDxReader` and dumps `x,y` pairs + a
  `CLASS=<tag>` trailer, matching the Java driver contract so
  both subprocess drivers can share the Python-side parser.

### Test totals

- ObjC: 1443 tests (was 1430).
- Python: 695 tests (was 682; 13 new M73 + 6 integration).
- Java: 307 tests (was 298; 9 new M73).
- Cross-language: 44 tests (was 38; 6 new JCAMP-DX conformance).

### Removed from "Deferred to v1.0+"

`Raman/IR support (new Spectrum subclasses)` — shipped here.

### Scope — what's intentionally NOT in v0.11

- 2-D JCAMP-DX (NTUPLES / PAGE). Imaging and 2-D NMR cubes are
  stored natively in HDF5; ASCII cubes are impractical at 10–100
  MB per map.
- 2D-COS and hyperspectral imaging-specific analyses.
- PAC / SQZ / DIF JCAMP-DX compression. Preserving bit-accurate
  cross-implementation round-trips is worth more than the byte
  savings at this stage.

---

## [v0.10.0] — 2026-04-20

Transport layer (M66–M72) plus the v1.0 per-Access-Unit encryption
stack. Three-language parity remains the rule — every surface shipped
here lands in Python, Objective-C, and Java before the tag.

### Added

- **Transport codec (M67)** — `.mots` streams for the MPEG-O wire
  format defined in `docs/transport-spec.md` §3. 24-byte packet
  headers, little-endian, `{StreamHeader, DatasetHeader, AccessUnit,
  ProtectionMetadata, Annotation, Provenance, Chromatogram,
  EndOfDataset, EndOfStream}` packet types. Python / ObjC / Java all
  parse the same byte stream.

- **Transport client + server (M68 / M68.5)** — WebSocket push
  endpoints (libwebsockets for ObjC, `websockets` for Python,
  Java-WebSocket for Java). Streams .mpgo datasets as `.mots` over
  the wire with optional CRC-32C per packet.

- **Acquisition simulator (M69)** — replays a fixture at wall-clock
  pace to exercise client/server scheduling.

- **Bidirectional conformance (M70)** — cross-language matrix test
  that any pair of {Python, ObjC, Java} writers and readers can
  exchange streams byte-for-byte.

- **Selective access + protection metadata (M71)** — per-packet
  AUFilter + ProtectionMetadata fields (cipher_suite, kek_algorithm,
  wrapped_dek, signature_algorithm, public_key).

- **Per-Access-Unit encryption (v1.0 scope)** — `opt_per_au_encryption`
  feature flag with the `<channel>_segments` VL_BYTES compound layout
  from `format-spec.md` §9.1. Each spectrum is a separate AES-256-GCM
  op with fresh IV + AAD = `dataset_id || au_sequence || channel_name`;
  ciphertext cannot be replayed against a different AU or envelope.
  Optional `opt_encrypted_au_headers` flag additionally encrypts the
  36-byte semantic header into `spectrum_index/au_header_segments`.

  Shipped as five phases across all three languages:
    - **Phase A** — per-AU primitives (AAD helpers, `ChannelSegment` /
      `HeaderSegment` / `AUHeaderPlaintext`, pack / unpack, round-trip).
    - **Phase B** — `VL_BYTES` compound-field kind + HDF5 provider
      wiring. The Java side uses a native hvl_t raw-buffer pool
      because JHI5 1.10 doesn't marshal VL-in-compound directly.
    - **Phase C** — file-level encrypt/decrypt orchestrator
      (`PerAUFile` / `MPGOPerAUFile` / `encrypt_per_au`). All I/O
      flows through the StorageProvider abstraction — any backend
      with VL_BYTES compound support works.
    - **Phase D** — encrypted transport writer + reader. Ciphertext
      passes through the wire unmodified (server never decrypts in
      transit, per `transport-spec.md` §6.2).
    - **Phase E** — cross-language conformance harness
      (`tests/integration/test_per_au_cross_language.py`) drives the
      `per_au_cli` tool in all three languages via subprocess and
      byte-compares a canonical MPAD decryption dump. 38/38 passing
      across every encrypt × decrypt × headers combination.

- **`per_au_cli transcode` subcommand** — migrate plaintext or
  existing v1.0-encrypted files to a fresh DEK / `--headers` setting.
  v0.x `opt_dataset_encryption` inputs fail loud with a migration
  hint (decrypt via v0.x API first).

- **Java HDF5 write durability fix** — `Hdf5File.close()` now calls
  `H5Fflush` before `H5Fclose` so writes persist even when child
  group handles leaked up the call stack. Caught by the cross-
  language test where Java encryption of a Python-created fixture
  silently dropped changes.

### Changed

- `FeatureFlags`: added `opt_per_au_encryption` and
  `opt_encrypted_au_headers` to the known-optional set.
- `CompoundField.Kind`: added `VL_BYTES` (bumps the enum from 4 to 5
  members in all three languages).

### Metrics

| Language   | Tests |
| ---------- | ----: |
| Python     |   682 |
| ObjC       |  1430 |
| Java       |   298 |
| Cross-lang |    38 |

---

## [v0.9.1] — 2026-04-19

Patch on top of v0.9.0 (commit `228eeb5`). Closes the remaining
v1.0 exporter gaps surfaced by M64 xfails and migrates the Zarr
on-disk format from v2 to v3.

### Added
- **mzTab exporter** across Python + ObjC + Java (commit
  `3c67ba9`). Both proteomics 1.0 (MTD + PSH/PSM + PRH/PRT) and
  metabolomics 2.0.0-M (MTD + SMH/SML) dialects supported. Output
  round-trips through the reader bit-identically.
- **imzML exporter** across Python + ObjC + Java (commit
  `ff0f201`). Continuous + processed modes; rejects divergent mz
  axis in continuous mode; UUID normalisation. Same commit fixes
  an importer cv-accession misclassification: `MS:1000030`/
  `MS:1000031` are vendor / instrument-model fields, not IMS mode.
- **nmrML spectrum1D** XSD gap closed via interleaved `(x,y)`
  encoding (commit `6b26f2e`).
- **mzML + ISA-Tab** validation closure and nmrML wrapper
  improvements (commit `65c3666`).
- Unit-level coverage for the new writers (commit `2f35bd2`).
- **v1.0 gap audit** doc covering the exporter + importer xfails
  surfaced by M64 (commit `4f17789`).

### Changed
- **Zarr v2 → v3 on-disk migration** across all three language
  providers (commits `391a7d2` + `da13fed`). Each node is now a
  single `zarr.json` file (`node_type: group | array`) with
  attributes nested inside; array chunks live under a `c/` prefix
  (`c/0/1/2`); dtypes use canonical names (`float64`, `int32`,
  ...). Compression on read accepts the `gzip` codec written by
  zarr-python's `GzipCodec`.
  - Python uses zarr-python 3.x (`LocalStore`, `FsspecStore`,
    `MemoryStore`, `create_array(compressors=...)`).
  - Java + ObjC self-contained writers/readers updated to emit and
    parse v3 layout byte-for-byte against zarr-python output.
  - No backward-compat shim — pre-deployment, no v2 stores in the
    wild. Read side does still accept legacy v2 dtype strings
    (`<f8`, `<i4`, ...) for safety.

### Test counts
- Python 586 pass / 11 skip / 4 xfail
- Objective-C 1271 PASS
- Java 245 pass

---

## [v0.9.0] — 2026-04-19 (commit `228eeb5`)

### Added
- **M57** Integration test infrastructure + fixture management
  (`download.py`, pinned source URLs, in-repo fallbacks).
- **M58** Cross-tool round-trip integration tests: mzML, nmrML,
  Thermo `.raw`, Bruker `.d`.
- **M59** imzML + `.ibd` importer. Python reference, then
  Objective-C + Java for three-language parity.
- **M60** mzTab importer (proteomics 1.0 + metabolomics 2.0.0-M)
  across Python + ObjC + Java.
- **M61** End-to-end workflow + security-lifecycle test matrix
  (84 cross-provider cells: encryption, signature, anonymization).
- **M62** Stress + cross-provider benchmark suite (31 stress-marked
  cells); cross-language stress + validation suites for all three
  languages.
- **M63** Waters MassLynx `.raw` importer (Python + ObjC + Java),
  delegation pattern through `MassLynxRawReader` where SDK present,
  open-source fallback otherwise.
- **M64** Cross-tool validation (PSI XSD, pyteomics, pymzml,
  isatools) + nightly stress CI.
- **M64.5** caller-refactor across all three languages so
  `SpectralDataset.open` / `write_minimal` dispatch on URL scheme
  (HDF5 / Memory / SQLite / Zarr). Phase A (Python), phase B
  (provider-aware Encryption/Signature/Anonymizer), phase C
  (KeyRotationManager + MSImage cube cross-provider). Java + ObjC
  follow-up landed `ProviderRegistry.open` and
  `+readViaProviderURL:` paths. 39 of 39 cross-provider cells
  pass; the remaining `memory`-as-cross-process xfail is by design.

### Performance
- 3-language profiling harness + pure-C libhdf5 baseline; three
  targeted optimisations (ObjC `writeMinimal` fast path, chunk-size
  tuning, concat improvement); ObjC harness fairness fix +
  Java index parity. ObjC sits at ~1.3× over raw C — documented
  in `tools/perf/ANALYSIS.md`.

### Test counts at v0.9.0
- Python 555 pass / 7 xfail (3 documenting v1.0 exporter defects)
- Objective-C 1202 PASS
- Java 232 pass

---

## [v0.8.0] — 2026-04-18

### Added
- **M49** Post-quantum crypto: ML-KEM-1024 (FIPS 203) envelope
  key-wrap and ML-DSA-87 (FIPS 204) dataset signatures. New `v3:`
  signature-attribute prefix; `opt_pqc_preview` feature flag
  auto-set whenever either primitive runs. Python and Objective-C
  use liboqs; Java uses Bouncy Castle 1.80+. Rationale: `docs/pqc.md`.
  - **M49.1** ObjC dataset / envelope integration via
    `MPGOSignatureManager` + `MPGOKeyRotationManager`.
- **M52** Java and Objective-C `ZarrProvider` ports. Self-contained
  LocalStore implementations — no external zarr library dependency.
  Same on-disk layout as the Python reference so all three languages
  cross-read one another's stores. (On-disk format migrated from
  Zarr v2 to v3 in v0.9; see Unreleased.)
- **M53** Bruker timsTOF `.d` importer. SQLite metadata reads
  natively in every language; binary frame decompression uses
  `opentimspy` + `opentims-bruker-bridge` in Python and subprocesses
  into the Python helper from Java / Objective-C. New
  `inv_ion_mobility` signal channel preserves the 2-D timsTOF
  geometry per-peak. Details: `docs/vendor-formats.md`.
- **M54 + M54.1** 32-cell cross-language × cross-provider PQC
  conformance matrix: primitive ML-DSA / ML-KEM, v3 signatures on
  HDF5 / Zarr / SQLite, v2+v3 coexistence, v0.7 backward-compat.
  New `com.dtwthalion.mpgo.tools.PQCTool` (Java) and
  `MpgoPQCTool` (ObjC) CLIs drive the harness. New Python
  `sign_storage_dataset` / `verify_storage_dataset` provider-agnostic
  helpers.

### Changed
- **Binding decision 42 (revised)** — see `docs/pqc.md`. Python
  `cryptography` 46 does not yet expose ML-KEM / ML-DSA, so
  Python + ObjC use `liboqs` instead of the originally-planned
  OpenSSL 3.5 path. Java keeps the Bouncy Castle plan.
- `CipherSuite` catalog: `ml-kem-1024` and `ml-dsa-87` graduate
  from `reserved` to `active`. `shake256` remains reserved.
  ML-DSA-87 public-key size corrected from 4864 → 2592 bytes
  (FIPS 204 §4).
- `validate_key(algorithm, key)` now rejects asymmetric algorithms
  with an explicit redirect to `validate_public_key` /
  `validate_private_key`. Symmetric-only by design.
- `java/run-tool.sh` git mode promoted from 100644 to 100755 so
  the parity tests stop skipping on fresh clones.

### Deprecated
- `v0.7` API surface marks nothing new as removed in v0.8. See
  `docs/api-stability-v0.8.md` for the v1.0 deprecation candidates.

### Fixed
- Python + Objective-C provider `read_canonical_bytes` on signed
  datasets now round-trips through every shipping provider
  (HDF5, Memory, SQLite, Zarr).

---

## [v0.7.0] — 2026-04-18

### Added
- **M41** SQLite storage provider across ObjC / Python / Java.
- **M43** `read_canonical_bytes()` protocol method enables
  cross-backend signature verification.
- **M44** Protocol-native `AcquisitionRun` and `MSImage` — upper
  layers go through `StorageGroup` instead of raw HDF5 handles.
- **M45** `create_dataset_nd` across all providers; native N-D
  image cubes + 2-D NMR matrices via the protocol.
- **M46** Python `ZarrProvider` reference implementation (stretch;
  Java / ObjC ports land in v0.8 M52).
- **M47** Wrapped-key blob format v1.2 — algorithm-discriminated
  envelope (`magic "MW" | version | algorithm_id | ct_len |
  md_len | metadata | ciphertext`). Reserves `algorithm_id=0x0001`
  for ML-KEM-1024 (activated in v0.8 M49).
- **M48** `CipherSuite` catalog with reserved PQC algorithm IDs
  and an `algorithm=` keyword parameter threaded through
  encryption / signing / wrapping.
- **M50** Cross-language consistency hardening (six Appendix-B
  gap resolutions: `open()` signatures, `readRows()`, capability
  queries, `provider_name` shape, precision decoupling, attribute
  del/enum).
- **M51** Compound write byte-parity harness across three
  languages — 9-cell interop grid.

### Changed
- `mpeg_o_format_version` bumps from `1.1` to `1.2`.
- Default wrapped-key layout is v1.2 (71 bytes for AES-GCM);
  v1.1 (60-byte fixed) remains readable indefinitely.

### Baseline
- Objective-C: 1057 assertions pass.
- Python: 284 tests pass.
- Java: 179 tests pass.

---

## [v0.6.1] — 2026-02

SQLite provider stress-test; six Appendix-B gap fixes shipped
inline (dual-style `open()`, `read_rows()` protocol method,
capability queries, etc.).

## [v0.6.0] — 2026-02

- **M33-M39** Storage provider abstraction land. Three-language
  parity across HDF5, Memory, and (v0.7) SQLite backends.
- Java reaches full feature parity with ObjC and Python.

## [v0.5.0] — 2025-12

- **M30-M33** Three-way conformance test harness across the
  three languages; shared fixture generator.
- Three-language feature parity achieved on the M11-M29
  milestone block.

## [v0.4.0] — 2025-10

- **M25** Envelope encryption + key rotation: DEK + KEK model,
  `/protection/key_info/` group layout.
- **M26-M28** Spectral anonymisation pipeline, nmrML writer,
  chromatogram API.
- `opt_key_rotation`, `opt_anonymized` feature flags.

## [v0.3.0] — 2025-08

- **M17-M24** Compound per-run provenance, `v2:` canonical-byte
  signatures, LZ4 + Numpress-delta compression, chromatogram
  import (M24).

## [v0.2.0] — 2025-06

- **M11-M16** Core dataset model: `/study/ms_runs/*/spectrum_index`,
  signal-channels group, compound `identifications` /
  `quantifications` / `provenance` datasets, v1 HMAC signatures.
- `mpeg_o_format_version = "1.1"` and `mpeg_o_features` JSON
  array introduced.

## [v0.1.0-alpha] — 2025-04

- **M1-M10** Initial ObjC reference implementation with HDF5
  backing store. Core spectrum hierarchy
  (`MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGOFreeInductionDecay`,
  `MPGOMSImage`). Basic mzML reader.

---

## Notes on format compatibility

- **Write-forward** — readers must refuse files carrying a
  required feature they don't recognise. Optional features
  (prefixed `opt_`) are ignored.
- **Read-backward** — every reader reads the full v0.1 through
  v0.8 range. The v1.1 wrapped-key blob (60-byte fixed) remains
  decryptable indefinitely (HANDOFF binding #38).
- Classical HMAC-SHA256 signatures (`v2:` prefix) continue to
  verify after the v0.8 PQC activation; post-quantum signatures
  (`v3:` prefix) raise `UnsupportedAlgorithmError` on v0.7-and-
  earlier readers, which is the correct behaviour.
