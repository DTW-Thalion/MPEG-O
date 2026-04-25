# Storage Providers

TTI-O separates the data model from the storage backend. The
`ttio.providers` package (and its Objective-C / Java equivalents)
defines a protocol contract — `StorageProvider`, `StorageGroup`,
`StorageDataset` — that every backend implements. Four providers
ship across all three language implementations (HDF5, Memory, SQLite,
Zarr). Zarr stores use the v3 on-disk format as of v0.9.

## Feature matrix

| Provider | URL schemes | Chunking | Compression | N-D datasets | Compound with VL strings | Compound with VL_BYTES (v0.10) | Attributes | Transactions |
|---|---|---|---|---|---|---|---|---|
| **HDF5** (`Hdf5Provider`) | `file://`, bare paths, `http(s)://`, `s3://` (via h5py) | Yes (native HDF5 chunking) | Yes (zlib, LZ4 via `hdf5plugin`, Numpress-delta) | Yes (native rank; M45 adds the protocol surface) | Yes (native HDF5 compound) | **Yes** (native `hvl_t`; Java uses a `NativeBytesPool` to pack slots) | Strings, ints, floats, arrays | No (HDF5 has no transactional model) |
| **Memory** (`MemoryProvider`) | `memory://<name>` | No (chunk hint stored but ignored) | No | Yes (in-memory ndarray) | Yes (in-memory structured ndarray) | **Yes** (stores `bytes` objects verbatim) | Any Python object | No |
| **SQLite** (`SqliteProvider`) | `sqlite://<path>`, `.db`/`.sqlite` paths | No (chunk hint accepted, ignored) | No | Yes (flat BLOB + `shape_json`) | Yes (row-of-dicts as JSON) | **No** (raises `NotImplementedError` at `create_compound_dataset`; use HDF5 for `opt_per_au_encryption`) | Strings, ints, floats | Yes (`BEGIN` / `COMMIT` / `ROLLBACK`) |
| **Zarr** (`ZarrProvider`, v3 on-disk as of v0.9) | `zarr:///<path>`, `zarr+memory://<name>`, `zarr+s3://bucket/key` | Yes (native zarr chunks) | Yes (Blosc wrappers for zlib and LZ4 via `numcodecs`) | Yes (native N-D) | Yes (sub-group + JSON-rows attribute) | **No** (raises `NotImplementedError`; same rationale as SQLite — JSON-based compound path needs base64 transport for bytes) | JSON-serialisable types | No |

Legend

- **Chunking** — honors `chunk_size` / `chunks` arguments to
  `create_dataset` / `create_dataset_nd`.
- **Compression** — honors the `compression` / `compression_level`
  arguments.
- **Compound with VL strings** — can store records with variable-length
  string fields (identifications, quantifications, provenance).
- **Compound with VL_BYTES** — can store records with variable-length
  byte fields. Required for `opt_per_au_encryption`
  (`<channel>_segments` schema: `{offset INT64, length UINT32,
  iv VL_BYTES, tag VL_BYTES, ciphertext VL_BYTES}`). SQLite and Zarr
  fail loud at the boundary; use HDF5 for encrypted files.
- **Attributes** — types accepted by `set_attribute`.
- **Transactions** — supports `begin_transaction` / `commit_transaction`
  / `rollback_transaction`.

## Canonical-bytes parity

Every provider's `StorageDataset.read_canonical_bytes()` produces the
same little-endian byte stream for the same data, regardless of backend
(M43). The canonical form drives signatures and encryption so signed /
encrypted datasets verify identically whichever provider wrote them.

Cross-backend test coverage:

- `python/tests/test_canonical_bytes_cross_backend.py` — HDF5, Memory,
  SQLite.
- `python/tests/test_zarr_provider.py::test_compound_canonical_bytes_matches_hdf5`
  — adds Zarr as the fourth provider.

## URL scheme routing

```python
from ttio.providers import open_provider

# HDF5 (default for bare paths and file:// URLs)
p = open_provider("/path/to/file.tio", mode="r")
p = open_provider("file:///path/to/file.tio", mode="r")

# Memory
p = open_provider("memory://pipeline-state", mode="w")

# SQLite
p = open_provider("sqlite:///path/to/file.db", mode="w")

# Zarr (v0.7 M46)
p = open_provider("zarr:///path/to/store.zarr", mode="w")      # directory
p = open_provider("zarr+memory://scratch", mode="w")           # in-memory
p = open_provider("zarr+s3://bucket/key.zarr", mode="r")       # S3 via fsspec
```

Explicit override via `provider="<name>"` bypasses URL detection.

## v0.7 → v0.8 roadmap

| Provider | Python | Java | ObjC |
|---|---|---|---|
| HDF5 | v0.6 | v0.6 | v0.6 |
| Memory | v0.6 | v0.6 | v0.6 |
| SQLite | v0.7 M41 | v0.7 M41 | v0.7 M41 |
| Zarr | v0.7 M46 | **v0.8 M52** | **v0.8 M52** |

Java and ObjC ZarrProvider ports shipped in v0.8 M52 as
self-contained LocalStore implementations — no external zarr
library dependency. The on-disk layout matches the Python
reference, so all three can cross-read one another's stores
(HANDOFF M52 acceptance). Full cross-language parity matrix
validation happens in M54; M52 ships per-language round-trip tests.

The on-disk format is **Zarr v3** (migrated from v2 in v0.9):
each node is a directory with a single `zarr.json` metadata file
(`node_type` is `"group"` or `"array"`), array chunks live under a
`c/` prefix with one path segment per axis (`c/0/1/2`), and dtypes
use canonical names (`float64`, `int32`, ...) rather than
numpy-style shorthand (`<f8`, `<i4`, ...). zarr-python 3.x writes
this format directly via `LocalStore` / `FsspecStore`.

Scope of the Java + ObjC ZarrProviders:

- URL schemes: `zarr:///abs/path` and bare local paths.
  `zarr+memory://` and `zarr+s3://` remain Python-only.
- Compression: write side emits uncompressed chunks. Read side
  accepts the `gzip` codec entry written by zarr-python's
  `GzipCodec`; other codecs raise.
- Primitive dtypes: float64, float32, int64, int32, uint32
  (little-endian).
- Compound datasets: the Python convention (sub-group +
  `_mpgo_kind="compound"` + `_mpgo_schema` + `_mpgo_rows` JSON
  attrs) is honored verbatim by all three languages.

## Writing a new provider

1. Subclass `StorageProvider`, `StorageGroup`, `StorageDataset` in
   `python/src/ttio/providers/<name>.py`.
2. Add a `[project.entry-points."ttio.providers"]` entry in
   `python/pyproject.toml`.
3. Make `python/tests/test_zarr_provider.py` (or a peer) pass against
   your backend. The contract tests cover group/attribute/primitive/
   compound/N-D round-trips plus canonical-bytes parity.
4. Cross-language parity: once the Python impl is stable, port to
   Java (`java/src/main/java/com/dtwthalion/ttio/providers/`) and
   Objective-C (`objc/Source/Providers/`). Both mirror the Python
   class and method shapes.

See `docs/api-review-v0.7.md` §Appendix B for the Gap items the
abstraction absorbed during M39 → M46.
