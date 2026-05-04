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
        """Union of MS and NMR runs, keyed by run name.

        Note: This DOES NOT include ``genomic_runs`` — those have a
        different return type (:class:`GenomicRun` rather than
        :class:`AcquisitionRun`). For modality-agnostic iteration
        across all run types, use :meth:`all_runs_unified` (Phase 1).
        """
        merged: dict[str, AcquisitionRun] = dict(self.ms_runs)
        for k, v in self.nmr_runs.items():
            merged.setdefault(k, v)
        return merged

    # ── Phase 2 (post-M91) — canonical unified runs accessor ────────

    @property
    def runs(self) -> Mapping[str, "Run"]:
        """Canonical mapping over every run in the file (MS + NMR +
        genomic), keyed by run name.

        Values conform to the :class:`ttio.protocols.run.Run`
        Protocol so callers can iterate uniformly without knowing
        the underlying modality:

            for name, run in ds.runs.items():
                print(f"{name}: {len(run)} measurements")

        Use :meth:`runs_of_modality` to narrow by class, or
        :meth:`runs_for_sample` to filter by provenance sample URI.

        Phase 2 promotes this to the canonical access pattern.
        Backward-compat: the legacy ``ms_runs`` / ``nmr_runs`` /
        ``genomic_runs`` dicts and the MS+NMR-only ``all_runs``
        property continue to work; new code should prefer ``runs``.
        """
        merged: dict[str, Any] = dict(self.ms_runs)
        for k, v in self.nmr_runs.items():
            merged.setdefault(k, v)
        for k, v in self.genomic_runs.items():
            merged.setdefault(k, v)
        return merged

    @property
    def all_runs_unified(self) -> Mapping[str, "Run"]:
        """Deprecated alias for :attr:`runs`. Kept for the brief
        Phase 1 → Phase 2 transition; remove in v1.0."""
        return self.runs

    def runs_for_sample(self, sample_uri: str) -> Mapping[str, "Run"]:
        """Return every run associated with ``sample_uri``.

        A run is considered associated when its
        :meth:`ttio.protocols.run.Run.provenance_chain` carries
        ``sample_uri`` in any record's ``input_refs``. Walks all
        modalities (MS, NMR, genomic) uniformly via the Run
        Protocol — closes the M91 cross-modality query gap that
        previously had to fork on access pattern.

        Returns a dict keyed by run name; empty when no run
        matches.
        """
        out: dict[str, Any] = {}
        for name, run in self.runs.items():
            try:
                chain = run.provenance_chain()
            except Exception:
                continue
            for prov in chain:
                if sample_uri in prov.input_refs:
                    out[name] = run
                    break
        return out

    def runs_of_modality(self, run_type: type) -> Mapping[str, "Run"]:
        """Return every run whose value is an instance of ``run_type``.

        Pass :class:`AcquisitionRun` to get the union of MS + NMR
        runs (any spectrum-class subtype); pass :class:`GenomicRun`
        to get genomic only. The return is a thin filter over
        :attr:`all_runs_unified`.
        """
        return {
            name: run
            for name, run in self.runs.items()
            if isinstance(run, run_type)
        }

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

        # Phase 2: ``runs`` may be a MIXED dict carrying both WrittenRun
        # (MS / NMR) and WrittenGenomicRun entries. Split them into the
        # legacy two-kwarg internal layout BEFORE any MS-only
        # introspection (e.g. activation_methods below). Callers using
        # the pre-Phase-2 form (separate ``runs=`` and ``genomic_runs=``
        # kwargs) are unaffected.
        if any(isinstance(v, WrittenGenomicRun) for v in runs.values()):
            split_ms: dict[str, WrittenRun] = {}
            split_g: dict[str, WrittenGenomicRun] = dict(genomic_runs or {})
            for name, value in runs.items():
                if isinstance(value, WrittenGenomicRun):
                    if name in split_g:
                        raise ValueError(
                            f"Phase 2 mixed runs dict: name {name!r} "
                            f"appears in both runs= and genomic_runs="
                        )
                    split_g[name] = value
                else:
                    split_ms[name] = value
            runs = split_ms
            genomic_runs = split_g

        # v1.0 single format-version stamp. Readers gate optional
        # features by the feature-flag list (opt_*), not by version
        # equality, so per-feature version bumps are unnecessary.
        any_m74 = any(
            run.activation_methods is not None for run in runs.values()
        )
        if features is None and any_m74:
            feature_list = feature_list + ["opt_ms2_activation_detail"]
        has_genomic = bool(genomic_runs)
        if has_genomic and "opt_genomic" not in feature_list:
            feature_list = feature_list + ["opt_genomic"]
        format_version = "1.0"

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
                    # M93 v1.2: embed referenced chromosome sequences at
                    # /study/references/<uri>/ before writing genomic runs,
                    # so the writer's REF_DIFF dispatch can resolve the
                    # md5 attribute back from disk if needed.
                    _embed_references_for_runs(study, genomic_runs)
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
                # M93 v1.2: embed referenced chromosome sequences before
                # writing the runs (provider path mirror of the HDF5 path).
                _embed_references_for_runs(study, genomic_runs)
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
    # v1.10 #10: opt-out for offsets-cumsum drop. Default False — new
    # files omit `spectrum_index/offsets` and `chromatogram_index/offsets`
    # (computed from `cumsum(lengths)` on read). Set True to keep the
    # offsets columns on disk for byte-equivalent backward compat with
    # pre-v1.10 readers.
    opt_keep_offsets_columns: bool = False


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
    # v1.10 #10: offsets is omitted by default — derivable from
    # cumsum(lengths). opt_keep_offsets_columns = True keeps it for
    # byte-equivalent backward compat with pre-v1.10 readers.
    columns: list[tuple[str, np.ndarray, str]] = [
        ("lengths", run.lengths, "<u4"),
        ("retention_times", run.retention_times, "<f8"),
        ("ms_levels", run.ms_levels, "<i4"),
        ("polarities", run.polarities, "<i4"),
        ("precursor_mzs", run.precursor_mzs, "<f8"),
        ("precursor_charges", run.precursor_charges, "<i4"),
        ("base_peak_intensities", run.base_peak_intensities, "<f8"),
    ]
    if getattr(run, "opt_keep_offsets_columns", False):
        columns.insert(0, ("offsets", run.offsets, "<u8"))
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
        write_chromatograms_to_run_group(
            g, run.chromatograms,
            keep_offsets_column=getattr(run, "opt_keep_offsets_columns", False),
        )


