# MPEG-O v0.2 — Continuation Session Prompt

> **Status:** v0.1.0-alpha is **complete and tagged**. All eight original
> milestones delivered, 379 tests passing in GitHub Actions CI, no
> warnings under `-Wall -Wextra`. This session executes **Milestones
> 9–15** to produce the **v0.2.0** release.

---

## First Steps on This Machine

Before writing any code:

1. Clone or pull the repo:
   ```bash
   git clone https://github.com/DTW-Thalion/MPEG-O.git
   # or: cd MPEG-O && git pull
   ```

2. **Read these files in full** — they are the source of truth:
   - `README.md` — project overview
   - `ARCHITECTURE.md` — three-layer class hierarchy, HDF5 container mapping, and v0.1 simplification notes
   - `WORKPLAN.md` — the eight completed milestones with acceptance criteria (all checked off)
   - `docs/primitives.md`, `docs/container-design.md`, `docs/class-hierarchy.md`, `docs/ontology-mapping.md`
   - `objc/GNUmakefile.preamble` — toolchain detection and build flags
   - `objc/check-deps.sh`, `objc/build.sh` — the build entry points
   - `.github/workflows/ci.yml` — CI job definition (source-built gnustep-2.0 + libobjc2)

3. **Set up the local toolchain.** The build requires source-built gnustep-2.0 (libobjc2 + gnustep-make + gnustep-base) plus libhdf5 and OpenSSL:
   ```bash
   sudo apt-get install -y clang cmake ninja-build make git \
       libhdf5-dev zlib1g-dev libssl-dev libxml2-dev \
       libgnutls28-dev libffi-dev libicu-dev libblocksruntime-dev \
       libcurl4-openssl-dev
   # Then build libobjc2, gnustep-make, gnustep-base from source
   # (see .github/workflows/ci.yml for exact steps and version tags)
   ```

4. **Verify the build:**
   ```bash
   cd objc
   ./build.sh check    # Must show 379 tests passing
   ```
   If this fails, replicate the CI toolchain build steps from `.github/workflows/ci.yml` locally before proceeding. Do not start milestone work on a broken build.

---

## Current State — What v0.1.0-alpha Delivered

### Complete and passing (379 tests)

- **Milestone 1 — Foundation:** Five capability protocols (`MPGOIndexable`, `MPGOStreamable`, `MPGOCVAnnotatable`, `MPGOProvenanceable`, `MPGOEncryptable`), four value classes (`MPGOCVParam`, `MPGOAxisDescriptor`, `MPGOEncodingSpec`, `MPGOValueRange`) with full `NSCoding`/`NSCopying`/`isEqual`/`hash`, `MPGOEnums.h`.
- **Milestone 2 — SignalArray + HDF5:** `MPGOHDF5File`, `MPGOHDF5Group`, `MPGOHDF5Dataset`, `MPGOHDF5Attribute` wrappers. `MPGOSignalArray` with float32/64, int32, complex128, chunked+zlib storage. 1M-element write/read ~3ms.
- **Milestone 3 — Spectrum classes:** `MPGOSpectrum`, `MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGONMR2DSpectrum`, `MPGOFreeInductionDecay`, `MPGOChromatogram`.
- **Milestone 4 — AcquisitionRun:** `MPGOAcquisitionRun` with signal channel separation, `MPGOSpectrumIndex` (parallel 1-D datasets), `MPGOInstrumentConfig`, random access, streaming. 1000-spectrum run write ~22ms.
- **Milestone 5 — Dataset + metadata:** `MPGOSpectralDataset` as root container, `MPGOIdentification`, `MPGOQuantification`, `MPGOProvenanceRecord`, `MPGOTransitionList`. Full `.mpgo` file round-trip.
- **Milestone 6 — MSImage:** `MPGOMSImage` with spatial grid, tile-based access. Standalone class (not yet a `MPGOSpectralDataset` subclass).
- **Milestone 7 — Encryption:** `MPGOEncryptionManager` with AES-256-GCM via OpenSSL. Selective per-dataset encryption. `MPGOAccessPolicy` with JSON persistence.
- **Milestone 8 — Query + Streaming:** `MPGOQuery` with compressed-domain predicates (RT range, MS level, polarity, precursor m/z, base peak). `MPGOStreamWriter`/`MPGOStreamReader`. 10k-spectrum query scan ~0.2ms.

### Known simplifications to resolve in v0.2

From `ARCHITECTURE.md § Implementation notes (v0.1.0-alpha)`:

1. **`MPGOEncryptable` is delegated, not directly conformed.** `MPGOAcquisitionRun` and `MPGOSpectralDataset` use the static `MPGOEncryptionManager` API rather than conforming to the protocol themselves.
2. **`MPGOProvenanceable` is dataset-level only.** Provenance is stored as an array on `MPGOSpectralDataset`, not per-run.
3. **Identifications, quantifications, provenance are JSON-encoded.** Stored as JSON strings in scalar HDF5 attributes, not as bespoke HDF5 compound types.
4. **`MPGOSpectrumIndex` uses parallel 1-D datasets.** Eight separate datasets instead of one compound `headers` dataset.
5. **`MPGOMSImage` is standalone.** Not a `MPGOSpectralDataset` subclass; no inherited identification/quantification/provenance support.
6. **`MPGOAcquisitionRun` accepts only `MPGOMassSpectrum`.** NMR spectra live in a separate `nmrRuns` array.
7. **`MPGONMR2DSpectrum` flattens its matrix.** 1D `MPGOSignalArray` with shape attributes instead of native 2D HDF5 dataset.

