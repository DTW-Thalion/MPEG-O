# P3.9 — Retire the raw-h5py leak (Python) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Remove the public `SpectralDataset.file` h5py handle, delete the `_native_h5py` escape shim, route signatures + genomic reference resolution through the StorageProvider protocol, and deprecate `native_handle()` — so no mainline TTI-O Python code reaches a raw h5py object.

**Architecture:** Five dependency-ordered PRs. The protocol infrastructure already exists (`StorageDataset.read_canonical_bytes` with an HDF5 zero-copy override; `StorageGroup.child_names/has_child/open_group/get_attribute/open_dataset`), so this is mostly *routing* + deleting escape hatches, not new abstraction. The HDF5 open path collapses into the already-protocol-based `_from_provider`. No `.tio` wire change; byte-parity fences guard the signature and ref_diff paths.

**Tech Stack:** Python 3.12, h5py, numpy, pytest. Spec: `docs/superpowers/specs/2026-06-04-p3-9-retire-raw-h5py-leak-design.md`.

**Environment / commands:**
- Tests: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <files> -q`
- Coverage gate: `.venv/bin/pytest --cov=ttio` must stay **≥0.84**.
- Build native rANS first if missing: `cd ~/TTI-O/native && cmake -S . -B _build -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build _build -j >/dev/null`.
- Commit identity: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit`.
- Push from Windows git: `"/c/Program Files/Git/bin/git.exe" -C //wsl.localhost/Ubuntu/home/toddw/TTI-O push -u origin p3-9-retire-raw-h5py-leak`.
- Branch is already created: `p3-9-retire-raw-h5py-leak` (the spec commit is on it). Each PR below is a commit-group on this branch unless the user requests separate branches; the controller cuts a PR per PR-section and merges before starting the next.

**Hard invariants (every PR):**
- No `.tio` on-disk / wire / transport change. No change to the embedded-reference layout (`/study/references/<uri>/{md5 attr, chromosomes/<chrom>/data}`).
- Cross-language signature + genomic ref_diff conformance preserved (byte-identical).
- Coverage ≥0.84.
- Behavior-identical except for the intended deprecation warning (PR-5) and the removed public `.file` attribute (PR-1).

---

## Verified facts (on `main`, 2026-06-04)

- `SpectralDataset.file: h5py.File | None` is a **dataclass field** (`spectral_dataset.py:93`). Set in exactly two places: `_from_provider` → `file=None` (`:287`); `_from_open_file` → `file=f` (`:357`).
- `_from_open_file` (`:302`) is a near-duplicate of `_from_provider` (`:227`) that reaches through raw h5py (`f["study"]`, `study["ms_runs"]`, `_load_references_h5py`). `_from_provider` already does the same via the protocol (`root.open_group(...)`, `_load_references_provider`) and is what Memory/SQLite/Zarr use. `Hdf5Provider.root_group()` returns a `StorageGroup` wrapping the h5py groups, and the `io.*` helpers accept both raw and wrapped targets (`_hdf5_io._unwrap_to_h5py`).
- HDF5 open routes to `_from_open_file` at `:183` (remote path) and `:220` (local path, after `f = provider.native_handle()`).
- Internal `.file` uses (each already has a provider branch): `close` (`:407` `self.file.close()`), `_read_subjects`/`_read_samples` (`:580`/`:597`, called as `_read_*(self.provider, self.file)`), `_study_target` (`:695`), `_study_has_child` (`:701`), `_mark_root_encrypted` (`:835` `io.write_fixed_string_attr(self.file, ...)`).
- `_read_subjects` (`:2720`) / `_read_samples` (`:2779`) take `(provider, file)`.
- `io.write_fixed_string_attr(obj, name, value)` (`_hdf5_io.py:64`), `io.read_string_attr(obj, name, default)` (`:92`) — both accept a `_IOTarget` (raw or StorageGroup) today.
- `native_handle()` real call site: only `spectral_dataset.py:218`. `zarr.py:483` is a comment.
- `_native_h5py(group)` (`acquisition_run.py:49`) callers: `acquisition_run.py:528`, `genomic_run.py:199`, `genomic_run.py:380`. 0 tests reference it.
- `signatures.py`: `sign_dataset`/`verify_dataset` accept raw h5py; canonical bytes already go through `_Hdf5Dataset(dataset).read_canonical_bytes()`. `_write_vl_string_attr`/`_read_vl_string_attr` (`:398`+) use low-level `h5py.h5a`/`h5py.h5t`. `sign_storage_dataset`/`verify_storage_dataset` already work fully via the protocol (`set_attribute`/`get_attribute`/`read_canonical_bytes`).
- `ReferenceResolver.__init__(self, h5_file, external_reference_path=None)` (`genomic/reference_resolver.py`); `resolve()` uses `h5.get("/study/references/<uri>")`, `ref_grp.attrs["md5"]`, `ref_grp.get("chromosomes/<chrom>")`, `ref_grp['chromosomes'].keys()`, `chrom_grp["data"]`. 1 production caller (`genomic_run.py:380`) + `tests/test_m93_reference_resolver.py`.
- External `.file`: `tools/fasta_export_cli.py:84` (`h5 = ds.file`), `genomic/reference_import.py:285` (error text only).
- Test coupling: `.file` in `test_fasta_fastq_tio_roundtrip.py:147`, `test_bruker_tdf.py:216`, `test_cli_smoke.py:122-123`, `test_providers.py:378-379`. `native_handle` in 5 files incl. the leak-contract assertion `test_providers.py:379`.