# M93 v1.2 — context-aware codec / reference-embed helpers.

def _any_v1_5_codec(
    genomic_runs: "Mapping[str, WrittenGenomicRun] | None",
) -> bool:
    """Return True if any run carries a v1.5 codec (REF_DIFF or FQZCOMP_NX16_Z).

    Used to gate the format-version bump from 1.4 → 1.5: only files that
    actually exercise an M93+ codec get the new version string, so
    M82-only writes preserve byte-parity with existing fixtures.

    M93 registered REF_DIFF as v1.5; M94.Z adds FQZCOMP_NX16_Z. Both are
    v1.5 codecs even though only REF_DIFF is "context-aware" in the M93
    sense (consumes sibling channels via the M86 pipeline hook).
    FQZCOMP_NX16_Z carries its sibling-channel metadata
    (``read_lengths``/``revcomp_flags``) inside the codec wire format,
    so it does not register as context-aware in :mod:`._codec_meta`,
    but it IS a v1.5 codec for format-version-gating purposes.
    """
    if not genomic_runs:
        return False
    from .enums import Compression as _Compression
    _V1_5_CODECS = frozenset({
        _Compression.REF_DIFF,         # M93
        _Compression.FQZCOMP_NX16_Z,   # M94.Z (CRAM-mimic rANS-Nx16)
    })
    for run in genomic_runs.values():
        for codec in run.signal_codec_overrides.values():
            try:
                ce = _Compression(codec)
            except ValueError:
                continue
            if ce in _V1_5_CODECS:
                return True
    return False


# Back-compat alias — pre-M94 callers used this name.
_any_context_aware_codec = _any_v1_5_codec


def _reference_md5_for_run(run: WrittenGenomicRun) -> bytes:
    """MD5 of concatenated chromosome sequences, in sorted-name order.

    Mirrors the on-disk ``@md5`` attribute computation. Returns an empty
    digest when ``reference_chrom_seqs`` is absent.
    """
    import hashlib
    if run.reference_chrom_seqs is None:
        return b""
    md5 = hashlib.md5()
    for chrom_name in sorted(run.reference_chrom_seqs):
        md5.update(run.reference_chrom_seqs[chrom_name])
    return md5.digest()


