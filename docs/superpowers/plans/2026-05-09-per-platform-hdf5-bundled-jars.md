# Per-platform tio-browser distribution with bundled HDF5 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace tio-browser's universal-3-platforms shaded JAR with three per-platform shaded JARs (`linux-x64`, `mac-aarch64`, `win-x64`), each bundling its own HDF5 1.14 + LZ4 plugin so `java -jar tio-browser-1.4.0-<platform>.jar` works on a fresh machine with only a JDK 17+.

**Architecture:** New `Hdf5NativeLoader` class extracts platform-specific HDF5 native libs from the JAR's `native/<platform>/hdf5/` resources to a per-JVM temp dir at `App.start()` time, calls `System.load()` in dependency order, then registers the LZ4 filter plugin path via `H5.H5PLappend`. Three Maven profiles (one per platform) drive the build: each activates the matching JavaFX classifier deps and shade `<filter>` block. The `release-shaded-jar.yml` matrix collapses from "3 native build jobs + 1 assembly job" to "3 build-and-shade jobs"; each platform's job builds HDF5 + LZ4 plugin from source, stages natives, and produces its own complete shaded JAR.

**Tech Stack:** Java 17+ (Hdf5NativeLoader, JHI5 = `hdf.hdf5lib.H5`), JUnit 5 + TestFX (tests), Maven 3.9+ with profiles (build), HDF5 1.14.6 + LZ4 plugin (native), GitHub Actions matrix (CI).

**Spec:** [`docs/superpowers/specs/2026-05-09-hdf5-bundled-natives-design.md`](../specs/2026-05-09-hdf5-bundled-natives-design.md).

---

## Phase A — Maven plumbing

### Task A.1: Discover the JHI5 Maven coordinate (pre-implementation investigation)

**Files:** none (research only).

- [ ] **Step 1: Check Maven Central for an HDFGroup-published JHI5 artifact.**

```bash
wsl -d Ubuntu -- bash -c 'curl -s "https://search.maven.org/solrsearch/select?q=g:org.hdfgroup&rows=20&wt=json" | python3 -m json.tool | head -60'
```

Look for an artifactId like `hdf-java`, `hdf5-java`, or `jhi5` published by `org.hdfgroup`. Note the latest version that includes the JHI5 classes (`hdf.hdf5lib.H5`).

- [ ] **Step 2: If a Maven Central artifact exists**, record its `groupId:artifactId:version` triple. Use this triple in Task A.4. Skip Step 3.

- [ ] **Step 3: If no Maven Central artifact**, plan to vendor the local `jarhdf5.jar` into a per-build local Maven repo. Approach for Task A.4: stage `/usr/local/lib/jarhdf5.jar` to `tio-browser/local-repo/org/hdfgroup/jarhdf5/1.14.6/jarhdf5-1.14.6.jar` (and a hand-crafted `.pom` next to it), declare `<repository><url>file://${project.basedir}/local-repo</url></repository>` in pom, depend with normal `compile` scope.

- [ ] **Step 4: Decide and document.** Add a one-line note at the top of the spec under "Components → 4. tio-browser/pom.xml jarhdf5 scope change" that records which path was chosen and why. Commit the doc edit.

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add docs/superpowers/specs/2026-05-09-hdf5-bundled-natives-design.md && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "docs(spec): pin jarhdf5 dependency strategy"'
```

### Task A.2: Add three platform Maven profiles to tio-browser/pom.xml

**Files:**
- Modify: `tio-browser/pom.xml`

Add a `<profiles>` block (at the same level as the existing one for `native-package`) with three profiles. Each profile sets a `<platform.classifier>` property and adds a JavaFX classifier dep override.

- [ ] **Step 1: Read the current pom.xml dependencies section** (`tio-browser/pom.xml:32-146`) so you can see which JavaFX classifiers exist today (currently all 4: `linux`, `mac`, `mac-aarch64`, `win`). Confirm the existing layout matches what's described in Task A.3 below.

- [ ] **Step 2: Move the per-classifier JavaFX dependencies into their respective profiles.** Replace the four JavaFX classifier blocks (lines 54-126) with a single profile-scoped set inside each platform profile.

Edit `tio-browser/pom.xml` to remove the existing JavaFX classifier dependency blocks (the `linux`, `mac`, `mac-aarch64`, `win` variants of `javafx-controls`, `javafx-graphics`, `javafx-fxml`) from `<dependencies>`. Replace with profiles at end of pom (before closing `</project>`):

```xml
<profiles>
    <profile>
        <id>linux-x64</id>
        <properties>
            <platform.classifier>linux-x64</platform.classifier>
            <javafx.classifier>linux</javafx.classifier>
        </properties>
        <dependencies>
            <dependency>
                <groupId>org.openjfx</groupId>
                <artifactId>javafx-controls</artifactId>
                <version>${javafx.version}</version>
                <classifier>${javafx.classifier}</classifier>
            </dependency>
            <dependency>
                <groupId>org.openjfx</groupId>
                <artifactId>javafx-graphics</artifactId>
                <version>${javafx.version}</version>
                <classifier>${javafx.classifier}</classifier>
            </dependency>
            <dependency>
                <groupId>org.openjfx</groupId>
                <artifactId>javafx-fxml</artifactId>
                <version>${javafx.version}</version>
                <classifier>${javafx.classifier}</classifier>
            </dependency>
        </dependencies>
    </profile>
    <profile>
        <id>mac-aarch64</id>
        <properties>
            <platform.classifier>mac-aarch64</platform.classifier>
            <javafx.classifier>mac-aarch64</javafx.classifier>
        </properties>
        <dependencies>
            <!-- same three javafx-* deps with ${javafx.classifier} -->
        </dependencies>
    </profile>
    <profile>
        <id>win-x64</id>
        <properties>
            <platform.classifier>win-x64</platform.classifier>
            <javafx.classifier>win</javafx.classifier>
        </properties>
        <dependencies>
            <!-- same three javafx-* deps with ${javafx.classifier} -->
        </dependencies>
    </profile>
</profiles>
```

(Repeat the three javafx-* blocks verbatim in each profile — Maven doesn't support inheritance between profiles. The `${javafx.classifier}` substitution is set per profile.)

- [ ] **Step 3: Verify the pom is well-formed.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -DskipTests -o validate -Dhdf5.jar=/usr/local/lib/jarhdf5.jar 2>&1 | tail -5'
```

Expected: BUILD SUCCESS.

- [ ] **Step 4: Verify each profile activates cleanly.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && for p in linux-x64 mac-aarch64 win-x64; do echo "=== $p ==="; mvn -P $p -DskipTests -o validate -Dhdf5.jar=/usr/local/lib/jarhdf5.jar 2>&1 | tail -2; done'
```

Expected: 3× BUILD SUCCESS.

- [ ] **Step 5: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/pom.xml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "build(tio-browser): per-platform Maven profiles for JavaFX classifier"'
```

### Task A.3: Configure shade plugin per profile (filter other-platform native resources, set finalName)

**Files:**
- Modify: `tio-browser/pom.xml`

Each profile gets a `<build><plugins>` block with a `maven-shade-plugin` execution that:

- Sets `<finalName>tio-browser-${project.version}-${platform.classifier}</finalName>`.
- Adds a `<filter>` excluding `native/*/` directories OTHER than the active platform.
- Drops `<shadedArtifactAttached>` so the JAR has a clean name (no `-shaded` suffix on the per-platform JARs).

- [ ] **Step 1: Edit the existing top-level `maven-shade-plugin` config** to remove `<shadedArtifactAttached>true</shadedArtifactAttached>` and `<shadedClassifierName>shaded</shadedClassifierName>`. Each profile will set its own `<finalName>` instead.

