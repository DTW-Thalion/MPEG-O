# Subjects + Samples Design (Deferral 2 → Stage 6)

**Status:** Design locked 2026-05-26. Implementation plan: `docs/superpowers/plans/2026-05-26-subjects-samples-impl.md`.

## 1. Problem

`SpectralDataset` cannot store metadata about *who* the data came from or *what* it was collected from. Today, the run → sample link is a free `AcquisitionRun.sampleName` string with no Subject side. The server-side cohort query feature (`SubjectFieldPredicate`) was bolted on top with its own allowlists, but no underlying entity exists.

`transport-spec.md §4.22` (added in Task 0.8) names `SUBJECT_METADATA (0x19)` and `SAMPLE_METADATA (0x1A)` packets but references a `format-spec §11` that does not exist. The transport plan deferred implementing 0x19/0x1A in Tasks 1.9/2.8/3.8 specifically because the model wasn't there.

This spec resolves that gap.

## 2. Goals

- Add `Subject` and `Sample` as first-class TTI-O entities.
- Persist them in the `.tio` HDF5 container alongside the existing accessors.
- Wire them through the transport so the 2 missing packet types round-trip cross-language.
- Don't break existing `.tio` files or `AcquisitionRun.sampleName`.

## 3. Non-goals

- No "investigation" entity above the dataset level (per-dataset subjects/samples for v1.4).
- No clinical/phenotype hierarchy (e.g. ICD codes, ontology refs). Open `attributes` slot absorbs this.
- No automatic Subject/Sample creation from existing `AcquisitionRun.sampleName` strings. Datasets without explicit Subject/Sample remain valid; the run→sample link stays free-string.
- No cohort-server schema changes. The existing `SubjectFieldPredicate` allowlists keep working unchanged; they query the new on-disk fields when present, ignore the dataset when absent.

## 4. Data model

### 4.1 `Subject`

Tight core + open attributes (decision 1 = "Tight core + open Attributes"):

| Field | Type | Required | Notes |
|---|---|---|---|
| `external_id` | str | **yes** | Unique within dataset. Primary key. |
| `project` | str | no | Free string, often a study acronym. |
| `sex` | str | no | Free string (e.g. `"M"`/`"F"`/`"NA"`). |
| `birth_year` | int? | no | YYYY, 4-digit. `null` / `0` sentinel = unknown. |
| `attributes` | Map<str, str> | no | Open extension slot. Keys are free; values stringified. |

`external_id` SHALL be a stable, deterministic string under the depositor's control (a study identifier, a UUID, etc.). It is referenced from `Sample.subject_external_id`.

### 4.2 `Sample`

| Field | Type | Required | Notes |
|---|---|---|---|
| `sample_id` | str | **yes** | Unique within dataset. Primary key. Matches `AcquisitionRun.sampleName` for the run→sample link (decision 2). |
| `subject_external_id` | str | no | Soft FK to `Subject.external_id`. Validation policy at §4.4. |
| `sample_kind` | str | no | Free string. The cohort predicate's allowlist is informational. |
| `collected_at` | int? | no | Unix seconds since epoch. `null` / `0` sentinel = unknown. |
| `attributes` | Map<str, str> | no | Open extension slot. |

### 4.3 Cardinality

- Zero or more Subjects per dataset.
- Zero or more Samples per dataset.
- A Sample MAY reference a Subject in the same dataset by `subject_external_id`. Cross-dataset references are out of scope for v1.4 (no global identity layer yet).

### 4.4 Validation

- `external_id` and `sample_id` SHALL be non-empty strings on write. Readers MAY tolerate empty values (skip the row with a warning) for forward compat.
- `Sample.subject_external_id`:
  - If present and matches a Subject in this dataset → consistent.
  - If present but no matching Subject → soft warning (logged), NOT an error. Allows datasets to ship Samples without full Subject metadata.
  - If absent → fine. Anonymous samples are valid.
- Duplicate `external_id` or `sample_id` on write SHALL raise.

## 5. HDF5 layout (format-spec §11)

Per-row group layout (decision 3):

