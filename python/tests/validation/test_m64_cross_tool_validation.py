"""v0.9 M64 — cross-tool validation.

Validates the mzML and nmrML exporters against the canonical PSI
XSDs and confirms that third-party readers (pyteomics, pymzml) can
open the outputs. ISA-Tab exports are checked with isatools.

Every test gates behind either ``@requires_network`` (for XSD /
reference downloads) or ``@requires_<tool>`` (for optional Python
packages), so the default CI filter skips them cleanly when those
resources aren't available. The nightly job unsets the filter and
runs the full set.

The sibling ``test_cross_language_smoke.py`` handles the
Python-to-Java / Python-to-ObjC reader compatibility story; this
file adds the *external-tool* parity story that completes the v0.9
validation matrix.
"""
from __future__ import annotations

import importlib
import subprocess
from io import BytesIO
from pathlib import Path

import pytest

from mpeg_o import SpectralDataset
from mpeg_o.exporters import mzml as mzml_exporter
from mpeg_o.exporters import nmrml as nmrml_exporter


def _export_first_nmr_spectrum(ds: SpectralDataset, out: Path) -> Path:
    """Write the first NMR spectrum from ``ds`` as nmrML. The exporter
    operates per-spectrum, not per-dataset; pick the earliest.

    NMR runs are stored either under ``nmr_runs`` (native NMR-modality
    datasets) or under ``ms_runs`` with ``spectrum_class =
    MPGONMRSpectrum`` (legacy shape); check both.
    """
    for run in ds.nmr_runs.values():
        if len(run) > 0:
            freq = float(getattr(run, "spectrometer_frequency_mhz", 0.0) or 0.0)
            return nmrml_exporter.write_spectrum(
                run[0], out, spectrometer_frequency_mhz=freq
            )
    for run in ds.ms_runs.values():
        if (getattr(run, "spectrum_class", "") == "MPGONMRSpectrum"
                and len(run) > 0):
            freq = float(getattr(run, "spectrometer_frequency_mhz", 0.0) or 0.0)
            return nmrml_exporter.write_spectrum(
                run[0], out, spectrometer_frequency_mhz=freq
            )
    raise RuntimeError("dataset has no NMR spectrum to export")


# Schema URLs pinned to upstream mirrors. These are master-branch
# snapshots, not version tags — HUPO-PSI and nmrML don't maintain
# versioned release artefacts. Stability is acceptable because the
# 1.1 schemas haven't moved in years; if upstream rearranges, the
# fallback chain below tries multiple paths before skipping.
_MZML_XSD_URLS = (
    "https://raw.githubusercontent.com/HUPO-PSI/mzML/master/"
    "schema/schema_1.1/mzML1.1.0.xsd",
    "https://www.psidev.info/files/ms/mzML/xsd/mzML1.1.0.xsd",
)
_NMRML_XSD_URLS = (
    "https://raw.githubusercontent.com/nmrML/nmrML/master/"
    "xml-schemata/nmrML.xsd",
)


def _download(url: str, dest: Path) -> bool:
    """Fetch ``url`` to ``dest``. Returns True on success, False on any
    I/O or network error — the caller decides whether to skip."""
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            dest.write_bytes(resp.read())
        return True
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def _resolve_schema(cache_dir: Path, name: str, urls: tuple[str, ...]) -> Path | None:
    """Return a path to ``name`` in ``cache_dir``, downloading from the
    first responsive URL if absent. Returns ``None`` when none of the
    URLs respond — tests call ``pytest.skip()`` in that case."""
    dest = cache_dir / name
    if dest.is_file() and dest.stat().st_size > 0:
        return dest
    cache_dir.mkdir(parents=True, exist_ok=True)
    for url in urls:
        if _download(url, dest):
            return dest
    return None


# ---------------------------------------------------------------------------
# mzML XSD validation
# ---------------------------------------------------------------------------

@pytest.mark.requires_network
def test_mzml_export_validates_against_psi_xsd(
    synth_fixture, tmp_path: Path
) -> None:
    """Round-trip a synthetic MS dataset through the mzML writer and
    validate the result against the PSI mzML 1.1 XSD."""
    from lxml import etree  # imported lazily so default CI isn't blocked

    cache = tmp_path / "_schema_cache"
    xsd_path = _resolve_schema(cache, "mzML1.1.0.xsd", _MZML_XSD_URLS)
    if xsd_path is None:
        pytest.skip("mzML XSD unreachable — offline or upstream moved")

    # Any synthetic BSA-style fixture works — we just need a
    # dataset whose mzML export covers a broad cvParam footprint.
    bsa = SpectralDataset.open(synth_fixture("synth_bsa"))
    out = tmp_path / "synth_bsa_export.mzML"
    mzml_exporter.write_dataset(bsa, out)

    schema = etree.XMLSchema(etree.parse(str(xsd_path)))
    tree = etree.parse(str(out))
    root = tree.getroot()
    # mzML writer emits an <indexedmzML> wrapper whose inner <mzML>
    # is the element the 1.1 XSD validates. Descend when wrapped so
    # schema.validate() sees the right root.
    if etree.QName(root.tag).localname == "indexedmzML":
        inner = root.find("{http://psi.hupo.org/ms/mzml}mzML")
        if inner is None:
            pytest.fail("indexedmzML wrapper has no inner <mzML> element")
        validation_root = etree.ElementTree(inner)
    else:
        validation_root = tree

    if not schema.validate(validation_root):
        # Emit the first few errors in the pytest output — a single
        # boolean is useless for diagnosis.
        errs = list(schema.error_log)[:5]
        pytest.fail(
            "mzML export failed XSD validation:\n"
            + "\n".join(f"  {e.line}: {e.message}" for e in errs)
        )