- [ ] **Step 2: In each of the 3 platform profiles** (added in Task A.2), append a `<build><plugins>` block:

```xml
<build>
    <finalName>tio-browser-${project.version}-${platform.classifier}</finalName>
    <plugins>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-shade-plugin</artifactId>
            <configuration>
                <filters>
                    <filter>
                        <artifact>${project.groupId}:${project.artifactId}</artifact>
                        <excludes>
                            <!-- For linux-x64 profile, exclude mac-aarch64/ and win-x64/.
                                 Adjust per profile. -->
                            <exclude>native/mac-aarch64/**</exclude>
                            <exclude>native/win-x64/**</exclude>
                        </excludes>
                    </filter>
                </filters>
            </configuration>
        </plugin>
    </plugins>
</build>
```

For the `mac-aarch64` profile, the excludes list `linux-x64/**` and `win-x64/**`. For `win-x64`: `linux-x64/**` and `mac-aarch64/**`.

- [ ] **Step 3: Build the linux-x64 JAR locally** to verify naming.

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && rm -rf target && mvn -P linux-x64 -DskipTests package -Dhdf5.jar=/usr/local/lib/jarhdf5.jar 2>&1 | tail -5 && ls target/*.jar'
```

Expected: `tio-browser-1.3.0-linux-x64.jar` and `tio-browser-1.3.0.jar` (the unshaded original) in target/.

- [ ] **Step 4: Verify the JAR contains only linux-x64 native resources.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && jar -tf target/tio-browser-1.3.0-linux-x64.jar | grep "^native/" | head -10'
```

Expected output should ONLY show `native/linux-x64/...` entries; no `native/mac-aarch64/` or `native/win-x64/`.

- [ ] **Step 5: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/pom.xml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "build(tio-browser): per-profile shade config + finalName + cross-platform native exclusion"'
```

### Task A.4: Switch jarhdf5 from system-scope to a real Maven dependency

**Files:**
- Modify: `tio-browser/pom.xml`

Apply the JHI5 dependency strategy chosen in Task A.1.

- [ ] **Step 1 (if Maven Central artifact found in A.1):** Replace the existing block at `tio-browser/pom.xml:46-52`:

```xml
<dependency>
    <groupId>org.hdfgroup</groupId>
    <artifactId>hdf5</artifactId>
    <version>1.10.10</version>
    <scope>system</scope>
    <systemPath>${hdf5.jar}</systemPath>
</dependency>
```

with the discovered Maven Central coordinate (e.g. `org.hdfgroup:hdf-java:3.3.x` — substitute the actual triple from Task A.1).

- [ ] **Step 1 (if local-repo strategy chosen in A.1):** Create `tio-browser/local-repo/org/hdfgroup/jarhdf5/1.14.6/` directory. Copy `/usr/local/lib/jarhdf5.jar` to `tio-browser/local-repo/org/hdfgroup/jarhdf5/1.14.6/jarhdf5-1.14.6.jar`. Create a hand-crafted `tio-browser/local-repo/org/hdfgroup/jarhdf5/1.14.6/jarhdf5-1.14.6.pom`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
    <modelVersion>4.0.0</modelVersion>
    <groupId>org.hdfgroup</groupId>
    <artifactId>jarhdf5</artifactId>
    <version>1.14.6</version>
    <packaging>jar</packaging>
</project>
```

Update the dependency in `tio-browser/pom.xml`:

```xml
<dependency>
    <groupId>org.hdfgroup</groupId>
    <artifactId>jarhdf5</artifactId>
    <version>1.14.6</version>
</dependency>
```

Add the local repo at the top-level `<project>`:

```xml
<repositories>
    <repository>
        <id>local-jhi5</id>
        <url>file://${project.basedir}/local-repo</url>
    </repository>
</repositories>
```

- [ ] **Step 2: Run `mvn package` to verify the dep resolves.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && rm -rf target && mvn -P linux-x64 -DskipTests package 2>&1 | tail -5'
```

Note: drop `-Dhdf5.jar=...` since system-scope is gone. Expected: BUILD SUCCESS.

- [ ] **Step 3: Verify the JHI5 classes are now in the shaded JAR.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && jar -tf target/tio-browser-1.3.0-linux-x64.jar | grep "^hdf/hdf5lib/" | head -5'
```

Expected: at least 5 lines like `hdf/hdf5lib/H5.class`, `hdf/hdf5lib/HDF5Constants.class`.

- [ ] **Step 4: Verify the surefire argLine no longer needs `-Dhdf5.jar=...`.** The `<argLine>` at `tio-browser/pom.xml:154-163` references `${hdf5.jar}` indirectly via the system path; remove that dependency by leaving the argLine alone (still valid since `java.library.path` for the native lookup is unchanged). If running tests breaks on a missing `${hdf5.jar}` token, change `<argLine>` to drop the `${hdf5.jar}` reference.

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 test 2>&1 | tail -8'
```

Expected: BUILD SUCCESS, 158 tests pass.

- [ ] **Step 5: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/pom.xml tio-browser/local-repo/ 2>/dev/null && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "build(tio-browser): vendor jarhdf5 as Maven dep so shaded JAR ships JHI5 classes"'
```

---

## Phase B — Hdf5NativeLoader

### Task B.1: Write the failing platform-detect test

**Files:**
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5NativeLoaderTest.java`

- [ ] **Step 1: Create the test file.**

```java
package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;

class Hdf5NativeLoaderTest {

    @Test
    void detectPlatformLinuxX64() {
        assertEquals("linux-x64",
            Hdf5NativeLoader.detectPlatform("Linux", "amd64"));
        assertEquals("linux-x64",
            Hdf5NativeLoader.detectPlatform("Linux", "x86_64"));
    }

    @Test
    void detectPlatformMacAarch64() {
        assertEquals("mac-aarch64",
            Hdf5NativeLoader.detectPlatform("Mac OS X", "aarch64"));
    }

    @Test
    void detectPlatformWinX64() {
        assertEquals("win-x64",
            Hdf5NativeLoader.detectPlatform("Windows 10", "amd64"));
    }

    @Test
    void detectPlatformReturnsNullForUnsupported() {
        assertNull(Hdf5NativeLoader.detectPlatform("Mac OS X", "x86_64"));
        assertNull(Hdf5NativeLoader.detectPlatform("Linux", "aarch64"));
        assertNull(Hdf5NativeLoader.detectPlatform("FreeBSD", "amd64"));
    }
}
```

- [ ] **Step 2: Run to verify failure.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5NativeLoaderTest test 2>&1 | tail -5'
```

Expected: COMPILATION ERROR (Hdf5NativeLoader class doesn't exist).

### Task B.2: Implement Hdf5NativeLoader.detectPlatform()

**Files:**
- Create: `tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoader.java`

- [ ] **Step 1: Create the source file with just the platform detection method (and minimal scaffolding).**

```java
package global.thalion.ttio.browser;

import java.nio.file.Path;

/**
 * Extracts and links the bundled HDF5 native libraries at startup so
 * the per-platform tio-browser shaded JAR works on a fresh machine
 * without any system HDF5 install.
 *
 * <p>Idempotent — safe to call from multiple entry points.
 *
 * <p>See {@code docs/superpowers/specs/2026-05-09-hdf5-bundled-natives-design.md}.
 */
public final class Hdf5NativeLoader {

    private static volatile boolean loaded = false;
    private static Path tempDir = null;

    private Hdf5NativeLoader() {}

