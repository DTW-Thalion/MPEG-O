# HANDOFF — M80 + M81 complete; on-disk repo dir + GitHub URL still pending

**Status (2026-04-25):** M80 (TTI-O rebrand) and M81 (Java
reverse-DNS correction) shipped. Source-tree rebrand is complete in
all three languages. Generated docs (Javadoc / autogsdoc / Sphinx)
regenerated. Test suites at full pre-rebrand baseline parity.

**This file replaces the M80 plan handoff** (which was self-corrupted
by the very rebrand it described). Refer to git history for the
historical M80 plan if needed.

---

## 1. What's done

### M80 — TTI-O rebrand (5 commits)

| Commit    | Phase                                                |
|-----------|------------------------------------------------------|
| `82c7ae4` | Phase 1 — Python (`mpeg_o` → `ttio`)                 |
| `df9702f` | Phase 2 — ObjC (`MPGO`/`Mpgo` → `TTIO`/`Ttio`)       |
| `dfdddde` | Phase 3 — Java (package + artifactId)                |
| `87068e4` | Phase 4 — Docs + repo                                |
| `f3267ab` | Phase 4 fixup — sed-order bug across 378 files       |

### M81 — Java reverse-DNS correction (2 commits)

| Commit    | Change                                                 |
|-----------|--------------------------------------------------------|
| `9c2ad31` | `com.dtwthalion.ttio` → `global.thalion.ttio`,         |
|           | pom.xml groupId, 158 .java moves, doc regen           |
| `1100cd4` | Cleanup: stale `mpeg-o` PyPI refs (Java exporter       |
|           | parity bug + 16 docs/CI files), 2 stale slash-form     |
|           | path checks in Python tests, run-tool.sh +x restored   |

### Renames applied

| Old | New | Where |
|---|---|---|
| `MPEG-O` | `TTI-O` | Human-readable product name |
| `mpeg_o` | `ttio` | Python package |
| `mpgo` | `ttio` | Lowercase token, CLI prefix, HDF5 attr prefix |
| `MPGO` / `Mpgo` | `TTIO` / `Ttio` | ObjC prefix |
| `com.dtwthalion.mpgo.*` | `global.thalion.ttio.*` | Java package (M80 → M81) |
| `.mpgo` | `.tio` | Container file extension |
| `.mots` | `.tis` | Transport stream extension |
| `"MO"` | `"TI"` | Transport magic bytes |
| `mpgo_format_version`, `mpgo_features`, … | `ttio_*` | HDF5 root attributes |
| `<groupId>com.dtwthalion</groupId>` | `<groupId>global.thalion</groupId>` | Maven |

### Preserved (intentionally not renamed)

- `MPEG-G` (ISO/IEC 23092 — external standard).
- `MPEG-2`, `MPEG-4`, `MPEG LA` (external references).
- `DTW-Thalion` (organisation name).
- `MPAD` (internal per-AU debug-dump magic).
- 3 migration-narrative docs that describe the rename itself
  (`docs/api-review-v0.6.md`, `docs/superpowers/specs/2026-04-16-m41-api-review-design.md`,
  `docs/superpowers/plans/2026-04-17-m41.9-docs-assembly.md`).
- Historical `docs/superpowers/plans/` and `docs/superpowers/specs/`
  documents that describe paths-as-they-were-at-plan-time. Slash-form
  `com/dtwthalion/ttio` references remain in those — historical
  artifacts, not live state.

### Verification

- Python: pytest 854 passing, 2 pre-existing M16 baseline failures
  in `test_smoke.py` (hardcoded version-string asserts — predate
  M80, out of M80/M81 scope).
- Java: `mvn test` 389/389 under `global.thalion.ttio`.
- ObjC: `gmake check` 1817 PASS, 1 env-dep skip
  (`TestTransportClient.m:172` Python server unreachable — baseline).
- Cross-language: full `[py/objc/java]³` matrix (61 cells) + 4-provider
  matrix passing.

---

## 2. What's still pending

### 2.1 On-disk repo dir + GitHub URL

