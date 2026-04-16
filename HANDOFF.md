# MPEG-O v0.5 — Java Feature Parity

> **Status:** v0.5.0 is **complete**. All three implementations at
> full feature parity: ObjC (836 assertions), Python (120 tests),
> Java (62 tests on JDK 17). Milestones 31-36 delivered the Java
> stream. Three-way cross-implementation conformance verified.

## Critical Update: hdf-java Maven Artifacts Now Available

The v0.4 session deferred Java because `libhdf5_java` required building
from HDF Group source. **HDF5 2.0.0 (Nov 2025) now publishes official
Maven artifacts** with platform-specific JNI JARs:

```xml
<dependency>
    <groupId>org.hdfgroup</groupId>
    <artifactId>hdf5-java-jni</artifactId>
    <version>2.0.0</version>
    <classifier>linux-x86_64</classifier>
</dependency>
```

Available on GitHub Packages (requires a GitHub PAT with `read:packages`).
This eliminates the build-from-source blocker entirely. The `pom.xml`
must include the HDF Group GitHub Packages repository, and CI must
configure Maven `settings.xml` with the token.

**Note:** GitHub Packages auth is required even for public packages.
CI uses `${{ secrets.GITHUB_TOKEN }}` which has `read:packages` by default.

---

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `README.md`, `ARCHITECTURE.md`, `WORKPLAN.md`, `docs/format-spec.md`, `docs/feature-flags.md`
3. Verify existing: `cd objc && ./build.sh check` and `cd ../python && pip install -e ".[test,import,crypto]" && pytest`
4. Tag v0.4.0 if not already tagged.

## Binding Decisions — All Prior Decisions Active, Plus:

23. **Java: Maven** with `org.hdfgroup:hdf5-java-jni:2.0.0` from GitHub Packages. JDK 17+.
24. **HDF5 API style:** Static methods on `hdf.hdf5lib.H5` + `hdf.hdf5lib.HDF5Constants`. Wrap into OO classes (`Hdf5File`, `Hdf5Group`, `Hdf5Dataset`) matching the ObjC/Python pattern.
25. **Java crypto:** `javax.crypto` for AES-256-GCM (`Cipher.getInstance("AES/GCM/NoPadding")`) and `javax.crypto.Mac` for HMAC-SHA256. No external crypto dependency.
26. **Java XML:** `javax.xml.parsers.SAXParser` for mzML/nmrML import. `javax.xml.stream.XMLStreamWriter` for mzML/nmrML export.
27. **Java value types:** Java records (JDK 16+) for CVParam, AxisDescriptor, EncodingSpec, ValueRange, InstrumentConfig.
28. **Cross-compat is the gate:** Every milestone's acceptance criteria include three-way fixture verification. A milestone is not complete until Java reads ObjC/Python fixtures AND ObjC/Python read Java-written fixtures.

---

## Dependency Graph

```
  M31 (CI + scaffold + HDF5 wrappers)
       |
       v
  M32 (Core: primitives + runs + dataset)
       |
       v
  M33 (Import/export: mzML, nmrML, ISA, Thermo stub)
       |
       v
  M34 (Protection: encrypt, sign, key rotation, anonymize)
       |
       v
  M35 (Advanced: thread safety, chromatograms, codecs)
       |
       v
  M36 (Three-way conformance + v0.5.0)
```

Strictly sequential — each builds on the previous. No parallelism needed; this is a single-language catch-up.

---

## Milestone 31 — Java CI + Maven Scaffold + HDF5 Wrappers

**License:** LGPL-3.0

### Deliverables

**Maven project scaffold:**

```
java/
+-- pom.xml
+-- src/main/java/com/dtwthalion/mpgo/
|   +-- hdf5/
|   |   +-- Hdf5File.java
|   |   +-- Hdf5Group.java
|   |   +-- Hdf5Dataset.java
|   |   +-- Hdf5CompoundType.java
|   |   +-- Hdf5Errors.java
|   +-- Enums.java
+-- src/test/java/com/dtwthalion/mpgo/
|   +-- Hdf5FileTest.java
|   +-- Hdf5DatasetTest.java
+-- src/test/resources/
    +-- (symlink or copy of objc/Tests/Fixtures/mpgo/)
```

