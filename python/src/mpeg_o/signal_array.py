"""``SignalArray`` — numpy buffer + axis + encoding metadata."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .axis_descriptor import AxisDescriptor
from .encoding_spec import EncodingSpec


@dataclass(frozen=True, slots=True)
class SignalArray:
    """A named 1-D numeric signal buffer paired with axis and encoding
    metadata. Mirrors the ObjC ``MPGOSignalArray`` value class.

    ``data`` is a ``numpy.ndarray``; callers that hold a ``SignalArray``
    should treat it as immutable.
    """

    data: np.ndarray
    axis: AxisDescriptor
    encoding: EncodingSpec = field(default_factory=EncodingSpec)

    @classmethod
    def from_numpy(
        cls,
        array: np.ndarray,
        axis: AxisDescriptor,
        encoding: EncodingSpec | None = None,
    ) -> "SignalArray":
        if array.ndim != 1:
            raise ValueError(f"SignalArray expects a 1-D ndarray, got shape={array.shape}")
        return cls(
            data=np.ascontiguousarray(array),
            axis=axis,
            encoding=encoding or EncodingSpec(),
        )

    def __len__(self) -> int:
        return int(self.data.shape[0])
