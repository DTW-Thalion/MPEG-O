# MPEG-O Reference Implementation — Continuation Session

> **Status (post-tag):** All eight milestones complete and merged on
> `main` (379 tests passing in CI). This document is preserved as the
> historical brief for the continuation session that built v0.1.0-alpha
> — refer to `WORKPLAN.md` for the canonical acceptance state and
> `ARCHITECTURE.md` for the as-built class/HDF5 layout.

You are taking over the MPEG-O reference implementation from a previous Claude Code session that ran on a different machine. This session will carry the project through **Milestones 1–8 plus the v0.1.0-alpha release**, executing on an i9 Windows + WSL/Ubuntu machine.

## Repository

- **URL:** https://github.com/DTW-Thalion/MPEG-O
- **License:** LGPL-3.0
- **Owner:** DTW-Thalion
- **Default branch:** `main`
- **Handoff point:** commit `9ba5938` — `build: add gcc objc header dir to include path on gnustep-1.8`

### First thing to do

Make sure the repo is cloned/updated on this machine, then **read these files in full before doing anything else**:

1. `README.md` — project overview
2. `ARCHITECTURE.md` — three-layer class hierarchy and HDF5 container mapping
3. `WORKPLAN.md` — the eight milestones with acceptance criteria
4. `docs/primitives.md`, `docs/container-design.md`, `docs/class-hierarchy.md`, `docs/ontology-mapping.md`
5. `objc/GNUmakefile.preamble` — toolchain detection and flags
6. `objc/check-deps.sh`, `objc/build.sh` — the build entry points
7. `.github/workflows/ci.yml` — CI job definition

Everything in those files is the source of truth. This handoff captures context that isn't in the tree.

---

## Current state

### What's complete (Phase 0–2)

- **Phase 0** — repo created, directory skeleton, LGPL-3.0 license, README with MPEG-G → MPEG-O mapping table, badges.
- **Phase 1** — `ARCHITECTURE.md` and `WORKPLAN.md` authored; `docs/` fully written.
- **Phase 2** — Objective-C scaffolding: GNUStep Make build system, all five capability protocols (`MPGOIndexable`, `MPGOStreamable`, `MPGOCVAnnotatable`, `MPGOProvenanceable`, `MPGOEncryptable`), and **four fully-implemented value classes** with `NSCoding`/`NSCopying`/`isEqual`/`hash`: `MPGOCVParam`, `MPGOAxisDescriptor`, `MPGOEncodingSpec`, `MPGOValueRange`. Plus `MPGOEnums.h` with all enums. Test runner `MPGOTests` with a Phase 2 smoke test.

**Note:** The value classes ARE the Milestone 1 production code — they're not stubs. What Milestone 1 still needs is **comprehensive test coverage** for them (construction edge cases, equality, hashing, copying, NSCoding round-trip, nil optional fields, zero-width ranges, extreme precisions, etc.). See `WORKPLAN.md` for the full acceptance criteria.

### Local build status (on the previous WSL machine)

- `./build.sh check` **passes, 8/8 tests green** against a **source-built gnustep-2.0 + libobjc2** setup.
- The build is verified to work end-to-end locally with that toolchain.

### CI status — **RED** at HEAD, needs fixing before Milestone 1

The previous session got CI to run on GitHub Actions (Ubuntu 24.04 runner) and debugged through five layers of Ubuntu-apt-gnustep incompatibilities, each commit peeling another onion layer:

1. `3f84a06` — Fixed `-fblocks` causing `objc/blocks_runtime.h` not found, by making `-fblocks` conditional on `gnustep-2.0` runtime.
2. `4ba4c1b` — Restored the `gobjc` apt package (to provide libobjc runtime headers, even though clang is the actual compiler).
3. `9ba5938` — Added `/usr/lib/gcc/x86_64-linux-gnu/*/include` to `ADDITIONAL_CPPFLAGS` on the `gnustep-1.8` path.

**Current failure at HEAD:** `/usr/include/GNUstep/Foundation/Foundation.h:31:9: fatal error: 'objc/objc.h' file not found`

The runtime ABI auto-detect correctly identifies `gnustep-1.8 (fragile)` and the `-fblocks` drop fires as expected, but the gcc-include-directory glob is either not expanding on the runner or `gobjc` on Ubuntu 24.04 isn't placing headers where the glob looks. The previous session never actually confirmed (with `find` or `dpkg -L`) where Ubuntu 24.04's `gobjc` puts `objc/objc.h`, or whether it installs it at all anymore.

### CI contract (user decision, binding for this session)

**Option (a): Match CI exactly. If CI is green, don't break it. If it is red, fix it before starting Milestone 1 work.**

