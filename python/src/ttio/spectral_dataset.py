"""``SpectralDataset`` — root ``.tio`` reader / writer façade.

This class is the main public entry point. It owns the underlying
``h5py.File`` handle, provides mapping-style access to runs, and exposes the
feature-flag / identifications / quantifications / provenance metadata.

Only reading and minimal writing are implemented in M16. Full writing
support (feature flags, compound datasets, signal channels for new runs)
uses the same helpers in :mod:`_hdf5_io` and is fleshed out alongside the
mzML/nmrML importers in M16.7.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from types import TracebackType
from typing import Any, Iterator, Mapping

import h5py
import numpy as np

from . import _hdf5_io as io
from ._rwlock import RWLock
from .access_policy import AccessPolicy
from .acquisition_run import AcquisitionRun
from .genomic_run import GenomicRun  # M82
from .enums import EncryptionLevel
from .feature_flags import FeatureFlags
from .identification import Identification
from .providers import StorageProvider, open_provider
from .providers.base import StorageGroup
from .providers.hdf5 import Hdf5Provider
from .provenance import ProvenanceRecord
from .quantification import Quantification
from .written_genomic_run import WrittenGenomicRun  # M82

# M23 sentinel: returned by ``read_lock``/``write_lock`` when ``thread_safe``
# is False so call sites can use ``with ds.read_lock(): ...`` unconditionally.
class _NullGuard:
    def __enter__(self) -> "_NullGuard":
        return self

    def __exit__(self, *exc: object) -> None:
        return None


_NULL_GUARD = _NullGuard()


def _split_run_names(value: str | None) -> tuple[str, ...]:
    if not value:
        return ()
    return tuple(name for name in value.split(",") if name)


@dataclass(slots=True)
class SpectralDataset:
    """Root container for an TTI-O ``.tio`` file.

    Owns a top-level ``study/`` group plus zero or more named MS
    acquisition runs, zero or more named NMR-spectrum collections,
    the dataset-wide identifications, quantifications, provenance
    records, and an optional transition list.

    Persistence uses a
    :class:`~ttio.providers.base.StorageProvider` (HDF5 by
    default); callers may supply another via the ``provider`` kwarg.

    Notes
    -----
    API status: Stable. ``Encryptable`` conformance is delivered in
    slice 41.5 when the encryption manager lands in Python.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOSpectralDataset`` · Java:
    ``global.thalion.ttio.SpectralDataset``.
    """

    path: Path
    # ``file`` is the legacy h5py handle. v0.9 M64.5: when the dataset
    # was opened via a non-HDF5 provider (memory/sqlite/zarr) this is
    # ``None`` and call sites must use :attr:`provider` instead. New
    # code paths route through the StorageGroup protocol.
    file: h5py.File | None
    feature_flags: FeatureFlags
    title: str
    isa_investigation_id: str
    ms_runs: dict[str, AcquisitionRun] = field(default_factory=dict)
    nmr_runs: dict[str, AcquisitionRun] = field(default_factory=dict)
    genomic_runs: dict[str, GenomicRun] = field(default_factory=dict)  # M82
    encrypted_algorithm: str = ""
    _closed: bool = False
    _remote_fileobj: Any = None  # fsspec file-like kept alive when remote
    _lock: RWLock | None = None  # M23: set when opened with thread_safe=True
    provider: StorageProvider | None = None  # M39: owning storage provider
    # ``provider`` is the backend abstraction introduced in M39. ``file``
    # remains the canonical h5py handle for byte-level code (signatures,
    # encryption, signal-channel codecs) that isn't expressed through the
    # protocol; it is the provider's native handle when ``provider`` is
    # set. New call sites should reach for ``provider.root_group()`` or
    # ``provider.native_handle()`` instead of ``file`` directly.
    # M41.5: Encryptable conformance.
    _access_policy: AccessPolicy | None = field(default=None, repr=False)

    # ------------------------------------------------------------- lifecycle

    @classmethod
    def open(
        cls,
        path: str | Path,
        *,
        provider: str | None = None,
        thread_safe: bool = False,
        writable: bool = False,
        **fsspec_kwargs: Any,
    ) -> "SpectralDataset":
        """Open a ``.tio`` dataset from a local path or cloud URL.

        URLs with a scheme recognised by :data:`ttio.remote.REMOTE_SCHEMES`
        (``s3://``, ``http(s)://``, ``gs://``, ``az://``, ``file://``) are
        routed through fsspec and read lazily — only the HDF5 metadata and
        any actively touched chunks are fetched. Extra keyword arguments are
        forwarded to :func:`fsspec.open` and are typically used for
        cloud-backend options (``anon=True``, ``key=...``, ...).

        Parameters
        ----------
        writable:
            If ``True``, open the file in read-write mode (``"r+"``) so
            that in-place operations such as
            :meth:`AcquisitionRun.encrypt_with_key` can write back to the
            same file handle. Ignored for remote URLs (which are always
            read-only). Default: ``False``.

        M39: a :class:`~ttio.providers.Hdf5Provider` is constructed for
        the target and exposed as ``dataset.provider``. The legacy
        ``dataset.file`` attribute continues to point at the underlying
        ``h5py.File`` (= ``provider.native_handle()``).
        """
        from .remote import is_remote_url, open_remote_file

        if is_remote_url(path):
            fileobj = open_remote_file(str(path), **fsspec_kwargs)
            try:
                f = h5py.File(fileobj, "r")
            except Exception:
                fileobj.close()
                raise
            try:
                provider = Hdf5Provider(f)
                return cls._from_open_file(Path(str(path)), f,
                                           remote_fileobj=fileobj,
                                           thread_safe=thread_safe,
                                           provider=provider)
            except Exception:
                f.close()
                fileobj.close()
                raise

        # v0.9 M64.5: URL scheme detection routes non-HDF5 providers
        # (``memory://...``, ``sqlite://...``, ``dir://...``) through
        # the storage protocol. Bare paths still open via HDF5 for
        # byte-parity with pre-M64.5 files.
        path_str = str(path)
        mode = "r+" if writable else "r"
        if "://" in path_str and not path_str.startswith("file://"):
            provider = open_provider(path_str, mode=mode)
            try:
                return cls._from_provider(Path(path_str), provider,
                                           thread_safe=thread_safe)
            except Exception:
                provider.close()
                raise

        p = Path(path)
        # M82: if an explicit provider name is given for a bare path, route
        # through open_provider so Memory / SQLite / Zarr backends work.
        if provider is not None and provider not in ("hdf5", "h5", "h5py"):
            sp = open_provider(str(path), provider=provider, mode=mode)
            try:
                return cls._from_provider(p, sp, thread_safe=thread_safe)
            except Exception:
                sp.close()
                raise
        provider = Hdf5Provider.open(str(p), mode=mode)
        f = provider.native_handle()
        try:
            return cls._from_open_file(p, f, thread_safe=thread_safe,
                                         provider=provider)
        except Exception:
            provider.close()
            raise

    @classmethod
    def _from_provider(
        cls,
        path: Path,
        provider: StorageProvider,
        *,
        thread_safe: bool = False,
    ) -> "SpectralDataset":
        """Open-side constructor for non-HDF5 providers.

        Reads everything through the :class:`StorageGroup` protocol so
        Memory / SQLite / Zarr backends work without touching h5py.
        """
        root = provider.root_group()
        version, features = io.read_feature_flags(root)
        flags = FeatureFlags.from_iterable(version, features)
        encrypted = io.read_string_attr(root, "encrypted", default="") or ""
        if not root.has_child("study"):
            raise ValueError(f"{path}: missing /study group; not an .tio file")
        study = root.open_group("study")
        title = io.read_string_attr(study, "title", default="") or ""
        isa = io.read_string_attr(study, "isa_investigation_id", default="") or ""

        ms_runs: dict[str, AcquisitionRun] = {}
        if study.has_child("ms_runs"):
            ms_group = study.open_group("ms_runs")
            names = _split_run_names(
                io.read_string_attr(ms_group, "_run_names", default="") or ""
            )
            for name in names:
                if ms_group.has_child(name):
                    run = AcquisitionRun.open(ms_group.open_group(name), name)
                    run._set_persistence_context(str(path), name)
                    ms_runs[name] = run

        nmr_runs: dict[str, AcquisitionRun] = {}
        if study.has_child("nmr_runs"):
            nmr_group = study.open_group("nmr_runs")
            names = _split_run_names(
                io.read_string_attr(nmr_group, "_run_names", default="") or ""
            )
            for name in names:
                if nmr_group.has_child(name):
                    run = AcquisitionRun.open(nmr_group.open_group(name), name)
                    run._set_persistence_context(str(path), name)
                    nmr_runs[name] = run

        genomic_runs_map: dict[str, GenomicRun] = {}  # M82
        if study.has_child("genomic_runs"):
            g_group = study.open_group("genomic_runs")
            names = _split_run_names(
                io.read_string_attr(g_group, "_run_names", default="") or ""
            )
            for name in names:
                if g_group.has_child(name):
                    genomic_runs_map[name] = GenomicRun.open(g_group.open_group(name), name)

        return cls(
            path=path,
            file=None,  # non-HDF5 providers don't expose h5py.File
            feature_flags=flags,
            title=title,
            isa_investigation_id=isa,
            ms_runs=ms_runs,
            nmr_runs=nmr_runs,
            genomic_runs=genomic_runs_map,  # M82
            encrypted_algorithm=encrypted,
            _remote_fileobj=None,
            _lock=(RWLock() if thread_safe else None),
            provider=provider,
        )

    @classmethod
    def _from_open_file(
        cls,
        path: Path,
        f: h5py.File,
        remote_fileobj: Any = None,
        thread_safe: bool = False,
        provider: StorageProvider | None = None,
    ) -> "SpectralDataset":
        version, features = io.read_feature_flags(f)
        flags = FeatureFlags.from_iterable(version, features)
        encrypted = io.read_string_attr(f, "encrypted", default="") or ""

        if "study" not in f:
            raise ValueError(f"{path}: missing /study group; not a v0.2+ .tio file")
        study = f["study"]

        title = io.read_string_attr(study, "title", default="") or ""
        isa = io.read_string_attr(study, "isa_investigation_id", default="") or ""

        # Resolve the canonical file path for the persistence context that
        # enables AcquisitionRun.encrypt_with_key / decrypt_with_key.
        file_path = str(path)

        ms_runs: dict[str, AcquisitionRun] = {}
        if "ms_runs" in study:
            ms_group = study["ms_runs"]
            names = _split_run_names(io.read_string_attr(ms_group, "_run_names", default=""))
            for name in names:
                if name in ms_group:
                    run = AcquisitionRun.open(ms_group[name], name)
                    run._set_persistence_context(file_path, name)
                    ms_runs[name] = run

        nmr_runs: dict[str, AcquisitionRun] = {}
        if "nmr_runs" in study:
            nmr_group = study["nmr_runs"]
            names = _split_run_names(io.read_string_attr(nmr_group, "_run_names", default=""))
            for name in names:
                if name in nmr_group:
                    run = AcquisitionRun.open(nmr_group[name], name)
                    run._set_persistence_context(file_path, name)
                    nmr_runs[name] = run

        genomic_runs_map: dict[str, GenomicRun] = {}  # M82
        if "genomic_runs" in study:
            g_group = study["genomic_runs"]
            names = _split_run_names(io.read_string_attr(g_group, "_run_names", default=""))
            for name in names:
                if name in g_group:
                    genomic_runs_map[name] = GenomicRun.open(g_group[name], name)

        return cls(
            path=path,
            file=f,
            feature_flags=flags,
            title=title,
            isa_investigation_id=isa,
            ms_runs=ms_runs,
            nmr_runs=nmr_runs,
            genomic_runs=genomic_runs_map,  # M82
            encrypted_algorithm=encrypted,
            _remote_fileobj=remote_fileobj,
            _lock=(RWLock() if thread_safe else None),
            provider=provider,
        )

    # ----------------------------------------------------- thread safety (M23)

    @property
    def is_thread_safe(self) -> bool:
        """True iff this dataset was opened with ``thread_safe=True``."""
        return self._lock is not None

    def read_lock(self) -> Any:
        """Context manager acquiring the shared read lock.

        A no-op when ``thread_safe`` was not set at open time, so call sites
        can use ``with ds.read_lock(): ...`` unconditionally.
        """
        return self._lock.read() if self._lock is not None else _NULL_GUARD

    def write_lock(self) -> Any:
        """Context manager acquiring the exclusive write lock (no-op when
        ``thread_safe`` was not set at open time)."""
        return self._lock.write() if self._lock is not None else _NULL_GUARD

    def close(self) -> None:
        with self.write_lock():
            if not self._closed:
                # Close via the provider when we have one — it owns the
                # h5py.File and any fsspec file-like. Fall back to direct
                # close for legacy instances constructed without M39.
                if self.provider is not None:
                    self.provider.close()
                else:
                    self.file.close()
                if self._remote_fileobj is not None:
                    try:
                        self._remote_fileobj.close()
                    except Exception:
                        pass
                    self._remote_fileobj = None
                self._closed = True

    def __enter__(self) -> "SpectralDataset":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    # --------------------------------------------------------------- queries

    @property
    def is_encrypted(self) -> bool:
        return bool(self.encrypted_algorithm)

    @property
    def all_runs(self) -> Mapping[str, AcquisitionRun]:
        """Union of MS and NMR runs, keyed by run name."""
        merged: dict[str, AcquisitionRun] = dict(self.ms_runs)
        for k, v in self.nmr_runs.items():
            merged.setdefault(k, v)
        return merged

    def _study_target(self) -> Any:
        """Return the IO target representing ``/study``.

        For HDF5-backed datasets this is the raw ``h5py.Group``; for
        provider-backed datasets it is a :class:`StorageGroup`. The
        helpers in :mod:`_hdf5_io` accept either form.
        """
        if self.file is not None:
            return self.file["study"]
        assert self.provider is not None  # invariant: file or provider is set
        return self.provider.root_group().open_group("study")

    def _study_has_child(self, name: str) -> bool:
        if self.file is not None:
            return name in self.file["study"]
        assert self.provider is not None
        return self.provider.root_group().open_group("study").has_child(name)

    def identifications(self) -> list[Identification]:
        with self.read_lock():
            study = self._study_target()
            if self._study_has_child("identifications"):
                return [
                    Identification(
                        run_name=r["run_name"],
                        spectrum_index=int(r["spectrum_index"]),
                        chemical_entity=r["chemical_entity"],
                        confidence_score=float(r["confidence_score"]),
                        evidence_chain=_maybe_json_list(r.get("evidence_chain_json", "[]")),
                    )
                    for r in io.read_compound_dataset(study, "identifications")
                ]
            blob = io.read_string_attr(study, "identifications_json", default="")
            return _decode_identifications_json(blob) if blob else []

    def quantifications(self) -> list[Quantification]:
        with self.read_lock():
            study = self._study_target()
            if self._study_has_child("quantifications"):
                return [
                    Quantification(
                        chemical_entity=r["chemical_entity"],
                        sample_ref=r["sample_ref"],
                        abundance=float(r["abundance"]),
                        normalization_method=r.get("normalization_method", ""),
                    )
                    for r in io.read_compound_dataset(study, "quantifications")
                ]
            blob = io.read_string_attr(study, "quantifications_json", default="")
            return _decode_quantifications_json(blob) if blob else []

    def provenance(self) -> list[ProvenanceRecord]:
        with self.read_lock():
            study = self._study_target()
            if self._study_has_child("provenance"):
                out: list[ProvenanceRecord] = []
                for r in io.read_compound_dataset(study, "provenance"):
                    out.append(
                        ProvenanceRecord(
                            timestamp_unix=int(r["timestamp_unix"]),
                            software=r["software"],
                            parameters=_maybe_json_dict(r.get("parameters_json", "{}")),
                            input_refs=_maybe_json_list(r.get("input_refs_json", "[]")),
                            output_refs=_maybe_json_list(r.get("output_refs_json", "[]")),
                        )
                    )
                return out
            blob = io.read_string_attr(study, "provenance_json", default="")
            return _decode_provenance_json(blob) if blob else []

    # ---- Encryptable conformance ----

    def encrypt_with_key(
        self, key: bytes, level: EncryptionLevel | None = None
    ) -> None:
        """Encrypt protectable content at the given granularity.

        For DATASET-level encryption (ObjC ``TTIOEncryptionLevelDataset``),
        encrypts every MS run's intensity channel in place. For finer-grained
        levels, callers should use ``run.encrypt_with_key`` directly.

        Matches ObjC ``-[TTIOSpectralDataset encryptWithKey:level:error:]``:
        after run-level encryption, marks the root with
        ``encrypted="aes-256-gcm"`` so :attr:`is_encrypted` and
        :attr:`encrypted_algorithm` round-trip across close/reopen.
        """
        for run in self.ms_runs.values():
            run.encrypt_with_key(key, level)
        self._mark_root_encrypted()

    def _mark_root_encrypted(self) -> None:
        """Persist ``encrypted=<algorithm>`` on the root, mirroring ObjC's
        ``-[TTIOSpectralDataset markRootEncryptedWithError:]``.

        Updates the in-memory ``encrypted_algorithm`` field as well so
        :attr:`is_encrypted` becomes True without requiring a reopen.
        """
        from .encryption import DEFAULT_ENCRYPTION_ALGORITHM

        if self.file is not None:
            io.write_fixed_string_attr(self.file, "encrypted", DEFAULT_ENCRYPTION_ALGORITHM)
        elif self.provider is not None:
            self.provider.root_group().set_attribute("encrypted", DEFAULT_ENCRYPTION_ALGORITHM)
        object.__setattr__(self, "encrypted_algorithm", DEFAULT_ENCRYPTION_ALGORITHM)

    def decrypt_with_key(self, key: bytes) -> dict[str, bytes]:
        """Decrypt every MS run's intensity channel.

        Returns a mapping of ``{run_name: plaintext_bytes}``. The on-disk
        file is NOT modified — decryption is read-only.

        Side effect: each run's decrypted channel is cached in memory so
        ``run.object_at_index(i).intensity_array`` works without re-decrypting
        (Option 1 of the MCP-Server M5 handoff; mirrors ObjC
        ``-[TTIOSpectralDataset decryptWithKey:]`` rehydration semantics).
        """
        return {name: run.decrypt_with_key(key) for name, run in self.ms_runs.items()}

    @classmethod
    def decrypt_in_place(cls, path: str | Path, key: bytes) -> None:
        """Strip AES-256-GCM encryption from a ``.tio`` file on disk.

        For every MS run with an encrypted intensity channel, replaces
        ``intensity_values_encrypted`` + IV + tag with a plaintext
        ``intensity_values`` dataset, then clears the root ``@encrypted``
        attribute. After this call the file is byte-compatible with the
        pre-encryption state and :attr:`is_encrypted` is ``False`` when
        reopened.

        Symmetric with :meth:`encrypt_with_key`: that method leaves the
        root ``@encrypted`` attribute set, this one removes it.

        The file must not be held open by another writer.

        Raises ``FileNotFoundError`` if the file does not exist,
        ``ValueError`` if ``key`` is not 32 bytes or any channel's tag
        does not verify.
        """
        from .encryption import (
            AES_KEY_LEN,
            decrypt_intensity_channel_in_run_in_place,
        )

        if len(key) != AES_KEY_LEN:
            raise ValueError(
                f"AES-256-GCM key must be {AES_KEY_LEN} bytes, got {len(key)}"
            )

        p = Path(path)
        if not p.exists():
            raise FileNotFoundError(f"File not found: {p}")

        with h5py.File(str(p), "r") as f:
            ms_group = f.get("study/ms_runs")
            if ms_group is None:
                run_names: list[str] = []
            else:
                names_attr = io.read_string_attr(
                    ms_group, "_run_names", default=""
                ) or ""
                run_names = [n for n in names_attr.split(",") if n]

        for run_name in run_names:
            decrypt_intensity_channel_in_run_in_place(str(p), run_name, key)

        with h5py.File(str(p), "r+") as f:
            if "encrypted" in f.attrs:
                del f.attrs["encrypted"]

    def access_policy(self) -> AccessPolicy | None:
        """Return the current access policy, or ``None`` if not set."""
        return self._access_policy

    def set_access_policy(self, policy: AccessPolicy | None) -> None:
        """Replace the current access policy."""
        object.__setattr__(self, "_access_policy", policy)

    # ---------------------------------------------------------------- writer

    @classmethod
    def write_minimal(
        cls,
        path: str | Path,
        *,
        title: str,
        isa_investigation_id: str,
        runs: Mapping[str, "WrittenRun"],
        genomic_runs: Mapping[str, WrittenGenomicRun] | None = None,  # M82
        identifications: list[Identification] | None = None,
        quantifications: list[Quantification] | None = None,
        provenance: list[ProvenanceRecord] | None = None,
        features: list[str] | None = None,
        provider: str | StorageProvider = "hdf5",
    ) -> Path:
        """Write a minimal v1.1 ``.tio`` file from in-memory data.

        Parameters
        ----------
        provider
            v0.9 M64.5: which storage backend to write through. The
            string ``"hdf5"`` (default) keeps byte-for-byte parity with
            pre-M64.5 files. Other values dispatch through
            :func:`open_provider` — ``"memory"``, ``"sqlite"``,
            ``"zarr"``, or any registered backend. A pre-opened
            :class:`StorageProvider` may also be passed; the caller
            owns its lifecycle in that case.
        """
        p = Path(path)
        feature_list = features or [
            "base_v1",
            "compound_identifications",
            "compound_quantifications",
            "compound_provenance",
            "compound_per_run_provenance",
            "opt_compound_headers",
        ]

        # M74 Slice E: if any run carries the four optional
        # activation/isolation columns, advertise the
        # opt_ms2_activation_detail feature flag and bump the format
        # version to 1.3 so readers know to look for them. Files without
        # M74 content keep the legacy 1.1 layout so existing byte-parity
        # tests continue to pass.
        any_m74 = any(
            run.activation_methods is not None for run in runs.values()
        )
        if features is None and any_m74:
            feature_list = feature_list + ["opt_ms2_activation_detail"]
        format_version = "1.3" if any_m74 else "1.1"

        # M82: opt_genomic feature flag + version bump when genomic_runs present.
        has_genomic = bool(genomic_runs)
        # M82: opt_genomic is the canonical advertisement of genomic content.
        # Add it whenever genomic_runs is non-empty, even if the caller supplied
        # their own features list (idempotent — no duplicate if already present).
        if has_genomic and "opt_genomic" not in feature_list:
            feature_list = feature_list + ["opt_genomic"]
        # M82: bump to 1.4 when genomic content present. 1.4 implies 1.3 (M74)
        # implies 1.1 (base). Readers gate features by feature flag list, not by
        # version equality.
        if has_genomic:
            format_version = "1.4"

        # HDF5 fast path keeps the legacy byte layout (fixed-length
        # string attrs, padded compound types) so existing tests and
        # cross-language readers continue to round-trip bit-for-bit.
        if isinstance(provider, str) and provider in ("hdf5", "h5", "h5py"):
            with h5py.File(p, "w") as f:
                io.write_feature_flags(f, format_version, feature_list)
                study = f.create_group("study")
                io.write_fixed_string_attr(study, "title", title)
                io.write_fixed_string_attr(study, "isa_investigation_id", isa_investigation_id)

                ms_group = study.create_group("ms_runs")
                io.write_fixed_string_attr(ms_group, "_run_names", ",".join(runs.keys()))
                for rname, run in runs.items():
                    _write_run(ms_group, rname, run)

                nmr_group = study.create_group("nmr_runs")
                io.write_fixed_string_attr(nmr_group, "_run_names", "")

                if has_genomic:
                    g_group = study.create_group("genomic_runs")
                    io.write_fixed_string_attr(
                        g_group, "_run_names", ",".join(genomic_runs.keys())
                    )
                    for gname, grun in genomic_runs.items():
                        _write_genomic_run(g_group, gname, grun)

                if identifications:
                    _write_identifications(study, identifications)
                if quantifications:
                    _write_quantifications(study, quantifications)
                if provenance:
                    _write_provenance(study, provenance)
            return p

        # Provider-driven write path — Memory / SQLite / Zarr / future.
        # Use the raw ``path`` string rather than ``Path(path)`` because
        # ``Path("memory://x")`` collapses ``//`` → ``/``, breaking the
        # MemoryProvider URL convention.
        owns_provider = False
        if isinstance(provider, str):
            url = str(path)
            sp = open_provider(url, provider=provider, mode="w")
            owns_provider = True
        else:
            sp = provider
        try:
            root = sp.root_group()
            io.write_feature_flags(root, format_version, feature_list)
            study = root.create_group("study")
            io.write_fixed_string_attr(study, "title", title)
            io.write_fixed_string_attr(study, "isa_investigation_id", isa_investigation_id)

            ms_group = study.create_group("ms_runs")
            io.write_fixed_string_attr(ms_group, "_run_names", ",".join(runs.keys()))
            for rname, run in runs.items():
                _write_run(ms_group, rname, run)

            nmr_group = study.create_group("nmr_runs")
            io.write_fixed_string_attr(nmr_group, "_run_names", "")

            if has_genomic:
                g_group = study.create_group("genomic_runs")
                io.write_fixed_string_attr(
                    g_group, "_run_names", ",".join(genomic_runs.keys())
                )
                for gname, grun in genomic_runs.items():
                    _write_genomic_run(g_group, gname, grun)

            if identifications:
                _write_identifications(study, identifications)
            if quantifications:
                _write_quantifications(study, quantifications)
            if provenance:
                _write_provenance(study, provenance)
        finally:
            if owns_provider:
                sp.close()
        return p


# ------------------------------------------------------------ writer helpers

@dataclass(slots=True)
class WrittenRun:
    """Simple container passed to :meth:`SpectralDataset.write_minimal`."""

    spectrum_class: str  # "TTIOMassSpectrum" or "TTIONMRSpectrum"
    acquisition_mode: int
    channel_data: dict[str, np.ndarray]  # concatenated signal buffers
    offsets: np.ndarray
    lengths: np.ndarray
    retention_times: np.ndarray
    ms_levels: np.ndarray
    polarities: np.ndarray
    precursor_mzs: np.ndarray
    precursor_charges: np.ndarray
    base_peak_intensities: np.ndarray
    # v0.11 M74: optional parallel per-spectrum arrays. Writer emits the
    # four datasets only when all four are non-None (schema-gating per
    # the opt_ms2_activation_detail feature flag).
    activation_methods: np.ndarray | None = None
    isolation_target_mzs: np.ndarray | None = None
    isolation_lower_offsets: np.ndarray | None = None
    isolation_upper_offsets: np.ndarray | None = None
    nucleus_type: str = ""
    provenance_records: list[ProvenanceRecord] = field(default_factory=list)
    # v0.3 M21: signal compression codec. Valid values are the strings
    # recognised by :func:`ttio._hdf5_io.write_signal_channel` plus
    # the TTIO-level ``"numpress_delta"`` codec, which transforms the
    # float64 buffer into an int64 first-difference array and stores
    # the fixed-point scaling factor on the signal_channels group.
    signal_compression: str = "gzip"
    # v0.4 M24: optional chromatogram traces for this run. Empty list
    # results in no /chromatograms/ group, preserving byte parity with
    # v0.3 files written by callers that don't supply chromatograms.
    chromatograms: list = field(default_factory=list)  # list[Chromatogram]


def _write_run(parent: h5py.Group, name: str, run: WrittenRun) -> None:
    g = parent.create_group(name)
    io.write_int_attr(g, "acquisition_mode", run.acquisition_mode)
    io.write_int_attr(g, "spectrum_count", int(run.offsets.shape[0]))
    io.write_fixed_string_attr(g, "spectrum_class", run.spectrum_class)
    if run.nucleus_type:
        io.write_fixed_string_attr(g, "nucleus_type", run.nucleus_type)

    if run.provenance_records:
        prov = g.create_group("provenance")
        _write_provenance(prov, run.provenance_records, dataset_name="steps")
        # Legacy @provenance_json mirror so ObjC signature manager and
        # v0.2 readers keep working — matches TTIOAcquisitionRun.m.
        legacy = json.dumps([
            {
                "inputRefs": r.input_refs,
                "software": r.software,
                "parameters": r.parameters,
                "outputRefs": r.output_refs,
                "timestampUnix": int(r.timestamp_unix),
            } for r in run.provenance_records
        ])
        io.write_fixed_string_attr(g, "provenance_json", legacy)

    cfg = g.create_group("instrument_config")
    for field_name in ("manufacturer", "model", "serial_number",
                       "source_type", "analyzer_type", "detector_type"):
        io.write_fixed_string_attr(cfg, field_name, "")

    idx = g.create_group("spectrum_index")
    io.write_int_attr(idx, "count", int(run.offsets.shape[0]))
    columns: list[tuple[str, np.ndarray, str]] = [
        ("offsets", run.offsets, "<u8"),
        ("lengths", run.lengths, "<u4"),
        ("retention_times", run.retention_times, "<f8"),
        ("ms_levels", run.ms_levels, "<i4"),
        ("polarities", run.polarities, "<i4"),
        ("precursor_mzs", run.precursor_mzs, "<f8"),
        ("precursor_charges", run.precursor_charges, "<i4"),
        ("base_peak_intensities", run.base_peak_intensities, "<f8"),
    ]
    # M74 schema-gating: only emit the four optional columns when all
    # four are supplied. The opt_ms2_activation_detail feature flag is
    # the author-level gate; this block translates that gate into
    # physical column presence on disk.
    m74_cols = (run.activation_methods, run.isolation_target_mzs,
                run.isolation_lower_offsets, run.isolation_upper_offsets)
    if all(c is not None for c in m74_cols):
        columns += [
            ("activation_methods", run.activation_methods, "<i4"),
            ("isolation_target_mzs", run.isolation_target_mzs, "<f8"),
            ("isolation_lower_offsets", run.isolation_lower_offsets, "<f8"),
            ("isolation_upper_offsets", run.isolation_upper_offsets, "<f8"),
        ]
    elif any(c is not None for c in m74_cols):
        raise ValueError(
            "WrittenRun M74 columns must be either all-None or all-set; "
            "partial population is not a valid schema state."
        )
    for dname, data, dtype in columns:
        io.write_signal_channel(idx, dname, data.astype(dtype, copy=False),
                                chunk_size=io.DEFAULT_INDEX_CHUNK)

    sig = g.create_group("signal_channels")
    io.write_fixed_string_attr(sig, "channel_names", ",".join(run.channel_data.keys()))
    codec = run.signal_compression
    for cname, buffer in run.channel_data.items():
        if codec == "numpress_delta":
            from ._numpress import encode as _np_encode
            deltas, scale = _np_encode(buffer.astype(np.float64, copy=False))
            ds_name = f"{cname}_values"
            io.write_signal_channel(
                sig, ds_name, deltas, compression="gzip",
            )
            # Per-channel fixed-point attribute, matching the ObjC
            # writer's ``@<chName>_numpress_fixed_point``.
            io.write_int_attr(sig, f"{cname}_numpress_fixed_point", int(scale))
        else:
            io.write_signal_channel(
                sig, f"{cname}_values",
                buffer.astype("<f8", copy=False),
                compression=codec,
            )

    # M24: chromatograms
    if run.chromatograms:
        from .acquisition_run import write_chromatograms_to_run_group
        write_chromatograms_to_run_group(g, run.chromatograms)


def _write_genomic_run(parent, name: str, run: WrittenGenomicRun) -> None:
    """Write one /study/genomic_runs/<name>/ subtree.

    Mirrors :func:`_write_run` but for the genomic data model. Uses the
    M82 signal-channel helpers from ``_hdf5_io`` and the existing
    compound-dataset writer for variable-length per-read fields.

    ``parent`` may be either a raw h5py group (HDF5 fast path) or a
    :class:`~ttio.providers.base.StorageGroup` (provider path). Raw
    h5py groups are wrapped in :class:`~ttio.providers.hdf5._Group` so
    the signal-channel helpers (which expect the StorageGroup API) work
    identically on both paths.
    """
    from ttio.genomic_index import GenomicIndex
    from ttio.providers.hdf5 import _Group as _H5Group

    # Normalise: the signal-channel helpers call StorageGroup.create_dataset
    # with the (name, Precision, length=N, ...) signature, which differs
    # from h5py's positional API.  Wrap any bare h5py group so both paths
    # use the same StorageGroup interface.
    if isinstance(parent, h5py.Group):
        parent = _H5Group(parent)

    # M86: validate any per-channel codec overrides before we touch
    # the file. Phase A/D/E covered the three byte/string channels
    # (sequences, qualities, read_names). Phase B (Binding Decision
    # §117) extends the override map to the three integer channels
    # (positions, flags, mapping_qualities), each of which accepts
    # only the rANS codecs — BASE_PACK / QUALITY_BINNED /
    # NAME_TOKENIZED are wrong-content for integer fields and would
    # silently corrupt the data. Anything outside the per-channel
    # whitelist is a caller error and must surface immediately
    # (Binding Decision §88).
    from .enums import Compression as _Compression
    _ALLOWED_OVERRIDE_CODECS_BY_CHANNEL = {
        "sequences": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.BASE_PACK,
        }),
        "qualities": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.BASE_PACK,
            _Compression.QUALITY_BINNED,
        }),
        # M86 Phase E: NAME_TOKENIZED is only valid on read_names
        # (Binding Decision §113). The codec tokenises UTF-8 strings
        # and would mis-tokenise binary byte streams like sequences/
        # qualities. The other byte-channel codecs are not valid here
        # because the source data is list[str], not bytes.
        "read_names": frozenset({
            _Compression.NAME_TOKENIZED,
        }),
        # M86 Phase C: cigars accepts THREE codecs (Binding Decisions
        # §120, §121, §122). The rANS pair operate on a length-prefix-
        # concat byte stream of the CIGAR strings (varint(len) + bytes
        # per CIGAR); NAME_TOKENIZED operates on the list[str] directly
        # via its own columnar/verbatim wire format. BASE_PACK and
        # QUALITY_BINNED are wrong-content (CIGARs are not ACGT bytes
        # nor Phred values) and are explicitly rejected with named
        # error messages below.
        "cigars": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.NAME_TOKENIZED,
        }),
        # M86 Phase B: integer channels accept ONLY the rANS codecs
        # (Binding Decision §117). The rANS coders are content-
        # agnostic byte-stream codecs and operate correctly on the
        # little-endian byte representation of int64/uint32/uint8
        # arrays (§118). The other byte-channel codecs do not
        # preserve integer values: BASE_PACK 2-bit-packs ACGT bytes
        # (mangling everything else), QUALITY_BINNED quantises Phred
        # scores onto an 8-bin centre table, and NAME_TOKENIZED
        # tokenises UTF-8 strings.
        "positions": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        }),
        "flags": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        }),
        "mapping_qualities": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        }),
        # M86 Phase F: per-field decomposition of the M82 mate_info
        # compound dataset. The bare key "mate_info" is reserved and
        # rejected (Binding Decision §126); callers must use the
        # three per-field virtual channel names. The chrom field
        # accepts the same codec set as the cigars channel (Phase C
        # / Binding Decision §130) — it's a list of structured
        # ASCII strings. The pos and tlen fields are integer
        # channels and accept the same codec set as positions/flags
        # (Binding Decision §117 generalised).
        "mate_info_chrom": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.NAME_TOKENIZED,
        }),
        "mate_info_pos": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        }),
        "mate_info_tlen": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        }),
    }
    _INTEGER_CHANNEL_NAMES = frozenset(
        {"positions", "flags", "mapping_qualities",
         "mate_info_pos", "mate_info_tlen"}
    )
    _MATE_INFO_FIELD_NAMES = frozenset(
        {"mate_info_chrom", "mate_info_pos", "mate_info_tlen"}
    )
    for ch_name, codec in run.signal_codec_overrides.items():
        # M86 Phase F Binding Decision §126 / Gotcha §143: the bare
        # "mate_info" key is reserved and rejected with a message
        # pointing at the three per-field names. Without the
        # explicit reject, the bare key would fall through to the
        # generic "channel not supported" branch and the caller
        # would not learn about the per-field surface.
        if ch_name == "mate_info":
            raise ValueError(
                "signal_codec_overrides['mate_info']: the bare "
                "'mate_info' key is reserved and rejected — "
                "mate_info is decomposed at the per-field level in "
                "M86 Phase F. Use one or more of the three per-"
                "field virtual channel names instead: "
                "'mate_info_chrom', 'mate_info_pos', "
                "'mate_info_tlen'. See docs/format-spec.md §10.9."
            )
        if ch_name not in _ALLOWED_OVERRIDE_CODECS_BY_CHANNEL:
            raise ValueError(
                f"signal_codec_overrides: channel '{ch_name}' not supported "
                f"(only sequences, qualities, read_names, cigars, "
                f"positions, flags, mapping_qualities, mate_info_chrom, "
                f"mate_info_pos, and mate_info_tlen can use TTIO codecs)"
            )
        try:
            codec_enum = _Compression(codec)
        except ValueError as exc:
            raise ValueError(
                f"signal_codec_overrides['{ch_name}']: codec {codec!r} "
                "is not a valid Compression value"
            ) from exc
        allowed = _ALLOWED_OVERRIDE_CODECS_BY_CHANNEL[ch_name]
        if codec_enum not in allowed:
            # Phase D Binding Decision §110: explicit message for the
            # (sequences, QUALITY_BINNED) category error — naming the
            # codec, the channel, and the lossy-quantisation rationale.
            if (
                codec_enum == _Compression.QUALITY_BINNED
                and ch_name == "sequences"
            ):
                raise ValueError(
                    f"signal_codec_overrides['{ch_name}']: codec "
                    f"QUALITY_BINNED is not valid on the '{ch_name}' "
                    "channel — quality binning is lossy and only "
                    "applies to Phred quality scores. Applying it to "
                    "ACGT sequence bytes would silently destroy the "
                    "sequence via Phred-bin quantisation. Use the "
                    "'qualities' channel for QUALITY_BINNED, or "
                    "RANS_ORDER0/RANS_ORDER1/BASE_PACK on sequences."
                )
            # Phase E Binding Decision §113: explicit message for
            # (sequences|qualities, NAME_TOKENIZED) — naming the
            # codec, the channel, and the wrong-input-type rationale.
            if (
                codec_enum == _Compression.NAME_TOKENIZED
                and ch_name in ("sequences", "qualities")
            ):
                raise ValueError(
                    f"signal_codec_overrides['{ch_name}']: codec "
                    f"NAME_TOKENIZED is not valid on the '{ch_name}' "
                    "channel — NAME_TOKENIZED tokenises UTF-8 read "
                    "name strings (digit runs vs string runs), not "
                    "binary byte streams like ACGT sequence bytes or "
                    "Phred quality scores. Applying it to "
                    f"'{ch_name}' would mis-tokenise the data and "
                    "fall back to verbatim, producing nonsensical "
                    "compression. Use the 'read_names' channel for "
                    "NAME_TOKENIZED, or RANS_ORDER0/RANS_ORDER1/"
                    f"BASE_PACK on '{ch_name}'."
                )
            # Phase B Binding Decision §117: explicit messages for
            # the wrong-content codecs on integer channels. Each
            # message names the codec, the channel, and explains
            # why the codec does not preserve integer values.
            if ch_name in _INTEGER_CHANNEL_NAMES:
                if codec_enum == _Compression.BASE_PACK:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"BASE_PACK is not valid on the '{ch_name}' "
                        "channel — BASE_PACK 2-bit-packs ACGT sequence "
                        f"bytes and would silently corrupt the integer "
                        "values stored on this channel. Use "
                        f"RANS_ORDER0 or RANS_ORDER1 on '{ch_name}'."
                    )
                if codec_enum == _Compression.QUALITY_BINNED:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"QUALITY_BINNED is not valid on the "
                        f"'{ch_name}' channel — QUALITY_BINNED "
                        "quantises Phred quality scores onto an 8-bin "
                        f"centre table and would silently destroy the "
                        "integer values stored on this channel. Use "
                        f"RANS_ORDER0 or RANS_ORDER1 on '{ch_name}'."
                    )
                if codec_enum == _Compression.NAME_TOKENIZED:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"NAME_TOKENIZED is not valid on the "
                        f"'{ch_name}' channel — NAME_TOKENIZED "
                        "tokenises UTF-8 read-name strings and would "
                        "mis-tokenise the integer values stored on "
                        f"this channel. Use RANS_ORDER0 or "
                        f"RANS_ORDER1 on '{ch_name}'."
                    )
            # Phase C Binding Decisions §120, §121: explicit messages
            # for the wrong-content codecs on the cigars channel. The
            # cigars channel holds variable-length ASCII CIGAR strings
            # — neither ACGT bytes (BASE_PACK) nor Phred quality
            # values (QUALITY_BINNED) match. The error names the
            # codec, the channel, and the wrong-content rationale.
            #
            # Phase F: mate_info_chrom shares the same codec rules as
            # cigars (Binding Decision §130) — both are list[str] of
            # structured ASCII content. Reuse the same wrong-content
            # rejection messages for the same reason.
            if ch_name in ("cigars", "mate_info_chrom"):
                if codec_enum == _Compression.BASE_PACK:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"BASE_PACK is not valid on the '{ch_name}' "
                        "channel — BASE_PACK 2-bit-packs ACGT sequence "
                        "bytes and would silently corrupt the structured "
                        "ASCII strings stored on this channel. Use "
                        f"RANS_ORDER0, RANS_ORDER1, or NAME_TOKENIZED on "
                        f"'{ch_name}'."
                    )
                if codec_enum == _Compression.QUALITY_BINNED:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"QUALITY_BINNED is not valid on the '{ch_name}' "
                        "channel — QUALITY_BINNED quantises Phred "
                        "quality scores onto an 8-bin centre table and "
                        "would silently destroy the structured ASCII "
                        "strings stored on this channel. Use "
                        f"RANS_ORDER0, RANS_ORDER1, or NAME_TOKENIZED on "
                        f"'{ch_name}'."
                    )
            raise ValueError(
                f"signal_codec_overrides['{ch_name}']: codec {codec!r} "
                f"not supported on the '{ch_name}' channel "
                f"(allowed: {sorted(c.name for c in allowed)})"
            )

    rg = parent.create_group(name)

    # Run-level attributes (mirrors _write_run pattern).
    io.write_int_attr(rg, "acquisition_mode", run.acquisition_mode)
    io.write_fixed_string_attr(rg, "modality", "genomic_sequencing")
    io.write_int_attr(rg, "spectrum_class", 5)
    io.write_fixed_string_attr(rg, "reference_uri", run.reference_uri)
    io.write_fixed_string_attr(rg, "platform", run.platform)
    io.write_fixed_string_attr(rg, "sample_name", run.sample_name)
    io.write_int_attr(rg, "read_count", int(run.offsets.shape[0]))

    # Genomic index (parallel arrays, including chromosomes as compound).
    idx = GenomicIndex(
        offsets=run.offsets,
        lengths=run.lengths,
        chromosomes=run.chromosomes,
        positions=run.positions,
        mapping_qualities=run.mapping_qualities,
        flags=run.flags,
    )
    idx_group = rg.create_group("genomic_index")
    idx.write(idx_group)

    # Signal channels — these honour run.signal_compression by default;
    # M86 lets per-channel overrides route sequences/qualities through
    # the rANS / BASE_PACK codecs instead.
    sc = rg.create_group("signal_channels")
    # M86 Phase B: integer channels dispatch through
    # ``_write_int_channel_with_codec``; when the per-channel
    # override is rANS the channel is serialised to little-endian
    # bytes and written as flat uint8 with @compression. When the
    # override is absent (the M82 default), the helper delegates to
    # the existing typed writer so byte parity is preserved.
    io._write_int_channel_with_codec(
        sc, "positions", run.positions, run.signal_compression,
        run.signal_codec_overrides.get("positions"),
    )
    io._write_byte_channel_with_codec(
        sc, "sequences", run.sequences, run.signal_compression,
        run.signal_codec_overrides.get("sequences"),
    )
    io._write_byte_channel_with_codec(
        sc, "qualities", run.qualities, run.signal_compression,
        run.signal_codec_overrides.get("qualities"),
    )
    io._write_int_channel_with_codec(
        sc, "flags", run.flags, run.signal_compression,
        run.signal_codec_overrides.get("flags"),
    )
    io._write_int_channel_with_codec(
        sc, "mapping_qualities", run.mapping_qualities,
        run.signal_compression,
        run.signal_codec_overrides.get("mapping_qualities"),
    )
    # Variable-length per-read string fields — cigars and read_names are
    # 7-bit ASCII; vl_str() (ASCII encoding) matches the ObjC reader.
    # M86 Phase C: schema lift for cigars. When an override is
    # present the writer replaces the M82 compound dataset with a
    # flat 1-D uint8 dataset of the same name carrying the codec
    # output, plus an @compression attribute (Binding Decisions
    # §120-§122). Three codec choices are supported (rANS uses a
    # length-prefix-concat byte stream over the CIGAR list; the
    # NAME_TOKENIZED codec consumes the list[str] directly).
    if "cigars" in run.signal_codec_overrides:
        from .enums import Precision as _Precision
        cigars_codec = _Compression(
            run.signal_codec_overrides["cigars"]
        )
        if cigars_codec in (
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        ):
            from .codecs.rans import encode as _rans_enc
            from .codecs.name_tokenizer import _varint_encode as _ve
            # Validate ASCII early so non-ASCII surfaces a clear
            # error before we touch the file (§2.5 contract).
            buf = bytearray()
            for idx, cig in enumerate(run.cigars):
                try:
                    payload = cig.encode("ascii")
                except UnicodeEncodeError as exc:
                    raise ValueError(
                        f"signal_codec_overrides['cigars']: cigar "
                        f"at index {idx} contains non-ASCII bytes "
                        "— CIGARs must be 7-bit ASCII per the SAM "
                        "spec"
                    ) from exc
                buf.extend(_ve(len(payload)))
                buf.extend(payload)
            order = (
                0
                if cigars_codec == _Compression.RANS_ORDER0
                else 1
            )
            encoded = _rans_enc(bytes(buf), order=order)
        elif cigars_codec == _Compression.NAME_TOKENIZED:
            from .codecs import name_tokenizer as _nt
            encoded = _nt.encode(list(run.cigars))
        else:  # pragma: no cover — validation above rejects this
            raise ValueError(
                f"signal_codec_overrides['cigars']: codec "
                f"{cigars_codec!r} is not supported"
            )
        arr = np.frombuffer(encoded, dtype=np.uint8)
        ds = sc.create_dataset(
            "cigars",
            _Precision.UINT8,
            length=int(arr.shape[0]),
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=_Compression.NONE,
        )
        ds.write(arr)
        io.write_int_attr(
            ds, "compression",
            int(cigars_codec), dtype="<u1",
        )
    else:
        io.write_compound_dataset(
            sc,
            "cigars",
            [{"value": c} for c in run.cigars],
            [("value", io.vl_str())],
        )
    # M86 Phase E: schema lift for read_names. When the
    # NAME_TOKENIZED override is set, replace the M82 compound
    # dataset with a flat 1-D uint8 dataset of the same name
    # carrying the codec output, plus an @compression == 8
    # attribute (Binding Decisions §111, §113). The two layouts
    # are mutually exclusive within a single run; readers
    # dispatch on dataset shape (compound vs uint8). No HDF5
    # filter is applied — codec output is high-entropy
    # (Binding Decision §87).
    if "read_names" in run.signal_codec_overrides:
        from .codecs import name_tokenizer as _nt
        from .enums import Precision as _Precision
        encoded = _nt.encode(list(run.read_names))
        arr = np.frombuffer(encoded, dtype=np.uint8)
        ds = sc.create_dataset(
            "read_names",
            _Precision.UINT8,
            length=int(arr.shape[0]),
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=_Compression.NONE,
        )
        ds.write(arr)
        io.write_int_attr(
            ds, "compression",
            int(_Compression.NAME_TOKENIZED), dtype="<u1",
        )
    else:
        io.write_compound_dataset(
            sc,
            "read_names",
            [{"value": n} for n in run.read_names],
            [("value", io.vl_str())],
        )
    # M86 Phase F: schema lift for mate_info. When ANY of the three
    # per-field overrides (mate_info_chrom / mate_info_pos /
    # mate_info_tlen) is in signal_codec_overrides, the writer
    # creates a subgroup ``signal_channels/mate_info/`` containing
    # three child datasets (chrom, pos, tlen) and dispatches each
    # child independently — codec-compressed if the per-field
    # override is set, natural-dtype HDF5-filter ZLIB if not
    # (Binding Decision §125, §127). Partial overrides allowed
    # (Gotcha §142). When NO mate_info_* override is set, the
    # existing M82 compound write path is used unchanged for byte
    # parity with pre-Phase-F files.
    _mate_override_keys = {
        "mate_info_chrom", "mate_info_pos", "mate_info_tlen",
    }
    _mate_overrides = {
        k: run.signal_codec_overrides[k]
        for k in _mate_override_keys
        if k in run.signal_codec_overrides
    }
    if _mate_overrides:
        _write_mate_info_subgroup(sc, run, _mate_overrides)
    else:
        io.write_compound_dataset(
            sc,
            "mate_info",
            [
                {"chrom": mc, "pos": int(mp), "tlen": int(tl)}
                for mc, mp, tl in zip(
                    run.mate_chromosomes,
                    run.mate_positions,
                    run.template_lengths,
                )
            ],
            [("chrom", io.vl_str()), ("pos", "<i8"), ("tlen", "<i4")],
        )

    # Per-run provenance — same pattern as _write_run.
    if run.provenance_records:
        prov = rg.create_group("provenance")
        _write_provenance(prov, run.provenance_records, dataset_name="steps")


def _write_mate_info_subgroup(
    sc,
    run: WrittenGenomicRun,
    overrides: dict[str, Any],
) -> None:
    """M86 Phase F: write the mate_info subgroup with per-field codec dispatch.

    Triggered when any of the three per-field override keys is in
    ``run.signal_codec_overrides``. Creates a subgroup
    ``signal_channels/mate_info/`` containing three child datasets
    (``chrom``, ``pos``, ``tlen``). Each field is independently
    codec-compressible: fields with an override are written as flat
    1-D uint8 with the codec output and ``@compression`` attribute
    (no HDF5 filter — Binding Decision §87); fields without an
    override use their natural dtype with HDF5 ZLIB filter inside
    the subgroup (Binding Decision §127, partial overrides allowed).

    The chrom field's serialisation matches Phase C cigars:
    NAME_TOKENIZED takes the list directly; rANS uses
    length-prefix-concat (varint(len) + ASCII bytes per chrom).

    The pos and tlen fields' serialisation matches Phase B integer
    channels: rANS over the LE byte representation of the typed
    array (``<i8`` for pos, ``<i4`` for tlen).
    """
    from .enums import Compression as _Compression, Precision as _Precision

    mate_group = sc.create_group("mate_info")

    # ---- chrom field ---------------------------------------------------
    chroms = list(run.mate_chromosomes)
    chrom_codec = overrides.get("mate_info_chrom")
    if chrom_codec is None:
        # Natural dtype (VL_STRING) with HDF5 ZLIB filter.
        io.write_compound_dataset(
            mate_group,
            "chrom",
            [{"value": c} for c in chroms],
            [("value", io.vl_str())],
        )
    else:
        chrom_codec = _Compression(chrom_codec)
        if chrom_codec in (
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        ):
            from .codecs.rans import encode as _rans_enc
            from .codecs.name_tokenizer import _varint_encode as _ve
            buf = bytearray()
            for idx, c in enumerate(chroms):
                try:
                    payload = c.encode("ascii")
                except UnicodeEncodeError as exc:
                    raise ValueError(
                        "signal_codec_overrides['mate_info_chrom']: "
                        f"chrom at index {idx} contains non-ASCII bytes"
                    ) from exc
                buf.extend(_ve(len(payload)))
                buf.extend(payload)
            order = (
                0
                if chrom_codec == _Compression.RANS_ORDER0
                else 1
            )
            encoded = _rans_enc(bytes(buf), order=order)
        elif chrom_codec == _Compression.NAME_TOKENIZED:
            from .codecs import name_tokenizer as _nt
            encoded = _nt.encode(chroms)
        else:  # pragma: no cover — validation rejects this
            raise ValueError(
                "signal_codec_overrides['mate_info_chrom']: codec "
                f"{chrom_codec!r} is not supported"
            )
        arr = np.frombuffer(encoded, dtype=np.uint8)
        ds = mate_group.create_dataset(
            "chrom",
            _Precision.UINT8,
            length=int(arr.shape[0]),
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=_Compression.NONE,
        )
        ds.write(arr)
        io.write_int_attr(
            ds, "compression", int(chrom_codec), dtype="<u1"
        )

    # ---- pos field -----------------------------------------------------
    pos_arr = np.asarray(run.mate_positions).astype("<i8", copy=False)
    pos_codec = overrides.get("mate_info_pos")
    _write_mate_int_field(
        mate_group, "pos", pos_arr, "<i8", _Precision.INT64, pos_codec,
    )

    # ---- tlen field ----------------------------------------------------
    tlen_arr = np.asarray(run.template_lengths).astype("<i4", copy=False)
    tlen_codec = overrides.get("mate_info_tlen")
    _write_mate_int_field(
        mate_group, "tlen", tlen_arr, "<i4", _Precision.INT32, tlen_codec,
    )


def _write_mate_int_field(
    mate_group,
    name: str,
    arr: np.ndarray,
    dtype_str: str,
    natural_precision: Any,
    codec: Any,
) -> None:
    """Write one of the integer mate fields (pos or tlen) with optional codec.

    Mirrors the Phase B integer-channel write contract: when ``codec``
    is ``None``, the array is written at its natural integer
    precision with HDF5 ZLIB. When ``codec`` is RANS_ORDER0 or
    RANS_ORDER1, the LE byte representation of the array is encoded
    through the M83 rANS codec and written as a flat unfiltered uint8
    dataset with ``@compression`` carrying the codec id.
    """
    from .enums import Compression as _Compression, Precision as _Precision

    if codec is None:
        # Natural-dtype write with HDF5 ZLIB filter inside the subgroup.
        ds = mate_group.create_dataset(
            name,
            natural_precision,
            length=int(arr.shape[0]),
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=_Compression.ZLIB,
            compression_level=6,
        )
        ds.write(arr)
        return

    codec_enum = _Compression(codec)
    if codec_enum not in (
        _Compression.RANS_ORDER0,
        _Compression.RANS_ORDER1,
    ):  # pragma: no cover — validation rejects this
        raise ValueError(
            f"signal_codec_overrides['mate_info_{name}']: codec "
            f"{codec!r} is not supported (only RANS_ORDER0 and "
            "RANS_ORDER1 are valid for the integer mate fields)"
        )

    le_bytes = bytes(np.ascontiguousarray(arr).tobytes())
    from .codecs.rans import encode as _enc
    order = 0 if codec_enum == _Compression.RANS_ORDER0 else 1
    encoded = _enc(le_bytes, order=order)
    arr_u8 = np.frombuffer(encoded, dtype=np.uint8)
    ds = mate_group.create_dataset(
        name,
        _Precision.UINT8,
        length=int(arr_u8.shape[0]),
        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
        compression=_Compression.NONE,
    )
    ds.write(arr_u8)
    io.write_int_attr(ds, "compression", int(codec_enum), dtype="<u1")


def _write_identifications(study: h5py.Group, records: list[Identification]) -> None:
    fields = [
        ("run_name", io.vl_str()),
        ("spectrum_index", "<u4"),
        ("chemical_entity", io.vl_str()),
        ("confidence_score", "<f8"),
        ("evidence_chain_json", io.vl_str()),
    ]
    io.write_compound_dataset(study, "identifications", [
        {
            "run_name": r.run_name,
            "spectrum_index": int(r.spectrum_index),
            "chemical_entity": r.chemical_entity,
            "confidence_score": float(r.confidence_score),
            "evidence_chain_json": json.dumps(r.evidence_chain),
        } for r in records
    ], fields)
    # M37: emit @identifications_json mirror so Java (JHI5 1.10 cannot
    # marshal compound-with-VL reads) can recover the full record set.
    io.write_fixed_string_attr(study, "identifications_json", json.dumps([
        {
            "run_name": r.run_name,
            "spectrum_index": int(r.spectrum_index),
            "chemical_entity": r.chemical_entity,
            "confidence_score": float(r.confidence_score),
            "evidence_chain": list(r.evidence_chain),
        } for r in records
    ]))


def _write_quantifications(study: h5py.Group, records: list[Quantification]) -> None:
    fields = [
        ("chemical_entity", io.vl_str()),
        ("sample_ref", io.vl_str()),
        ("abundance", "<f8"),
        ("normalization_method", io.vl_str()),
    ]
    io.write_compound_dataset(study, "quantifications", [
        {
            "chemical_entity": r.chemical_entity,
            "sample_ref": r.sample_ref,
            "abundance": float(r.abundance),
            "normalization_method": r.normalization_method,
        } for r in records
    ], fields)
    # M37: JSON mirror (see _write_identifications)
    io.write_fixed_string_attr(study, "quantifications_json", json.dumps([
        {
            "chemical_entity": r.chemical_entity,
            "sample_ref": r.sample_ref,
            "abundance": float(r.abundance),
            **({"normalization_method": r.normalization_method}
               if r.normalization_method else {}),
        } for r in records
    ]))


def _write_provenance(
    study: h5py.Group,
    records: list[ProvenanceRecord],
    *,
    dataset_name: str = "provenance",
) -> None:
    fields = [
        ("timestamp_unix", "<i8"),
        ("software", io.vl_str()),
        ("parameters_json", io.vl_str()),
        ("input_refs_json", io.vl_str()),
        ("output_refs_json", io.vl_str()),
    ]
    io.write_compound_dataset(study, dataset_name, [
        {
            "timestamp_unix": int(r.timestamp_unix),
            "software": r.software,
            "parameters_json": json.dumps(r.parameters),
            "input_refs_json": json.dumps(r.input_refs),
            "output_refs_json": json.dumps(r.output_refs),
        } for r in records
    ], fields)
    # M37: JSON mirror. Only emitted for the top-level /study/provenance
    # dataset; per-run provenance (§6.4) stays compound-only because the
    # Java reader never descends into run-level compound datasets.
    if dataset_name == "provenance":
        io.write_fixed_string_attr(study, "provenance_json", json.dumps([
            {
                "timestamp_unix": int(r.timestamp_unix),
                "software": r.software,
                "parameters": r.parameters,
                "input_refs": list(r.input_refs),
                "output_refs": list(r.output_refs),
            } for r in records
        ]))


# --------------------------------------------------------- JSON fallback ---


def _maybe_json_list(value: str) -> list[str]:
    try:
        parsed = json.loads(value) if value else []
    except json.JSONDecodeError:
        return []
    if isinstance(parsed, list):
        return [str(x) for x in parsed]
    return []


def _maybe_json_dict(value: str) -> dict[str, object]:
    try:
        parsed = json.loads(value) if value else {}
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _decode_identifications_json(blob: str) -> list[Identification]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[Identification] = []
    for r in data if isinstance(data, list) else []:
        out.append(Identification(
            run_name=str(r.get("run_name", "")),
            spectrum_index=int(r.get("spectrum_index", 0)),
            chemical_entity=str(r.get("chemical_entity", "")),
            confidence_score=float(r.get("confidence_score", 0.0)),
            evidence_chain=[str(x) for x in r.get("evidence_chain", [])],
        ))
    return out


def _decode_quantifications_json(blob: str) -> list[Quantification]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[Quantification] = []
    for r in data if isinstance(data, list) else []:
        out.append(Quantification(
            chemical_entity=str(r.get("chemical_entity", "")),
            sample_ref=str(r.get("sample_ref", "")),
            abundance=float(r.get("abundance", 0.0)),
            normalization_method=str(r.get("normalization_method", "")),
        ))
    return out


def _decode_provenance_json(blob: str) -> list[ProvenanceRecord]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    out: list[ProvenanceRecord] = []
    items = data if isinstance(data, list) else []
    for r in items:
        out.append(ProvenanceRecord(
            timestamp_unix=int(r.get("timestamp_unix", 0)),
            software=str(r.get("software", "")),
            parameters=r.get("parameters", {}) if isinstance(r.get("parameters"), dict) else {},
            input_refs=[str(x) for x in r.get("input_refs", [])],
            output_refs=[str(x) for x in r.get("output_refs", [])],
        ))
    return out