def _embed_references_for_runs(
    study, genomic_runs: "Mapping[str, WrittenGenomicRun]",
) -> None:
    """Embed each unique reference (by ``reference_uri``) once at
    ``/study/references/<reference_uri>/``.

    Only runs that have ``embed_reference=True`` AND a context-aware
    codec override on ``sequences`` AND non-None ``reference_chrom_seqs``
    contribute; the dedup key is ``reference_uri``. When the same URI
    carries two different MD5s across runs, raises :class:`ValueError`
    (Q6 = C, single source of truth per file).

    Accepts either a raw ``h5py.Group`` (HDF5 fast path) or a
    :class:`StorageGroup` (provider path). Internally normalises to
    ``StorageGroup``.
    """
    from .codecs._codec_meta import is_context_aware
    from .enums import Compression as _Compression, Precision as _Precision
    from .providers.hdf5 import _Group as _H5Group

    from .codecs import ref_diff_v2 as _rdv2_meta

    needs_embed: dict[str, tuple[bytes, dict[str, bytes]]] = {}
    for run in genomic_runs.values():
        if not run.embed_reference:
            continue
        if run.reference_chrom_seqs is None:
            continue
        # Embed if a context-aware codec override is set on this run,
        # OR if the v1.8 REF_DIFF_V2 default path will be used (when the
        # native lib is available and opt_disable_ref_diff_v2 is not set).
        _has_context_aware_override = any(
            is_context_aware(_Compression(c))
            for c in run.signal_codec_overrides.values()
            if _is_valid_compression(c)
        )
        _uses_ref_diff_v2_default = (
            not getattr(run, "opt_disable_ref_diff_v2", False)
            and _rdv2_meta.HAVE_NATIVE_LIB
            and not any(c == "*" or c == "" for c in run.cigars)
        )
        if not (_has_context_aware_override or _uses_ref_diff_v2_default):
            continue
        md5 = _reference_md5_for_run(run)
        if run.reference_uri in needs_embed:
            existing_md5, _ = needs_embed[run.reference_uri]
            if existing_md5 != md5:
                raise ValueError(
                    f"reference_uri {run.reference_uri!r} carries two "
                    "different MD5s across runs in this dataset: "
                    f"{existing_md5.hex()} vs {md5.hex()} — same URI "
                    "cannot map to two different reference contents."
                )
            continue
        needs_embed[run.reference_uri] = (md5, dict(run.reference_chrom_seqs))

    if not needs_embed:
        return

    # Normalise study to a StorageGroup so create_group / create_dataset
    # have a single API surface.
    if isinstance(study, h5py.Group):
        study_sg = _H5Group(study)
    else:
        study_sg = study

    if study_sg.has_child("references"):
        refs_grp = study_sg.open_group("references")
    else:
        refs_grp = study_sg.create_group("references")

    for uri, (md5, chrom_seqs) in needs_embed.items():
        if refs_grp.has_child(uri):
            existing = refs_grp.open_group(uri)
            existing_md5_hex = io.read_string_attr(existing, "md5") or ""
            if existing_md5_hex != md5.hex():
                raise ValueError(
                    f"reference_uri {uri!r} already embedded with a "
                    f"different MD5 ({existing_md5_hex!r} != "
                    f"{md5.hex()!r}); same URI cannot map to two "
                    "different reference contents in one file."
                )
            continue
        ref_grp = refs_grp.create_group(uri)
        io.write_fixed_string_attr(ref_grp, "md5", md5.hex())
        io.write_fixed_string_attr(ref_grp, "reference_uri", uri)
        chroms_grp = ref_grp.create_group("chromosomes")
        for chrom_name in sorted(chrom_seqs):
            seq = chrom_seqs[chrom_name]
            c = chroms_grp.create_group(chrom_name)
            io.write_int_attr(c, "length", len(seq))
            arr = np.frombuffer(seq, dtype=np.uint8)
            ds = c.create_dataset(
                "data",
                _Precision.UINT8,
                length=int(arr.shape[0]),
                chunk_size=io.DEFAULT_SIGNAL_CHUNK,
                compression=_Compression.ZLIB,
                compression_level=6,
            )
            ds.write(arr)


def _is_valid_compression(value: object) -> bool:
    from .enums import Compression as _Compression
    try:
        _Compression(value)
        return True
    except ValueError:
        return False


