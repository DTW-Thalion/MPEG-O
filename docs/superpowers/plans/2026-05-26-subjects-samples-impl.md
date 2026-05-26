# Subjects + Samples Implementation Plan (Stage 6 / Deferral 2)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Implement `Subject` and `Sample` as first-class TTI-O entities per `docs/superpowers/specs/2026-05-26-subjects-samples-design.md`, including HDF5 storage, transport packets (SUBJECT_METADATA 0x19 + SAMPLE_METADATA 0x1A), and cross-lang conformance.

**Architecture:** Per-row HDF5 group layout (`/study/subjects/<external_id>/` + `/study/samples/<sample_id>/` with typed attributes + JSON-serialised open `attributes` slot). Transport via Arrow IPC packets mirroring IDENTIFICATIONS_TABLE / QUANTIFICATIONS_TABLE. Java → Python → ObjC parity. Cross-lang conformance.

**Tech Stack:** Same as v0.11. JDK 25 + Maven, Python 3.12 + pyarrow 16, ObjC GNUstep + libarrow C++ 24.

## File map

| File | Role |
|---|---|
| `java/src/main/java/global/thalion/ttio/Subject.java` (new) | Java Subject record |
| `java/src/main/java/global/thalion/ttio/Sample.java` (new) | Java Sample record |
| `java/src/main/java/global/thalion/ttio/SpectralDataset.java` | `subjects()` + `samples()` accessors + create overload |
| `java/src/main/java/global/thalion/ttio/transport/ArrowIpcCodec.java` | + `encodeSubjects` / `decodeSubjects` / `encodeSamples` / `decodeSamples` |
| `java/src/main/java/global/thalion/ttio/transport/TransportWriter.java` | + `writeSubjectMetadata` / `writeSampleMetadata` + prelude wiring |
| `java/src/main/java/global/thalion/ttio/transport/TransportReader.java` | + 0x19 / 0x1A decoders + materialise |
| `python/src/ttio/subject.py` (new) | Python Subject dataclass |
| `python/src/ttio/sample.py` (new) | Python Sample dataclass |
| `python/src/ttio/spectral_dataset.py` | `subjects` + `samples` properties + write_minimal kwargs |
| `python/src/ttio/transport/arrow_ipc.py` | + 4 new schema / encode / decode functions |
| `python/src/ttio/transport/codec.py` | + writer + reader for 0x19 / 0x1A + prelude |
| `objc/Source/TTIOSubject.{h,m}` (new) | ObjC TTIOSubject class |
| `objc/Source/TTIOSample.{h,m}` (new) | ObjC TTIOSample class |
| `objc/Source/TTIOSpectralDataset.{h,m}` | `subjects` + `samples` accessors |
| `objc/Source/Transport/TTIOArrowIpcCodec.{h,m,Bridge.mm}` | + encode/decode entry points |
| `objc/Source/Transport/TTIOTransportWriter.m` | + emit methods + prelude |
| `objc/Source/Transport/TTIOTransportReader.m` | + decoders + materialise |
| `docs/format-spec.md` | New §11 covering subjects/samples HDF5 layout |
| `docs/transport-spec.md` | Update §4.22 to reflect the implemented wire format |

## Task list

### Task 6.1: Java `Subject` + `Sample` types + SpectralDataset accessors + HDF5 layout

- [ ] **Step 1:** Create `java/src/main/java/global/thalion/ttio/Subject.java` as a `record` per spec §4.1. Include a private static `attributesJson()` helper using `TreeMap` (matches the Java sort-keys fix from `9022622f`). Constructor validates `externalId` is non-empty and normalises null inputs (`project`/`sex` → `""`; `attributes` → `Map.of()`).

- [ ] **Step 2:** Create `Sample.java` analogously.

- [ ] **Step 3:** Add `subjects` + `samples` fields to `SpectralDataset`. Read them eagerly in the existing open() path when `/study/subjects/` or `/study/samples/` groups are present (mirror how `references` are read). Add `subjects()` / `samples()` accessors returning unmodifiable lists.

- [ ] **Step 4:** Add the 9-arg `SpectralDataset.create(...)` overload accepting `List<Subject> subjects, List<Sample> samples`. Write `/study/subjects/<external_id>/` and `/study/samples/<sample_id>/` per-row groups with typed attributes. Validate per spec §4.4 (duplicate IDs raise; empty IDs raise; soft-FK mismatch logs WARNING).

