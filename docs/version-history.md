# TTI-O Version History

This document preserves the release-by-release feature narrative for TTI-O. The
[README](../README.md) presents features flat, in their present-tense current
form; this file tracks *when* each capability landed, for historians,
compatibility engineers, and anyone wiring a reader against a specific format
version.

For per-milestone detail (acceptance criteria, binding decisions, gotchas) see
[`../WORKPLAN.md`](../WORKPLAN.md) and [`../CHANGELOG.md`](../CHANGELOG.md).

## v0.1.0-alpha — Objective-C foundation

* **Foundation** — five capability protocols (`TTIOIndexable`, `TTIOStreamable`, `TTIOCVAnnotatable`, `TTIOProvenanceable`, `TTIOEncryptable`) plus the immutable value classes `TTIOValueRange`, `TTIOEncodingSpec`, `TTIOAxisDescriptor`, `TTIOCVParam`.
* **HDF5 wrappers** — thin Cocoa wrappers over the libhdf5 C API (`TTIOHDF5File`, `TTIOHDF5Group`, `TTIOHDF5Dataset`, `TTIOHDF5Errors`, `TTIOHDF5Types`) supporting `float32` / `float64` / `int32` / `int64` / `uint32` / `complex128` (compound), chunked storage, and zlib compression. Hyperslab partial reads, automatic runtime ABI detection, and `NSError` out-parameters on every fallible call.
* **Signal arrays** — `TTIOSignalArray` is the atomic typed-buffer unit, conforms to `TTIOCVAnnotatable`, and round-trips through HDF5 with axis descriptors and JSON-encoded CV annotations.
* **Spectrum classes** — `TTIOSpectrum` base plus `TTIOMassSpectrum`, `TTIONMRSpectrum`, `TTIONMR2DSpectrum`, `TTIOFreeInductionDecay` (Complex128-backed), and `TTIOChromatogram` (TIC/XIC/SRM).
* **Acquisition runs** — `TTIOAcquisitionRun` conforms to `TTIOIndexable` + `TTIOStreamable`. Writing channelizes every spectrum into contiguous `mz_values` + `intensity_values` datasets; reading is lazy and uses HDF5 hyperslab selection so a random-access spectrum read only touches its own chunks. `TTIOSpectrumIndex` carries seven parallel scan-metadata arrays (offsets, lengths, RT, MS level, polarity, precursor m/z, base peak) for compressed-domain queries.
* **Spectral datasets** — `TTIOSpectralDataset` is the root `.tio` container object. Holds named MS runs, named NMR-spectrum collections, identifications, quantifications, W3C PROV provenance records, and SRM/MRM transition lists. Multi-run round-trip and provenance lookup by input ref are first-class.
* **MS imaging** — `TTIOMSImage` stores a 3-D `[height, width, spectralPoints]` HDF5 dataset with tile-aligned chunking; tile reads (default 32×32 pixels) hit exactly the chunks they need.
* **Selective encryption** — `TTIOEncryptionManager` (AES-256-GCM via OpenSSL) encrypts an acquisition run's intensity channel in place while leaving `mz_values` and the spectrum index readable as plaintext. Wrong keys fail cleanly via GCM tag mismatch — never partial bytes. `TTIOAccessPolicy` persists JSON-encoded subject/stream/key-id metadata under `/protection/access_policies` independently of any key store.
* **Query + streaming** — `TTIOQuery` builds compressed-domain predicates (RT range, MS level, polarity, precursor m/z range, base peak threshold) over an in-memory index without touching signal channels; a 10k-spectrum scan runs in ~0.2 ms in CI. `TTIOStreamWriter` / `TTIOStreamReader` provide incremental write + sequential read over runs of arbitrary size.

CI runs every push on `ubuntu-latest` with **clang + libobjc2 + gnustep-base built from source** (the `gnustep-2.0` non-fragile ABI), then exercises the full test suite.

## v0.2.0 — importers, feature flags, dataset-level encryption

* **mzML import** — `TTIOMzMLReader` is a SAX parser (`NSXMLParser`) that consumes PSI-MS mzML 1.1 files, decodes base64 binary arrays (with optional zlib inflate), maps CV accessions via `TTIOCVTermMapper`, and produces an `TTIOSpectralDataset` with a populated MS run. Tested against the canonical `tiny.pwiz.1.1.mzML` and `1min.mzML` fixtures from HUPO-PSI.
* **nmrML import** — `TTIONmrMLReader` handles nmrML 1.0+ including vendor-realistic files: element-based acquisition parameters, int32/int64 FID payloads widened to complex128 on import, dimension scale extraction. Validated against `bmse000325.nmrML` from the BMRB via the nmrML project.
* **Modality-agnostic runs** — `TTIOAcquisitionRun` now accepts any `TTIOSpectrum` subclass. Signal channel serialization is name-driven (`<channel>_values`), so MS runs are binary-compatible with v0.1 while NMR runs produce `chemical_shift_values` + `intensity_values`. Runs formally conform to `<TTIOProvenanceable>` + `<TTIOEncryptable>` with per-run provenance chains, protocol-based encrypt/decrypt delegating to `TTIOEncryptionManager`.
* **Native HDF5 compound types** — identifications, quantifications, and dataset-level provenance migrate from JSON string attributes to native HDF5 compound datasets with variable-length C strings. Spectrum index carries an optional rank-1 `headers` compound dataset for `h5dump` readability alongside the parallel 1-D arrays. `TTIOHDF5CompoundType` wraps `H5Tcreate(H5T_COMPOUND, ...)` with VL string helpers.
* **Feature flags + format version** — every v0.2 file carries `@ttio_format_version = "1.1"` and a JSON array `@ttio_features` on the root group. `TTIOFeatureFlags` provides the registry; `opt_`-prefixed features are informational while non-prefixed features are required.
* **Dataset-level encryption** — `TTIOSpectralDataset` conforms to `<TTIOEncryptable>` end-to-end. A single `encryptWithKey:level:error:` call encrypts every run's intensity channel, seals the compound identification/quantification datasets, and writes the `@encrypted` root marker and `@access_policy_json`. `-closeFile` releases the HDF5 handle so the encryption manager can reopen read-write.
* **MSImage inheritance** — `TTIOMSImage` inherits from `TTIOSpectralDataset`, so image datasets carry identifications/quantifications/provenance/access-policy for free. The 3-D cube lives at `/study/image_cube/` with spatial metadata (`pixelSizeX/Y`, `scanPattern`); v0.1 `/image_cube/` layout remains readable via auto-detection.
* **Native 2-D NMR** — `TTIONMR2DSpectrum` writes a proper rank-2 HDF5 dataset (`intensity_matrix_2d`) with F1/F2 dimension scales attached via `H5DSattach_scale`. Readers prefer the native 2-D form and fall back to the v0.1 flattened 1-D array.
* **HMAC-SHA256 digital signatures** — `TTIOSignatureManager` signs HDF5 dataset bytes and provenance chains; `TTIOVerifier` reports Valid/Invalid/NotSigned/Error. 1M-element float64 sign + verify runs in ~15 ms combined.
* **Format specification** — [`format-spec.md`](format-spec.md) documents every group, dataset, attribute, and compound type in enough detail for a conforming Python/Rust/Go reader. [`feature-flags.md`](feature-flags.md) is the feature string registry. Reference `.tio` fixtures under `objc/Tests/Fixtures/ttio/` (generated by `objc/Tools/MakeFixtures`) provide canonical smoke-test files.

