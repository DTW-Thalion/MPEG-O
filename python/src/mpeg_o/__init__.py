"""MPEG-O — Python reader/writer for the multi-omics data standard.

Public API is re-exported here. See :class:`mpeg_o.SpectralDataset` for the
main entry point.
"""
from __future__ import annotations

__version__ = "0.4.0"
FORMAT_VERSION = "1.1"

from .enums import (
    AcquisitionMode,
    Compression,
    Polarity,
    Precision,
    SamplingMode,
)
from .value_range import ValueRange
from .cv_param import CVParam
from .axis_descriptor import AxisDescriptor
from .encoding_spec import EncodingSpec
from .instrument_config import InstrumentConfig
from .signal_array import SignalArray
from .spectrum import Spectrum
from .mass_spectrum import MassSpectrum
from .nmr_spectrum import NMRSpectrum
from .nmr_2d import NMR2DSpectrum
from .fid import FreeInductionDecay
from .chromatogram import Chromatogram
from .identification import Identification
from .quantification import Quantification
from .provenance import ProvenanceRecord
from .transition_list import Transition, TransitionList
from .feature_flags import FeatureFlags
from .acquisition_run import AcquisitionRun, SpectrumIndex
from .spectral_dataset import SpectralDataset, WrittenRun
from .ms_image import MSImage

__all__ = [
    "__version__",
    "FORMAT_VERSION",
    "AcquisitionMode",
    "Compression",
    "Polarity",
    "Precision",
    "SamplingMode",
    "ValueRange",
    "CVParam",
    "AxisDescriptor",
    "EncodingSpec",
    "InstrumentConfig",
    "SignalArray",
    "Spectrum",
    "MassSpectrum",
    "NMRSpectrum",
    "NMR2DSpectrum",
    "FreeInductionDecay",
    "Chromatogram",
    "Identification",
    "Quantification",
    "ProvenanceRecord",
    "Transition",
    "TransitionList",
    "FeatureFlags",
    "AcquisitionRun",
    "SpectrumIndex",
    "SpectralDataset",
    "WrittenRun",
    "MSImage",
]
