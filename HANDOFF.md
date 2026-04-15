# MPEG-O v0.4 — Continuation Session Prompt

> **Status:** v0.3.0 is **complete**. Dual-language implementation (Objective-C + Python) with cross-implementation conformance, cloud access, LZ4/Numpress codecs, canonical signatures, mzML import/export. This session executes **Milestones 23-30** to produce **v0.4.0** — adding thread safety, the Java stream, key rotation, chromatogram API, ISA-Tab/JSON export, spectral anonymization, and nmrML export.

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `README.md`, `ARCHITECTURE.md`, `WORKPLAN.md`, `docs/format-spec.md`, `docs/feature-flags.md`
3. Verify: `cd objc && ./build.sh check` (ObjC tests) and `cd ../python && pip install -e ".[test,import,crypto]" && pytest` (Python tests)
4. Tag v0.3.0 if not already tagged.

## Binding Decisions

### From v0.1-v0.3 (still active)

1. Milestone-by-milestone checkpoints with user review. 2. Clang-only for ObjC (ARC). 3. Immutable value classes. 4. CRLF/LF via .gitattributes. 5. Shell scripts need executable bit. 6. HDF5 via C API with ObjC wrappers. 7. `.mpgo` extension. 8. `NSError **` out-params. 9. Test isolation. 10. One commit per milestone. 11. CI green before complete. 12. ARC on libMPGO, MRC on tests. 13. Apache-2.0 on import/export. 14. PyPI name `mpeg-o`, Python 3.11+. 15. Cloud via fsspec. 16. Numpress clean-room.

### From v0.4 planning (new)

17. **Java: Maven** build system (standard in bioinformatics). Package `com.dtwthalion.mpgo`. 18. **HDF5-Java: `hdf-java`** (HDF Group JNI). Full read/write. 19. **Anonymization: broad scope** — proteomics + metabolomics + NMR. 20. **ISA output: both ISA-Tab and ISA-JSON.** 21. **PyPI: remain on TestPyPI** until v1.0. 22. **Vendor import: Thermo `.raw` first** (most used). Bruker TDF deferred.

## Dependency Graph

```
  M23 (Thread safety)  M24 (Chromatogram)  M26 (Java)
       |                    |                   |
       v                    v                   |
  M25 (Key rotation)   M27 (ISA export)        |
       |                    |                   |
       v                    v                   |
  M28 (Anonymization)  M29 (nmrML+stubs)       |
       |                    |                   |
       +--------+-----------+-------------------+
                v
          M30 (v0.4.0)
```

M23, M24, M26 start in parallel.

---

## Milestone 23 — Thread Safety (ObjC + Python)

**License:** LGPL-3.0

**ObjC:** Verify `H5is_library_threadsafe()` in CI. If false, build HDF5 from source with `--enable-threadsafe`. Add `NSRecursiveLock` on `MPGOHDF5File` for all H5D/H5G operations. Add `-isThreadSafe` method. **Python:** `SpectralDataset` wraps `h5py.File` with `threading.RLock`. Opt-in via `thread_safe=True` param. **Docs:** Update ARCHITECTURE.md threading model. **Benchmark:** Single vs 4-thread read of 100 spectra from 10k-spectrum file. Overhead < 15%, speedup 2-4x.

**Acceptance:** `H5is_library_threadsafe()` true in CI. Two threads read concurrently without crashes. Write blocks readers. Single-thread overhead < 15%. Model documented.

---

## Milestone 24 — Chromatogram API + mzML Writer Completion

**License:** LGPL-3.0 (core), Apache-2.0 (export)

Resolves v0.3 M19 deferred item. **ObjC:** `MPGOAcquisitionRun` gains `chromatograms` property (`NSArray<MPGOChromatogram *>`). HDF5: `/study/ms_runs/run_NNNN/chromatograms/` with time_values + intensity_values + chromatogram_index. **Python:** matching `AcquisitionRun.chromatograms`. **mzML writer:** both ObjC and Python emit `<chromatogramList>` + `<index name="chromatogram">` with byte-correct offsets and cvParam type (TIC MS:1000235, XIC MS:1000627, SRM MS:1000789). **mzML reader:** chromatograms stored on run object.

**Acceptance:** 100 spectra + 3 chromatograms round-trip. mzML chromatogram round-trip. v0.3 files readable (empty list). Cross-language parity. indexedmzML offsets correct.

---

## Milestone 25 — Key Rotation (`opt_key_rotation`)

