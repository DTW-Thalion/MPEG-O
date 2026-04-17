# MPEG-O v0.6 — Storage/Transport Provider Abstraction

> **Status:** v0.5.0 is **complete**. Three languages at feature parity
> (ObjC 836 assertions, Python 120 tests, Java 62 tests). This session
> executes **Milestones 37–42** to introduce the **pluggable storage and
> transport provider architecture**, fix Java compound I/O, add Thermo
> `.raw` import via delegation, and publish to PyPI + Maven Central.

---

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `README.md`, `ARCHITECTURE.md`, `WORKPLAN.md`, `docs/format-spec.md`, `docs/feature-flags.md`
3. Verify all three builds:
   ```bash
   cd objc && ./build.sh check
   cd ../python && pip install -e ".[test,import,crypto]" && pytest
   cd ../java && mvn verify -B
   ```
4. Tag v0.5.0 if not already tagged.

---

## Binding Decisions — All Prior (1–28) Active, Plus:

29. **Storage/Transport Provider abstraction.** The data model and API are the standard; the storage backend is a pluggable implementation detail. All three languages define provider protocols/ABCs/interfaces. HDF5 becomes one implementation, not the only one.
30. **Provider auto-discovery.** ObjC: `NSBundle` + `+load` registration. Python: `importlib.metadata` entry points. Java: `java.util.ServiceLoader`. Providers register themselves; upper layers query the registry.
31. **Provider capability floor.** Every storage provider MUST support: hierarchical groups, named datasets with typed arrays, partial reads (hyperslab equivalent), chunked storage, compression, compound types with VL strings, and scalar/array attributes on groups and datasets. The interface defines all of these; providers that cannot deliver a capability throw a clear `UnsupportedOperationException` / `NSError` / `NotImplementedError`.
32. **Two providers in v0.6.** `Hdf5Provider` (refactored from existing code) and `MemoryProvider` (in-memory, for tests and transient pipelines). The MemoryProvider proves the abstraction actually works.
33. **Transport is orthogonal to storage.** `LocalTransport` (POSIX), `S3Transport` (ROS3 for ObjC, fsspec for Python), `HttpTransport` (range requests). Transport delivers bytes; storage interprets them.
34. **Thermo `.raw` via delegation to ThermoRawFileParser.** No proprietary code in MPEG-O's dependency tree. Shell out to `ThermoRawFileParser` (user-installed), capture mzML output, read with existing mzML reader.
35. **Maven Central groupId: `global.thalion`** (reversed `thalion.global`). Full artifact: `global.thalion:mpgo:0.6.0`.
36. **Multiple releases before v1.0.** v0.6 API review is a checkpoint, not a freeze.

---

## Dependency Graph

```
  M37 (Java compound I/O)     M38 (Thermo delegation)
       |                           |
       v                           |
  M39 (Provider abstraction — all three languages)
       |                           |
       +------------+--------------+
                    |
                    v
               M40 (Publishing: PyPI + Maven Central)
                    |
                    v
               M41 (API review checkpoint)
                    |
                    v
               M42 (v0.6.0 release)
```

M37 and M38 are independent and can start in parallel. M39 depends on M37 (Java needs working compound I/O before refactoring into providers). M40 depends on M39 (publish the provider-based architecture). M38 feeds into M39 (Thermo reader uses the format provider pattern).

---

## Milestone 37 — Java Compound Dataset I/O + JSON Parsing

**License:** LGPL-3.0

v0.5 Java writes JSON attributes and returns `List.of()` for compound reads. This blocks Java from properly reading ObjC/Python-written files.

**Deliverables**

- `Hdf5CompoundType.java` upgraded: VL-string-aware compound type creation, read, write via `H5Tcreate(H5T_COMPOUND)` + `H5Tset_size(H5T_VARIABLE)`
- `SpectralDataset.create()` writes native compound datasets matching `format-spec.md` §6
- `SpectralDataset.open()` reads native compound datasets for identifications, quantifications, provenance
- Full JSON parsing for `readCompoundIdentifications`, `readCompoundQuantifications`, `readCompoundProvenance` (currently return `List.of()`)
- JSON fallback retained for v0.1/v0.2 files
- JSON attribute mirror retained on write for backward compat

