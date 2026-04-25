"""``Spectrum`` — generic multi-channel spectrum base class."""
from __future__ import annotations

from dataclasses import dataclass, field

from .axis_descriptor import AxisDescriptor
from .signal_array import SignalArray


@dataclass(slots=True)
class Spectrum:
    """Generic multi-channel 1-D spectrum with per-scan metadata.

    Holds an ordered mapping of named :class:`SignalArray` objects and
    the coordinate axes that index them, plus per-scan metadata
    (index position, scan time, optional precursor info for tandem
    MS).

    Concrete subclasses (:class:`MassSpectrum`, :class:`NMRSpectrum`)
    add their own typed metadata.

    Parameters
    ----------
    signal_arrays : dict[str, SignalArray]
        Named signal arrays keyed by channel name
        (``"mz"``, ``"intensity"``, ``"chemical_shift"``, ...).
    axes : list[AxisDescriptor]
        Coordinate axes describing the signal arrays.
    index_position : int, default 0
        Position in the parent :class:`~ttio.acquisition_run.AcquisitionRun` (0-based).
    scan_time_seconds : float, default 0.0
        Scan time in seconds from run start.
    precursor_mz : float, default 0.0
        Precursor m/z for tandem MS. ``0`` if not tandem.
    precursor_charge : int, default 0
        Precursor charge state. ``0`` if unknown.

    Notes
    -----
    API status: Stable.

    HDF5 representation: each spectrum is an HDF5 group whose
    immediate children are ``SignalArray`` sub-groups plus scalar
    attributes for the metadata fields.

    Cross-language equivalents
    --------------------------
    Objective-C: ``TTIOSpectrum`` · Java:
    ``global.thalion.ttio.Spectrum``.
    """

    signal_arrays: dict[str, SignalArray] = field(default_factory=dict)
    axes: list[AxisDescriptor] = field(default_factory=list)
    index_position: int = 0
    scan_time_seconds: float = 0.0
    precursor_mz: float = 0.0
    precursor_charge: int = 0

    def signal_array(self, name: str) -> SignalArray:
        """Return the named ``SignalArray``. Raises ``KeyError`` if absent."""
        try:
            return self.signal_arrays[name]
        except KeyError as exc:
            raise KeyError(
                f"no such signal array {name!r}; have {sorted(self.signal_arrays)}"
            ) from exc

    def has_signal_array(self, name: str) -> bool:
        """Return ``True`` iff ``name`` is in ``signal_arrays``."""
        return name in self.signal_arrays

    def signal_array_names(self) -> list[str]:
        """Return the channel names in insertion order."""
        return list(self.signal_arrays.keys())

    def __len__(self) -> int:
        if not self.signal_arrays:
            return 0
        return min(len(c) for c in self.signal_arrays.values())
