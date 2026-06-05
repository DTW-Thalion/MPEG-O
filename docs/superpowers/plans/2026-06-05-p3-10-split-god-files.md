# P3.10 — Split the god-files (3 SDKs) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Decompose four monolithic source files by moving cohesive code groups into separate files/units, keeping every public class API byte-identical (pure code movement, no wire/protocol/behavior change).

**Architecture:** Four independent PRs (Python dataset → Python transport → Java → ObjC), each its own branch off main, CI-green, merged before the next. The "test" for a code-move is that the **unmodified existing suite still passes** (characterization), plus cross-language conformance on CI. No new behavior, so no TDD-RED — instead: capture a green baseline, move code verbatim, re-run to green.

**Tech Stack:** Python 3.12 / pytest; Java 22 / Maven / JUnit (jacoco ≥0.84 gate); ObjC / GNUstep / ctest. Spec: `docs/superpowers/specs/2026-06-05-p3-10-split-god-files-design.md`.

**Environment / commands:**
- Python tests: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args> -q`
- Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -Dtest=<Class> test` (fast) and `JAVA_HOME=~/jdk25 mvn -o verify -B` (full + jacoco ≥0.84 gate).
- ObjC: `cd ~/TTI-O/objc && ./build.sh check` (builds libTTIO + runs the test runner). If `build.sh` needs args, study it first.
- Commit: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit`.
- Push from Windows git: `"/c/Program Files/Git/bin/git.exe" -C //wsl.localhost/Ubuntu/home/toddw/TTI-O push -u origin <branch>`.
- Branch `p3-10-split-god-files` is created (carries the spec + plan + PR-1). PRs 2-4 branch fresh off main after each merge. **Always `git fetch` before `reset --hard origin/main`.**

**Hard invariants (every PR):**
- No `.tio`/wire/transport/public-API/behavior change. `ttio/__init__.py` re-exports + ObjC `.h` + Java public API unchanged.
- Cross-language conformance + each SDK's full suite stay green. Local cross-language tests fail on the known JDK 21-vs-22 `UnsupportedClassVersionError` env issue — CI is the gate for those; confirm no PURE-language regressions.
- Code moves VERBATIM. Do not "improve" logic while moving. If a moved function needs an import the new module lacks, add the import; do not change the function body.

---

## Baseline note (all PRs)
Each moved chunk is verbatim. The fence is: the SAME test set that passes before the move passes after. So Step 1 of every task is "run the target suite, record the green baseline," and the final step is "re-run, identical pass set."

---

### Task 1 (PR-1): Python `spectral_dataset.py` → extract two write submodules

**Files:**
- Create: `python/src/ttio/_dataset_write_genomic.py`
- Create: `python/src/ttio/_dataset_write_metadata.py`
- Modify: `python/src/ttio/spectral_dataset.py`

- [ ] **Step 1: Baseline.** Run the dataset + genomic + transport suites and record the green set:
  `...pytest tests/test_spectral_dataset.py tests/test_m82_genomic_run.py tests/test_m86_genomic_codec_wiring.py tests/test_per_run_provenance.py tests/test_references_accessor.py tests/test_write_minimal_progress.py -q` → all pass. Note the count.