---

## Binding Decisions — Do Not Override

These decisions were made collaboratively with the user across the v0.1 and v0.2 planning sessions. They are binding unless the user explicitly revises them in conversation.

### From v0.1 session

1. **Milestone-by-milestone checkpoints.** Complete Milestone N, commit, verify CI green, pause for user review before starting Milestone N+1. Do **not** chain milestones without user acknowledgment.

2. **Clang-only.** `gcc`/`gobjc` cannot compile libMPGO because Objective-C ARC (`-fobjc-arc`) is required and gobjc doesn't support it. `build.sh` enforces `CC=clang OBJC=clang`.

3. **Value classes are immutable and return `self` from `-copyWithZone:`.** Standard Cocoa pattern for immutable value objects.

4. **No thread safety in v0.1 or v0.2.** Document as "not thread-safe" where relevant. Deferred to v0.3.

5. **CRLF/LF handled by `.gitattributes`.** Do not modify `.gitattributes`.

6. **Shell scripts must have executable bit.** Use `git update-index --chmod=+x <file>` for any new `.sh` files.

7. **HDF5 via C API wrapped in thin Objective-C classes.** Always check return values. Always close `hid_t` identifiers.

8. **`.mpgo` file extension.** Internally valid HDF5 files.

9. **Error handling uses `NSError **` out-parameters.** Return `nil` or `NO` on failure. Never throw exceptions for expected errors.

10. **Test isolation.** Each test creates its own temporary HDF5 file in `/tmp/mpgo_test_*` and deletes it after the test.

11. **Commit discipline.** One commit per completed milestone with a clear message referencing the milestone number. Include `Co-Authored-By` trailer. HEREDOC for multi-line messages.

12. **Build verification.** `./build.sh check` must pass locally and in GitHub Actions CI before any milestone is considered complete.

13. **ARC on libMPGO, MRC on the test harness.** `objc/Tests/GNUmakefile.preamble` applies `-fno-objc-arc` to the test binary. Preserve this split.

### From v0.2 planning session

14. **Milestone 10 (A1+A5) is simultaneous.** Protocol conformance and modality-agnostic runs are tackled together because they are deeply coupled.

15. **mzML reader (Milestone 9) comes before Track A cleanup.** Real-world data validation precedes refactoring. Bugs found against PRIDE data get fixed before compound-type migration.

16. **Python stream waits until v0.2 stabilizes.** No `python/` code until v0.2.0 is tagged and the on-disk format is frozen.

17. **Formal schema evolution mechanism.** See "Versioning & Schema Evolution" section below.

18. **Permissive licensing (Apache-2.0) on the import/export layer.** Core `libMPGO` stays LGPL-3.0. Files under `Import/` and `Export/` are Apache-2.0.

---

## Versioning & Schema Evolution

Replace the current `@mpeg_o_version` string attribute with a two-part scheme on all new files:

### Format version attribute

```
@mpeg_o_format_version = "1.1"    (major.minor, string attribute on HDF5 root)
```

- **Major** increments on backward-incompatible layout changes
- **Minor** increments on backward-compatible additions

### Feature flags attribute

```
@mpeg_o_features = ["base_v1", "compound_identifications", "compound_headers", "per_run_provenance"]
```

A JSON array of feature strings stored as a variable-length string attribute on the root group.

- Features **without** a prefix are **required** — a reader must refuse to open the file if it doesn't support the feature
- Features prefixed with `opt_` are **optional** — a reader may skip unknown optional features gracefully

### Backward compatibility with v0.1

v0.1 files carry `@mpeg_o_version = "1.0.0"` and no `@mpeg_o_features`. Readers detect v0.1 files by the absence of `@mpeg_o_features` and fall back to the v0.1 code path (JSON-encoded metadata, parallel index datasets, mass-spectrum-only runs).

### Feature registry

| Feature String | Milestone | Required? | Description |
|---|---|---|---|
| `base_v1` | 9 | Required | Core six primitives, signal channels, spectrum index |
| `compound_identifications` | 11 | Required | Identifications/quantifications as HDF5 compound types |
| `compound_headers` | 11 | Optional | SpectrumIndex compound headers dataset |
| `per_run_provenance` | 10 | Optional | Each run carries its own provenance chain |
| `opt_native_2d_nmr` | 12 | Optional | NMR2DSpectrum uses native 2D HDF5 datasets |
| `opt_digital_signatures` | 14 | Optional | Signed provenance and data integrity |

### Implementation

Create an `MPGOFeatureFlags` utility class:

```objc
@interface MPGOFeatureFlags : NSObject
+ (NSArray<NSString *> *)readFromFile:(MPGOHDF5File *)file error:(NSError **)error;
+ (BOOL)writeFeatures:(NSArray<NSString *> *)features toFile:(MPGOHDF5File *)file error:(NSError **)error;
+ (BOOL)file:(MPGOHDF5File *)file supportsFeature:(NSString *)feature;
+ (BOOL)isV1File:(MPGOHDF5File *)file;  // checks for absence of @mpeg_o_features
@end
```