**Acceptance**

- [x] Java writes compound identifications matching format-spec §6.1
- [x] Java reads ObjC-written compound idents/quants/provenance — all fields match
- [x] Java-written compound datasets readable by ObjC and Python
- [x] v0.1 JSON fallback works
- [x] Three-way cross-compat green

**Shipped:** commit `e4fac3c`. Native compound write via
`NativeStringPool` (sun.misc.Unsafe-backed C-string pool); JSON
attribute mirror emitted by all three languages per format-spec
§11.1; fixtures regenerated.

---

## Milestone 38 — Thermo `.raw` Import via ThermoRawFileParser Delegation

**License:** Apache-2.0

No proprietary code in MPEG-O. Shell out to the user-installed `ThermoRawFileParser` binary, which converts `.raw` → mzML, then read the mzML with our existing reader.

**Deliverables**

**Python: `mpeg_o.importers.thermo_raw`**

```python
def read(path: str | Path, *,
         thermorawfileparser: str | None = None) -> SpectralDataset:
    """Import a Thermo .raw file via ThermoRawFileParser.

    Args:
        path: Path to the .raw file
        thermorawfileparser: Path to ThermoRawFileParser binary.
            If None, searches PATH. Raises FileNotFoundError if not found.

    The binary is invoked as:
        ThermoRawFileParser -i <raw> -o <tmpdir> -f 2  # format 2 = mzML

    The resulting mzML is parsed with mpeg_o.importers.mzml.read(),
    then the temp file is deleted.
    """
```

**ObjC: `MPGOThermoRawReader`**

Replace the stub with a real implementation that:
1. Uses `NSTask` to invoke `ThermoRawFileParser` (or `mono ThermoRawFileParser.exe` on systems without .NET 8)
2. Captures the mzML output in a temp directory
3. Reads with `MPGOMzMLReader`
4. Cleans up temp files
5. Returns nil + descriptive NSError if ThermoRawFileParser not found

**Java: `ThermoRawReader.java`**

Same pattern: `ProcessBuilder` to invoke ThermoRawFileParser, parse mzML output with `MzMLReader`.

**`docs/vendor-formats.md` update:**
- Installation instructions for ThermoRawFileParser (.NET 8 runtime, or Mono, or Conda/BioContainers)
- Note that Thermo's `.raw` format has no open specification
- Link to CompOmics ThermoRawFileParser repo

**Testing:**
- If ThermoRawFileParser is on PATH, run integration test with a small `.raw` fixture
- If not on PATH, skip gracefully with log message
- Unit test the delegation mechanism with a mock binary that outputs known mzML

**Acceptance**

- [x] Python: `thermo_raw.read("sample.raw")` returns valid SpectralDataset (when ThermoRawFileParser available)
- [x] ObjC: `MPGOThermoRawReader` returns dataset (when available)
- [x] Java: `ThermoRawReader.read()` returns dataset (when available)
- [x] Missing binary → clear error, not crash
- [x] Mock-binary unit test works in CI without ThermoRawFileParser installed
- [x] `docs/vendor-formats.md` updated

**Shipped:** commit `5fd96bc`. Binary resolution order: explicit arg →
`THERMORAWFILEPARSER` env → `ThermoRawFileParser` on PATH →
`ThermoRawFileParser.exe` + mono. Integration tests use a bash mock
binary so CI doesn't need the real parser installed.

---

## Milestone 39 — Storage/Transport Provider Abstraction (All Three Languages)

**License:** LGPL-3.0

This is the headline milestone. Extract protocols/ABCs/interfaces for storage and transport. Refactor all existing HDF5 code to implement the new protocols. Add a MemoryProvider to prove the abstraction.

### Part A — Define the Provider Interfaces

**ObjC protocols** (in `objc/Source/Providers/`):

