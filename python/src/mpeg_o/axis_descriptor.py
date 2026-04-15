"""``AxisDescriptor`` — names + units + sampling metadata for one signal axis."""
from __future__ import annotations

from dataclasses import dataclass

from .enums import SamplingMode


@dataclass(frozen=True, slots=True)
class AxisDescriptor:
    """Describes a single axis of a signal array.

    Mirrors the ObjC ``MPGOAxisDescriptor`` value class. ``name`` is a short
    token like ``"mz"`` or ``"chemical_shift"`` and ``unit`` is a free-form
    label (``"m/z"``, ``"ppm"``, ``"s"``, ...).
    """

    name: str
    unit: str
    sampling_mode: SamplingMode = SamplingMode.UNIFORM
