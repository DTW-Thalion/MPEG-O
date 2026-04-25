# M41 — API Review Checkpoint: Design

**Date:** 2026-04-16
**Milestone:** M41 (TTI-O v0.6)
**Status:** Design, pending user approval
**Scope decision:** Option C — full consistency pass; ObjC is ground truth

## 1. Scope & Non-Goals

### In scope

- Bring the Python and Java implementations to semantic parity with
  Objective-C (the normative implementation) for every **public** class,
  protocol/interface, method, and field.
- Add language-idiomatic doc comments to every public API:
  - **Objective-C:** GSdoc / AutoGSDoc (touch-ups only; mostly already
    present)
  - **Python:** NumPy-style docstrings (`numpydoc` compatible)
  - **Java:** Javadoc with `{@link}`, `<p>`, `@since 0.6`
- Embed cross-language cross-references in each class's primary doc
  block.
- Deliver two documents:
  - `docs/api-review-v0.6.md` — three-column parity map with finalized
    "now-consistent" state, per-subsystem inconsistency resolutions,
    stability markers.
  - `docs/migration-guide.md` — Python-focused quickstart for
    mzML → TTI-O and nmrML → TTI-O.

### Out of scope

- Non-public internals (`_hdf5_io.py`, `MiniJson.java`, `TTIOHDF5File`
  and other low-level HDF5 helpers, `_rwlock.py`, etc.).
- The `com.dtwthalion` → `global.thalion` groupId migration (belongs to
  M40). Cross-references in docstrings use **short class names**
  (`SignalArray`, `Spectrum`) so they stay valid under the groupId
  change.
- Format-spec changes, new features, new importers/exporters.
- Performance work, build-system refactoring.

## 2. Ground-Truth Principle & Parity Rules

**Objective-C is normative.** Every public-API question is resolved by
reading the ObjC headers.

"Parity" means **semantic equivalence**, not literal symbol
equivalence:

1. **Names adapt to language convention.** ObjC `-precursorMz` → Python
   `precursor_mz` → Java `precursorMz()`. Not a divergence.
2. **Types adapt to language idiom.**
   - `NSData` ↔ Python `bytes` / `np.ndarray` ↔ Java `byte[]` /
     typed primitive array (`double[]`, `float[]`).
   - `NSArray<T *>` ↔ Python `list[T]` / `tuple[T, ...]` ↔ Java
     `List<T>`.
   - `NSDictionary<K, V>` ↔ Python `dict[K, V]` / `Mapping[K, V]` ↔
     Java `Map<K, V>`.
   - `NSError **` ↔ Python exceptions ↔ Java exceptions /
     `AutoCloseable`.
3. **Class shape must match.** If ObjC `TTIOSpectrum` base has
   `precursorMz`, both Python `Spectrum` base and Java `Spectrum` base
   must have it too. Subclass-specific fields stay on subclasses in
   all three languages.
4. **Method sets must match.** Every ObjC public method needs a Python
   and Java equivalent, resolved by semantics — not by spelling.
5. **Protocols/interfaces align.** ObjC `<TTIOIndexable>` → Python
   `Protocol` / `ABC` → Java `interface`. Same capability surface, same
   method set.

Existing convenience methods that are pure language idiom — Python
`__len__` / `__iter__` / `__repr__`, Java `toString()` /
`hashCode()` / `equals()` — are not "extras" and are retained.

## 3. Inconsistency Taxonomy

During each subsystem's audit, findings are classified as:

| Class              | Meaning                                                                                   | Action                                                              |
| ------------------ | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| **Missing-member** | Python or Java lacks a field/method ObjC has                                              | Add it; ObjC shape is authoritative                                 |
| **Shape-drift**    | Field/method exists but on a different class than in ObjC                                 | Move to match ObjC's class hierarchy                                |
| **Signature-drift**| Exists but differs in semantic return type or parameter list                              | Rewrite to match ObjC's semantics                                   |
| **Naming-drift**   | Semantically equivalent but name doesn't follow language convention                       | Rename to the idiomatic form                                        |
| **Extra-member**   | Python or Java has something ObjC doesn't                                                 | Evaluate case-by-case; usually remove unless a pure language idiom  |

Every resolved finding appears in `api-review-v0.6.md` with a before /
after summary.

### Known divergences already spotted

These are real, and will be among the first things fixed:

