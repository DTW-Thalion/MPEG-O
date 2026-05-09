# Per-platform out-of-box tio-browser distribution — design

**Status:** Approved 2026-05-09. Awaiting implementation plan.

**Goal:** ship three platform-specific shaded JARs per tio-browser release. Each JAR runs out of the box on its target platform with no system HDF5 install, no system JavaFX, no other prerequisites beyond a JDK 17+ runtime. Each JAR carries only its own platform's natives — no cross-platform bloat.

Names:

- `tio-browser-1.4.0-linux-x64.jar`
- `tio-browser-1.4.0-mac-aarch64.jar`
- `tio-browser-1.4.0-win-x64.jar`

Approximate per-JAR size: ~31 MB each (vs. ~64 MB for a hypothetical universal-3-platforms-in-one JAR).

**Non-goals:**
- A "universal" all-platforms JAR (drops by 50% of overhead, but adds a "which one do I download" decision; we make the decision instead via per-platform names).
- Library-side bundling. `java/pom.xml` keeps `<scope>system</scope>` for jarhdf5; only the *distribution* bundles HDF5.
- Universal2 macOS, linux-aarch64, win-aarch64. Same platform set as `libttio_rans_jni`.
- BLOSC plugin (Zarr-only, not an HDF5 filter). ZSTD plugin (Bruker-internal, not an HDF5 filter).
- Switching to a pure-Java HDF5 implementation. The library's HDF5 abstraction (`global.thalion.ttio.hdf5.*`) stays on `hdf.hdf5lib.H5` (HDFGroup's JHI5).

---

## Bundle target (per JAR)

Each per-platform JAR bundles **only** its own platform's natives:

| File | Linux x64 | macOS arm64 | Windows x64 |
|---|---|---|---|
| TTI-O rANS native | `libttio_rans_jni.so` | `libttio_rans_jni.dylib` | `ttio_rans_jni.dll` |
| HDF5 1.14 core | `libhdf5.so.310` | `libhdf5.310.dylib` | `hdf5.dll` |
| HDF5 high-level | `libhdf5_hl.so.310` | `libhdf5_hl.310.dylib` | `hdf5_hl.dll` |
| HDF5 JNI shim | `libhdf5_java.so` | `libhdf5_java.dylib` | `hdf5_java.dll` |
| LZ4 filter plugin (id 32004) | `libh5lz4.so` | `libh5lz4.dylib` | `h5lz4.dll` |
| JavaFX runtime | `javafx-*-21.0.5-linux.jar` classes | `javafx-*-21.0.5-mac-aarch64.jar` classes | `javafx-*-21.0.5-win.jar` classes |
| JHI5 jar | `jarhdf5.jar` (~700 KB) | (same) | (same) |