---

## Licensing Structure

### Directory layout

```
MPEG-O/
├── LICENSE                      # LGPL-3.0 (covers core libMPGO)
├── LICENSE-IMPORT-EXPORT        # Apache-2.0 (covers Import/ and Export/)
├── objc/Source/
│   ├── Core/                    # LGPL-3.0
│   ├── HDF5/                    # LGPL-3.0
│   ├── MS/                      # LGPL-3.0
│   ├── NMR/                     # LGPL-3.0
│   ├── Protocols/               # LGPL-3.0
│   ├── ValueClasses/            # LGPL-3.0
│   ├── Protection/              # LGPL-3.0
│   ├── Query/                   # LGPL-3.0
│   ├── Import/                  # Apache-2.0 ← NEW in v0.2
│   │   ├── MPGOMzMLReader.h/.m
│   │   ├── MPGONmrMLReader.h/.m
│   │   ├── MPGOBase64.h/.m
│   │   └── MPGOCVTermMapper.h/.m
│   └── Export/                  # Apache-2.0 ← FUTURE (v0.3)
```

### File headers

Every file under `Import/` and `Export/` carries:

```objc
/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
```

All other `.m` and `.h` files carry the existing LGPL-3.0 header.

### LICENSE-IMPORT-EXPORT

Create this file at the repo root containing the standard Apache License 2.0 text. The first action of Milestone 9 is to commit this file before writing any Import/ code.

### GNUmakefile integration

Add the `Import/` source files to `objc/Source/GNUmakefile`'s `libMPGO_OBJC_FILES` and `libMPGO_HEADER_FILES` lists. Apache-2.0 is compatible with LGPL-3.0 for combined works.

---

## Milestone 9 — mzML Reader (Real-World Data Import)

**Track:** B1 — New capability
**License:** Apache-2.0 (in `objc/Source/Import/`)

### Pre-work

1. Commit `LICENSE-IMPORT-EXPORT` (Apache-2.0 text) at repo root.
2. Create `objc/Source/Import/` directory.
3. Add Import files to `objc/Source/GNUmakefile`.
4. Download 2–3 small mzML test fixtures from PRIDE or the PSI mzML example files. Place in `objc/Tests/Fixtures/`. If files are > 5 MB each, create a `objc/Tests/Fixtures/download.sh` script that fetches them; add the script to `.gitignore` exceptions but not the data files themselves.

### Classes to implement

**`MPGOBase64` (`Import/MPGOBase64.h/.m`)**

Decodes base64-encoded strings to `NSData`. Handles the mzML convention where `<binaryDataArray>` content is base64-encoded, optionally zlib-compressed.

```objc
@interface MPGOBase64 : NSObject
+ (NSData *)decodeString:(NSString *)base64String;
+ (NSData *)decodeString:(NSString *)base64String zlibInflate:(BOOL)inflate;
@end
```

Use GNUStep's built-in base64 decoding if available (`-[NSData initWithBase64EncodedString:options:]` or `GSMimeDecoder`), falling back to a simple lookup-table implementation. For zlib inflate, use `uncompress()` from `<zlib.h>` (already linked).

**`MPGOCVTermMapper` (`Import/MPGOCVTermMapper.h/.m`)**

Maps PSI-MS controlled vocabulary accessions to MPGO enum values and property setters. Does not need to load the full OBO ontology file — hardcode mappings for the ~50 most common accessions:

```objc
@interface MPGOCVTermMapper : NSObject

// Data type accessions
+ (MPGOPrecision)precisionForAccession:(NSString *)acc;
// MS:1000521 → MPGOPrecisionFloat32 (32-bit float)
// MS:1000523 → MPGOPrecisionFloat64 (64-bit float)

// Compression accessions
+ (MPGOCompressionAlgorithm)compressionForAccession:(NSString *)acc;
// MS:1000574 → MPGOCompressionZlib
// MS:1000576 → MPGOCompressionNone

// Array type accessions (which signal array is this?)
+ (NSString *)signalArrayNameForAccession:(NSString *)acc;
// MS:1000514 → @"mz"
// MS:1000515 → @"intensity"
// MS:1000516 → @"charge"
// MS:1000517 → @"signal_to_noise"
// MS:1000595 → @"time" (for chromatograms)
// MS:1000820 → @"ion_mobility"

// Spectrum metadata accessions
+ (BOOL)isMSLevelAccession:(NSString *)acc;         // MS:1000511
+ (BOOL)isPolarityAccession:(NSString *)acc;         // MS:1000129 (neg), MS:1000130 (pos)
+ (BOOL)isScanWindowAccession:(NSString *)acc;       // MS:1000501 (lower), MS:1000500 (upper)
+ (BOOL)isTotalIonCurrentAccession:(NSString *)acc;  // MS:1000285
+ (BOOL)isBasePeakAccession:(NSString *)acc;         // MS:1000504 (m/z), MS:1000505 (intensity)
+ (BOOL)isRetentionTimeAccession:(NSString *)acc;    // MS:1000016
+ (BOOL)isScanStartTimeAccession:(NSString *)acc;    // MS:1000016
+ (BOOL)isPrecursorAccession:(NSString *)acc;        // MS:1000744 (selected ion m/z)

// Passthrough: unknown accessions become raw MPGOCVParam objects
+ (MPGOCVParam *)cvParamFromAccession:(NSString *)acc
                                 name:(NSString *)name
                                value:(NSString *)value
                          ontologyRef:(NSString *)ontRef
                                 unit:(NSString *)unitAcc;
@end
```

