"""Python equivalent of Java's
``global.thalion.ttio.transport.AccessorSpec`` enum (commit
``46c26587``).

Each :class:`AccessorSpec` entry pairs a fixture builder with a
content-equality assertion scoped to one first-class accessor on
:class:`ttio.spectral_dataset.SpectralDataset`. The conformance
test (:mod:`tests.test_accessor_matrix_conformance`) parametrises
over :data:`ACCESSOR_SPECS` and exercises each accessor's transport
round-trip in isolation; the coverage-gap watchdog
(:mod:`tests.test_coverage_gap_watchdog`) runs every comparator
against the all-in-one ``everything.tio`` fixture so a silent drop
of any single accessor fires a clear assertion.

Stage 1 (Task 2.10): 8 first-class accessors covered. SUBJECTS +
SAMPLES are deferred until they exist as first-class entities on
``SpectralDataset``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np

from ttio.spectral_dataset import SpectralDataset

from _v0_11_fixtures import (
    build_dataset_provenance_only,
    build_encryption_algorithm_only,
    build_genomic_runs_only,
    build_identifications_only,
    build_image_ms_continuous,
    build_ms_runs_only,
    build_quantifications_only,
    build_reference_only,
)


@dataclass(frozen=True)
class AccessorSpec:
    """One row of the conformance matrix.

    Attributes
    ----------
    name
        Stable identifier (matches Java's enum constant name) used
        as the pytest parametrize id.
    build_fixture
        Callable ``(target: Path) -> Path`` that writes a fresh
        ``.tio`` containing **only** this accessor's content.
    assert_content_equals
        Callable ``(a: SpectralDataset, b: SpectralDataset) -> None``
        that raises ``AssertionError`` on any field-level mismatch
        for this accessor. Comparators are field-by-field rather
        than ``__eq__``-based so the failure message points at the
        exact attribute that drifted.
    """

    name: str
    build_fixture: Callable[[Path], Path]
    assert_content_equals: Callable[[SpectralDataset, SpectralDataset], None]


# ── per-accessor content-equality comparators ────────────────────────


def _ref_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``AccessorSpec.REFERENCES.assertContentEquals``:
    same URI set, same chromosome list per URI, byte-equal sequences."""
    refs_a = dict(a.references)
    refs_b = dict(b.references)
    if len(refs_a) != len(refs_b):
        raise AssertionError(
            f"reference count mismatch: {len(refs_a)} vs {len(refs_b)}"
        )
    for uri, ref_a in refs_a.items():
        ref_b = refs_b.get(uri)
        if ref_b is None:
            raise AssertionError(
                f"missing reference {uri!r} in round-trip output"
            )
        if len(ref_a.chromosomes) != len(ref_b.chromosomes):
            raise AssertionError(
                f"chromosome count mismatch for {uri!r}: "
                f"{len(ref_a.chromosomes)} vs {len(ref_b.chromosomes)}"
            )
        # Cross-language note: Java preserves FASTA file order while
        # the Python embed-helper sorts alphabetically. Compare the
        # name set, then look up each sequence by name so the
        # comparator is order-agnostic — matches the spec's
        # order-invariant MD5 contract.
        names_a = sorted(ref_a.chromosomes)
        names_b = sorted(ref_b.chromosomes)
        if names_a != names_b:
            raise AssertionError(
                f"chromosome name set mismatch for {uri!r}: "
                f"{names_a} vs {names_b}"
            )
        seqs_a = {n: s for n, s in zip(ref_a.chromosomes, ref_a.sequences)}
        seqs_b = {n: s for n, s in zip(ref_b.chromosomes, ref_b.sequences)}
        for name in names_a:
            if seqs_a[name] != seqs_b[name]:
                raise AssertionError(
                    f"chromosome sequence mismatch at "
                    f"{uri!r}[{name!r}]: lens "
                    f"{len(seqs_a[name])} vs {len(seqs_b[name])}"
                )


def _ms_runs_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``MS_RUNS.assertContentEquals``: same name set,
    same spectrum count per run, same per-spectrum scan time +
    precursor mz, byte-equal mz/intensity signal arrays."""
    ma = dict(a.ms_runs)
    mb = dict(b.ms_runs)
    if set(ma.keys()) != set(mb.keys()):
        raise AssertionError(
            f"ms-run name set mismatch: {sorted(ma.keys())} vs "
            f"{sorted(mb.keys())}"
        )
    for name in ma.keys():
        ra = ma[name]
        rb = mb[name]
        if len(ra) != len(rb):
            raise AssertionError(
                f"spectrum count mismatch for run {name!r}: "
                f"{len(ra)} vs {len(rb)}"
            )
        for i in range(len(ra)):
            sa = ra[i]
            sb = rb[i]
            if abs(sa.scan_time_seconds - sb.scan_time_seconds) > 1e-9:
                raise AssertionError(
                    f"scan_time mismatch at {name}/{i}: "
                    f"{sa.scan_time_seconds} vs {sb.scan_time_seconds}"
                )
            if abs(sa.precursor_mz - sb.precursor_mz) > 1e-9:
                raise AssertionError(
                    f"precursor_mz mismatch at {name}/{i}: "
                    f"{sa.precursor_mz} vs {sb.precursor_mz}"
                )
            # Compare each declared channel (typically mz, intensity
            # for MS) byte-for-byte. ``signal_array`` returns a
            # SignalArray whose ``.data`` is a numpy view; allclose
            # with strict tolerance catches any silent truncation.
            for c in ra.channel_names:
                arr_a = np.asarray(sa.signal_array(c).data)
                arr_b = np.asarray(sb.signal_array(c).data)
                if not np.array_equal(arr_a, arr_b):
                    raise AssertionError(
                        f"channel {c!r} mismatch at "
                        f"{name}/{i}: shapes "
                        f"{arr_a.shape} vs {arr_b.shape}"
                    )


def _genomic_runs_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``GENOMIC_RUNS.assertContentEquals``: same name
    set, same read count per run, same run-level scalar metadata."""
    ga = dict(a.genomic_runs)
    gb = dict(b.genomic_runs)
    if set(ga.keys()) != set(gb.keys()):
        raise AssertionError(
            f"genomic-run name set mismatch: {sorted(ga.keys())} vs "
            f"{sorted(gb.keys())}"
        )
    for name in ga.keys():
        ra = ga[name]
        rb = gb[name]
        if len(ra) != len(rb):
            raise AssertionError(
                f"read count mismatch for run {name!r}: "
                f"{len(ra)} vs {len(rb)}"
            )
        if ra.reference_uri != rb.reference_uri:
            raise AssertionError(
                f"reference_uri mismatch for run {name!r}: "
                f"{ra.reference_uri!r} vs {rb.reference_uri!r}"
            )
        if ra.platform != rb.platform:
            raise AssertionError(
                f"platform mismatch for run {name!r}: "
                f"{ra.platform!r} vs {rb.platform!r}"
            )
        if ra.sample_name != rb.sample_name:
            raise AssertionError(
                f"sample_name mismatch for run {name!r}: "
                f"{ra.sample_name!r} vs {rb.sample_name!r}"
            )
        if int(ra.acquisition_mode) != int(rb.acquisition_mode):
            raise AssertionError(
                f"acquisition_mode mismatch for run {name!r}: "
                f"{int(ra.acquisition_mode)} vs "
                f"{int(rb.acquisition_mode)}"
            )


def _image_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``IMAGE.assertContentEquals``: same shape,
    element-wise m/z axis equality (within 1e-9), element-wise
    intensity cube equality (within 1e-9)."""
    ia = a.image
    ib = b.image
    if ia is None or ib is None:
        raise AssertionError(
            f"MSImage missing on at least one side: a={ia}, b={ib}"
        )
    if (ia.width, ia.height, ia.spectral_points) != \
            (ib.width, ib.height, ib.spectral_points):
        raise AssertionError(
            f"image shape mismatch: {ia.width}x{ia.height}x"
            f"{ia.spectral_points} vs {ib.width}x{ib.height}x"
            f"{ib.spectral_points}"
        )
    mz_a = np.asarray(ia.mz_axis)
    mz_b = np.asarray(ib.mz_axis)
    if mz_a.shape != mz_b.shape:
        raise AssertionError(
            f"mz_axis length mismatch: {mz_a.shape} vs {mz_b.shape}"
        )
    for i in range(mz_a.size):
        if not math.isclose(float(mz_a[i]), float(mz_b[i]), abs_tol=1e-9):
            raise AssertionError(
                f"mz_axis[{i}] mismatch: {mz_a[i]} vs {mz_b[i]}"
            )
    cube_a = np.asarray(ia.intensity)
    cube_b = np.asarray(ib.intensity)
    if cube_a.shape != cube_b.shape:
        raise AssertionError(
            f"intensity-cube shape mismatch: {cube_a.shape} vs "
            f"{cube_b.shape}"
        )
    # Element-wise absolute comparison; numpy.allclose with the same
    # tolerance gives one log line on failure instead of N.
    if not np.allclose(cube_a, cube_b, atol=1e-9, rtol=0.0):
        # Find the first mismatch for a useful error message.
        diff = np.abs(cube_a - cube_b)
        idx = np.unravel_index(int(np.argmax(diff)), diff.shape)
        raise AssertionError(
            f"intensity-cube mismatch at {idx}: "
            f"{cube_a[idx]} vs {cube_b[idx]}"
        )


def _identifications_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``IDENTIFICATIONS.assertContentEquals``: same row
    count and each row's run_name / spectrum_index / chemical_entity /
    confidence_score / evidence_chain."""
    la = a.identifications()
    lb = b.identifications()
    if len(la) != len(lb):
        raise AssertionError(
            f"identification count mismatch: {len(la)} vs {len(lb)}"
        )
    for i, (ia, ib) in enumerate(zip(la, lb)):
        if ia.run_name != ib.run_name:
            raise AssertionError(
                f"identification[{i}].run_name mismatch: "
                f"{ia.run_name!r} vs {ib.run_name!r}"
            )
        if ia.spectrum_index != ib.spectrum_index:
            raise AssertionError(
                f"identification[{i}].spectrum_index mismatch: "
                f"{ia.spectrum_index} vs {ib.spectrum_index}"
            )
        if ia.chemical_entity != ib.chemical_entity:
            raise AssertionError(
                f"identification[{i}].chemical_entity mismatch: "
                f"{ia.chemical_entity!r} vs {ib.chemical_entity!r}"
            )
        if abs(ia.confidence_score - ib.confidence_score) >= 1e-9:
            raise AssertionError(
                f"identification[{i}].confidence_score mismatch: "
                f"{ia.confidence_score} vs {ib.confidence_score}"
            )
        if list(ia.evidence_chain) != list(ib.evidence_chain):
            raise AssertionError(
                f"identification[{i}].evidence_chain mismatch: "
                f"{ia.evidence_chain!r} vs {ib.evidence_chain!r}"
            )


def _quantifications_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``QUANTIFICATIONS.assertContentEquals``: same row
    count and each row's chemical_entity / sample_ref / abundance /
    normalization_method / unit."""
    la = a.quantifications()
    lb = b.quantifications()
    if len(la) != len(lb):
        raise AssertionError(
            f"quantification count mismatch: {len(la)} vs {len(lb)}"
        )
    for i, (qa, qb) in enumerate(zip(la, lb)):
        if qa.chemical_entity != qb.chemical_entity:
            raise AssertionError(
                f"quantification[{i}].chemical_entity mismatch: "
                f"{qa.chemical_entity!r} vs {qb.chemical_entity!r}"
            )
        if qa.sample_ref != qb.sample_ref:
            raise AssertionError(
                f"quantification[{i}].sample_ref mismatch: "
                f"{qa.sample_ref!r} vs {qb.sample_ref!r}"
            )
        if abs(qa.abundance - qb.abundance) >= 1e-9:
            raise AssertionError(
                f"quantification[{i}].abundance mismatch: "
                f"{qa.abundance} vs {qb.abundance}"
            )
        if qa.normalization_method != qb.normalization_method:
            raise AssertionError(
                f"quantification[{i}].normalization_method mismatch: "
                f"{qa.normalization_method!r} vs "
                f"{qb.normalization_method!r}"
            )
        if qa.unit != qb.unit:
            raise AssertionError(
                f"quantification[{i}].unit mismatch: "
                f"{qa.unit!r} vs {qb.unit!r}"
            )


def _provenance_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``DATASET_PROVENANCE.assertContentEquals``: same
    record count, same per-record timestamp / software / parameters /
    input_refs / output_refs. ``parameters`` is compared as a dict
    (key order-agnostic) to match Java's
    ``Objects.equals(parameters, parameters)`` on a ``Map`` —
    on-disk JSON ordering MAY drift but the dict contents MUST not."""
    la = a.provenance()
    lb = b.provenance()
    if len(la) != len(lb):
        raise AssertionError(
            f"provenance count mismatch: {len(la)} vs {len(lb)}"
        )
    for i, (pa, pb) in enumerate(zip(la, lb)):
        if pa.timestamp_unix != pb.timestamp_unix:
            raise AssertionError(
                f"provenance[{i}].timestamp_unix mismatch: "
                f"{pa.timestamp_unix} vs {pb.timestamp_unix}"
            )
        if pa.software != pb.software:
            raise AssertionError(
                f"provenance[{i}].software mismatch: "
                f"{pa.software!r} vs {pb.software!r}"
            )
        if dict(pa.parameters) != dict(pb.parameters):
            raise AssertionError(
                f"provenance[{i}].parameters mismatch: "
                f"{dict(pa.parameters)!r} vs {dict(pb.parameters)!r}"
            )
        if list(pa.input_refs) != list(pb.input_refs):
            raise AssertionError(
                f"provenance[{i}].input_refs mismatch: "
                f"{list(pa.input_refs)!r} vs {list(pb.input_refs)!r}"
            )
        if list(pa.output_refs) != list(pb.output_refs):
            raise AssertionError(
                f"provenance[{i}].output_refs mismatch: "
                f"{list(pa.output_refs)!r} vs {list(pb.output_refs)!r}"
            )


def _encryption_algorithm_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``ENCRYPTION_ALGORITHM.assertContentEquals``:
    same ``is_encrypted`` flag, same algorithm string."""
    if a.is_encrypted != b.is_encrypted:
        raise AssertionError(
            f"is_encrypted mismatch: {a.is_encrypted} vs {b.is_encrypted}"
        )
    if a.encrypted_algorithm != b.encrypted_algorithm:
        raise AssertionError(
            f"encrypted_algorithm mismatch: "
            f"{a.encrypted_algorithm!r} vs {b.encrypted_algorithm!r}"
        )


# ── master list — order matches Java's enum declaration ──────────────


ACCESSOR_SPECS: list[AccessorSpec] = [
    AccessorSpec("REFERENCES", build_reference_only, _ref_equals),
    AccessorSpec("MS_RUNS", build_ms_runs_only, _ms_runs_equals),
    AccessorSpec("GENOMIC_RUNS", build_genomic_runs_only, _genomic_runs_equals),
    AccessorSpec("IMAGE", build_image_ms_continuous, _image_equals),
    AccessorSpec(
        "IDENTIFICATIONS",
        build_identifications_only,
        _identifications_equals,
    ),
    AccessorSpec(
        "QUANTIFICATIONS",
        build_quantifications_only,
        _quantifications_equals,
    ),
    AccessorSpec(
        "DATASET_PROVENANCE",
        build_dataset_provenance_only,
        _provenance_equals,
    ),
    AccessorSpec(
        "ENCRYPTION_ALGORITHM",
        build_encryption_algorithm_only,
        _encryption_algorithm_equals,
    ),
]