**License:** LGPL-3.0

Envelope encryption: DEK wraps data, KEK wraps DEK. Rotation re-wraps DEK without re-encrypting data (O(1)). **HDF5:** `/protection/key_info` gains `dek_wrapped` dataset (60 bytes: 32 DEK + 12 IV + 16 tag), `@kek_id`, `@kek_algorithm` ("aes-256-gcm"), `@wrapped_at`, `key_history` compound dataset. **ObjC:** `MPGOKeyRotationManager` with `enableEnvelopeEncryption:`, `rotateKey:`, `unwrapDEK:`. **Python:** `mpeg_o.key_rotation` with matching functions. **Migration:** v0.3 direct-key files: decrypt with old key, generate DEK, re-encrypt, wrap DEK with KEK.

**Acceptance:** Encrypt with KEK-1, read OK. Rotate to KEK-2, read OK, KEK-1 fails. Key history tracks both. Rotation < 100ms. Cross-language parity. v0.3 backward compat.

---

## Milestone 26 — Java Implementation

**License:** LGPL-3.0 (core), Apache-2.0 (importers/exporters)

Maven project under `java/`. Package `com.dtwthalion.mpgo`. JDK 17+. Uses `hdf-java` (HDF Group JNI) for HDF5, `javax.crypto` for AES-256-GCM and HMAC-SHA256, `javax.xml.parsers.SAXParser` for mzML/nmrML import, `java.util.Base64` for decoding. Java records for value types. AutoCloseable for file handles. Lazy-loading AcquisitionRun.

**Structure:** `src/main/java/com/dtwthalion/mpgo/` with SignalArray, Spectrum hierarchy, AcquisitionRun, SpectralDataset, Identification, Quantification, ProvenanceRecord, FeatureFlags, Enums. Sub-packages: `hdf5/` (Hdf5File, Hdf5Group, Hdf5Dataset, Hdf5CompoundType, Hdf5IO), `protection/` (EncryptionManager, SignatureManager, KeyRotationManager, AccessPolicy), `importers/` (MzMLReader, NmrMLReader, CVTermMapper, Base64Decoder), `exporters/` (MzMLWriter). Tests under `src/test/` with CrossCompatTest reading ObjC/Python fixtures.

**pom.xml:** hdf-java dependency, JUnit 5, maven.compiler.source/target=17. Surefire plugin with `-Djava.library.path` for native HDF5.

**Acceptance:** `mvn package` produces jar. All fixtures readable. Round-trip verified. Java fixtures readable by ObjC and Python. Encryption, signature, key rotation cross-language parity. mzML import works. Chromatogram API works. CI: `mvn verify` green on JDK 17.

---

## Milestone 27 — ISA-Tab/JSON Export (All Three Languages)

**License:** Apache-2.0

**ObjC:** `MPGOISAExporter` in `Export/`. **Python:** `mpeg_o.exporters.isa`. **Java:** `ISAExporter.java` in `exporters/`.

Mapping: Dataset title -> Investigation title. `isaInvestigationId` -> Investigation ID. Each AcquisitionRun -> Study + Assay. InstrumentConfig -> Assay technology/platform. ProvenanceRecord chain -> Protocol REF. Identification -> result file refs. CVParam -> parameter values. Chromatograms -> derived data refs.

**ISA-Tab output:** `i_investigation.txt`, `s_study.txt`, `a_assay_ms.txt`/`a_assay_nmr.txt` (UTF-8 TSV). **ISA-JSON:** single JSON file per ISA-JSON schema.

**Acceptance:** Valid ISA-Tab and ISA-JSON from multi-run dataset. Validates with `isatools` (if available, skip otherwise). Metadata round-trip. Three languages produce structurally identical output.

---

## Milestone 28 — Spectral Anonymization (ObjC + Python)

**License:** LGPL-3.0

**ObjC:** `MPGOAnonymizer` in `Protection/`. **Python:** `mpeg_o.anonymization`.

**Policies — proteomics:** `redact_saav_spectra` — remove spectra with SAAV identifications. `mask_intensity_below_quantile` — zero below threshold. **Metabolomics:** `mask_rare_metabolites` — suppress signals linked to rare metabolites (below prevalence threshold from bundled/user JSON table mapping CHEBI IDs to population frequencies). **NMR:** `coarsen_chemical_shift_decimals` — reduce ppm precision. **Universal:** `coarsen_mz_decimals`, `strip_metadata_fields` (operator name, serial, source files, timestamps).