**`MPGOMzMLReader` (`Import/MPGOMzMLReader.h/.m`)**

SAX-based mzML 1.1 parser using `NSXMLParser`. Implements `NSXMLParserDelegate`.

```objc
@interface MPGOMzMLReader : NSObject

+ (MPGOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error;
+ (MPGOSpectralDataset *)readFromURL:(NSURL *)url error:(NSError **)error;
+ (MPGOSpectralDataset *)readFromData:(NSData *)data error:(NSError **)error;

@end
```

**Parsing strategy:**

The parser maintains a state stack tracking element nesting. Key elements:

- `<mzML>` → root, extract version
- `<cvList>` / `<cv>` → build ontology reference map
- `<referenceableParamGroupList>` / `<referenceableParamGroup>` → store param groups for later expansion
- `<fileDescription>` / `<sourceFileList>` → extract source file metadata
- `<run>` → begin building an `MPGOAcquisitionRun`
- `<spectrumList count="N">` → pre-allocate spectrum array
- `<spectrum index="..." id="..." defaultArrayLength="...">` → begin a new `MPGOMassSpectrum`
  - `<cvParam>` inside `<spectrum>` → extract MS level, polarity, scan time, etc. via `MPGOCVTermMapper`
  - `<precursorList>` / `<precursor>` / `<selectedIon>` → extract precursor m/z, charge
  - `<binaryDataArrayList>` / `<binaryDataArray>` → for each array:
    - Collect `<cvParam>` to determine: precision (float32/64), compression (zlib/none), array type (m/z/intensity/etc.)
    - Collect the base64 text content between start and end tags
    - Decode via `MPGOBase64`
    - Create `MPGOSignalArray` with appropriate `MPGOEncodingSpec` and `MPGOAxisDescriptor`
- `<chromatogramList>` / `<chromatogram>` → similar pattern, produce `MPGOChromatogram` objects
- `<dataProcessing>` / `<processingMethod>` → produce `MPGOProvenanceRecord` chain

**Critical implementation details:**

- `<binaryDataArray>` text content may arrive across multiple `parser:foundCharacters:` callbacks — accumulate into an `NSMutableString`.
- `<referenceableParamGroup>` elements may be referenced from within spectra via `<referenceableParamGroupRef ref="..."/>`. Expand these inline during spectrum parsing.
- The `defaultArrayLength` attribute on `<spectrum>` gives the expected element count — validate decoded array length against this.
- mzML uses 1-indexed `<spectrum index="0">` (0-indexed despite the attribute name). The `id` attribute is a string like `"scan=1234"`.
- Chromatogram arrays are time+intensity pairs, same decoding logic as spectrum arrays.
- Unit accessions in `<cvParam unitAccession="UO:0000010">` should be preserved on `MPGOCVParam.unit`.

### Tests for Milestone 9

Create `objc/Tests/TestMzMLReader.m`:

- Parse a centroided mzML file → verify spectrum count
- Verify m/z and intensity arrays for specific spectra (compare against known values)
- Verify MS level and polarity extracted correctly
- Verify chromatogram count and TIC values
- Verify retention times on spectra
- Verify precursor m/z and charge for MS2 spectra
- Full round-trip: mzML → `MPGOSpectralDataset` → write `.mpgo` → read `.mpgo` → verify spectrum count and array values
- Error test: parse truncated/malformed XML → nil with NSError, no crash
- If a profile-mode fixture is available: parse and verify larger arrays

**Note on test fixtures:** If suitable mzML files cannot be committed to the repo due to size, create synthetic mzML test data programmatically — write a small helper that emits valid mzML XML with known m/z and intensity values, then parse that. This guarantees repeatable tests without external downloads.

### Acceptance criteria

- [ ] Parse a real (or realistic synthetic) centroided mzML file
- [ ] Spectrum count matches `<spectrumList count="N">`
- [ ] m/z and intensity arrays for sampled spectra match expected values within float64 epsilon
- [ ] Chromatogram extraction works (TIC at minimum)
- [ ] cvParam annotations (MS level, polarity, scan window, RT) correctly mapped
- [ ] Full round-trip: mzML → MPGO objects → write .mpgo → read .mpgo → verify
- [ ] Profile-mode mzML (larger arrays, possibly compressed) parses correctly
- [ ] Malformed XML returns nil + NSError, no crash
- [ ] Performance: 50 MB equivalent parses in < 10 seconds (logged, PASS if under)

### Commit message

```
Milestone 9: mzML reader — real-world data import

- MPGOMzMLReader: SAX-based mzML 1.1 parser via NSXMLParser
- MPGOBase64: base64 decode + zlib inflate for binaryDataArray
- MPGOCVTermMapper: PSI-MS CV accession → MPGO model mapping
- LICENSE-IMPORT-EXPORT: Apache-2.0 for import/export layer
- Full round-trip test: mzML → .mpgo → read back → verify
```

