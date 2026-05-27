"""ProgressSink coverage for :func:`ttio.importers.mzml.read`.

Synthesises a small mzML with 250 spectra and asserts:
- mid-parse callbacks fire every PROGRESS_INTERVAL_SPECTRA (100)
- the final callback reports ``(n, n)``
"""
from __future__ import annotations

import base64
import struct
from pathlib import Path

from ttio.importers.mzml import PROGRESS_INTERVAL_SPECTRA, read


def _spectrum_block(idx: int) -> str:
    # Two-point spectrum: mz=[100.0, 200.0], intensity=[1.0, 2.0]
    mz = base64.b64encode(struct.pack("<2d", 100.0 + idx, 200.0 + idx)).decode()
    it = base64.b64encode(struct.pack("<2d", 1.0, 2.0)).decode()
    return f"""    <spectrum id="spec_{idx}" index="{idx}" defaultArrayLength="2">
      <cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="1"/>
      <binaryDataArrayList count="2">
        <binaryDataArray encodedLength="32">
          <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
          <cvParam cvRef="MS" accession="MS:1000576" name="no compression"/>
          <cvParam cvRef="MS" accession="MS:1000514" name="m/z array"/>
          <binary>{mz}</binary>
        </binaryDataArray>
        <binaryDataArray encodedLength="32">
          <cvParam cvRef="MS" accession="MS:1000523" name="64-bit float"/>
          <cvParam cvRef="MS" accession="MS:1000576" name="no compression"/>
          <cvParam cvRef="MS" accession="MS:1000515" name="intensity array"/>
          <binary>{it}</binary>
        </binaryDataArray>
      </binaryDataArrayList>
    </spectrum>
"""


def _build_mzml(path: Path, n: int) -> None:
    body = "".join(_spectrum_block(i) for i in range(n))
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<mzML xmlns="http://psi.hupo.org/ms/mzml" version="1.1.0">
  <run id="run1">
    <spectrumList count="{n}">
{body}    </spectrumList>
  </run>
</mzML>
"""
    path.write_text(xml)


def test_mzml_progress_fires(tmp_path: Path) -> None:
    n = 250
    p = tmp_path / "synth.mzML"
    _build_mzml(p, n)

    events: list[tuple[int, int]] = []
    result = read(p, progress=lambda d, t: events.append((d, t)))
    assert len(result.ms_spectra) == n
    assert len(events) >= n // PROGRESS_INTERVAL_SPECTRA, events
    assert events[-1] == (n, n)
    assert any(t == -1 for _, t in events[:-1])


def test_mzml_progress_none_safe(tmp_path: Path) -> None:
    n = 50
    p = tmp_path / "tiny.mzML"
    _build_mzml(p, n)
    result = read(p)
    assert len(result.ms_spectra) == n
