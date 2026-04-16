"""mzML writer — Python port of ``MPGOMzMLWriter``.

Serializes a :class:`mpeg_o.SpectralDataset` to an ``indexedmzML`` file,
mirroring the XML structure produced by the Objective-C reference
implementation. The text is assembled by hand (rather than through
``xml.etree``) so byte offsets can be tracked precisely for the
``<indexList>`` entries — ``indexedmzML`` requires offsets into the raw
UTF-8 byte stream, not into a DOM model.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import base64
import zlib
from pathlib import Path
from typing import Iterable

import numpy as np

from ..spectral_dataset import SpectralDataset


_PRELUDE = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<indexedmzML xmlns="http://psi.hupo.org/ms/mzml"'
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    ' xsi:schemaLocation="http://psi.hupo.org/ms/mzml'
    ' http://psidev.info/files/ms/mzML/xsd/mzML1.1.0_idx.xsd">\n'
    '  <mzML xmlns="http://psi.hupo.org/ms/mzml"'
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    ' xsi:schemaLocation="http://psi.hupo.org/ms/mzml'
    ' http://psidev.info/files/ms/mzML/xsd/mzML1.1.0.xsd"'
    ' id="mpgo_export" version="1.1.0">\n'
    '    <cvList count="2">\n'
    '      <cv id="MS" fullName="Proteomics Standards Initiative Mass Spectrometry Ontology"'
    ' version="4.1.0" URI="https://raw.githubusercontent.com/HUPO-PSI/psi-ms-CV/master/psi-ms.obo"/>\n'
    '      <cv id="UO" fullName="Unit Ontology" version="releases/2020-03-10"'
    ' URI="http://ontologies.berkeleybop.org/uo.obo"/>\n'
    '    </cvList>\n'
    '    <fileDescription>\n'
    '      <fileContent>\n'
    '        <cvParam cvRef="MS" accession="MS:1000580" name="MSn spectrum" value=""/>\n'
    '      </fileContent>\n'
    '    </fileDescription>\n'
    '    <softwareList count="1">\n'
    '      <software id="mpeg_o" version="0.4.0">\n'
    '        <cvParam cvRef="MS" accession="MS:1000799" name="custom unreleased software tool" value="mpeg-o"/>\n'
    '      </software>\n'
    '    </softwareList>\n'
    '    <instrumentConfigurationList count="1">\n'
    '      <instrumentConfiguration id="IC1">\n'
    '        <cvParam cvRef="MS" accession="MS:1000031" name="instrument model" value=""/>\n'
    '      </instrumentConfiguration>\n'
    '    </instrumentConfigurationList>\n'
    '    <dataProcessingList count="1">\n'
    '      <dataProcessing id="dp_export">\n'
    '        <processingMethod order="0" softwareRef="mpeg_o">\n'
    '          <cvParam cvRef="MS" accession="MS:1000544" name="Conversion to mzML"/>\n'
    '        </processingMethod>\n'
    '      </dataProcessing>\n'
    '    </dataProcessingList>\n'
)


def _xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;").replace("'", "&apos;"))


def _fmt_double(v: float) -> str:
    """Match the ObjC writer's %.15g format."""
    return f"{v:.15g}"


def _encode_array(buf: np.ndarray, zlib_compress: bool) -> str:
    """Encode a numpy array as base64 (optionally zlib-compressed) so the
    output is byte-identical to the Objective-C writer."""
    raw = np.ascontiguousarray(buf, dtype="<f8").tobytes()
    if zlib_compress:
        raw = zlib.compress(raw)
    return base64.b64encode(raw).decode("ascii")


def write_dataset(
    dataset: SpectralDataset,
    path: str | Path,
    *,
    zlib_compression: bool = False,
) -> Path:
    """Serialize ``dataset`` to ``path`` as indexed mzML.

    The first ``MPGOMassSpectrum``-class run in ``dataset.ms_runs`` is
    exported. Additional runs, NMR runs, MSImage cubes, and chromatograms
    are deliberately skipped for M19; extending the writer to cover them
    is straightforward.
    """
    blob = dataset_to_bytes(dataset, zlib_compression=zlib_compression)
    out = Path(path)
    out.write_bytes(blob)
    return out


