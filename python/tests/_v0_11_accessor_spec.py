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

Stage 1 (Task 2.10): 8 first-class accessors covered.

Stage 5 (Task 5.6, Deferral 1): MS_IMAGE_PROCESSED, RAMAN_IMAGE,
IR_IMAGE. MS_IMAGE_PROCESSED shares the IMAGE fixture but supplies
a custom ``encode_strategy`` callable that swaps the writer's
``write_image`` for ``write_image_processed`` (opt-in sparse wire
mode). The remaining two integrate via the §5.4.5 image-block
prelude and use the default ``write_dataset`` encode path.

Stage 6 (Task 6.6, Deferral 2): SUBJECTS, SAMPLES. Both flow through
``write_dataset`` unchanged — the §5.4.3 prelude emits
SUBJECT_METADATA (0x19) before SAMPLE_METADATA (0x1A) when present,
and the reader layers them back as ``/study/subjects/<external_id>/``
+ ``/study/samples/<sample_id>/`` HDF5 groups.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

import numpy as np

from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import (
    TRANSPORT_V0_11_FEATURE,
    TransportWriter,
)

from _v0_11_fixtures import (
    build_dataset_provenance_only,
    build_encryption_algorithm_only,
    build_genomic_runs_only,
    build_identifications_only,
    build_image_ms_continuous,
    build_image_ms_processed_only,
    build_ir_image_only,
    build_ms_runs_only,
    build_quantifications_only,
    build_raman_image_only,
    build_reference_only,
    build_samples_only,
    build_subjects_only,
)


def _default_encode(
    source: SpectralDataset, out: io.IOBase
) -> None:
    """Default encode: drop the whole dataset through
    :meth:`TransportWriter.write_dataset`. Honoured by every
    AccessorSpec entry whose ``encode_strategy`` is left as the
    default."""
    with TransportWriter(out) as w:
        w.write_dataset(source)


def _ms_image_processed_encode(
    source: SpectralDataset, out: io.IOBase
) -> None:
    """Stage 5 / Task 5.6: MS_IMAGE_PROCESSED encode path.

    Emits a minimal §5.4 prelude by hand with
    :meth:`TransportWriter.write_image_processed` swapped in where
    :meth:`write_image` would otherwise sit. The source fixture
    carries only an MSImage, so the rest of the prelude collapses to
    stream-header + image + EOS — matches the Java ordering exactly
    so the materialised .tio carries a fully-formed dense intensity
    cube on the other side."""
    with TransportWriter(out) as w:
        w.write_stream_header(
            format_version="1.2",
            title=source.title or "",
            isa_investigation=source.isa_investigation_id or "",
            features=[TRANSPORT_V0_11_FEATURE],
            n_datasets=0,
        )
        w.write_image_processed(source.image)
        w.write_end_of_stream()


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
    encode_strategy
        Optional callable ``(source: SpectralDataset, out) -> None``
        that overrides the default
        :meth:`TransportWriter.write_dataset` encode path. Used by
        MS_IMAGE_PROCESSED to swap in ``write_image_processed``;
        every other accessor inherits the default.
    """

    name: str
    build_fixture: Callable[[Path], Path]
    assert_content_equals: Callable[[SpectralDataset, SpectralDataset], None]
    encode_strategy: Callable[[SpectralDataset, Any], None] = field(
        default=_default_encode
    )


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


# ── Stage 5 / Task 5.6 comparators (Deferral 1) ─────────────────────


def _raman_image_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``RAMAN_IMAGE.assertContentEquals``: same shape +
    excitation + laser power + scan pattern + element-wise wavenumbers
    + element-wise intensity cube (all within 1e-9)."""
    ra = a.raman_image
    rb = b.raman_image
    if ra is None or rb is None:
        raise AssertionError(
            f"RamanImage missing on at least one side: a={ra}, b={rb}"
        )
    if (ra.width, ra.height, ra.spectral_points) != (
        rb.width, rb.height, rb.spectral_points
    ):
        raise AssertionError(
            f"raman shape mismatch: {ra.width}x{ra.height}x"
            f"{ra.spectral_points} vs {rb.width}x{rb.height}x"
            f"{rb.spectral_points}"
        )
    if not math.isclose(
        ra.excitation_wavelength_nm, rb.excitation_wavelength_nm,
        abs_tol=1e-9,
    ):
        raise AssertionError(
            f"excitation_wavelength_nm mismatch: "
            f"{ra.excitation_wavelength_nm} vs {rb.excitation_wavelength_nm}"
        )
    if not math.isclose(ra.laser_power_mw, rb.laser_power_mw, abs_tol=1e-9):
        raise AssertionError(
            f"laser_power_mw mismatch: "
            f"{ra.laser_power_mw} vs {rb.laser_power_mw}"
        )
    if ra.scan_pattern != rb.scan_pattern:
        raise AssertionError(
            f"raman scan_pattern mismatch: "
            f"{ra.scan_pattern!r} vs {rb.scan_pattern!r}"
        )
    wn_a = np.asarray(ra.wavenumbers)
    wn_b = np.asarray(rb.wavenumbers)
    if wn_a.shape != wn_b.shape:
        raise AssertionError(
            f"wavenumbers length mismatch: {wn_a.shape} vs {wn_b.shape}"
        )
    if not np.allclose(wn_a, wn_b, atol=1e-9, rtol=0.0):
        idx = int(np.argmax(np.abs(wn_a - wn_b)))
        raise AssertionError(
            f"wavenumbers[{idx}] mismatch: {wn_a[idx]} vs {wn_b[idx]}"
        )
    c_a = np.asarray(ra.intensity)
    c_b = np.asarray(rb.intensity)
    if c_a.shape != c_b.shape:
        raise AssertionError(
            f"raman intensity-cube shape mismatch: {c_a.shape} vs {c_b.shape}"
        )
    if not np.allclose(c_a, c_b, atol=1e-9, rtol=0.0):
        diff = np.abs(c_a - c_b)
        idx = np.unravel_index(int(np.argmax(diff)), diff.shape)
        raise AssertionError(
            f"raman intensity-cube mismatch at {idx}: "
            f"{c_a[idx]} vs {c_b[idx]}"
        )