Sizing:
- Existing universal-style 3-platform shaded JAR ≈ 34 MB.
- Per-platform shaded JAR ≈ 31 MB (one platform's libttio_rans + one JavaFX classifier + HDF5 stack).
- The cost saving relative to a universal-with-HDF5 JAR (~64 MB) is ~33 MB per download.

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

### 2. Native resource layout (per JAR)

Each per-platform JAR carries one platform tree, e.g. for the linux-x64 JAR:

```
native/
└── linux-x64/
    ├── libttio_rans_jni.so
    └── hdf5/
        ├── libhdf5.so.310
        ├── libhdf5_hl.so.310
        ├── libhdf5_java.so
        └── libh5lz4.so
```

The mac-aarch64 and win-x64 JARs have parallel single-platform trees. Resource paths are tagged by platform name (rather than just `native/hdf5/`) so the loader's platform-detect step gives a clear error message if someone runs the wrong JAR on the wrong OS: "expected `native/linux-x64/...` but you're on win-x64; download tio-browser-1.4.0-win-x64.jar instead."

### 3. `release-shaded-jar.yml` matrix updates

Restructure: the matrix `build-native` jobs each produce a complete shaded JAR for their platform — there is **no** separate `build-shaded-jar` assembly job that waits for all three.

For each platform `<P>`:

1. Existing native build step: produce `libttio_rans_jni` for `<P>`.
2. **New**: build HDF5 1.14 + JNI shim + LZ4 plugin for `<P>` (see per-platform recipes below).
3. Stage all natives into `tio-browser/src/main/resources/native/<P>/`.
4. Run `mvn -P <P> -Dhdf5.jar=<staged-jarhdf5.jar> package`. The `<P>` profile activates per-platform Maven dependencies (JavaFX classifier) and shade configuration.
5. Upload `tio-browser-1.4.0-<P>.jar` as the platform's release asset.

Per-platform HDF5 build recipes:

- **Linux x64 (`ubuntu-22.04`)**: existing `scripts/install-hdf5.sh 1.14.6` already builds HDF5 + JNI shim. Add `scripts/build-h5lz4.sh` (new) to compile the LZ4 filter plugin against that HDF5. Stage `/usr/local/lib/{libhdf5.so.310,libhdf5_hl.so.310,libhdf5_java.so,libh5lz4.so}` into `tio-browser/src/main/resources/native/linux-x64/hdf5/`.
- **macOS arm64 (`macos-14`)**: same `install-hdf5.sh` script; macOS toolchain produces `.dylib` files. Build LZ4 plugin via `scripts/build-h5lz4.sh`. Stage into `tio-browser/src/main/resources/native/mac-aarch64/hdf5/`.
- **Windows x64 (`windows-2022`, MSYS2 UCRT64)**: `pacman -S mingw-w64-ucrt-x86_64-hdf5 mingw-w64-ucrt-x86_64-hdf5-tools`. Build LZ4 plugin from source against MSYS2's HDF5. Stage `.dll` files into `tio-browser/src/main/resources/native/win-x64/hdf5/`.

Final release upload: 3 JARs as separate GitHub Release assets, each named clearly by platform.

### 4. `tio-browser/pom.xml` per-platform shading

The pom gets three Maven profiles (`linux-x64`, `mac-aarch64`, `win-x64`), each activated explicitly via `-P` in the matrix. Each profile sets:

- The JavaFX classifier dep set (e.g. `linux` for linux-x64, `mac-aarch64` for mac-aarch64, `win` for win-x64).
- A shade-plugin `<filter>` block excluding other-platform native resources (so `linux-x64`'s JAR doesn't accidentally ship `mac-aarch64/...` files even if they're in `src/main/resources/`).
- The `<finalName>` produces `tio-browser-${project.version}-${profile.classifier}` so each profile emits a distinctly-named JAR.

The `jarhdf5` dependency switches from `<scope>system</scope>` to either:

- A Maven Central artifact for HDFGroup's JHI5 (e.g. `org.hdfgroup:hdf-java:3.3.x` — needs verification during implementation), OR
- A custom local Maven repo: install `jarhdf5.jar` to `<repo>` in CI before build, depend with `<scope>compile</scope>`. Path TBD during implementation.

Either way, the JHI5 classes ship in each per-platform shaded JAR.

**Decision (Task A.1, 2026-05-09): Option B (local-repo vendoring).** A `repo1.maven.org` search for `g:org.hdfgroup` returns a single artifact, `org.hdfgroup:hdf-java:2.6.1` (published 2010), which predates HDF5 1.12 and lacks `H5.H5PLappend`. Other candidates surfaced (`org.broadinstitute:hdf5-java-bindings:1.2.0-hdf5_2.11.0`, the `org.scala-saddle:jhdf5` family, `io.jhdf:jhdf`) are either too old, target a different package (`ch.systemsx.cisd.hdf5`), or are pure-Java readers without the `hdf.hdf5lib.H5` JNI binding required by `Hdf5NativeLoader`. HDFGroup itself does not publish JHI5 to Maven Central. Strategy: vendor the locally-built `/usr/local/lib/jarhdf5-1.14.6.jar` (HDF5 1.14.6, confirmed via `javap` to expose both `H5get_libversion(int[])` and `H5PLappend(String)`) into a per-build Maven repo at `tio-browser/local-repo/` with coordinates `org.hdfgroup:jarhdf5:1.14.6`. The pom adds `<repository><id>local-jhi5</id><url>file://${project.basedir}/local-repo</url></repository>` and depends on it with `<scope>compile</scope>` so the classes shade into each per-platform JAR. CI installs the jar with `mvn install:install-file -Dfile=$STAGED_JARHDF5 -DgroupId=org.hdfgroup -DartifactId=jarhdf5 -Dversion=1.14.6 -Dpackaging=jar -DlocalRepositoryPath=tio-browser/local-repo` before `mvn package`. Phase A.4 implements this.

---

## Loader flow

`Hdf5NativeLoader.ensureLoaded()` on first call:

1. **Detect platform** from `os.name` + `os.arch`. Map to one of `linux-x64`, `mac-aarch64`, `win-x64`.

2. **Look up `/native/<platform>/hdf5/` resources**. Since each JAR carries only one platform, the lookup either succeeds (you're running the right JAR) or returns nothing (you're running the wrong JAR — covered in Failure handling below).

3. **Create temp dir** via `Files.createTempDirectory("tio-browser-hdf5-")`. Register `Runtime.getRuntime().addShutdownHook` for recursive deletion.

4. **Extract resources** in fixed dependency order from `/native/<platform>/hdf5/` to the temp dir. Each JVM gets its own temp dir via `createTempDirectory`, so per-process isolation is automatic — no name-prefixing needed.

5. **`System.load(absolutePath)`** for each non-plugin lib in dependency order: HDF5 core → HDF5 high-level → HDF5 JNI shim. If any throws `UnsatisfiedLinkError`, wrap as `Hdf5NativeLoadException(libname, cause)` and rethrow.

6. **Register LZ4 plugin path** with `H5.H5PLappend(tempDir.toString())`. Java can't set env vars after JVM start, so `HDF5_PLUGIN_PATH` is not the right tool; JHI5's API is. If `H5PLappend` itself fails (e.g. JHI5 < 1.12), log warning and continue — non-fatal.

7. Mark `loaded = true`.

`App.start(Stage)` calls `Hdf5NativeLoader.ensureLoaded()` as its first line, before constructing `MainWindow`.

---

## Failure handling

| Scenario | Behavior |
|---|---|
| Detected platform doesn't match the JAR's native tree (e.g. running `tio-browser-1.4.0-linux-x64.jar` on a Mac) | Modal Alert: `"This is the linux-x64 build of tio-browser. You're on mac-aarch64. Download tio-browser-1.4.0-mac-aarch64.jar from the release page and re-run."` Then `System.exit(1)`. |
| Genuinely unsupported platform (linux-aarch64, win-arm64, macOS Intel) | Modal Alert: `"tio-browser doesn't ship a build for linux-aarch64 yet. Either build from source (see README) or open an issue."` Then `System.exit(1)`. |
| Temp-dir creation fails (read-only filesystem) | Throw `Hdf5NativeLoadException`. `App.start` catches and shows a modal Alert: `"Cannot extract bundled HDF5 — set java.io.tmpdir to a writable directory."` Then `System.exit(1)`. |
| Resource missing from JAR (corrupt download) | Same — `Hdf5NativeLoadException` + Alert + exit. |
| `System.load` fails on a core lib (libhdf5 / libhdf5_hl / libhdf5_java) | Wrap `UnsatisfiedLinkError` as `Hdf5NativeLoadException(libName, cause)`. Same modal Alert, paraphrasing the libname. |
| LZ4 plugin missing or `H5PLappend` fails | Non-fatal. Log warning. App works for non-LZ4 datasets. Opening an LZ4-compressed dataset surfaces the existing "LZ4 filter (id 32004) is not available" error from `Hdf5Group.java:170-174`. |

The "wrong JAR for this OS" case becomes the most common end-user failure. The Alert text includes the exact correct asset name to download — high-quality error UX.

---

## Testing

| Test | Type | What |
|---|---|---|
| `Hdf5NativeLoaderTest` | unit | platform detection table; temp-dir creation/cleanup; idempotency (second `ensureLoaded()` is no-op); throws `Hdf5NativeLoadException` on missing resource (synthetic test JAR with missing entry); throws on platform-mismatch (synthetic test JAR with the wrong native tree) |
| `Hdf5NativeLoaderIntegrationTest` | TestFX (`@BeforeAll Platform.startup`) | calls `ensureLoaded()` then `H5.H5get_libversion(int[])`, asserts major=1, minor=14 |
| `Hdf5Lz4PluginTest` | integration | uses an `lz4_compressed.tio` fixture (small dataset compressed with `Compression.LZ4`); opens via `SpectralDataset.open`, asserts read succeeds with the bundled plugin |
| existing `mvn -P <P> test` | regression | continues to work via the loader's idempotency on dev machines that have system HDF5 — the bundled libs win (per A1), exercising the bundled path even in dev |

The `lz4_compressed.tio` fixture lives under `tio-browser/src/test/resources/ttio/lz4_compressed.tio` and is generated once via `Hdf5Group.createDataset(..., Compression.LZ4, ...)` against the bundled HDF5 + LZ4 plugin during the test setup.

Each per-platform CI job runs `mvn -P <its-platform> verify` end-to-end, exercising the loader + JHI5 against the freshly-built natives.

---

## Distribution: jpackage installers

The `native-package` Maven profile becomes platform-specific too — each per-platform CI job runs `mvn -P <its-platform> -P native-package package` to produce a platform-specific installer alongside the platform-specific JAR. The release uploads both:

- `tio-browser_1.4.0_amd64.deb` (Linux)
- `tio-browser-1.4.0-mac-aarch64.dmg` (macOS arm64)
- `tio-browser-1.4.0-win-x64.msi` (Windows)

The shaded JAR fed into jpackage already contains its platform's HDF5; jpackage just wraps it with a JRE.

---

## Migration

- **Library devs**: no change. `java/pom.xml` keeps `<scope>system</scope>`. `mvn -pl java verify` continues to use system HDF5 as before.
- **Library consumers (Python, ObjC)**: no change. They consume the library, not the tio-browser distribution.
- **tio-browser devs**: must pass `-P linux-x64` (or whichever platform you're on) to `mvn` invocations. CI handles this in the matrix; local devs add an alias or pick whichever profile matches their dev machine. Without a profile selector, `mvn` errors helpfully with "no profile activated; pick one of `linux-x64`, `mac-aarch64`, `win-x64`."
- **End users**: download the matching JAR for their OS from the release page. Each JAR is self-contained; `java -jar tio-browser-1.4.0-<platform>.jar` just works on the matching machine, no other prerequisites.

---

## Versioning

This change is large enough to warrant a tio-browser version bump:
- `tio-browser/pom.xml` `<version>` 1.3.0 → 1.4.0.
- Repo tag `v1.4.0`.
- `CHANGELOG.md` `[1.4.0]` section under `[Unreleased]`, focused on the per-platform out-of-box install.

The library version (`global.thalion:ttio` 1.2.0) is unaffected.
