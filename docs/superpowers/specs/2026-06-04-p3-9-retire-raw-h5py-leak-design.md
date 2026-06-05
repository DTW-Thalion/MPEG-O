# P3.9 — Retire the raw-h5py leak (Python) — Design

> OO-assessment (`docs/architecture/2026-06-02-oo-design-assessment.md`) P3.9.
> Python-only. No `.tio` wire / on-disk change. Cross-language ref_diff and
> signature conformance preserved (byte-parity fences).

## Goal

No mainline TTI-O Python code reaches a raw `h5py` object. Concretely:

1. The public `SpectralDataset.file: h5py.File | None` handle is **removed** —
   consumers can no longer obtain a backend-specific raw handle off the dataset.
2. The `_native_h5py(group)` escape shim (`acquisition_run.py`) is **deleted**;
   its callers route through the storage protocol.
3. `signatures.py`'s `sign_dataset` / `verify_dataset` stop touching raw h5py for
   the *live* (v2/v3) path; the only remaining raw-h5py island is the deprecated
   **v1 native-bytes** legacy-verify fallback, clearly quarantined.
4. Genomic reference resolution (`ReferenceResolver`, `fasta_export_cli`,
   `genomic_run`) navigates embedded references through the `StorageGroup`
   protocol instead of an `h5py.File`.
5. `StorageProvider.native_handle()` is **deprecated** (Python `DeprecationWarning`,
   method retained), mirroring Java's existing `@Deprecated(forRemoval=true)` —
   keeping the three SDKs in parity and deferring hard removal to a future
   coordinated major.

## Why this is lower-risk than the audit implied

The protocol infrastructure already exists:

- `StorageDataset.read_canonical_bytes()` (`providers/base.py:187`) is a protocol
  method with an **HDF5 zero-copy override** (`providers/hdf5._Dataset`), so the
  **v2/v3 signature byte stream is already backend-agnostic**.
  `sign_storage_dataset` / `verify_storage_dataset` already use only
  `set_attribute` / `get_attribute` / `read_canonical_bytes`.
- `StorageGroup` already exposes `child_names`, `has_child`, `open_group`,
  `get_attribute`, and `open_dataset` (+ `StorageDataset.read`) — everything the
  genomic reference walk needs.

So P3.9 is mostly *routing* + deletion of escape hatches, not new abstraction.

## Inventory (verified on `main`, 2026-06-04)

**Public leak — `SpectralDataset.file`:**
- Internal uses (each already has a `provider.root_group()` fallback branch):
  `close` (`spectral_dataset.py:407`), `_read_subjects`/`_read_samples`
  (`:580`/`:597`), `_study_group` (`:695`), `_study_has_child` (`:701`),
  encrypted-attr write (`:835`).
- Open-path constructor: `:218` `f = provider.native_handle()` →
  `_from_open_file(p, f, ...)`. This is what *sets* `self.file`.
- External consumers: `tools/fasta_export_cli.py:84` (`h5 = ds.file`),
  `genomic/reference_import.py:285` (error-message text only).

**`_native_h5py(group)` shim** (`acquisition_run.py:49`): callers at
`acquisition_run.py:528` and `genomic_run.py:199` (cold-path string attrs) and
`genomic_run.py:380` (`ReferenceResolver(_native_h5py(self.group).file)`).
0 tests reference it.

**`signatures.py` raw-h5py:** `_dataset_native_bytes` (v1 legacy), the
h5py-native `sign_dataset`/`verify_dataset` fast path, and
`_write_vl_string_attr`/`_read_vl_string_attr` (low-level `h5py.h5a`/`h5py.h5t`
VL-UTF-8 attr write for ObjC parity).

**`native_handle()` real call sites:** only `spectral_dataset.py:218`
(`zarr.py:483` is a comment).

**Test coupling (light):** 5 files use `.file`, 5 use `native_handle`, 0 use
`_native_h5py`. `ReferenceResolver` has 1 production caller +
`tests/test_m93_reference_resolver.py`. `test_providers.py:378-379` asserts the
leak contract `ds.provider.native_handle() is ds.file` (to be inverted).

## Architecture — five PRs

Each PR is independently CI-green and reviewable (the P2.5/P2.6 multi-PR cadence).
Ordering is dependency-driven: the dataset surface first, then the consumers it
exposed, then native_handle last (once no mainline caller remains).

### PR-1 — Dataset surface

Remove the public `SpectralDataset.file` attribute entirely.

- The open-path constructor stops calling `provider.native_handle()`; it
  constructs the dataset from the provider and keeps a private reference to the
  provider only (the existing `_from_provider` path is the model). Fold/redirect
  `_from_open_file` so the HDF5 open path no longer threads a raw `h5py.File`.
- Each internal `.file` use deletes its `if self.file is not None: <h5py branch>`
  and keeps the existing `provider.root_group()` branch (study access becomes
  `provider.root_group().open_group("study")`; encrypted-attr becomes
  `provider.root_group().set_attribute(...)`; subjects/samples read via the
  provider helper already present).
- Update the ~3 tests that read `ds.file` (`test_fasta_fastq_tio_roundtrip.py`,
  `test_bruker_tdf.py`, `test_cli_smoke.py`) to navigate via
  `ds.provider.root_group()`.