---

# PR-1 — Dataset surface: remove `SpectralDataset.file`

**Outcome:** The `file` dataclass field is gone; the HDF5 open path runs through `_from_provider`; all internal `.file` uses route through `provider`. `native_handle()` stays (genomic/signatures still use it). `.tio` round-trips byte-identically.

### Task 1.1: Route HDF5 open through `_from_provider` and delete `_from_open_file`

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py` (`:175-225` open paths, delete `_from_open_file` `:302`+ and `_load_references_h5py`)
- Test: `python/tests/test_p3_9_no_file_attr.py` (new)

- [ ] **Step 1: Write the failing test** — `tests/test_p3_9_no_file_attr.py`:

```python
"""P3.9: SpectralDataset no longer exposes a raw h5py .file handle, and
HDF5 opens go through the provider path identically to other backends."""
import numpy as np
import pytest
from ttio.spectral_dataset import SpectralDataset
from ttio.acquisition_run import AcquisitionRun  # noqa: F401  (fixtures)


def _write_minimal_tio(path):
    sd = SpectralDataset.create(str(path), title="t", isa_investigation_id="i")
    sd.close()


def test_spectraldataset_has_no_file_attribute(tmp_path):
    p = tmp_path / "x.tio"
    _write_minimal_tio(p)
    ds = SpectralDataset.open(str(p))
    try:
        assert not hasattr(ds, "file"), "public .file handle must be removed"
        assert ds.provider is not None
        assert ds.provider.root_group().has_child("study")
    finally:
        ds.close()