---

## Milestone 10 — Protocol Conformance + Modality-Agnostic Runs

**Track:** A1 + A5
**License:** LGPL-3.0

### Changes to existing classes

**`MPGOAcquisitionRun`:**

- Add formal `<MPGOEncryptable>` conformance. Implement `-encryptWithKey:level:error:` and `-decryptWithKey:error:` that delegate to `MPGOEncryptionManager` internally but present the protocol interface.
- Add formal `<MPGOProvenanceable>` conformance. Each run carries its own `NSMutableArray<MPGOProvenanceRecord *> *provenanceRecords` property.
- Remove the type restriction that only accepts `MPGOMassSpectrum`. Accept any `MPGOSpectrum` subclass.
- Make signal channel serialization **name-driven**: when writing to HDF5, iterate the spectra's signal array dictionaries, collect unique array names, and create one HDF5 dataset per name. For MS runs this produces `mz_values` and `intensity_values` as before. For NMR runs this produces `chemical_shift_values` and `intensity_values`.
- The `MPGOSpectrumIndex` header fields must accommodate NMR spectra (which lack `precursor_mz` and `ms_level`). Use sentinel values (e.g., `NAN` for precursor_mz, `0` for ms_level) for non-MS spectra, or make these fields nullable in the index.
- Per-run provenance: write to `/run_NNNN/provenance/` group; read back on deserialization.

**`MPGOSpectralDataset`:**

- Add formal `<MPGOEncryptable>` conformance. Delegates to `MPGOEncryptionManager` for the file-level operations.
- The existing `nmrRuns` array property can be deprecated in favor of regular `runs` entries that happen to contain NMR spectra.

**`MPGOEncryptionManager`:**

- Mark the file-path-based API methods with `MPGO_DEPRECATED_MSG("Use -[MPGOAcquisitionRun encryptWithKey:level:error:] instead")`.
- Keep them functional for backward compatibility.

### Tests for Milestone 10

- Create `MPGOAcquisitionRun` with 100 `MPGOMassSpectrum` → write → read → verify (existing behavior preserved)
- Create `MPGOAcquisitionRun` with 50 `MPGONMRSpectrum` → write → read → verify all chemical_shift and intensity arrays
- Per-run provenance: add 3 steps → write → read → verify chain
- Encrypt via run's protocol method → decrypt → verify data integrity
- `MPGOQuery` works on NMR runs: "acquisition time > 5.0" predicate
- `MPGOStreamWriter`/`Reader` round-trip on NMR runs
- v0.1 `.mpgo` files still readable (backward compat test — use a fixture written by v0.1 code)
- Deprecated `MPGOEncryptionManager` API still works

### Acceptance criteria

- [ ] MS run: 100 spectra write/read/verify
- [ ] NMR run: 50 spectra write/read/verify
- [ ] Per-run provenance round-trip
- [ ] Encryption via protocol method
- [ ] Query on NMR runs
- [ ] Streaming on NMR runs
- [ ] v0.1 file backward compatibility
- [ ] Deprecation warnings emitted for old API

---

## Milestone 11 — Native HDF5 Compound Types

**Track:** A2 + A3
**License:** LGPL-3.0

### New class

**`MPGOHDF5CompoundType` (`HDF5/MPGOHDF5CompoundType.h/.m`)**

Wraps `H5Tcreate(H5T_COMPOUND, ...)` with field registration:

```objc
@interface MPGOHDF5CompoundType : NSObject
- (instancetype)initWithSize:(size_t)totalSize;
- (BOOL)addField:(NSString *)name type:(hid_t)type offset:(size_t)offset;
- (hid_t)typeId;
- (void)close;
@end
```

### Changes to serialization

**Identifications:** Replace JSON-encoded string with compound dataset at `/study/identifications/`:

```
{
    spectrum_ref:    uint32
    chemical_entity: variable-length string
    score:           float64
    evidence_type:   variable-length string
}
```

**Quantifications:** Replace JSON with compound dataset at `/study/quantifications/`:

```
{
    abundance:       float64
    sample_ref:      variable-length string
    normalization:   variable-length string
}
```

**Provenance records:** Replace JSON with compound dataset at `/run_NNNN/provenance/steps` (per-run) and `/study/provenance/steps` (dataset-level):

```
{
    timestamp:       variable-length string (ISO8601)
    software:        variable-length string
    parameters_json: variable-length string (JSON-encoded NSDictionary)
    input_refs:      variable-length string (JSON array of ref strings)
    output_refs:     variable-length string (JSON array of ref strings)
}
```

**SpectrumIndex compound headers:** Add a compound `headers` dataset alongside (not replacing) the existing parallel 1-D datasets:

```
{
    offset:              uint64
    length:              uint32
    retention_time:      float64
    ms_level:            uint8
    polarity:            int8
    precursor_mz:        float64
    precursor_charge:    int32
    base_peak_intensity: float64
}
```

### Feature flags and backward compatibility

**`MPGOFeatureFlags`** class (see Versioning section above). Writers emit `@mpeg_o_format_version` and `@mpeg_o_features`. Readers check for feature flags first; if absent, fall back to v0.1 JSON path.

### Tests