v0.1 `.tio` files written by libTTIO v0.1.0-alpha remain fully readable by v0.2.0 code — the readers detect the absence of `@ttio_features` and dispatch to JSON fallback paths.

## v0.3.0 — Python parity, canonical signatures, mzML writer, cloud

* **Python `ttio` package** — a full reader/writer for the `.tio` format built on `h5py` + `numpy`, mirroring the ObjC class hierarchy 1-to-1. Ships an editable layout under `python/src/ttio/` with `importers/` (mzML + nmrML), `exporters/` (mzML), and `_numpress` codec helpers. PyPI name: **`ttio`** (import as `ttio`). Requires Python 3.11+. Every v0.2 reference fixture (`minimal_ms`, `full_ms`, `nmr_1d`, `encrypted`, `signed`) is loaded byte-compatibly by the Python reader, and a new `TtioVerify` + `TtioSign` ObjC CLI pair tests the other direction (Python-written files decoded by the ObjC reference reader).
* **Compound per-run provenance** — `TTIOAcquisitionRun` persists its provenance chain as a compound HDF5 dataset at `/study/ms_runs/<run>/provenance/steps`, reusing the 5-field type from dataset-level `/study/provenance`. The legacy `@provenance_json` mirror is kept in place so the v0.2 signature manager continues to work. Feature flag: `compound_per_run_provenance`.
* **Canonical byte-order signatures** — `TTIOSignatureManager` now hashes a canonical little-endian byte stream (atomic numeric datasets via LE memory types, compound datasets field-by-field with VL strings emitted as `u32_le(len) || bytes`). Signatures carry a `"v2:"` prefix; v0.2 native-byte signatures remain verifiable via an automatic fallback path. Cross-language byte-identical MACs between ObjC and Python by construction. Feature flag: `opt_canonical_signatures`.
* **mzML writer** — `TTIOMzMLWriter` + `ttio.exporters.mzml` emit indexed-mzML from a `SpectralDataset`, with byte-correct `<indexList>` offsets per spectrum and optional zlib compression of binary arrays. Licensed Apache-2.0 alongside the import layer.
* **Cloud-native access (Python)** — `SpectralDataset.open("s3://bucket/file.tio")` routes URLs through `fsspec`. HTTP, S3, GCS, and Azure backends are supported through fsspec plugins; the reader pulls only the HDF5 metadata and a handful of chunks per touched spectrum. Benchmark: 10 random spectra from a 15 MB remote file in ~50 ms, ~24% of file bytes transferred.
* **LZ4 + Numpress-delta compression** — optional signal-channel codecs. LZ4 via HDF5 filter 32004 (plugin-gated, skipped cleanly at runtime when unavailable) is ~35× faster on write / ~2× faster on read than zlib. Numpress-delta is a clean-room implementation of Teleman et al. 2014 (*MCP* 13(6)) with sub-ppm relative error for typical m/z data. Both codecs are cross-language byte-identical between ObjC and Python.

## v0.4.0 — threading, chromatograms, envelope encryption, ISA, anonymization

* **Thread safety (M23)** — `TTIOHDF5File` carries a `pthread_rwlock_t` that serializes writes and allows concurrent reads. Python side: opt-in `SpectralDataset.open(..., thread_safe=True)` with a writer-preferring `RWLock`. Degrades to exclusive locking on non-threadsafe libhdf5 builds.
* **Chromatogram API (M24)** — `TTIOAcquisitionRun.chromatograms` persists TIC/XIC/SRM traces under `<run>/chromatograms/` with a parallel-array chromatogram index. mzML writer emits `<chromatogramList>` + `<index name="chromatogram">` with byte-correct offsets; reader parses them back.
* **Envelope encryption + key rotation (M25)** — DEK encrypts data, KEK wraps DEK. `/protection/key_info/` stores the 60-byte wrapped DEK blob + KEK metadata. Rotation re-wraps in O(1) without touching signal datasets. Feature flag: `opt_key_rotation`.
* **ISA-Tab / ISA-JSON export (M27)** — `TTIOISAExporter` / `ttio.exporters.isa` produces investigation/study/assay TSV files + ISA-JSON from a `SpectralDataset`. Licensed Apache-2.0.
* **Spectral anonymization (M28)** — policy-based pipeline (SAAV redaction, intensity masking, m/z coarsening, rare-metabolite suppression, metadata stripping) that reads a dataset and writes a new `.tio`. Audit trail via provenance record. Feature flag: `opt_anonymized`.
* **nmrML writer (M29)** — serializes `NMRSpectrum` + FID to nmrML XML with acquisition parameters and base64 spectrum arrays. Round-trips through the existing nmrML reader.
* **Thermo RAW stub (M29)** — `TTIOThermoRawReader` / `ttio.importers.thermo_raw` stub; returns not-implemented error with SDK guidance. See [`vendor-formats.md`](vendor-formats.md).

## v0.5.0 — three-language parity (Java joins)

* **Three-language parity** — Java implementation (`global.thalion.ttio`, JDK 17 + Maven) reaches full behavioural parity with the Objective-C reference and Python reader/writer. Every cross-language round-trip test in the matrix passes byte-for-byte, driven by shared format fixtures.
* **Canonical byte-order signatures across languages** — `v2:` HMAC-SHA256 signatures (Appendix B in [`format-spec.md`](format-spec.md)) verify identically whether produced by Objective-C, Python, or Java, validating the canonical little-endian byte layout at the implementation level.
* **Compound metadata round-trip across languages** — identifications / quantifications / dataset-level provenance round-trip through all three languages (native compound datasets in HDF5; Python / Java write a JSON attribute mirror so JHI5 1.10's missing VL-in-compound support doesn't block interop).

## v0.6.0 / v0.6.1 — storage provider abstraction

* **Storage provider abstraction (M39)** — `StorageProvider` / `StorageGroup` / `StorageDataset` (`TTIOStorageProtocols.h` in ObjC; `global.thalion.ttio.providers` in Java; `ttio.providers` in Python). `open_provider("scheme://...")` resolves the right backend by URL scheme. `Hdf5Provider` wraps the existing layer; `MemoryProvider` ships alongside as a transient-state backend that proves the contract by construction.
* **SQLiteProvider (M41, v0.6.1)** — fourth-backend validation: the full group/dataset/attribute/compound tree stored as SQLite rows. Uses the standard-library `sqlite3` module, no extra deps.
* **Native Thermo RAW import (M35)** — `TTIOThermoRawReader` shells out to `ThermoRawFileParser` and ingests the resulting mzML. See [`vendor-formats.md`](vendor-formats.md).
* **ROS3 cloud reads (M42, v0.6.1)** — `SpectralDataset.open("s3://...")` streams HDF5 metadata + chunks directly over S3 / HTTPS via libhdf5's ROS3 VFD.
* **Full API documentation (M38, v0.6.1)** — Sphinx HTML docs, Javadoc HTML, and an expanded ObjC gsdoc landing page all exposed under `docs/api/`.
* **Appendix B gap closures (v0.6.1)** — six cross-language polish items from the v0.6 API review: primitive-row compound read normalisation (`read_rows`), delete_attribute, capability-query methods, unified `open()` dispatch, attribute-names listing, `provider_name()` / docstrings converged.