    /**
     * Map JVM os.name + os.arch to one of the bundled platform classifiers
     * ({@code linux-x64}, {@code mac-aarch64}, {@code win-x64}). Returns
     * {@code null} if the running platform isn't bundled.
     *
     * <p>Package-private for unit-test access.
     */
    static String detectPlatform(String osName, String osArch) {
        String name = osName.toLowerCase();
        String arch = osArch.toLowerCase();
        if (name.contains("linux") && (arch.equals("amd64") || arch.equals("x86_64"))) {
            return "linux-x64";
        }
        if (name.contains("mac") && arch.equals("aarch64")) {
            return "mac-aarch64";
        }
        if (name.contains("windows") && (arch.equals("amd64") || arch.equals("x86_64"))) {
            return "win-x64";
        }
        return null;
    }

    public static Path tempDir() { return tempDir; }
}
```

- [ ] **Step 2: Run the test to verify it passes.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5NativeLoaderTest test 2>&1 | tail -5'
```

Expected: 4 tests pass.

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoader.java tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5NativeLoaderTest.java && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "feat(tio-browser): Hdf5NativeLoader skeleton + platform detection"'
```

### Task B.3: Write failing tests for resource extraction + idempotency

**Files:**
- Modify: `tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5NativeLoaderTest.java`

- [ ] **Step 1: Append these tests to the test file (inside the same class).**

```java
@Test
void ensureLoadedIsIdempotent() {
    Hdf5NativeLoader.ensureLoaded();
    Path first = Hdf5NativeLoader.tempDir();
    Hdf5NativeLoader.ensureLoaded();
    Path second = Hdf5NativeLoader.tempDir();
    // Same temp dir on second call — proves no re-extract.
    assertEquals(first, second);
}

@Test
void ensureLoadedExtractsAllRequiredLibsForLinuxX64(@TempDir Path overrideTemp) throws Exception {
    // Skip on platforms other than linux-x64 — we only have control
    // over the bundle layout for the platform whose JAR we built.
    org.junit.jupiter.api.Assumptions.assumeTrue(
        "linux-x64".equals(Hdf5NativeLoader.detectPlatform(
            System.getProperty("os.name"), System.getProperty("os.arch"))),
        "test only runs on linux-x64");
    Hdf5NativeLoader.ensureLoaded();
    Path tmp = Hdf5NativeLoader.tempDir();
    assertNotNull(tmp);
    // The 4 libs from the spec must end up extracted.
    assertTrue(Files.exists(tmp.resolve("libhdf5.so.310")));
    assertTrue(Files.exists(tmp.resolve("libhdf5_hl.so.310")));
    assertTrue(Files.exists(tmp.resolve("libhdf5_java.so")));
    assertTrue(Files.exists(tmp.resolve("libh5lz4.so")));
}
```

Add the imports `java.nio.file.Files`, `org.junit.jupiter.api.io.TempDir`, and `static org.junit.jupiter.api.Assertions.assertNotNull`, `assertTrue`.

- [ ] **Step 2: Run tests to verify the new ones fail (the platform-detect ones still pass).**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5NativeLoaderTest test 2>&1 | tail -10'
```

Expected: 4 pass, 2 fail with "ensureLoaded does not exist" or NPE.

### Task B.4: Implement ensureLoaded() with extract + System.load

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoader.java`

- [ ] **Step 1: Replace the body of `Hdf5NativeLoader.java`** (keep the class header + private constructor + `detectPlatform` + `tempDir()` accessor; add the rest):

```java
private static final String[] LINUX_LIBS = {
    "libhdf5.so.310", "libhdf5_hl.so.310", "libhdf5_java.so", "libh5lz4.so"
};
private static final String[] MAC_LIBS = {
    "libhdf5.310.dylib", "libhdf5_hl.310.dylib", "libhdf5_java.dylib", "libh5lz4.dylib"
};
private static final String[] WIN_LIBS = {
    "hdf5.dll", "hdf5_hl.dll", "hdf5_java.dll", "h5lz4.dll"
};

/**
 * Extract bundled HDF5 native libs to a per-JVM temp dir, System.load
 * them in dependency order, register the LZ4 plugin search path with
 * JHI5. Idempotent. Throws {@link Hdf5NativeLoadException} on hard
 * failures (temp-dir creation, missing resource, UnsatisfiedLinkError
 * on a core lib).
 */
public static synchronized void ensureLoaded() {
    if (loaded) return;
    String platform = detectPlatform(
        System.getProperty("os.name"), System.getProperty("os.arch"));
    if (platform == null) {
        throw new Hdf5NativeLoadException(
            "Unsupported platform: " + System.getProperty("os.name") + " "
            + System.getProperty("os.arch") + ". Supported: linux-x64, "
            + "mac-aarch64, win-x64.");
    }
    String[] libs = libsFor(platform);
    Path dir;
    try {
        dir = Files.createTempDirectory("tio-browser-hdf5-");
    } catch (IOException e) {
        throw new Hdf5NativeLoadException(
            "Cannot create temp dir for HDF5 extraction. Set java.io.tmpdir "
            + "to a writable directory.", e);
    }
    Runtime.getRuntime().addShutdownHook(new Thread(() -> deleteRecursive(dir)));
    String resourcePrefix = "/native/" + platform + "/hdf5/";
    for (String lib : libs) {
        Path target = dir.resolve(lib);
        try (InputStream in = Hdf5NativeLoader.class.getResourceAsStream(resourcePrefix + lib)) {
            if (in == null) {
                throw new Hdf5NativeLoadException(
                    "Resource missing from JAR: " + resourcePrefix + lib
                    + ". This JAR may be corrupt or built for the wrong "
                    + "platform — expected " + platform + ".");
            }
            Files.copy(in, target);
        } catch (IOException e) {
            throw new Hdf5NativeLoadException(
                "Failed to extract " + lib + " to " + target, e);
        }
    }
    // Load core libs in dependency order: hdf5 -> hdf5_hl -> hdf5_java.
    // The LZ4 plugin (last entry in libs[]) is loaded by HDF5 itself
    // when the plugin path is registered (see step 5 below); we don't
    // System.load it directly.
    for (int i = 0; i < libs.length - 1; i++) {
        Path lib = dir.resolve(libs[i]);
        try {
            System.load(lib.toAbsolutePath().toString());
        } catch (UnsatisfiedLinkError e) {
            throw new Hdf5NativeLoadException(
                "Failed to System.load " + lib + ": " + e.getMessage(), e);
        }
    }
    tempDir = dir;
    // LZ4 plugin path registration is in Task B.5.
    loaded = true;
}

private static String[] libsFor(String platform) {
    switch (platform) {
        case "linux-x64": return LINUX_LIBS;
        case "mac-aarch64": return MAC_LIBS;
        case "win-x64": return WIN_LIBS;
        default: throw new IllegalStateException("unreachable: " + platform);
    }
}

private static void deleteRecursive(Path dir) {
    try {
        if (!Files.exists(dir)) return;
        Files.walk(dir)
             .sorted(java.util.Comparator.reverseOrder())
             .forEach(p -> { try { Files.delete(p); } catch (IOException ignored) {} });
    } catch (IOException ignored) {}
}
```

Add a sibling exception class `Hdf5NativeLoadException`:

Path: `tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoadException.java`

```java
package global.thalion.ttio.browser;

/** Hard failure during {@link Hdf5NativeLoader#ensureLoaded()}. */
public class Hdf5NativeLoadException extends RuntimeException {
    public Hdf5NativeLoadException(String message) { super(message); }
    public Hdf5NativeLoadException(String message, Throwable cause) {
        super(message, cause);
    }
}
```

Add imports to Hdf5NativeLoader.java: `java.io.IOException`, `java.io.InputStream`, `java.nio.file.Files`.

- [ ] **Step 2: Run tests.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5NativeLoaderTest test 2>&1 | tail -10'
```