- 100 identifications as compound type → read → verify all fields
- 50 quantifications as compound type → read → verify
- Compound headers queryable via hyperslab read
- Open a v0.1 `.mpgo` fixture → read succeeds via JSON fallback
- New files contain `@mpeg_o_features` with expected values
- `h5dump` produces readable compound type output (visual verification)
- 10,000 identification records write/read < 50ms

### Acceptance criteria

- [ ] Compound identifications round-trip
- [ ] Compound quantifications round-trip
- [ ] Compound headers queryable
- [ ] v0.1 backward compatibility
- [ ] Feature flags written and read correctly
- [ ] h5dump readability
- [ ] Performance target met

### M11 add-on — MPGOSpectralDataset `<MPGOEncryptable>` conformance

Unfinished M10 scope folded into M11 because it touches the same
persistence layer as the compound-type migration. Separating these
would force a second pass over `MPGOSpectralDataset` later.

**Semantics.** File-level encrypt applies the key to every run's
intensity channel *and* to the new compound identification /
quantification datasets under `/study/`. One call protects all
sensitive payloads under one key. m/z and spectrum-index header
fields stay readable so tooling can scan without the key.

**File handle management.** `MPGOSpectralDataset.readFromFilePath:`
keeps the underlying HDF5 file open for lazy hyperslab reads, which
blocks the encryption manager's RW reopen. Add:

```objc
- (BOOL)closeFile;   // releases root group + underlying HDF5 handle
```

After `closeFile`, lazy spectrum reads error out with a clear
`MPGOErrorInvalidState`. Encrypt/decrypt require the file to be
closed (or must close it themselves before delegating).

**Protocol methods on `MPGOSpectralDataset`:**

```objc
- (BOOL)encryptWithKey:(NSData *)key
                 level:(MPGOEncryptionLevel)level
                 error:(NSError **)error;
- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error;
- (MPGOAccessPolicy *)accessPolicy;
- (void)setAccessPolicy:(MPGOAccessPolicy *)policy;
```

`encryptWithKey:` closes the file, iterates `msRuns.allValues`,
delegates to each run's `encryptWithKey:level:error:` (which already
hits `MPGOEncryptionManager` under the hood), then encrypts the
compound identification/quantification datasets via a new
`+[MPGOEncryptionManager encryptCompoundDataset:atFilePath:withKey:error:]`
helper added in the same milestone.

**Access policy persistence.** Stored on the root group as
`@access_policy_json` (JSON-encoded `MPGOAccessPolicy`). Runs
inherit the dataset policy unless they carry their own override.

**Root encryption marker.** Write `@encrypted = "aes-256-gcm"` on
the root group so external tools can detect protected files without
walking into per-run groups.

**Out of scope for v0.2.** Key rotation, multi-key per-subject
protection, and envelope-style key wrapping. Document as v0.3.

### M11 add-on — Acceptance criteria

- [ ] `[MPGOSpectralDataset closeFile]` releases the HDF5 handle;
      subsequent lazy reads return `MPGOErrorInvalidState`
- [ ] Dataset-level encrypt → reload → every run's intensity channel
      reports encrypted; every run's m/z channel still readable
- [ ] Dataset-level encrypt also protects the compound identification
      and quantification datasets
- [ ] `@encrypted` marker appears on the root group after encrypt
- [ ] `@access_policy_json` round-trips through write/read
- [ ] `MPGOSpectralDataset` formally conforms to `<MPGOEncryptable>`
- [ ] Deprecated file-path API still functional

---

## Milestone 12 — MSImage Inheritance + Native 2D NMR

**Track:** A4 + A6
**License:** LGPL-3.0

### MSImage refactoring

- `MPGOMSImage` becomes a subclass of `MPGOSpectralDataset`.
- The spatial cube is stored under `/study/image_run_NNNN/` following the standard run group structure, with additional spatial metadata attributes (`spatial_width`, `spatial_height`, `pixel_size_x`, `pixel_size_y`, `scan_pattern`).
- MSImage inherits identification, quantification, and provenance support from the superclass.
- The v0.1 `/image_cube/` layout remains readable as a fallback.

### Native 2D NMR

- `MPGONMR2DSpectrum` stores its intensity matrix as a native 2D HDF5 dataset using `H5Dcreate2` with a rank-2 dataspace.
- Add HDF5 dimension scales (`H5DSset_scale`, `H5DSattach_scale`) for the F1 and F2 axes.
- The v0.1 flattened layout remains readable as a fallback.
- Files containing native 2D NMR data include `opt_native_2d_nmr` in `@mpeg_o_features`.

### Tests

- 64×64 MSImage write/read/verify
- MSImage with identifications and quantifications
- MSImage provenance chain
- HSQC-type 2D NMR (256×128) as native 2D dataset write/read/verify
- `h5dump` displays 2D NMR dataset dimensions correctly
- v0.1 flattened 2D NMR file readable

### Acceptance criteria

- [ ] MSImage inherits dataset capabilities
- [ ] 2D NMR native HDF5 dataset round-trip
- [ ] Dimension scales present and correct
- [ ] Backward compatibility for both MSImage and 2D NMR v0.1 layouts
- [ ] Feature flag `opt_native_2d_nmr` emitted

---

## Milestone 13 — nmrML Reader