- [ ] **Step 2: Study** `spectral_dataset.py` lines 1115–2718. Confirm the exact function set per the spec's PR-1 list and note, for each, its module-level dependencies (imports it uses: `numpy as np`, `_hdf5_io as io`, `enums`, the record classes, `WrittenGenomicRun`, `WrittenRun`, constants like `DEFAULT_SIGNAL_CHUNK`). Confirm NONE of the to-be-moved functions are referenced outside `spectral_dataset.py`: `grep -rn "<fname>" python/src python/tests` for a few representative privates (`_write_genomic_run`, `_write_identifications`, `_read_subjects`). If any external caller exists, plan a re-export in `spectral_dataset.py`.
- [ ] **Step 3: Create `_dataset_write_genomic.py`** — move VERBATIM the genomic-write functions (spec PR-1 list: `_any_v1_5_codec`, `_reference_md5_for_run`, `_load_references_provider`, `_embed_references_for_runs`, `_is_valid_compression`, `_write_sequences_ref_diff_v2`, `_write_qualities_fqzcomp_nx16_z`, `_write_genomic_run`, `_build_chrom_id_table`, `_resolve_mate_chrom_ids`, `_write_bulk_v2_blob`, `_write_mate_info_bulk_verbatim`, `_write_sequences_ref_diff_bulk_verbatim`, `_write_read_names_bulk_verbatim`, `_write_mate_info_inline_v2`). Add the module docstring + the imports they need at the top (`from __future__ import annotations`, numpy, `from . import _hdf5_io as io`, enums, `from .written_genomic_run import WrittenGenomicRun`, etc. — derive from Step 2). Do NOT import `spectral_dataset`.
- [ ] **Step 4: Create `_dataset_write_metadata.py`** — move VERBATIM the metadata + subjects/samples functions (spec PR-1 list: `_write_identifications`, `_write_quantifications`, `_write_provenance`, `_maybe_json_list`, `_maybe_json_dict`, `_decode_identifications_json`, `_decode_quantifications_json`, `_decode_provenance_json`, `_validate_subjects_and_samples`, `_write_subjects_h5`, `_write_samples_h5`, `_write_subjects_provider`, `_write_samples_provider`, `_parse_attributes_json`, `_read_subjects`, `_read_samples`, `_read_string_attr_or_default`, `_read_long_attr_or_default`) with their needed imports (`Subject`, `Sample`, `Identification`, `Quantification`, `ProvenanceRecord`, `io`, `json`, `StorageProvider` for type hints).
- [ ] **Step 5: Update `spectral_dataset.py`** — delete the moved functions; add imports at the top so the class/`_write_run`/`write_minimal` call sites still resolve. Cleanest: `from . import _dataset_write_genomic as _gw` and `from . import _dataset_write_metadata as _mw`, then update internal references (e.g. `_write_genomic_run(...)` → `_gw._write_genomic_run(...)`). Alternatively `from ._dataset_write_genomic import (...)` explicit names. Pick one and apply consistently. Any name an external caller used (from Step 2) gets re-imported into `spectral_dataset`'s namespace so its public path still works.
- [ ] **Step 6: Run** the baseline set from Step 1 → identical pass set. Then a quick import smoke: `...python -c "import ttio.spectral_dataset, ttio._dataset_write_genomic, ttio._dataset_write_metadata; from ttio import SpectralDataset, WrittenRun; print('ok')"` (use `.venv/bin/python`).
- [ ] **Step 7: Full suite + coverage:** `...pytest -q 2>&1 | tail -3` (only JDK/xlang env failures remain) and `...pytest --cov=ttio --ignore=tests/conformance --ignore=tests/integration --ignore=tests/validation -q 2>&1 | grep -i TOTAL` (≥84% on CI; report local %).
- [ ] **Step 8: Commit** `refactor(p3.10): extract genomic-write + metadata-IO submodules from spectral_dataset` + a CHANGELOG `### Changed` (internal restructure, no API/wire change, P3.10).

---

### Task 2 (PR-2): Python `transport/codec.py` → writer/reader/common + facade

**Files:**
- Create: `python/src/ttio/transport/_writer.py`, `_reader.py`, `_common.py`
- Modify: `python/src/ttio/transport/codec.py` (becomes facade)

- [ ] **Step 1: Baseline.** Run the transport suites: `...pytest tests/test_transport_codec.py tests/test_transport_codec_unit.py tests/test_transport_conformance.py tests/test_dataset_walker.py tests/test_transport_packets_unit.py -q` → record the green set (note: `test_transport_conformance` may have xlang legs that fail locally on JDK env — record which PURE-Python ones pass).
- [ ] **Step 2: Study** `transport/codec.py`. Confirm the symbol groups per spec PR-2. CRITICAL: `grep -rn "transport.codec\|transport import codec\|from .codec\|from ttio.transport.codec" python/src python/tests` — list EVERY symbol imported from `codec` by any caller. The facade must re-export all of them.
- [ ] **Step 3: Create `_common.py`** — move VERBATIM `_read_mate_chrom_names_table`, `_apply_wire_codec`, `_decode_wire_codec`, `_iter_genomic_run_access_units` + their imports. (These are used by both writer and reader.)
- [ ] **Step 4: Create `_writer.py`** — move VERBATIM `TransportWriter` + writer-only free helpers (`_spectrum_to_access_unit`, `_instrument_config_json`, `_genomic_run_metadata_json`, `_provenance_params_json`, `_provenance_csv_join`, `_provenance_csv_split`, `_provenance_params_parse`, `_scan_pattern_to_byte`). Import shared helpers from `._common`.
- [ ] **Step 5: Create `_reader.py`** — move VERBATIM `TransportReader` + reader/ingest helpers (`_new_genomic_accumulator`, `_ingest_genomic_access_unit_bytes`, `_decode_stream_header`, `_decode_dataset_header`, `_ingest_access_unit_bytes`, `_ingest_access_unit`, `_scan_pattern_from_byte`). Import from `._common`.
- [ ] **Step 6: Rewrite `codec.py` as a facade** — keep its module docstring; `from ._common import *`-equivalent explicit re-imports, `from ._writer import TransportWriter` (+ any writer helper a caller imported), `from ._reader import TransportReader` (+ reader helpers callers imported), and keep `file_to_transport` / `transport_to_file` here (they orchestrate writer+reader — either keep their bodies in codec.py importing the classes, or move to `_common`/their own and re-export). Add an `__all__` matching the pre-split public surface from Step 2.
- [ ] **Step 7: Run** the Step 1 baseline set → identical pass set. Import smoke: `...python -c "from ttio.transport.codec import TransportWriter, TransportReader, file_to_transport, transport_to_file; print('ok')"` plus any other symbol Step 2 found.
- [ ] **Step 8: Full suite** `...pytest -q 2>&1 | tail -3` → only JDK/xlang env failures. Coverage as in Task 1.
- [ ] **Step 9: Commit** `refactor(p3.10): split transport/codec.py into writer/reader/common (codec.py = facade)` + CHANGELOG.

