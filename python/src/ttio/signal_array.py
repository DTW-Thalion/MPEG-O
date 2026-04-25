"""``SignalArray`` — numpy buffer + axis + encoding metadata."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .axis_descriptor import AxisDescriptor
from .cv_param import CVParam
from .encoding_spec import EncodingSpec


@dataclass(slots=True)
class SignalArray:
    """A named 1-D numeric signal buffer paired with axis and encoding
    metadata, with CV annotation support.

    Parameters
    ----------
    data : numpy.ndarray
        1-D numeric array holding the raw signal values. Callers should
        treat the array contents as immutable after construction.
    axis : AxisDescriptor or None, optional
        Descriptor of the physical dimension represented by ``data``
        (e.g. m/z, ppm). ``None`` when the axis is not yet known or not
        applicable.
    encoding : EncodingSpec, optional
        Wire-format encoding for HDF5 serialisation.  Defaults to
        FLOAT64 / ZLIB / little-endian.
    cv_params : list of CVParam, optional
        Initial CV annotations.  Usually empty; grow at runtime via
        :meth:`add_cv_param`.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOSignalArray`` ·
    Java: ``com.dtwthalion.ttio.SignalArray``
    """

    data: np.ndarray
    axis: AxisDescriptor | None = None
    encoding: EncodingSpec = field(default_factory=EncodingSpec)
    cv_params: list[CVParam] = field(default_factory=list)

    # ------------------------------------------------------------------
    # CVAnnotatable
    # ------------------------------------------------------------------

    def add_cv_param(self, param: CVParam) -> None:
        """Attach *param* to this array in insertion order."""
        self.cv_params.append(param)

    def remove_cv_param(self, param: CVParam) -> None:
        """Detach *param*.  No-op if not present."""
        try:
            self.cv_params.remove(param)
        except ValueError:
            pass

    def all_cv_params(self) -> list[CVParam]:
        """Return all attached CV params in insertion order."""
        return list(self.cv_params)

    def cv_params_for_accession(self, accession: str) -> list[CVParam]:
        """Return params whose ``accession`` equals *accession*."""
        return [p for p in self.cv_params if p.accession == accession]

    def cv_params_for_ontology_ref(self, ontology_ref: str) -> list[CVParam]:
        """Return params whose ``ontology_ref`` equals *ontology_ref*."""
        return [p for p in self.cv_params if p.ontology_ref == ontology_ref]

    def has_cv_param_with_accession(self, accession: str) -> bool:
        """Return ``True`` if at least one attached param matches *accession*."""
        return any(p.accession == accession for p in self.cv_params)

    # ------------------------------------------------------------------
    # Constructors
    # ------------------------------------------------------------------

    @classmethod
    def from_numpy(
        cls,
        array: np.ndarray,
        axis: AxisDescriptor | None = None,
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
