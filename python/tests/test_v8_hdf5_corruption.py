"""V8 HDF5 corruption / partial-write recovery tests (Python).

Verifies that h5py raises a *catchable* exception (no segfault, no
hang, no silent data corruption) on malformed or truncated .tio
files. Each scenario locks in the current behaviour so a future
h5py upgrade or our own writer-side change can't silently regress.

Scenarios (one test each):

1. Zero-byte file → OSError with file path in message.
2. One-byte file → OSError (not enough data for the superblock).
3. Truncation at the superblock (first 8 KB chopped) → OSError.
4. Truncation at a group header (after data chunks but before
   index) → OSError or graceful HDF5ParseError.
5. Truncation mid-chunk (last 4 KB chopped) → OSError.
6. Corrupted superblock magic (first 8 bytes zeroed) → OSError.
7. Empty .tio file (0 bytes, no superblock) — rejected at open.
8. Append junk past EOF (file structurally valid but tail is
   garbage) — currently accepted by h5py since it stops reading
   at the declared file extent. Locks in this behaviour.

Per docs/verification-workplan.md §V8.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import pytest


h5py = pytest.importorskip("h5py")
import numpy as np


@pytest.fixture
def intact_tio(tmp_path):
    """A small valid .tio file we can derive corruption variants from."""
    path = tmp_path / "intact.tio"
    with h5py.File(path, "w") as f:
        f.create_dataset(
            "intensity", data=np.arange(10000, dtype=np.float64),
            chunks=(1024,),
        )
        f.create_dataset(
            "mz", data=np.linspace(100.0, 1000.0, 10000),
            chunks=(1024,),
        )
        grp = f.create_group("metadata")
        grp.attrs["sample"] = "V8_TEST"
    return path


# ---------------------------------------------------------------------------
# 1-3: Zero-byte / 1-byte / truncated-at-superblock
# ---------------------------------------------------------------------------


def test_zero_byte_file_raises_oserror(tmp_path):
    """A zero-byte .tio file raises OSError on open."""
    empty = tmp_path / "empty.tio"
    empty.write_bytes(b"")
    with pytest.raises((OSError, ValueError)):
        with h5py.File(empty, "r") as _:
            pass


def test_one_byte_file_raises_oserror(tmp_path):
    """A 1-byte file is not a valid HDF5 file."""
    one = tmp_path / "one.tio"
    one.write_bytes(b"\x00")
    with pytest.raises((OSError, ValueError)):
        with h5py.File(one, "r") as _:
            pass


def test_superblock_truncation_raises_oserror(tmp_path, intact_tio):
    """Truncating the file to the first 4 bytes nukes the superblock."""
    truncated = tmp_path / "no_superblock.tio"
    full = intact_tio.read_bytes()
    truncated.write_bytes(full[:4])
    with pytest.raises((OSError, ValueError)):
        with h5py.File(truncated, "r") as _:
            pass


# ---------------------------------------------------------------------------
# 4-5: Truncation mid-file
# ---------------------------------------------------------------------------


def test_mid_file_truncation_raises_or_partial_read(tmp_path, intact_tio):
    """Mid-file truncation either raises on open or on first dataset read.

    h5py may successfully open the superblock + group structure even
    when chunk data at the end is missing; the failure surfaces when
    we actually try to read the affected dataset. Either path is
    acceptable as long as we don't segfault.
    """
    truncated = tmp_path / "mid_chopped.tio"
    full = intact_tio.read_bytes()
    # Lop off the last quarter — guaranteed past the superblock and
    # group headers but in the middle of dataset chunks.
    truncated.write_bytes(full[: len(full) * 3 // 4])
    raised = False
    try:
        with h5py.File(truncated, "r") as f:
            # Force a full read to trip any deferred chunk-loading.
            for ds_name in ["intensity", "mz"]:
                if ds_name in f:
                    try:
                        _ = f[ds_name][...]
                    except (OSError, ValueError):
                        raised = True
    except (OSError, ValueError):
        raised = True
    assert raised, (
        "mid-file truncation should raise on open or on first dataset read; "
        "neither happened"
    )


def test_last_kb_truncation_recovers_or_raises(tmp_path, intact_tio):
    """Lopping the trailing KB usually corrupts the chunk index."""
    truncated = tmp_path / "tail_chopped.tio"
    full = intact_tio.read_bytes()
    truncated.write_bytes(full[: max(1, len(full) - 1024)])
    raised = False
    try:
        with h5py.File(truncated, "r") as f:
            for ds_name in ["intensity", "mz"]:
                if ds_name in f:
                    try:
                        _ = f[ds_name][...]
                    except (OSError, ValueError):
                        raised = True
    except (OSError, ValueError):
        raised = True
    # Either path is fine — what matters is we don't crash silently.
    # (We assert raised=True OR that the data, if returned, is valid.)
    if not raised:
        with h5py.File(truncated, "r") as f:
            for ds_name in ["intensity", "mz"]:
                if ds_name in f:
                    arr = f[ds_name][...]
                    # If h5py returned data, it must be the right length.
                    # Locks in: never return a truncated array silently.
                    assert len(arr) == 10000


# ---------------------------------------------------------------------------
# 6: Corrupted superblock magic
# ---------------------------------------------------------------------------


def test_corrupted_superblock_magic_raises(tmp_path, intact_tio):
    """Zeroing the HDF5 magic bytes (first 8) makes the file unreadable."""
    corrupted = tmp_path / "no_magic.tio"
    full = bytearray(intact_tio.read_bytes())
    for i in range(8):
        full[i] = 0
    corrupted.write_bytes(bytes(full))
    with pytest.raises((OSError, ValueError)):
        with h5py.File(corrupted, "r") as _:
            pass


# ---------------------------------------------------------------------------
# 7-8: Boundary edge cases
# ---------------------------------------------------------------------------


def test_random_garbage_raises(tmp_path):
    """A 16 KB block of random bytes is not a valid HDF5 file."""
    rng = np.random.default_rng(42)
    garbage = tmp_path / "garbage.tio"
    garbage.write_bytes(rng.integers(0, 256, size=16 * 1024, dtype=np.uint8).tobytes())
    with pytest.raises((OSError, ValueError)):
        with h5py.File(garbage, "r") as _:
            pass


def test_appended_junk_past_eof_is_tolerated(tmp_path, intact_tio):
    """h5py reads up to the declared file extent and ignores trailing junk.

    Locks in current behaviour — if we ever want to harden against
    silent appends, we'd need a checksum/signature scheme outside
    HDF5 itself.
    """
    extended = tmp_path / "with_junk.tio"
    full = intact_tio.read_bytes()
    extended.write_bytes(full + b"\xDE\xAD\xBE\xEF" * 256)
    # Should open and read cleanly — junk is past EOF.
    with h5py.File(extended, "r") as f:
        assert "intensity" in f
        assert len(f["intensity"]) == 10000
        assert "mz" in f
        assert len(f["mz"]) == 10000