## v0.7.0 — byte-level protocol, crypto agility, PQC prep

* **Byte-level storage protocol (M43)** — `StorageDataset.read_canonical_bytes()` / `-readCanonicalBytesAtOffset:count:error:` — the protocol-native path for signatures and encryption. Canonical byte stream is little-endian regardless of backend or host endianness; every provider (HDF5, Memory, SQLite, Zarr) returns bit-equal bytes for the same logical data. Binding decision 37.
* **AcquisitionRun + MSImage protocol-native access (M44)** — the hot-path spectrum slice read goes through `StorageDataset` instead of reaching for `h5py.Dataset` / `TTIOHDF5Dataset` / `Hdf5Dataset` directly. `AcquisitionRun`'s instance state now holds only protocol types across all three languages.
* **Full-rank N-D datasets (M45)** — `create_dataset_nd` completes on Memory and SQLite providers using a flat-BLOB + `@__shape_<name>__` attribute pattern that preserves rank through the protocol. Hdf5Provider gets the same pattern; v0.8 may add native `H5Screate_simple` storage as an optimisation.
* **ZarrProvider Python reference (M46, stretch)** — fourth storage backend, validates the abstraction against the Zarr spec. URL schemes: `zarr:///path/to/store.zarr` (directory), `zarr+memory://<name>`, `zarr+s3://bucket/key` (via fsspec). Canonical-bytes parity verified against HDF5. Java + ObjC ports deferred to v0.8 per binding decision 41. (Migrated to the Zarr v3 on-disk format in v0.9.)
* **Versioned wrapped-key blob format (M47)** — `[magic "MW" | version 0x02 | algorithm_id | ct_len | md_len | metadata | ciphertext]`, replacing the fixed 60-byte AES-GCM-only v1.1 blob. v1.1 blobs remain readable by v0.7+ indefinitely (binding decision 38). Reserved algorithm IDs for ML-KEM-1024, ML-DSA-87, SHAKE-256. Feature flag: `wrapped_key_v2`.
* **Crypto algorithm agility (M48)** — `CipherSuite` static catalog (AEAD / KEM / MAC / Signature / Hash / XOF). `encrypt_bytes(..., algorithm=...)`, `sign_dataset(..., algorithm=...)`, `enable_envelope_encryption(..., algorithm=...)` gained opt-in `algorithm=` parameters; default remains AES-256-GCM / HMAC-SHA256 for backward compat. Binding decision 39 — fixed allow-list, not plugin-registered.
* **Cross-language compound byte-parity harness (M51, stretch)** — three new dumper CLIs (`python -m ttio.tools.dump_identifications`, Java `DumpIdentifications`, ObjC `TtioDumpIdentifications`) emit identifications / quantifications / provenance as byte-identical canonical JSON. `test_compound_writer_parity.py` pairwise-diffs the three outputs; any divergence fails the test. Caught + fixed a Java `H5T_NATIVE_UINT64` precision-probe bug on the way in.
* **Cross-language polish (M50)** — six independent sub-items: unified `open()` docs, ObjC `-readRowsWithError:` made @required, Java typed importer exception hierarchy, Java `@since` audit, cross-language error-domain mapping appendix ([`api-review-v0.7.md`](api-review-v0.7.md) §C), Appendix B Gap 7 cross-references.

## v0.8.0 — post-quantum crypto, Zarr across languages, Bruker timsTOF

