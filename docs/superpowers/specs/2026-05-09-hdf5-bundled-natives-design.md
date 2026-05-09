# HDF5 bundled natives in tio-browser fat JAR — design

**Status:** Approved 2026-05-09. Awaiting implementation plan.

**Goal:** the `tio-browser-X.Y.Z-shaded.jar` runs out of the box on Linux x64, macOS arm64, and Windows x64 with no system HDF5 install required. `java -jar tio-browser-1.4.0-shaded.jar` on a fresh machine just works.

**Non-goals:**
- Library-side bundling. `java/pom.xml` keeps `<scope>system</scope>` for jarhdf5; only the *distribution* bundles HDF5.
- Universal2 macOS, linux-aarch64, win-aarch64. Same platform set as `libttio_rans_jni`.
- BLOSC plugin (Zarr-only, not an HDF5 filter). ZSTD plugin (Bruker-internal, not an HDF5 filter).
- Switching to a pure-Java HDF5 implementation. The library's HDF5 abstraction (`global.thalion.ttio.hdf5.*`) stays on `hdf.hdf5lib.H5` (HDFGroup's JHI5).

---

## Bundle target

For each platform, ship the following native artifacts under `tio-browser/src/main/resources/native/<platform>/hdf5/`:

| File | Purpose |
|---|---|
| `libhdf5.so.310` (Linux), `libhdf5.310.dylib` (macOS), `hdf5.dll` (Windows) | HDF5 1.14 core C library |
| `libhdf5_hl.so.310` / `.310.dylib` / `hdf5_hl.dll` | HDF5 high-level API |
| `libhdf5_java.so` / `.dylib` / `hdf5_java.dll` | JNI shim that JHI5 (`hdf.hdf5lib.H5`) loads |
| `libh5lz4.so` / `.dylib` / `h5lz4.dll` | LZ4 filter plugin (HDF5 filter id 32004) — required for the `Compression.LZ4` codec exposed by `Hdf5Group.java:165-175` |

Plus the Java side: `jarhdf5.jar` (~700 KB), shaded into the fat JAR via a real Maven dependency (replacing the current `<scope>system</scope>`).

Approximate size impact: +30 MB to the shaded JAR (HDF5 ≈ 9 MB / platform × 3 = 27 MB; JHI5 jar 0.7 MB; LZ4 plugin 0.1 MB / platform × 3). Final `tio-browser-X.Y.Z-shaded.jar` ≈ 64 MB.

---

## Components

### 1. `Hdf5NativeLoader` (new)

Path: `tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoader.java`

```java
public final class Hdf5NativeLoader {
    private static volatile boolean loaded = false;
    private static Path tempDir = null;

    /** Idempotent: extract bundled HDF5 natives to a temp dir,
     *  System.load them in dependency order, register the LZ4 plugin
     *  search path. Throws Hdf5NativeLoadException on hard failures
     *  (temp-dir creation, resource missing, UnsatisfiedLinkError on
     *  a core lib). LZ4 plugin failures are non-fatal (logged). */
    public static synchronized void ensureLoaded() { ... }

    /** Test seam: where the libs ended up. null until ensureLoaded(). */
    public static Path tempDir() { return tempDir; }

    private Hdf5NativeLoader() {}
}
```

### 2. Native resource layout

```
tio-browser/src/main/resources/native/
├── linux-x64/
│   ├── libttio_rans_jni.so          (existing)
│   └── hdf5/
│       ├── libhdf5.so.310
│       ├── libhdf5_hl.so.310
│       ├── libhdf5_java.so
│       └── libh5lz4.so
├── mac-aarch64/
│   ├── libttio_rans_jni.dylib       (existing)
│   └── hdf5/
│       ├── libhdf5.310.dylib
│       ├── libhdf5_hl.310.dylib
│       ├── libhdf5_java.dylib
│       └── libh5lz4.dylib
└── win-x64/
    ├── ttio_rans_jni.dll            (existing)
    └── hdf5/
        ├── hdf5.dll
        ├── hdf5_hl.dll
        ├── hdf5_java.dll
        └── h5lz4.dll
```