```objc
@protocol MPGOStorageProvider <NSObject>
- (id<MPGOStorageGroup>)rootGroup:(NSError **)error;
- (BOOL)close:(NSError **)error;
- (BOOL)isOpen;
- (NSString *)providerName;  // "hdf5", "memory", etc.
@end

@protocol MPGOStorageGroup <NSObject>
- (NSString *)name;
- (BOOL)hasChild:(NSString *)name;
- (NSArray<NSString *> *)childNames:(NSError **)error;

// Subgroup navigation
- (id<MPGOStorageGroup>)openGroup:(NSString *)name error:(NSError **)error;
- (id<MPGOStorageGroup>)createGroup:(NSString *)name error:(NSError **)error;
- (BOOL)deleteChild:(NSString *)name error:(NSError **)error;

// Dataset access
- (id<MPGOStorageDataset>)openDataset:(NSString *)name error:(NSError **)error;
- (id<MPGOStorageDataset>)createDataset:(NSString *)name
                              precision:(MPGOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                       compressionLevel:(NSInteger)level
                                  error:(NSError **)error;

// Compound dataset access
- (id<MPGOStorageDataset>)createCompoundDataset:(NSString *)name
                                          fields:(NSArray<MPGOCompoundField *> *)fields
                                           count:(NSUInteger)count
                                           error:(NSError **)error;

// Attributes
- (BOOL)hasAttribute:(NSString *)name;
- (NSString *)stringAttribute:(NSString *)name error:(NSError **)error;
- (BOOL)setStringAttribute:(NSString *)name value:(NSString *)value error:(NSError **)error;
- (int64_t)integerAttribute:(NSString *)name defaultValue:(int64_t)def;
- (BOOL)setIntegerAttribute:(NSString *)name value:(int64_t)value error:(NSError **)error;
@end

@protocol MPGOStorageDataset <NSObject>
- (MPGOPrecision)precision;
- (NSUInteger)length;
- (NSData *)readAll:(NSError **)error;
- (NSData *)readSlice:(NSRange)range error:(NSError **)error;   // hyperslab
- (BOOL)writeData:(NSData *)data error:(NSError **)error;
- (BOOL)close;
@end
```

**Python ABCs** (in `mpeg_o/providers/base.py`):

```python
class StorageProvider(ABC):
    @abstractmethod
    def root_group(self) -> "StorageGroup": ...
    @abstractmethod
    def close(self) -> None: ...
    @abstractmethod
    def provider_name(self) -> str: ...

class StorageGroup(ABC):
    @abstractmethod
    def has_child(self, name: str) -> bool: ...
    @abstractmethod
    def child_names(self) -> list[str]: ...
    @abstractmethod
    def open_group(self, name: str) -> "StorageGroup": ...
    @abstractmethod
    def create_group(self, name: str) -> "StorageGroup": ...
    @abstractmethod
    def open_dataset(self, name: str) -> "StorageDataset": ...
    @abstractmethod
    def create_dataset(self, name: str, precision: Precision,
                       length: int, chunk_size: int = 16384,
                       compression_level: int = 6) -> "StorageDataset": ...
    @abstractmethod
    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> "StorageDataset": ...
    @abstractmethod
    def get_attribute(self, name: str) -> str | int | None: ...
    @abstractmethod
    def set_attribute(self, name: str, value: str | int) -> None: ...
    @abstractmethod
    def has_attribute(self, name: str) -> bool: ...

class StorageDataset(ABC):
    @abstractmethod
    def read(self, offset: int = 0, count: int = -1) -> np.ndarray: ...
    @abstractmethod
    def write(self, data: np.ndarray) -> None: ...
    @abstractmethod
    def precision(self) -> Precision: ...
    @abstractmethod
    def length(self) -> int: ...
```

**Java interfaces** (in `com.dtwthalion.mpgo.providers`):

```java
public interface StorageProvider extends AutoCloseable {
    StorageGroup rootGroup();
    String providerName();
}

public interface StorageGroup extends AutoCloseable {
    boolean hasChild(String name);
    List<String> childNames();
    StorageGroup openGroup(String name);
    StorageGroup createGroup(String name);
    StorageDataset openDataset(String name);
    StorageDataset createDataset(String name, Precision precision,
                                  long length, int chunkSize, int compressionLevel);
    StorageDataset createCompoundDataset(String name,
                                          List<CompoundField> fields, int count);
    String getStringAttribute(String name);
    void setStringAttribute(String name, String value);
    long getIntegerAttribute(String name, long defaultValue);
    void setIntegerAttribute(String name, long value);
    boolean hasAttribute(String name);
}

public interface StorageDataset extends AutoCloseable {
    Object readData();                      // full read
    Object readSlice(long offset, int count); // hyperslab
    void writeData(Object data);
    Precision precision();
    long length();
}
```