* **Post-quantum crypto (M49 + M49.1)** — ML-KEM-1024 (FIPS 203) envelope key-wrap and ML-DSA-87 (FIPS 204) dataset signatures. New `v3:` signature-attribute prefix and `opt_pqc_preview` feature flag. Python and Objective-C use [`liboqs`](https://github.com/open-quantum-safe/liboqs) (via `liboqs-python` and direct C linkage); Java uses Bouncy Castle 1.80+. Library-choice rationale and wire-format reference: [`pqc.md`](pqc.md). Opt-in via `pip install 'ttio[pqc]'`; AES-256-GCM + HMAC-SHA256 remain the defaults.
* **Java + Objective-C `ZarrProvider` ports (M52)** — self-contained LocalStore implementations. No external zarr library dependency; on-disk layout matches the Python reference (v0.7 M46) so all three languages cross-read one another's stores. Compound datasets use the Python convention (sub-group + `_mpgo_kind="compound"` + `_mpgo_schema` + `_mpgo_rows` JSON attrs). In-memory (`zarr+memory://`) and S3 (`zarr+s3://`) schemes remain Python-only. (On-disk format migrated from Zarr v2 to v3 in v0.9.)
* **Bruker timsTOF `.d` importer (M53)** — SQLite metadata reads natively in every language (uses `java.sql` in Java, `libsqlite3` in ObjC, stdlib `sqlite3` in Python). Binary frame decompression uses [`opentimspy`](https://pypi.org/project/opentimspy/) + `opentims-bruker-bridge` in Python and subprocesses into the Python helper from Java / ObjC — no proprietary Bruker SDK involved. New **`inv_ion_mobility` signal channel** preserves the 2-D timsTOF geometry per-peak. Install with `pip install 'ttio[bruker]'`. Details: [`vendor-formats.md`](vendor-formats.md).
* **Cross-language PQC conformance matrix (M54 + M54.1)** — 32-cell verification matrix across all three languages and four providers: primitive ML-DSA / ML-KEM sign-verify-encaps-decaps, `v3:` dataset signatures on HDF5 / Zarr / SQLite, v2+v3 coexistence on the same file, v0.7 classical backward-compat. New `global.thalion.ttio.tools.PQCTool` (Java) and `TtioPQCTool` (ObjC) CLIs drive the Python pytest harness. Python `sign_storage_dataset` / `verify_storage_dataset` provider-agnostic helpers let PQC signatures ride any storage backend for free.
* **v1.0 API stability audit (M55)** — every public API classified Stable / Provisional / Deprecated across the three languages in new [`api-stability-v0.8.md`](api-stability-v0.8.md). Deprecation ledger identifies five APIs scheduled for removal at v1.0 (file-path intensity-channel helpers, `nativeHandle()`, v1 HMAC fallback). Comprehensive [`../CHANGELOG.md`](../CHANGELOG.md) covering v0.1-alpha through v0.8.

## v0.9.x — provider hardening, exporter fidelity

* **Provider abstraction hardening** — SQLite and Zarr v3 backends in all three languages with byte-parity on compound records and canonical bytes. On-disk Zarr format migrated from v2 to v3. See [`providers.md`](providers.md).
* **Exporter fidelity (v0.9.1)** — mzTab exporter (proteomics 1.0 + metabolomics 2.0.0-M dialects), imzML exporter (continuous + processed modes, UUID normalisation), nmrML `<spectrum1D>` content-model fix (interleaved `(x,y)` with auto-detect on read), and compound-per-entity extensions.

## v0.10.0 — streaming transport, per-AU encryption

* **Streaming transport layer (M66–M72)** — `.tis` packet codec with 24-byte headers and nine packet types (StreamHeader, DatasetHeader, AccessUnit, ProtectionMetadata, Annotation, Provenance, Chromatogram, EndOfDataset, EndOfStream). Three-language parity in Python / ObjC / Java. Bidirectional conformance test matrix: any writer pairs with any reader. See [`transport-spec.md`](transport-spec.md).
* **WebSocket client + server (M68 / M68.5)** — libwebsockets for ObjC, `websockets` for Python, Java-WebSocket for Java. Stream `.tio` datasets as `.tis` with optional CRC-32C per packet.
* **Acquisition simulator (M69)** — replays a fixture at wall-clock pace to exercise client / server scheduling.
* **Selective access + ProtectionMetadata (M71)** — per-packet `AUFilter` for client-driven filtering without decryption; ProtectionMetadata packet carries `cipher_suite`, `kek_algorithm`, `wrapped_dek`, `signature_algorithm`, `public_key`.
* **Per-Access-Unit encryption (v1.0 scope)** — `opt_per_au_encryption` feature flag with the `<channel>_segments` VL_BYTES compound layout (see [`format-spec.md`](format-spec.md) §9.1). Each spectrum is a separate AES-256-GCM op with fresh IV and AAD = `dataset_id || au_sequence || channel_name`; ciphertext cannot be replayed against a different AU or envelope. Optional `opt_encrypted_au_headers` additionally encrypts the 36-byte semantic header into `spectrum_index/au_header_segments`. Full design in [`transport-encryption-design.md`](transport-encryption-design.md).
* **Cross-language CLIs + conformance harness** — `per_au_cli` (Python), `PerAUCli` (Java), `TtioPerAU` (ObjC) all expose `{encrypt, decrypt, send, recv, transcode}` subcommands. `decrypt` emits a canonical "MPAD" binary dump so the test harness can byte-compare decryption artefacts across every language pair. 38/38 combinations pass. The `transcode` subcommand supports `--rekey` for DEK rotation and refuses v0.x `opt_dataset_encryption` inputs with a migration hint.
* **VL_BYTES compound field kind** — new across all three languages' provider abstraction. Java's HDF5 provider uses a native `hvl_t` raw-buffer pool backed by `sun.misc.Unsafe` because JHI5 1.10 doesn't marshal VL-in-compound directly.

## v0.11.0 — Raman + IR, JCAMP-DX

* **Vibrational spectroscopy (M73)** — Raman and IR become first-class modalities alongside MS and NMR. Four new domain classes per language: `RamanSpectrum` / `IRSpectrum` (keyed by `wavenumber` + `intensity`, with excitation/laser/integration and mode/resolution/scans metadata respectively) plus `RamanImage` / `IRImage` (rank-3 intensity cubes with a shared wavenumber axis). HDF5 layout: `/study/raman_image_cube/` and `/study/ir_image_cube/` mirror the existing MSImage tile chunking. See [`format-spec.md`](format-spec.md) §7a and [`class-hierarchy.md`](class-hierarchy.md) Layer 3c.
* **JCAMP-DX 5.01 AFFN bridge** — native reader and writer in all three languages for the `##XYDATA=(X++(Y..Y))` dialect. Writers emit LDRs in a fixed order with `%.10g` formatting, producing byte-identical output for identical input. Readers dispatch on `##DATA TYPE=` (RAMAN SPECTRUM / INFRARED ABSORBANCE / INFRARED TRANSMITTANCE, with INFRARED SPECTRUM falling back to `##YUNITS=`). 2-D NTUPLES is intentionally out of scope. See [`vendor-formats.md`](vendor-formats.md). *(Compression variants added in v0.11.1.)*
* **New `IRMode` enum** — `TRANSMITTANCE=0`, `ABSORBANCE=1`. Present in all three languages (Python: `ttio.IRMode`, Java: `global.thalion.ttio.Enums.IRMode`, ObjC: `TTIOIRMode`).
* **Cross-language JCAMP-DX conformance** — 6 new integration tests compare bit-for-bit parses across Python↔Java and Python↔ObjC. ObjC CLI `TtioJcampDxDump` joins the existing CLI family as the subprocess driver.

## v0.11.1 — JCAMP-DX compression, UV/Vis, 2D-COS

* **JCAMP-DX 5.01 compression reader (PAC / SQZ / DIF / DUP)** — all three languages now decode the full §5.9 compressed `##XYDATA` dialect. Auto-detected by a sentinel-char scan that excludes `e`/`E` so AFFN scientific notation doesn't false-trigger; delegates to `ttio.importers._jcamp_decode` (Python), `global.thalion.ttio.importers.JcampDxDecode` (Java), or `TTIOJcampDxDecode` (ObjC). Writers remain AFFN-only — bit-accurate round-trips are worth more than the byte savings at this stage.
* **`UVVisSpectrum` class** — 1-D UV/visible absorption spectrum keyed by `"wavelength"` (nm) + `"absorbance"`, with `pathLengthCm` + `solvent` metadata, in all three languages. JCAMP-DX reader dispatches `UV/VIS SPECTRUM`, `UV-VIS SPECTRUM`, and `UV/VISIBLE SPECTRUM` variants to this class; writer emits `##DATA TYPE=UV/VIS SPECTRUM` with `##XUNITS=NANOMETERS` + `##YUNITS=ABSORBANCE` and `##$PATH LENGTH CM` / `##$SOLVENT` custom LDRs.
* **`TwoDimensionalCorrelationSpectrum` class** — Noda 2D-COS representation with rank-2 synchronous (in-phase) and asynchronous (quadrature) correlation matrices sharing a single variable axis (`nu_1 == nu_2`). Row-major `float64`, size-by-size; construction validates rank, matching shape, and squareness. Gated behind the new `opt_native_2d_cos` feature flag. Present in all three languages.

## v0.12.0 — mzTab round-trip completion, MS/MS activation detail, JCAMP-DX compressed writer, 2D-COS compute

* **M74 MS/MS activation method + isolation window metadata** — `ActivationMethod` enum (NONE, CID, HCD, ETD, UVPD, ECD, EThcD) and per-spectrum `isolationTargetMz` / `isolationLowerOffset` / `isolationUpperOffset` / `activationEnergy` fields on `SpectrumIndex` in all three languages. mzML reader populates these from `cvParam` on `<precursor>`/`<activation>`/`<isolationWindow>`; mzML writer emits them with the correct PSI-MS CV accessions (MS:1000133 CID, MS:1000422 HCD, MS:1000598 ETD, MS:1000250 ECD, MS:1003246 UVPD, MS:1003181 EThcD; MS:1000827/828/829 for isolation window). Gated behind the `opt_ms2_activation_detail` feature flag and format version `1.3`; legacy files without M74 columns still read/write as format `1.1`, preserving byte-parity with pre-v0.12 fixtures. Closes the final "must-fix for v1.0" item in `docs/v1.0-gaps.md`.
* **M75 Python CLI parity** — `ttio-verify`, `ttio-sign`, `ttio-pqc` console_scripts registered in `pyproject.toml` backed by the existing `verifier.py` / `signatures.py` / `pqc.py` modules. Brings Python up to the ObjC + Java CLI surface for the three protection tools; subcommand grammar is 1:1 across all three languages.
* **M76 JCAMP-DX compressed-writer emission** — opt-in PAC / SQZ / DIF compression in the JCAMP-DX writer in all three languages, with AFFN still the default for bit-accurate round-trips. Compressed output emits an explicit Y-check token on every non-first line to defeat decoder prev-last-y collisions on plateau boundaries; YFACTOR is chosen per-spectrum as `10 ** (ceil(log10(max_abs)) - 7)` for ~7 significant digits of Y precision; rounding is explicit half-away-from-zero. Gated on a cross-language byte-parity conformance test at `conformance/jcamp_dx/`.
* **M77 2D-COS computation primitives** — generalised synchronous / asynchronous decomposition from a perturbation series using Noda's Hilbert-transform approach, plus a disrelation-spectrum statistical significance test. API (`hilbert_noda_matrix` / `compute` / `disrelation_spectrum`) ships in all three languages against a shared `conformance/two_d_cos/` fixture. Cross-language gate is float-tolerance (rtol=1e-9, atol=1e-12) rather than byte-parity — BLAS accumulation order differs across implementations.
* **M78 mzTab PEH/PEP + SFH/SMF + SEH/SME round-trip** — new `Feature` value class beside `Identification` and `Quantification` in all three languages, carrying `feature_id`, `run_name`, `chemical_entity`, `retention_time_seconds`, `exp_mass_to_charge`, `charge`, `adduct_ion`, `abundances`, and `evidence_refs`. The mzTab reader parses peptide-level PEH/PEP rows (1.0) and small-molecule feature SFH/SMF rows (2.0.0-M); subsequent SEH/SME parsing back-fills the feature's `chemical_entity` from the SME placeholder to `database_identifier` / `chemical_name` / `chemical_formula`. The writer emits those sections with an inverse rank↔confidence mapping (rank N ↔ confidence 1/N). SEH/SME emission is gated on features being present, so plain-SML metabolomics round-trips stay byte-identical with pre-M78 output. Closes the "deferred further" mzTab Feature item in `docs/v1.0-gaps.md`.

## v1.0.0 — First stable release

Pure promote from v0.12.0. No new code; v1.0.0 signals that the public API is SemVer-stable from this tag forward and that `docs/v1.0-gaps.md` Must-fix and Nice-to-have lists are both empty.

* **Package metadata** — `python/pyproject.toml` version 0.8.0 → 1.0.0 with classifier `Development Status :: 5 - Production/Stable`; `java/pom.xml` version 0.8.0 → 1.0.0. (Both files had remained frozen at 0.8.0 through v0.9.0–v0.12.0; git tags were the source of truth for each release.)
* **Not in this tag** — M40 PyPI + Maven Central publishing continues to wait on external account / API-token setup (planned for v1.0.1); mzML `<softwareList>` / `<dataProcessingList>` provenance-chain emission and hyperspectral-image analysis primitives are both scope-expansion, explicitly deferred past v1.0 in `docs/v1.0-gaps.md`.
* **Format version** — container format remains at `1.3` (v0.12.0 M74 bump). No on-disk schema change in v1.0.0.

## v1.2.0 — TTI-O rebrand + genomic stack + transport extension + multi-omics integration (M79–M92, 2026-04-25 → 2026-04-28)

v1.2.0 is the project's largest single-version expansion: an end-to-end genomic data pathway alongside the spectroscopy/spectrometry stack that was the focus of v0.1–v1.0. The work spans a brand rename (M80), a new run-and-element hierarchy modelled on SAM/BAM (M82), a complete five-codec genomic compression library wired into every M82 channel (M83–M86), SAM/BAM and CRAM importers/exporters (M87–M88), genomic transport extension (M89), genomic encryption + anonymisation (M90, 15 sub-mileposts), a multi-omics integration test (M91), a post-M91 OO abstraction polish that unifies the MS and genomic surfaces under a single `Run` protocol with canonical `runs` / `runsForSample` / `runsOfModality` accessors and a per-run-provenance compound dataset dual-write across all three languages (Phase 1+2), and a benchmarking + documentation pass (M92).

### M79 — Modality + genomic enumerations groundwork (2026-04-25)

Reserved enum slots for genomic content: a new `Compression` enum gains `RANS_ORDER0=4`, `RANS_ORDER1=5`, `BASE_PACK=6`, `QUALITY_BINNED=7`, `NAME_TOKENIZED=8`. New `AcquisitionMode.GENOMIC_*` values for read alignment / WGS / WES. New `Modality` enum string ("genomic_sequencing"). Reserved-only — no encoders or decoders yet, but the enum slots commit the wire-level codec ids for cross-language readers to recognise even before the codec library lands.

### M80 — TTI-O rebrand clean sweep (2026-04-25)

Repository-wide renaming of every `mpgo`/`MPGO`/`Mpgo` identifier (and the `mpeg_o` Python package, the `.mpgo` file extension, and the `MO` transport magic bytes) to `ttio`/`TTIO`/`Ttio`/`ttio`/`.tio`/`TI`. Clean break per Binding Decision §74 — no backward compatibility, no dual-read shims. Files written by pre-M80 implementations cannot be read by post-M80 implementations and vice versa. The rationale: TTI-O ("Thalion Initiative") is a name the Thalion organisation owns; the prior `MPEG-O` name implied an MPEG-G derivation that was architectural inspiration only, not a formal MPEG-G profile or extension.

### M81 — Java reverse-DNS correction (2026-04-25)

M80's Java rename used `com.dtwthalion.ttio` as the Maven groupId; M81 corrected it to `global.thalion.ttio` to match Thalion's actual root domain. Pure rename across all Java source, test, and Maven artefact metadata. Filed before any external Maven Central publishing so no released artefact carried the wrong groupId.

### M82 — GenomicRun + AlignedRead + signal-channel layout (2026-04-25, four sub-milestones)

Parallel run-and-element hierarchy alongside the existing spectrum-based classes. New types in all three languages:

* **`GenomicRun`** — lazy view over one aligned-read run; `Indexable<AlignedRead>` + `Streamable<AlignedRead>` + `AutoCloseable`. Per-read access via `run[i]` (Python) / `run.alignedReadAt(i)` (Java) / `[run readAtIndex:]` (ObjC).
* **`AlignedRead`** — per-read value class (`read_name`, `chromosome`, `position`, `mapping_quality`, `cigar`, `sequence`, `qualities`, `flags`, mate-pair info — modelled directly on SAM/BAM).
* **`GenomicIndex`** — parallel-array per-read scalars (offsets, lengths, chromosomes, positions, mapping qualities, flags); supports region / unmapped / flag queries.
* **`WrittenGenomicRun`** — pure write-side container passed to `SpectralDataset.write_minimal(genomic_runs=...)`.

Storage under `/study/genomic_runs/<name>/` mirrors the existing `/study/ms_runs/` layout. `signal_channels/` carries per-base byte arrays (`sequences`, `qualities`), per-read parallel arrays (`positions`, `flags`, `mapping_qualities`), and three VL_STRING compounds (`cigars`, `read_names`, `mate_info`). The sub-milestones were M82.1 (Python reference), M82.2 (ObjC normative), M82.3 (Java parity), M82.4 (cross-language conformance — 9-cell matrix `test_m82_3x3_matrix.py`), and M82.5 (`docs/M82.md` + `ARCHITECTURE.md` divergence-analysis section).

### M83 — rANS entropy codec (2026-04-25)

Clean-room implementation of the range Asymmetric Numeral Systems entropy coder from Duda 2014 (arXiv:1311.2540) — order-0 (marginal) and order-1 (per-context) variants. Wire format, frequency-table normalisation, state width (64-bit unsigned, L=2²³, b=2⁸), and big-endian byte order all explicitly specified for byte-identical output across Python / ObjC / Java. Six canonical conformance fixtures (vectors A/B/C × order 0/1) under `python/tests/fixtures/codecs/rans_*.bin` are the wire-level conformance test vectors. Codec spec at [`codecs/rans.md`](codecs/rans.md). Performance on the M83 reference host: ObjC 181 / 229 MB/s encode/decode; Java 86 / 168 MB/s; Python 7.3 / 6.8 MB/s.

### M84 — BASE_PACK genomic codec + sidecar mask (2026-04-26)

Clean-room 2-bit ACGT packing with a sparse `(position: uint32, original_byte: uint8)` sidecar mask for non-ACGT bytes (`N`, IUPAC ambiguity codes, soft-masking lowercase, gaps). Lossless on the full 256-byte alphabet via the mask. Case-sensitive packing preserves soft-masking convention used by RepeatMasker / BWA / etc. Big-endian bit packing within byte; padding bits in final body byte are zero. Four canonical fixtures (pure ACGT, realistic ~1% N, IUPAC stress, empty). ObjC encode 907 MB/s, decode 2093 MB/s. Codec spec at [`codecs/base_pack.md`](codecs/base_pack.md).

### M85 Phase A — QUALITY_BINNED codec (2026-04-26)

Fixed Illumina-8 / CRUMBLE-derived 8-bin Phred quantisation with 4-bit-packed bin indices, big-endian within byte. Lossy by construction: `decode(encode(x)) == bin_centre[bin_of[x]]` per the bin table (centres 0/5/15/22/27/32/37/40). Hardcoded `scheme_id == 0x00` in v0; future scheme ids reserved for NCBI 4-bin, Bonfield variable-width, etc. Phred values >40 saturate to bin 7 / centre 40. Four canonical fixtures. Codec spec at [`codecs/quality.md`](codecs/quality.md).

### M85 Phase B — NAME_TOKENIZED codec (2026-04-26)

Lean two-token-type columnar codec for read names: numeric digit-runs (without leading zeros) and string non-digit-runs (absorbing leading-zero digit-runs). Per-column type detection picks columnar mode (delta-encoded numeric columns + dictionary-encoded string columns) or verbatim fallback. Achieves ~3-7:1 compression on structured Illumina names. NOT a faithful CRAM 3.1 / Bonfield 2022 implementation — that's a future optimisation milestone if the 20:1 target ever becomes load-bearing. Four canonical fixtures. Codec spec at [`codecs/name_tokenizer.md`](codecs/name_tokenizer.md).

### M86 — Genomic codec pipeline-wiring (six phases, 2026-04-26)

End-to-end integration of the M83/M84/M85 codecs into the `signal_channels/` write/read paths via a per-channel `WrittenGenomicRun.signal_codec_overrides` dict. Each compressed channel carries an `@compression` uint8 attribute holding the M79 codec id; the reader dispatches on that attribute (and, for the schema-lifted channels, on the HDF5 link type). All six phases shipped on 2026-04-26:

* **Phase A — byte channels** (RANS_ORDER0/1, BASE_PACK on `sequences` and `qualities`). Established the per-channel `@compression` attribute scheme, the lazy whole-channel decode + per-instance cache pattern, and the no-double-compression rule (codec output is high-entropy; no HDF5 filter on top).
* **Phase B — integer channels** (RANS_ORDER0/1 on `positions` int64, `flags` uint32, `mapping_qualities` uint8). Defined the int↔byte serialisation contract: arrays serialise to little-endian bytes per element before encoding; reader looks up natural dtype by channel name.
* **Phase C — cigars channel** (RANS_ORDER0/1 + NAME_TOKENIZED). First channel accepting multiple codecs; documented selection guidance (rANS for real WGS data, NAME_TOKENIZED for known-uniform inputs). Schema lift from compound (M82) to flat 1-D uint8.
* **Phase D — qualities QUALITY_BINNED** (codec id 7 added to the qualities byte channel). Validation rejects QUALITY_BINNED on `sequences` (would silently destroy ACGT data via Phred-bin quantisation).
* **Phase E — read_names schema lift + NAME_TOKENIZED** (codec id 8 on a flat-byte `read_names` dataset replacing the M82 compound). First M86 phase doing a compound→flat schema lift.
* **Phase F — mate_info per-field decomposition** (the M82 3-field compound → subgroup with three child datasets `chrom`, `pos`, `tlen`, each independently codec-compressible). First phase introducing HDF5 link-type dispatch (group vs dataset) for a top-level `signal_channels` link. Three new "virtual" channel names (`mate_info_chrom`, `mate_info_pos`, `mate_info_tlen`) in `signal_codec_overrides`; partial overrides allowed.

Cross-language conformance fixtures for every phase under `python/tests/fixtures/codecs/` and `python/tests/fixtures/genomic/`. Selection guidance for the multi-codec channels in [`format-spec.md`](format-spec.md) §10.5–§10.9.

After M86 Phase F, every M82 channel under `signal_channels/` accepts at least one codec, and every M79 codec slot (4–8) is wired into its applicable channels with cross-language byte-exact conformance. The M82-era genomic codec story is functionally complete; remaining future scope is optional optimisation milestones (a custom CIGAR-specific RLE-then-rANS codec for higher peak compression than NAME_TOKENIZED, or a full Bonfield 2022 name tokeniser for the 20:1 target).

### M87 — SAM/BAM importer (2026-04-26)

`BamReader` / `SamReader` (Python), `TTIOBamReader` (ObjC), and `BamReader` (Java) wrap `samtools view -h` as a subprocess (no htslib link); convert SAM/BAM input to `WrittenGenomicRun` instances. The SAM header drives the reference dictionary (`@SQ`), sample + platform (`@RG`), and provenance chain (`@PG`); optional region filter passes through to samtools verbatim. Cross-language `bam_dump` CLI emits canonical JSON byte-identical across Python / ObjC / Java. Requires `samtools` on `PATH` at runtime; the reader class loads without it (the error fires only at first import call).

### M88 + M88.1 — CRAM importer + `bam_dump --reference` flag (2026-04-26)

`CramReader` / `TTIOCramReader` extends the M87 BAM reader with a mandatory reference FASTA argument injected as `samtools view --reference <fasta>`. Reuses the SAM-text parsing path; produces `WrittenGenomicRun` instances with the same shape as the BAM reader. The shared `bam_dump` CLI auto-dispatches to the CRAM reader on `.cram` paths via a new `--reference <fasta>` flag (M88.1), keeping a single CLI surface and a single parity harness file.

### M89 — Transport layer extension for genomic (2026-04-27)

`.tis` GenomicRead AU payload carries a `chromosome + position + mapq + flags` prefix when `spectrum_class == 5` (replaces the zeroed spectral fields M79 reserved). `TransportWriter.write_genomic_run()` / `TransportReader.materialise_genomic_run()` ship in all three languages; `AUFilter` extends with chromosome + position-range predicates so subscribers can scope a stream to a region without decrypting AUs they won't read; MS and genomic runs interleave in a single `.tis` and dispatch per-AU on the `spectrum_class` byte. 3×3 cross-language transport matrix green for both encode and decode directions.

### M90 — Encryption, signatures, and anonymisation for genomic data (2026-04-27 / 2026-04-28, 15 sub-mileposts)

Per-AU AES-256-GCM on genomic signal channels (AAD = `dataset_id || au_sequence || channel_name`); ML-DSA-87 signatures over the chromosomes VL compound dataset (M90.15); region-based encryption keyed on the reserved `_headers` key in the per-region key map (M90.11) — encrypt chr6 / HLA, leave chr1 in clear. Genomic anonymiser (strip read names, randomise quality on a seeded RNG, mask SAM-overlapping regions). MPAD transport debug magic bumped to `"MPA1"` with a per-entry dtype byte (M90.12) so genomic UINT8 channels survive transport without the previous unconditional float64 cast that silently mangled them. Java VL_STRING attribute reader/writer rewired through the canonical JHDF5 `H5Awrite_VLStrings` / `H5Aread_VLStrings` entry points (M90.7); ObjC reader follow-up handles the same wire shape via `H5Tis_variable_str` probe + `H5Dvlen_reclaim`.

### M91 — Multi-omics integration test (2026-04-28)

Single `.tio` carrying a 10K-read WGS genomic run + a 1K-spectrum proteomics MS run + a 100-spectrum NMR metabolomics run, with shared provenance keyed on a common sample URI and a unified encryption envelope. Verifies cross-modality query (`runs_for_sample("sample://NA12878")` returns all three modalities) and `.tis` transport multiplexing across all three languages.

### Phase 1+2 abstraction polish — `Run` protocol + per-run compound provenance dual-write (2026-04-28)

OO design pass on the modality surface driven by M91 findings. Both `AcquisitionRun` and `GenomicRun` now conform to a uniform `Run` protocol (Python `runtime_checkable Protocol`, ObjC `@protocol TTIORun`, Java `interface Run`) exposing `name`, `acquisition_mode`, `__len__` / `count` / `numberOfRuns`, `__getitem__` / `get` / `objectAtIndex:`, and `provenance_chain` / `provenanceChain`. New modality-agnostic accessors on `SpectralDataset`: `runs` (canonical unified mapping), `runs_for_sample(uri)`, `runs_of_modality(cls)`. `SpectralDataset.write_minimal(runs={...})` accepts a mixed mapping of MS + genomic runs and dispatches by class; Java + ObjC have equivalent mixed-dict overloads. Per-run provenance now writes the canonical `<run>/provenance/steps` compound dataset on the HDF5 fast path in all three languages while keeping the legacy `@provenance_json` mirror as a fallback for non-HDF5 providers and pre-Phase-2 readers; reader prefers compound. M51 cross-language byte-parity harness extended with an `ms_per_run_provenance` section so the Python / Java / ObjC dumpers' per-run output is byte-identical. Phase 1 introduced `all_runs_unified` / `allRunsUnified` as the unified accessor; Phase 2 promoted the canonical name to `runs` / `runs()` and retained `all_runs_unified` / `allRunsUnified` as deprecated aliases.

### M92 — Benchmarking, documentation refresh, v1.2.0 release (2026-04-28)

Compression-benchmark report comparing TTI-O genomic against BAM, CRAM 3.1, and MPEG-G (Genie) on NA12878 WGS (downsampled), ERR194147 WES, and a synthetic mixed-chromosome dataset; harness under `tools/benchmarks/`, fixtures pinned via DVC under `data/genomic/`. Documentation refresh: README, ARCHITECTURE, migration guide, format-spec, codecs spec. Acceptance gates: TTI-O within 15% of CRAM 3.1 on lossless paths; all three language test suites green; 3×3 cross-language conformance matrix green for `.tio` + `.tis` with genomic data; M91 multi-omics integration test green. Tag cut as v1.2.0 (skipping the workplan's earlier v0.11.0 placeholder, which would have collided with the existing pre-stable v0.11.0 tag).

## v1.2.0 (in progress) — codec parity (M93 / M94 / M94.Z / M95) + Cython acceleration + Phase 10 (libttio_rans + ObjC M44 catch-up)

* **M93 — REF_DIFF reference-based sequence-diff codec (2026-04-28).** New codec id `9` for `signal_channels/sequences`. Context-aware per-channel codec receiving `(positions, cigars, reference_resolver)` from sibling channels at write/read time. Slice-based wire format (10 K reads/slice, CRAM-aligned) for random-access decode. Embedded reference at `/study/references/<reference_uri>/` with auto-deduplication across runs sharing a URI. Replaces `BASE_PACK` as the default for `signal_channels/sequences` when a reference is available. Format-version bumps `1.4 → 1.5` only when REF_DIFF is actually used (M82-only writes stay at `1.4` for byte-parity). Cross-language byte-exact across Python / ObjC / Java via 4 canonical `ref_diff_{a,b,c,d}.bin` fixtures. Spec: [`codecs/ref_diff.md`](codecs/ref_diff.md).

* **M94 — FQZCOMP_NX16 v1 lossless quality codec (2026-04-29).** New codec id `10` for `signal_channels/qualities`. fqzcomp-Nx16 (Bonfield 2022 / CRAM 3.1 default) with interleaved 4-way rANS for SIMD parallelism and a context model on `(prev_q[0..2], position_bucket, revcomp_flag, length_bucket)` hashed via SplitMix64 to 4096 contexts. Adaptive `+16` learning rate with halve-with-floor-1 renormalisation at the 4096 max-count boundary. Wire-format header is **54 + L bytes** (field-by-field sum); body has a 16-byte substream-length prefix before round-robin bytes. Auto-default on `qualities` gated on v1.5 candidacy to preserve M82 byte-parity (binding decision §80h). Cross-language byte-exact across Python / ObjC / Java via 7 canonical `fqzcomp_nx16_{a,b,c,d,f,g,h}.bin` fixtures. Spec: [`codecs/fqzcomp_nx16.md`](codecs/fqzcomp_nx16.md).

* **M94.Z — FQZCOMP_NX16_Z CRAM-mimic quality codec (2026-04-29).** New codec id `12`, ships alongside the v1 codec id `10` (which is retained for backward-compatibility fixture readability). Mirrors the CRAM 3.1 fqzcomp encoder's 16-bit renormalisation strategy: per-symbol normalisation is eliminated by maintaining state invariants across adaptive count updates, with rounding handled via a deterministic 16-bit lower-bound renorm guaranteed to produce byte-paired encoder/decoder output by construction (no insertion-sort tie-break, no fixed-`M` boundary). **Replaces the abandoned M94.X variable-total approach as the production v1.2.0 quality codec.** Cross-language perf on a 100K read × 100bp Illumina synthetic: Python 145 MB/s encode / 94 MB/s decode (Cython kernel `_fqzcomp_nx16_z.pyx`); ObjC 51 MB/s encode at CRAM parity; Java 33 MB/s encode. All three exceed the previous M94.X spec targets on encode. Cross-language byte-exact via 7 canonical `m94z_{a,b,c,d,f,g,h}.bin` fixtures. Wired into the M86 pipeline (`Compression.FQZCOMP_NX16_Z = 12` on `signal_channels/qualities`); `tools/benchmarks/formats.py` adapter updated. Spec: [`codecs/fqzcomp_nx16_z.md`](codecs/fqzcomp_nx16_z.md). Design doc: `superpowers/specs/2026-04-29-m94z-cram-mimic-design.md`.

* **Cython acceleration of pre-existing pure-Python codecs (Python only).** Hot paths replaced with thin Cython kernels under `python/src/ttio/codecs/_<codec>/_<codec>.pyx`. `.pyx` source committed; `.c` transpilation output and `.so` extension are gitignored and regenerated by `python setup.py build_ext`. REF_DIFF (M93): **44× pack speedup, 35× unpack speedup**. NAME_TOKENIZED (M86 Phase E): 11% encode / 8% decode chr22 wall-time drop. M94 v1 + M94.Z ship with built-in Cython kernels. Pure-Python `_*_py` fallbacks remain available for environments without C extensions, gated on `_HAVE_C_EXTENSION`. ObjC and Java keep their native fast paths (no Cython analogue).

* **Pipeline defects fixed.** Two cumulative fixes in `python/src/ttio/genomic_run.py` discovered during M94.Z chr22 profiling: (i) `_mate_info_is_subgroup()` was burning ~50% of decode wall on redundant HDF5 link probes (5.3M calls all returning the same answer) — now memoised on `_mate_info_subgroup_cached` per run instance; (ii) per-read codec attribute lookups were eating ~6% of decode wall via `importlib._handle_fromlist` — codec module imports (`Compression`, `Precision`, `_hdf5_io`, `codecs.rans`, `codecs.name_tokenizer`) hoisted to module load.

* **Cumulative chr22 perf.** Encode 18 min → 27.91 s (38.7× faster); decode 24.6 min → 21.76 s (67.8× faster). Position vs CRAM 3.1 (3.03 s / 1.63 s) tightened from 355× / 1162× off down to 9.2× / 13.4× off. Codec compute is now ~4% of TTI-O wall time; remaining gap is HDF5 framework overhead + multi-omics infrastructure (metadata round-trip, provenance compounds, modality dispatch), accepted for v1.2.0 scope per user direction. Files added: 4 Cython extension packages (`_ref_diff/`, `_name_tokenizer/`, `_fqzcomp_nx16/`, `_fqzcomp_nx16_z/`), 11 ObjC test/source files (M93 + M94 + M94.Z), 7 Java test/source files (M93 + M94 + M94.Z).

* **Phase 10 — libttio_rans + ObjC M44 catch-up (2026-04-30 / 2026-05-01).** Three workstreams ship in this phase:
  * **FQZCOMP_NX16 (M94 v1) removal.** The legacy adaptive codec (codec id `10`, ~0.16 MB/s) is deleted entirely (~4500 lines across Python / Java / ObjC). Java preserves the enum ordinal as `_RESERVED_10` (`@Deprecated`); ObjC uses `TTIOCompressionReserved10`. The default v1.5 quality codec is now FQZCOMP_NX16_Z (id `12`); decoder dispatch in all three languages goes `REF_DIFF (9) → NX16_Z (12) → error`.
  * **`libttio_rans` C library at `native/`.** Self-contained CMake build providing AVX2/SSE4.1/scalar SIMD-dispatched rANS kernels (~510 MiB/s encode, ~605 MiB/s decode on AVX2 hosts), a pthread thread pool, and a multi-block V2 wire format. Optional JNI build (`-DTTIO_RANS_BUILD_JNI=ON`) and TSAN build. 4 ctest suites with 29 sub-tests, 0 warnings under `-Wall -Wextra -Wpedantic`. See [`native-rans-library.md`](native-rans-library.md).
  * **M94.Z V2 wire format.** New version byte = 2 indicating the rANS body uses libttio_rans's `[4×states LE][4×lane_sizes LE][per-lane data]` layout. Opt-in via `prefer_native` parameter or `TTIO_M94Z_USE_NATIVE` env var; V1 (version byte = 1) remains the default and is produced by Cython / pure-Java / pure-ObjC encoders. Wired through Python ctypes (`fqzcomp_nx16_z.py:_HAVE_NATIVE_LIB`), Java JNI (`TtioRansNative` + `FqzcompNx16Z.getBackendName()`), and ObjC direct linkage (`__has_include("ttio_rans.h")`). V2 decode is currently pure-language in all three bindings (callback-overhead per symbol exceeds the C decode gain); native decode via `ttio_rans_decode_block_streaming` is wired but off by default.
  * **ObjC M44 catch-up (Tasks 30 + 31, 2026-05-01).** Brings ObjC's writer chain to parity with Python's M44 (v0.7) and Java's M44 (v0.7) migrations. ~2200 lines refactored across `TTIOSignalArray`, `TTIOSpectrum` + 7 subclasses, `TTIOInstrumentConfig`, `TTIOSpectrumIndex`, `TTIOAcquisitionRun`, `TTIOCompoundIO`, and `TTIOSpectralDataset.m -writeToFilePath:` — all now accept `id<TTIOStorageGroup>` instead of `TTIOHDF5Group *`. `TTIOHDF5Group` and `TTIOHDF5Dataset` formally implement `<TTIOStorageGroup>` / `<TTIOStorageDataset>` directly via bridge methods. MS-only datasets now write through `memory://`, `sqlite://`, `zarr://` URLs via both `+writeMinimalToPath:` (Task 30) and `-writeToFilePath:` (Task 31). NMR runs and Image-subclass datasets remain HDF5-only by design (H5DSset_scale dimension scales / native 3D cubes have no protocol equivalents — same scope as Python and Java). Includes `TTIOZarrProvider.createDatasetNamed:` fix to silently ignore unsupported `TTIOCompression` instead of erroring (was a protocol-contract violation).
  * **chr22 ratio holds at 1.965× CRAM 3.1** under both V1 and V2 (codec is not the bottleneck — gap is HDF5 multi-omics framing). Test counts: Python 540/540, Java 845/845, ObjC 3256/2 (the 2 are pre-existing TestMilestone29 Thermo mock-binary tests, unrelated).

## Format compatibility

Every version's files remain readable by later versions. v0.11 readers open
v0.1–v0.10 files without ceremony. v0.11 adds two new HDF5 groups
(`raman_image_cube/`, `ir_image_cube/`) under `/study/`; pre-v0.11 readers
silently ignore them (they don't match any known layout). `RamanSpectrum`,
`IRSpectrum`, `UVVisSpectrum`, and `TwoDimensionalCorrelationSpectrum` persist
through the generic `TTIOSpectrum` path with `@mpgo_class` attributes, so
pre-v0.11 readers fall back to the `Spectrum` base class rather than failing.
v0.10 transport and per-AU encryption behaviour is unchanged. v0.12 M74
activation detail is additive — legacy files without M74 columns remain
format `1.1`. Classical AES-256-GCM wrapping and HMAC-SHA256 signatures verify
indefinitely.

The v1.2.0 M79–M92 line is a clean break from v1.0 / v1.1.x readers
per Binding Decision §74 (M80 rebrand drops `mpgo`/`MPGO` for `ttio`/`TTIO`).
Within that line, downstream additions remain backward-compatible with their
upstream peers: M86 codec attributes are absent on M82-shape files (readers
still see uncompressed natural-dtype channels); M89 genomic AUs (`spectrum_class
== 5`) are tagged with the `opt_genomic` feature flag and pre-M89 transport
readers reject the stream cleanly via the flag check; M90.12 MPAD output
still parses on a v0.10 / pre-M90.12 reader as a length-mismatch error
(magic check fails first), avoiding silent float-cast corruption; Phase 2
per-run provenance writes BOTH the canonical `<run>/provenance/steps`
compound dataset and the legacy `@provenance_json` attribute, so Phase 1
readers (which only know the JSON attribute) round-trip Phase 2 files
without loss.
