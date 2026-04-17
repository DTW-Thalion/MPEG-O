"""``AxisDescriptor`` — names + units + sampling metadata for one signal axis."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import SamplingMode
from .value_range import ValueRange


@dataclass(frozen=True, slots=True)
class AxisDescriptor:
    """Describes a single axis of a :class:`~mpeg_o.signal_array.SignalArray`.

    Immutable value class. ``name`` is a short token (``"mz"``,
    ``"chemical_shift"``, ...) and ``unit`` is a free-form label
    (``"m/z"``, ``"ppm"``, ``"s"``, ...).

    Parameters
    ----------
    name : str
        Semantic name of the axis.
    unit : str
        Unit of the axis values.
    value_range : ValueRange or None, default None
        Numeric bounds of the axis. ``None`` when unknown.
    sampling_mode : SamplingMode, default SamplingMode.UNIFORM
        Whether samples are regularly spaced.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOAxisDescriptor`` · Java:
    ``com.dtwthalion.mpgo.AxisDescriptor``.
    """

    name: str
    unit: str
    value_range: ValueRange | None = None
    sampling_mode: SamplingMode = SamplingMode.UNIFORM