### 3. `release-shaded-jar.yml` matrix updates

Each platform's `build-native` job gains an HDF5 build step before its existing native upload:

- **Linux x64 (`ubuntu-22.04`)**: existing `scripts/install-hdf5.sh 1.14.6` already builds HDF5 + JNI shim. Add `scripts/build-h5lz4.sh` (new) to compile the LZ4 filter plugin against that HDF5. Stage `/usr/local/lib/{libhdf5.so.310,libhdf5_hl.so.310,libhdf5_java.so}` and `libh5lz4.so` into `staging/native/linux-x64/hdf5/`.
- **macOS arm64 (`macos-14`)**: build HDF5 1.14 + JNI shim from source on macOS toolchain. Build LZ4 plugin. Stage `.dylib` files.
- **Windows x64 (`windows-2022`, MSYS2 UCRT64)**: `pacman -S mingw-w64-ucrt-x86_64-hdf5 mingw-w64-ucrt-x86_64-hdf5-tools`. Build LZ4 plugin from source against MSYS2's HDF5. Stage `.dll` files.

Each platform job uploads its `staging/native/<platform>/` tree as an artifact (existing pattern). The `build-shaded-jar` job downloads all three and copies into `tio-browser/src/main/resources/native/` before `mvn package` runs.

### 4. `tio-browser/pom.xml` jarhdf5 scope change

Replace:
```xml
<dependency>
    <groupId>local.hdfgroup</groupId>
    <artifactId>jarhdf5</artifactId>
    <version>1.14.6</version>
    <scope>system</scope>
    <systemPath>${hdf5.jar}</systemPath>
</dependency>
```

With either:
- A Maven Central artifact for HDFGroup's JHI5 (e.g. `org.hdfgroup:hdf-java:3.3.x` if it exists and is current; needs verification during implementation), OR
- A custom local Maven repo: install `/usr/local/lib/jarhdf5.jar` to `<repo>` in CI before build, depend with `<scope>compile</scope>`. Path TBD during implementation.

Either way, the resulting shaded JAR carries the JHI5 classes.

---

## Loader flow

`Hdf5NativeLoader.ensureLoaded()` on first call:

1. **Detect platform** from `os.name` + `os.arch`. Supported map: `Linux x86_64 → linux-x64`, `Mac OS X aarch64 → mac-aarch64`, `Windows 10 amd64 → win-x64`. Unsupported → log warning, return without loading (graceful degradation; JHI5 falls back to `System.loadLibrary` lookup against `java.library.path`).

2. **Create temp dir** via `Files.createTempDirectory("tio-browser-hdf5-")`. Register `Runtime.getRuntime().addShutdownHook` for recursive deletion.

3. **Extract resources** in fixed dependency order from `/native/<platform>/hdf5/` to the temp dir. (Each JVM gets its own temp dir via `createTempDirectory`, so per-process isolation is automatic — no name-prefixing needed.)

4. **`System.load(absolutePath)`** for each non-plugin lib in dependency order: HDF5 core → HDF5 high-level → HDF5 JNI shim. If any throws `UnsatisfiedLinkError`, wrap as `Hdf5NativeLoadException(libname, cause)` and rethrow.

5. **Register LZ4 plugin path** with `H5.H5PLappend(tempDir.toString())`. Java can't set env vars after JVM start, so `HDF5_PLUGIN_PATH` is not the right tool; JHI5's API is. If `H5PLappend` itself fails (e.g. JHI5 < 1.12), log warning and continue — non-fatal.

6. Mark `loaded = true`.

`App.start(Stage)` calls `Hdf5NativeLoader.ensureLoaded()` as its first line, before constructing `MainWindow`.

---

## Failure handling

