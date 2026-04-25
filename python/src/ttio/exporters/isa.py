"""ISA-Tab / ISA-JSON exporter — Python mirror of ``TTIOISAExporter``.

Produces a bundle of UTF-8 text files that describe a
:class:`ttio.SpectralDataset` in the Investigation / Study / Assay
model. Output is byte-identical to the Objective-C exporter for the
same logical input — the M27 cross-language parity test asserts this.

File mapping:

    i_investigation.txt        one row per Investigation metadata field
    s_study.txt                one row per sample (= acquisition run)
    a_assay_ms_<run>.txt       one file per MS run, one row per run
    investigation.json         ISA-JSON (single file per investigation)

SPDX-License-Identifier: Apache-2.0

Cross-language equivalents
--------------------------
Objective-C: ``TTIOISAExporter`` · Java:
``com.dtwthalion.ttio.exporters.ISAExporter``

API status: Stable.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Mapping

from ..spectral_dataset import SpectralDataset


# ------------------------------------------------------------ TSV helpers


def _isa_escape(cell: str | None) -> str:
    """Match ``TTIOISAExporter``'s escape rules.

    Quotes cells containing a tab, quote, or newline; interior quotes
    are doubled. Pure-ASCII plain cells pass through unchanged.
    """
    if cell is None:
        return ""
    if any(ch in cell for ch in "\t\"\n"):
        return '"' + cell.replace('"', '""') + '"'
    return cell


def _row(cells: list[str]) -> str:
    return "\t".join(_isa_escape(c) for c in cells) + "\n"


# ---------------------------------------------------- per-file builders


def _investigation_file(dataset: SpectralDataset, run_names: list[str]) -> bytes:
    buf: list[str] = []
    buf.append("ONTOLOGY SOURCE REFERENCE\n")
    buf.append(_row(["Term Source Name", "MS"]))
    buf.append(_row([
        "Term Source File",
        "https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo",
    ]))
    buf.append(_row(["Term Source Version", "4.1.0"]))
    buf.append(_row([
        "Term Source Description",
        "Proteomics Standards Initiative Mass Spectrometry Ontology",
    ]))

    buf.append("INVESTIGATION\n")
    buf.append(_row(["Investigation Identifier", dataset.isa_investigation_id or ""]))
    buf.append(_row(["Investigation Title", dataset.title or ""]))
    buf.append(_row(["Investigation Description", ""]))
    buf.append(_row(["Investigation Submission Date", ""]))
    buf.append(_row(["Investigation Public Release Date", ""]))

    # ISA-Tab 1.0 requires every investigation-file section header to
    # be present, even when the data rows are empty. isatools halts
    # validation at the first missing required section. The following
    # blocks emit each required section with field labels only — they
    # validate cleanly and leave the investigator free to fill them in
    # later.

    buf.append("INVESTIGATION PUBLICATIONS\n")
    buf.append(_row(["Investigation PubMed ID"]))
    buf.append(_row(["Investigation Publication DOI"]))
    buf.append(_row(["Investigation Publication Author List"]))
    buf.append(_row(["Investigation Publication Title"]))
    buf.append(_row(["Investigation Publication Status"]))
    buf.append(_row(["Investigation Publication Status Term Accession Number"]))
    buf.append(_row(["Investigation Publication Status Term Source REF"]))

    buf.append("INVESTIGATION CONTACTS\n")
    buf.append(_row(["Investigation Person Last Name"]))
    buf.append(_row(["Investigation Person First Name"]))
    buf.append(_row(["Investigation Person Mid Initials"]))
    buf.append(_row(["Investigation Person Email"]))
    buf.append(_row(["Investigation Person Phone"]))
    buf.append(_row(["Investigation Person Fax"]))
    buf.append(_row(["Investigation Person Address"]))
    buf.append(_row(["Investigation Person Affiliation"]))
    buf.append(_row(["Investigation Person Roles"]))
    buf.append(_row(["Investigation Person Roles Term Accession Number"]))
    buf.append(_row(["Investigation Person Roles Term Source REF"]))

    buf.append("STUDY\n")
    buf.append(_row(["Study Identifier", dataset.isa_investigation_id or ""]))
    buf.append(_row(["Study Title", dataset.title or ""]))
    # isatools requires Study Description to be non-empty; fall back to
    # the title when the dataset doesn't carry a dedicated description.
    buf.append(_row([
        "Study Description",
        dataset.title or dataset.isa_investigation_id or "TTI-O exported study",
    ]))
    buf.append(_row(["Study Submission Date", ""]))
    buf.append(_row(["Study Public Release Date", ""]))
    buf.append(_row(["Study File Name", "s_study.txt"]))

    buf.append("STUDY DESIGN DESCRIPTORS\n")
    buf.append(_row(["Study Design Type"]))
    buf.append(_row(["Study Design Type Term Accession Number"]))
    buf.append(_row(["Study Design Type Term Source REF"]))

    buf.append("STUDY PUBLICATIONS\n")
    buf.append(_row(["Study PubMed ID"]))
    buf.append(_row(["Study Publication DOI"]))
    buf.append(_row(["Study Publication Author List"]))
    buf.append(_row(["Study Publication Title"]))
    buf.append(_row(["Study Publication Status"]))
    buf.append(_row(["Study Publication Status Term Accession Number"]))
    buf.append(_row(["Study Publication Status Term Source REF"]))

    buf.append("STUDY FACTORS\n")
    buf.append(_row(["Study Factor Name"]))
    buf.append(_row(["Study Factor Type"]))
    buf.append(_row(["Study Factor Type Term Accession Number"]))
    buf.append(_row(["Study Factor Type Term Source REF"]))

    buf.append("STUDY ASSAYS\n")
    measurement = ["Study Assay Measurement Type"]
    measurement_acc = ["Study Assay Measurement Type Term Accession Number"]
    measurement_ref = ["Study Assay Measurement Type Term Source REF"]
    technology  = ["Study Assay Technology Type"]
    technology_acc = ["Study Assay Technology Type Term Accession Number"]
    technology_ref = ["Study Assay Technology Type Term Source REF"]
    platform    = ["Study Assay Technology Platform"]
    fname       = ["Study Assay File Name"]
    for name in run_names:
        run = dataset.ms_runs[name]
        measurement.append("metabolite profiling")
        measurement_acc.append("")
        measurement_ref.append("")
        technology.append("mass spectrometry")
        technology_acc.append("")
        technology_ref.append("")
        platform.append(run.instrument_config.model or "")
        fname.append(f"a_assay_ms_{name}.txt")
    buf.append(_row(measurement))
    buf.append(_row(measurement_acc))
    buf.append(_row(measurement_ref))
    buf.append(_row(technology))
    buf.append(_row(technology_acc))
    buf.append(_row(technology_ref))
    buf.append(_row(platform))
    buf.append(_row(fname))

    # STUDY PROTOCOLS must declare every Protocol REF that appears in
    # s_study.txt ("sample collection") or a_assay_ms_*.txt ("mass
    # spectrometry"). Columns are tab-separated protocol rows.
    buf.append("STUDY PROTOCOLS\n")
    buf.append(_row(["Study Protocol Name", "sample collection", "mass spectrometry"]))
    buf.append(_row(["Study Protocol Type", "sample collection", "mass spectrometry"]))
    buf.append(_row(["Study Protocol Type Term Accession Number", "", ""]))
    buf.append(_row(["Study Protocol Type Term Source REF", "", ""]))
    buf.append(_row(["Study Protocol Description", "", ""]))
    buf.append(_row(["Study Protocol URI", "", ""]))
    buf.append(_row(["Study Protocol Version", "", ""]))
    buf.append(_row(["Study Protocol Parameters Name", "", ""]))
    buf.append(_row(["Study Protocol Parameters Name Term Accession Number", "", ""]))
    buf.append(_row(["Study Protocol Parameters Name Term Source REF", "", ""]))
    buf.append(_row(["Study Protocol Components Name", "", ""]))
    buf.append(_row(["Study Protocol Components Type", "", ""]))
    buf.append(_row(["Study Protocol Components Type Term Accession Number", "", ""]))
    buf.append(_row(["Study Protocol Components Type Term Source REF", "", ""]))

    buf.append("STUDY CONTACTS\n")
    buf.append(_row(["Study Person Last Name"]))
    buf.append(_row(["Study Person First Name"]))
    buf.append(_row(["Study Person Mid Initials"]))
    buf.append(_row(["Study Person Email"]))
    buf.append(_row(["Study Person Phone"]))
    buf.append(_row(["Study Person Fax"]))
    buf.append(_row(["Study Person Address"]))
    buf.append(_row(["Study Person Affiliation"]))
    buf.append(_row(["Study Person Roles"]))
    buf.append(_row(["Study Person Roles Term Accession Number"]))
    buf.append(_row(["Study Person Roles Term Source REF"]))

    return "".join(buf).encode("utf-8")


def _study_file(dataset: SpectralDataset, run_names: list[str]) -> bytes:
    buf = [_row([
        "Source Name", "Sample Name", "Characteristics[organism]",
        "Protocol REF", "Date",
    ])]
    for name in run_names:
        buf.append(_row([
            f"src_{name}",
            f"sample_{name}",
            "",
            "sample collection",
            "",
        ]))
    return "".join(buf).encode("utf-8")


def _assay_file(dataset: SpectralDataset, run_name: str) -> bytes:
    header = _row([
        "Sample Name",
        "Protocol REF",
        "Parameter Value[instrument]",
        "Parameter Value[ionization]",
        "Assay Name",
        "Raw Spectral Data File",
        "Derived Spectral Data File",
    ])
    run = dataset.ms_runs[run_name]
    chroms = list(run.chromatograms)
    derived = ";".join(
        f"{run_name}_chrom_{i}" for i in range(len(chroms))
    )
    row = _row([
        f"sample_{run_name}",
        "mass spectrometry",
        run.instrument_config.model or "",
        run.instrument_config.source_type or "",
        run_name,
        f"{run_name}.mzML",
        derived,
    ])
    return (header + row).encode("utf-8")


def _isa_json(dataset: SpectralDataset, run_names: list[str]) -> bytes:
    assays = []
    samples = []
    sources = []
    for name in run_names:
        run = dataset.ms_runs[name]
        derived_files = [
            {
                "name": f"{name}_chrom_{i}",
                "type": "Derived Spectral Data File",
            }
            for i in range(len(run.chromatograms))
        ]
        assays.append({
            "dataFiles": [{
                "name": f"{name}.mzML",
                "type": "Raw Spectral Data File",
            }],
            "derivedFiles": derived_files,
            "filename": f"a_assay_ms_{name}.txt",
            "measurementType": {"annotationValue": "metabolite profiling"},
            "technologyPlatform": run.instrument_config.model or "",
            "technologyType": {"annotationValue": "mass spectrometry"},
        })
        samples.append({
            "@id": f"#sample/{name}",
            "name": f"sample_{name}",
        })
        sources.append({
            "@id": f"#source/{name}",
            "name": f"src_{name}",
        })

    study = {
        "assays": assays,
        "filename": "s_study.txt",
        "identifier": dataset.isa_investigation_id or "",
        "materials": {
            "samples": samples,
            "sources": sources,
        },
        "title": dataset.title or "",
    }

    investigation = {
        "identifier": dataset.isa_investigation_id or "",
        "ontologySourceReferences": [{
            "description": "Proteomics Standards Initiative Mass Spectrometry Ontology",
            "file": "https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo",
            "name": "MS",
            "version": "4.1.0",
        }],
        "studies": [study],
        "title": dataset.title or "",
    }

    # ObjC's NSJSONWritingPrettyPrinted and Python's json.dumps differ in
    # whitespace (NSJSONSerialization emits ' : ' on macOS, unpredictable
    # on GNUstep; python's default is ': '). M27's acceptance is
    # "structurally identical" output, not byte-identical — the parity
    # test therefore compares the TSV files byte-for-byte and the ISA-JSON
    # files after parse-and-re-dump normalization. We emit stable sorted
    # keys so round-trips through json.loads give equal Python dicts.
    text = json.dumps(investigation, indent=2, sort_keys=True,
                      ensure_ascii=True)
    return (text + "\n").encode("utf-8")


# ---------------------------------------------------------- public API


def bundle_for_dataset(dataset: SpectralDataset) -> dict[str, bytes]:
    """Return the ISA bundle as ``{filename: bytes}`` for ``dataset``."""
    run_names = sorted(dataset.ms_runs.keys())
    out: dict[str, bytes] = {
        "i_investigation.txt": _investigation_file(dataset, run_names),
        "s_study.txt": _study_file(dataset, run_names),
        "investigation.json": _isa_json(dataset, run_names),
    }
    for name in run_names:
        out[f"a_assay_ms_{name}.txt"] = _assay_file(dataset, name)
    return out


def write_bundle_for_dataset(
    dataset: SpectralDataset, directory: str | Path
) -> Path:
    """Write the ISA bundle to ``directory`` (creating it if needed)."""
    out_dir = Path(directory)
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, blob in bundle_for_dataset(dataset).items():
        (out_dir / name).write_bytes(blob)
    return out_dir
