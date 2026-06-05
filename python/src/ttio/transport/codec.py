"""Transport-stream codec: file ↔ transport bytes.

The writer walks a :class:`SpectralDataset` and emits the full
packet sequence specified in ``docs/transport-spec.md``. The reader
ingests a packet stream and materializes it back into a ``.tio``
file via :meth:`SpectralDataset.write_minimal`.

Scope:

- Signal data is emitted as ``float64``. On-wire compression via
  ``Compression.ZLIB`` is opt-in (``TransportWriter(use_compression=True)``)
  and handled automatically by :class:`TransportReader` regardless.
- ProtectionMetadata / Annotation / Provenance / Chromatogram
  packet slots are defined on the wire but writer emission and
  reader materialization of encrypted AUs remain v1.0 integration
  items (the wire is stable as of M71).
- Selective-access filtering lives in M68 (server) and M71 (filter
  enforcement).

This module is a thin re-export facade (OO-assessment P3.10): the
:class:`TransportWriter` lives in :mod:`ttio.transport._writer`, the
:class:`TransportReader` in :mod:`ttio.transport._reader`, and the
shared helpers in :mod:`ttio.transport._common`. Every historical
``from ttio.transport.codec import ...`` import path is preserved here.
"""
from __future__ import annotations

from pathlib import Path
from typing import BinaryIO

from ..spectral_dataset import SpectralDataset

# Re-exported wire constants / mappings (public-by-import surface).
from .packets import (  # noqa: F401  (re-export)
    TRANSPORT_V0_11_FEATURE,
    unpack_string,
)
from ._common import (  # noqa: F401  (re-export)
    _LOG,
    _CHECKSUM_STRUCT,
    _POLARITY_TO_WIRE,
    _WIRE_TO_POLARITY,
    _SPECTRUM_CLASS_TO_WIRE,
    _WIRE_TO_SPECTRUM_CLASS,
    _RANS_ORDER0_WIRE,
    _RANS_ORDER1_WIRE,
    _BASE_PACK_WIRE,
    _read_mate_chrom_names_table,
    _apply_wire_codec,
    _decode_wire_codec,
    _iter_genomic_run_access_units,
)
from ._writer import (  # noqa: F401  (re-export)
    TransportWriter,
    _scan_pattern_to_byte,
    _provenance_params_json,
    _provenance_csv_join,
    _provenance_csv_split,
    _provenance_params_parse,
    _instrument_config_json,
    _genomic_run_metadata_json,
    _spectrum_to_access_unit,
)
from ._reader import (  # noqa: F401  (re-export)
    TransportReader,
    _scan_pattern_from_byte,
    _new_genomic_accumulator,
    _ingest_genomic_access_unit_bytes,
    _decode_stream_header,
    _decode_dataset_header,
    _ingest_access_unit_bytes,
    _ingest_access_unit,
)


# ---------------------------------------------------------- convenience


def file_to_transport(
    ttio_path: str | Path,
    output: BinaryIO | str | Path,
    *,
    use_checksum: bool = False,
    use_compression: bool = False,
    use_bulk_mode: bool = False,
) -> None:
    """Convert a ``.tio`` file to a transport stream.

    ``use_bulk_mode=True`` enables Phase 2c-T verbatim v2-blob
    carriage for genomic runs. See ``docs/transport-spec.md`` §6.4.
    """
    with SpectralDataset.open(ttio_path) as ds, \
            TransportWriter(output,
                              use_checksum=use_checksum,
                              use_compression=use_compression,
                              use_bulk_mode=use_bulk_mode) as tw:
        tw.write_dataset(ds)


def transport_to_file(
    source: BinaryIO | str | Path,
    ttio_path: str | Path,
    *,
    provider: str = "hdf5",
) -> SpectralDataset:
    """Convert a transport stream to a ``.tio`` file."""
    with TransportReader(source) as tr:
        return tr.read_to_dataset(output_path=ttio_path, provider=provider)


__all__ = [
    "TransportReader",
    "TransportWriter",
    "file_to_transport",
    "transport_to_file",
    "TRANSPORT_V0_11_FEATURE",
    "unpack_string",
    "_SPECTRUM_CLASS_TO_WIRE",
    "_POLARITY_TO_WIRE",
    "_apply_wire_codec",
    "_decode_wire_codec",
    "_iter_genomic_run_access_units",
    "_spectrum_to_access_unit",
    "_instrument_config_json",
    "_genomic_run_metadata_json",
    "_ingest_access_unit",
    "_decode_stream_header",
    "_decode_dataset_header",
]
