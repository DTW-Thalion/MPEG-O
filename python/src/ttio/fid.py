"""``FreeInductionDecay`` — NMR time-domain SignalArray subclass."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .signal_array import SignalArray


@dataclass(slots=True)
class FreeInductionDecay(SignalArray):
    """NMR free-induction-decay signal.

    Subclass of :class:`SignalArray` holding a complex-valued buffer
    plus FID-specific acquisition metadata: dwell time, scan count,
    receiver gain.

    Parameters
    ----------
    dwell_time_seconds : float, default 0.0
        Sample spacing in seconds.
    scan_count : int, default 1
        Number of scans averaged.
    receiver_gain : float, default 1.0
        Receiver gain used during acquisition.
    *plus all base :class:`SignalArray` parameters (data, axis,
    encoding, cv_params)*

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOFreeInductionDecay`` · Java:
    ``global.thalion.ttio.FreeInductionDecay``.
    """

    dwell_time_seconds: float = 0.0
    scan_count: int = 1
    receiver_gain: float = 1.0
