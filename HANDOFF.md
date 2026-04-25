# HANDOFF — M80: TTIO Rebrand (Clean Sweep)

**Scope:** Rename every reference to TTI-O / TTIO / ttio across the
entire repository to TTI-O / TTIO / ttio. No backward compatibility.
No dual-read support for old attribute names. This is a clean break —
every file in the repo is touched.

**No functional changes.** The test suite must produce identical
results (same assertion counts, same pass/fail) after the rename.
The only differences are names, paths, and magic bytes.

**Branch from:** `main` after M79.

---

## 1. Naming Convention Map

| Old | New | Context |
|---|---|---|
| `TTI-O` | `TTI-O` | Human-readable product name in prose |
| `mpeg-o` | `ttio` | Python package name (PyPI), CLI, lowercase references |
| `ttio` | `ttio` | Python module name (underscored), on-disk HDF5 attribute prefix |
| `TTIO` | `TTIO` | ObjC class/protocol/constant/enum prefix |
| `Ttio` | `Ttio` | ObjC mixed-case (e.g., `TtioVerify` → `TtioVerify`, `TtioDumpIdentifications` → `TtioDumpIdentifications`) |
| `ttio` | `ttio` | Java package segment, lowercase file references, CLI tool names |
| `com.dtwthalion.tio` | `com.dtwthalion.ttio` | Java package |
| `.tio` | `.tio` | File container extension |
| `.tis` | `.tis` | Transport stream extension |
| `"MO"` | `"TI"` | 2-byte transport header magic |
| `ttio_format_version` | `ttio_format_version` | HDF5 root attribute |
| `ttio_features` | `ttio_features` | HDF5 root attribute |
| `ttio_version` | `ttio_version` | Legacy v0.1 HDF5 root attribute |
| `MPEG-G` | `MPEG-G` | **NO CHANGE** — external standard references stay as-is |
| `DTW-Thalion` | `DTW-Thalion` | **NO CHANGE** — org name stays |

---

## 2. Execution Order

Strict order matters — do these in sequence, verifying each step
compiles/passes before moving on.

### Phase 1: Python package rename

This is the most invasive phase because directory names change.

**2.1 Directory rename:**
```bash
mv python/src/ttio python/src/ttio
```

**2.2 pyproject.toml:**
- `name = "mpeg-o"` → `name = "ttio"`
- `[project.entry-points."ttio.providers"]` → `[project.entry-points."ttio.providers"]`
- All entry point module paths: `ttio.providers.hdf5:Hdf5Provider` → `ttio.providers.hdf5:Hdf5Provider`
- Any `[tool.pytest]` paths referencing `ttio`

**2.3 Global find-replace in `python/src/ttio/`:**
```
ttio  →  ttio          (import paths, module references)
TTI-O  →  TTI-O         (docstrings, comments)
mpeg-o  →  ttio          (package name references, pip install)
.tio   →  .tio          (file extension references)
.tis   →  .tis          (transport extension references)
```

**Critical files requiring manual attention:**

- `ttio/_hdf5_io.py`:
  - `FEATURES_ATTR = "ttio_features"` → `"ttio_features"`
  - `VERSION_ATTR = "ttio_format_version"` → `"ttio_format_version"`
  - `LEGACY_VERSION_ATTR = "ttio_version"` → `"ttio_version"`

- `ttio/transport/packets.py`:
  - `HEADER_MAGIC = b"MO"` → `b"TI"`

- `ttio/transport/__init__.py`:
  - Module docstring: `TTI-O` → `TTI-O`

- `ttio/spectral_dataset.py` (or wherever `.tio` extension is
  checked/written): every `.tio` → `.tio`

**2.4 Test directory:**
```bash
# If tests import ttio:
find python/tests/ -name '*.py' -exec sed -i 's/ttio/ttio/g' {} +
find python/tests/ -name '*.py' -exec sed -i 's/TTI-O/TTI-O/g' {} +
find python/tests/ -name '*.py' -exec sed -i 's/\.tio/\.tio/g' {} +
find python/tests/ -name '*.py' -exec sed -i 's/\.tis/\.tis/g' {} +
```

