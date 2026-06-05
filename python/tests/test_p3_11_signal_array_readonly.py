"""P3.11: SignalArray.data is a read-only (writeable=False) zero-copy view."""
import numpy as np
import pytest
from ttio.signal_array import SignalArray


def test_from_numpy_data_is_read_only():
    sa = SignalArray.from_numpy(np.arange(8, dtype="<f8"))
    assert sa.data.flags.writeable is False
    with pytest.raises(ValueError):
        sa.data[0] = 99.0


def test_direct_construction_data_is_read_only():
    sa = SignalArray(data=np.arange(4, dtype="<f8"))
    assert sa.data.flags.writeable is False
    with pytest.raises(ValueError):
        sa.data[1] = 1.0


def test_freeze_does_not_freeze_caller_array():
    src = np.arange(5, dtype="<f8")
    SignalArray(data=src)
    src[0] = 42.0  # constructing a SignalArray must NOT freeze the caller's array
    assert src[0] == 42.0


def test_values_preserved():
    src = np.array([1.5, 2.5, 3.5], dtype="<f8")
    sa = SignalArray.from_numpy(src)
    assert np.array_equal(sa.data, src)
