"""P3.9 (PR-2/5): the raw-h5py sign/verify entrypoints must route through
the StorageProvider protocol so the same attribute is readable both ways.

These tests pin the cross-path equivalence between the h5py-native
``sign_dataset``/``verify_dataset`` and the provider-based
``sign_storage_dataset``/``verify_storage_dataset``. They must hold both
before and after the P3.9 refactor (no wire change).
"""
from __future__ import annotations


def test_sign_dataset_attr_is_protocol_readable(tmp_path):
    import h5py
    import numpy as np
    from ttio import signatures
    from ttio.providers.hdf5 import _Dataset as Hdf5Dataset

    p = tmp_path / "s.h5"
    with h5py.File(p, "w") as f:
        dset = f.create_dataset("d", data=np.arange(16, dtype="<i4"))
        key = b"k" * 32
        sig = signatures.sign_dataset(dset, key)
        assert sig.startswith("v2:")
        assert signatures.verify_dataset(dset, key) is True
        # the attribute written via the raw-h5py entrypoint must be
        # readable through the protocol wrapper
        assert signatures.verify_storage_dataset(Hdf5Dataset(dset), key) is True


def test_storage_signed_attr_is_h5py_readable(tmp_path):
    """Reverse direction: an attribute written via the storage protocol
    must verify through the raw-h5py ``verify_dataset`` entrypoint, and
    both directions produce v2:-prefixed signatures."""
    import h5py
    import numpy as np
    from ttio import signatures
    from ttio.providers.hdf5 import _Dataset as Hdf5Dataset

    p = tmp_path / "s2.h5"
    with h5py.File(p, "w") as f:
        dset = f.create_dataset("d", data=np.arange(16, dtype="<i4"))
        key = b"k" * 32
        sig = signatures.sign_storage_dataset(Hdf5Dataset(dset), key)
        assert sig.startswith("v2:")
        # storage-written attr must be readable by the h5py entrypoint
        assert signatures.verify_dataset(dset, key) is True
        # and vice versa via the wrapper
        assert signatures.verify_storage_dataset(Hdf5Dataset(dset), key) is True
        # both paths must produce the identical prefixed signature
        sig2 = signatures.sign_dataset(dset, key)
        assert sig2 == sig