def _ir_image_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``IR_IMAGE.assertContentEquals``: same shape +
    mode + resolution + scan pattern + element-wise wavenumbers +
    element-wise intensity cube (all within 1e-9)."""
    ia = a.ir_image
    ib = b.ir_image
    if ia is None or ib is None:
        raise AssertionError(
            f"IRImage missing on at least one side: a={ia}, b={ib}"
        )
    if (ia.width, ia.height, ia.spectral_points) != (
        ib.width, ib.height, ib.spectral_points
    ):
        raise AssertionError(
            f"ir shape mismatch: {ia.width}x{ia.height}x"
            f"{ia.spectral_points} vs {ib.width}x{ib.height}x"
            f"{ib.spectral_points}"
        )
    if int(ia.mode) != int(ib.mode):
        raise AssertionError(
            f"ir mode mismatch: {int(ia.mode)} vs {int(ib.mode)}"
        )
    if not math.isclose(
        ia.resolution_cm_inv, ib.resolution_cm_inv, abs_tol=1e-9
    ):
        raise AssertionError(
            f"ir resolution_cm_inv mismatch: "
            f"{ia.resolution_cm_inv} vs {ib.resolution_cm_inv}"
        )
    if ia.scan_pattern != ib.scan_pattern:
        raise AssertionError(
            f"ir scan_pattern mismatch: "
            f"{ia.scan_pattern!r} vs {ib.scan_pattern!r}"
        )
    wn_a = np.asarray(ia.wavenumbers)
    wn_b = np.asarray(ib.wavenumbers)
    if wn_a.shape != wn_b.shape:
        raise AssertionError(
            f"ir wavenumbers length mismatch: {wn_a.shape} vs {wn_b.shape}"
        )
    if not np.allclose(wn_a, wn_b, atol=1e-9, rtol=0.0):
        idx = int(np.argmax(np.abs(wn_a - wn_b)))
        raise AssertionError(
            f"ir wavenumbers[{idx}] mismatch: {wn_a[idx]} vs {wn_b[idx]}"
        )
    c_a = np.asarray(ia.intensity)
    c_b = np.asarray(ib.intensity)
    if c_a.shape != c_b.shape:
        raise AssertionError(
            f"ir intensity-cube shape mismatch: {c_a.shape} vs {c_b.shape}"
        )
    if not np.allclose(c_a, c_b, atol=1e-9, rtol=0.0):
        diff = np.abs(c_a - c_b)
        idx = np.unravel_index(int(np.argmax(diff)), diff.shape)
        raise AssertionError(
            f"ir intensity-cube mismatch at {idx}: "
            f"{c_a[idx]} vs {c_b[idx]}"
        )


# ── Stage 6 / Task 6.6 comparators (Deferral 2) ─────────────────────


def _subjects_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``SUBJECTS.assertContentEquals``: same row count
    and each row's external_id / project / sex / birth_year /
    attributes (dict-equal — key order doesn't matter; the sort-keys
    JSON serialisation is the cross-language byte-parity contract,
    not the in-memory dict)."""
    la = a.subjects
    lb = b.subjects
    if len(la) != len(lb):
        raise AssertionError(
            f"subject count mismatch: {len(la)} vs {len(lb)}"
        )
    for i, (sa, sb) in enumerate(zip(la, lb)):
        if sa.external_id != sb.external_id:
            raise AssertionError(
                f"subject[{i}].external_id mismatch: "
                f"{sa.external_id!r} vs {sb.external_id!r}"
            )
        if sa.project != sb.project:
            raise AssertionError(
                f"subject[{i}].project mismatch: "
                f"{sa.project!r} vs {sb.project!r}"
            )
        if sa.sex != sb.sex:
            raise AssertionError(
                f"subject[{i}].sex mismatch: "
                f"{sa.sex!r} vs {sb.sex!r}"
            )
        if sa.birth_year != sb.birth_year:
            raise AssertionError(
                f"subject[{i}].birth_year mismatch: "
                f"{sa.birth_year} vs {sb.birth_year}"
            )
        if dict(sa.attributes) != dict(sb.attributes):
            raise AssertionError(
                f"subject[{i}].attributes mismatch: "
                f"{dict(sa.attributes)!r} vs {dict(sb.attributes)!r}"
            )