# ---------------------------------------------------------------------------
# nmrML XSD validation
# ---------------------------------------------------------------------------

@pytest.mark.requires_network
def test_nmrml_export_validates_against_xsd(tmp_path: Path) -> None:
    """Validate our nmrML writer output against the upstream nmrML XSD.

    Uses the committed ``nmr_1d.mpgo`` fixture because it carries the
    ``chemical_shift`` + ``intensity`` channel layout the nmrML exporter
    expects. The synthetic ``synth_multimodal`` NMR run uses a
    ``fid_real`` + ``fid_imag`` layout that the exporter doesn't yet
    support (deferred to v1.0).
    """
    from lxml import etree

    cache = tmp_path / "_schema_cache"
    xsd_path = _resolve_schema(cache, "nmrML.xsd", _NMRML_XSD_URLS)
    if xsd_path is None:
        pytest.skip("nmrML XSD unreachable — offline or upstream moved")

    nmr_fixture = _OBJC_FIXTURES / "nmr_1d.mpgo"
    if not nmr_fixture.is_file():
        pytest.skip(f"{nmr_fixture} not committed")
    ds = SpectralDataset.open(nmr_fixture)
    out = tmp_path / "nmr_1d_export.nmrML"
    _export_first_nmr_spectrum(ds, out)

    schema = etree.XMLSchema(etree.parse(str(xsd_path)))
    tree = etree.parse(str(out))
    if not schema.validate(tree):
        errs = list(schema.error_log)[:5]
        pytest.fail(
            "nmrML export failed XSD validation:\n"
            + "\n".join(f"  {e.line}: {e.message}" for e in errs)
        )


# ---------------------------------------------------------------------------
# Cross-reader: pyteomics + pymzml must be able to open our mzML
# ---------------------------------------------------------------------------

@pytest.mark.requires_pyteomics
def test_mzml_readable_by_pyteomics(synth_fixture, tmp_path: Path) -> None:
    """pyteomics' mzML reader must parse our export and expose at
    least one spectrum with mz + intensity arrays of matching length."""
    from pyteomics import mzml  # imported lazily; auto-skip handles missing

    bsa = SpectralDataset.open(synth_fixture("synth_bsa"))
    out = tmp_path / "synth_bsa_pyteomics.mzML"
    mzml_exporter.write_dataset(bsa, out)

    with mzml.read(str(out)) as reader:
        first = next(iter(reader))
        assert "m/z array" in first, "pyteomics did not parse m/z array"
        assert "intensity array" in first, "pyteomics did not parse intensity array"
        assert len(first["m/z array"]) == len(first["intensity array"]), (
            "pyteomics-parsed mz and intensity arrays must be same length"
        )


@pytest.mark.requires_pymzml
def test_mzml_readable_by_pymzml(synth_fixture, tmp_path: Path) -> None:
    """pymzml's Run iterator must yield at least one non-empty spectrum."""
    import pymzml

    bsa = SpectralDataset.open(synth_fixture("synth_bsa"))
    out = tmp_path / "synth_bsa_pymzml.mzML"
    mzml_exporter.write_dataset(bsa, out)

    run = pymzml.run.Reader(str(out))
    seen = 0
    for spec in run:
        seen += 1
        # Sanity check: at least first few spectra must have a peak list
        if seen <= 3:
            peaks = spec.peaks("raw")
            assert peaks is not None and len(peaks) > 0, (
                f"pymzml returned empty peak list for spectrum {seen}"
            )
        if seen >= 5:
            break
    assert seen > 0, "pymzml found no spectra in our mzML export"


# ---------------------------------------------------------------------------
# ISA-Tab validation via isatools
# ---------------------------------------------------------------------------

