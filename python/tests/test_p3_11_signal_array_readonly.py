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


def test_freeze_does_not_freeze_caller_noncontiguous():
    # Non-contiguous slice: np.ascontiguousarray returns a FRESH array that
    # SignalArray owns outright (exercises the `arr is not self.data` branch).
    src = np.arange(10, dtype="<f8")[::2]
    assert not src.flags["C_CONTIGUOUS"]
    sa = SignalArray(data=src)
    assert sa.data.flags.writeable is False
    src[0] = 99.0  # must NOT raise — we froze our own copy, not src's buffer
    assert src[0] == 99.0


def test_zero_copy_contiguous_shares_buffer():
    # Contiguous input must be stored as a zero-copy view (a `.copy()` would
    # silently pass the other tests but break the audit's zero-copy intent).
    src = np.arange(5, dtype="<f8")
    sa = SignalArray(data=src)
    assert np.shares_memory(sa.data, src)
