"""Waters MassLynx importer integration test — v0.9 M63.

Mirrors the Thermo delegation test style (``test_thermo_delegation.py``):

* Error-contract tests always run — missing converter / missing input
  directory / wrong explicit path.
* Real-fixture round-trip is gated on ``TTIO_MASSLYNX_FIXTURE`` +
  a resolvable ``masslynxraw`` binary.
* **Mock-converter test** always runs: a tiny shell script that
  behaves like a minimal ``masslynxraw`` (reads ``-i`` + ``-o`` flags,
  emits a stub mzML) proves the delegation + mzML parsing path
  end-to-end without any proprietary tool installed.
"""
from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

import pytest

from ttio.importers import waters_masslynx
from ttio.importers.waters_masslynx import WatersMassLynxError


MASSLYNX_BIN = shutil.which("masslynxraw") or shutil.which("MassLynxRaw.exe")


def test_missing_binary_raises_clear_error(tmp_path: Path) -> None:
    """When the binary is unresolvable the importer surfaces a
    FileNotFoundError pointing at the install docs."""
    fake_raw = tmp_path / "missing.raw"
    fake_raw.mkdir()
    with pytest.raises(FileNotFoundError):
        waters_masslynx.read(fake_raw, converter="/nonexistent/no-such-masslynx")


def test_missing_input_raises_filenotfound(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        waters_masslynx.read(tmp_path / "does-not-exist.raw")


def test_file_not_directory_raises(tmp_path: Path) -> None:
    """Waters inputs are directories — a plain file must be rejected."""
    bogus = tmp_path / "bogus.raw"
    bogus.write_text("this is not a directory")
    with pytest.raises(FileNotFoundError):
        waters_masslynx.read(bogus)


def test_mock_converter_roundtrip(tmp_path: Path) -> None:
    """Mock converter: POSIX shell script that emits a minimal mzML.

    Validates the full delegation pipeline — resolver finds the
    explicit converter, subprocess runs, stub mzML lands in the
    temp dir, the importer locates + parses it.
    """
    mzml_stub = """<?xml version="1.0" encoding="UTF-8"?>
<mzML xmlns="http://psi.hupo.org/ms/mzml" version="1.1.0">
  <cvList count="2">
    <cv id="MS" fullName="PSI MS" version="4.1.0"/>
    <cv id="UO" fullName="UO" version="2020-03-10"/>
  </cvList>
  <fileDescription><fileContent>
    <cvParam cvRef="MS" accession="MS:1000580" name="MSn spectrum"/>
  </fileContent></fileDescription>
  <softwareList count="1"><software id="mock_masslynx" version="0.0"/></softwareList>
  <instrumentConfigurationList count="1"><instrumentConfiguration id="IC1"/></instrumentConfigurationList>
  <dataProcessingList count="1"><dataProcessing id="dp"/></dataProcessingList>
  <run id="mock_waters_run" defaultInstrumentConfigurationRef="IC1">
    <spectrumList count="1" defaultDataProcessingRef="dp">
      <spectrum index="0" id="scan=1" defaultArrayLength="2">
        <cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="1"/>
        <cvParam cvRef="MS" accession="MS:1000130" name="positive scan"/>
        <scanList count="1"><scan>
          <cvParam cvRef="MS" accession="MS:1000016" name="scan start time" value="0.0" unitCvRef="UO" unitAccession="UO:0000010"/>
        </scan></scanList>
        <binaryDataArrayList count="2">
          <binaryDataArray encodedLength="16">
            <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
            <cvParam cvRef="MS" accession="MS:1000576" name="no compression"/>
            <cvParam cvRef="MS" accession="MS:1000514" name="m/z array"/>
            <binary>AAAAAAAAJEAAAAAAAAA0QA==</binary>
          </binaryDataArray>
          <binaryDataArray encodedLength="16">
            <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
            <cvParam cvRef="MS" accession="MS:1000576" name="no compression"/>
            <cvParam cvRef="MS" accession="MS:1000515" name="intensity array"/>
            <binary>AAAAAAAA8D8AAAAAAAAAQA==</binary>
          </binaryDataArray>
        </binaryDataArrayList>
      </spectrum>
    </spectrumList>
  </run>
</mzML>
"""
    # Embed the stub inside the mock converter so the script is
    # self-contained — the argv parsing pulls -o and writes
    # <basename>.mzML inside that directory.
    mock = tmp_path / "mock_masslynxraw"
    mock.write_text(f"""#!/bin/sh
set -eu
input=""
output=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i) input=$2; shift 2;;
        -o) output=$2; shift 2;;
        *) shift;;
    esac
done
if [ -z "$input" ] || [ -z "$output" ]; then
    echo "usage: $0 -i <input.raw> -o <output-dir>" >&2
    exit 2
fi
stem=$(basename "$input" .raw)
cat > "$output/$stem.mzML" <<'TTIO_MOCK_MZML'
{mzml_stub}TTIO_MOCK_MZML
""")
    mock.chmod(mock.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    src = tmp_path / "Sample_01.raw"
    src.mkdir()  # Waters inputs are directories

    result = waters_masslynx.read(src, converter=str(mock))
    assert result.spectrum_count == 1
    assert result.ms_spectra, "mock mzML must parse into at least one spectrum"


def test_env_var_override(tmp_path: Path, monkeypatch) -> None:
    """MASSLYNXRAW env var resolves over PATH lookup."""
    nonexistent = tmp_path / "env-binary-does-not-exist"
    monkeypatch.setenv("MASSLYNXRAW", str(nonexistent))
    src = tmp_path / "Sample.raw"
    src.mkdir()
    with pytest.raises(FileNotFoundError, match="missing binary"):
        waters_masslynx.read(src)


@pytest.mark.requires_network  # marker also used for vendor-binary gating
def test_real_masslynx_roundtrip(tmp_path: Path) -> None:
    """End-to-end: real .raw → .tio via a real masslynxraw binary.

    Skipped unless both ``TTIO_MASSLYNX_FIXTURE`` is set to a
    Waters ``.raw`` directory AND a ``masslynxraw`` binary is
    available on PATH.
    """
    fixture_env = os.environ.get("TTIO_MASSLYNX_FIXTURE")
    if not fixture_env:
        pytest.skip("TTIO_MASSLYNX_FIXTURE not set; no real Waters .raw available")
    if not MASSLYNX_BIN:
        pytest.skip("masslynxraw / MassLynxRaw.exe not on PATH")
    raw = Path(fixture_env)
    if not raw.is_dir():
        pytest.skip(f"TTIO_MASSLYNX_FIXTURE={raw} not a directory")

    result = waters_masslynx.read(raw)
    assert result.spectrum_count > 0