def _write_sequences_ref_diff(sc, run: WrittenGenomicRun) -> None:
    """Write the ``sequences`` channel through the REF_DIFF codec.

    v1.8+ default: when libttio_rans is loadable AND the run isn't
    opting out AND the v1 REF_DIFF eligibility checks pass (single-
    chromosome, all reads mapped, reference present), write
    signal_channels/sequences as a GROUP containing a refdiff_v2
    child dataset (@compression = 14).

    Opt-out / fallback paths:
    - ``opt_disable_ref_diff_v2 = True``: write the existing v1 REF_DIFF
      flat dataset (@compression = 9) or BASE_PACK fallback (@compression
      = 6). v1 layout is also used when the native lib is unavailable or
      eligibility checks fail (unmapped reads / no reference).
    - Q5b = C: missing reference or unmapped reads → BASE_PACK silently.

    **Single-chromosome limitation (v1.2 first pass):** both v1 and v2
    paths require all reads aligned to a single chromosome. Multi-
    chromosome runs raise :class:`ValueError`.
    """
    from .codecs import ref_diff_v2 as _rdv2
    from .codecs.ref_diff import encode as _ref_diff_encode
    from .codecs.base_pack import encode as _base_pack_encode
    from .enums import Compression as _Compression, Precision as _Precision

    # Resolve the reference sequence for this run.
    chrom_seq: bytes | None = None
    if run.reference_chrom_seqs is not None:
        unique_chroms = set(run.chromosomes)
        if len(unique_chroms) == 0:
            chrom_seq = None
        elif len(unique_chroms) > 1:
            raise ValueError(
                "REF_DIFF v1.2 first pass supports single-chromosome runs only; "
                f"this run carries reads on chromosomes {sorted(unique_chroms)}. "
                "Multi-chromosome support is an M93.X follow-up — split into "
                "per-chromosome runs as a workaround."
            )
        else:
            chrom = next(iter(unique_chroms))
            chrom_seq = run.reference_chrom_seqs.get(chrom)

    raw_bytes = bytes(run.sequences.tobytes())

    # M93 v1.2: REF_DIFF can't encode unmapped reads (cigar="*"). When
    # any read in the run is unmapped, fall back to BASE_PACK on the
    # whole channel — same Q5b=C semantics as missing-reference.
    has_unmapped = any(c == "*" or c == "" for c in run.cigars)

    # v1.8 dispatch: prefer the v2 path when eligible.
    use_v2 = (
        not getattr(run, "opt_disable_ref_diff_v2", False)
        and _rdv2.HAVE_NATIVE_LIB
        and chrom_seq is not None
        and not has_unmapped
    )

    if use_v2:
        # v1.8 path: encode via ref_diff_v2 and write as a GROUP with
        # a refdiff_v2 child dataset (@compression = 14).
        positions = np.asarray(run.positions, dtype=np.int64)
        n = len(run.cigars)
        # Build n_reads+1 offsets array from run.offsets (n entries)
        # and run.lengths (n entries): append the total base count.
        offsets_arr = np.asarray(run.offsets, dtype=np.uint64)
        if offsets_arr.shape[0] == n:
            total_len = int(offsets_arr[-1]) + int(run.lengths[-1]) if n > 0 else 0
            offsets_arr = np.append(offsets_arr, np.uint64(total_len))
        elif offsets_arr.shape[0] != n + 1:
            raise ValueError(
                f"run.offsets must have n_reads or n_reads+1 entries; "
                f"got {offsets_arr.shape[0]} for n={n}"
            )

        md5 = _reference_md5_for_run(run)
        sequences_arr = np.asarray(run.sequences, dtype=np.uint8)
        encoded = _rdv2.encode(
            sequences_arr,
            offsets_arr,
            positions,
            list(run.cigars),
            chrom_seq,
            md5,
            run.reference_uri,
            reads_per_slice=10_000,
        )
        arr = np.frombuffer(encoded, dtype=np.uint8)
        seq_group = sc.create_group("sequences")
        ds = seq_group.create_dataset(
            "refdiff_v2",
            _Precision.UINT8,
            length=int(arr.shape[0]),
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=_Compression.NONE,
        )
        ds.write(arr)
        io.write_int_attr(ds, "compression", int(_Compression.REF_DIFF_V2), dtype="<u1")
        return

    # v1 path (unchanged): flat dataset with REF_DIFF or BASE_PACK.
    if chrom_seq is None or has_unmapped:
        # Q5b = C: silent fallback to BASE_PACK on this channel.
        encoded = _base_pack_encode(raw_bytes)
        codec_id = int(_Compression.BASE_PACK)
    else:
        # Split sequences into per-read slices using offsets/lengths.
        offsets = [int(o) for o in run.offsets]
        lengths = [int(l) for l in run.lengths]
        per_read: list[bytes] = []
        for off, ln in zip(offsets, lengths):
            per_read.append(raw_bytes[off:off + ln])
        positions = [int(p) for p in run.positions]
        cigars = list(run.cigars)
        md5 = _reference_md5_for_run(run)
        encoded = _ref_diff_encode(
            per_read, cigars, positions, chrom_seq, md5, run.reference_uri,
        )
        codec_id = int(_Compression.REF_DIFF)

    arr = np.frombuffer(encoded, dtype=np.uint8)
    ds = sc.create_dataset(
        "sequences",
        _Precision.UINT8,
        length=int(arr.shape[0]),
        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
        compression=_Compression.NONE,
    )
    ds.write(arr)
    io.write_int_attr(ds, "compression", codec_id, dtype="<u1")


