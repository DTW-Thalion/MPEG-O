"""SQLite storage provider — Milestone 41 stress-test of Provisional ABCs.

Stores the full MPEG-O group/dataset tree in a single SQLite file.
Groups and datasets are rows in relational tables; primitive dataset
data is stored as little-endian BLOBs; compound datasets are stored as
JSON arrays of row-dicts.

This implementation deliberately uses no external dependencies beyond
the Python standard library and numpy — sqlite3 ships with CPython.

Schema version: 1
Provider identifier: mpeg_o.providers.sqlite

API status: Provisional (stress-test — not for production use yet).

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

import json
import os
import sqlite3
from typing import Any

import numpy as np

from ..enums import Compression, Precision
from .base import (
    CompoundField,
    CompoundFieldKind,
    StorageDataset,
    StorageGroup,
    StorageProvider,
)

# ---------------------------------------------------------------------------
# SQL schema
# ---------------------------------------------------------------------------

_DDL = """\
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS groups (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id   INTEGER REFERENCES groups(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  UNIQUE(parent_id, name)
);

CREATE TABLE IF NOT EXISTS datasets (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id         INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  name             TEXT NOT NULL,
  kind             TEXT NOT NULL CHECK(kind IN ('primitive','compound')),
  precision        TEXT,
  shape_json       TEXT NOT NULL,
  data             BLOB,
  compound_fields  TEXT,
  compound_rows    TEXT,
  UNIQUE(group_id, name)
);

CREATE TABLE IF NOT EXISTS group_attributes (
  group_id    INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  value_type  TEXT NOT NULL CHECK(value_type IN ('string','int','float')),
  value       TEXT NOT NULL,
  PRIMARY KEY (group_id, name)
);

CREATE TABLE IF NOT EXISTS dataset_attributes (
  dataset_id  INTEGER NOT NULL REFERENCES datasets(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  value_type  TEXT NOT NULL CHECK(value_type IN ('string','int','float')),
  value       TEXT NOT NULL,
  PRIMARY KEY (dataset_id, name)
);

CREATE TABLE IF NOT EXISTS meta (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_datasets_group ON datasets(group_id);
CREATE INDEX IF NOT EXISTS idx_ga_group ON group_attributes(group_id);
CREATE INDEX IF NOT EXISTS idx_da_dataset ON dataset_attributes(dataset_id);
"""

_META_INSERTS = """\
INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '1');
INSERT OR REPLACE INTO meta (key, value) VALUES ('provider', 'mpeg_o.providers.sqlite');
"""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Map Precision enum value name → numpy little-endian dtype string
_PRECISION_NAME: dict[str, Precision] = {p.name: p for p in Precision}


def _pack(array: np.ndarray, precision: Precision) -> bytes:
    """Serialize array to little-endian bytes."""
    dtype = precision.numpy_dtype()
    return np.ascontiguousarray(array, dtype=dtype).tobytes()


def _unpack(blob: bytes, precision: Precision,
            shape: tuple[int, ...]) -> np.ndarray:
    """Deserialize little-endian bytes to shaped numpy array."""
    dtype = precision.numpy_dtype()
    arr = np.frombuffer(blob, dtype=dtype)
    if shape and len(shape) > 1:
        arr = arr.reshape(shape)
    return arr


def _encode_attr(value: Any) -> tuple[str, str]:
    """Return (value_type, str_value) for storage."""
    if isinstance(value, bool):
        # bool is a subclass of int — check first
        return ("int", str(int(value)))
    if isinstance(value, int):
        return ("int", str(value))
    if isinstance(value, float):
        return ("float", repr(value))
    return ("string", str(value))


def _decode_attr(value_type: str, value: str) -> Any:
    if value_type == "int":
        return int(value)
    if value_type == "float":
        return float(value)
    return value


def _fields_to_json(fields: list[CompoundField]) -> str:
    return json.dumps([{"name": f.name, "kind": f.kind.value} for f in fields])


def _fields_from_json(s: str) -> tuple[CompoundField, ...]:
    raw = json.loads(s)
    return tuple(
        CompoundField(name=r["name"], kind=CompoundFieldKind(r["kind"]))
        for r in raw
    )


# ---------------------------------------------------------------------------
# SqliteDataset
# ---------------------------------------------------------------------------

class SqliteDataset(StorageDataset):
    """A dataset row backed by a SQLite ``datasets`` table entry.

    Primitive datasets store data as a little-endian BLOB.
    Compound datasets store rows as a JSON array of dicts.
    """

    def __init__(self, conn: sqlite3.Connection, dataset_id: int,
                 name: str, precision: Precision | None,
                 shape: tuple[int, ...],
                 fields: tuple[CompoundField, ...] | None,
                 read_only: bool = False) -> None:
        self._conn = conn
        self._dataset_id = dataset_id
        self._name = name
        self._precision = precision
        self._shape = shape
        self._fields = fields
        self._read_only = read_only

    # ── Type and shape ──────────────────────────────────────────────────

    @property
    def name(self) -> str:
        return self._name

    @property
    def precision(self) -> Precision | None:
        return self._precision

    @property
    def shape(self) -> tuple[int, ...]:
        return self._shape

    @property
    def chunks(self) -> tuple[int, ...] | None:
        # SQLite stores everything contiguous — no chunking concept.
        return None

    @property
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        return self._fields

    # ── Read / write ────────────────────────────────────────────────────

    def read(self, offset: int = 0, count: int = -1) -> np.ndarray:
        """Read ``count`` elements starting at ``offset``.

        For primitive datasets returns a numpy array.
        For compound datasets returns a list of dicts (not a structured
        ndarray) — the provider stores JSON, not numpy-structured bytes,
        so a full structured ndarray cannot be reconstructed without the
        full round-trip encoding overhead.  This is an **interface gap**
        noted in the report.
        """
        if self._fields is not None:
            # Compound: load JSON rows, slice
            row = self._conn.execute(
                "SELECT compound_rows FROM datasets WHERE id = ?",
                (self._dataset_id,)
            ).fetchone()
            rows: list[dict] = json.loads(row[0]) if row and row[0] else []
            if count < 0:
                return rows[offset:]      # type: ignore[return-value]
            return rows[offset: offset + count]  # type: ignore[return-value]
        # Primitive
        row = self._conn.execute(
            "SELECT data FROM datasets WHERE id = ?",
            (self._dataset_id,)
        ).fetchone()
        if not row or row[0] is None:
            # Empty dataset
            dtype = np.dtype(self._precision.numpy_dtype())  # type: ignore[union-attr]
            return np.zeros(0, dtype=dtype)
        arr = _unpack(bytes(row[0]), self._precision, self._shape)  # type: ignore[arg-type]
        if len(self._shape) > 1:
            if count < 0:
                return arr[offset:]
            return arr[offset: offset + count]
        if count < 0:
            return arr[offset:]
        return arr[offset: offset + count]

    def write(self, data: Any) -> None:
        """Write the full dataset.

        For primitive datasets, ``data`` must be array-like; for compound
        datasets, ``data`` must be a list of dicts.
        """
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        if self._fields is not None:
            # Compound
            serialized = json.dumps(data)
            self._conn.execute(
                "UPDATE datasets SET compound_rows = ? WHERE id = ?",
                (serialized, self._dataset_id),
            )
        else:
            # Primitive
            arr = np.asarray(data)
            blob = _pack(arr, self._precision)  # type: ignore[arg-type]
            # Update shape in case caller passed differently-shaped data
            self._conn.execute(
                "UPDATE datasets SET data = ?, shape_json = ? WHERE id = ?",
                (blob, json.dumps(list(arr.shape)), self._dataset_id),
            )
            self._shape = tuple(arr.shape)
        self._conn.commit()

    # ── Attributes ──────────────────────────────────────────────────────

    def has_attribute(self, name: str) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM dataset_attributes WHERE dataset_id = ? AND name = ?",
            (self._dataset_id, name),
        ).fetchone()
        return row is not None

    def get_attribute(self, name: str) -> Any:
        row = self._conn.execute(
            "SELECT value_type, value FROM dataset_attributes "
            "WHERE dataset_id = ? AND name = ?",
            (self._dataset_id, name),
        ).fetchone()
        if row is None:
            raise KeyError(f"attribute '{name}' not found on dataset '{self._name}'")
        return _decode_attr(row[0], row[1])

    def set_attribute(self, name: str, value: Any) -> None:
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        vtype, vstr = _encode_attr(value)
        self._conn.execute(
            "INSERT OR REPLACE INTO dataset_attributes "
            "(dataset_id, name, value_type, value) VALUES (?, ?, ?, ?)",
            (self._dataset_id, name, vtype, vstr),
        )
        self._conn.commit()

    def attribute_names(self) -> list[str]:
        rows = self._conn.execute(
            "SELECT name FROM dataset_attributes WHERE dataset_id = ? ORDER BY name",
            (self._dataset_id,),
        ).fetchall()
        return [r[0] for r in rows]

    def delete_attribute(self, name: str) -> None:
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        self._conn.execute(
            "DELETE FROM dataset_attributes WHERE dataset_id = ? AND name = ?",
            (self._dataset_id, name),
        )
        self._conn.commit()

    def close(self) -> None:
        """No-op — connection is owned by the provider."""
        return None


# ---------------------------------------------------------------------------
# SqliteGroup
# ---------------------------------------------------------------------------

class SqliteGroup(StorageGroup):
    """A row in the ``groups`` table, exposed as a StorageGroup."""

    def __init__(self, conn: sqlite3.Connection, group_id: int,
                 name: str, read_only: bool = False) -> None:
        self._conn = conn
        self._group_id = group_id
        self._name = name
        self._read_only = read_only

    # ── Identity ────────────────────────────────────────────────────────

    @property
    def name(self) -> str:
        return self._name

    # ── Children ────────────────────────────────────────────────────────

    def child_names(self) -> list[str]:
        groups = self._conn.execute(
            "SELECT name FROM groups WHERE parent_id = ? ORDER BY name",
            (self._group_id,),
        ).fetchall()
        datasets = self._conn.execute(
            "SELECT name FROM datasets WHERE group_id = ? ORDER BY name",
            (self._group_id,),
        ).fetchall()
        return [r[0] for r in groups] + [r[0] for r in datasets]

    def has_child(self, name: str) -> bool:
        g = self._conn.execute(
            "SELECT 1 FROM groups WHERE parent_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        if g:
            return True
        d = self._conn.execute(
            "SELECT 1 FROM datasets WHERE group_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        return d is not None

    def open_group(self, name: str) -> "SqliteGroup":
        row = self._conn.execute(
            "SELECT id FROM groups WHERE parent_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        if row is None:
            raise KeyError(
                f"group '{name}' not found in '{self._name}'"
            )
        return SqliteGroup(self._conn, row[0], name, self._read_only)

    def create_group(self, name: str) -> "SqliteGroup":
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        if self.has_child(name):
            raise ValueError(
                f"'{name}' already exists in '{self._name}'"
            )
        cur = self._conn.execute(
            "INSERT INTO groups (parent_id, name) VALUES (?, ?)",
            (self._group_id, name),
        )
        self._conn.commit()
        return SqliteGroup(self._conn, cur.lastrowid, name, self._read_only)

    def delete_child(self, name: str) -> None:
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        # Try groups first (CASCADE handles descendants + attrs)
        row = self._conn.execute(
            "SELECT id FROM groups WHERE parent_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        if row:
            self._conn.execute("DELETE FROM groups WHERE id = ?", (row[0],))
            self._conn.commit()
            return
        # Try datasets
        row = self._conn.execute(
            "SELECT id FROM datasets WHERE group_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        if row:
            self._conn.execute("DELETE FROM datasets WHERE id = ?", (row[0],))
            self._conn.commit()

    # ── Datasets ────────────────────────────────────────────────────────

    def open_dataset(self, name: str) -> SqliteDataset:
        row = self._conn.execute(
            "SELECT id, kind, precision, shape_json, compound_fields "
            "FROM datasets WHERE group_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        if row is None:
            raise KeyError(
                f"dataset '{name}' not found in '{self._name}'"
            )
        ds_id, kind, prec_name, shape_json, fields_json = row
        precision = _PRECISION_NAME[prec_name] if prec_name else None
        shape = tuple(json.loads(shape_json))
        fields = _fields_from_json(fields_json) if fields_json else None
        return SqliteDataset(self._conn, ds_id, name, precision, shape,
                             fields, self._read_only)

    def create_dataset(self, name: str, precision: Precision,
                       length: int, *,
                       chunk_size: int = 0,
                       compression: Compression = Compression.NONE,
                       compression_level: int = 6) -> SqliteDataset:
        # chunk_size / compression are silently accepted but ignored —
        # SQLite has no native chunk/filter pipeline.
        del chunk_size, compression, compression_level
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        shape_json = json.dumps([length])
        cur = self._conn.execute(
            "INSERT INTO datasets "
            "(group_id, name, kind, precision, shape_json, data) "
            "VALUES (?, ?, 'primitive', ?, ?, NULL)",
            (self._group_id, name, precision.name, shape_json),
        )
        self._conn.commit()
        return SqliteDataset(self._conn, cur.lastrowid, name, precision,
                             (length,), None, self._read_only)

    def create_dataset_nd(self, name: str, precision: Precision,
                           shape: tuple[int, ...], *,
                           chunks: tuple[int, ...] | None = None,
                           compression: Compression = Compression.NONE,
                           compression_level: int = 6) -> SqliteDataset:
        del chunks, compression, compression_level
        if len(shape) == 1:
            return self.create_dataset(name, precision, shape[0])
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        shape_json = json.dumps(list(shape))
        cur = self._conn.execute(
            "INSERT INTO datasets "
            "(group_id, name, kind, precision, shape_json, data) "
            "VALUES (?, ?, 'primitive', ?, ?, NULL)",
            (self._group_id, name, precision.name, shape_json),
        )
        self._conn.commit()
        return SqliteDataset(self._conn, cur.lastrowid, name, precision,
                             tuple(shape), None, self._read_only)

    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> SqliteDataset:
        if self.has_child(name):
            raise ValueError(f"'{name}' already exists in '{self._name}'")
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        fields_json = _fields_to_json(fields)
        shape_json = json.dumps([count])
        cur = self._conn.execute(
            "INSERT INTO datasets "
            "(group_id, name, kind, precision, shape_json, "
            " compound_fields, compound_rows) "
            "VALUES (?, ?, 'compound', NULL, ?, ?, '[]')",
            (self._group_id, name, shape_json, fields_json),
        )
        self._conn.commit()
        return SqliteDataset(self._conn, cur.lastrowid, name, None,
                             (count,), tuple(fields), self._read_only)

    # ── Attributes ──────────────────────────────────────────────────────

    def has_attribute(self, name: str) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM group_attributes WHERE group_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        return row is not None

    def get_attribute(self, name: str) -> Any:
        row = self._conn.execute(
            "SELECT value_type, value FROM group_attributes "
            "WHERE group_id = ? AND name = ?",
            (self._group_id, name),
        ).fetchone()
        if row is None:
            raise KeyError(
                f"attribute '{name}' not found on group '{self._name}'"
            )
        return _decode_attr(row[0], row[1])

    def set_attribute(self, name: str, value: Any) -> None:
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        vtype, vstr = _encode_attr(value)
        self._conn.execute(
            "INSERT OR REPLACE INTO group_attributes "
            "(group_id, name, value_type, value) VALUES (?, ?, ?, ?)",
            (self._group_id, name, vtype, vstr),
        )
        self._conn.commit()

    def delete_attribute(self, name: str) -> None:
        if self._read_only:
            raise IOError("provider opened in read-only mode")
        self._conn.execute(
            "DELETE FROM group_attributes WHERE group_id = ? AND name = ?",
            (self._group_id, name),
        )
        self._conn.commit()

    def attribute_names(self) -> list[str]:
        rows = self._conn.execute(
            "SELECT name FROM group_attributes WHERE group_id = ? ORDER BY name",
            (self._group_id,),
        ).fetchall()
        return [r[0] for r in rows]

    def close(self) -> None:
        """No-op — connection is owned by the provider."""
        return None


# ---------------------------------------------------------------------------
# SqliteProvider
# ---------------------------------------------------------------------------

class SqliteProvider(StorageProvider):
    """SQLite-backed storage provider.

    Each MPEG-O file is a single ``.mpgo.sqlite`` SQLite database.

    Usage::

        p = SqliteProvider()
        p.open("/path/to/data.mpgo.sqlite", mode="w")
        root = p.root_group()
        ...
        p.close()

    Or as a context manager::

        with SqliteProvider.open("/path/to/data.mpgo.sqlite", mode="r") as p:
            ...

    URL form ``sqlite:///abs/path/to/data.mpgo.sqlite`` is also
    accepted by :meth:`open`.

    API status: Provisional (stress-test).
    SPDX-License-Identifier: LGPL-3.0-or-later
    """

    def __init__(self) -> None:
        self._conn: sqlite3.Connection | None = None
        self._path: str | None = None
        self._read_only: bool = False

    # ── Open / close ────────────────────────────────────────────────────

    def open(self_or_path, path_or_url=None, *, mode: str = "r",  # type: ignore[override]
             **kwargs) -> "SqliteProvider":
        """Open or create a SQLite backing store.

        Supports two call styles:

        *Instance style* (mutates self, return value = self)::

            p = SqliteProvider()
            p.open("/path/to/data.mpgo.sqlite", mode="w")

        *Class style* (creates new instance)::

            p = SqliteProvider.open("/path/to/data.mpgo.sqlite", mode="w")

        ``mode`` semantics:

        * ``"r"``        — read-only; file must exist.
        * ``"r+"``/``"rw"`` — read/write; file must exist.
        * ``"w"``        — create or truncate.
        * ``"a"``        — read/write; create if absent.

        Implementation note: per Appendix B Gap 1, this method
        intentionally does NOT use ``@classmethod`` so that the
        instance-mutating call style works. When called as
        ``SqliteProvider.open(path)``, Python passes the path string as
        the first positional argument; we detect this via ``isinstance``
        and construct a new instance accordingly.
        """
        del kwargs
        if isinstance(self_or_path, SqliteProvider):
            # Called as bound instance method: p.open(path, mode=...)
            instance: SqliteProvider = self_or_path
            actual_path = path_or_url
        else:
            # Called as unbound / class call: SqliteProvider.open(path, mode=...)
            # self_or_path IS the path string in this case.
            instance = SqliteProvider.__new__(SqliteProvider)
            SqliteProvider.__init__(instance)
            actual_path = self_or_path

        if actual_path is None:
            raise TypeError("open() requires a path argument")

        instance._do_open(actual_path, mode=mode)
        return instance

    def _do_open(self, path_or_url: str, *, mode: str = "r") -> None:
        """Internal: connect to SQLite file, apply PRAGMAs and DDL."""
        path = _resolve_path(path_or_url)
        read_only = mode == "r"

        if mode == "r":
            if not os.path.exists(path):
                raise FileNotFoundError(
                    f"SQLite file not found (mode='r'): {path}"
                )
            conn = sqlite3.connect(path)
            conn.execute("PRAGMA foreign_keys = ON")
        elif mode in ("r+", "rw"):
            if not os.path.exists(path):
                raise FileNotFoundError(
                    f"SQLite file not found (mode='{mode}'): {path}"
                )
            conn = sqlite3.connect(path)
            _init_db(conn)
        elif mode == "w":
            # Create or truncate
            if os.path.exists(path):
                os.remove(path)
            conn = sqlite3.connect(path)
            _init_db(conn)
        elif mode == "a":
            conn = sqlite3.connect(path)
            _init_db(conn)
        else:
            raise ValueError(f"unknown mode: {mode!r}")

        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = NORMAL")

        self._conn = conn
        self._path = path
        self._read_only = read_only

    def close(self) -> None:
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    # ── StorageProvider contract ─────────────────────────────────────────

    def provider_name(self) -> str:
        return "sqlite"

    def is_open(self) -> bool:
        return self._conn is not None

    def root_group(self) -> SqliteGroup:
        if self._conn is None:
            raise IOError("provider is not open")
        row = self._conn.execute(
            "SELECT id FROM groups WHERE parent_id IS NULL AND name = '/'",
        ).fetchone()
        if row is None:
            raise RuntimeError("root group '/' missing from SQLite store")
        return SqliteGroup(self._conn, row[0], "/", self._read_only)

    def native_handle(self) -> sqlite3.Connection | None:
        """Return the raw ``sqlite3.Connection``. Escape hatch."""
        return self._conn

    # ── Transactions (Appendix B Gap 11) ─────────────────────────

    def begin_transaction(self) -> None:
        if self._conn is None:
            raise IOError("provider is not open")
        self._conn.execute("BEGIN")

    def commit_transaction(self) -> None:
        if self._conn is None:
            raise IOError("provider is not open")
        self._conn.commit()

    def rollback_transaction(self) -> None:
        if self._conn is None:
            raise IOError("provider is not open")
        self._conn.rollback()

    @staticmethod
    def supports_url(url: str) -> bool:
        """Return True for ``sqlite://`` URLs and recognised file extensions."""
        if url.startswith("sqlite://"):
            return True
        lower = url.lower()
        return lower.endswith(".mpgo.sqlite") or lower.endswith(".sqlite")

    def __repr__(self) -> str:
        state = f"path={self._path!r}" if self._path else "closed"
        return f"SqliteProvider({state})"


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

def _resolve_path(path_or_url: str) -> str:
    """Strip ``sqlite://`` prefix; return bare filesystem path."""
    if path_or_url.startswith("sqlite://"):
        return path_or_url[len("sqlite://"):]
    return path_or_url


def _init_db(conn: sqlite3.Connection) -> None:
    """Apply DDL and ensure root group exists."""
    conn.executescript(_DDL)
    conn.executescript(_META_INSERTS)
    # Ensure root group
    conn.execute(
        "INSERT OR IGNORE INTO groups (parent_id, name) VALUES (NULL, '/')"
    )
    conn.commit()