def dataset_to_bytes(
    dataset: SpectralDataset,
    *,
    zlib_compression: bool = False,
) -> bytes:
    """Build an indexed-mzML byte blob from ``dataset``."""
    runs = dataset.ms_runs
    chosen_name = None
    chosen_run = None
    for name in sorted(runs.keys()):
        run = runs[name]
        if run.spectrum_class == "MPGOMassSpectrum":
            chosen_name = name
            chosen_run = run
            break
    if chosen_run is None:
        raise ValueError("dataset has no MPGOMassSpectrum run to export")

    n = len(chosen_run)
    parts: list[bytes] = []
    total = 0  # running byte offset into the output stream

    def emit(s: str) -> int:
        nonlocal total
        b = s.encode("utf-8")
        parts.append(b)
        offset_at_start = total
        total += len(b)
        return offset_at_start

    emit(_PRELUDE)
    emit(f'    <run id="{_xml_escape(chosen_name)}" defaultInstrumentConfigurationRef="IC1">\n')
    emit(f'      <spectrumList count="{n}" defaultDataProcessingRef="dp_export">\n')

    spectrum_offsets: list[tuple[str, int]] = []
    # The ObjC writer points each <indexList> offset at the first
    # non-whitespace byte of the `<spectrum ` tag (after the eight-byte
    # indent). Track the same anchor here so the two files produce
    # byte-identical index blocks for the same logical input.
    INDENT = "        "
    for i in range(n):
        spec = chosen_run[i]
        mz = np.ascontiguousarray(spec.mz_array.data, dtype="<f8")
        intensity = np.ascontiguousarray(spec.intensity_array.data, dtype="<f8")
        array_length = int(mz.shape[0])
        scan_id = f"scan={i + 1}"

        # Opening tag of the <spectrum> element: record its offset.
        offset_before = total
        emit(f'{INDENT}<spectrum index="{i}" id="{_xml_escape(scan_id)}"'
             f' defaultArrayLength="{array_length}">\n')
        spectrum_offsets.append((scan_id, offset_before + len(INDENT)))

        emit('          <cvParam cvRef="MS" accession="MS:1000580" name="MSn spectrum" value=""/>\n')
        emit(f'          <cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="{int(spec.ms_level)}"/>\n')
        if spec.polarity == 1:
            emit('          <cvParam cvRef="MS" accession="MS:1000130" name="positive scan" value=""/>\n')
        elif spec.polarity == -1:
            emit('          <cvParam cvRef="MS" accession="MS:1000129" name="negative scan" value=""/>\n')

        emit('          <scanList count="1">\n')
        emit('            <cvParam cvRef="MS" accession="MS:1000795" name="no combination" value=""/>\n')
        emit('            <scan>\n')
        emit(f'              <cvParam cvRef="MS" accession="MS:1000016" name="scan start time"'
             f' value="{_fmt_double(float(spec.retention_time))}"'
             f' unitCvRef="UO" unitAccession="UO:0000010" unitName="second"/>\n')
        emit('            </scan>\n')
        emit('          </scanList>\n')

        if spec.precursor_mz > 0.0 or int(spec.ms_level) > 1:
            emit('          <precursorList count="1">\n')
            emit('            <precursor>\n')
            emit('              <selectedIonList count="1">\n')
            emit('                <selectedIon>\n')
            emit(f'                  <cvParam cvRef="MS" accession="MS:1000744" name="selected ion m/z"'
                 f' value="{_fmt_double(float(spec.precursor_mz))}"'
                 f' unitCvRef="MS" unitAccession="MS:1000040" unitName="m/z"/>\n')
            if spec.precursor_charge > 0:
                emit(f'                  <cvParam cvRef="MS" accession="MS:1000041" name="charge state"'
                     f' value="{int(spec.precursor_charge)}"/>\n')
            emit('                </selectedIon>\n')
            emit('              </selectedIonList>\n')
            emit('            </precursor>\n')
            emit('          </precursorList>\n')

        emit('          <binaryDataArrayList count="2">\n')
        mz_b64 = _encode_array(mz, zlib_compression)
        in_b64 = _encode_array(intensity, zlib_compression)
        comp_acc = "MS:1000574" if zlib_compression else "MS:1000576"
        comp_name = "zlib compression" if zlib_compression else "no compression"
        for accession, name, unit_acc, unit_name, payload in (
            ("MS:1000514", "m/z array", "MS:1000040", "m/z", mz_b64),
            ("MS:1000515", "intensity array", "MS:1000131", "number of counts", in_b64),
        ):
            emit(f'            <binaryDataArray encodedLength="{len(payload)}">\n')
            emit('              <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float" value=""/>\n')
            emit(f'              <cvParam cvRef="MS" accession="{comp_acc}" name="{comp_name}" value=""/>\n')
            emit(f'              <cvParam cvRef="MS" accession="{accession}" name="{name}" value=""'
                 f' unitCvRef="MS" unitAccession="{unit_acc}" unitName="{unit_name}"/>\n')
            emit(f'              <binary>{payload}</binary>\n')
            emit('            </binaryDataArray>\n')
        emit('          </binaryDataArrayList>\n')
        emit('        </spectrum>\n')

    emit('      </spectrumList>\n')

    # M24: chromatogramList
    chroms = list(getattr(chosen_run, "chromatograms", []) or [])
    chrom_offsets: list[tuple[str, int]] = []
    if chroms:
        emit(f'      <chromatogramList count="{len(chroms)}"'
             f' defaultDataProcessingRef="dp_export">\n')
        for i, c in enumerate(chroms):
            cid = f"chrom={i + 1}"
            offset_before = total
            emit(f'{INDENT}<chromatogram index="{i}" id="{_xml_escape(cid)}"'
                 f' defaultArrayLength="{int(c.retention_times.shape[0])}">\n')
            chrom_offsets.append((cid, offset_before + len(INDENT)))

            ctype = int(c.chromatogram_type)
            if ctype == 0:  # TIC
                emit('          <cvParam cvRef="MS" accession="MS:1000235"'
                     ' name="total ion current chromatogram" value=""/>\n')
            elif ctype == 1:  # XIC
                emit('          <cvParam cvRef="MS" accession="MS:1000627"'
                     ' name="selected ion current chromatogram" value=""/>\n')
                emit(f'          <userParam name="target m/z"'
                     f' value="{_fmt_double(float(c.target_mz))}" type="xsd:double"/>\n')
            elif ctype == 2:  # SRM
                emit('          <cvParam cvRef="MS" accession="MS:1001473"'
                     ' name="selected reaction monitoring chromatogram" value=""/>\n')
                emit(f'          <userParam name="precursor m/z"'
                     f' value="{_fmt_double(float(c.precursor_mz))}" type="xsd:double"/>\n')
                emit(f'          <userParam name="product m/z"'
                     f' value="{_fmt_double(float(c.product_mz))}" type="xsd:double"/>\n')

            t_arr = np.ascontiguousarray(c.retention_times, dtype="<f8")
            i_arr = np.ascontiguousarray(c.intensities, dtype="<f8")
            t_b64 = _encode_array(t_arr, zlib_compression)
            i_b64 = _encode_array(i_arr, zlib_compression)
            comp_acc = "MS:1000574" if zlib_compression else "MS:1000576"
            comp_name = "zlib compression" if zlib_compression else "no compression"

            emit('          <binaryDataArrayList count="2">\n')
            # time array (MS:1000595) + intensity array (MS:1000515)
            for accession, name, unit_acc, unit_name, payload in (
                ("MS:1000595", "time array", "UO:0000010", "second", t_b64),
                ("MS:1000515", "intensity array", "MS:1000131", "number of counts", i_b64),
            ):
                unit_cv = "UO" if accession == "MS:1000595" else "MS"
                emit(f'            <binaryDataArray encodedLength="{len(payload)}">\n')
                emit('              <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float" value=""/>\n')
                emit(f'              <cvParam cvRef="MS" accession="{comp_acc}" name="{comp_name}" value=""/>\n')
                emit(f'              <cvParam cvRef="MS" accession="{accession}" name="{name}" value=""'
                     f' unitCvRef="{unit_cv}" unitAccession="{unit_acc}" unitName="{unit_name}"/>\n')
                emit(f'              <binary>{payload}</binary>\n')
                emit('            </binaryDataArray>\n')
            emit('          </binaryDataArrayList>\n')
            emit('        </chromatogram>\n')
        emit('      </chromatogramList>\n')

    emit('    </run>\n')
    emit('  </mzML>\n')

    index_list_offset = total
    index_count = 1 + (1 if chroms else 0)
    emit(f'  <indexList count="{index_count}">\n')
    emit('    <index name="spectrum">\n')
    for scan_id, offset in spectrum_offsets:
        emit(f'      <offset idRef="{_xml_escape(scan_id)}">{offset}</offset>\n')
    emit('    </index>\n')
    if chroms:
        emit('    <index name="chromatogram">\n')
        for cid, offset in chrom_offsets:
            emit(f'      <offset idRef="{_xml_escape(cid)}">{offset}</offset>\n')
        emit('    </index>\n')
    emit('  </indexList>\n')
    emit(f'  <indexListOffset>{index_list_offset}</indexListOffset>\n')
    emit('  <fileChecksum>0</fileChecksum>\n')
    emit('</indexedmzML>\n')

    return b"".join(parts)