Expected:
- `detectPlatform*` tests still pass.
- `ensureLoadedExtractsAllRequiredLibsForLinuxX64` will FAIL because no native libs are bundled in resources yet — that's correct; we'll wire the build in Phase D and the test will pass when CI builds the per-platform JAR. Mark it as `@Disabled` for now with a TODO note pointing to Phase D, or use `assumeTrue(Files.exists(target))` style guard. Pick whichever is cleaner.

Decision: use `Assumptions.assumeTrue(Hdf5NativeLoader.class.getResourceAsStream("/native/linux-x64/hdf5/libhdf5.so.310") != null, "native HDF5 not bundled in this build (Phase D wires it)")`. This skips the test gracefully when the build hasn't staged natives yet.

- [ ] **Step 3: Update the test with the assumeTrue guard** so it skips cleanly until natives are bundled, then re-run.

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5NativeLoaderTest test 2>&1 | tail -10'
```

Expected: 5 pass + 1 skipped (the extract test, until Phase D bundles libs).

- [ ] **Step 4: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/ && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "feat(tio-browser): Hdf5NativeLoader extract + System.load + Hdf5NativeLoadException"'
```

### Task B.5: Register LZ4 plugin path via H5.H5PLappend

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoader.java`

- [ ] **Step 1: Append to `ensureLoaded()` — after the System.load loop, before `tempDir = dir; loaded = true;`:**

```java
// Register the LZ4 plugin search path with JHI5. We can't set
// HDF5_PLUGIN_PATH env var after JVM start (Java has no portable
// setenv), so use the JHI5 in-process API. Non-fatal on failure —
// the app still works for non-LZ4 datasets; opening LZ4-compressed
// data surfaces the existing "LZ4 filter (id 32004) is not
// available" error from Hdf5Group.java.
try {
    hdf.hdf5lib.H5.H5PLappend(dir.toAbsolutePath().toString());
} catch (Throwable t) {
    java.util.logging.Logger.getLogger(Hdf5NativeLoader.class.getName())
        .warning("Could not register LZ4 plugin path: " + t.getMessage()
            + " (LZ4-compressed datasets won't open, but other features work)");
}
```

- [ ] **Step 2: Run the test suite — should still pass (B.5 is non-test-breaking).**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 test 2>&1 | tail -8'
```

Expected: BUILD SUCCESS.

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/main/java/global/thalion/ttio/browser/Hdf5NativeLoader.java && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "feat(tio-browser): register LZ4 plugin path via H5.H5PLappend"'
```

### Task B.6: Wire Hdf5NativeLoader.ensureLoaded() into App.start()

**Files:**
- Modify: `tio-browser/src/main/java/global/thalion/ttio/browser/App.java`

- [ ] **Step 1: Read the current `App.start(Stage)` method** to locate the right insertion point (the very first line, before `getParameters()` is called or `MainWindow` is constructed).

- [ ] **Step 2: Add the call as the first line of `start(Stage)`:**

```java
@Override
public void start(Stage primaryStage) throws Exception {
    Hdf5NativeLoader.ensureLoaded();  // first thing — extracts + links bundled HDF5
    // ... existing body
}
```

Wrap the call in a try/catch that shows a modal Alert + exits on `Hdf5NativeLoadException`:

```java
try {
    Hdf5NativeLoader.ensureLoaded();
} catch (Hdf5NativeLoadException e) {
    new javafx.scene.control.Alert(
        javafx.scene.control.Alert.AlertType.ERROR,
        e.getMessage(),
        javafx.scene.control.ButtonType.CLOSE
    ).showAndWait();
    System.exit(1);
}
```

- [ ] **Step 3: Run the AppSmokeTest to confirm we haven't broken FX startup.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=AppSmokeTest test 2>&1 | tail -8'
```

Expected: BUILD SUCCESS.

- [ ] **Step 4: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/main/java/global/thalion/ttio/browser/App.java && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "feat(tio-browser): wire Hdf5NativeLoader.ensureLoaded as first line of App.start"'
```

### Task B.7: Add the integration test (Hdf5NativeLoaderIntegrationTest)

**Files:**
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5NativeLoaderIntegrationTest.java`

- [ ] **Step 1: Create the test.**

```java
package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/**
 * End-to-end test of {@link Hdf5NativeLoader}: invokes ensureLoaded,
 * then calls H5.H5get_libversion(int[]) and asserts HDF5 1.14. Skips
 * gracefully if the running JAR doesn't bundle natives for this
 * platform (Phase D wires the bundling).
 */
class Hdf5NativeLoaderIntegrationTest {

    @Test
    void loadedHdf5ReportsVersion1_14() {
        Assumptions.assumeTrue(
            Hdf5NativeLoader.class.getResourceAsStream(
                "/native/linux-x64/hdf5/libhdf5.so.310") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/mac-aarch64/hdf5/libhdf5.310.dylib") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/win-x64/hdf5/hdf5.dll") != null,
            "no platform's HDF5 natives bundled in this build");
        Hdf5NativeLoader.ensureLoaded();
        int[] v = new int[3];
        hdf.hdf5lib.H5.H5get_libversion(v);
        assertEquals(1, v[0], "HDF5 major version should be 1");
        assertEquals(14, v[1], "HDF5 minor version should be 14");
        assertNotNull(Hdf5NativeLoader.tempDir());
    }
}
```

- [ ] **Step 2: Run the integration test.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5NativeLoaderIntegrationTest test 2>&1 | tail -8'
```

Expected: SKIPPED (until Phase D bundles natives).

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5NativeLoaderIntegrationTest.java && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "test(tio-browser): Hdf5NativeLoaderIntegrationTest for end-to-end JHI5 load"'
```

---

## Phase C — HDF5 build scripts

### Task C.1: Write scripts/build-h5lz4.sh

**Files:**
- Create: `scripts/build-h5lz4.sh`

- [ ] **Step 1: Create the script.** Builds the LZ4 filter plugin against an already-installed HDF5 1.14 (typically at `/usr/local`) and emits `libh5lz4.so` (or `.dylib` / `.dll` depending on platform):

```bash
#!/usr/bin/env bash
# Build the HDF5 LZ4 filter plugin (HDF5 filter id 32004) against an
# already-installed HDF5. Outputs into /usr/local/lib alongside the
# core HDF5 libs (so the release-shaded-jar matrix stages everything
# from one directory).
#
# Usage: scripts/build-h5lz4.sh [version]
#   version: HDF5External Filters tag (default: master)
#
# Source: https://github.com/HDFGroup/hdf5_plugins/tree/master/LZ4
set -euo pipefail

VERSION="${1:-master}"
WORK="${WORK:-/tmp/h5lz4-build}"
PREFIX="${PREFIX:-/usr/local}"

rm -rf "$WORK"
git clone --depth 1 --branch "$VERSION" \
    https://github.com/HDFGroup/hdf5_plugins.git "$WORK"
cmake -B "$WORK/_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DPLUGIN_PACKAGE_NAME=lz4 \
    -DH5PL_VENDOR_PACKAGE_NAME=lz4 \
    -DBUILD_TESTING=OFF \
    -DH5PL_ALLOW_EXTERNAL_SUPPORT=TGZ \
    -DENABLE_LZ4=ON \
    -DENABLE_BSHUF=OFF -DENABLE_BLOSC=OFF -DENABLE_BLOSC2=OFF \
    -DENABLE_BZIP2=OFF -DENABLE_JPEG=OFF -DENABLE_LZF=OFF \
    -DENABLE_MAFISC=OFF -DENABLE_SZF=OFF -DENABLE_ZFP=OFF \
    -DENABLE_ZSTD=OFF \
    "$WORK/LZ4"
cmake --build "$WORK/_build" --parallel
sudo cmake --install "$WORK/_build"
echo "build-h5lz4: installed plugin to $PREFIX"
ls -l "$PREFIX/lib/libh5lz4"* 2>/dev/null || ls -l "$PREFIX/HDF_Group"/*/lz4/ 2>/dev/null
```

