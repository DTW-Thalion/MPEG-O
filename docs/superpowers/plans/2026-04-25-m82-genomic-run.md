# M82 — GenomicRun + AlignedRead + Signal Channel Layout — Master Plan

**Spec:** [`HANDOFF.md`](../../../HANDOFF.md) (M82)

**Goal:** Three-language implementation of the genomic data model
(`GenomicRun`, `AlignedRead`, `GenomicIndex`, signal channel layout)
mirroring the existing M4 mass-spec pipeline.

---

## Why this is split into five sub-plans

The HANDOFF spec is 1127 lines covering Python (reference), ObjC
(normative), Java, cross-language conformance, and documentation. Each
of those is an independent subsystem with its own acceptance gate, and
each produces working, testable software on its own. Trying to execute
the whole milestone in one plan would be a 4000+ line task list with
mixed contexts — instead, split by subsystem so each can be executed,
reviewed, and merged independently.

| Sub-plan | Scope (HANDOFF §) | Depends on | Status |
|---|---|---|---|
| [M82.1 — Python reference](2026-04-25-m82.1-python-reference.md) | §2 + §3 + §4 + §5 + §6 + §7 | M79 enums (shipped) | **Plan written; ready to execute** |
| M82.2 — ObjC normative | §8 | M82.1 (data model + fixture) | Plan to be written after M82.1 lands |
| M82.3 — Java | §9 | M82.1 | Plan to be written after M82.1 lands |
| M82.4 — Cross-language conformance | §10 | M82.1, .2, .3 | Plan to be written after .1–.3 land |
| M82.5 — Documentation | §11 | All of the above | Plan to be written after .1–.4 land |

**Execution order is sequential.** Python is the reference: ObjC and
Java read the Python-written fixture for cross-language validation.
Documentation lands last to describe the actual shipped surface.

---

## Acceptance gates per sub-plan

Drawn from HANDOFF §"Acceptance Criteria":

### M82.1 (Python)
- All existing tests pass (zero regressions vs. 884-test M81 baseline).
- 100-read and 10K-read GenomicRun round-trips through HDF5 with all
  fields correct.
- Region query "chr1:10000-20000" returns correct subset.
- Unmapped-read filter returns correct subset.
- Paired-end mate info round-trips.
- Multi-omics file (1 ms_run + 1 genomic_run) readable independently.
- `"opt_genomic"` feature flag present when genomic_runs exist.
- Pre-M82 files open with empty `genomic_runs` dict.
- Memory + SQLite providers round-trip.

### M82.2 (ObjC)
- All existing ObjC tests pass.
- ≥ 40 new assertions in `TestM82GenomicRun.m`.
- 100-read round-trip via HDF5Provider + MemoryProvider.
- Multi-omics file readable.
- Pre-M82 file → empty `genomicRuns` dictionary.

### M82.3 (Java)
- All existing Java tests pass.
- ≥ 12 test methods, ≥ 50 assertions.
- 100-read round-trip via Hdf5Provider, MemoryProvider, SqliteProvider.

### M82.4 (Cross-language)
- 3×3 writer × reader matrix passes (Python/ObjC/Java each direction).
- Reference fixture `tests/fixtures/genomic/m82_100reads.tio` committed.
- Multi-omics cross-language fixture (5 MS spectra + 100 reads).

### M82.5 (Documentation)
- `docs/format-spec.md` §10 complete.
- `ARCHITECTURE.md` updated with genomic classes.
- `CHANGELOG.md` M82 entry under `[Unreleased]`.
- CI green across all three languages.

---

## Binding decisions (HANDOFF §"Binding Decisions" #70-74)

These are locked and must not be revisited during execution:

- **#70**: Genomic runs live under `/study/genomic_runs/`, separate from
  `/study/ms_runs/`. ms_runs readers never see genomic groups.
- **#71**: M82 stores one ASCII byte per base (no packing). Base-packing
  is deferred to a future codec milestone.
- **#72**: Flags stored as UINT32 (not UINT16). Future-proof for
  extended flag bits.
- **#73**: `GenomicIndex.chromosomes` is `list[str]`, stored as compound
  VL_BYTES. Variable-length strings.
- **#74**: All three languages ship in the same milestone. No
  single-language deferral for the data model.

---

## Build environment quick reference (HANDOFF §3.3)

- WSL Ubuntu (`wsl -d Ubuntu`) for all builds.
- Python tests: `cd ~/TTI-O/python && pytest -x tests/test_m82_genomic_run.py`.
- Java: `cd ~/TTI-O/java && mvn test`.
- ObjC: `cd ~/TTI-O/objc && . /usr/share/GNUstep/Makefiles/GNUstep.sh && LD_LIBRARY_PATH=Source/obj:/usr/local/lib:/home/toddw/_oqs/lib gmake -s check`.
- Push from Windows: `'/c/Program Files/Git/bin/git.exe' -C //wsl.localhost/Ubuntu/home/toddw/TTI-O push`.
- Cross-language test cache to clear if Java compile breaks: `rm -rf /tmp/ttio_m73_driver/`.