### Part B — Provider Registry + Auto-Discovery

**ObjC:** `MPGOProviderRegistry` singleton. Providers register via `+load`:

```objc
@interface MPGOProviderRegistry : NSObject
+ (instancetype)shared;
- (void)registerProvider:(Class<MPGOStorageProvider>)providerClass
                 forScheme:(NSString *)scheme;  // "file", "s3", "memory"
- (id<MPGOStorageProvider>)providerForURL:(NSURL *)url error:(NSError **)error;
@end

// In MPGOHDF5Provider.m:
+ (void)load {
    [[MPGOProviderRegistry shared] registerProvider:self forScheme:@"file"];
    [[MPGOProviderRegistry shared] registerProvider:self forScheme:@"hdf5"];
}
```

**Python:** `importlib.metadata` entry points:

```toml
# pyproject.toml
[project.entry-points."mpeg_o.providers"]
hdf5 = "mpeg_o.providers.hdf5:Hdf5Provider"
memory = "mpeg_o.providers.memory:MemoryProvider"
```

```python
# mpeg_o/providers/registry.py
from importlib.metadata import entry_points

def discover_providers() -> dict[str, type[StorageProvider]]:
    eps = entry_points(group="mpeg_o.providers")
    return {ep.name: ep.load() for ep in eps}
```

**Java:** `java.util.ServiceLoader`:

```java
// META-INF/services/com.dtwthalion.mpgo.providers.StorageProvider
// contains: com.dtwthalion.mpgo.providers.Hdf5Provider
// contains: com.dtwthalion.mpgo.providers.MemoryProvider

public class ProviderRegistry {
    public static StorageProvider forScheme(String scheme) {
        for (StorageProvider p : ServiceLoader.load(StorageProvider.class)) {
            if (p.supportsScheme(scheme)) return p;
        }
        throw new IllegalArgumentException("No provider for scheme: " + scheme);
    }
}
```

### Part C — Refactor Existing HDF5 Code into Hdf5Provider

**ObjC:**
- `MPGOHDF5Provider` implements `<MPGOStorageProvider>` — wraps `MPGOHDF5File`
- `MPGOHDF5GroupAdapter` implements `<MPGOStorageGroup>` — wraps `MPGOHDF5Group`
- `MPGOHDF5DatasetAdapter` implements `<MPGOStorageDataset>` — wraps `MPGOHDF5Dataset`
- Existing `MPGOHDF5File`/`Group`/`Dataset` classes remain internally but are no longer called directly by upper layers
- `MPGOAcquisitionRun`, `MPGOSpectralDataset`, `MPGOCompoundIO`, `MPGOSignatureManager`, `MPGOEncryptionManager`, `MPGOKeyRotationManager` all switch from direct HDF5 calls to `<MPGOStorageGroup>` / `<MPGOStorageDataset>` protocol calls
- Thread safety (`pthread_rwlock_t`) stays on `MPGOHDF5File`; the adapter delegates lock calls

**Python:**
- `mpeg_o.providers.hdf5.Hdf5Provider` wraps `h5py.File`
- `mpeg_o.providers.hdf5.Hdf5Group` wraps `h5py.Group`
- `mpeg_o.providers.hdf5.Hdf5Dataset` wraps `h5py.Dataset`
- `_hdf5_io.py` helper functions refactored to use provider interfaces
- `SpectralDataset.open()` resolves provider via registry, then proceeds with provider-agnostic code
- fsspec cloud access becomes a transport concern: `Hdf5Provider` accepts either a path or a file-like object

**Java:**
- `com.dtwthalion.mpgo.providers.Hdf5Provider` wraps existing `Hdf5File`
- Same adapter pattern

### Part D — MemoryProvider (Second Provider)

In-memory storage for tests and transient pipelines. Proves the abstraction works without touching disk.

**Data model:** `Map<String, Object>` tree where groups are nested maps and datasets are typed arrays. Attributes are a parallel metadata map.