- [ ] **Step 2: chmod +x the script.**

```bash
wsl -d Ubuntu -- bash -c 'chmod +x ~/TTI-O.worktrees/hdf5-bundled/scripts/build-h5lz4.sh'
```

- [ ] **Step 3: Local smoke-test on Linux.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && ./scripts/build-h5lz4.sh master 2>&1 | tail -20 && ls -la /usr/local/lib/libh5lz4*'
```

Expected: `libh5lz4.so` (some version) created. If sudo is unavailable in the runner env, adjust the script to install to `${PREFIX}` without sudo and have the CI step sudo cp afterwards.

- [ ] **Step 4: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add scripts/build-h5lz4.sh && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "build(scripts): build-h5lz4.sh for the HDF5 LZ4 filter plugin"'
```

### Task C.2: Verify scripts/install-hdf5.sh works on macOS arm64

**Files:**
- Modify (if needed): `scripts/install-hdf5.sh`

- [ ] **Step 1: Read the existing script.** Check whether `./configure` invocation uses GNU make-isms that don't work on BSD make (macOS).

```bash
wsl -d Ubuntu -- bash -c 'head -50 ~/TTI-O.worktrees/hdf5-bundled/scripts/install-hdf5.sh'
```

- [ ] **Step 2: If the script uses Linux-only paths or commands**, add a portable replacement (e.g. `sed -i ''` for macOS BSD sed, conditional `nproc` vs `sysctl -n hw.ncpu`). If everything is portable, skip to step 3.

- [ ] **Step 3: No commit needed if the script was already portable** (the macOS CI job will exercise it in Phase D).

### Task C.3: Document Windows MSYS2 HDF5 install in scripts/build-native-windows.md

**Files:**
- Create: `scripts/build-native-windows.md`

- [ ] **Step 1: Create a short README** describing the `pacman` packages and LZ4 plugin build command for Windows MSYS2 UCRT64. Used by the release-shaded-jar workflow's Windows job.

```markdown
# Building HDF5 + LZ4 plugin on Windows (MSYS2 UCRT64)

Required pacman packages:

```
mingw-w64-ucrt-x86_64-hdf5
mingw-w64-ucrt-x86_64-hdf5-tools
mingw-w64-ucrt-x86_64-cmake
mingw-w64-ucrt-x86_64-ninja
```

Install with:

```
pacman -Sy --needed --noconfirm \
    mingw-w64-ucrt-x86_64-hdf5 \
    mingw-w64-ucrt-x86_64-hdf5-tools \
    mingw-w64-ucrt-x86_64-cmake \
    mingw-w64-ucrt-x86_64-ninja
```

After install, HDF5 lives at `/ucrt64/lib/`:
- `libhdf5.dll` → strip to `hdf5.dll` for staging
- `libhdf5_hl.dll` → `hdf5_hl.dll`
- The JNI shim (`hdf5_java.dll`) is NOT in the MSYS2 package; build it from source against the installed HDF5 using HDFGroup's `tools-make` tarball.

Then build the LZ4 plugin via `scripts/build-h5lz4.sh master` with `PREFIX=/ucrt64`.

The release-shaded-jar workflow's Windows job follows this recipe.
```

- [ ] **Step 2: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add scripts/build-native-windows.md && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "docs(scripts): MSYS2 HDF5 + LZ4 plugin recipe for Windows"'
```

---

## Phase D — CI workflow restructure

### Task D.1: Restructure release-shaded-jar.yml — drop assembly job, fold shading into matrix

**Files:**
- Modify: `.github/workflows/release-shaded-jar.yml`

This is the biggest single edit in the plan. Read the full current file first, then apply the changes below.

- [ ] **Step 1: Read the current workflow** end-to-end so you can preserve the bits that still apply (cache config, native-build steps, jpackage profile usage) while restructuring the job topology.

```bash
wsl -d Ubuntu -- bash -c 'wc -l ~/TTI-O.worktrees/hdf5-bundled/.github/workflows/release-shaded-jar.yml && head -5 ~/TTI-O.worktrees/hdf5-bundled/.github/workflows/release-shaded-jar.yml'
```

- [ ] **Step 2: Restructure into a single matrix job** that builds natives + builds the shaded JAR + uploads, per platform. Roughly:

```yaml
name: Release shaded jar (per-platform)

on:
  push:
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: write   # for softprops/action-gh-release

jobs:
  build-platform-jar:
    name: ${{ matrix.classifier }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - classifier: linux-x64
            os: ubuntu-22.04
          - classifier: mac-aarch64
            os: macos-14
          - classifier: win-x64
            os: windows-2022
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Set up JDK 21
        uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '21' }

      - name: Build libttio_rans_jni (existing platform-specific recipe)
        # COPY the existing per-platform native build steps from the
        # current build-native job here, gated by ${{ matrix.classifier }}.
        # ...

      - name: Build HDF5 1.14 + LZ4 plugin
        # See per-platform sub-tasks D.2-D.4

      - name: Stage natives into tio-browser/src/main/resources/native/
        run: |
          mkdir -p tio-browser/src/main/resources/native/${{ matrix.classifier }}/hdf5
          # COPY libttio_rans_jni + HDF5 + LZ4 plugin into the staging dir
          # (per-platform paths in D.2-D.4)

      - name: Build shaded JAR
        working-directory: tio-browser
        run: mvn -B -P ${{ matrix.classifier }} -DskipTests package

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: tio-browser-${{ matrix.classifier }}
          path: tio-browser/target/tio-browser-*-${{ matrix.classifier }}.jar
          if-no-files-found: error

  publish-release:
    needs: build-platform-jar
    runs-on: ubuntu-latest
    if: startsWith(github.ref, 'refs/tags/v')
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
      - name: Publish GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: artifacts/**/tio-browser-*.jar
```

- [ ] **Step 3: Validate with `actionlint`** if available, or by pushing to a scratch branch and viewing the run. Don't run the full workflow yet — D.2/D.3/D.4 will fill in the per-platform native build steps.

- [ ] **Step 4: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add .github/workflows/release-shaded-jar.yml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "ci(release): restructure release-shaded-jar.yml to per-platform matrix"'
```

### Task D.2: Linux x64 — wire HDF5 + LZ4 plugin build + staging

**Files:**
- Modify: `.github/workflows/release-shaded-jar.yml` (the `linux-x64` matrix entry)

- [ ] **Step 1: Add the HDF5 + LZ4 build step to the matrix entry.** Inside the `if: matrix.classifier == 'linux-x64'` step group:

```yaml
      - name: Build HDF5 1.14 + LZ4 plugin (linux-x64)
        if: matrix.classifier == 'linux-x64'
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
              cmake ninja-build clang
          bash scripts/install-hdf5.sh 1.14.6
          sudo bash scripts/build-h5lz4.sh master
          sudo ldconfig
```

- [ ] **Step 2: Add the staging step:**

```yaml
      - name: Stage HDF5 + LZ4 natives into resources (linux-x64)
        if: matrix.classifier == 'linux-x64'
        run: |
          mkdir -p tio-browser/src/main/resources/native/linux-x64/hdf5
          cp /usr/local/lib/libhdf5.so.310 tio-browser/src/main/resources/native/linux-x64/hdf5/
          cp /usr/local/lib/libhdf5_hl.so.310 tio-browser/src/main/resources/native/linux-x64/hdf5/
          cp /usr/local/lib/libhdf5_java.so tio-browser/src/main/resources/native/linux-x64/hdf5/
          cp /usr/local/lib/libh5lz4.so tio-browser/src/main/resources/native/linux-x64/hdf5/
          ls -la tio-browser/src/main/resources/native/linux-x64/hdf5/
          # libttio_rans_jni from the existing build step
          cp native/_build/libttio_rans_jni.so tio-browser/src/main/resources/native/linux-x64/
```

