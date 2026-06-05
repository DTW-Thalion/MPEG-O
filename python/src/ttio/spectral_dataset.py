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
from types import MappingProxyType, TracebackType
from typing import Any, Iterator, Mapping

import h5py
import numpy as np

from . import _hdf5_io as io
from ._rwlock import RWLock
from .access_policy import AccessPolicy
from .io.progress import ProgressSinkLike, _fire
from .acquisition_run import AcquisitionRun
from .genomic.reference_import import ReferenceImport  # tio-browser Phase 0
from .genomic_run import GenomicRun  # M82
from .enums import EncryptionLevel
from .feature_flags import FeatureFlags
from .ir_image import IRImage
from .ms_image import MSImage
from .raman_image import RamanImage
from .identification import Identification
from .providers import StorageProvider, open_provider
from .providers.base import StorageGroup
from .providers.hdf5 import Hdf5Provider
from .provenance import ProvenanceRecord
from .quantification import Quantification
from .sample import Sample  # Stage 6 (transport-spec v0.11, Deferral 2)
from .subject import Subject  # Stage 6 (transport-spec v0.11, Deferral 2)
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
    feature_flags: FeatureFlags
    title: str
    isa_investigation_id: str
    ms_runs: dict[str, AcquisitionRun] = field(default_factory=dict)
    nmr_runs: dict[str, AcquisitionRun] = field(default_factory=dict)
    genomic_runs: dict[str, GenomicRun] = field(default_factory=dict)  # M82
    # Embedded references at /study/references/<uri>/, populated on
    # open() from the canonical embed layout (see
    # :func:`_embed_references_for_runs` for the writer side). Empty
    # for files without an embedded reference, including those whose
    # genomic runs use ``embed_reference=False``. Mirrors Java's
    # ``SpectralDataset.references()`` (added Phase 0 of tio-browser).
    _references: dict[str, "ReferenceImport"] = field(default_factory=dict)
    encrypted_algorithm: str = ""
    _closed: bool = False
    _remote_fileobj: Any = None  # fsspec file-like kept alive when remote
    _lock: RWLock | None = None  # set when opened with thread_safe=True
    provider: StorageProvider | None = None  # owning storage provider
    # ``provider`` is the backend abstraction introduced in M39. Byte-level
    # code (signatures, encryption, signal-channel codecs) reaches the
    # underlying ``h5py.File`` via ``provider.native_handle()``; call sites
    # should prefer ``provider.root_group()`` for protocol access.
    # Encryptable conformance.
    _access_policy: AccessPolicy | None = field(default=None, repr=False)
    # Lazy image cache — populated on first access of the `image` property.
    _image_cache_loaded: bool = field(default=False, repr=False)
    _image_cache: "MSImage | None" = field(default=None, repr=False)
    # Lazy raman_image cache — populated on first access of the `raman_image` property.
    _raman_image_cache_loaded: bool = field(default=False, repr=False)
    _raman_image_cache: "RamanImage | None" = field(default=None, repr=False)
    # Lazy ir_image cache — populated on first access of the `ir_image` property.
    _ir_image_cache_loaded: bool = field(default=False, repr=False)
    _ir_image_cache: "IRImage | None" = field(default=None, repr=False)
    # Stage 6 (transport-spec v0.11, Deferral 2): lazy subject + sample
    # caches. Populated on first access of the `subjects` / `samples`
    # property by enumerating `/study/subjects/` / `/study/samples/`.
    _subjects_cache_loaded: bool = field(default=False, repr=False)
    _subjects_cache: list[Subject] = field(default_factory=list, repr=False)
    _samples_cache_loaded: bool = field(default=False, repr=False)
    _samples_cache: list[Sample] = field(default_factory=list, repr=False)

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
                provider = Hdf5Provider._from_open_h5py(f)
                return cls._from_provider(Path(str(path)), provider,
                                          thread_safe=thread_safe,
                                          _remote_fileobj=fileobj)
            except Exception:
                f.close()
                fileobj.close()
                raise

        # URL scheme detection routes non-HDF5 providers
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
        # if an explicit provider name is given for a bare path, route
        # through open_provider so Memory / SQLite / Zarr backends work.
        if provider is not None and provider not in ("hdf5", "h5", "h5py"):
            sp = open_provider(str(path), provider=provider, mode=mode)
            try:
                return cls._from_provider(p, sp, thread_safe=thread_safe)
            except Exception:
                sp.close()
                raise
        provider = Hdf5Provider.open(str(p), mode=mode)
        try:
            return cls._from_provider(p, provider, thread_safe=thread_safe)
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
        _remote_fileobj: Any = None,
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

        references_map = _load_references_provider(study)

        return cls(
            path=path,
            feature_flags=flags,
            title=title,
            isa_investigation_id=isa,
            ms_runs=ms_runs,
            nmr_runs=nmr_runs,
            genomic_runs=genomic_runs_map,  # M82
            _references=references_map,
            encrypted_algorithm=encrypted,
            _remote_fileobj=_remote_fileobj,
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
        """Release the underlying HDF5 file, provider, and remote handles.

        Idempotent: calling :meth:`close` on an already-closed dataset is
        a no-op. Invoked automatically by the context-manager protocol
        (``with SpectralDataset.open(...) as ds:``) and from ``__del__``
        as a best-effort safety net.
        """
        with self.write_lock():
            if not self._closed:
                # Close via the provider when we have one — it owns the
                # h5py.File and any fsspec file-like. Fall back to direct
                # close for legacy instances constructed without M39.
                if self.provider is not None:
                    self.provider.close()
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
        """Whether the dataset's signal payload is encrypted.

        Returns
        -------
        bool
            True when an ``@encrypted_algorithm`` attribute was recorded
            on the root group at write time (regardless of which
            channels carry ciphertext). False for plaintext datasets.
        """
        return bool(self.encrypted_algorithm)

    @property
    def references(self) -> Mapping[str, ReferenceImport]:
        """Embedded references at ``/study/references/<uri>/``, keyed
        by URI string.

        Populated on :meth:`open` from the canonical embed layout (see
        :func:`_embed_references_for_runs`). Empty for files without
        embedded references — including those whose genomic runs use
        ``embed_reference=False`` (the v1.2+ default), which keep the
        ``reference_uri`` attribute but rely on the
        :class:`ReferenceResolver` for byte resolution.

        The return is a read-only view: mutations on the returned
        mapping do not affect the dataset. Mirrors Java's
        ``SpectralDataset.references()`` (added Phase 0 of
        tio-browser).

        :since: 1.1.0
        """
        # Deliberate tightening over `all_runs` etc.: /study/references/
        # is a write-once-on-open snapshot, so we expose it as a true
        # read-only view (mutation raises TypeError) rather than a
        # cheap dict copy. Added in 1.1.0.
        return MappingProxyType(self._references)

    def _lazy_ms_image(self) -> "MSImage | None":
        """Lazy-read the embedded MSImage at /study/image_cube.

        Reads the cube on first access, caches the result. Returns
        ``None`` when no image group exists.
        """
        if not self._image_cache_loaded:
            self._image_cache_loaded = True
            if self.provider is None:
                self._image_cache = None
            else:
                root = self.provider.root_group()
                if root.has_child("study"):
                    study = root.open_group("study")
                    self._image_cache = MSImage.read_from(study)
                # else: _image_cache stays None (already initialized)
        return self._image_cache

    def _lazy_raman_image(self) -> "RamanImage | None":
        """Lazy-read the embedded RamanImage at /study/raman_image_cube.

        Reads the cube on first access, caches the result. Returns
        ``None`` when no raman image group exists.
        """
        if not self._raman_image_cache_loaded:
            self._raman_image_cache_loaded = True
            if self.provider is None:
                self._raman_image_cache = None
            else:
                root = self.provider.root_group()
                if root.has_child("study"):
                    study = root.open_group("study")
                    self._raman_image_cache = RamanImage.read_from(study)
                # else: _raman_image_cache stays None (already initialized)
        return self._raman_image_cache

    def _lazy_ir_image(self) -> "IRImage | None":
        """Lazy-read the embedded IRImage at /study/ir_image_cube.

        Reads the cube on first access, caches the result. Returns
        ``None`` when no IR image group exists. Stage 5.2
        (transport-spec v0.11, Deferral 1).
        """
        if not self._ir_image_cache_loaded:
            self._ir_image_cache_loaded = True
            if self.provider is None:
                self._ir_image_cache = None
            else:
                root = self.provider.root_group()
                if root.has_child("study"):
                    study = root.open_group("study")
                    self._ir_image_cache = IRImage.read_from(study)
                # else: _ir_image_cache stays None (already initialized)
        return self._ir_image_cache

    def image_for_kind(self, kind: "ImageKind") -> "Image | None":
        """The embedded :class:`~ttio.image.Image` for the given
        :class:`~ttio.enums.ImageKind`, or ``None`` when that modality
        is absent.

        Lazy per-kind: reads the cube on first access and caches the
        result. Replaces the former typed ``image`` / ``raman_image``
        / ``ir_image`` accessors with a uniform lookup.

        :since: 1.2.0
        """
        from .enums import ImageKind
        if kind == ImageKind.MS:
            return self._lazy_ms_image()
        if kind == ImageKind.RAMAN:
            return self._lazy_raman_image()
        if kind == ImageKind.IR:
            return self._lazy_ir_image()
        raise ValueError(f"unknown ImageKind: {kind!r}")

    @property
    def images(self) -> "dict[ImageKind, Image]":
        """Embedded images keyed by :class:`~ttio.enums.ImageKind`,
        containing only the modalities present on this dataset.

        Each entry is materialised lazily via :meth:`image_for_kind`
        (per-kind cache preserved). Absent modalities are omitted.

        :since: 1.2.0
        """
        from .enums import ImageKind
        out: "dict[ImageKind, Image]" = {}
        for k in (ImageKind.MS, ImageKind.RAMAN, ImageKind.IR):
            img = self.image_for_kind(k)
            if img is not None:
                out[k] = img
        return out

    @property
    def subjects(self) -> list[Subject]:
        """List of :class:`~ttio.subject.Subject` rows persisted under
        ``/study/subjects/`` on this dataset, in on-disk iteration
        order. Empty list when no Subjects were written (which is
        most pre-Stage-6 files). Lazily populated on first access.

        Stage 6 (transport-spec v0.11, Deferral 2). Mirrors Java
        :meth:`global.thalion.ttio.SpectralDataset.subjects`.

        :since: 1.4.0
        """
        if not self._subjects_cache_loaded:
            self._subjects_cache_loaded = True
            self._subjects_cache = _read_subjects(self.provider, None)
        return self._subjects_cache

    @property
    def samples(self) -> list[Sample]:
        """List of :class:`~ttio.sample.Sample` rows persisted under
        ``/study/samples/`` on this dataset, in on-disk iteration
        order. Empty list when no Samples were written. Lazily
        populated on first access.

        Stage 6 (transport-spec v0.11, Deferral 2). Mirrors Java
        :meth:`global.thalion.ttio.SpectralDataset.samples`.

        :since: 1.4.0
        """
        if not self._samples_cache_loaded:
            self._samples_cache_loaded = True
            self._samples_cache = _read_samples(self.provider, None)
        return self._samples_cache

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
        return self.provider.root_group().open_group("study")

    def _study_has_child(self, name: str) -> bool:
        return self.provider.root_group().open_group("study").has_child(name)

    def identifications(self) -> list[Identification]:
        """Return the dataset's identification records.

        Reads from the compound ``/study/identifications`` dataset when
        present, falling back to the legacy ``@identifications_json``
        attribute on ``/study`` for older files.

        Returns
        -------
        list[Identification]
            Identification records in stored order. Empty when no
            identifications group or JSON attribute is present.
        """
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
        """Return the dataset's quantification records.

        Reads from the compound ``/study/quantifications`` dataset when
        present (with optional per-row units from the
        ``@quantification_units`` JSON sidecar attribute), falling back
        to the legacy ``@quantifications_json`` attribute for older
        files.

        Returns
        -------
        list[Quantification]
            Quantification records in stored order. Empty when no
            quantifications group or JSON attribute is present.
        """
        with self.read_lock():
            study = self._study_target()
            if self._study_has_child("quantifications"):
                # Optional sidecar `@quantification_units` JSON-array
                # attribute carries one unit per row. Absent on legacy
                # files; readers default missing rows to empty string.
                units_blob = io.read_string_attr(
                    study, "quantification_units", default="")
                units = json.loads(units_blob) if units_blob else []
                rows = list(io.read_compound_dataset(study, "quantifications"))
                out: list[Quantification] = []
                for i, r in enumerate(rows):
                    unit = units[i] if i < len(units) else ""
                    out.append(Quantification(
                        chemical_entity=r["chemical_entity"],
                        sample_ref=r["sample_ref"],
                        abundance=float(r["abundance"]),
                        normalization_method=r.get("normalization_method", ""),
                        unit=unit if isinstance(unit, str) else "",
                    ))
                return out
            blob = io.read_string_attr(study, "quantifications_json", default="")
            return _decode_quantifications_json(blob) if blob else []

    def provenance(self) -> list[ProvenanceRecord]:
        """Return the dataset-level provenance chain.

        Reads from the compound ``/study/provenance`` dataset when
        present, falling back to the legacy ``@provenance_json``
        attribute on ``/study`` for older files. Per-run provenance is
        exposed separately by :class:`AcquisitionRun.provenance_records`.

        Returns
        -------
        list[ProvenanceRecord]
            Provenance records in stored order. Empty when neither the
            compound dataset nor the JSON attribute is present.
        """
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

        self.provider.root_group().set_attribute("encrypted", DEFAULT_ENCRYPTION_ALGORITHM)
        object.__setattr__(self, "encrypted_algorithm", DEFAULT_ENCRYPTION_ALGORITHM)

    def decrypt_with_key(self, key: bytes) -> dict[str, bytes]:
        """Decrypt every MS run's intensity channel into an in-memory overlay.

        Returns a mapping of ``{run_name: plaintext_bytes}``.

        **Read-only / asymmetric**: the on-disk file is NOT modified,
        the root ``@encrypted`` attribute is left in place, and
        :attr:`is_encrypted` continues to return ``True`` on this
        instance and on any reopen. This is the asymmetric counterpart
        to :meth:`encrypt_with_key` (which IS persistent +
        flag-flipping) by design: in-memory rehydration lets a process
        read encrypted data without rewriting the file.

        To fully reverse encryption on disk and clear the
        ``@encrypted`` attribute, use the classmethod
        :meth:`decrypt_in_place` — close any open instance first.

        Side effect: each run's decrypted channel is cached in memory
        so ``run.object_at_index(i).intensity_array`` works without
        re-decrypting (Option 1 of the MCP-Server M5 handoff; mirrors
        ObjC ``-[TTIOSpectralDataset decryptWithKey:]`` rehydration
        semantics).

        Cross-language equivalents
        --------------------------
        Java: ``SpectralDataset.decryptWithKey(byte[])`` (same
        in-memory-only semantics) · Objective-C:
        ``-[TTIOSpectralDataset decryptWithKey:error:]`` (same).
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
        image: "MSImage | None" = None,
        raman_image: "RamanImage | None" = None,
        ir_image: "IRImage | None" = None,
        subjects: list[Subject] | None = None,
        samples: list[Sample] | None = None,
        progress: "ProgressSinkLike | None" = None,
    ) -> Path:
        """Write a minimal v1.1 ``.tio`` file from in-memory data.

        Parameters
        ----------
        provider
            : which storage backend to write through. The
            string ``"hdf5"`` (default) keeps byte-for-byte parity with
            pre-M64.5 files. Other values dispatch through
            :func:`open_provider` — ``"memory"``, ``"sqlite"``,
            ``"zarr"``, or any registered backend. A pre-opened
            :class:`StorageProvider` may also be passed; the caller
            owns its lifecycle in that case.
        """
        p = Path(path)
        # Stage 6 (transport-spec v0.11, Deferral 2): validate
        # Subject + Sample lists upfront so the writer fails fast on
        # duplicate IDs before any backend mutation. Soft-FK warnings
        # are emitted by the same call.
        subjects_list = list(subjects) if subjects else []
        samples_list = list(samples) if samples else []
        if subjects_list or samples_list:
            _validate_subjects_and_samples(subjects_list, samples_list)
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

        # ------------------------------------------------------------------
        # Progress: emit one tick per non-empty section in §5.4 order:
        #   encryption -> provenance -> subjects -> samples ->
        #   references -> image -> identifications ->
        #   quantifications -> runs (MS + NMR + Genomic combined).
        # We start with a baseline (0, total) so consumers can show
        # an immediate determinate bar.
        # ------------------------------------------------------------------
        _section_flags: list[tuple[str, bool]] = [
            ("encryption", False),  # write_minimal never encrypts; placeholder
            ("provenance", bool(provenance)),
            ("subjects", bool(subjects_list)),
            ("samples", bool(samples_list)),
            # references are embedded as part of genomic runs; gate on those
            ("references", has_genomic),
            ("image", image is not None or raman_image is not None
                or ir_image is not None),
            ("identifications", bool(identifications)),
            ("quantifications", bool(quantifications)),
            ("runs", bool(runs) or bool(genomic_runs)),
        ]
        _progress_total = sum(1 for _, present in _section_flags if present)
        _progress_done = 0
        _fire(progress, _progress_done, _progress_total)

        def _section_done(name: str) -> None:
            nonlocal _progress_done
            _progress_done += 1
            _fire(progress, _progress_done, _progress_total)

        # HDF5 fast path keeps the legacy byte layout (fixed-length
        # string attrs, padded compound types) so existing tests and
        # cross-language readers continue to round-trip bit-for-bit.
        if isinstance(provider, str) and provider in ("hdf5", "h5", "h5py"):
            with h5py.File(p, "w") as f:
                io.write_feature_flags(f, format_version, feature_list)
                study = f.create_group("study")
                io.write_fixed_string_attr(study, "title", title)
                io.write_fixed_string_attr(study, "isa_investigation_id", isa_investigation_id)

                # §5.4 ordering: provenance first, then subjects/samples,
                # then references, then image, then identifications /
                # quantifications, then runs (last because they tend to
                # be the largest payload).
                if provenance:
                    _write_provenance(study, provenance)
                    _section_done("provenance")
                if subjects_list:
                    _write_subjects_h5(study, subjects_list)
                    _section_done("subjects")
                if samples_list:
                    _write_samples_h5(study, samples_list)
                    _section_done("samples")

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
                    _section_done("references")
                    g_group = study.create_group("genomic_runs")
                    io.write_fixed_string_attr(
                        g_group, "_run_names", ",".join(genomic_runs.keys())
                    )
                    for gname, grun in genomic_runs.items():
                        _write_genomic_run(g_group, gname, grun)

                if (image is not None or raman_image is not None
                        or ir_image is not None):
                    # Wrap the raw h5py.Group in the package-private adapter
                    # so write_to (which expects a StorageGroup) works
                    # uniformly across both the fast-path and protocol-path branches.
                    from ttio.providers.hdf5 import _Group as _Hdf5Group
                    if image is not None:
                        image.write_to(_Hdf5Group(study))
                    if raman_image is not None:
                        raman_image.write_to(_Hdf5Group(study))
                    if ir_image is not None:
                        ir_image.write_to(_Hdf5Group(study))
                    _section_done("image")

                if identifications:
                    _write_identifications(study, identifications)
                    _section_done("identifications")
                if quantifications:
                    _write_quantifications(study, quantifications)
                    _section_done("quantifications")
                if runs or genomic_runs:
                    _section_done("runs")
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

            # §5.4 ordering: provenance first, then subjects/samples,
            # then references, then image, then identifications /
            # quantifications, then runs.
            if provenance:
                _write_provenance(study, provenance)
                _section_done("provenance")
            if subjects_list:
                _write_subjects_provider(study, subjects_list)
                _section_done("subjects")
            if samples_list:
                _write_samples_provider(study, samples_list)
                _section_done("samples")

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
                _section_done("references")
                g_group = study.create_group("genomic_runs")
                io.write_fixed_string_attr(
                    g_group, "_run_names", ",".join(genomic_runs.keys())
                )
                for gname, grun in genomic_runs.items():
                    _write_genomic_run(g_group, gname, grun)

            if image is not None:
                image.write_to(study)   # study is already a StorageGroup here
            if raman_image is not None:
                raman_image.write_to(study)   # study is already a StorageGroup here
            if ir_image is not None:
                ir_image.write_to(study)   # study is already a StorageGroup here
            if (image is not None or raman_image is not None
                    or ir_image is not None):
                _section_done("image")

            if identifications:
                _write_identifications(study, identifications)
                _section_done("identifications")
            if quantifications:
                _write_quantifications(study, quantifications)
                _section_done("quantifications")
            if runs or genomic_runs:
                _section_done("runs")
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
    # optional parallel per-spectrum arrays. Writer emits the
    # four datasets only when all four are non-None (schema-gating per
    # the opt_ms2_activation_detail feature flag).
    activation_methods: np.ndarray | None = None
    isolation_target_mzs: np.ndarray | None = None
    isolation_lower_offsets: np.ndarray | None = None
    isolation_upper_offsets: np.ndarray | None = None
    # Optional per-spectrum centroided flag (0 = profile, 1 = centroided).
    # Independent of M74 gating; written to ``spectrum_index/centroideds``.
    centroideds: np.ndarray | None = None
    nucleus_type: str = ""
    # Optional NMR solvent label (e.g. "CDCl3", "DMSO-d6"). Empty when
    # not specified or when the run is not NMR. Written as the
    # ``@solvent`` string attribute on the run group. Also reused as the
    # UV-Vis solvent label.
    solvent: str = ""
    # Optional vibrational-spectrum run metadata (IR / Raman / UV-Vis).
    # Written as scalar run-group attributes only when set, so MS/NMR
    # files stay byte-identical. Read back in AcquisitionRun.open and
    # used by _materialize_spectrum to reconstruct the subclass.
    ir_mode: int | None = None              # IRMode value (0/1)
    ir_resolution_cm_inv: float = 0.0
    ir_number_of_scans: int = 0
    raman_excitation_wavelength_nm: float = 0.0
    raman_laser_power_mw: float = 0.0
    raman_integration_time_sec: float = 0.0
    uvvis_path_length_cm: float = 0.0
    provenance_records: list[ProvenanceRecord] = field(default_factory=list)
    # signal compression codec. Valid values are the strings
    # recognised by :func:`ttio._hdf5_io.write_signal_channel` plus
    # the TTIO-level ``"numpress_delta"`` codec, which transforms the
    # float64 buffer into an int64 first-difference array and stores
    # the fixed-point scaling factor on the signal_channels group.
    signal_compression: str = "gzip"
    # optional chromatogram traces for this run. Empty list
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

    if getattr(run, "solvent", ""):
        io.write_fixed_string_attr(g, "solvent", run.solvent)

    # Vibrational-spectrum run metadata (only emitted when set, so MS/NMR
    # files keep byte parity). Mirrored in Java/ObjC readers.
    if run.ir_mode is not None:
        io.write_int_attr(g, "ir_mode", int(run.ir_mode))
    if run.ir_resolution_cm_inv:
        io.write_float_attr(g, "ir_resolution_cm_inv", run.ir_resolution_cm_inv)
    if run.ir_number_of_scans:
        io.write_int_attr(g, "ir_number_of_scans", int(run.ir_number_of_scans))
    if run.raman_excitation_wavelength_nm:
        io.write_float_attr(g, "raman_excitation_wavelength_nm",
                            run.raman_excitation_wavelength_nm)
    if run.raman_laser_power_mw:
        io.write_float_attr(g, "raman_laser_power_mw", run.raman_laser_power_mw)
    if run.raman_integration_time_sec:
        io.write_float_attr(g, "raman_integration_time_sec",
                            run.raman_integration_time_sec)
    if run.uvvis_path_length_cm:
        io.write_float_attr(g, "uvvis_path_length_cm", run.uvvis_path_length_cm)

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
    # offsets is never written — readers derive from cumsum(lengths).
    columns: list[tuple[str, np.ndarray, str]] = [
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
    # Optional centroided column — independent of M74 gating.
    if run.centroideds is not None:
        columns.append(("centroideds", run.centroideds, "<i4"))
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

    # chromatograms
    if run.chromatograms:
        from .acquisition_run import write_chromatograms_to_run_group
        write_chromatograms_to_run_group(g, run.chromatograms)


# M93 v1.2 — context-aware codec / reference-embed helpers.

def _any_v1_5_codec(
    genomic_runs: "Mapping[str, WrittenGenomicRun] | None",
) -> bool:
    """Return True if any run carries a v1.5 codec (REF_DIFF_V2 or FQZCOMP_NX16_Z).

    Used to gate the format-version bump from 1.4 → 1.5: only files that
    actually exercise an M93+ codec get the new version string, so
    M82-only writes preserve byte-parity with existing fixtures.

    v1.0 reset (Phase 2c): the v1 REF_DIFF (codec id 9) implementation was
    removed; only REF_DIFF_V2 (codec id 14) and FQZCOMP_NX16_Z (codec id 12)
    register as v1.5 codecs for the format-version gate. FQZCOMP_NX16_Z
    carries its sibling-channel metadata (``read_lengths`` / ``revcomp_flags``)
    inside the codec wire format, so it does not need an embedded
    reference (``needs_embedded_reference`` is False) — but it IS a v1.5
    codec for the gate.
    """
    if not genomic_runs:
        return False
    from .enums import Compression as _Compression
    _V1_5_CODECS = frozenset({
        _Compression.REF_DIFF_V2,      # v1.8 #11
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


def _load_references_provider(study) -> dict[str, ReferenceImport]:
    """Read ``/study/references/<uri>/`` via the StorageGroup protocol.

    Inverse-side helper for :func:`_embed_references_for_runs`. Returns
    an empty dict when the ``references`` sub-group is absent, mirroring
    Java's ``Map.of()`` empty-map contract.
    """
    if not study.has_child("references"):
        return {}
    refs_grp = study.open_group("references")
    out: dict[str, ReferenceImport] = {}
    try:
        for uri in refs_grp.child_names():
            sub = refs_grp.open_group(uri)
            try:
                out[uri] = ReferenceImport.read_from_group(sub)
            finally:
                sub.close()
    finally:
        refs_grp.close()
    return out


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
    from .codecs._registry import CODEC_REGISTRY
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
        # native lib is available).
        _has_context_aware_override = any(
            getattr(CODEC_REGISTRY.get(_Compression(c)), "needs_embedded_reference", False)
            for c in run.signal_codec_overrides.values()
            if _is_valid_compression(c)
        )
        _uses_ref_diff_v2_default = (
            _rdv2_meta.HAVE_NATIVE_LIB
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


def _write_sequences_ref_diff_v2(sc, run: WrittenGenomicRun) -> None:
    """Write the ``sequences`` channel through the REF_DIFF_V2 codec.

    v1.0 reset (Phase 2c): the v1 REF_DIFF (codec id 9) writer was
    removed. The v2 path (codec id 14) is now the only reference-diff
    sequences writer.

    Eligibility: requires libttio_rans loadable, a single-chromosome
    run, all reads mapped (no ``cigar=="*"``), and a reference present.
    When any precondition fails, falls back to BASE_PACK on a flat
    dataset (Q5b = C) — same fallback semantics as the original v1.5
    REF_DIFF path. The fallback uses the canonical, codec-free
    sequences dataset layout.

    **Single-chromosome limitation (v1.8 first pass):** REF_DIFF_V2
    requires all reads aligned to a single chromosome. Multi-chromosome
    runs raise :class:`ValueError`.
    """
    from .codecs import ref_diff_v2 as _rdv2
    from .codecs._registry import CODEC_REGISTRY
    from .codecs._context import CodecContext, DecodedChannel
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
                "REF_DIFF_V2 v1.8 supports single-chromosome runs only; "
                f"this run carries reads on chromosomes {sorted(unique_chroms)}. "
                "Multi-chromosome support is a follow-up — split into "
                "per-chromosome runs as a workaround."
            )
        else:
            chrom = next(iter(unique_chroms))
            chrom_seq = run.reference_chrom_seqs.get(chrom)

    raw_bytes = bytes(run.sequences.tobytes())

    # REF_DIFF_V2 cannot encode unmapped reads (cigar="*"). When any
    # read in the run is unmapped, fall back to BASE_PACK on the whole
    # channel — same Q5b=C semantics as missing-reference.
    has_unmapped = any(c == "*" or c == "" for c in run.cigars)

    use_v2 = (
        _rdv2.HAVE_NATIVE_LIB
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
        # Codec-registry refactor (Task 5c): route REF_DIFF_V2 encode
        # through the registry. Inputs that get written into the blob
        # header (offsets/reference/md5/uri/cigars/positions) ride on the
        # encode-only CodecContext fields. The codec returns a GROUP
        # layout ({"refdiff_v2": blob}); we materialise the `sequences`
        # group + child + @compression below — byte-identical to the
        # prior direct ref_diff_v2.encode call.
        encoded_channel = CODEC_REGISTRY[_Compression.REF_DIFF_V2].encode(
            DecodedChannel.of_bytes(bytes(sequences_arr.tobytes())),
            CodecContext(
                offsets=offsets_arr,
                positions=positions,
                cigar_strings=list(run.cigars),
                reference=chrom_seq,
                reference_md5=md5,
                reference_uri=run.reference_uri,
                reads_per_slice=10_000,
            ),
        )
        seq_group = sc.create_group("sequences")
        for child_name, blob in encoded_channel.group_children.items():
            arr = np.frombuffer(blob, dtype=np.uint8)
            ds = seq_group.create_dataset(
                child_name,
                _Precision.UINT8,
                length=int(arr.shape[0]),
                chunk_size=io.DEFAULT_SIGNAL_CHUNK,
                compression=_Compression.NONE,
            )
            ds.write(arr)
            io.write_int_attr(
                ds, "compression", int(_Compression.REF_DIFF_V2), dtype="<u1")
        return

    # Fallback: flat dataset with BASE_PACK (Q5b = C).
    encoded = _base_pack_encode(raw_bytes)
    codec_id = int(_Compression.BASE_PACK)

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
    from .codecs._registry import CODEC_REGISTRY
    from .codecs._context import CodecContext, DecodedChannel
    from .enums import Compression as _Compression, Precision as _Precision

    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp_flags = [
        1 if (int(f) & SAM_REVERSE_FLAG) else 0 for f in run.flags
    ]

    # Codec-registry refactor (Task 5b): route FQZCOMP_NX16_Z through the
    # registry. Its encode adapter requires read_lengths + revcomp_flags
    # in the CodecContext — sourced exactly as the prior direct call did
    # (index lengths + the SAM reverse flag bit). Bytes are identical.
    encoded = CODEC_REGISTRY[_Compression.FQZCOMP_NX16_Z].encode(
        DecodedChannel.of_bytes(qualities),
        CodecContext(
            read_lengths=np.asarray(read_lengths),
            revcomp_flags=np.asarray(revcomp_flags),
        ),
    ).dataset_bytes

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

    # validate any per-channel codec overrides before we touch
    # the file. The override surface covers the four byte/string
    # channels (sequences, qualities, read_names, cigars). Anything
    # outside the per-channel whitelist is a caller error and must
    # surface immediately ().
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
            # M94.Z v1.2: CRAM-mimic rANS-Nx16 quality codec. Carries its
            # own read_lengths + needs revcomp_flags from run.flags & 16.
            _Compression.FQZCOMP_NX16_Z,
        }),
        # v1.0 reset: read_names is auto-encoded with NAME_TOKENIZED_V2
        # (codec id 15); no explicit override is supported.
        "read_names": frozenset(),
        # cigars accepts the rANS pair on a length-prefix-
        # concat byte stream of the CIGAR strings (varint(len) + bytes
        # per CIGAR). BASE_PACK and QUALITY_BINNED are wrong-content
        # (CIGARs are not ACGT bytes nor Phred values) and are
        # explicitly rejected with named error messages below.
        "cigars": frozenset({
            _Compression.RANS_ORDER0,
            _Compression.RANS_ORDER1,
        }),
    }
    # per-record integer metadata channels removed from the
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
        # per-field mate_info_* overrides are disallowed —
        # the inline_v2 codec encodes all three fields together.
        if ch_name in ("mate_info_chrom", "mate_info_pos", "mate_info_tlen"):
            raise ValueError(
                f"signal_codec_overrides[{ch_name!r}]: per-field "
                "mate_info_* overrides are disallowed — the v1.7+ "
                "inline_v2 codec encodes all three mate fields into "
                "a single blob with no per-field codec choice."
            )
        # M86 Phase F / Gotcha §143: the bare
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
                f"(only sequences, qualities, read_names, and cigars "
                f"can use TTIO codecs)"
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
            # Phase D : explicit message for the
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
            # Phase C Binding Decisions §120, §121: explicit messages
            # for the wrong-content codecs on the cigars channel. The
            # cigars channel holds variable-length ASCII CIGAR strings
            # — neither ACGT bytes (BASE_PACK) nor Phred quality
            # values (QUALITY_BINNED) match. The error names the
            # codec, the channel, and the wrong-content rationale.
            if ch_name == "cigars":
                if codec_enum == _Compression.BASE_PACK:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"BASE_PACK is not valid on the '{ch_name}' "
                        "channel — BASE_PACK 2-bit-packs ACGT sequence "
                        "bytes and would silently corrupt the structured "
                        "ASCII strings stored on this channel. Use "
                        f"RANS_ORDER0 or RANS_ORDER1 on '{ch_name}'."
                    )
                if codec_enum == _Compression.QUALITY_BINNED:
                    raise ValueError(
                        f"signal_codec_overrides['{ch_name}']: codec "
                        f"QUALITY_BINNED is not valid on the '{ch_name}' "
                        "channel — QUALITY_BINNED quantises Phred "
                        "quality scores onto an 8-bin centre table and "
                        "would silently destroy the structured ASCII "
                        "strings stored on this channel. Use "
                        f"RANS_ORDER0 or RANS_ORDER1 on '{ch_name}'."
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

    # M93 v1.2: REF_DIFF is a context-aware codec — encoding requires
    # positions, cigars, and the reference sequence in addition to the
    # raw byte stream. Dispatch on a special branch when the override
    # selects it; everything else falls through to the existing helper.
    _seq_codec = run.signal_codec_overrides.get("sequences")
    # v1.0 reset (Phase 2c): the v1 REF_DIFF (codec id 9) writer was
    # removed. The default codec lookup now resolves to REF_DIFF_V2
    # (codec id 14) when caller has not selected a per-channel codec
    # AND signal_compression is the "auto-pick best lossless" gzip
    # default AND a reference is available. The
    # _write_sequences_ref_diff_v2 helper handles BASE_PACK fallback
    # (Q5b=C) when the v2 native lib is unavailable / single-chrom
    # check fails / unmapped reads are present.
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
    # explicit override or the REF_DIFF_V2 auto-default we just resolved
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
        # or the sequences channel is going through REF_DIFF_V2 (resolved
        # above into _seq_codec).
        if (_seq_codec is not None
                and _is_valid_compression(_seq_codec)
                and _Compression(_seq_codec) == _Compression.REF_DIFF_V2):
            _is_v1_5_candidate = True
        else:
            for _ovr in run.signal_codec_overrides.values():
                if _is_valid_compression(_ovr):
                    _ce = _Compression(_ovr)
                    if _ce in (
                        _Compression.REF_DIFF_V2,
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

    # positions / flags / mapping_qualities are NOT written
    # under signal_channels/. They live exclusively in genomic_index/,
    # mirroring MS's spectrum_index/ pattern (per-record metadata =
    # index; signal_channels = bulk data). See docs/format-spec.md
    # §4 and §10.7. Override-validation rejects these channel names.
    # Old files (v1.5 and earlier) may carry these under
    # signal_channels/ — readers ignore them; the genomic_index/ copy
    # is canonical.
    if (
        run.bulk_v2_blobs is not None
        and run.bulk_v2_blobs.ref_diff_blob is not None
    ):
        # Phase 2c-T verbatim path: skip codec encode and write the
        # wire blob bytes directly.
        if run.bulk_v2_blobs.ref_diff_reference_uri != run.reference_uri:
            raise ValueError(
                f"BulkV2Blobs.ref_diff_reference_uri "
                f"{run.bulk_v2_blobs.ref_diff_reference_uri!r} != "
                f"run.reference_uri {run.reference_uri!r}"
            )
        _write_sequences_ref_diff_bulk_verbatim(
            sc, run.bulk_v2_blobs.ref_diff_blob,
        )
    elif (
        _seq_codec is not None
        and _is_valid_compression(_seq_codec)
        and _Compression(_seq_codec) == _Compression.REF_DIFF_V2
    ):
        _write_sequences_ref_diff_v2(sc, run)
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
    # schema lift for cigars. When an override is
    # present the writer replaces the M82 compound dataset with a
    # flat 1-D uint8 dataset of the same name carrying the codec
    # output, plus an @compression attribute (Binding Decisions
    # §120-§122). The rANS pair operate on a length-prefix-concat
    # byte stream over the CIGAR list (varint(len) + bytes per
    # CIGAR).
    #
    # v1.0 reset (Phase 2c): the v1 NAME_TOKENIZED (codec id 8) writer
    # branch was removed.
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
            from .codecs._varint import varint_encode as _ve
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
    # v1.0 reset (Phase 2c) — read_names is always written via the
    # NAME_TOKENIZED_V2 codec (codec id 15) when there is at least one
    # read. The v1 NAME_TOKENIZED writer (codec id 8) and the M82
    # compound fallback were both removed; per-channel overrides for
    # read_names are no longer accepted (validation rejects them
    # earlier in this function).
    #
    # Empty-run case: the writer short-circuits and writes a placeholder
    # NAME_TOKENIZED_V2-tagged empty dataset so readers can detect the
    # layout uniformly. When there are reads but the native library is
    # unavailable, raise a clear RuntimeError pointing at the install
    # path.
    from .codecs import name_tokenizer_v2 as _nt2
    from .enums import Precision as _Precision
    if (
        run.bulk_v2_blobs is not None
        and run.bulk_v2_blobs.name_tok_blob is not None
    ):
        # Phase 2c-T verbatim path.
        _write_read_names_bulk_verbatim(sc, run.bulk_v2_blobs.name_tok_blob)
    elif len(run.read_names) == 0:
        # Short-circuit: write a zero-length uint8 dataset tagged with
        # the v2 codec id so readers dispatch to the v2 path uniformly.
        ds = sc.create_dataset(
            "read_names",
            _Precision.UINT8,
            length=0,
            chunk_size=io.DEFAULT_SIGNAL_CHUNK,
            compression=_Compression.NONE,
        )
        io.write_int_attr(
            ds, "compression",
            int(_Compression.NAME_TOKENIZED_V2), dtype="<u1",
        )
    else:
        if not _nt2.HAVE_NATIVE_LIB:
            raise RuntimeError(
                "NAME_TOKENIZED_V2 codec requires the native libttio_rans "
                "library. Install via 'pip install ttio[native]' or build "
                "from source with --with-native (set TTIO_RANS_LIB_PATH if "
                "the library is at a non-default location)."
            )
        # Codec-registry refactor (Task 5b): NAME_TOKENIZED_V2 needs no
        # run context — encode through the registry with an empty
        # CodecContext. Bytes are identical to the prior direct call.
        from .codecs._registry import CODEC_REGISTRY
        from .codecs._context import CodecContext, DecodedChannel
        encoded = CODEC_REGISTRY[_Compression.NAME_TOKENIZED_V2].encode(
            DecodedChannel.of_str_list(list(run.read_names)),
            CodecContext.empty(),
        ).dataset_bytes
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
    # v1.0 reset (Phase 2c) — mate_info is always written via the
    # inline_v2 codec (codec id 13) under
    # signal_channels/mate_info/inline_v2. The v1 per-field subgroup
    # writer (Phase F) and the M82 compound fallback were both
    # removed; per-field mate_info_* overrides are rejected earlier
    # in this function.
    #
    # Empty-run case: if there are no reads, no mate_info group is
    # emitted (the reader treats absence as "no mates"). When there
    # are reads but the native library is unavailable, raise a clear
    # RuntimeError pointing at the install path.
    from .codecs import mate_info_v2 as _miv2
    if (
        run.bulk_v2_blobs is not None
        and run.bulk_v2_blobs.mate_info_blob is not None
    ):
        # Phase 2c-T verbatim path: skip codec encode entirely and write
        # the wire blob bytes + chrom_names table.
        _write_mate_info_bulk_verbatim(
            sc,
            run.bulk_v2_blobs.mate_info_blob,
            run.bulk_v2_blobs.mate_info_chrom_names or [],
        )
    elif len(run.mate_chromosomes) > 0:
        if not _miv2.HAVE_NATIVE_LIB:
            raise RuntimeError(
                "MATE_INLINE_V2 codec requires the native libttio_rans "
                "library. Install via 'pip install ttio[native]' or build "
                "from source with --with-native (set TTIO_RANS_LIB_PATH if "
                "the library is at a non-default location)."
            )
        _write_mate_info_inline_v2(sc, run)

    # Per-run provenance — same pattern as _write_run.
    if run.provenance_records:
        prov = rg.create_group("provenance")
        _write_provenance(prov, run.provenance_records, dataset_name="steps")


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


def _write_bulk_v2_blob(
    parent, *, dataset_name: str, blob: bytes, codec_id: int
) -> None:
    """Write a verbatim v2 codec blob as a 1-D uint8 dataset.

    Used by the transport bulk-mode receiver (Phase 2c-T) to bypass
    the v2 codec encode step and write the wire bytes directly. The
    ``@compression`` attribute is stamped with ``codec_id`` so the
    file remains self-describing — readers dispatch on the same
    compression byte they would for a freshly-encoded blob.
    """
    from .enums import Compression as _Compression, Precision as _Precision

    arr = np.frombuffer(bytes(blob), dtype=np.uint8)
    ds = parent.create_dataset(
        dataset_name,
        _Precision.UINT8,
        length=int(arr.shape[0]),
        chunk_size=io.DEFAULT_SIGNAL_CHUNK,
        compression=_Compression.NONE,
    )
    if arr.shape[0] > 0:
        ds.write(arr)
    io.write_int_attr(ds, "compression", int(codec_id), dtype="<u1")


def _write_mate_info_bulk_verbatim(
    sc, blob: bytes, chrom_names: list[str]
) -> None:
    """Phase 2c-T: write a verbatim ``inline_v2`` blob + chrom_names
    table. Mirrors the layout produced by
    :func:`_write_mate_info_inline_v2` but skips the codec encode."""
    from .enums import Compression as _Compression
    mate_group = sc.create_group("mate_info")
    _write_bulk_v2_blob(
        mate_group,
        dataset_name="inline_v2",
        blob=blob,
        codec_id=int(_Compression.MATE_INLINE_V2),
    )
    io.write_compound_dataset(
        mate_group,
        "chrom_names",
        [{"name": n} for n in chrom_names],
        [("name", io.vl_str())],
    )


def _write_sequences_ref_diff_bulk_verbatim(sc, blob: bytes) -> None:
    """Phase 2c-T: write a verbatim ``refdiff_v2`` blob under
    ``signal_channels/sequences/refdiff_v2``. Mirrors the v1.8 v2
    layout produced by :func:`_write_sequences_ref_diff_v2`."""
    from .enums import Compression as _Compression
    seq_group = sc.create_group("sequences")
    _write_bulk_v2_blob(
        seq_group,
        dataset_name="refdiff_v2",
        blob=blob,
        codec_id=int(_Compression.REF_DIFF_V2),
    )


def _write_read_names_bulk_verbatim(sc, blob: bytes) -> None:
    """Phase 2c-T: write a verbatim ``name_tok_v2`` blob to
    ``signal_channels/read_names``. Mirrors the v1.8 v2 layout
    produced by the inline NAME_TOKENIZED_V2 path."""
    from .enums import Compression as _Compression
    _write_bulk_v2_blob(
        sc,
        dataset_name="read_names",
        blob=blob,
        codec_id=int(_Compression.NAME_TOKENIZED_V2),
    )


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
    from .codecs._registry import CODEC_REGISTRY
    from .codecs._context import CodecContext, DecodedChannel
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

    # Codec-registry refactor (Task 5b): route MATE_INLINE_V2 through the
    # registry. Its encode adapter consumes the mate triple via the
    # DecodedChannel.of_mate_info value and own_chrom_ids/own_positions
    # from the CodecContext — sourced exactly as the prior direct call.
    # Bytes are identical.
    own_positions = np.asarray(run.positions, dtype=np.int64)
    encoded = CODEC_REGISTRY[_Compression.MATE_INLINE_V2].encode(
        DecodedChannel.of_mate_info({
            "mate_chrom_ids": mate_chrom_ids,
            "mate_positions": np.asarray(run.mate_positions, dtype=np.int64),
            "template_lengths": np.asarray(run.template_lengths, dtype=np.int32),
        }),
        CodecContext(own_chrom_ids=own_chrom_ids, own_positions=own_positions),
    ).dataset_bytes
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
    # emit @identifications_json mirror so Java (JHI5 1.10 cannot
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
    # Optional sidecar `@quantification_units` JSON-array attribute:
    # one string per row, parallel to the compound dataset above.
    # Emitted only when at least one record carries a non-empty unit;
    # absent on legacy files (units default to "").
    if any(getattr(r, "unit", "") for r in records):
        io.write_fixed_string_attr(study, "quantification_units",
            json.dumps([getattr(r, "unit", "") or "" for r in records]))
    # JSON mirror (see _write_identifications)
    io.write_fixed_string_attr(study, "quantifications_json", json.dumps([
        {
            "chemical_entity": r.chemical_entity,
            "sample_ref": r.sample_ref,
            "abundance": float(r.abundance),
            **({"normalization_method": r.normalization_method}
               if r.normalization_method else {}),
            **({"unit": r.unit} if getattr(r, "unit", "") else {}),
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
    # JSON mirror. Only emitted for the top-level /study/provenance
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
            unit=str(r.get("unit", "")),
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


# ── Stage 6 (transport-spec v0.11, Deferral 2): Subjects + Samples ──
# Per design spec docs/superpowers/specs/2026-05-26-subjects-samples-design.md
# §4.4 (validation), §5 (HDF5 layout). Mirrors Java's
# SpectralDataset.{validateSubjectsAndSamples, writeSubjects, writeSamples,
# readSubjects, readSamples} from commit dd39f4e6.

import logging  # noqa: E402

_STAGE6_LOG = logging.getLogger(__name__)


def _validate_subjects_and_samples(
    subjects: list[Subject], samples: list[Sample]
) -> None:
    """Pre-write validation per spec §4.4:
    duplicate ``Subject.external_id`` or ``Sample.sample_id`` raises
    :class:`ValueError`; soft-FK mismatch (``Sample.subject_external_id``
    not found in Subject list) logs WARNING but does not fail."""
    seen_subjects: set[str] = set()
    for s in subjects:
        if s.external_id in seen_subjects:
            raise ValueError(
                f"duplicate Subject.external_id: {s.external_id}"
            )
        seen_subjects.add(s.external_id)
    seen_samples: set[str] = set()
    for s in samples:
        if s.sample_id in seen_samples:
            raise ValueError(
                f"duplicate Sample.sample_id: {s.sample_id}"
            )
        seen_samples.add(s.sample_id)
    for s in samples:
        fk = s.subject_external_id
        if not fk:
            continue
        if fk not in seen_subjects:
            _STAGE6_LOG.warning(
                "Sample %r references unknown Subject.external_id %r "
                "— soft-FK mismatch, writing anyway (spec §4.4).",
                s.sample_id, fk,
            )


def _write_subjects_h5(study: h5py.Group, subjects: list[Subject]) -> None:
    """HDF5 fast path: write ``/study/subjects/<external_id>/`` per-row
    groups with typed attributes. Mirrors Java's
    :meth:`SpectralDataset.writeSubjects`."""
    if not subjects:
        return
    from ttio.providers.hdf5 import _Group as _Hdf5Group
    subjects_group = study.create_group("subjects")
    for s in subjects:
        row_native = subjects_group.create_group(s.external_id)
        row = _Hdf5Group(row_native)
        # external_id (str) — always written.
        io.write_fixed_string_attr(row, "external_id", s.external_id)
        # optional strings — only emit when non-empty (Java parity).
        if s.project:
            io.write_fixed_string_attr(row, "project", s.project)
        if s.sex:
            io.write_fixed_string_attr(row, "sex", s.sex)
        # birth_year (int64) — always written; sentinel 0 means unknown.
        io.write_int_attr(row, "birth_year", int(s.birth_year))
        # attributes_json — always written; "{}" when empty.
        io.write_fixed_string_attr(row, "attributes_json", s.attributes_json())


def _write_samples_h5(study: h5py.Group, samples: list[Sample]) -> None:
    """HDF5 fast path: write ``/study/samples/<sample_id>/`` per-row
    groups with typed attributes. Mirrors Java's
    :meth:`SpectralDataset.writeSamples`."""
    if not samples:
        return
    from ttio.providers.hdf5 import _Group as _Hdf5Group
    samples_group = study.create_group("samples")
    for s in samples:
        row_native = samples_group.create_group(s.sample_id)
        row = _Hdf5Group(row_native)
        io.write_fixed_string_attr(row, "sample_id", s.sample_id)
        if s.subject_external_id:
            io.write_fixed_string_attr(
                row, "subject_external_id", s.subject_external_id
            )
        if s.sample_kind:
            io.write_fixed_string_attr(row, "sample_kind", s.sample_kind)
        io.write_int_attr(row, "collected_at", int(s.collected_at))
        io.write_fixed_string_attr(row, "attributes_json", s.attributes_json())


def _write_subjects_provider(
    study: StorageGroup, subjects: list[Subject]
) -> None:
    """Provider-agnostic mirror of :func:`_write_subjects_h5`."""
    if not subjects:
        return
    subjects_group = study.create_group("subjects")
    for s in subjects:
        row = subjects_group.create_group(s.external_id)
        row.set_attribute("external_id", s.external_id)
        if s.project:
            row.set_attribute("project", s.project)
        if s.sex:
            row.set_attribute("sex", s.sex)
        row.set_attribute("birth_year", int(s.birth_year))
        row.set_attribute("attributes_json", s.attributes_json())


def _write_samples_provider(
    study: StorageGroup, samples: list[Sample]
) -> None:
    """Provider-agnostic mirror of :func:`_write_samples_h5`."""
    if not samples:
        return
    samples_group = study.create_group("samples")
    for s in samples:
        row = samples_group.create_group(s.sample_id)
        row.set_attribute("sample_id", s.sample_id)
        if s.subject_external_id:
            row.set_attribute("subject_external_id", s.subject_external_id)
        if s.sample_kind:
            row.set_attribute("sample_kind", s.sample_kind)
        row.set_attribute("collected_at", int(s.collected_at))
        row.set_attribute("attributes_json", s.attributes_json())


def _parse_attributes_json(blob: str | None) -> dict[str, str]:
    """Parse ``attributes_json`` back into a ``dict[str, str]``.
    Mirrors Java's ``MiniJson.parseStringMap`` semantics for the
    Subject + Sample case (``{}`` and the empty string both decode to
    an empty dict)."""
    if not blob or blob == "{}":
        return {}
    try:
        parsed = json.loads(blob)
    except json.JSONDecodeError:
        return {}
    if not isinstance(parsed, dict):
        return {}
    return {str(k): str(v) for k, v in parsed.items()}


def _read_subjects(
    provider: StorageProvider | None, file: h5py.File | None
) -> list[Subject]:
    """Stage 6: enumerate ``/study/subjects/`` children and decode each
    per-row group into a :class:`Subject`. Empty list when the group
    is absent (pre-Stage-6 files)."""
    out: list[Subject] = []
    # Fast path: native h5py.
    if file is not None:
        if "study" not in file:
            return out
        study = file["study"]
        if "subjects" not in study:
            return out
        from ttio.providers.hdf5 import _Group as _Hdf5Group
        subjects_group = study["subjects"]
        for name in subjects_group.keys():
            row_native = subjects_group[name]
            row = _Hdf5Group(row_native)
            external_id = io.read_string_attr(row, "external_id", default=name) or name
            project = io.read_string_attr(row, "project", default="") or ""
            sex = io.read_string_attr(row, "sex", default="") or ""
            birth_year = io.read_int_attr(row, "birth_year", default=0) or 0
            attrs_json = io.read_string_attr(row, "attributes_json", default="{}") or "{}"
            out.append(Subject(
                external_id=external_id,
                project=project,
                sex=sex,
                birth_year=int(birth_year),
                attributes=_parse_attributes_json(attrs_json),
            ))
        return out
    # Provider path.
    if provider is None:
        return out
    root = provider.root_group()
    if not root.has_child("study"):
        return out
    study = root.open_group("study")
    if not study.has_child("subjects"):
        return out
    subjects_group = study.open_group("subjects")
    for name in subjects_group.child_names():
        row = subjects_group.open_group(name)
        external_id = _read_string_attr_or_default(row, "external_id", name)
        project = _read_string_attr_or_default(row, "project", "")
        sex = _read_string_attr_or_default(row, "sex", "")
        birth_year = _read_long_attr_or_default(row, "birth_year", 0)
        attrs_json = _read_string_attr_or_default(row, "attributes_json", "{}")
        out.append(Subject(
            external_id=external_id,
            project=project,
            sex=sex,
            birth_year=int(birth_year),
            attributes=_parse_attributes_json(attrs_json),
        ))
    return out


def _read_samples(
    provider: StorageProvider | None, file: h5py.File | None
) -> list[Sample]:
    """Stage 6: enumerate ``/study/samples/`` children and decode each
    per-row group into a :class:`Sample`. Empty list when the group
    is absent (pre-Stage-6 files)."""
    out: list[Sample] = []
    if file is not None:
        if "study" not in file:
            return out
        study = file["study"]
        if "samples" not in study:
            return out
        from ttio.providers.hdf5 import _Group as _Hdf5Group
        samples_group = study["samples"]
        for name in samples_group.keys():
            row_native = samples_group[name]
            row = _Hdf5Group(row_native)
            sample_id = io.read_string_attr(row, "sample_id", default=name) or name
            subject_external_id = io.read_string_attr(
                row, "subject_external_id", default=""
            ) or ""
            sample_kind = io.read_string_attr(row, "sample_kind", default="") or ""
            collected_at = io.read_int_attr(row, "collected_at", default=0) or 0
            attrs_json = io.read_string_attr(row, "attributes_json", default="{}") or "{}"
            out.append(Sample(
                sample_id=sample_id,
                subject_external_id=subject_external_id,
                sample_kind=sample_kind,
                collected_at=int(collected_at),
                attributes=_parse_attributes_json(attrs_json),
            ))
        return out
    if provider is None:
        return out
    root = provider.root_group()
    if not root.has_child("study"):
        return out
    study = root.open_group("study")
    if not study.has_child("samples"):
        return out
    samples_group = study.open_group("samples")
    for name in samples_group.child_names():
        row = samples_group.open_group(name)
        sample_id = _read_string_attr_or_default(row, "sample_id", name)
        subject_external_id = _read_string_attr_or_default(
            row, "subject_external_id", ""
        )
        sample_kind = _read_string_attr_or_default(row, "sample_kind", "")
        collected_at = _read_long_attr_or_default(row, "collected_at", 0)
        attrs_json = _read_string_attr_or_default(row, "attributes_json", "{}")
        out.append(Sample(
            sample_id=sample_id,
            subject_external_id=subject_external_id,
            sample_kind=sample_kind,
            collected_at=int(collected_at),
            attributes=_parse_attributes_json(attrs_json),
        ))
    return out


def _read_string_attr_or_default(
    group: StorageGroup, name: str, fallback: str
) -> str:
    if not group.has_attribute(name):
        return fallback
    v = group.get_attribute(name)
    if v is None:
        return fallback
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return str(v)


def _read_long_attr_or_default(
    group: StorageGroup, name: str, fallback: int
) -> int:
    if not group.has_attribute(name):
        return fallback
    v = group.get_attribute(name)
    if v is None:
        return fallback
    try:
        return int(v)
    except (TypeError, ValueError):
        return fallback