**2.5 Fixtures:**
Rename any `.tio` fixture files to `.tio` and any `.tis` to `.tis`
in `python/tests/fixtures/`. Update all fixture path references in
test files.

**2.6 Verify:**
```bash
cd python && pip install -e ".[dev]" --break-system-packages && pytest
```
All tests must pass with the same count as before the rename.

---

### Phase 2: Objective-C prefix rename

**2.7 File renames:** Every `.h` and `.m` file under `objc/Source/`
and `objc/Tests/` that has `TTIO` in its filename:

```bash
# Generate the rename commands:
find objc/ -name 'TTIO*' -o -name 'Ttio*' | while read f; do
  newf=$(echo "$f" | sed 's/TTIO/TTIO/g; s/Ttio/Ttio/g')
  echo "mv '$f' '$newf'"
done
```

Execute all renames. This covers classes like:
- `TTIOHDF5File.h` → `TTIOHDF5File.h`
- `TTIOSpectralDataset.h` → `TTIOSpectralDataset.h`
- `TTIOAccessUnit.h` → `TTIOAccessUnit.h`
- `TTIOStorageProtocols.h` → `TTIOStorageProtocols.h`
- `TTIOTransportPacket.h` → `TTIOTransportPacket.h`
- `TTIOFeatureFlags.h` → `TTIOFeatureFlags.h`
- `TTIOEnums.h` → `TTIOEnums.h`
- Tools: `TtioVerify` → `TtioVerify`, `TtioDumpIdentifications` → `TtioDumpIdentifications`, `TtioPerAU` → `TtioPerAU`
- etc.

**2.8 Content replace in all `.h`, `.m`, `.strings` files:**
```bash
find objc/ -name '*.h' -o -name '*.m' | xargs sed -i \
  -e 's/TTIO/TTIO/g' \
  -e 's/Ttio/Ttio/g' \
  -e 's/ttio/ttio/g' \
  -e 's/TTI-O/TTI-O/g' \
  -e 's/ttio/ttio/g' \
  -e 's/\.tio/\.tio/g' \
  -e 's/\.tis/\.tis/g'
```

**Critical manual checks after sed:**

- `TTIOEnums.h`: verify enum names look right (e.g.,
  `TTIOPrecisionFloat32`, `TTIOCompressionZlib`, etc.)

- `TTIOTransportPacket.h` / `.m`:
  - `TTIOTransportHeaderMagic` → `TTIOTransportHeaderMagic`
  - Magic value: `{'M', 'O'}` → `{'T', 'I'}`

- `TTIOFeatureFlags.h` / `.m`:
  - `@"ttio_format_version"` → `@"ttio_format_version"`
  - `@"ttio_features"` → `@"ttio_features"`
  - `@"ttio_version"` → `@"ttio_version"`

- GNUmakefile(s): update library name, any `TTIO` references in
  build targets, installed header paths.

- `objc/Tests/Fixtures/ttio/` → `objc/Tests/Fixtures/ttio/`
  (directory rename + fixture file renames `.tio` → `.tio`)

**2.9 Verify:**
```bash
cd objc && make CC=clang OBJC=clang && make CC=clang OBJC=clang check
```
Same assertion count as before.

---

### Phase 3: Java package rename

**2.10 Directory rename:**
```bash
mv java/src/main/java/com/dtwthalion/ttio \
   java/src/main/java/com/dtwthalion/ttio
mv java/src/test/java/com/dtwthalion/ttio \
   java/src/test/java/com/dtwthalion/ttio
```

**2.11 pom.xml:**
- `<groupId>global.thalion</groupId>` stays
- `<artifactId>mpeg-o</artifactId>` → `<artifactId>ttio</artifactId>`
- Any `ttio` or `ttio` references in plugin configs

**2.12 ServiceLoader file:**
```bash
mv java/src/main/resources/META-INF/services/com.dtwthalion.tio.providers.StorageProvider \
   java/src/main/resources/META-INF/services/com.dtwthalion.ttio.providers.StorageProvider
```
Update the contents of that file to reference `com.dtwthalion.ttio.providers.*`.