(Adjust the `libttio_rans_jni.so` source path to match the existing build step's output location; check by reading the current workflow.)

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add .github/workflows/release-shaded-jar.yml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "ci(release): linux-x64 HDF5 + LZ4 native build + staging"'
```

### Task D.3: macOS arm64 — wire HDF5 + LZ4 plugin build + staging

**Files:**
- Modify: `.github/workflows/release-shaded-jar.yml` (the `mac-aarch64` matrix entry)

- [ ] **Step 1: Add HDF5 + LZ4 build step:**

```yaml
      - name: Install build deps + Build HDF5 1.14 + LZ4 (mac-aarch64)
        if: matrix.classifier == 'mac-aarch64'
        run: |
          brew install cmake ninja
          bash scripts/install-hdf5.sh 1.14.6
          sudo bash scripts/build-h5lz4.sh master
```

- [ ] **Step 2: Add staging step:**

```yaml
      - name: Stage HDF5 + LZ4 natives (mac-aarch64)
        if: matrix.classifier == 'mac-aarch64'
        run: |
          mkdir -p tio-browser/src/main/resources/native/mac-aarch64/hdf5
          cp /usr/local/lib/libhdf5.310.dylib tio-browser/src/main/resources/native/mac-aarch64/hdf5/
          cp /usr/local/lib/libhdf5_hl.310.dylib tio-browser/src/main/resources/native/mac-aarch64/hdf5/
          cp /usr/local/lib/libhdf5_java.dylib tio-browser/src/main/resources/native/mac-aarch64/hdf5/
          cp /usr/local/lib/libh5lz4.dylib tio-browser/src/main/resources/native/mac-aarch64/hdf5/
          # libttio_rans_jni
          cp native/_build/libttio_rans_jni.dylib tio-browser/src/main/resources/native/mac-aarch64/
```

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add .github/workflows/release-shaded-jar.yml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "ci(release): mac-aarch64 HDF5 + LZ4 native build + staging"'
```

### Task D.4: Windows x64 — wire HDF5 + LZ4 plugin build + staging

**Files:**
- Modify: `.github/workflows/release-shaded-jar.yml` (the `win-x64` matrix entry)

- [ ] **Step 1: Add MSYS2 + HDF5 + LZ4 build steps:**

```yaml
      - name: Set up MSYS2 (win-x64)
        if: matrix.classifier == 'win-x64'
        uses: msys2/setup-msys2@v2
        with:
          msystem: UCRT64
          install: >-
            mingw-w64-ucrt-x86_64-hdf5
            mingw-w64-ucrt-x86_64-hdf5-tools
            mingw-w64-ucrt-x86_64-cmake
            mingw-w64-ucrt-x86_64-ninja
            mingw-w64-ucrt-x86_64-clang

      - name: Build LZ4 plugin (win-x64)
        if: matrix.classifier == 'win-x64'
        shell: msys2 {0}
        run: |
          PREFIX=/ucrt64 bash scripts/build-h5lz4.sh master
```

- [ ] **Step 2: Add staging step:**

```yaml
      - name: Stage HDF5 + LZ4 natives (win-x64)
        if: matrix.classifier == 'win-x64'
        shell: msys2 {0}
        run: |
          mkdir -p tio-browser/src/main/resources/native/win-x64/hdf5
          cp /ucrt64/bin/libhdf5*.dll tio-browser/src/main/resources/native/win-x64/hdf5/
          # Strip libhdf5.dll → hdf5.dll for jpackage convention
          mv tio-browser/src/main/resources/native/win-x64/hdf5/libhdf5.dll \
             tio-browser/src/main/resources/native/win-x64/hdf5/hdf5.dll
          mv tio-browser/src/main/resources/native/win-x64/hdf5/libhdf5_hl.dll \
             tio-browser/src/main/resources/native/win-x64/hdf5/hdf5_hl.dll
          mv tio-browser/src/main/resources/native/win-x64/hdf5/libhdf5_java.dll \
             tio-browser/src/main/resources/native/win-x64/hdf5/hdf5_java.dll
          cp /ucrt64/bin/libh5lz4.dll tio-browser/src/main/resources/native/win-x64/hdf5/h5lz4.dll
          # libttio_rans_jni
          cp native/_build/ttio_rans_jni.dll tio-browser/src/main/resources/native/win-x64/
```

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add .github/workflows/release-shaded-jar.yml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "ci(release): win-x64 HDF5 + LZ4 native build + staging"'
```

---

## Phase E — Integration tests + LZ4 fixture

### Task E.1: Generate the LZ4 test fixture

**Files:**
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5Lz4FixtureGenerator.java` (one-off generator)
- Create: `tio-browser/src/test/resources/ttio/lz4_compressed.tio`

- [ ] **Step 1: Write a small `main()` that creates a minimal `.tio` with one LZ4-compressed dataset:**

```java
package global.thalion.ttio.browser;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

/** One-off generator for src/test/resources/ttio/lz4_compressed.tio.
 *  Run via `mvn exec:java -Dexec.mainClass=...` after Phase D is wired
 *  (so the LZ4 plugin is loadable). Re-run only when the fixture
 *  schema changes. */
public final class Hdf5Lz4FixtureGenerator {

    public static void main(String[] args) throws Exception {
        Hdf5NativeLoader.ensureLoaded();
        String out = "tio-browser/src/test/resources/ttio/lz4_compressed.tio";
        try (Hdf5File f = Hdf5File.create(out);
             Hdf5Group root = f.rootGroup();
             Hdf5Group g = root.createGroup("study")) {
            byte[] payload = new byte[4096];
            for (int i = 0; i < payload.length; i++) payload[i] = (byte)(i & 0xff);
            g.createByteDataset("lz4_payload", payload, Compression.LZ4, 5);
        }
        System.out.println("Wrote " + out);
    }
}
```

(API names like `createByteDataset` may differ — check `Hdf5Group.java` and use the right method for byte-array writes with compression.)

- [ ] **Step 2: Run the generator (after Phase D bundles natives).**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -DskipTests test-compile && mvn -P linux-x64 exec:java -Dexec.mainClass=global.thalion.ttio.browser.Hdf5Lz4FixtureGenerator -Dexec.classpathScope=test 2>&1 | tail -3'
```

Expected: prints `Wrote tio-browser/src/test/resources/ttio/lz4_compressed.tio`. Verify the fixture is non-empty and reads back correctly.

- [ ] **Step 3: Commit the fixture (binary) + the generator.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5Lz4FixtureGenerator.java tio-browser/src/test/resources/ttio/lz4_compressed.tio && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "test(tio-browser): LZ4-compressed fixture + generator"'
```

### Task E.2: Add Hdf5Lz4PluginTest

**Files:**
- Create: `tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5Lz4PluginTest.java`

- [ ] **Step 1: Create the test that opens the fixture and verifies LZ4 read works:**

```java
package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;

import java.nio.file.Path;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

/** Confirms the bundled LZ4 plugin (filter id 32004) can decode a
 *  dataset written with Compression.LZ4. Skips when natives aren't
 *  bundled in this build. */
class Hdf5Lz4PluginTest {

    @Test
    void readsLz4CompressedDataset() throws Exception {
        Assumptions.assumeTrue(
            Hdf5NativeLoader.class.getResourceAsStream(
                "/native/linux-x64/hdf5/libh5lz4.so") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/mac-aarch64/hdf5/libh5lz4.dylib") != null
            || Hdf5NativeLoader.class.getResourceAsStream(
                "/native/win-x64/hdf5/h5lz4.dll") != null,
            "no platform's HDF5 + LZ4 natives bundled in this build");
        Hdf5NativeLoader.ensureLoaded();
        Path fixture = Path.of("src/test/resources/ttio/lz4_compressed.tio");
        try (Hdf5File f = Hdf5File.openReadOnly(fixture.toString());
             Hdf5Group root = f.rootGroup();
             Hdf5Group study = root.openGroup("study")) {
            byte[] read = study.readByteDataset("lz4_payload");
            byte[] expected = new byte[4096];
            for (int i = 0; i < expected.length; i++) expected[i] = (byte)(i & 0xff);
            assertArrayEquals(expected, read);
        }
    }
}
```

(Adjust API method names to match the actual `Hdf5File`/`Hdf5Group` surface.)

- [ ] **Step 2: Run the test (will skip until natives are bundled in CI).**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -Dtest=Hdf5Lz4PluginTest test 2>&1 | tail -8'
```

Expected: SKIPPED locally; PASSES in CI after Phase D.

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/src/test/java/global/thalion/ttio/browser/Hdf5Lz4PluginTest.java && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "test(tio-browser): Hdf5Lz4PluginTest — round-trip via bundled LZ4 plugin"'
```

---

## Phase F — Docs + version bump

### Task F.1: Bump tio-browser version 1.3.0 → 1.4.0 + update jpackage args

**Files:**
- Modify: `tio-browser/pom.xml`

- [ ] **Step 1: Bump version + jpackage references:**

| Line | Before | After |
|---|---|---|
| `tio-browser/pom.xml:10` | `<version>1.3.0</version>` | `<version>1.4.0</version>` |
| jpackage `--main-jar` arg | `tio-browser-1.3.0-shaded.jar` | `tio-browser-1.4.0-${platform.classifier}.jar` |
| jpackage `--app-version` arg | `1.3.0` | `1.4.0` |

The jpackage invocation now needs to know the platform classifier — same `${platform.classifier}` variable from Phase A. Move the jpackage profile config inside each platform profile if it isn't already, OR have the `native-package` profile reference `${platform.classifier}` (works only when both profiles are co-activated).

Cleanest: rewrite the `native-package` profile to require co-activation with a platform profile:

```xml
<profile>
    <id>native-package</id>
    <build>
        <plugins>
            <plugin>
                <groupId>org.codehaus.mojo</groupId>
                <artifactId>exec-maven-plugin</artifactId>
                <configuration>
                    <arguments>
                        <argument>--input</argument>
                        <argument>target/installer-staging</argument>
                        <argument>--main-jar</argument>
                        <argument>tio-browser-${project.version}-${platform.classifier}.jar</argument>
                        ...
                        <argument>--app-version</argument>
                        <argument>${project.version}</argument>
                        ...
                    </arguments>
                </configuration>
            </plugin>
        </plugins>
    </build>
</profile>
```

- [ ] **Step 2: Verify pom is well-formed:**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && mvn -P linux-x64 -o validate 2>&1 | tail -3'
```

Expected: BUILD SUCCESS.

- [ ] **Step 3: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/pom.xml && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "release: tio-browser 1.3.0 -> 1.4.0 + platform-classifier jpackage args"'
```

### Task F.2: Update tio-browser/README.md + docs/tio-browser.md for per-platform downloads

**Files:**
- Modify: `tio-browser/README.md`
- Modify: `docs/tio-browser.md`

- [ ] **Step 1: README — replace the "Quick install" section** to show the 3 download options:

```markdown
## Quick install (end users)

Download the JAR for your operating system from the [latest GitHub Release](https://github.com/DTW-Thalion/TTI-O/releases/latest):

| OS | Download |
|---|---|
| Linux x86_64 | `tio-browser-1.4.0-linux-x64.jar` |
| macOS Apple Silicon (arm64) | `tio-browser-1.4.0-mac-aarch64.jar` |
| Windows x86_64 | `tio-browser-1.4.0-win-x64.jar` |

Run with a JDK 17+:

```bash
java -jar tio-browser-1.4.0-<your-os>.jar
java -jar tio-browser-1.4.0-<your-os>.jar --open path/to/dataset.tio
```

Each per-platform JAR bundles HDF5 1.14, the LZ4 filter plugin, and `libttio_rans_jni` for that platform — **no other prerequisites beyond a JDK 17+**.

If you download the wrong JAR for your OS, the app shows a modal error pointing you to the correct asset.
```

- [ ] **Step 2: Replace the "Native installers" section** (already mentions `--P native-package`) to note the per-platform nature:

```markdown
## Native installers (optional)

For users who prefer a platform-native installer instead of the JAR:

| OS | Asset |
|---|---|
| Linux | `tio-browser_1.4.0_amd64.deb` |
| macOS | `tio-browser-1.4.0-mac-aarch64.dmg` (arm64) |
| Windows | `tio-browser-1.4.0-win-x64.msi` |

Each installer bundles the platform's HDF5 + JRE — completely self-contained.

To build locally:

```bash
mvn -pl tio-browser package -P <your-platform> -P native-package
```

Where `<your-platform>` is one of `linux-x64`, `mac-aarch64`, `win-x64`.
```

- [ ] **Step 3: docs/tio-browser.md** — update the CLI invocation example to use the new naming.

```bash
wsl -d Ubuntu -- bash -c "sed -i 's/tio-browser-1\\.3\\.0-shaded\\.jar/tio-browser-1.4.0-<your-os>.jar/g' ~/TTI-O.worktrees/hdf5-bundled/docs/tio-browser.md"
```

- [ ] **Step 4: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add tio-browser/README.md docs/tio-browser.md && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "docs(tio-browser): per-platform download instructions for v1.4.0"'
```

### Task F.3: Add CHANGELOG [1.4.0] entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Open `CHANGELOG.md`** and add a new section under `[Unreleased]`:

```markdown
## [Unreleased]

## [1.4.0] - YYYY-MM-DD

### Changed

- **`tio-browser` distribution model: per-platform JARs.** Replaces the
  prior "one universal shaded JAR for all 3 platforms" with three
  platform-specific JARs (`tio-browser-1.4.0-linux-x64.jar`,
  `tio-browser-1.4.0-mac-aarch64.jar`, `tio-browser-1.4.0-win-x64.jar`).
  Each JAR is ~31 MB instead of the universal-with-HDF5 alternative
  (~64 MB), carries only its own platform's natives, and **bundles
  HDF5 1.14 + the LZ4 filter plugin** so `java -jar tio-browser-1.4.0-<your-os>.jar`
  on a fresh machine works out of the box with only a JDK 17+ — no
  system HDF5 install required.
- New `Hdf5NativeLoader` extracts the bundled HDF5 native libs to a
  per-JVM temp dir at `App.start()`, calls `System.load` in dependency
  order (hdf5 → hdf5_hl → hdf5_java), and registers the LZ4 plugin
  search path via `H5.H5PLappend`. Idempotent; throws
  `Hdf5NativeLoadException` on hard failures (modal Alert + exit).
- Wrong-JAR-for-OS detection: running `tio-browser-1.4.0-linux-x64.jar`
  on a Mac shows a clear modal Alert with the correct download name.
- `release-shaded-jar.yml` workflow restructured: each platform's
  build job now produces its own complete shaded JAR end-to-end (no
  separate assembly job).
```

(Use today's date for `YYYY-MM-DD` at commit time.)

- [ ] **Step 2: Commit.**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled && git add CHANGELOG.md && git -c user.name=DTW-Thalion -c user.email=todd.white@thalion.global commit -m "docs: CHANGELOG [1.4.0] entry — per-platform JARs with bundled HDF5"'
```

---

## Phase G — Local verification + PR

### Task G.1: Local verification — Linux end-to-end

**Files:** none (verification only).

- [ ] **Step 1: Clean build the Linux JAR locally with everything wired:**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && rm -rf target src/main/resources/native/linux-x64/hdf5 && mkdir -p src/main/resources/native/linux-x64/hdf5 && cp /usr/local/lib/libhdf5.so.310 /usr/local/lib/libhdf5_hl.so.310 /usr/local/lib/libhdf5_java.so /usr/local/lib/libh5lz4.so src/main/resources/native/linux-x64/hdf5/ && cp /home/toddw/TTI-O/native/_build/libttio_rans_jni.so src/main/resources/native/linux-x64/ && mvn -B -P linux-x64 verify 2>&1 | tail -10'
```

Expected: BUILD SUCCESS, all tests pass (including the LZ4 fixture round-trip and the integration test that verifies HDF5 1.14).

- [ ] **Step 2: Verify JAR contents:**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && jar -tf target/tio-browser-1.4.0-linux-x64.jar | grep -E "^(native|hdf/hdf5lib)" | head -15 && echo "---" && ls -la target/tio-browser-1.4.0-linux-x64.jar'
```

Expected:
- All 4 HDF5 libs under `native/linux-x64/hdf5/`.
- `libttio_rans_jni.so` under `native/linux-x64/`.
- No `native/mac-aarch64/...` or `native/win-x64/...`.
- JHI5 classes (`hdf/hdf5lib/H5.class`, etc.) present.
- JAR size ≈ 31 MB.

- [ ] **Step 3: Smoke-test fresh-JVM startup of the JAR (using monocle classpath since this is headless):**

```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O.worktrees/hdf5-bundled/tio-browser && timeout 5 java -Dprism.order=sw -Dglass.platform=Monocle -Dmonocle.platform=Headless -cp target/tio-browser-1.4.0-linux-x64.jar:/home/toddw/.m2/repository/org/testfx/openjfx-monocle/17.0.10/openjfx-monocle-17.0.10.jar global.thalion.ttio.browser.AppLauncher 2>&1 | head -30'
```

Expected: no UnsatisfiedLinkError, no `Hdf5NativeLoadException`. App may keep running until SIGTERM. The key thing is no startup error.

### Task G.2: Push branch + open PR

- [ ] **Step 1: Push the branch:**

```bash
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O.worktrees/hdf5-bundled" -c safe.directory="*" push -u origin feat-hdf5-bundled-natives
```

- [ ] **Step 2: Open PR with body** referencing the spec + summarizing each phase. PR body template (write to `$env:TEMP\pr-hdf5-bundled-body.md` and use `gh pr create --body-file`):

```markdown
## Summary

Implements `docs/superpowers/specs/2026-05-09-hdf5-bundled-natives-design.md`. Replaces tio-browser's universal shaded JAR with three per-platform JARs (`linux-x64`, `mac-aarch64`, `win-x64`), each bundling HDF5 1.14 + the LZ4 filter plugin so `java -jar tio-browser-1.4.0-<platform>.jar` works on a fresh machine with only a JDK 17+.

## What's in this PR

- **Phase A**: Maven plumbing — three platform profiles in `tio-browser/pom.xml`, JavaFX classifier deps moved into per-profile blocks, jarhdf5 switched from system-scope to a real Maven dep, per-profile shade `<filter>` blocks excluding other-platform native resources, `<finalName>` set to `tio-browser-${project.version}-${platform.classifier}`.
- **Phase B**: `Hdf5NativeLoader` (TDD) — platform detection, temp-dir extraction, `System.load` in dependency order, LZ4 plugin path via `H5.H5PLappend`, wired as the first line of `App.start()`.
- **Phase C**: `scripts/build-h5lz4.sh` for the LZ4 plugin; portable HDF5 build verified for macOS; Windows MSYS2 recipe documented.
- **Phase D**: `release-shaded-jar.yml` restructured to per-platform matrix; each job builds HDF5 + LZ4 + libttio_rans + shaded JAR end-to-end and uploads its artifact. Final `publish-release` job aggregates and publishes the GitHub Release.
- **Phase E**: LZ4 round-trip test fixture + `Hdf5Lz4PluginTest`.
- **Phase F**: tio-browser version bump 1.3.0 → 1.4.0; per-platform README + user guide; CHANGELOG `[1.4.0]` entry.

## Test plan

- [ ] CI per-platform matrix all green
- [ ] CI uploads 3 distinct JAR assets named `tio-browser-1.4.0-linux-x64.jar` etc.
- [ ] Local: `mvn -P linux-x64 verify` passes; JAR is ~31 MB; contains only `native/linux-x64/`
- [ ] Smoke-test: `java -jar tio-browser-1.4.0-linux-x64.jar --open <fixture>` works on a fresh Ubuntu container with only OpenJDK 17 installed
```

- [ ] **Step 3: Run the gh pr create command.**

```bash
gh pr create --repo DTW-Thalion/TTI-O --base main --head feat-hdf5-bundled-natives \
    --title "feat(tio-browser): per-platform JARs with bundled HDF5 (v1.4.0)" \
    --body-file /tmp/pr-hdf5-bundled-body.md
```

- [ ] **Step 4: Watch CI.** Verify that all 3 per-platform matrix jobs go green and the publish-release job creates the GitHub Release with 3 distinct JAR assets. If something fails, debug per-platform — the matrix's `fail-fast: false` should let other platforms continue running so you can diagnose all failures in one cycle.

---

## Plan self-review

**Spec coverage check:**
- ✓ Bundle target table (HDF5 + LZ4 per platform) — Tasks D.2-D.4 stage them
- ✓ `Hdf5NativeLoader` — Tasks B.1-B.7
- ✓ Native resource layout (per-JAR single-platform tree) — enforced by Task A.3 shade filters
- ✓ `release-shaded-jar.yml` matrix updates — Phase D
- ✓ jarhdf5 dependency change — Task A.4
- ✓ Loader flow (detect → temp dir → extract → System.load → H5PLappend) — B.2-B.5
- ✓ Failure handling (wrong JAR, unsupported platform, temp-dir fail, missing resource, UnsatisfiedLinkError, LZ4 missing) — B.4 + B.5 + B.6
- ✓ Testing (unit, integration, LZ4 round-trip) — Phase B + Phase E
- ✓ Distribution / jpackage — F.1
- ✓ Migration (no library changes) — implicit; no Phase touches `java/`
- ✓ Versioning bump — F.1, F.3

**Placeholder scan:**
- "TBD" in spec at the JHI5 dep strategy is acknowledged and Task A.1 is the discovery step. No "TODO" / "FIXME" / "implement later" elsewhere.

**Type / signature consistency:**
- `Hdf5NativeLoader.detectPlatform(String, String)` — used consistently across B.1 (test), B.2 (impl), B.3 (test).
- `Hdf5NativeLoader.ensureLoaded()` — same signature in B.3 (test), B.4 (impl), B.6 (caller).
- `${platform.classifier}` Maven property — defined in A.2 and consumed in A.3 + F.1.
- LZ4 plugin lib filenames per platform — same set in spec table, B.4 (`LINUX_LIBS`/`MAC_LIBS`/`WIN_LIBS`), and D.2-D.4 (staging).
- `Hdf5NativeLoadException` — defined in B.4, caught in B.6.

No issues to fix.