```

- [ ] **Step 2: Run to verify it fails** — `...pytest tests/test_p3_9_no_file_attr.py -q` → FAIL (`.file` still present). Adjust `SpectralDataset.create` call to match the actual constructor if needed (study the real `create`/`open` signatures first).
- [ ] **Step 3: Study** the two HDF5 open sites (`:175-225`), `_from_open_file` (`:302`), `_from_provider` (`:227`), `_load_references_h5py` vs `_load_references_provider`. Confirm `Hdf5Provider.open(path)` + `_from_provider` produces an equivalent dataset (runs, references, encrypted flag, persistence context) to `_from_open_file`.
- [ ] **Step 4: Implement** —
  - Remove the `file: h5py.File | None` field (`:93`) and its doc-comment block (`:90-118`).
  - In `_from_provider`, delete the `file=None` kwarg (`:287`).
  - Delete `_from_open_file` entirely and `_load_references_h5py` (now unused — grep to confirm).
  - Local open path (`:213-221`): after `provider = Hdf5Provider.open(str(p), mode=mode)`, call `return cls._from_provider(p, provider, thread_safe=thread_safe)` (drop `f = provider.native_handle()` and the `_from_open_file` call). On exception, `provider.close()`.
  - Remote open path (`:175-185`): construct an `Hdf5Provider` over the opened remote file object and route through `_from_provider`, threading `_remote_fileobj` so close still releases the fsspec handle. (Study how the remote path obtains `f`; wrap it via the provider's from-open-file constructor if one exists, else add a private `Hdf5Provider._from_h5py(f)` classmethod that stores the handle without reopening.)
- [ ] **Step 5: Run** the new test + the dataset suite:
  `...pytest tests/test_p3_9_no_file_attr.py tests/test_spectral_dataset.py tests/test_providers.py -q` → green (note: `test_providers.py:378-379` will FAIL here because it asserts `ds.file`; that test is fixed in Task 1.3).
- [ ] **Step 6: Commit** `refactor(p3.9): route HDF5 open through _from_provider; drop _from_open_file`.

### Task 1.2: Migrate internal `.file` uses to the provider

**Files:**
- Modify: `python/src/ttio/spectral_dataset.py` (`:407`, `:580`, `:597`, `:695-702`, `:835`, `_read_subjects` `:2720`, `_read_samples` `:2779`)

- [ ] **Step 1: Study** each site + the `_read_subjects(provider, file)` / `_read_samples(provider, file)` bodies — confirm the provider-only branch is already exercised by non-HDF5 backends (so it's proven correct).
- [ ] **Step 2: Implement** —
  - `close` (`:400-407`): the `if self.provider is not None:` branch already closes via provider; delete the `else: self.file.close()` fallback (provider is now always set). Keep the `_remote_fileobj` close.
  - `subjects`/`samples` (`:580`/`:597`): call `_read_subjects(self.provider)` / `_read_samples(self.provider)`; change the two helper signatures to drop the `file` parameter and remove any h5py branch inside (read via the provider root).
  - `_study_target` (`:693-696`): return `self.provider.root_group().open_group("study")` (drop the `self.file["study"]` branch + the now-stale docstring line about raw `h5py.Group`).
  - `_study_has_child` (`:700-702`): `return self.provider.root_group().open_group("study").has_child(name)`.
  - `_mark_root_encrypted` (`:834-837`): `self.provider.root_group().set_attribute("encrypted", DEFAULT_ENCRYPTION_ALGORITHM)` (drop the `io.write_fixed_string_attr(self.file, ...)` branch).
- [ ] **Step 3: Run** `...pytest tests/test_spectral_dataset.py tests/test_subjects*.py tests/test_sample*.py tests/test_encryption*.py -q` → green. (Adjust globs to the real test filenames; study `ls tests | grep -iE "subject|sample|encrypt"` first.)
- [ ] **Step 4: Commit** `refactor(p3.9): route SpectralDataset internal IO through provider`.

### Task 1.3: Migrate external `.file` consumers + tests

**Files:**
- Modify: `python/src/ttio/tools/fasta_export_cli.py:84`, `python/src/ttio/genomic/reference_import.py:285`
- Modify tests: `tests/test_fasta_fastq_tio_roundtrip.py:147`, `tests/test_bruker_tdf.py:216`, `tests/test_cli_smoke.py:122-123`, `tests/test_providers.py:378-379`

- [ ] **Step 1: Study** `fasta_export_cli.py:80-100` (it reads `/study/references/<uri>` → `md5` attr → `chromosomes`). Note: this is migrated more fully in PR-4 via `ReferenceResolver`; here, just stop using `ds.file` and navigate `ds.provider.root_group()`.
- [ ] **Step 2: Implement** —
  - `fasta_export_cli.py`: replace `h5 = ds.file; ... h5.get(...)` with provider navigation: `root = ds.provider.root_group()`; guard `if not root.has_child("study") or not root.open_group("study").has_child("references"): raise RuntimeError(f"fasta_export_cli requires embedded references; got provider {ds.provider.provider_name()!r}")`; then `refs = root.open_group("study").open_group("references")`; use `refs.has_child(uri)` / `refs.open_group(uri)`; read `md5` via `get_attribute`; `chromosomes` via `open_group`. (Mirror the `ReferenceResolver` walk; PR-4 may dedupe.)
  - `reference_import.py:285`: update the error text from "`no .file handle`" to "`provider {type(...).__name__} has no embedded /study/references`".
  - Tests: rewrite each `ds.file` access to `ds.provider.root_group()` navigation (`test_cli_smoke.py:122-123` → `root = ds.provider.root_group(); assert root.open_group("study").has_child("references")`). For `test_providers.py:378-379`, **delete the leak-contract assertion** `assert ds.provider.native_handle() is ds.file` (replaced in PR-5 by the deprecation test) and assert `not hasattr(ds, "file")`.
- [ ] **Step 3: Run** `...pytest tests/test_fasta_fastq_tio_roundtrip.py tests/test_bruker_tdf.py tests/test_cli_smoke.py tests/test_providers.py -q` → green.
- [ ] **Step 4: Full suite + coverage** `...pytest --cov=ttio -q 2>&1 | tail -20` → all pass, coverage ≥0.84.
- [ ] **Step 5: Commit** `refactor(p3.9): migrate external .file consumers + tests to provider` + CHANGELOG `### Changed` entry under `## [Unreleased]` noting `SpectralDataset.file` removal (OO-assessment P3.9).