```python
class MemoryProvider(StorageProvider):
    """In-memory storage provider. Data lives in Python dicts.
    Useful for tests and transient pipelines where no file I/O is needed."""

    def __init__(self):
        self._root = {"__attrs__": {}, "__datasets__": {}, "__children__": {}}

    def root_group(self) -> "MemoryGroup":
        return MemoryGroup(self._root)
```

**Three-language implementation:** ObjC (NSDictionary tree), Python (dict tree), Java (HashMap tree).

**Validation:** Create a `SpectralDataset` using `MemoryProvider`, populate with spectra, read back, verify all values match. This is the proof that the abstraction works — if `SpectralDataset` functions identically over `MemoryProvider` and `Hdf5Provider`, the protocol contract is correct.

### Part E — SpectralDataset.open() Factory

```python
def open(path_or_url: str, *, provider: str | None = None, **kwargs):
    if provider:
        # Explicit provider override
        cls = registry.get(provider)
    elif "://" in path_or_url:
        scheme = path_or_url.split("://")[0]
        cls = registry.for_scheme(scheme)
    else:
        # Local file — detect by extension or content
        cls = registry.for_scheme("file")
    return cls.open(path_or_url, **kwargs)
```

### Acceptance

- [x] ObjC: `MPGOStorageProvider` / `Group` / `Dataset` protocols defined
- [x] Python: `StorageProvider` / `Group` / `Dataset` ABCs defined
- [x] Java: `StorageProvider` / `Group` / `Dataset` interfaces defined
- [x] `Hdf5Provider` passes all existing tests (no regression)
- [x] `MemoryProvider` passes a round-trip test: create dataset with spectra, read back, verify
- [x] Provider registry auto-discovers both providers in all three languages
- [x] `SpectralDataset.open()` resolves providers by URL scheme (via factory + ServiceLoader / entry-points / +load)
- [x] Three-way cross-compat still green (HDF5 path unchanged)
- [x] S3 transport works via HDF5 provider (Python: fsspec; Java/ObjC cloud deferred to v0.7)
- [x] `ARCHITECTURE.md` updated with provider architecture diagram

**Shipped:** commits `109a3bd` (protocols + providers + registries) and
`1429b89` (protocol extensions — N-D, `native_handle()` escape — plus
SpectralDataset.open routed through Hdf5Provider in all three languages).

**Caller refactor scope deliberately narrowed** (tracked in
`ARCHITECTURE.md` "Caller refactor status" table): top-level
SpectralDataset.open/create/write go through a Provider; byte-level
code (AcquisitionRun signal channels, MSImage cubes, signature /
encryption / key-rotation classes, compound metadata helpers) uses
`provider.native_handle()` and stays HDF5-shaped. A non-HDF5
provider (Zarr, SQLite) in v0.7 will drive the remaining protocol
extensions (codec metadata on datasets, byte-level dataset access,
higher-rank support on Hdf5Provider) organically.

---

## Milestone 40 — Package Publishing (PyPI + Maven Central)

**License:** N/A

**PyPI:**
- Publish `mpeg-o` v0.6.0 to PyPI proper. `pip install mpeg-o` works globally.
- Includes provider entry points for auto-discovery.

**Maven Central:**
- Publish `global.thalion:mpgo:0.6.0` via Sonatype OSSRH.
- Requires: GPG-signed artifacts, Sonatype JIRA account, domain `thalion.global` verified.
- `pom.xml` groupId changes from `com.dtwthalion` to `global.thalion`.
- Includes `META-INF/services` for ServiceLoader discovery.

**GitHub Packages:** Continue as mirror for both.

**Acceptance**

- [ ] `pip install mpeg-o` from PyPI works
- [ ] `global.thalion:mpgo` resolves from Maven Central without special repo config
- [ ] Both packages include correct license, URLs, description
- [ ] Entry points / ServiceLoader configs present and functional

---

## Milestone 41 — API Review Checkpoint

**License:** All

Not a freeze — a checkpoint for consistency and documentation before more releases.

**Deliverables**