---

### Task 3 (PR-3): Java `SpectralDataset.java` → package-private writer/metadata helpers

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/SpectralDatasetGenomicWriter.java`
- Create: `java/src/main/java/global/thalion/ttio/SpectralDatasetMetadataIO.java`
- Modify: `java/src/main/java/global/thalion/ttio/SpectralDataset.java`

- [ ] **Step 1: Baseline.** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o test -B 2>&1 | tail -15` → record BUILD SUCCESS + test count.
- [ ] **Step 2: Study** `SpectralDataset.java` lines ~1377–3096. Confirm the static-method sets per spec PR-3. CRITICAL: `grep -rn "SpectralDataset\.\(build\|write\|read\|parse\|validate\|encode\|referenceMd5\|usesRefDiff\|codecIdFor\|bytesToHexLocal\|nonEmptyJson\)" src/test src/main` — find any caller of the to-be-moved statics OUTSIDE SpectralDataset (esp. the package-private `buildIdentificationsJson`/`buildQuantificationsJson`/`buildProvenanceJson`). For each external caller, plan to keep a thin `static` delegator on `SpectralDataset` OR update the call site. Also note which moved statics call each other / call `SpectralDataset` private statics that are NOT moving (those must become package-private or also move).
- [ ] **Step 3: Create `SpectralDatasetGenomicWriter.java`** — `package global.thalion.ttio;` class `final class SpectralDatasetGenomicWriter`. Move VERBATIM the genomic-write statics (spec PR-3 list, ~1377–2546), changing each from `private static` to `static` (package-private) so `SpectralDataset` can call them. Add the imports SpectralDataset had that these use. Methods that call sibling moved statics now call them within this class (unqualified); methods that call statics remaining on `SpectralDataset` call `SpectralDataset.<name>` (make those package-private if needed).
- [ ] **Step 4: Create `SpectralDatasetMetadataIO.java`** — `final class SpectralDatasetMetadataIO`, move VERBATIM the metadata + subjects/samples statics (spec PR-3 list, ~2547–3096), `private static`→`static`. Add imports.
- [ ] **Step 5: Update `SpectralDataset.java`** — delete the moved methods; update call sites in the create/write orchestration to `SpectralDatasetGenomicWriter.<m>(...)` / `SpectralDatasetMetadataIO.<m>(...)`. For any external-caller static found in Step 2, add a thin `static <T> name(...) { return SpectralDatasetMetadataIO.name(...); }` delegator on `SpectralDataset` (preserves the call site + visibility). Keep all instance accessors, public statics (`open`/`create`/`createWithImages`), encrypt/decrypt/close.
- [ ] **Step 6: Compile + test** `JAVA_HOME=~/jdk25 mvn -o test -B 2>&1 | tail -15` → BUILD SUCCESS, identical test count to Step 1.
- [ ] **Step 7: Full verify (jacoco gate)** `JAVA_HOME=~/jdk25 mvn -o verify -B 2>&1 | tail -15` → BUILD SUCCESS, "All coverage checks have been met" (≥0.84). Code movement is coverage-neutral; if a moved package-private method's coverage attribution shifts and dips the bundle, that's unexpected — investigate (don't lower the gate).
- [ ] **Step 8: Commit** `refactor(p3.10): extract SpectralDatasetGenomicWriter + SpectralDatasetMetadataIO (Java)` + CHANGELOG.

---

### Task 4 (PR-4): ObjC `TTIOSpectralDataset.m` → categories + internal header

**Files:**
- Create: `objc/Source/Dataset/TTIOSpectralDataset+Internal.h`
- Create: `objc/Source/Dataset/TTIOSpectralDataset+GenomicWrite.m`
- Modify: `objc/Source/Dataset/TTIOSpectralDataset.m`
- Modify: `objc/Source/GNUmakefile` (both `*_OBJC_FILES` lists)

- [ ] **Step 1: Baseline.** `cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -20` → record clean build + test-runner pass count. (If `build.sh` doesn't exist or needs a target, `ls objc/*.sh` and study it; the project builds libTTIO then runs `TTIOTestRunner`.)
- [ ] **Step 2: Study** `TTIOSpectralDataset.m`. Identify (a) the file-`static` C genomic-write functions (~86–1312: `_TTIO_M86_*`, `_TTIO_V17_*`, `_TTIO_V18_*`, `_TTIO_PhaseT_*`, `_TTIO_M93_*`, `_TTIO_M94*`); (b) the `+` genomic write class methods (`+writeGenomicRunStorage:`, `+writeMSRunStorage:`, `+writeMinimalGenomicViaProviderURL:`, `+writeGenomicRun:`, `+writeMinimalToPath:` family, ~2122–3253). Determine which statics are used ONLY by the genomic class methods (move with them) vs also by core `writeToFilePath:`/read (keep shared ones in core OR declare in `+Internal.h`). Note every ivar the moving class methods touch (likely few, since they take params) — those ivars go in the internal header.
- [ ] **Step 3: Create `TTIOSpectralDataset+Internal.h`** — a class-extension header: `@interface TTIOSpectralDataset () { /* ivars the categories need */ }` plus declarations of any internal helper methods/`static`-equivalent the categories share. Import the same headers the `.m` top imports. The core `TTIOSpectralDataset.m` and the category `.m` both `#import` this. (Move the ivar block from the primary `.m`'s class extension into this header.)
- [ ] **Step 4: Create `TTIOSpectralDataset+GenomicWrite.m`** — `#import "TTIOSpectralDataset+Internal.h"` (+ needed headers); move VERBATIM the genomic-write `static` C functions from Step 2(a) and `@implementation TTIOSpectralDataset (GenomicWrite)` containing the class methods from Step 2(b). Statics used only here stay `static` in this file. Statics shared with core: declare in `+Internal.h` (non-static) and define once (in whichever file owns them).
- [ ] **Step 5: Update core `TTIOSpectralDataset.m`** — remove the moved statics + class methods; `#import "TTIOSpectralDataset+Internal.h"`; keep init/`writeToFilePath:`/read/`closeFile`/runs/encrypt/decrypt/access-policy. Ensure any shared static now declared in `+Internal.h` is defined exactly once (no duplicate-symbol link error).
- [ ] **Step 6: Register in `objc/Source/GNUmakefile`** — add `Dataset/TTIOSpectralDataset+GenomicWrite.m` to BOTH `*_OBJC_FILES` lists (study the file for the two list names, e.g. `libTTIO_OBJC_FILES` and any tools/second surface). Add `TTIOSpectralDataset+Internal.h` to the headers list if one is enumerated.
- [ ] **Step 7: Build + test** `cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -25` → clean build (no duplicate-symbol / undeclared-selector / missing-ivar errors), identical test-runner pass count to Step 1. Fix any ivar-visibility error by moving that ivar/decl into `+Internal.h`.
- [ ] **Step 8: Commit** `refactor(p3.10): split TTIOSpectralDataset.m into +GenomicWrite category (ObjC)` + CHANGELOG.

---

## Final review
After PR-4: dispatch a final reviewer over the cumulative P3.10 diff — confirm each god-file shrank, NO public API/signature changed (diff the public surfaces), no logic drift in moved code (spot-check a few moved functions are verbatim), CHANGELOG coherent. Then `superpowers:finishing-a-development-branch`.

## Self-review notes (author)
- **Spec coverage:** Task 1↔PR-1 (Python dataset), Task 2↔PR-2 (Python transport), Task 3↔PR-3 (Java), Task 4↔PR-4 (ObjC). All four spec PRs mapped. Out-of-scope items (transport Java/ObjC, class-internal mixins, P3.8/P3.11) excluded.
- **No-TDD rationale:** code movement has no new behavior; the characterization fence (same suite green before/after) is the correct verification, stated per task.
- **Risk coverage:** Python cycles (Step 2/3/4 one-way imports) + facade re-exports (Task 2 Step 2/6 grep-all-importers); Java package-private FQN (Task 3 Step 2/5 delegators); ObjC ivar visibility + GNUmakefile (Task 4 Step 3/6/7). All flagged with concrete handling.
- **Verbatim discipline:** every move step says VERBATIM; the final review spot-checks it.