- [ ] **Step 5:** Add a 7-arg → 9-arg forwarding overload passing `List.of(), List.of()` so callers don't break.

- [ ] **Step 6:** Write test `SpectralDatasetSubjectsSamplesTest.java`. Cover round-trip, empty list, duplicate ID, soft-FK warning, attributes round-trip, legacy `.tio` (no subjects group) returns empty list.

- [ ] **Step 7:** Run + commit:
```
cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -B test -Dtest='Subject*,Sample*,*Subject*,*Sample*' -Dhdf5.jar=/usr/share/java/jarhdf5.jar 2>&1 | tail -10
git add java/src/main/java/global/thalion/ttio/Subject.java \
        java/src/main/java/global/thalion/ttio/Sample.java \
        java/src/main/java/global/thalion/ttio/SpectralDataset.java \
        java/src/test/java/global/thalion/ttio/SpectralDatasetSubjectsSamplesTest.java
git commit -m "feat(ttio): Subject + Sample first-class on SpectralDataset (Stage 6.1)"
```

### Task 6.2: Java SUBJECT_METADATA + SAMPLE_METADATA transport packets

- [ ] **Step 1:** Extend `ArrowIpcCodec.java` with two new schemas + 4 static methods:
```java
private static final Schema SUBJECT_SCHEMA = new Schema(List.of(
    new Field("external_id",     FieldType.notNullable(new ArrowType.Utf8()), null),
    new Field("project",         FieldType.nullable(new ArrowType.Utf8()), null),
    new Field("sex",             FieldType.nullable(new ArrowType.Utf8()), null),
    new Field("birth_year",      FieldType.nullable(new ArrowType.Int(32, true)), null),
    new Field("attributes_json", FieldType.nullable(new ArrowType.Utf8()), null)
));
// SAMPLE_SCHEMA similar with int64 collected_at
public static byte[] encodeSubjects(List<Subject> rows) { /* ... */ }
public static List<Subject> decodeSubjects(byte[] ipc) { /* ... */ }
public static byte[] encodeSamples(List<Sample> rows) { /* ... */ }
public static List<Sample> decodeSamples(byte[] ipc) { /* ... */ }
```

- [ ] **Step 2:** Test `ArrowIpcCodecSubjectsSamplesTest.java`: empty + non-empty round-trip for both, attribute Map preservation.

- [ ] **Step 3:** Add `writeSubjectMetadata(List<Subject>)` + `writeSampleMetadata(List<Sample>)` to `TransportWriter`. Mirror `writeIdentificationsTable` exactly: empty → no packet, else `uint32 len + IPC bytes`.

- [ ] **Step 4:** Add reader decoders for 0x19 / 0x1A in `TransportReader`. Accumulate into `collectedSubjects` / `collectedSamples`, pass into the materialised `SpectralDataset.create` via the 9-arg overload.

- [ ] **Step 5:** Wire into `writeDataset`'s v0.11 prelude in §5.4 order (after provenance, before references). Update `has_v011_content` to OR `!dataset.subjects().isEmpty() || !dataset.samples().isEmpty()`.

- [ ] **Step 6:** Write test `TransportSubjectsSamplesTest.java`: 4 tests (subjects-only round-trip, samples-only round-trip, empty → no packets, both populated → ordering check). Use SpectralDataset fixtures from 6.1.

- [ ] **Step 7:** Run + commit:
```
git add java/src/main/java/global/thalion/ttio/transport/ArrowIpcCodec.java \
        java/src/main/java/global/thalion/ttio/transport/TransportWriter.java \
        java/src/main/java/global/thalion/ttio/transport/TransportReader.java \
        java/src/test/java/global/thalion/ttio/transport/{ArrowIpcCodecSubjectsSamplesTest,TransportSubjectsSamplesTest}.java
git commit -m "feat(ttio/transport): SUBJECT_METADATA (0x19) + SAMPLE_METADATA (0x1A) Arrow IPC packets"
```

### Task 6.3: Python parity (types + SpectralDataset + arrow_ipc + transport)

Same shape as 6.1 + 6.2, but in Python. THREE commits keep history clean:

- [ ] **Commit 1:** Create `python/src/ttio/subject.py` + `sample.py` dataclasses; add `subjects` + `samples` lazy properties on `SpectralDataset`; extend `write_minimal` with `subjects=` + `samples=` kwargs; HDF5 per-row group write/read mirroring Java.
- [ ] **Commit 2:** Extend `python/src/ttio/transport/arrow_ipc.py` with `_SUBJECT_SCHEMA` + `_SAMPLE_SCHEMA` + 4 encode/decode functions.
- [ ] **Commit 3:** Add `write_subject_metadata` + `write_sample_metadata` to `TransportWriter`; reader 0x19 / 0x1A decoders; `write_dataset` prelude wiring in §5.4 order.

Tests at `python/tests/test_subject.py`, `test_sample.py`, `test_spectral_dataset_subjects_samples.py`, `test_transport_subjects_samples.py`, `test_arrow_ipc_subjects_samples.py`.

### Task 6.4: ObjC parity (types + SpectralDataset + ArrowIpcCodec + transport)

Three commits, mirroring Task 6.3 in ObjC:

- [ ] **Commit 1:** `TTIOSubject.{h,m}` + `TTIOSample.{h,m}` classes; `-subjects` + `-samples` accessors on `TTIOSpectralDataset`; HDF5 per-row group write/read.
- [ ] **Commit 2:** Extend `TTIOArrowIpcBridge.mm` + `TTIOArrowIpcCodec.{h,m}` with subject/sample schemas + encode/decode entry points.
- [ ] **Commit 3:** `-writeSubjectMetadata:` + `-writeSampleMetadata:` on `TTIOTransportWriter`; reader 0x19 / 0x1A decoders; `-writeDataset:` prelude wiring.

### Task 6.5: Doc updates — format-spec §11 + transport-spec §4.22

- [ ] **Step 1:** Write `docs/format-spec.md` §11 documenting the per-row HDF5 group layout per spec §5.
- [ ] **Step 2:** Update `docs/transport-spec.md` §4.22 from "reserved" to the implemented Arrow IPC wire format per spec §6.
- [ ] **Step 3:** Commit:
```
git commit -m "docs: format-spec §11 + transport-spec §4.22 — subjects + samples"
```

### Task 6.6: AccessorMatrix + xlang conformance + everything.tio extension

- [ ] **Step 1:** Add `SUBJECTS` + `SAMPLES` to `AccessorSpec` in all 3 SDKs (Java enum, Python dataclass list, ObjC array). Fixtures: deterministic 2-subject / 3-sample layout matching the spec §8 cross-cardinality cases.
- [ ] **Step 2:** Extend `FixtureBuilder.buildEverything()` in all 3 SDKs to include subjects + samples.
- [ ] **Step 3:** Extend `python/tests/conformance/test_transport_v0_11_xlang.py` with the 2 new accessors (18 new cells). All 18 SHOULD pass.
- [ ] **Step 4:** Run all 3 SDKs' AccessorMatrix tests + xlang matrix. Verify 95 total cells expected (8 + 3 + 2 accessors × 9 pairs - 9 GENOMIC_RUNS env-skip = 102 actual = 93 pass + 9 skip).
- [ ] **Step 5:** Commit:
```
git commit -m "test(ttio/transport): AccessorMatrix + xlang for SUBJECTS + SAMPLES"
```

### Task 6.7: Stage 6 gate + tag

- [ ] **Step 1:** Run Java + Python + ObjC full suites. All green.
- [ ] **Step 2:** Run xlang matrix: 111 cells total (102 pre-6.6 + 18 new - 9 env-skip = ... aim for 111 pass + 9 skip).
- [ ] **Step 3:** Tag + push:
```
git tag stage-6-transport-v0-11-subjects-samples
git push origin feat/transport-spec-v0-11 stage-6-transport-v0-11-subjects-samples
```

## Self-Review

- **Spec coverage:** every section of the design spec maps to a task above (§4 types → 6.1+6.3+6.4; §5 HDF5 → 6.1+6.3+6.4 + §11 doc in 6.5; §6 transport → 6.2+6.3+6.4 + §4.22 doc in 6.5; §7 API surface → 6.1+6.3+6.4; §8 conformance → 6.6; §9 backward compat → tested in every task).
- **Placeholder scan:** No "TBD" / "TODO" steps. Every commit specifies exactly which files to touch.
- **Type consistency:** `attributes_json` schema column name reused across Java/Python/ObjC. `birth_year` is int32 in Arrow, int64 in HDF5 — intentional, documented in spec §6 / 5.