# M94.Z — FQZCOMP_NX16_Z quality codec. Same dispatch pattern as
# _write_sequences_ref_diff but for the qualities channel.
SAM_REVERSE_FLAG = 16


def _write_qualities_fqzcomp_nx16_z(sc, run: WrittenGenomicRun) -> None:
    """Write the ``qualities`` channel through the FQZCOMP_NX16_Z codec.

    M94.Z is the CRAM-mimic rANS-Nx16 variant — parallel to v1, same
    sibling-channel inputs (read_lengths + revcomp_flags) but a different
    on-wire format (magic ``M94Z`` instead of ``FQZN``). Codec id 12.
    """
    from .codecs.fqzcomp_nx16_z import encode as _fqzcomp_z_encode
    from .enums import Compression as _Compression, Precision as _Precision

    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp_flags = [
        1 if (int(f) & SAM_REVERSE_FLAG) else 0 for f in run.flags
    ]

    encoded = _fqzcomp_z_encode(qualities, read_lengths, revcomp_flags)

    arr = np.frombuffer(encoded, dtype=np.uint8)
    ds = sc.create_dataset(
        "qualities",
        _Precision.UINT8,
        length=int(arr.shape[0]),
        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
        compression=_Compression.NONE,
    )
    ds.write(arr)
    io.write_int_attr(
        ds, "compression",
        int(_Compression.FQZCOMP_NX16_Z), dtype="<u1",
    )


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
            # M93 v1.2: reference-based diff. Context-aware codec —
            # the writer plumbs positions, cigars, and the reference
            # sequences through to ref_diff.encode(); per-channel
            # validation here only checks codec applicability.
            _Compression.REF_DIFF,
        }),
        "qualities": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.BASE_PACK,
            _Compression.QUALITY_BINNED,
            # M94.Z v1.2: CRAM-mimic rANS-Nx16 quality codec. Carries its
            # own read_lengths + needs revcomp_flags from run.flags & 16.
            _Compression.FQZCOMP_NX16_Z,
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
        # v1.6: positions / flags / mapping_qualities REMOVED from the
        # override surface. These per-record integer fields live only
        # in genomic_index/ now. See _DROPPED_INT_CHANNELS below for
        # the explicit reject path. (M86 Phase B integer-channel
        # codec wiring under signal_channels/ was a write-side
        # optimisation per former format-spec §10.7 — no reader ever
        # consumed those bytes; the genomic_index/ copy is canonical.)
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
            _Compression.DELTA_RANS_ORDER0,
        }),
        "mate_info_tlen": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
            _Compression.DELTA_RANS_ORDER0,
        }),
    }
    _INTEGER_CHANNEL_NAMES = frozenset(
        {"mate_info_pos", "mate_info_tlen"}
    )
    _MATE_INFO_FIELD_NAMES = frozenset(
        {"mate_info_chrom", "mate_info_pos", "mate_info_tlen"}
    )
    # v1.6: per-record integer metadata channels removed from the
    # signal_channels/ override surface. They live exclusively in
    # genomic_index/ now (see comment above). Hard-error so callers
    # with stale code learn immediately.
    _DROPPED_INT_CHANNELS = frozenset(
        {"positions", "flags", "mapping_qualities"}
    )
    for ch_name, codec in run.signal_codec_overrides.items():
        if ch_name in _DROPPED_INT_CHANNELS:
            raise ValueError(
                f"signal_codec_overrides[{ch_name!r}]: removed in v1.6 — "
                f"per-record integer metadata fields ({sorted(_DROPPED_INT_CHANNELS)!r}) "
                f"are stored only under genomic_index/, not "
                f"signal_channels/. The override no longer applies. "
                f"See docs/format-spec.md §4 and §10.7."
            )
        # v1.7 #11: per-field mate_info_* overrides are disallowed
        # when the inline_v2 codec is active (the default in v1.7+).
        # Set opt_disable_inline_mate_info_v2 = True to use the v1
        # layout with per-field overrides.
        if ch_name in ("mate_info_chrom", "mate_info_pos", "mate_info_tlen"):
            if not getattr(run, "opt_disable_inline_mate_info_v2", False):
                raise ValueError(
                    f"signal_codec_overrides[{ch_name!r}]: per-field "
                    "mate_info_* overrides are disallowed when the "
                    "v1.7 inline_v2 codec is active. Set "
                    "opt_disable_inline_mate_info_v2=True on "
                    "WrittenGenomicRun to use the v1 layout "
                    "(three independent compressed streams)."
                )
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
    idx.write(idx_group, keep_offsets_column=getattr(
        run, "opt_keep_offsets_columns", False))

    # Signal channels — these honour run.signal_compression by default;
    # M86 lets per-channel overrides route sequences/qualities through
    # the rANS / BASE_PACK codecs instead.
    sc = rg.create_group("signal_channels")

    # M93 v1.2: REF_DIFF is a context-aware codec — encoding requires
    # positions, cigars, and the reference sequence in addition to the
    # raw byte stream. Dispatch on a special branch when the override
    # selects it; everything else falls through to the existing helper.
    _seq_codec = run.signal_codec_overrides.get("sequences")
    # v1.5 default codec lookup (Q5a=B, no feature flag): when caller
    # has not selected a per-channel codec AND signal_compression is the
    # "auto-pick best lossless" gzip default AND a reference is available,
    # apply REF_DIFF. The REF_DIFF branch below handles BASE_PACK
    # fallback (Q5b=C) when ref is absent.
    if (
        _seq_codec is None
        and run.signal_compression == "gzip"
        and run.reference_chrom_seqs is not None
    ):
        from .genomic._default_codecs import default_codec_for
        _default = default_codec_for("sequences")
        if _default is not None:
            _seq_codec = _default

    # M94.Z v1.2: FQZCOMP_NX16_Z is a v1.5 quality codec — carries
    # read_lengths + revcomp_flags inside the codec wire format. Apply
    # auto-default (Q5a=B): when signal_compression="gzip" AND empty
    # qualities override AND the run is ALREADY a v1.5 candidate (i.e.
    # at least one v1.5 codec is active on this run, whether through an
    # explicit override or the REF_DIFF auto-default we just resolved
    # for sequences), use FQZCOMP_NX16_Z.
    #
    # The "v1.5 candidate" gate preserves byte-parity for pure-M82
    # baseline writes (no reference, no v1.5 overrides) — those keep
    # the legacy uncompressed/zlib qualities path so existing M82+
    # fixtures remain stable.
    _qual_codec = run.signal_codec_overrides.get("qualities")
    _is_v1_5_candidate = False
    if (
        _qual_codec is None
        and run.signal_compression == "gzip"
    ):
        # Detect v1.5 candidacy: any explicit override is a v1.5 codec,
        # or the sequences channel is going through REF_DIFF (resolved
        # above into _seq_codec).
        if (_seq_codec is not None
                and _is_valid_compression(_seq_codec)
                and _Compression(_seq_codec) == _Compression.REF_DIFF):
            _is_v1_5_candidate = True
        else:
            for _ovr in run.signal_codec_overrides.values():
                if _is_valid_compression(_ovr):
                    _ce = _Compression(_ovr)
                    if _ce in (
                        _Compression.REF_DIFF,
                        _Compression.FQZCOMP_NX16_Z,
                        _Compression.DELTA_RANS_ORDER0,
                    ):
                        _is_v1_5_candidate = True
                        break
        if _is_v1_5_candidate:
            from .genomic._default_codecs import default_codec_for
            _default = default_codec_for("qualities")
            if _default is not None:
                _qual_codec = _default

    def _resolve_int_override(channel: str):
        ovr = run.signal_codec_overrides.get(channel)
        if ovr is not None:
            return ovr
        if _is_v1_5_candidate:
            from .genomic._default_codecs import default_codec_for
            d = default_codec_for(channel)
            if d is not None:
                return d
        return None

    # v1.6: positions / flags / mapping_qualities are NOT written
    # under signal_channels/. They live exclusively in genomic_index/,
    # mirroring MS's spectrum_index/ pattern (per-record metadata =
    # index; signal_channels = bulk data). See docs/format-spec.md
    # §4 and §10.7. Override-validation rejects these channel names.
    # Old files (v1.5 and earlier) may carry these under
    # signal_channels/ — readers ignore them; the genomic_index/ copy
    # is canonical.
    if (
        _seq_codec is not None
        and _is_valid_compression(_seq_codec)
        and _Compression(_seq_codec) == _Compression.REF_DIFF
    ):
        _write_sequences_ref_diff(sc, run)
    else:
        io._write_byte_channel_with_codec(
            sc, "sequences", run.sequences, run.signal_compression,
            _seq_codec,
        )
    if (
        _qual_codec is not None
        and _is_valid_compression(_qual_codec)
        and _Compression(_qual_codec) == _Compression.FQZCOMP_NX16_Z
    ):
        _write_qualities_fqzcomp_nx16_z(sc, run)
    else:
        io._write_byte_channel_with_codec(
            sc, "qualities", run.qualities, run.signal_compression,
            _qual_codec,
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
    # M86 Phase E + v1.8 #11 ch3: schema lift for read_names with v2 dispatch.
    # Three layouts (mutually exclusive within a single run):
    #
    # - **NAME_TOKENIZED v1** (codec id 8): flat 1-D uint8 dataset
    #   ``read_names`` with @compression == 8. Selected when the user
    #   explicitly passes ``signal_codec_overrides["read_names"] =
    #   Compression.NAME_TOKENIZED`` OR sets ``opt_disable_name_tokenized_v2``
    #   AND no override is set.
    # - **NAME_TOKENIZED v2** (codec id 15): flat 1-D uint8 dataset
    #   ``read_names`` with @compression == 15. The v1.8 default —
    #   selected when no override is present, ``opt_disable_name_tokenized_v2``
    #   is False, and the native lib is available.
    # - **M82 compound** (no codec): VL_STRING-in-compound dataset.
    #   Selected only when the v1 fallback is requested but no override
    #   was set (the historical no-override case).
    #
    # Readers dispatch on @compression value (8 vs 15) when shape is
    # uint8, else fall through to the compound path. No HDF5 filter is
    # applied — codec output is high-entropy (Binding Decision §87).
    from .codecs import name_tokenizer_v2 as _nt2
    from .enums import Precision as _Precision
    _rn_override = run.signal_codec_overrides.get("read_names")
    _use_rn_v2 = (
        _rn_override is None
        and not getattr(run, "opt_disable_name_tokenized_v2", False)
        and _nt2.HAVE_NATIVE_LIB
    )
    if _use_rn_v2:
        encoded = _nt2.encode(list(run.read_names))
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
            int(_Compression.NAME_TOKENIZED_V2), dtype="<u1",
        )
    elif _rn_override is not None:
        from .codecs import name_tokenizer as _nt
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
    # v1.7 #11: mate_info dispatch. Default path (opt_disable_inline_mate_info_v2
    # == False AND native lib available): encode all three mate fields into a
    # single inline_v2 blob (codec id 13) written under
    # signal_channels/mate_info/inline_v2. Fallback v1 path (opt-out or no
    # native lib): M86 Phase F subgroup with per-field datasets, or M82
    # compound when no per-field overrides are set.
    from .codecs import mate_info_v2 as _miv2
    _use_v2 = (
        not getattr(run, "opt_disable_inline_mate_info_v2", False)
        and _miv2.HAVE_NATIVE_LIB
    )
    if _use_v2:
        _write_mate_info_inline_v2(sc, run)
    else:
        # v1 path: M86 Phase F per-field subgroup if overrides present,
        # else M82 compound (no mate_info_* override keys when v2 is
        # disabled — validation above already blocked them when v2 active).
        _mate_override_keys = {
            "mate_info_chrom", "mate_info_pos", "mate_info_tlen",
        }
        _mate_overrides = {}
        for k in _mate_override_keys:
            _resolved = _resolve_int_override(k)
            if _resolved is not None:
                _mate_overrides[k] = _resolved
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
        _Compression.DELTA_RANS_ORDER0,
    ):  # pragma: no cover — validation rejects this
        raise ValueError(
            f"signal_codec_overrides['mate_info_{name}']: codec "
            f"{codec!r} is not supported (only RANS_ORDER0, "
            "RANS_ORDER1, and DELTA_RANS_ORDER0 are valid for "
            "the integer mate fields)"
        )

    le_bytes = bytes(np.ascontiguousarray(arr).tobytes())
    if codec_enum == _Compression.DELTA_RANS_ORDER0:
        from .codecs.delta_rans import encode as _dra_enc
        elem_size = {"<i8": 8, "<i4": 4, "<u4": 4, "<u1": 1}[dtype_str]
        encoded = _dra_enc(le_bytes, element_size=elem_size)
    else:
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