**2.13 Content replace in all `.java` files:**
```bash
find java/ -name '*.java' | xargs sed -i \
  -e 's/com\.dtwthalion\.tio/com.dtwthalion.ttio/g' \
  -e 's/TTIO/TTIO/g' \
  -e 's/TTI-O/TTI-O/g' \
  -e 's/ttio/ttio/g' \
  -e 's/\.tio/\.tio/g' \
  -e 's/\.tis/\.tis/g'
```

**Critical manual checks:**

- `PacketHeader.java`:
  - `MAGIC = {(byte) 'M', (byte) 'O'}` → `{(byte) 'T', (byte) 'I'}`

- Feature flag constants: any `"ttio_"` → `"ttio_"`

- Test fixtures: rename `.tio` → `.tio` files, update paths.

**2.14 Verify:**
```bash
cd java && mvn clean test
```
Same test count as before.

---

### Phase 4: Documentation + Repository

**2.15 All markdown files:**
```bash
find . -name '*.md' | xargs sed -i \
  -e 's/TTI-O/TTI-O/g' \
  -e 's/mpeg-o/ttio/g' \
  -e 's/ttio/ttio/g' \
  -e 's/TTIO/TTIO/g' \
  -e 's/Ttio/Ttio/g' \
  -e 's/ttio/ttio/g' \
  -e 's/\.tio/\.tio/g' \
  -e 's/\.tis/\.tis/g'
```

**Manual review required on:**

- `README.md`: verify badges, repo URLs, all prose reads naturally.
  The repo URL `github.com/DTW-Thalion/TTI-O` → update to new repo
  name if renaming on GitHub, otherwise note the discrepancy.
- `ARCHITECTURE.md`: class hierarchy tables, protocol names.
- `HANDOFF.md`: all milestone references.
- `WORKPLAN.md` / `WORKPLAN-GENOMICS.md`: milestone descriptions.
- `CHANGELOG.md`: historical entries — rename class references but
  keep the milestone context legible.
- `docs/format-spec.md`: on-disk attribute names, file extension.
- `docs/transport-spec.md`: magic bytes, `.tis` → `.tis`, wire
  format description.
- `docs/feature-flags.md`: attribute names.
- `docs/transport-encryption-design.md`: any `TTIO` / `ttio` refs.
- `docs/providers.md`, `docs/pqc.md`, `docs/migration-guide.md`,
  `docs/api-stability-v0.8.md`, `docs/api-review-v0.7.md`.
- `LICENSE`: no change needed (LGPL text doesn't reference the
  project name).

**2.16 Protect MPEG-G references:**
After the global sed, verify that references to the *external*
standard `MPEG-G` (ISO/IEC 23092) have NOT been accidentally
renamed. Search for `MPEG-G` — if any hits, revert those to `MPEG-G`.
```bash
grep -rn "MPEG-G" . | grep -v ".git"
# Should return zero results. Fix any hits.
```

Also verify `MPEG-2`, `MPEG-4`, `MPEG LA` references are untouched.

**2.17 CI config:**
- `.github/workflows/ci.yml`: update any `mpeg-o` / `ttio` / `.tio`
  references in paths, artifact names, job names.

**2.18 Tools:**
- `tools/perf/` scripts: any `ttio` / `ttio` references.
- Python CLI entry points: `python -m ttio.tools.*` → `python -m ttio.tools.*`
- ObjC tool binaries: `TtioVerify` → `TtioVerify` etc. (covered in
  Phase 2 file renames, but verify GNUmakefile targets match).
- Java CLI tools: `TtioDumpIdentifications` → `TtioDumpIdentifications`
  etc.

---

## 3. Cross-Language Integration Tests

After all four phases, run the cross-language conformance tests:

```bash
cd python && pytest tests/integration/ -v
```

These tests spawn ObjC and Java subprocesses. The subprocess binary
names and Python import paths have changed, so the integration test
harness needs updating:

- Subprocess commands referencing `TtioVerify` → `TtioVerify`
- Subprocess commands referencing `TtioDumpIdentifications` → `TtioDumpIdentifications`
- Subprocess commands referencing `TtioPerAU` → `TtioPerAU`
- Any `ttio` import in the harness → `ttio`