---

# PR-2 — Signatures through the protocol

**Outcome:** `sign_dataset`/`verify_dataset` route raw-h5py inputs through `_Hdf5Dataset` + the storage path; VL-attr write goes through the provider's `set_attribute`; the only remaining raw-h5py island is the deprecated v1 native-bytes verify.

### Task 2.1: Route sign/verify through the storage path; collapse VL-attr helpers

**Files:**
- Modify: `python/src/ttio/signatures.py` (`sign_dataset` `:82`, `verify_dataset` `:128`, `_write_vl_string_attr`/`_read_vl_string_attr` `:398`+)
- Test: `python/tests/test_p3_9_signatures_protocol.py` (new)

- [ ] **Step 1: Write the failing test** — sign an HDF5-backed dataset via `sign_dataset(h5py_dataset, key)`, then verify the **same stored attribute** is readable by `verify_storage_dataset(_Hdf5Dataset(h5py_dataset), key)` (proves the attr write went through the protocol-compatible path), and that `verify_dataset` round-trips:

```python
def test_sign_dataset_attr_is_protocol_readable(tmp_path):
    # build a tiny HDF5 dataset, sign via the h5py-native entrypoint
    import h5py, numpy as np
    from ttio import signatures
    from ttio.providers.hdf5 import _Dataset as Hdf5Dataset
    p = tmp_path / "s.h5"
    with h5py.File(p, "w") as f:
        dset = f.create_dataset("d", data=np.arange(16, dtype="<i4"))
        key = b"k" * 32
        sig = signatures.sign_dataset(dset, key)
        assert sig.startswith("v2:")
        assert signatures.verify_dataset(dset, key) is True
        # the attribute must be readable through the protocol wrapper
        assert signatures.verify_storage_dataset(Hdf5Dataset(dset), key) is True
```