def _build_chrom_id_table(chromosomes: list[str]) -> "tuple[np.ndarray, dict[str, int]]":
    """Encounter-order chrom_id assignment matching the L1 contract.

    Returns (uint16 array of chrom_ids per record, dict name -> id).
    Uses 0xFFFF for unmapped records ('*' or empty string).
    """
    name_to_id: dict[str, int] = {}
    ids = np.empty(len(chromosomes), dtype=np.uint16)
    for i, name in enumerate(chromosomes):
        if name == "*" or not name:
            ids[i] = 0xFFFF
            continue
        if name not in name_to_id:
            name_to_id[name] = len(name_to_id)
        ids[i] = name_to_id[name]
    return ids, name_to_id


def _resolve_mate_chrom_ids(
    mate_chromosomes: list[str],
    own_chrom_ids: "np.ndarray",
    name_to_id: "dict[str, int]",
) -> "np.ndarray":
    """Map mate chromosome names to int32 ids; -1 for '*'.

    Uses the same encounter-order dict as own_chrom_ids; extends the
    dict if a mate references a chrom that never appears as own
    (rare cross-chrom case). The '=' SAM shortcut is resolved to the
    record's own chrom_id. name_to_id is copied and not mutated.
    """
    n = len(mate_chromosomes)
    out = np.empty(n, dtype=np.int32)
    local_map = dict(name_to_id)
    for i, name in enumerate(mate_chromosomes):
        if name == "*" or not name:
            out[i] = -1
        elif name == "=":
            own = own_chrom_ids[i]
            out[i] = -1 if own == 0xFFFF else int(own)
        else:
            if name not in local_map:
                local_map[name] = len(local_map)
            out[i] = local_map[name]
    return out