All cross-language cells must pass. Same counts as before.

---

## 4. Fixture Regeneration

**Do NOT reuse old fixtures.** Regenerate all reference fixtures
using the renamed code. Old `.tio` fixtures contain `ttio_*`
HDF5 attributes that the renamed code will not recognise (no
backward compat).

```bash
# Python fixtures:
cd python && python -m ttio.tools.make_fixtures

# ObjC fixtures:
cd objc && ./TtioMakeFixtures   # (was TtioMakeFixtures)
```

Commit the new `.tio` fixtures, delete the old `.tio` ones.

---

## 5. Final Verification Checklist

- [ ] `grep -rn "TTIO\|ttio\|ttio\|\.tio\|\.tis" --include='*.py' --include='*.java' --include='*.h' --include='*.m' --include='*.md' . | grep -v .git | grep -v MPEG-G`
      returns **zero results** (excluding MPEG-G external references).
- [ ] `grep -rn "MPEG-G" . | grep -v .git` returns **zero results**.
- [ ] Python: `pytest` — same test count, all pass.
- [ ] ObjC: `make check` — same assertion count, all pass.
- [ ] Java: `mvn test` — same test count, all pass.
- [ ] Cross-language integration: all cells pass.
- [ ] `.tio` fixture files present; no `.tio` files remain.
- [ ] `.tis` transport fixtures present; no `.tis` files remain.
- [ ] Transport magic bytes are `b"TI"` in all three languages.
- [ ] On-disk attributes are `ttio_format_version` and `ttio_features`.
- [ ] No `MPEG-2`, `MPEG-4`, `MPEG-G`, `MPEG LA` references
      accidentally renamed.
- [ ] CI green.

---

## 6. Gotchas

64. **Sed over-matching.** The pattern `ttio` can appear inside
    longer identifiers. The sed commands above use simple replacement
    which should be safe because `ttio` is always a standalone
    token (module name, attribute prefix). But spot-check for
    accidental damage in strings like `ttio_features` →
    `ttio_features` (correct) vs hypothetical `non_ttioptional` →
    `non_ttiotional` (broken). The latter pattern doesn't exist in
    the codebase, but verify.

65. **GNUmakefile library name.** The ObjC build produces
    `libTTIO.so` (or `.dylib`). This must become `libTTIO.so`.
    Check the GNUmakefile for the `LIBRARY_NAME` variable and any
    `-l` linker flags in test targets.

66. **Java module-info.** If `module-info.java` exists, its
    `module` declaration and `exports`/`requires` statements need
    updating.

67. **Python `__init__.py` re-exports.** The top-level
    `ttio/__init__.py` may re-export submodules. Verify all
    `from ttio.xxx import yyy` → `from ttio.xxx import yyy`.

68. **H5 attribute name in fixture files.** Since we regenerate all
    fixtures, old attributes like `ttio_format_version` will NOT
    be present. But if any test explicitly writes the old attribute
    name as a backward-compat test, that test should be deleted
    (no backward compat).

69. **ObjC `#ifndef` guards.** Header guards like
    `#ifndef TTIO_STORAGE_PROTOCOLS_H` must become
    `#ifndef TTIO_STORAGE_PROTOCOLS_H`. The sed handles this, but
    verify no mismatched `#ifndef`/`#define` pairs after rename.

70. **Transport spec `"MPAD"` debug format.** The per-AU CLI's
    `decrypt` subcommand emits a canonical `"MPAD"` binary dump
    header. Check whether this magic string should also change
    (it's an internal debug format, not a public wire format — leave
    as-is unless you want to rename it to `"TIAD"` or similar).

---

## Binding Decisions

| # | Decision | Rationale |
|---|---|---|
| 67 | No backward compatibility with `.tio` / `ttio_*` attributes. Clean break. | No external users yet. Carrying dual-read logic adds complexity with zero benefit. |
| 68 | Transport magic changes from `"MO"` to `"TI"`. | Two-byte mnemonic for "Thalion Initiative". Clean, memorable, no known collision. |
| 69 | `"MPAD"` debug dump magic is NOT renamed. | Internal diagnostic format, not part of the public wire spec. Renaming adds churn with no value. |
