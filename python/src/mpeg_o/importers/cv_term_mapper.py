"""PSI-MS and nmrCV accession mappings.

Exact Python port of the ObjC ``MPGOCVTermMapper`` lookup tables. The set
deliberately mirrors the ObjC side so that writing an ``mzML`` from Python
(M19) produces the same accession choices as the ObjC exporter.
"""
from __future__ import annotations

from ..enums import Compression, Precision

# ----- PSI-MS: precision -----
PRECISION_ACCESSIONS: dict[str, Precision] = {
    "MS:1000521": Precision.FLOAT32,
    "MS:1000523": Precision.FLOAT64,
    "MS:1000519": Precision.INT32,
    "MS:1000522": Precision.INT64,
}

# ----- PSI-MS: compression -----
COMPRESSION_ACCESSIONS: dict[str, Compression] = {
    "MS:1000574": Compression.ZLIB,
    "MS:1000576": Compression.NONE,
}

# ----- PSI-MS: binary-data-array channel names -----
SIGNAL_ARRAY_ACCESSIONS: dict[str, str] = {
    "MS:1000514": "mz",
    "MS:1000515": "intensity",
    "MS:1000516": "charge",
    "MS:1000517": "signal_to_noise",
    "MS:1000595": "time",
    "MS:1000617": "wavelength",
    "MS:1000820": "ion_mobility",
}

# ----- Scalar cvParams used during parsing -----
MS_LEVEL = "MS:1000511"
POSITIVE_POLARITY = "MS:1000130"
NEGATIVE_POLARITY = "MS:1000129"
SCAN_WINDOW_LOWER = "MS:1000501"
SCAN_WINDOW_UPPER = "MS:1000500"
SCAN_START_TIME = "MS:1000016"
SELECTED_ION_MZ = "MS:1000744"
CHARGE_STATE = "MS:1000041"
TOTAL_ION_CHROMATOGRAM = "MS:1000235"
SELECTED_REACTION_MONITORING = "MS:1001473"

MINUTES_UNIT = "UO:0000031"  # scan start time minute unit

# ----- nmrCV -----
NMR_SPECTROMETER_FREQUENCY = "NMR:1000001"
NMR_NUCLEUS = "NMR:1000002"
NMR_NUMBER_OF_SCANS = "NMR:1000003"
NMR_DWELL_TIME = "NMR:1000004"
NMR_SWEEP_WIDTH = "NMR:1400014"


def precision_for(accession: str) -> Precision:
    return PRECISION_ACCESSIONS.get(accession, Precision.FLOAT64)


def compression_for(accession: str) -> Compression:
    return COMPRESSION_ACCESSIONS.get(accession, Compression.NONE)


def signal_array_name(accession: str) -> str | None:
    return SIGNAL_ARRAY_ACCESSIONS.get(accession)