def _samples_equals(a: SpectralDataset, b: SpectralDataset) -> None:
    """Mirror Java's ``SAMPLES.assertContentEquals``: same row count
    and each row's sample_id / subject_external_id / sample_kind /
    collected_at / attributes."""
    la = a.samples
    lb = b.samples
    if len(la) != len(lb):
        raise AssertionError(
            f"sample count mismatch: {len(la)} vs {len(lb)}"
        )
    for i, (sa, sb) in enumerate(zip(la, lb)):
        if sa.sample_id != sb.sample_id:
            raise AssertionError(
                f"sample[{i}].sample_id mismatch: "
                f"{sa.sample_id!r} vs {sb.sample_id!r}"
            )
        if sa.subject_external_id != sb.subject_external_id:
            raise AssertionError(
                f"sample[{i}].subject_external_id mismatch: "
                f"{sa.subject_external_id!r} vs "
                f"{sb.subject_external_id!r}"
            )
        if sa.sample_kind != sb.sample_kind:
            raise AssertionError(
                f"sample[{i}].sample_kind mismatch: "
                f"{sa.sample_kind!r} vs {sb.sample_kind!r}"
            )
        if sa.collected_at != sb.collected_at:
            raise AssertionError(
                f"sample[{i}].collected_at mismatch: "
                f"{sa.collected_at} vs {sb.collected_at}"
            )
        if dict(sa.attributes) != dict(sb.attributes):
            raise AssertionError(
                f"sample[{i}].attributes mismatch: "
                f"{dict(sa.attributes)!r} vs {dict(sb.attributes)!r}"
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
    AccessorSpec(
        "MS_IMAGE_PROCESSED",
        build_image_ms_processed_only,
        _image_equals,
        encode_strategy=_ms_image_processed_encode,
    ),
    AccessorSpec(
        "RAMAN_IMAGE",
        build_raman_image_only,
        _raman_image_equals,
    ),
    AccessorSpec(
        "IR_IMAGE",
        build_ir_image_only,
        _ir_image_equals,
    ),
    # Stage 6 / Task 6.6 (Deferral 2)
    AccessorSpec(
        "SUBJECTS",
        build_subjects_only,
        _subjects_equals,
    ),
    AccessorSpec(
        "SAMPLES",
        build_samples_only,
        _samples_equals,
    ),
]