The local working copy is still at `~/MPEG-O` and the GitHub
remote is still `DTW-Thalion/MPEG-O`. Renaming these requires:

1. Close all editors / IDE workspaces / Sphinx servers / `mvn`
   / `gmake` background processes pointed at the old path.
2. Rename on GitHub (`DTW-Thalion/MPEG-O` → `DTW-Thalion/TTI-O`),
   accept the auto-redirect.
3. Local rename: `mv ~/MPEG-O ~/TTI-O`.
4. Update `~/.bashrc`, `~/.bash_profile`, any tooling configs,
   shell aliases, IDE workspace files, CI runner paths that bake
   the old path.
5. Update remote URL: `git remote set-url origin git@github.com:DTW-Thalion/TTI-O.git`.
6. Update CI workflows that hardcode the old path.

Defer until the user has a quiet window for the local rename.

### 2.2 M40 publishing (still blocked)

M40 (PyPI + Maven Central publish) was blocked 2026-04-24 on
account email verification. M81 corrected the groupId to
`global.thalion` BEFORE publishing, so when the block clears the
correct groupId will be claimed on first upload. See
`project_mpeg_o_m40_publishing.md` memory.

### 2.3 Pre-existing baseline failures (not introduced by rebrand)

Two `tests/test_smoke.py` failures in Python — version-string asserts
hardcoded to old values:

- `test_version_string` — asserts `"0.4."` substring; actual `"1.1.1"`
- `test_format_version` — asserts `"1.1"`; actual `"1.3"`

These came from M16 (commit `214cccec`) and survived through every
release. Out of M80/M81 scope but worth fixing in a small follow-up.

---

## 3. Operational notes for the next session

### 3.1 Cross-language test cache

Cross-language tests cache a compiled `M73Driver.class` in
`/tmp/ttio_m73_driver/`. The driver `.java` is only written when
absent, so a stale cache from a prior package's run will keep
breaking compile after any future Java package change. Clear with:

```sh
rm -rf /tmp/ttio_m73_driver/
```

### 3.2 Multi-rule sed gotcha

The M80 Phase 4 sed had `s/\.mpgo\b/.tio/g` running before the
package-qualifier rule, which ate one `t` from
`com.dtwthalion.mpgo` and produced `com.dtwthalion.tio`. Lessons in
`feedback_sed_order_extension_vs_qualifier.md` (saved to memory).
For any future bulk rename mixing file extensions and dot-bounded
package qualifiers: order most-specific (longest) match first, OR
anchor extension rules with `\b` on both ends, AND grep for the
partially-broken intermediate after the pass.

### 3.3 Build environment

- WSL Ubuntu (`wsl -d Ubuntu`) for all builds; clean POSIX
  environment. Windows MSYS2 / Git Bash mangles `/tmp/` and
  `wsl -- bash -c '/tmp/foo.sh'` — pass the script via stdin or
  cat its contents inline if that bites.
- Push from Windows git (HTTPS auth works there; WSL hangs):
  `'/c/Program Files/Git/bin/git.exe' -C //wsl.localhost/Ubuntu/home/toddw/MPEG-O push`.
  First use needs a `safe.directory` exception for the UNC path.
- HDF5 needs `-Djava.library.path=/usr/lib/x86_64-linux-gnu/jni:/usr/lib/x86_64-linux-gnu/hdf5/serial`
  for Maven (already wired in `pom.xml` Surefire config).
- ObjC build:
  `cd objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && LD_LIBRARY_PATH=Source/obj:/usr/local/lib:/home/toddw/_oqs/lib gmake -s check`.

---

## 4. Where to look next

- `WORKPLAN.md` — milestone roster, M80 + M81 sections appended at
  the bottom.
- `CHANGELOG.md` — `[Unreleased]` covers M80 + M81; pre-rebrand
  M79 moved under `[pre-rebrand]`.
- `docs/version-history.md` — release-by-release narrative.
- Genomic milestone series M74–M82 — M79 shipped (groundwork);
  M74 (`GenomicRun` + write-side path, rANS/base-pack/quality
  encoders) is the next functional milestone.