- `docs/api-review-v0.6.md`: lists every public class/method/interface across three languages, flags inconsistencies
- Provider interfaces marked as **Provisional** (may change before v1.0)
- Core data model classes (SignalArray, Spectrum, AcquisitionRun, SpectralDataset) marked as **Stable**
- All public APIs have docstrings/javadoc/header comments
- `docs/migration-guide.md`: mzML → MPEG-O and nmrML → MPEG-O workflows

**Acceptance**

- [ ] `docs/api-review-v0.6.md` committed
- [ ] `docs/migration-guide.md` committed
- [ ] No undocumented public APIs
- [ ] Provider interfaces clearly marked Provisional

---

## Milestone 42 — v0.6.0 Release

**Deliverables**

- All docs updated (ARCHITECTURE with provider diagram, format-spec, feature-flags, vendor-formats, api-review, migration-guide)
- CI: three-language matrix + cross-compat + provider tests
- Packages on PyPI and Maven Central
- `pom.xml` groupId: `global.thalion`
- Tag v0.6.0

**Acceptance**

- [ ] All three languages green
- [ ] Three-way cross-compat green
- [ ] MemoryProvider round-trip passes in all three languages
- [ ] `pip install mpeg-o` from PyPI
- [ ] Maven Central resolves
- [ ] v0.1–v0.5 backward compat preserved
- [ ] Tag pushed

---

## Known Gotchas

**Inherited (1–25):** All prior gotchas active.

**New (v0.6):**

26. **Provider refactor scope.** Every class that currently calls `MPGOHDF5Group` or `MPGOHDF5Dataset` directly must be updated to use `<MPGOStorageGroup>` / `<MPGOStorageDataset>`. This includes `MPGOAcquisitionRun`, `MPGOSpectralDataset`, `MPGOCompoundIO`, `MPGOSignatureManager`, `MPGOEncryptionManager`, `MPGOKeyRotationManager`, `MPGOAnonymizer`, `MPGOFeatureFlags`. Grep for `MPGOHDF5` in the source to find all call sites.

27. **MemoryProvider compound types.** The MemoryProvider must support compound datasets (list-of-dicts internally). This is simpler than HDF5 compound types but the interface must be identical from the caller's perspective.

28. **Provider entry point naming.** Python entry points use `mpeg_o.providers` group. Java uses `com.dtwthalion.mpgo.providers.StorageProvider` service interface (note: this must be updated to `global.thalion.mpgo.providers.StorageProvider` when groupId changes in M40). ObjC uses `+load` class method registration.

29. **ThermoRawFileParser detection.** Search PATH for `ThermoRawFileParser` (Linux .NET 8 self-contained), `ThermoRawFileParser.exe` (Mono), or check `THERMORAWFILEPARSER` env var. The binary name varies by installation method (Conda, Docker, manual).

30. **Maven Central groupId migration.** Changing from `com.dtwthalion` to `global.thalion` is a breaking change for any Java consumer. Since v0.5 was only on GitHub Packages (not Maven Central), the blast radius is minimal, but document the change clearly.

31. **Sonatype OSSRH setup.** Requires: Sonatype JIRA account, domain verification for `thalion.global` (TXT record or GitHub repo proof), GPG key for artifact signing, CI secrets for deployment. This setup work should happen early in the release cycle, not during M40.

---

## Execution Checklist

1. Tag v0.5.0 if needed.
2. **M37:** Java compound I/O fix. **Pause.**
3. **M38:** Thermo delegation. **Pause.**
4. **M39:** Provider abstraction (all three languages). **Pause.**
5. **M40:** PyPI + Maven Central publishing. **Pause.**
6. **M41:** API review checkpoint. **Pause.**
7. **M42:** Tag v0.6.0.

**CI must be green before any milestone is complete.**

---

## Deferred to v0.7+

| Item | Description |
|---|---|
| ZarrProvider | Zarr storage backend (the abstraction makes this straightforward) |
| SQLiteProvider | SQLite metadata + binary signal storage |
| DBMSTransport | Store .mpgo data in Postgres/MySQL |
| Java cloud access | ROS3 VFD or equivalent for Java |
| Bruker TDF import | Real implementation via TDF SDK |
| Waters MassLynx import | Stub + implementation |
| Raman/IR support | New Spectrum subclasses |
| Streaming transport | MPEG-G Part 2 protocol |
| v1.0 API freeze | After production feedback on provider architecture |