def _write_mate_info_inline_v2(sc, run: "WrittenGenomicRun") -> None:
    """v1.7+ inline_v2 writer per spec §4.

    Encodes the full mate triple via libttio_rans (the cross-language
    byte-exact codec from T11) and writes the result as a single
    uint8 blob at signal_channels/mate_info/inline_v2.

    Also writes signal_channels/mate_info/chrom_names — a compound
    dataset mapping chrom_id (uint16) → name (VL_STRING). This covers
    mate-only chromosomes (e.g. a cross-chromosome mate on a chrom that
    no own-read lands on) which are absent from genomic_index/chromosome_names.
    The reader uses this table to resolve mate_chrom_ids returned by
    ttio_mate_info_v2_decode back to string names.
    """
    from .codecs import mate_info_v2 as _miv2
    from .enums import Compression as _Compression, Precision as _Precision

    own_chrom_ids, name_to_id = _build_chrom_id_table(run.chromosomes)
    mate_chrom_ids = _resolve_mate_chrom_ids(
        run.mate_chromosomes, own_chrom_ids, name_to_id)

    # After _resolve_mate_chrom_ids, name_to_id may have been extended
    # for mate-only chroms. Reconstruct the full ordered list from the
    # (possibly extended) local map used by _resolve_mate_chrom_ids.
    # Since _resolve_mate_chrom_ids uses a copy, we rebuild from scratch.
    full_name_to_id: dict[str, int] = dict(name_to_id)
    for name in run.mate_chromosomes:
        if name and name not in ("*", "=") and name not in full_name_to_id:
            full_name_to_id[name] = len(full_name_to_id)
    chrom_names_in_order = sorted(full_name_to_id.keys(),
                                  key=lambda n: full_name_to_id[n])

    encoded = _miv2.encode(
        mate_chrom_ids=mate_chrom_ids,
        mate_positions=np.asarray(run.mate_positions, dtype=np.int64),
        template_lengths=np.asarray(run.template_lengths, dtype=np.int32),
        own_chrom_ids=own_chrom_ids,
        own_positions=np.asarray(run.positions, dtype=np.int64),
    )
    arr = np.frombuffer(encoded, dtype=np.uint8)

    mate_group = sc.create_group("mate_info")
    ds = mate_group.create_dataset(
        "inline_v2",
        _Precision.UINT8,
        length=int(arr.shape[0]),
        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
        compression=_Compression.NONE,
    )
    ds.write(arr)
    io.write_int_attr(ds, "compression",
                      int(_Compression.MATE_INLINE_V2), dtype="<u1")

    # Write the full chrom_id → name lookup table (encounter-order, id = row index).
    io.write_compound_dataset(
        mate_group,
        "chrom_names",
        [{"name": n} for n in chrom_names_in_order],
        [("name", io.vl_str())],
    )


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