**Audit:** Signed ProvenanceRecord documenting policy, counts, timestamp. `opt_anonymized` feature flag. **Output:** new file, never in-place. Encrypted inputs require decryption key from caller.

**Bundled data:** `data/metabolite_prevalence.json` with common human metabolites. Documented as non-authoritative default.

**Acceptance:** SAAV redaction removes correct spectra. Intensity masking works. m/z and chemical shift coarsening works. Rare metabolite masking works. Metadata stripping works. Provenance signed and verifiable. Readable by all three implementations. Original unmodified.

---

## Milestone 29 — nmrML Writer + Thermo RAW Stub

**License:** Apache-2.0

**nmrML writer** in all three languages. Serializes NMRSpectrum and FID to nmrML XML: `<acquisition1D>`, `<fidData>` (base64 complex128), `<spectrum1D>`, nmrCV cvParams for nucleus, frequency, sweep width, dwell time.

**Thermo RAW stub** in all three languages. Defines public API, returns not-implemented error with SDK guidance. **ObjC:** `MPGOThermoRawReader` returns nil + NSError. **Python:** `mpeg_o.importers.thermo_raw.read()` raises NotImplementedError. **Java:** throws UnsupportedOperationException. API contract stable for future implementation.

**`docs/vendor-formats.md`:** new file covering Thermo .raw, Bruker TDF (stub), Waters MassLynx (stub) format overviews and integration patterns.

**Acceptance:** nmrML round-trip verified across three languages. Stubs compile/import without error. `docs/vendor-formats.md` committed.

---

## Milestone 30 — v0.4.0 Release

**Docs:** Update format-spec.md, feature-flags.md, README.md, ARCHITECTURE.md, WORKPLAN.md. New docs/vendor-formats.md. **CI:** Add java-test job (JDK 17, mvn verify) and cross-compat-3way job (ObjC<->Python<->Java fixture exchange). **Packages:** mpeg-o updated on TestPyPI. Java artifact to GitHub Packages. **Release:** `git tag -a v0.4.0 -m "MPEG-O v0.4.0: Java stream, thread safety, key rotation, chromatogram API, ISA-Tab/JSON export, spectral anonymization, nmrML writer"`

**Acceptance:** All three languages green. All fixtures cross-readable. v0.1/v0.2/v0.3 backward compat. TestPyPI updated. GitHub Packages artifact. CI all green. Tag pushed.

---

## Known Gotchas

**Inherited:** 1. HDF5 paths differ by install. 2. Testing.h vs ARC split. 3. Custom check:: target. 4. Runtime ABI detect. 5. -fblocks gnustep-2.0 only. 6. LF enforcement. 7. NSXMLParser needs libxml2. 8. h5py compound types must match format-spec. 9. Fixed test IVs for cross-language crypto. 10. Numpress relative error. 11. LZ4 filter runtime check.

**New (v0.4):** 12. HDF5 thread-safe: check `H5is_library_threadsafe()` at runtime; may need source build. 13. hdf-java JNI: set `-Djava.library.path` to HDF5 native lib dir in surefire. 14. hdf-java API: static methods on `hdf.hdf5lib.H5`; wrap into OO. 15. javax.crypto HMAC: validate 32-byte key length. 16. Key rotation backward compat: detect envelope vs direct encryption by presence of `dek_wrapped`. 17. ISA-Tab: UTF-8 TSV; validate with isatools if available. 18. Anonymization prevalence table: bundled default is non-authoritative; document clearly. 19. Anonymization of encrypted files: requires decryption key from caller.

---

## Execution Checklist

1. Tag v0.3.0 if needed.
2. **M23:** Thread safety. **Pause.**
3. **M24:** Chromatogram API. **Pause.**
4. **M25:** Key rotation. **Pause.**
5. **M26:** Java stream. **Pause.**
6. **M27:** ISA-Tab/JSON export. **Pause.**
7. **M28:** Spectral anonymization. **Pause.**
8. **M29:** nmrML writer + Thermo stub. **Pause.**
9. **M30:** Docs, CI, packages, tag v0.4.0.

**CI must be green before any milestone is complete.**

## Deferred to v0.5+

Streaming transport (MPEG-G Part 2). Zarr backend. DuckDB query layer. Bruker TDF import. Waters MassLynx import. Raman/IR spectrum support. PyPI stable release. Maven Central. MPEG-G conformance suite. v1.0 API freeze.