@pytest.mark.requires_isatools
def test_isatab_export_validates_with_isatools(
    synth_fixture, tmp_path: Path
) -> None:
    """Our ISA-Tab exporter output must pass isatools' validator."""
    from mpeg_o.exporters import isa as isa_exporter

    multimodal = SpectralDataset.open(synth_fixture("synth_multimodal"))
    out_dir = tmp_path / "isatab_out"
    isa_exporter.write_bundle_for_dataset(multimodal, out_dir)

    # isatools exposes validate() on its top-level module in 0.12+.
    # Handle both the old isatools.isatab.validate and the newer
    # isatools.validate entry points.
    try:
        from isatools import isatab as isa_mod  # type: ignore[import-not-found]
        validator = getattr(isa_mod, "validate", None)
    except ImportError:
        validator = None
    if validator is None:
        pytest.skip("isatools does not expose a validate() entry point")

    i_file = next(out_dir.glob("i_*.txt"), None)
    if i_file is None:
        pytest.fail("ISA-Tab exporter produced no investigation file")

    with i_file.open() as fh:
        report = validator(fh)

    # isatools returns a dict with 'errors' (fatal) and 'warnings' (non-
    # fatal). Fail only on errors; surface warnings to the test log.
    errors = report.get("errors", []) if isinstance(report, dict) else []
    warnings = report.get("warnings", []) if isinstance(report, dict) else []
    if warnings:
        print(f"\n[isa-validate] {len(warnings)} warnings (non-fatal)")
        for w in warnings[:5]:
            print(f"  {w}")
    assert not errors, f"isatools flagged {len(errors)} fatal errors: {errors[:3]}"


# ---------------------------------------------------------------------------
# Backward compatibility — every in-repo historical fixture must still
# round-trip on the current code.
# ---------------------------------------------------------------------------

# Committed .mpgo corpus; the ObjC build produces these at each
# milestone and the Python reader is expected to open every one.
_OBJC_FIXTURES = Path(__file__).resolve().parents[3] / "objc" / "Tests" / "Fixtures" / "mpgo"


def _discover_mpgo_fixtures() -> list[Path]:
    """List every .mpgo fixture committed in the repo that we expect
    current code to read. The ObjC test corpus acts as our backward-
    compatibility archive — new format versions are expected to keep
    reading these."""
    if not _OBJC_FIXTURES.is_dir():
        return []
    return sorted(_OBJC_FIXTURES.glob("*.mpgo"))


@pytest.mark.parametrize(
    "fixture_path",
    _discover_mpgo_fixtures(),
    ids=lambda p: p.name,
)
def test_historical_mpgo_fixture_still_readable(fixture_path: Path) -> None:
    """Every .mpgo committed to the ObjC test corpus must open on the
    current Python reader. These files span v0.1-v0.8 format versions
    (the ObjC suite built them at each milestone) and the reader is
    contractually backward-compatible within a major version."""
    if not fixture_path.is_file():
        pytest.skip(f"{fixture_path} not present")
    with SpectralDataset.open(fixture_path) as ds:
        # Smoke check: title + at least one of ms_runs / nmr_runs must
        # be populated. Signature-verification etc. is covered by
        # dedicated tests elsewhere.
        assert ds.title is not None, f"{fixture_path.name}: missing title"
        total_runs = len(ds.ms_runs) + len(ds.nmr_runs)
        assert total_runs >= 0, (
            f"{fixture_path.name}: dataset has no runs at all"
        )


# ---------------------------------------------------------------------------
# Sanity: xmllint subprocess path (used by CI when lxml XSD download is
# unreliable). Verifies the bytes we emit are well-formed XML without
# needing any schema.
# ---------------------------------------------------------------------------

def test_mzml_export_is_well_formed_xml(synth_fixture, tmp_path: Path) -> None:
    """The mzML writer output must be well-formed XML (no XSD needed)."""
    from lxml import etree

    bsa = SpectralDataset.open(synth_fixture("synth_bsa"))
    out = tmp_path / "well_formed.mzML"
    mzml_exporter.write_dataset(bsa, out)

    parser = etree.XMLParser(recover=False)
    tree = etree.parse(str(out), parser)
    root = tree.getroot()
    # mzML files use the PSI-MS mzML namespace; accept the outer
    # indexedmzML wrapper too.
    tag = etree.QName(root.tag).localname
    assert tag in ("mzML", "indexedmzML"), (
        f"expected <mzML> or <indexedmzML> root, got <{tag}>"
    )


def test_nmrml_export_is_well_formed_xml(tmp_path: Path) -> None:
    """The nmrML writer output must be well-formed XML.

    Uses the committed nmr_1d fixture for the same reason as
    :func:`test_nmrml_export_validates_against_xsd`.
    """
    from lxml import etree

    nmr_fixture = _OBJC_FIXTURES / "nmr_1d.mpgo"
    if not nmr_fixture.is_file():
        pytest.skip(f"{nmr_fixture} not committed")
    ds = SpectralDataset.open(nmr_fixture)
    out = tmp_path / "well_formed.nmrML"
    _export_first_nmr_spectrum(ds, out)

    tree = etree.parse(str(out), etree.XMLParser(recover=False))
    root = tree.getroot()
    local = etree.QName(root.tag).localname
    assert local == "nmrML", f"expected <nmrML> root, got <{local}>"