```
/study/subjects/
    <external_id>/                  HDF5 group, one per Subject
        # Attributes (all optional except external_id):
        external_id:        utf8 (str)
        project:            utf8 (str)
        sex:                utf8 (str)
        birth_year:         int64 (sentinel 0 = unknown)
        attributes_json:    utf8 — JSON object, sort_keys=true, separators=(",", ":")

/study/samples/
    <sample_id>/                    HDF5 group, one per Sample
        # Attributes (all optional except sample_id):
        sample_id:           utf8 (str)
        subject_external_id: utf8 (str)
        sample_kind:         utf8 (str)
        collected_at:        int64 (sentinel 0 = unknown)
        attributes_json:     utf8
```

**HDF5 group names** are `external_id` / `sample_id` verbatim, with the same safety rules as existing TTI-O group names (no `/`, see Task 0.9 finding). Depositors MUST choose values that are valid HDF5 group names; a writer-side validation error is acceptable.

**Why per-row groups, not compound dataset:** Compound datasets in HDF5 are awkward to extend (adding a column rewrites the table) and don't accept variable-length strings cleanly. Per-row groups are inspect-friendly with `h5dump` and let `attributes_json` carry the open-extension slot without table-schema gymnastics. The cost is metadata overhead for large cohorts (~hundreds of bytes per row), which is acceptable for v1.4.

**Empty case:** If a dataset has no Subjects, `/study/subjects/` is absent (NOT an empty group). Same for Samples. Readers MUST treat absent-group as zero rows.

## 6. Transport (transport-spec §4.22)

Two packet types, Arrow IPC payloads mirroring IDENTIFICATIONS_TABLE / QUANTIFICATIONS_TABLE.

### 6.1 `SUBJECT_METADATA (0x19)` payload

```
uint32 arrow_ipc_length
bytes  arrow_ipc[arrow_ipc_length]   # Arrow IPC stream
```

Arrow schema:
```
external_id:        utf8 (required)
project:            utf8 (nullable)
sex:                utf8 (nullable)
birth_year:         int32 (nullable)         # widened from on-disk int64 to int32 for Arrow column-width consistency with Identification.spectrum_index
attributes_json:    utf8 (nullable)
```

Emit nothing when the Subject list is empty (zero packets for empty input).

### 6.2 `SAMPLE_METADATA (0x1A)` payload

```
uint32 arrow_ipc_length
bytes  arrow_ipc[arrow_ipc_length]   # Arrow IPC stream
```

Arrow schema:
```
sample_id:           utf8 (required)
subject_external_id: utf8 (nullable)
sample_kind:         utf8 (nullable)
collected_at:        int64 (nullable)        # unix seconds — wider than birth_year intentionally
attributes_json:     utf8 (nullable)
```

Emit nothing when empty.

### 6.3 Cross-language byte equivalence

Same rule as IDENTIFICATIONS_TABLE / QUANTIFICATIONS_TABLE: **logical equivalence**, not byte equality. Arrow Java / pyarrow / libarrow-C++ each emit different flatbuffer envelopes; the row content cross-decodes correctly. The `uint32 length` prefix is byte-identical.

### 6.4 Ordering (transport-spec §5.4)

The §5.4 ordering already lists SUBJECT_METADATA + SAMPLE_METADATA in slot 3 (after ENCRYPTION_ALGORITHM + DATASET_PROVENANCE, before references). Subjects emit first, then Samples (forward references resolve correctly during streaming materialise).

## 7. API surface (per SDK)

### Java

```java
// New classes:
public record Subject(String externalId, String project, String sex,
                       int birthYear, Map<String, String> attributes) {
    public Subject {
        // ... required-field + null-attr normalization
    }
    public String attributesJson() { /* sorted-key JSON */ }
}

public record Sample(String sampleId, String subjectExternalId,
                      String sampleKind, long collectedAt,
                      Map<String, String> attributes) { /* ... */ }

// New SpectralDataset accessors:
public List<Subject> subjects();
public List<Sample> samples();

// New SpectralDataset.create overload (parallel to provenance):
public static SpectralDataset create(String path, String title, String isaId,
        List<AcquisitionRun> runs, List<Identification> identifications,
        List<Quantification> quantifications, List<ProvenanceRecord> provenance,
        List<Subject> subjects, List<Sample> samples);
```

