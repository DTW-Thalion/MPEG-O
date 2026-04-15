# MPEG-O — Python Implementation (planned)

Python implementation — planned. Will follow the Objective-C reference implementation architecture.

See [`../ARCHITECTURE.md`](../ARCHITECTURE.md) and [`../WORKPLAN.md`](../WORKPLAN.md) for the canonical class hierarchy and milestone plan. The Python stream will use `h5py` for HDF5 access and mirror the `MPGO` class names without the prefix (e.g. `mpeg_o.SignalArray`, `mpeg_o.MassSpectrum`).