**Track:** B2
**License:** Apache-2.0 (in `Import/`)

### Classes to implement

**`MPGONmrMLReader` (`Import/MPGONmrMLReader.h/.m`)**

SAX-based nmrML parser, same `NSXMLParser` approach as the mzML reader.

Key nmrML elements:
- `<nmrML>` → root
- `<acquisition>` / `<acquisition1D>` → acquisition parameters
- `<fidData>` → base64-encoded complex128 FID (interleaved real+imaginary pairs as float64)
- `<spectrum1D>` → processed spectrum
- `<spectrumList>` → list of processed spectra
- `<cvParam>` → uses nmrCV accessions (e.g., `NMR:1000001` for spectrometer frequency)

**CV term mappings needed:**
- `NMR:1000001` → spectrometer frequency (MHz)
- `NMR:1000002` → nucleus type (1H, 13C, etc.)
- `NMR:1400014` → sweep width
- `NMR:1000003` → number of scans
- `NMR:1000004` → dwell time

Add nmrCV mappings to `MPGOCVTermMapper` or create a parallel `MPGONmrCVTermMapper`.

### Tests

- Parse nmrML example file → verify FID array (real + imaginary)
- Verify acquisition parameters (frequency, nucleus, sweep width)
- Processed 1D spectrum import if present
- Full round-trip: nmrML → MPGO → .mpgo → read → verify
- Error handling: invalid XML

### Acceptance criteria

- [ ] FID data arrays match reference
- [ ] Acquisition parameters correctly mapped
- [ ] Round-trip verification
- [ ] Error handling

---

## Milestone 14 — Digital Signatures + Integrity Verification

**Track:** B5
**License:** LGPL-3.0

### Classes to implement

**`MPGOSignatureManager` (`Protection/MPGOSignatureManager.h/.m`)**

```objc
@interface MPGOSignatureManager : NSObject

// Sign a dataset within an open .mpgo file
+ (BOOL)signDataset:(NSString *)datasetPath
             inFile:(NSString *)filePath
            withKey:(NSData *)hmacKey
              error:(NSError **)error;

// Verify a dataset's signature
+ (BOOL)verifyDataset:(NSString *)datasetPath
               inFile:(NSString *)filePath
              withKey:(NSData *)hmacKey
                error:(NSError **)error;

// Sign a provenance chain
+ (BOOL)signProvenanceInRun:(NSString *)runPath
                     inFile:(NSString *)filePath
                    withKey:(NSData *)hmacKey
                      error:(NSError **)error;

// Verify the entire provenance chain
+ (BOOL)verifyProvenanceInRun:(NSString *)runPath
                       inFile:(NSString *)filePath
                      withKey:(NSData *)hmacKey
                        error:(NSError **)error;

@end
```

**`MPGOVerifier` (`Protection/MPGOVerifier.h/.m`)**

Higher-level verification API:

```objc
typedef NS_ENUM(NSUInteger, MPGOVerificationStatus) {
    MPGOVerificationStatusValid,
    MPGOVerificationStatusInvalid,
    MPGOVerificationStatusNotSigned,
    MPGOVerificationStatusError
};

@interface MPGOVerifier : NSObject
+ (MPGOVerificationStatus)verifyDataset:(NSString *)path
                                 inFile:(NSString *)filePath
                                withKey:(NSData *)key
                                  error:(NSError **)error;
@end
```

**Implementation:** Use HMAC-SHA256 via OpenSSL (`HMAC()` from `<openssl/hmac.h>`, already linked). Read the raw HDF5 dataset bytes, compute HMAC, store/compare as a base64-encoded HDF5 attribute named `@mpgo_signature` on the dataset. Files with signatures include `opt_digital_signatures` in `@mpeg_o_features`.

### Tests

- Sign intensity channel → verify → PASS
- Tamper one byte → verify → FAIL with descriptive error
- Sign provenance chain → verify chain → PASS
- Unsigned dataset → `MPGOVerificationStatusNotSigned`
- Signed file still readable by `h5dump`
- 1M-element float64 sign+verify < 100ms

### Acceptance criteria

- [ ] Tamper detection works
- [ ] Chain verification works
- [ ] Unsigned datasets handled gracefully
- [ ] HDF5 tool compatibility preserved
- [ ] Performance target met

---

## Milestone 15 — Format Specification + v0.2.0 Release

**Track:** Cross-cutting

### Documentation deliverables

**`docs/format-spec.md`** — standalone specification of the `.mpgo` HDF5 layout:

- Every HDF5 group with its path, required/optional status, and purpose
- Every HDF5 dataset with its path, datatype, dimensionality, chunking parameters, and compression
- Every HDF5 attribute with its path, datatype, and semantics
- All compound type definitions with field names, types, and offsets
- The feature flag mechanism and registry
- Versioning rules (what constitutes major vs minor changes)
- Example `h5dump` output for a minimal valid `.mpgo` file

This document must be detailed enough for a Python developer to implement a conforming reader without looking at the Objective-C source.

**`docs/feature-flags.md`** — registry of all feature strings, their semantics, and which milestone introduced them.

### Conformance test fixtures

Create 5–8 reference `.mpgo` files in `objc/Tests/Fixtures/`:

1. `minimal_ms.mpgo` — single MS run, 10 spectra, no identifications
2. `full_ms.mpgo` — MS run with identifications, quantifications, provenance
3. `nmr_1d.mpgo` — NMR 1D spectra
4. `nmr_2d.mpgo` — NMR 2D spectrum (native layout)
5. `ms_image.mpgo` — small MSImage
6. `encrypted.mpgo` — selective encryption on intensity channel
7. `signed.mpgo` — signed intensity channel with provenance
8. `v0.1_compat.mpgo` — file written by v0.1 code (JSON metadata, parallel index)

Each fixture has expected values documented in `objc/Tests/Fixtures/README.md`.

### Final verification

- All milestones 9–14 complete with tests green
- v0.1.0-alpha `.mpgo` files readable by v0.2.0 code
- CI includes mzML and nmrML parse + round-trip tests
- No warnings under `-Wall -Wextra`
- Update `README.md` with new sections on import/export and versioning
- Update `ARCHITECTURE.md` to remove the v0.1 simplification notes (they are now resolved)
- Update `WORKPLAN.md` to add milestones 9–15 with checked acceptance criteria

### Release

```bash
git tag -a v0.2.0 -m "MPEG-O v0.2.0: mzML/nmrML import, modality-agnostic runs, compound HDF5 types, digital signatures, formal versioning"
git push origin v0.2.0
```

---

## Known Gotchas

1. **HDF5 paths differ by install method.** Ubuntu apt: `/usr/include/hdf5/serial/` and `/usr/lib/x86_64-linux-gnu/hdf5/serial/`. Source builds: `/usr/local`. The preamble accepts `HDF5_PREFIX` on the command line.

2. **`Testing.h` uses `NSAutoreleasePool`, which ARC forbids.** `objc/Tests/GNUmakefile.preamble` applies `-fno-objc-arc` to the test binary. Preserve this split.

3. **GNUStep Make's `test-tool.make` does not auto-run.** The top-level `objc/GNUmakefile` has a custom `check::` target that explicitly invokes the test binary with `LD_LIBRARY_PATH` extended.

4. **Runtime ABI auto-detection** probes `libgnustep-base.so` for `._OBJC_CLASS_NSObject` (v2) vs `_OBJC_CLASS_NSObject` (v1). Follow the `ifeq ($(MPGO_OBJC_RUNTIME),gnustep-2.0)` pattern for any new toolchain flags.

5. **`-fblocks` is gated on gnustep-2.0 only.** libMPGO must not depend on blocks-based APIs.

6. **Windows authoring quirk.** `.gitattributes` forces LF. If `git diff` shows whole-file changes, fix with `git add --renormalize .`

7. **`NSXMLParser` availability.** GNUStep's `NSXMLParser` requires `libxml2`. The CI workflow already installs `libxml2-dev`. Verify it is present on the local machine before starting Milestone 9.

8. **Variable-length HDF5 strings.** Creating VL string datasets requires `H5Tcopy(H5T_C_S1)` + `H5Tset_size(H5T_VARIABLE)`. VL strings in compound types need careful memory management — HDF5 allocates the string data on read, and the caller must free it with `H5Dvlen_reclaim()` (or `H5Treclaim()` in newer HDF5). Wrap this carefully in the compound type reader.

9. **mzML `<referenceableParamGroup>`.** These are defined once and referenced by ID from multiple spectra. The parser must resolve these references during parsing. A common pattern: store them in an `NSDictionary<NSString *, NSArray<MPGOCVParam *> *>` keyed by `id`, then expand inline when `<referenceableParamGroupRef ref="..."/>` is encountered.

10. **mzML base64 text across multiple callbacks.** `NSXMLParser` may deliver the text content of a `<binary>` element across multiple `parser:foundCharacters:` calls. Always accumulate into an `NSMutableString` and decode only in `parser:didEndElement:`.

---

## Dependency Graph

```
  Milestone 9 (mzML Reader)
       │
       ▼
  Milestone 10 (Protocol Conformance + Agnostic Runs)
       │
       ▼
  Milestone 11 (Compound Types + Headers + Feature Flags)
       │
       ├───────────────────────┐
       ▼                       ▼
  Milestone 12              Milestone 13
  (MSImage + 2D NMR)        (nmrML Reader)
       │                       │
       └───────────┬───────────┘
                   ▼
            Milestone 14
            (Digital Signatures)
                   │
                   ▼
            Milestone 15
            (Format Spec + v0.2.0)
```

Milestones 12 and 13 can proceed in parallel. Milestone 14 depends on both.

---

## Execution Checklist

1. Pull repo, read all referenced files, verify local build (379 tests).
2. **Milestone 9:** Commit LICENSE-IMPORT-EXPORT, implement mzML reader, test, push. Pause for user review.
3. **Milestone 10:** Protocol conformance + agnostic runs. Pause for user review.
4. **Milestone 11:** Compound types + feature flags. Pause for user review.
5. **Milestones 12 + 13:** MSImage/2D NMR + nmrML reader. Pause for user review.
6. **Milestone 14:** Digital signatures. Pause for user review.
7. **Milestone 15:** Format spec, conformance fixtures, release prep. Tag v0.2.0.

**CI must be green before any milestone is considered complete.** Do not push milestone commits on a red build. If CI breaks, fix it before proceeding.