- `native_handle()` is **left in place** this PR (signatures + genomic still use
  it transitively); only the dataset's own use of it is removed.

**Risk:** Low. **Fence:** full pytest suite + a `.tio` open→read→write→reopen
round-trip byte-parity assertion.

### PR-2 — Signatures

Route the live signature path entirely through the protocol.

- `sign_dataset` / `verify_dataset`: when handed a raw `h5py` object, wrap it in
  `providers.hdf5._Dataset` and delegate to `sign_storage_dataset` /
  `verify_storage_dataset` (they already produce identical canonical bytes).
- Collapse `_write_vl_string_attr` / `_read_vl_string_attr` onto the provider's
  `set_attribute` / `get_attribute`. The HDF5 provider's `set_attribute` already
  writes the ObjC-compatible VL-UTF-8 attribute (proven by the existing
  cross-language signature conformance matrix that `sign_storage_dataset` feeds).
- The deprecated **v1 native-bytes** verify fallback (`_dataset_native_bytes`)
  is the single retained raw-h5py island, kept behind the existing
  `DeprecationWarning` and clearly commented as the only legacy escape.

**Risk:** Medium (signature bytes). **Fence:** the cross-language signature
read/verify conformance matrix (HMAC v2 + ML-DSA-87 v3) stays green; a
sign-then-verify round-trip on an HDF5-backed dataset; legacy v1 verify still
validates a stored unprefixed signature.

### PR-3 — Cold-path attribute helpers

- Extend the `_hdf5_io` string-attribute read helpers to accept a `StorageGroup`
  (operating through `get_attribute`) in addition to the raw object they take
  today — the end-state the `_native_h5py` docstring already anticipates.
- Migrate `acquisition_run.py:528` and `genomic_run.py:199` to pass the
  `StorageGroup` directly.
- **Delete `_native_h5py`** and its import sites.

**Risk:** Low (0 tests reference the shim). **Fence:** full pytest suite;
existing acquisition/genomic cold-path attribute tests.

### PR-4 — Genomic reference resolution

- `ReferenceResolver.__init__` accepts a `StorageGroup` (the provider root, or a
  pre-opened `/study/references` group) instead of an `h5py.File`. `resolve()`
  navigates via `has_child`/`open_group`, reads `md5` via `get_attribute`, lists
  covered chromosomes via `child_names`, and reads the chromosome `data` dataset
  via `open_dataset(...).read()` (`np.asarray(...).tobytes()` →
  byte-identical to the current `chrom_grp["data"]` read). The external-FASTA and
  `RefMissingError` (Q5c hard-error) branches are unchanged.
- Update `genomic_run.py:380` to pass `self.group` (a `StorageGroup`);
  `fasta_export_cli.py:84` to navigate `ds.provider.root_group()`;
  `reference_import.py:285` error text; and `test_m93_reference_resolver.py` to
  construct the resolver from a provider/group.

**Risk:** Medium (sits in the ref_diff decode path). **Fence:** a REF_DIFF
encode→decode **round-trip byte-parity** test (decoded sequence bytes identical
before/after the migration) + the existing cross-language genomic conformance
tests.

### PR-5 — Deprecate native_handle

No mainline caller remains after PR-1/PR-2/PR-4.

- `StorageProvider.native_handle()` emits a `DeprecationWarning` (method
  retained), with a docstring pointing to `root_group()` and noting parity with
  Java's `@Deprecated(forRemoval=true)`.
- Remove the `zarr.py:483` comment that recommends `native_handle()`.
- Invert `test_providers.py:378-379`: instead of asserting the leak identity,
  assert calling `native_handle()` warns and that `SpectralDataset` no longer
  exposes `.file`.

**Risk:** Low. **Fence:** full pytest suite; a test asserting the
`DeprecationWarning` fires.

## Error handling

- Genomic/HDF5-only tools that genuinely require an HDF5 backend (fasta_export)
  raise a clear `RuntimeError`/`TypeError` naming the actual provider type when
  navigation finds no `/study/references` — same contract as today, just sourced
  from the provider instead of a missing `.file`.
- `ReferenceResolver`'s `RefMissingError` (Q5c hard-error, MD5 mismatch) behavior
  is preserved exactly; no partial decode.

## Out of scope

- Java / ObjC `native_handle()` removal (separate SDKs; Java already deprecated;
  a future coordinated major handles hard removal).
- Removing the deprecated **v1** native-bytes signature path (its own scheduled
  removal item; P3.9 only quarantines it).
- Any change to the `.tio` on-disk layout, embedded-reference structure, or
  transport protocol.

## Testing summary

| PR | Primary fence |
|----|---------------|
| PR-1 | pytest suite + `.tio` round-trip byte-parity |
| PR-2 | cross-language signature conformance (v2 + v3) + sign/verify round-trip + legacy v1 verify |
| PR-3 | pytest suite + acquisition/genomic cold-path attr tests |
| PR-4 | REF_DIFF encode→decode round-trip byte-parity + cross-language genomic conformance |
| PR-5 | pytest suite + DeprecationWarning assertion |

Coverage gate: Python ≥0.84 (`pytest --cov=ttio`) holds for each PR.