**pom.xml:**

```xml
<project>
    <groupId>com.dtwthalion</groupId>
    <artifactId>mpgo</artifactId>
    <version>0.5.0-SNAPSHOT</version>
    <packaging>jar</packaging>

    <properties>
        <maven.compiler.source>17</maven.compiler.source>
        <maven.compiler.target>17</maven.compiler.target>
        <hdf5.version>2.0.0</hdf5.version>
    </properties>

    <repositories>
        <repository>
            <id>hdfgroup-github</id>
            <url>https://maven.pkg.github.com/HDFGroup/hdf5</url>
        </repository>
    </repositories>

    <dependencies>
        <dependency>
            <groupId>org.hdfgroup</groupId>
            <artifactId>hdf5-java-jni</artifactId>
            <version>${hdf5.version}</version>
            <classifier>linux-x86_64</classifier>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <version>5.11.0</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <version>3.2.5</version>
                <configuration>
                    <argLine>-Djava.library.path=/usr/lib/x86_64-linux-gnu/hdf5/serial</argLine>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

**HDF5 wrapper layer:**

Mirror the ObjC/Python pattern:

- `Hdf5File`: wraps `H5.H5Fcreate`/`H5Fopen`/`H5Fclose`. Implements `AutoCloseable`. Owns a `ReentrantReadWriteLock` for thread safety.
- `Hdf5Group`: wraps `H5Gcreate2`/`H5Gopen2`/`H5Gclose`. String/integer attribute read/write. `hasChild()` check.
- `Hdf5Dataset`: wraps `H5Dcreate2`/`H5Dwrite`/`H5Dread`/`H5Dclose`. Support float32/64, int32/64, uint32, complex128 (compound). Chunked + zlib compression. Partial reads via hyperslab.
- `Hdf5CompoundType`: wraps `H5Tcreate(H5T_COMPOUND)` with VL string fields.
- `Enums.java`: `Precision`, `Compression`, `Polarity`, `SamplingMode`, `AcquisitionMode`, `ChromatogramType`, `ByteOrder`, `EncryptionLevel` — all Java enums.

**CI job:**

```yaml
  java-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - name: Install native HDF5
        run: sudo apt-get install -y libhdf5-dev
      - name: Configure Maven for GitHub Packages
        run: |
          mkdir -p ~/.m2
          cat > ~/.m2/settings.xml << 'EOF'
          <settings>
            <servers>
              <server>
                <id>hdfgroup-github</id>
                <username>${env.GITHUB_ACTOR}</username>
                <password>${env.GITHUB_TOKEN}</password>
              </server>
            </servers>
          </settings>
          EOF
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and test
        working-directory: java
        run: mvn verify
        env:
          GITHUB_ACTOR: ${{ github.actor }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Acceptance criteria

- [ ] `mvn compile` succeeds with hdf5-java-jni resolved from GitHub Packages
- [ ] `Hdf5File` create/open/close; file exists on disk
- [ ] `Hdf5Dataset` write float64 + read back; values match within epsilon
- [ ] Chunked + zlib compressed int32 dataset round-trip
- [ ] Complex128 compound type round-trip
- [ ] Partial read (hyperslab) verified
- [ ] String and integer attributes on groups
- [ ] CI java-test job green

---

## Milestone 32 — Java Core: Primitives + Runs + Dataset

**License:** LGPL-3.0

### Deliverables

All six primitives + container classes:

**Value classes (Java records):**
- `CVParam(String ontologyRef, String accession, String name, String value, String unit)`
- `AxisDescriptor(String name, String unit, ValueRange range, SamplingMode mode)`
- `EncodingSpec(Precision precision, Compression compression, ByteOrder byteOrder)`
- `ValueRange(double minimum, double maximum)`
- `InstrumentConfig(String manufacturer, String model, String serialNumber, String sourceType, String analyzerType, String detectorType)`

**Core classes:**
- `SignalArray` — typed buffer (`double[]`, `float[]`, `int[]`) with encoding + axis + CV annotations
- `Spectrum` — named SignalArray dictionary + coordinate axes + scan time
- `MassSpectrum` extends Spectrum — m/z + intensity + msLevel + polarity
- `NMRSpectrum` extends Spectrum — chemical shift + intensity + nucleus + frequency
- `NMR2DSpectrum` — 2D intensity matrix with F1/F2 descriptors; native rank-2 HDF5 dataset
- `FreeInductionDecay` — complex128 real+imaginary + dwell time
- `Chromatogram` — time + intensity + type enum
- `AcquisitionRun` — ordered spectra + chromatograms + instrument config + spectrum index + provenance. Lazy loading. Implements `AutoCloseable`.
- `SpectrumIndex` — offsets/lengths/headers for O(1) access
- `SpectralDataset` — root `.mpgo` reader/writer. `open(path)` returns `AutoCloseable` handle. Lazy loading. Reads v0.1, v0.2, v0.3, v0.4 files via feature flag dispatch.
- `MSImage` extends SpectralDataset — spatial grid with tile access
- `Identification`, `Quantification`, `ProvenanceRecord`, `TransitionList`
- `FeatureFlags` — reader/writer matching ObjC/Python exactly

**HDF5 I/O:**
- Signal channel separation on write (same layout as ObjC/Python)
- Compound datasets for identifications/quantifications/provenance
- Feature flags: `@mpeg_o_format_version` + `@mpeg_o_features`
- v0.1 JSON fallback paths for legacy files
- Compound per-run provenance (v0.3+) with `@provenance_json` fallback (v0.2)

### Acceptance criteria

- [ ] Read every ObjC/Python reference fixture — spectrum counts, array values, identifications, quantifications, provenance, feature flags all match
- [ ] Write a multi-run dataset (MS + NMR) -> read back -> round-trip verified
- [ ] Java-written fixtures readable by ObjC `mpgo-verify` tool and Python reader
- [ ] MSImage tile access works
- [ ] v0.1, v0.2, v0.3 backward compat verified
- [ ] Chromatograms on runs round-trip (v0.4 feature)

---

## Milestone 33 — Java Import/Export

**License:** Apache-2.0

### Deliverables

All in `com.dtwthalion.mpgo.importers` and `com.dtwthalion.mpgo.exporters`:

**mzML reader (`MzMLReader.java`):**
- SAX parser via `javax.xml.parsers.SAXParser`
- Base64 decode via `java.util.Base64` + `java.util.zip.Inflater` for zlib
- `CVTermMapper.java` with hardcoded PSI-MS + nmrCV accessions
- `referenceableParamGroup` expansion
- `defaultArrayLength` validation

**mzML writer (`MzMLWriter.java`):**
- XMLStreamWriter output
- Reverse CVTermMapper
- Base64 + optional zlib for binary arrays
- `indexedmzML` with byte-offset index
- `<chromatogramList>` emission

**nmrML reader (`NmrMLReader.java`):**
- SAX parser for nmrML
- Complex128 FID decoding (interleaved real+imaginary)

**nmrML writer (`NmrMLWriter.java`):**
- XMLStreamWriter for `<acquisition1D>`, `<fidData>`, `<spectrum1D>`

**ISA exporter (`ISAExporter.java`):**
- ISA-Tab TSV output
- ISA-JSON output
- Same mapping rules as ObjC/Python

**Thermo RAW stub (`ThermoRawReader.java`):**
- Throws `UnsupportedOperationException` with SDK guidance

### Acceptance criteria

- [ ] mzML round-trip: mzML -> .mpgo -> mzML -> compare spectra
- [ ] mzML chromatograms included in output
- [ ] nmrML round-trip: nmrML -> .mpgo -> nmrML -> verify FID
- [ ] ISA-Tab output matches ObjC/Python structurally
- [ ] ISA-JSON output matches ObjC/Python structurally
- [ ] Parse HUPO-PSI `tiny.pwiz.1.1.mzML` fixture; verify spectrum count
- [ ] Parse BMRB `bmse000325.nmrML` fixture; verify FID
- [ ] Thermo stub throws with guidance message
- [ ] indexedmzML offsets byte-correct

---

## Milestone 34 — Java Protection Layer

**License:** LGPL-3.0

### Deliverables

**Encryption (`EncryptionManager.java`):**
- AES-256-GCM via `javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")`
- Selective per-channel encryption (intensity encrypted, m/z clear)
- Compound dataset sealing
- `@encrypted` marker + `@access_policy_json`

**Signatures (`SignatureManager.java`):**
- HMAC-SHA256 via `javax.crypto.Mac.getInstance("HmacSHA256")`
- v2 canonical byte-order signatures (little-endian normalization)
- `"v2:" + base64(mac)` format
- v1 native-byte fallback for pre-v0.3 files
- Provenance chain signing

**Key rotation (`KeyRotationManager.java`):**
- Envelope encryption (DEK + KEK)
- `enableEnvelopeEncryption()`, `rotateKey()`, `unwrapDEK()`
- `/protection/key_info` with `dek_wrapped`, `@kek_id`, `key_history`
- Migration from v0.3 direct encryption

**Anonymization (`Anonymizer.java`):**
- SAAV spectrum redaction
- Intensity quantile masking
- m/z coarsening, chemical shift coarsening
- Rare metabolite masking (bundled prevalence table)
- Metadata stripping
- Signed anonymization provenance
- `opt_anonymized` feature flag

### Acceptance criteria

- [ ] Encrypt in Java -> decrypt in Java -> data correct
- [ ] Encrypt in Java -> decrypt in Python/ObjC -> data correct (cross-language)
- [ ] ObjC/Python encrypted fixtures -> decrypt in Java -> correct
- [ ] Sign in Java -> verify in all three languages
- [ ] Canonical v2 signatures match across all three languages for same data
- [ ] Key rotation: KEK-1 -> KEK-2 -> read with KEK-2; cross-language parity
- [ ] Anonymize in Java: SAAV redaction, intensity masking, coarsening verified
- [ ] Anonymized files readable by ObjC and Python

---

## Milestone 35 — Java Advanced Features

**License:** LGPL-3.0

### Deliverables

**Thread safety:**
- `Hdf5File` owns `ReentrantReadWriteLock`
- All group/dataset operations acquire read or write lock
- `isThreadSafe()` method (probe `H5.H5is_library_threadsafe()`)
- Degraded exclusive-only mode when HDF5 is not threadsafe

**LZ4 compression:**
- HDF5 filter 32004; check availability at runtime via `H5.H5Zfilter_avail()`
- Skip LZ4 tests gracefully if filter not loadable
- LZ4-compressed files from ObjC/Python readable

**Numpress-delta:**
- Clean-room implementation from Teleman et al. 2014
- `NumpressCodec.java` with `linearEncode()` / `linearDecode()`
- Sub-ppm relative error verified
- Numpress files from ObjC/Python readable; Java-written files readable by both

**Cloud access (optional):**
- If time permits: investigate HDF5 2.0's improved ROS3 VFD (S3 native reads) which is now in the official release
- Otherwise: document as v0.6 scope with a note that Python's fsspec path is the recommended cloud access method

### Acceptance criteria

- [ ] Two Java threads reading concurrently — no crashes
- [ ] Writer blocks readers
- [ ] LZ4 round-trip (if filter available)
- [ ] ObjC/Python LZ4 files readable by Java
- [ ] Numpress round-trip within < 1 ppm
- [ ] Cross-language Numpress parity
- [ ] Thread safety model documented

---

## Milestone 36 — Three-Way Conformance + v0.5.0 Release

**Track:** Cross-cutting

### Three-way cross-compat CI job

```yaml
  cross-compat-3way:
    needs: [objc-build-test, python-test, java-test]
    runs-on: ubuntu-latest
    steps:
      # 1. Build ObjC, generate fixtures
      # 2. Install Python, read ObjC fixtures
      # 3. Build Java, read ObjC fixtures
      # 4. Write fixtures from Python, read in ObjC + Java
      # 5. Write fixtures from Java, read in ObjC + Python
      # 6. Verify: all values match across all three
```

### Documentation

- `ARCHITECTURE.md`: Java class mapping table, HDF5 2.0 Maven setup
- `README.md`: Java build instructions, three-language badges, all three streams at v0.5.0
- `WORKPLAN.md`: M31-M36 with checked criteria
- `docs/format-spec.md`: no layout changes (Java is a reader/writer, not a format change)

### Package publishing

- `mpeg-o` updated on TestPyPI
- Java artifact to GitHub Packages (`com.dtwthalion:mpgo:0.5.0`)

### Release

```bash
git tag -a v0.5.0 -m "MPEG-O v0.5.0: Java implementation at full feature parity with ObjC and Python. Three-way cross-implementation conformance."
git push origin v0.5.0
```

### Acceptance criteria

- [ ] ObjC: all tests pass (unchanged from v0.4)
- [ ] Python: all tests pass on 3.11 and 3.12 (unchanged from v0.4)
- [ ] Java: all tests pass on JDK 17
- [ ] Three-way cross-compat: every fixture readable by all three
- [ ] v0.1/v0.2/v0.3/v0.4 backward compat preserved in Java
- [ ] Java artifact on GitHub Packages
- [ ] CI: ObjC + Python + Java + 3-way cross-compat, all green
- [ ] Tag `v0.5.0` pushed

---

## Known Gotchas

**Inherited (1-19):** All prior gotchas remain active. Key ones for Java:

9. **Fixed test IVs for cross-language crypto.** Java, ObjC, Python must all use the same test key and IV. `javax.crypto` AESGCM and OpenSSL produce identical output for same inputs.
16. **Key rotation backward compat.** Detect envelope vs direct encryption by presence of `dek_wrapped`.
18. **Anonymization prevalence table.** Bundle `data/metabolite_prevalence.json` in the Java jar's resources.

**New (v0.5):**

20. **GitHub Packages auth for hdf5-java-jni.** CI uses `${{ secrets.GITHUB_TOKEN }}` which has `read:packages` by default. Local dev needs a PAT with `read:packages` in `~/.m2/settings.xml`. Document this in `java/README.md`.

21. **HDF5 2.0 API changes.** HDF5 2.0 renamed some constants and deprecated `H5Dcreate1` in favor of `H5Dcreate`. Use `HDF5Constants.H5P_DEFAULT` consistently. The `H5.H5Dcreate()` wrapper in 2.0 uses the v2 signature by default.

22. **Java native library path.** `hdf5-java-jni` bundles the JNI `.so` inside the JAR, but `libhdf5.so` must be on the system. CI: `apt-get install libhdf5-dev`. Surefire plugin: `-Djava.library.path=/usr/lib/x86_64-linux-gnu/hdf5/serial`. The exact path varies by Ubuntu version.

23. **VL strings in Java.** HDF5-Java represents VL strings as `String[]` arrays. Reading a VL string dataset returns `String[]`; writing requires `H5.H5Dwrite_VLStrings()`. Compound types with VL string fields use the `H5.H5Tset_size(HDF5Constants.H5T_VARIABLE)` pattern.

24. **Java complex128.** HDF5 compound type `{double re; double im;}`. In Java, represent as `double[]` pairs or a `record Complex128(double re, double im)`. Read/write via compound type wrappers.

25. **Java Base64 + zlib.** `java.util.Base64.getDecoder().decode()` + `java.util.zip.Inflater` for mzML binary arrays. Unlike Python's `zlib.decompress()`, Java's `Inflater` requires explicit output buffer sizing — use a growing `ByteArrayOutputStream`.

---

## Execution Checklist

1. ~~Tag v0.4.0 if needed.~~ Done.
2. **M31:** Java CI + scaffold + HDF5 wrappers. Done (17 tests).
3. **M32:** Java core primitives + runs + dataset. Done (26 tests).
4. **M33:** Java import/export. Done (36 tests).
5. **M34:** Java protection layer. Done (50 tests).
6. **M35:** Java advanced features. Done (62 tests).
7. **M36:** Three-way conformance + v0.5.0 release. Done.

**CI must be green before any milestone is complete.**

---

## Deferred to v0.6+

| Item | Description |
|---|---|
| Java cloud access | HDF5 2.0 ROS3 VFD for native S3 reads |
| Streaming transport | MPEG-G Part 2 real-time acquisition |
| Zarr backend | Alternative to HDF5 |
| DuckDB query layer | SQL interface via extension |
| Bruker TDF import | Real implementation |
| Waters MassLynx import | Stub + implementation |
| Raman/IR support | Extend Spectrum hierarchy |
| PyPI stable release | Graduate from TestPyPI |
| Maven Central | Publish Java artifact publicly |
| v1.0 API freeze | Stable release |