### Python

```python
@dataclass(frozen=True, slots=True)
class Subject:
    external_id: str
    project: str = ""
    sex: str = ""
    birth_year: int = 0
    attributes: dict[str, str] = field(default_factory=dict)

@dataclass(frozen=True, slots=True)
class Sample:
    sample_id: str
    subject_external_id: str = ""
    sample_kind: str = ""
    collected_at: int = 0
    attributes: dict[str, str] = field(default_factory=dict)

# SpectralDataset:
@property
def subjects(self) -> list[Subject]: ...
@property
def samples(self) -> list[Sample]: ...

# write_minimal kwargs: subjects=..., samples=...
```

### Objective-C

```objc
@interface TTIOSubject : NSObject
@property (nonatomic, readonly) NSString *externalId;
@property (nonatomic, readonly) NSString *project;
@property (nonatomic, readonly) NSString *sex;
@property (nonatomic, readonly) int64_t birthYear;
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *attributes;
+ (instancetype)subjectWithExternalId:(NSString *)externalId ...;
@end

@interface TTIOSample : NSObject /* parallel */ @end

// TTIOSpectralDataset:
@property (nonatomic, readonly) NSArray<TTIOSubject *> *subjects;
@property (nonatomic, readonly) NSArray<TTIOSample *> *samples;
```

## 8. Conformance

- AccessorMatrix gains 2 entries: `SUBJECTS`, `SAMPLES` (in all 3 SDKs and the xlang matrix).
- `everything.tio` fixture extended with 2 subjects + 3 samples (one sample subject-less, one subject sample-less, one fully linked) to exercise the soft-FK validation rules.
- Cross-lang xlang matrix grows: 9 lang pairs × 2 new accessors = 18 cells, target 18 PASS.

## 9. Backward compat

- Existing `.tio` files (no `/study/subjects/` or `/study/samples/`) read with `subjects()` / `samples()` returning empty lists. No errors.
- Existing transport streams (no 0x19 / 0x1A packets) read fine — readers just see no subject/sample packets. `transport_v0_11` feature flag stays unset if no other v0.11 content is present.
- `AcquisitionRun.sampleName` remains the canonical run→sample link string. When both Sample rows and `AcquisitionRun.sampleName` are present, applications SHOULD treat `sampleName` as a foreign key into Sample. No automatic enrichment — Sample lookup is the caller's job.
- Cohort-server `SubjectFieldPredicate` queries can now resolve against the on-disk `/study/subjects/.../external_id, sex, ...` attributes when present. No code change required in the server; the existing predicate logic just sees new data.

## 10. Non-questions explicitly closed

- **"Per-investigation subjects?"** → No. Per-dataset only for v1.4. The `isaInvestigationId` string is still the only cross-dataset link.
- **"Sample inheritance / parent-of-aliquots?"** → No. Out of scope. `attributes["parent_sample_id"]` is sufficient if a depositor needs it.
- **"Consent / withdrawal flags?"** → No first-class field. Goes in `attributes` if needed.
- **"Sample → run automatic discovery?"** → No. Callers iterate runs + match `sampleName` themselves. Possibly a v1.4.1 convenience helper.

## 11. Risks / unknowns

- **HDF5 group-name safety:** depositors might choose `external_id` / `sample_id` values with `/`, spaces, or non-ASCII. Writer validates and rejects with a clear error. Documenting an "id safety" sentence in format-spec §11.
- **Sample.collected_at sentinel `0`:** January 1 1970 is theoretically a valid value. Risk is negligible (no clinical samples from 1970). Could use `Long.MIN_VALUE` or a separate `has_collected_at` bool, but the spec keeps `0` for simplicity.
- **Arrow nullability:** the Arrow schema marks every field except `external_id`/`sample_id` as nullable. Writers MUST emit null (not empty-string) for absent values so Python / ObjC readers correctly produce `None` / `nil`. The Identification/Quantification codec writes empty-string by convention; subject/sample uses null for the optional core fields and sticks with the codec's empty-string convention for `attributes_json` (always present, just `"{}"` if empty).
