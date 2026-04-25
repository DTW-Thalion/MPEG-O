"""Cloud-native ``.tio`` access via fsspec (Milestone 20).

The remote path is deliberately thin: ``fsspec.open(url, "rb")`` returns
a seekable byte stream that supports HTTP range requests (for
``http://`` / ``https://``) or equivalent partial reads for ``s3://``,
``gs://``, and ``az://``. That stream is handed straight to
``h5py.File`` in read-only mode, which then reads only the chunks it
needs as the caller touches datasets — HDF5's own chunking +
random-access semantics carry the rest.

The benefit is that **opening a remote file transfers only the HDF5
metadata and the spectrum index** (a few kilobytes per run), not the
entire signal payload. Individual spectrum reads pull down at most one
HDF5 chunk per channel (16 KiB by default).

``SpectralDataset.open`` detects URL schemes via :func:`is_remote_url`
and routes through :func:`open_remote_file` when the target is not a
local path. Callers can also invoke the remote helper directly when
they need tight control over the fsspec options.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import urlparse


# Schemes that should be routed through fsspec. ``file`` is listed so
# callers can test the remote code path with a local URL (the test suite
# relies on this). Every scheme here either ships with fsspec's built-in
# implementations or is contributed by an ``[project.optional-dependencies].cloud``
# dependency (``s3fs``, ``gcsfs``, ``adlfs``, ``aiohttp``).
REMOTE_SCHEMES = frozenset({
    "file",
    "http", "https",
    "s3",
    "gs", "gcs",
    "az", "abfs", "abfss",
})


def is_remote_url(target: str | Path) -> bool:
    """Return ``True`` if ``target`` should be opened via fsspec.

    ``Path`` instances and plain relative paths always go through the
    local filesystem. Anything with a recognised scheme in
    :data:`REMOTE_SCHEMES` is treated as remote.
    """
    if isinstance(target, Path):
        return False
    if not isinstance(target, str):
        return False
    parsed = urlparse(target)
    if not parsed.scheme:
        return False
    # Windows drive letters parse as a single-char scheme ("c", "d", ...).
    if len(parsed.scheme) == 1:
        return False
    return parsed.scheme.lower() in REMOTE_SCHEMES


def open_remote_file(url: str, **fsspec_kwargs: Any):  # type: ignore[no-untyped-def]
    """Open a file-like object for ``url`` suitable for ``h5py.File``.

    The returned object is the raw fsspec file handle (not an
    ``AbstractContextManager``) so the caller can hand it directly to
    :class:`h5py.File` and the dataset wrapper can ``.close()`` both
    when it goes out of scope. ``fsspec_kwargs`` are forwarded to
    :func:`fsspec.open`.
    """
    try:
        import fsspec
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "Remote .tio access requires the 'cloud' optional dependency; "
            "install with 'pip install ttio[cloud]'"
        ) from exc
    opener = fsspec.open(url, mode="rb", **fsspec_kwargs)
    return opener.open()