This means your **immediate Day 1 task** is to get CI green at a new HEAD, and only then begin Milestone 1. Do not skip CI and push Milestone 1 code on top of a red build.

### Recommended CI fix strategy

The apt Ubuntu gnustep-1.8 + clang combination is a fragile path where every fix reveals another layer. Two approaches, in order of preference:

1. **Build gnustep-base from source against libobjc2 in the CI job**, mirroring the WSL developer setup. This gives you a `gnustep-2.0` runtime on CI that matches what developers use locally, making every test of local behavior directly applicable to CI. Adds roughly two minutes per CI run but eliminates a whole class of apt-path surprises. The job would:
   - `apt-get install clang cmake ninja-build libhdf5-dev zlib1g-dev libssl-dev make`
   - Build libobjc2 from source (https://github.com/gnustep/libobjc2)
   - Build and install `gnustep-make` and `gnustep-base` from source against libobjc2
   - Then `cd objc && ./build.sh check`

2. **Continue diagnosing the apt path.** At minimum, start the next attempt by adding a CI step that prints `find /usr/lib/gcc -type d -name objc`, `dpkg -L gobjc | grep objc`, and `dpkg -L libgnustep-base-dev | grep objc` so you can see exactly where (if anywhere) `objc/objc.h` actually lands on the Ubuntu 24.04 runner. The previous session hypothesized `/usr/lib/gcc/x86_64-linux-gnu/14/include/objc/objc.h` without confirming.

**Strong recommendation: option 1.** It converges on a single supported toolchain path (libobjc2-based gnustep-2.0) and makes CI a faithful mirror of the developer experience. The runtime auto-detect in `GNUmakefile.preamble` already handles both paths, so the change is confined to `.github/workflows/ci.yml` — no library code changes.

### Local dev environment (this machine)

- Windows 11 + WSL/Ubuntu, Claude Code running from PowerShell on Windows.
- The previous session's WSL already had `gnustep-base` built from source against `libobjc2`. Confirm the same is true on this machine, or replicate that setup before trusting `./build.sh check`.
- You can run `./build.sh check` inside WSL for sub-second verification. **Iterate locally** instead of waiting for CI round-trips during implementation.

---

## Binding decisions from the previous session

These decisions were made collaboratively with the user and must be preserved unless the user explicitly revises them:

1. **Milestone-by-milestone checkpoints.** Complete Milestone N, commit, verify CI green, pause for user review before starting Milestone N+1. Do **not** chain milestones without user acknowledgment.

2. **Clang-only.** `gcc`/`gobjc` cannot compile libMPGO because Objective-C ARC (`-fobjc-arc`) is required and gobjc doesn't support it. `build.sh` enforces `CC=clang OBJC=clang`. Never add code that would only work under gobjc.

3. **Value classes are immutable and return `self` from `-copyWithZone:`.** This is standard Cocoa practice for immutable value objects. Applies to `MPGOCVParam`, `MPGOAxisDescriptor`, `MPGOEncodingSpec`, `MPGOValueRange`, and any similar value classes added in later milestones (`MPGOInstrumentConfig`, `MPGOProvenanceRecord`, etc.).

4. **No thread safety in v0.1.** Document as "not thread-safe" where relevant. Concurrent access to an `MPGOHDF5File` from multiple threads is undefined. A future version may adopt HDF5's `--enable-threadsafe` build with explicit locking, but not in v0.1.0-alpha.

5. **CRLF/LF is handled by `.gitattributes`.** The repo forces LF endings for all source and build files (`*.m`, `*.h`, `GNUmakefile`, `*.sh`, `*.yml`). This matters because files may be edited through tools that default to CRLF on Windows. Do not modify `.gitattributes`.

6. **Shell scripts must be committed with the executable bit set.** A previous CI run died because `build.sh` was committed with mode `100644`. If you add any new `.sh` files on Windows, use `git update-index --chmod=+x <file>` to set mode `100755` before committing.

7. **HDF5 is accessed via the C API wrapped in thin Objective-C classes.** Do not introduce a Python-style high-level HDF5 abstraction. Each `H5*` call should be wrapped with explicit return-code checks and `NSError` out-parameters for fallible operations. Every `hid_t` must be closed via the wrapper's `-dealloc` or `-close`.

8. **MPEG-O files use `.mpgo` extension and are valid HDF5 files internally.** Any HDF5-aware tool (`h5dump`, `h5py`, HDFView) must be able to inspect them without a special reader. MPEG-O adds semantic structure on top of HDF5's generic model, not a new binary format.

9. **Error handling uses `NSError **` out-parameters for fallible operations.** Return `nil` or `NO` on failure. Never throw exceptions for expected error paths.

10. **Test isolation:** every test creates its own temporary HDF5 file in `/tmp/mpgo_test_*` and deletes it after the test. Do not share fixture files between tests.

11. **Python and Java implementations are planned but not active.** `python/README.md` and `java/README.md` are stubs. Do not add code to `python/` or `java/` during this session unless the user explicitly asks. All active work is in `objc/`.

12. **Commit discipline.** One commit per completed milestone with a clear message referencing the milestone number. Do not commit broken code. Use HEREDOC for multi-line commit messages and include the `Co-Authored-By` trailer.

13. **Never create documentation files (`*.md`) beyond what the workplan specifies** unless the user explicitly requests them. The docs that exist (`README`, `ARCHITECTURE`, `WORKPLAN`, `docs/*.md`, `HANDOFF.md`) are the complete documentation surface until the user asks for more.

---

## Known gotchas carried forward

1. **HDF5 paths differ by install method.** Ubuntu apt installs headers under `/usr/include/hdf5/serial/` and libs under `/usr/lib/x86_64-linux-gnu/hdf5/serial/`. Homebrew uses `/opt/homebrew/opt/hdf5`. Source builds typically use `/usr/local`. The preamble accepts `HDF5_PREFIX` on the command line for overrides. Test all new HDF5 code paths with both apt and source-built HDF5 if possible.

2. **`Testing.h` uses `NSAutoreleasePool`, which ARC forbids.** `objc/Tests/GNUmakefile.preamble` applies `-fno-objc-arc` specifically to the test binary while leaving `libMPGO` itself under ARC. Preserve this split. Do not convert `libMPGO` to MRC or the test harness to ARC.

3. **GNUstep Make's `test-tool.make` does not auto-run the binary on `make check`.** The top-level `objc/GNUmakefile` adds a custom `check::` target that depends on `all` and explicitly invokes `Tests/$(GNUSTEP_OBJ_DIR)/MPGOTests` with `LD_LIBRARY_PATH` extended to include the in-tree `libMPGO.so` and `/usr/local/lib`. If you add new test binaries, extend this target; don't reinvent it.

4. **Runtime ABI auto-detection probes `libgnustep-base.so` for the symbol `._OBJC_CLASS_NSObject`** (non-fragile v2) vs `_OBJC_CLASS_NSObject` (fragile v1). The detection is in `GNUmakefile.preamble` and is mirrored by `check-deps.sh`. If you add new toolchain flags that depend on the runtime, follow the same `ifeq ($(MPGO_OBJC_RUNTIME),gnustep-2.0)` pattern.

5. **`-fblocks` is gated on gnustep-2.0 only.** On gnustep-1.8 (apt Ubuntu), clang's `-fblocks` causes `GSVersionMacros.h` to include `objc/blocks_runtime.h`, which isn't shipped by libobjc on that path. `libMPGO` must not depend on blocks-based APIs (`dispatch_*`, `^`-literals, etc.) until/unless the build requires gnustep-2.0. For v0.1, no code uses blocks.

6. **Windows authoring quirk.** If files are ever re-saved through a Windows editor, `.gitattributes` should auto-correct line endings on commit, but watch for any `git diff` that shows whole-file changes due to line-ending drift. Fix with `git add --renormalize .` if it happens.

---

## Remaining work — the eight milestones

Full acceptance criteria are in `WORKPLAN.md`. High-level summary:

### Milestone 1 — Foundation tests (nearly done)

The value classes are already implemented. What's left is **comprehensive test coverage**. Replace the current Phase 2 smoke test in `objc/Tests/TestValueClasses.m` with thorough tests per the workplan. Add any missing test functions to `MPGOTestRunner.m`'s `START_SET`/`END_SET` blocks. Acceptance: all tests pass under `./build.sh check` locally and in CI.

### Milestone 2 — SignalArray + HDF5 wrapper

New files under `objc/Source/HDF5/`:

- `MPGOHDF5File` — `H5Fcreate`/`H5Fopen`/`H5Fclose`
- `MPGOHDF5Group` — `H5Gcreate2`/`H5Gopen2`/`H5Gclose`
- `MPGOHDF5Dataset` — `H5Dcreate2`/`H5Dwrite`/`H5Dread`/`H5Dclose`, supporting float32, float64, int32, int64, uint32, complex128 (compound type)
- `MPGOHDF5Attribute` — `H5Acreate2`/`H5Awrite`/`H5Aread`
- Chunked storage + zlib compression (`H5Pset_chunk`, `H5Pset_deflate`)

Plus `objc/Source/Core/MPGOSignalArray.{h,m}` with HDF5 round-trip methods and CVAnnotation persistence. Add the new files to `libMPGO_OBJC_FILES` / `libMPGO_HEADER_FILES` in `objc/Source/GNUmakefile`.

### Milestone 3 — Spectrum + concrete spectrum classes

- `MPGOSpectrum` base class (dict of named SignalArrays)
- `MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGONMR2DSpectrum`, `MPGOFreeInductionDecay`, `MPGOChromatogram`
- Each with HDF5 serialization following the container design
- Validation: `MPGOMassSpectrum` rejects construction with mismatched m/z and intensity lengths

### Milestone 4 — AcquisitionRun + SpectrumIndex (Access Unit)

- Signal-channel separation on HDF5 write: extract all m/z values to one contiguous dataset, intensities to another, scan metadata to a compound dataset
- `MPGOSpectrumIndex` with offsets/lengths/headers compound table
- `MPGOInstrumentConfig` value class
- Random-access reads via HDF5 hyperslab selection — verify only relevant chunks are touched
- Full `MPGOStreamable` + `MPGOIndexable` support

### Milestone 5 — SpectralDataset + Identification + Quantification + Provenance

- `MPGOSpectralDataset` as root `.mpgo` file object
- `MPGOIdentification`, `MPGOQuantification`, `MPGOProvenanceRecord`, `MPGOTransitionList`
- Full multi-run `.mpgo` round-trip test

### Milestone 6 — MSImage (spatial extension)

- `MPGOMSImage` extends `MPGOSpectralDataset` with a spatial grid
- Tile-based Access Units (32×32 pixel default)
- 3D HDF5 layout `[x, y, spectral_points]` with tile-aligned chunking

### Milestone 7 — Protection / encryption

- AES-256-GCM via OpenSSL (`libcrypto`)
- `MPGOEncryptionManager` + `MPGOAccessPolicy` (JSON in `/protection/access_policies`)
- Selective encryption: encrypt `intensity_values` while leaving `mz_values` + `scan_metadata` unencrypted
- GCM auth-tag verification on decrypt; wrong key → clean authenticated-decryption failure, no silent corruption

### Milestone 8 — Query API + streaming

- `MPGOQuery` with compressed-domain queries via AU header scanning (does NOT decompress signal data)
- `MPGOStreamWriter` / `MPGOStreamReader` for progressive I/O
- Predicates: RT range, MS level, polarity, precursor m/z range, base peak intensity threshold
- Performance: 10k-spectrum header scan < 50 ms

### Release — v0.1.0-alpha

All milestones complete, CI green, no warnings under `-Wall -Wextra`, tag `v0.1.0-alpha` pushed.

---

## Implementation constraints (unchanged from the original brief)

1. **All code is Objective-C under GNUStep** (`#import <Foundation/Foundation.h>`). No Apple-only frameworks.
2. **HDF5 via the C API** wrapped in Objective-C. Always check return values. Always close identifiers.
3. **ARC on libMPGO, MRC on the test harness.** Preserve the split.
4. **`MPGO` prefix on all classes, enums, protocols.** No exceptions.
5. **`.mpgo` file extension.** Internally they are HDF5 files.
6. **External dependencies:** GNUStep Base, libhdf5, zlib (bundled with HDF5), OpenSSL/libcrypto (Milestone 7 only). Nothing else.
7. **Commit discipline:** one commit per completed milestone, clear message, `Co-Authored-By` trailer, HEREDOC for multi-line messages.
8. **Build verification:** `./build.sh check` must pass locally (WSL) and in GitHub Actions CI before any milestone is considered complete.

---

## Recommended execution order for this session

1. **Pull the repo on this machine and read the files listed at the top of this document.**
2. **Verify the WSL toolchain.** Run `./build.sh check` in `objc/` inside WSL and confirm 8/8 tests pass. If the WSL setup on this machine is not yet configured with source-built gnustep-2.0 + libobjc2, replicate that setup first. (Guidance: libobjc2 at https://github.com/gnustep/libobjc2, gnustep-make and gnustep-base at https://github.com/gnustep.)
3. **Fix CI.** Open `.github/workflows/ci.yml` and implement the recommended "build gnustep from source against libobjc2" approach. Push, watch the run, iterate until green. Use `gh run watch` with `run_in_background: true` so you don't burn context on polling.
4. **Milestone 1.** Replace the Phase 2 smoke test with full coverage. Commit, verify CI green, pause for user review.
5. **Milestones 2–8.** One at a time, pausing for user review after each.
6. **Tag `v0.1.0-alpha`.**

Proceed. Ask the user if anything in this handoff is ambiguous before taking destructive or shared-state actions (pushing, creating PRs, tagging releases). Treat the user's CI-contract-option-(a) decision as binding: **CI must be green before any Milestone 1 work lands.**