- [ ] **Step 2: Run to verify** baseline behavior (this may already pass for verify; the point is to lock the cross-path equivalence before refactor). Note any RED.
- [ ] **Step 3: Study** how `_Hdf5Dataset.set_attribute` writes string attrs vs `_write_vl_string_attr`. Confirm (via a quick interactive check or the existing cross-lang conformance test) that `set_attribute` produces an attribute the ObjC/Java verifiers accept — i.e. that `sign_storage_dataset` (which uses `set_attribute`) is already in the conformance matrix.
- [ ] **Step 4: Implement** —
  - `sign_dataset`: after the existing `isinstance(dataset, StorageDataset)` delegation, for the raw-h5py branch wrap and delegate: `return sign_storage_dataset(_Hdf5Dataset(dataset), key, algorithm=algorithm)`. This removes the `_write_vl_string_attr(dataset, ...)` call.
  - `verify_dataset`: for the raw-h5py branch, for **v2/v3** delegate to `verify_storage_dataset(_Hdf5Dataset(dataset), key, algorithm=algorithm)`. Keep the **v1 unprefixed** legacy path inline (it needs `_dataset_native_bytes` + `_read_vl_string_attr`), clearly commented as the sole retained raw-h5py island (scheduled for separate removal). Read the stored attr for the v1-detection via `_Hdf5Dataset(dataset).get_attribute(SIGNATURE_ATTR)` so only the native-bytes hashing stays raw.
  - Delete `_write_vl_string_attr` if no longer referenced; keep `_read_vl_string_attr` only if the v1 path still needs it (else delete). Grep to confirm.
- [ ] **Step 5: Run** `...pytest tests/test_p3_9_signatures_protocol.py tests/test_*signature*.py tests/test_m90_2_genomic_signatures.py -q` → green, incl. the cross-language conformance matrix (skips gracefully if ObjC/Java tooling absent — note it; CI runs it).
- [ ] **Step 6: Commit** `refactor(p3.9): sign/verify route through the storage protocol` + CHANGELOG entry.

---

# PR-3 — Cold-path attribute helpers; delete `_native_h5py`

**Outcome:** `_hdf5_io` string-attr read helpers accept `StorageGroup`; `acquisition_run.py:528` and `genomic_run.py:199` pass the group directly; `_native_h5py` is deleted.

### Task 3.1: Extend helpers + delete the shim

**Files:**
- Modify: `python/src/ttio/_hdf5_io.py` (the string-attr read helpers, `:92`+)
- Modify: `python/src/ttio/acquisition_run.py` (`_native_h5py` `:49`, callers `:528`), `python/src/ttio/genomic_run.py` (`:199`)
- Test: `python/tests/test_p3_9_coldpath_attrs.py` (new)