- `Spectrum` base fields disagree across languages:
  - ObjC: `indexPosition`, `scanTimeSeconds`, `precursorMz`,
    `precursorCharge`.
  - Python: `retention_time`, `ms_level`, `polarity`, `precursor_mz`,
    `precursor_charge`, `base_peak_intensity`, `index`, `run_name`.
  - Java: `indexPosition`, `scanTimeSeconds` **only** — precursor
    fields are on the `MassSpectrum` subclass instead.
- `Spectrum.signalArrays` (ObjC, Java) vs `Spectrum.channels` (Python)
  — naming drift.
- `MassSpectrum.mz_array` returns `SignalArray` in Python;
  `MassSpectrum.mzValues()` returns `double[]` in Java. Signature
  drift; ObjC shape is authoritative.

These are illustrative, not exhaustive. The full list is produced
during the per-subsystem audits.

## 4. Execution Order — Subsystem-by-Subsystem (Approach 2)

Each sub-milestone follows the same loop:

1. Audit the ObjC subsystem's public API.
2. Fix Python divergences.
3. Fix Java divergences.
4. Add / upgrade docstrings in all three languages.
5. Run the full test suite in each language + three-way cross-compat.
6. Commit with a "M41.N — <subsystem> parity" message.
7. **Pause for user review before the next slice.**

Slices are ordered so leaves come first (no dependents to break):

| Slice | Subsystem                    | Classes in scope                                                                                           |
| ----- | ---------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 41.1  | Domain protocols + ValueClasses | `CVAnnotatable`, `Encryptable`, `Indexable`, `Provenanceable`, `Streamable`; `AxisDescriptor`, `CVParam`, `EncodingSpec`, `ValueRange`, `Enums` |
| 41.2  | Core + Spectra               | `SignalArray`, `Numpress`; `Spectrum` + `MassSpectrum`, `NMRSpectrum`, `NMR2DSpectrum`, `FID`, `Chromatogram` |
| 41.3  | Run + Image                  | `AcquisitionRun`, `InstrumentConfig`, `SpectrumIndex`, `MSImage`                                           |
| 41.4  | Dataset                      | `SpectralDataset`, `Identification`, `Quantification`, `ProvenanceRecord`, `TransitionList`, `CompoundIO`  |
| 41.5  | Protection                   | `AccessPolicy`, `Anonymizer`, `EncryptionManager`, `KeyRotationManager`, `SignatureManager`, `Verifier`     |
| 41.6  | Query                        | `Query`, `StreamReader`, `StreamWriter`                                                                    |
| 41.7  | Storage providers            | `StorageProvider` / `StorageGroup` / `StorageDataset` protocols; `HDF5Provider`, `MemoryProvider`, `ProviderRegistry`, `CompoundField` |
| 41.8  | Import / Export              | mzML reader + writer, nmrML reader + writer, Thermo reader, ISA exporter, `Base64`, `CVTermMapper`         |
| 41.9  | Docs assembly                | Finalize `api-review-v0.6.md` and `migration-guide.md`; stability markers; final three-way cross-compat run |

Ordering rationale: domain protocols are true leaves (used by later
classes); value classes have no dependents. Storage provider protocols
stay paired with their concrete implementations in 41.7 since nothing
else depends on them until the providers themselves.

Slices 41.1–41.8 each leave all three trees green; 41.9 is pure docs.
One commit per slice (nine commits total for M41). This matches the
existing milestone-checkpoint discipline even though binding decisions
say "one commit per milestone" — sub-milestones inherit sub-commits.

## 5. Docstring Standards (Language-Idiomatic)

### Objective-C (GSdoc / AutoGSDoc)

Keep the existing style. Per-class prose block at `@interface`; per
property/method `/** ... */` blocks describing parameters, return
values, and error conditions.

```objc
/**
 * Base class for any spectrum. Holds an ordered dictionary of named
 * TTIOSignalArrays plus the coordinate axes that index them, the
 * spectrum's position in its parent run, scan time, and optional
 * precursor info for tandem MS.
 *
 * Concrete subclasses (TTIOMassSpectrum, TTIONMRSpectrum, ...) add
 * their own typed metadata and validation.
 *
 * HDF5 representation: each spectrum is an HDF5 group whose immediate
 * children are TTIOSignalArray sub-groups (one per named array) plus
 * scalar attributes for the metadata fields.
 *
 * Cross-language equivalents:
 *   Python: ttio.spectrum.Spectrum
 *   Java:   com.dtwthalion.tio.Spectrum
 */
@interface TTIOSpectrum : NSObject
```

### Python (NumPy-style)