| Scenario | Behavior |
|---|---|
| Unsupported platform (linux-aarch64, win-arm64, macOS Intel) | Log warning, skip extract. JHI5 falls through to `System.loadLibrary("hdf5_java")`. If that finds nothing, `H5.H5open()` throws `UnsatisfiedLinkError` on first H5 call — surfaces in Diagnostics dialog as `ERROR: HDF5 library not loaded`. |
| Temp-dir creation fails (read-only filesystem) | Throw `Hdf5NativeLoadException`. `App.start` catches and shows a modal Alert: `"Cannot extract bundled HDF5 — set java.io.tmpdir to a writable directory or install HDF5 1.14+ system-wide."` Then `System.exit(1)`. |
| Resource missing from JAR (corrupt download) | Same — `Hdf5NativeLoadException` + Alert + exit. |
| `System.load` fails on a core lib (libhdf5 / libhdf5_hl / libhdf5_java) | Wrap `UnsatisfiedLinkError` as `Hdf5NativeLoadException(libName, cause)`. Same modal Alert, paraphrasing the libname. |
| LZ4 plugin missing or `H5PLappend` fails | Non-fatal. Log warning. App works for non-LZ4 datasets. Opening an LZ4-compressed dataset surfaces the existing "LZ4 filter (id 32004) is not available" error from `Hdf5Group.java:170-174`. |

---

## Testing

| Test | Type | What |
|---|---|---|
| `Hdf5NativeLoaderTest` | unit | platform detection table; temp-dir creation/cleanup; idempotency (second `ensureLoaded()` is no-op); throws on missing resource (synthetic test JAR with missing entry) |
| `Hdf5NativeLoaderIntegrationTest` | TestFX (`@BeforeAll Platform.startup`) | calls `ensureLoaded()` then `H5.H5get_libversion(int[])`, asserts major=1, minor=14 |
| `Hdf5Lz4PluginTest` | integration | uses an `lz4_compressed.tio` fixture (small dataset compressed with `Compression.LZ4`); opens via `SpectralDataset.open`, asserts read succeeds with the bundled plugin |
| existing `mvn test` | regression | continues to work via the loader's idempotency on dev machines that have system HDF5 — the bundled libs win (per A1), exercising the bundled path even in dev |

The `lz4_compressed.tio` fixture lives under `tio-browser/src/test/resources/ttio/lz4_compressed.tio` and is generated once via `Hdf5Group.createDataset(..., Compression.LZ4, ...)` against the bundled HDF5 + LZ4 plugin during the test setup.

---

## Distribution: jpackage installers

The `native-package` Maven profile is unchanged. jpackage stages the shaded JAR (which now contains HDF5 natives) into the app image; no profile-side changes needed. The .deb/.dmg/.msi installers automatically inherit the bundled HDF5.

---

## Migration

- **Library devs**: no change. `java/pom.xml` keeps `<scope>system</scope>`. `mvn -pl java verify` continues to use system HDF5 as before.
- **Library consumers (Python, ObjC)**: no change. They consume the library, not the tio-browser distribution.
- **tio-browser devs running `mvn -pl tio-browser test`**: the loader runs first; the bundled HDF5 takes precedence over system HDF5 (per A1 — bundled always wins). Behavior is identical to a fresh-machine fat-JAR run, which is what we want for parity.
- **End users**: drop-in. `java -jar tio-browser-1.4.0-shaded.jar` works on any Linux x64 / macOS arm64 / Windows x64 machine with a JDK 17+, no other prerequisites.

---

## Versioning

This change is large enough to warrant a tio-browser version bump:
- `tio-browser/pom.xml` `<version>` 1.3.0 → 1.4.0.
- Repo tag `v1.4.0`.
- `CHANGELOG.md` `[1.4.0]` section under `[Unreleased]`, focused on the out-of-box install experience.

The library version (`global.thalion:ttio` 1.2.0) is unaffected.