- [ ] **Step 1: Study** `_hdf5_io.read_string_attr` (`:92`) and `read_feature_flags` — confirm whether they already accept a `StorageGroup` via `_unwrap_to_h5py`, OR whether the cold-path callers at `acquisition_run.py:528`/`genomic_run.py:199` use a helper that still requires a raw group. Identify the exact helper(s) the two `_native_h5py` callers feed their result into.
- [ ] **Step 2: Write the failing test** — `tests/test_p3_9_coldpath_attrs.py`: open a `.tio` whose AcquisitionRun cold-path attributes are read, assert the value matches when the run group is a `StorageGroup` (the HDF5 provider path) — i.e. the path that currently goes through `_native_h5py` returns identical values without it. (Pick a concrete cold-path attribute the run exposes; study `acquisition_run.py:520-540`.)
- [ ] **Step 3: Run to verify** it passes today (baseline) — this is a *characterization* test guarding the refactor.
- [ ] **Step 4: Implement** — extend the relevant `_hdf5_io` helper(s) to accept a `StorageGroup` (read via `get_attribute`/`attribute_names`) in addition to a raw object; change `acquisition_run.py:528` and `genomic_run.py:199` to pass `self.group` directly (drop `_native_h5py(...)`); delete `_native_h5py` and its `from .acquisition_run import _native_h5py` imports. (`genomic_run.py:380` is migrated in PR-4 — leave its `_native_h5py` call until then, OR temporarily inline `self.group._grp` with a `# removed in PR-4` note. Prefer: do PR-3 and PR-4 in sequence so `_native_h5py` deletion lands with PR-4's resolver change. If keeping PRs independent, defer the actual `del _native_h5py` to PR-4 and have PR-3 only extend helpers + migrate the two cold-path callers.)
- [ ] **Step 5: Run** `...pytest tests/test_p3_9_coldpath_attrs.py tests/test_m82_genomic_run.py tests/test_acquisition*.py -q` → green.
- [ ] **Step 6: Commit** `refactor(p3.9): cold-path attr helpers accept StorageGroup; drop _native_h5py callers`.

---

# PR-4 — Genomic reference resolution through the protocol

**Outcome:** `ReferenceResolver` navigates embedded references via `StorageGroup`; `genomic_run.py:380`, `fasta_export_cli.py`, `reference_import.py`, and `test_m93_reference_resolver.py` updated; ref_diff decode is byte-identical. `_native_h5py` fully deleted (its last caller is gone).

### Task 4.1: Migrate `ReferenceResolver` to `StorageGroup`

**Files:**
- Modify: `python/src/ttio/genomic/reference_resolver.py`
- Modify: `python/src/ttio/genomic_run.py:380`, `python/src/ttio/acquisition_run.py` (delete `_native_h5py` if not already)
- Modify test: `python/tests/test_m93_reference_resolver.py`
- Test: `python/tests/test_p3_9_refdiff_roundtrip.py` (new byte-parity fence)

- [ ] **Step 1: Write the byte-parity fence FIRST** — `tests/test_p3_9_refdiff_roundtrip.py`: build a small genomic run with an embedded reference, REF_DIFF-encode then decode, and assert the decoded sequence bytes equal the original input bytes. (Study `tests/test_m93_reference_resolver.py` + an existing ref_diff round-trip test, e.g. `test_m90_10_genomic_wire_codec.py`, for the fixture-build pattern.) This must pass before AND after the migration with identical bytes.
- [ ] **Step 2: Run** it against current code → green (baseline).
- [ ] **Step 3: Study** `ReferenceResolver.resolve()` and map each h5py op to the protocol: `h5.get("/study/references/<uri>")` → `root.open_group("study").open_group("references")` then `has_child(uri)`/`open_group(uri)`; `ref_grp.attrs["md5"]` → `ref_grp.get_attribute("md5")`; `ref_grp.get("chromosomes/<chrom>")` → `ref_grp.open_group("chromosomes")` then `has_child`/`open_group`; `ref_grp['chromosomes'].keys()` → `ref_grp.open_group("chromosomes").child_names()`; `chrom_grp["data"]` → `chrom_grp.open_dataset("data").read()` then `np.asarray(...).tobytes()`.
- [ ] **Step 4: Implement** —
  - `ReferenceResolver.__init__(self, root_group, external_reference_path=None)` taking a `StorageGroup` (the provider root). Keep `_hex_str_attr` (now coercing `get_attribute` returns — same types). Rewrite `resolve()` per Step 3. Preserve the external-FASTA branch and `RefMissingError` (Q5c) text exactly. Update the class docstring (`h5_file` → `root_group`).
  - `genomic_run.py:380`: `resolver = ReferenceResolver(self.group._root_or_provider_root())` — i.e. pass the provider root group. Study how `self.group` reaches the provider root; if a run group can't reach root directly, thread the dataset's provider in. (The resolver only needs `/study/references`, so passing the **references group** directly is also acceptable — choose whichever the run can supply cleanly and update `resolve()` to navigate from that anchor consistently.)
  - `fasta_export_cli.py`: reuse `ReferenceResolver` (delete the bespoke walk added in PR-1 Task 1.3 if it duplicates the resolver).
  - Delete `_native_h5py` from `acquisition_run.py` (now no callers) + remove its imports.
  - `test_m93_reference_resolver.py`: construct the resolver from a provider root group instead of `h5py.File f` (open the fixture via `SpectralDataset.open(...).provider.root_group()` or directly via `Hdf5Provider`).
- [ ] **Step 5: Run** the fence + genomic suite:
  `...pytest tests/test_p3_9_refdiff_roundtrip.py tests/test_m93_reference_resolver.py tests/test_m90_10_genomic_wire_codec.py tests/test_m86_genomic_codec_wiring.py -q` → green, **decoded bytes identical**.
- [ ] **Step 6: Full suite + coverage** `...pytest --cov=ttio -q 2>&1 | tail -20` → ≥0.84.
- [ ] **Step 7: Commit** `refactor(p3.9): genomic ReferenceResolver navigates via StorageGroup; remove _native_h5py` + CHANGELOG entry.

---

# PR-5 — Deprecate `native_handle()`

**Outcome:** `StorageProvider.native_handle()` warns (method retained), mirroring Java's `@Deprecated(forRemoval=true)`; no mainline caller remains.

### Task 5.1: Add DeprecationWarning + invert the leak-contract test

**Files:**
- Modify: `python/src/ttio/providers/base.py` (`native_handle` `:476`) and each provider override (`hdf5.py`, `memory.py`, `sqlite.py`, `zarr.py`)
- Modify: `python/src/ttio/providers/zarr.py:483` (comment)
- Test: `python/tests/test_p3_9_native_handle_deprecated.py` (new)

- [ ] **Step 1: Verify no mainline caller** — `grep -rn "native_handle()" src/ttio --include=*.py | grep -v "def native_handle"` → only comments. If any real call remains, fix it before deprecating.
- [ ] **Step 2: Write the failing test** — assert `native_handle()` emits `DeprecationWarning`:

```python
import warnings, pytest
def test_native_handle_warns(tmp_path):
    from ttio.spectral_dataset import SpectralDataset
    p = tmp_path / "x.tio"
    SpectralDataset.create(str(p), title="t", isa_investigation_id="i").close()
    ds = SpectralDataset.open(str(p))
    try:
        with pytest.warns(DeprecationWarning):
            ds.provider.native_handle()
    finally:
        ds.close()
```

- [ ] **Step 3: Run to verify it fails** (no warning yet).
- [ ] **Step 4: Implement** — at the top of each `native_handle()` implementation, `warnings.warn("native_handle() is deprecated and slated for removal; use root_group(). Parity: Java @Deprecated(forRemoval=true).", DeprecationWarning, stacklevel=2)` then return as before. Update the base docstring. Fix the `zarr.py:483` comment to point at `root_group()` instead of recommending `native_handle()`.
- [ ] **Step 5: Run** `...pytest tests/test_p3_9_native_handle_deprecated.py tests/test_providers.py -q` → green. Confirm the suite doesn't itself trip the warning into an error (if `-W error` is configured, filter in the legitimate internal callers — there should be none).
- [ ] **Step 6: Full suite + coverage** `...pytest --cov=ttio -q 2>&1 | tail -20` → ≥0.84.
- [ ] **Step 7: Commit** `refactor(p3.9): deprecate StorageProvider.native_handle() (parity with Java)` + CHANGELOG `### Deprecated` entry.

---

## Final review

After PR-5: dispatch a final code-review subagent over the whole P3.9 diff. Confirm:
- `grep -rn "\.file\b" src/ttio` shows no `SpectralDataset.file` access; `grep -rn "_native_h5py"` → none; `native_handle()` real call sites → none.
- Cross-language signature + ref_diff conformance green on CI.
- CHANGELOG `[Unreleased]` has the P3.9 entries (Changed: `.file` removed; Deprecated: `native_handle()`).
- Then `superpowers:finishing-a-development-branch`.

## Self-review notes (author)
- **Spec coverage:** PR-1↔goal#1, PR-2↔#3, PR-3+PR-4↔#2+#4, PR-5↔#5. All five spec workstreams mapped.
- **PR-3/PR-4 coupling:** `_native_h5py` has 3 callers; PR-3 migrates 2 (cold-path), PR-4 migrates the 3rd (resolver) and does the actual `del`. The plan flags this so neither PR leaves a dangling reference — if run independently, PR-3 keeps `_native_h5py` and PR-4 deletes it.
- **Byte-parity fences:** PR-2 (signature conformance matrix), PR-4 (ref_diff round-trip) are written/confirmed-green BEFORE the refactor (characterization tests).
- **Constructor risk:** `file` is a dataclass field set in 2 sites; collapsing `_from_open_file`→`_from_provider` removes both and the duplication. The remote-open path is the one place needing care (threading `_remote_fileobj` through the provider) — called out explicitly in Task 1.1 Step 4.