```python
class Spectrum:
    """Generic multi-channel 1-D spectrum with per-scan metadata.

    A ``Spectrum`` owns an ordered mapping of named ``SignalArray``
    objects and the coordinate axes that index them, plus per-scan
    metadata (index position, scan time, optional precursor info for
    tandem MS).

    Parameters
    ----------
    signal_arrays : dict[str, SignalArray]
        Named signal arrays keyed by channel name
        (``"mz"``, ``"intensity"``, ``"chemical_shift"``, ...).
    axes : list[AxisDescriptor]
        Coordinate axes describing the signal arrays.
    index_position : int, default 0
        Position in the parent ``AcquisitionRun`` (0-based).
    scan_time_seconds : float, default 0.0
        Scan time in seconds from run start.
    precursor_mz : float, default 0.0
        Precursor m/z for tandem MS. 0 if not tandem.
    precursor_charge : int, default 0
        Precursor charge state. 0 if unknown.

    Notes
    -----
    HDF5 representation: each spectrum is an HDF5 group whose immediate
    children are ``SignalArray`` sub-groups plus scalar attributes.

    See Also
    --------
    MassSpectrum : MS-specific subclass.
    NMRSpectrum : 1-D NMR subclass.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOSpectrum`` · Java: ``Spectrum``
    """
```

### Java (Javadoc)

```java
/**
 * Base class for any spectrum. Holds an ordered map of named
 * {@link SignalArray}s plus the coordinate axes that index them,
 * the spectrum's position in its parent run, scan time, and
 * optional precursor info for tandem MS.
 *
 * <p>Concrete subclasses ({@link MassSpectrum}, {@link NMRSpectrum},
 * ...) add their own typed metadata and validation.</p>
 *
 * <p><b>HDF5 representation:</b> each spectrum is an HDF5 group
 * whose immediate children are {@code SignalArray} sub-groups
 * (one per named array) plus scalar attributes for the metadata
 * fields.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOSpectrum}, Python {@code ttio.spectrum.Spectrum}.</p>
 *
 * @since 0.6
 */
public class Spectrum {
    ...
}
```

## 6. Cross-Language Cross-References

Each **public class**'s primary doc block carries a "Cross-language
equivalents" line. Short class names only (no Java FQN, no full
Python dotted path in the headline form) so the xref is invariant
under the M40 groupId change.

Method-level xrefs are **omitted** unless a method name diverges in
a surprising way. The class-level xref is sufficient: a reader can
go look at the named counterpart.

## 7. Stability Markers

HANDOFF decrees:

- **Core data model** (SignalArray, Spectrum and subclasses,
  AcquisitionRun, SpectralDataset, MSImage, value classes) =
  **Stable**.
- **Provider interfaces** (StorageProvider / StorageGroup /
  StorageDataset, HDF5Provider, MemoryProvider, ProviderRegistry) =
  **Provisional** — may change before v1.0.

Stamped in two places:

1. **In source docs:**
   - ObjC: prose sentence in the class-level `/** ... */` block
     ("API status: Stable." or "API status: Provisional — may change
     before v1.0.").
   - Python: NumPy docstring section:
     ```rst
     .. note::
        API status: Stable.
     ```
   - Java: Javadoc paragraph:
     ```java
     * <p><b>API status:</b> Provisional — may change before v1.0.</p>
     ```
     No extra annotation dependency (avoids JetBrains
     `@ApiStatus.Experimental` or similar).

2. **In `api-review-v0.6.md`:** every class row has an explicit
   Stability column.

## 8. Deliverable — `docs/api-review-v0.6.md`

```
# TTI-O v0.6 API Review

## 1. Scope and stability policy
   - Three-language coverage: ObjC (normative), Python, Java
   - Stable vs Provisional definitions and policy

## 2. Namespace summary
   - ObjC:   TTIO* (Foundation-based, prefix convention)
   - Python: ttio.* (single top-level package)
   - Java:   com.dtwthalion.tio.* (groupId migrates to global.thalion in M40)

## 3. Per-subsystem parity
   One section per slice 41.1 .. 41.8. Each section has:
     - Three-column class table: ObjC | Python | Java | Stability
     - Method-level parity callouts for classes with non-trivial surface
     - "Fixes applied in this review" block listing resolved inconsistencies
       (before / after)

## 4. Known stylistic differences (not divergences)
   - Naming convention (camelCase vs snake_case vs labeled-args)
   - Error conveyance (NSError ** vs exceptions vs exceptions)
   - Resource management (manual release vs context manager vs
     try-with-resources)
   - Idiomatic conveniences that are expected in each language

## 5. Appendix — Audit methodology
   - How the audit was conducted
   - How to reproduce for future versions
```

## 9. Deliverable — `docs/migration-guide.md`

```
# Migrating to TTI-O

## 1. Audience and prerequisites
   - "You have mzML or nmrML files and want to move to TTI-O."
   - Python 3.11+, pip, optional ThermoRawFileParser for .raw input.

## 2. Install
   - pip install -e ".[test,import]"  (from source during v0.6;
     swap to "pip install mpeg-o" once M40 ships)

## 3. mzML → TTI-O
   3.1 Python quickstart (runnable snippet)
   3.2 CLI (TtioImport or equivalent)
   3.3 Semantic mapping table:
       mzML run            -> AcquisitionRun
       mzML spectrum       -> Spectrum (MassSpectrum subclass)
       mzML cvParam        -> CVParam
       mzML instrumentConf -> InstrumentConfig
       mzML dataProcessing -> ProvenanceRecord
       mzML scan window    -> ValueRange on MassSpectrum.scanWindow
   3.4 Round-trip verification with TtioVerify CLI

## 4. nmrML → TTI-O
   4.1 Python quickstart
   4.2 Semantic mapping table (NMR-specific)
   4.3 Round-trip verification

## 5. Where the fixtures live
   - Pointer to data/ directory for reference mzML and nmrML inputs
   - Known good .tio outputs used in cross-compat tests
```

## 10. Verification

### Per-slice acceptance

- ObjC: `cd ~/TTI-O/objc && ./build.sh check` passes.
- Python: `cd ~/TTI-O/python && pytest` passes.
- Java: `cd ~/TTI-O/java && mvn verify -B` passes.
- Three-way cross-compat fixture round-trip passes.

### M41 completion (matches HANDOFF acceptance list)

- [ ] `docs/api-review-v0.6.md` committed.
- [ ] `docs/migration-guide.md` committed.
- [ ] No undocumented public APIs (enforced by audit in 41.9).
- [ ] Provider interfaces clearly marked Provisional.
- [ ] Test counts in each language are ≥ pre-M41 (new methods added
      for parity come with at least smoke tests).

### Tests for added methods

Any Python or Java public method added during M41 to achieve parity
ships with at least a smoke test. No API added without a test. This
keeps ObjC 867 / Python 142 / Java 84 honest and ensures regressions
surface immediately.

## 11. Commit Discipline

- One commit per slice (41.1 through 41.9) → nine commits on `main`.
- Commit message format: `M41.N: <subsystem> parity`.
- Multi-line messages via `-F ~/msg.txt` per existing discipline.
- `Co-Authored-By` trailer per existing discipline.
- `git fetch "//wsl.localhost/Ubuntu/home/toddw/TTI-O" main` →
  `git clean -fd java/` → `git merge --ff-only FETCH_HEAD` →
  `git push origin main` from the Windows checkout per existing
  workflow.
- Release tag for v0.6.0 stays user-gated and is not touched by M41.

## 12. Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Parity fixes break existing ObjC tests via cross-compat | ObjC unchanged except doc touch-ups; Python/Java must read/write fixtures identically |
| Naming changes in Python break downstream Python code | Pre-release; no external callers; user has authorized |
| NumPy-style docstring conversion is tedious | Scope limited to **public** APIs; internals keep existing docstrings |
| Java groupId xref rot after M40 | Use short names in cross-refs; one-line fix in `api-review-v0.6.md` namespace table when M40 lands |
| Spectrum field reshape is a breaking internal change | Tests will catch it; cross-compat fixtures re-generate from ObjC |
| Scope creep across subsystems | Strict per-slice pause discipline; user reviews before next slice |

## 13. Post-M41 Follow-Ups

Deferred (not in M41):

- M40 — PyPI + Maven Central publishing (when accounts are ready).
- M42 — v0.6.0 release tag.
- Any new features, new importers/exporters.

## 14. Open Decisions Resolved Inline

1. **Cross-ref format in docstrings:** short class names, not FQNs.
   Invariant under M40 groupId change.
2. **Commit granularity:** one per slice, nine total.
3. **Python docstring style:** NumPy (`numpydoc`-compatible).
4. **Java stability annotation:** prose in Javadoc, not
   `@ApiStatus.Experimental`. No new dependency.
5. **Migration guide language:** Python only. Java/ObjC readers can
   translate idiomatically.
6. **Tests for added methods:** mandatory, smoke-level is enough.
