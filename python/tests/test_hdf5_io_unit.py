"""Unit tests for :mod:`ttio._hdf5_io` — error branches and codec
write helpers not exercised by the existing :mod:`test_hdf5_io`
file.

Targets the missed lines around:

- ``read_string_attr`` numpy/scalar branches
- ``read_string_attr_from_scalar``
- ``write_signal_channel`` lz4 / none / unknown-codec branches
- ``write_compound_dataset`` non-HDF5 (StorageGroup) field-kind
  dispatch (UINT32 / INT64 / FLOAT64 / VL_STRING / unknown→FLOAT64)
- ``read_compound_dataset`` — np.generic and bytes branches via the
  fast-path fallthrough
- ``_zero_value_for`` for object / string kinds
- ``read_feature_flags`` legacy + JSON-decode-error branches
- ``is_legacy_v1`` for non-HDF5 StorageGroup
- ``write_channel_segments`` / ``read_channel_segments`` /
  ``write_au_header_segments`` / ``read_au_header_segments``
- ``_compression_for`` error branch
- ``_write_byte_channel_with_codec`` (rANS / unknown override)
- ``_write_int_channel_with_codec`` (None for each typed channel,
  RANS for positions, unknown channel name, unsupported override)
- ``_write_uint64_channel``
"""
from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import h5py
import numpy as np
import pytest

from ttio import _hdf5_io as io


# ----------------------------------------- _zero_value_for branches ---


class TestZeroValueFor:
    def test_float(self) -> None:
        assert io._zero_value_for(np.dtype("<f8")) == 0.0

    def test_int(self) -> None:
        assert io._zero_value_for(np.dtype("<i4")) == 0

    def test_uint(self) -> None:
        assert io._zero_value_for(np.dtype("<u4")) == 0

    def test_object_dtype_returns_empty_string(self) -> None:
        # Object dtype (kind == "O") → empty string. Used for VL string
        # compound members.
        assert io._zero_value_for(np.dtype("O")) == ""

    def test_bytes_dtype_returns_empty_string(self) -> None:
        assert io._zero_value_for(np.dtype("S5")) == ""

    def test_unicode_dtype_returns_empty_string(self) -> None:
        assert io._zero_value_for(np.dtype("U5")) == ""

    def test_unknown_dtype_returns_none(self) -> None:
        # Boolean dtype kind == "b" — not in any of the known buckets.
        assert io._zero_value_for(np.dtype("?")) is None


# ----------------------------------------- read_string_attr branches ---


class TestReadStringAttrBranches:
    def test_returns_default_when_attr_absent(self, tmp_path: Path) -> None:
        p = tmp_path / "a.h5"
        with h5py.File(p, "w") as f:
            assert io.read_string_attr(f, "absent", default="dflt") == "dflt"
            assert io.read_string_attr(f, "absent") is None

    def test_str_attr(self, tmp_path: Path) -> None:
        p = tmp_path / "a.h5"
        with h5py.File(p, "w") as f:
            f.attrs["title"] = "hello"
        with h5py.File(p, "r") as f:
            assert io.read_string_attr(f, "title") == "hello"

    def test_bytes_attr(self, tmp_path: Path) -> None:
        p = tmp_path / "a.h5"
        with h5py.File(p, "w") as f:
            io.write_fixed_string_attr(f, "x", "world")
        with h5py.File(p, "r") as f:
            assert io.read_string_attr(f, "x") == "world"


class TestReadStringAttrFromScalar:
    def test_from_bytes(self) -> None:
        assert io.read_string_attr_from_scalar(b"hello") == "hello"

    def test_from_str(self) -> None:
        # Non-bytes path falls through to ``str(value)``.
        assert io.read_string_attr_from_scalar("plain") == "plain"

    def test_from_int_coerces_to_str(self) -> None:
        # ``str(value)`` is the catch-all; ints land here.
        assert io.read_string_attr_from_scalar(42) == "42"


# ------------------------------------------ write_signal_channel codecs ---


class TestWriteSignalChannelCodecs:
    def test_compression_none(self, tmp_path: Path) -> None:
        p = tmp_path / "n.h5"
        data = np.arange(100, dtype=np.float64)
        with h5py.File(p, "w") as f:
            g = f.create_group("g")
            ds = io.write_signal_channel(g, "v", data, compression="none")
            # Chunked but uncompressed — no HDF5 filter installed.
            assert ds.compression is None
            assert ds.chunks is not None

    def test_gzip_gets_byte_shuffle(self, tmp_path: Path) -> None:
        p = tmp_path / "s.h5"
        data = np.arange(1000, dtype=np.float64)
        with h5py.File(p, "w") as f:
            g = f.create_group("g")
            ds = io.write_signal_channel(g, "v", data)
            assert ds.compression == "gzip"
            assert ds.shuffle is True
        with h5py.File(p, "r") as f:
            assert np.array_equal(f["g/v"][()], data)

    def test_uint8_skips_shuffle(self, tmp_path: Path) -> None:
        # Single-byte elements have nothing to shuffle.
        p = tmp_path / "u8.h5"
        data = np.arange(256, dtype=np.uint8)
        with h5py.File(p, "w") as f:
            g = f.create_group("g")
            ds = io.write_signal_channel(g, "v", data)
            assert ds.compression == "gzip"
            assert ds.shuffle is False

    def test_unknown_codec_raises(self, tmp_path: Path) -> None:
        p = tmp_path / "u.h5"
        data = np.arange(10, dtype=np.float64)
        with h5py.File(p, "w") as f:
            g = f.create_group("g")
            with pytest.raises(ValueError, match="unknown compression codec"):
                io.write_signal_channel(g, "v", data, compression="zstd")

    def test_lz4_compression_when_plugin_available(self, tmp_path: Path) -> None:
        # Skip cleanly if hdf5plugin isn't importable in the test env.
        pytest.importorskip("hdf5plugin")
        p = tmp_path / "l.h5"
        data = np.arange(1000, dtype=np.float64)
        with h5py.File(p, "w") as f:
            g = f.create_group("g")
            ds = io.write_signal_channel(g, "v", data, compression="lz4")
            assert ds.chunks is not None
        with h5py.File(p, "r") as f:
            recovered = f["g/v"][()]
            np.testing.assert_array_equal(recovered, data)


# ------------------------------------------ feature flags branches ---


class TestFeatureFlagsBranches:
    def test_no_attrs_returns_default_version(self, tmp_path: Path) -> None:
        p = tmp_path / "empty.h5"
        with h5py.File(p, "w") as f:
            pass
        with h5py.File(p, "r") as f:
            version, features = io.read_feature_flags(f)
            assert version == "1.0.0"
            assert features == []

    def test_features_with_no_version_attr(self, tmp_path: Path) -> None:
        p = tmp_path / "fnov.h5"
        with h5py.File(p, "w") as f:
            io.write_fixed_string_attr(
                f, io.FEATURES_ATTR, '["base_v1"]'
            )
        with h5py.File(p, "r") as f:
            version, features = io.read_feature_flags(f)
            # Falls back to default when version absent.
            assert version == "1.0.0"
            assert features == ["base_v1"]

    def test_invalid_json_features_falls_back_to_empty(
        self, tmp_path: Path
    ) -> None:
        p = tmp_path / "badj.h5"
        with h5py.File(p, "w") as f:
            io.write_fixed_string_attr(f, io.VERSION_ATTR, "1.1")
            io.write_fixed_string_attr(f, io.FEATURES_ATTR, "not-json")
        with h5py.File(p, "r") as f:
            version, features = io.read_feature_flags(f)
            assert version == "1.1"
            assert features == []

    def test_non_list_json_features_falls_back_to_empty(
        self, tmp_path: Path
    ) -> None:
        p = tmp_path / "obj.h5"
        with h5py.File(p, "w") as f:
            io.write_fixed_string_attr(f, io.VERSION_ATTR, "1.1")
            # A JSON object, not a list — branch returns empty.
            io.write_fixed_string_attr(f, io.FEATURES_ATTR, '{"a": 1}')
        with h5py.File(p, "r") as f:
            version, features = io.read_feature_flags(f)
            assert version == "1.1"
            assert features == []


# -------------------------------------- StorageGroup (Memory) paths ---


class TestStorageGroupPaths:
    """Exercise the non-HDF5 StorageGroup branches in the helpers
    that route via _unwrap_to_h5py(). Uses the in-memory provider."""

    def _make_memory_root(self):
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://hdf5io_test_{id(self)}", mode="w"
        )
        return provider, provider.root_group()

    def test_write_and_read_string_attr_via_memory(self) -> None:
        provider, root = self._make_memory_root()
        try:
            io.write_fixed_string_attr(root, "title", "memstudy")
            assert io.read_string_attr(root, "title") == "memstudy"
            assert io.read_string_attr(root, "missing", "D") == "D"
            assert io.read_string_attr(root, "missing") is None
        finally:
            provider.close()

    def test_write_and_read_int_attr_via_memory(self) -> None:
        provider, root = self._make_memory_root()
        try:
            io.write_int_attr(root, "count", 99)
            assert io.read_int_attr(root, "count") == 99
            assert io.read_int_attr(root, "missing") is None
            assert io.read_int_attr(root, "missing", default=7) == 7
        finally:
            provider.close()

    def test_is_legacy_v1_on_memory_provider(self) -> None:
        provider, root = self._make_memory_root()
        try:
            # Initially no features attr → legacy.
            assert io.is_legacy_v1(root) is True
            # Add features → no longer legacy.
            io.write_feature_flags(root, "1.1", ["base_v1"])
            assert io.is_legacy_v1(root) is False
            version, feats = io.read_feature_flags(root)
            assert version == "1.1"
            assert feats == ["base_v1"]
        finally:
            provider.close()

    def test_write_signal_channel_on_memory_provider(self) -> None:
        provider, root = self._make_memory_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(50, dtype=np.float64)
            io.write_signal_channel(sig, "values", data)
            recovered = np.asarray(io.read_signal_channel(sig, "values"))
            np.testing.assert_array_equal(recovered, data)
        finally:
            provider.close()

    def test_write_signal_channel_rejects_non_1d_on_memory(self) -> None:
        provider, root = self._make_memory_root()
        try:
            sig = root.create_group("signal_channels")
            with pytest.raises(ValueError, match="must be 1-D"):
                io.write_signal_channel(
                    sig, "bad", np.zeros((3, 3), dtype=np.float64)
                )
        finally:
            provider.close()

    def test_write_compound_dataset_on_memory_dispatches_kinds(self) -> None:
        # Routes through the field-kind dispatch (lines 305-321).
        provider, root = self._make_memory_root()
        try:
            g = root.create_group("g")
            records = [
                {"i32": 1, "i64": 100, "f64": 1.5, "name": "a", "weird": 0},
                {"i32": 2, "i64": 200, "f64": 2.5, "name": "b", "weird": 1},
            ]
            fields = [
                ("i32", "<u4"),
                ("i64", "<i8"),
                ("f64", "<f8"),
                ("name", io.vl_str()),
                # An unrecognised dtype string forces the fallback to FLOAT64
                # and exercises the "TypeError → dt = None" branch via a
                # bogus type object.
                ("weird", "<i2"),
            ]
            io.write_compound_dataset(g, "mixed", records, fields)
            out = io.read_compound_dataset(g, "mixed")
            assert len(out) == 2
            assert out[0]["i32"] == 1
            assert out[0]["i64"] == 100
            assert out[0]["f64"] == 1.5
            assert out[0]["name"] == "a"
        finally:
            provider.close()

    def test_write_compound_dataset_with_typeerror_dtype_on_memory(
        self,
    ) -> None:
        # An object that np.dtype() refuses → TypeError → dt = None →
        # kind = FLOAT64 (line 321 branch).
        provider, root = self._make_memory_root()
        try:
            g = root.create_group("g")

            class _NotADtype:
                pass

            records = [{"x": 1.5}, {"x": 2.5}]
            fields = [("x", _NotADtype())]
            io.write_compound_dataset(g, "tx", records, fields)
            out = io.read_compound_dataset(g, "tx")
            assert len(out) == 2
        finally:
            provider.close()


# -------------- channel_segments + au_header_segments helpers ---


class TestChannelSegmentsHelpers:
    """Exercise write/read_channel_segments and write/read_au_header_segments
    via the Memory provider (covers lines around 476-555)."""

    def _make_root(self):
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://seg_test_{id(self)}", mode="w"
        )
        return provider, provider.root_group()

    def test_channel_segments_round_trip(self) -> None:
        provider, root = self._make_root()
        try:
            segments = [
                SimpleNamespace(
                    offset=0, length=4,
                    iv=b"\x00" * 12, tag=b"\x11" * 16,
                    ciphertext=b"abcd",
                ),
                SimpleNamespace(
                    offset=4, length=8,
                    iv=b"\x01" * 12, tag=b"\x22" * 16,
                    ciphertext=b"abcdefgh",
                ),
            ]
            io.write_channel_segments(root, "segments", segments)
            recovered = io.read_channel_segments(root, "segments")
            assert len(recovered) == 2
            assert recovered[0].offset == 0
            assert recovered[0].length == 4
            assert recovered[0].iv == b"\x00" * 12
            assert recovered[0].tag == b"\x11" * 16
            assert recovered[0].ciphertext == b"abcd"
            assert recovered[1].offset == 4
            assert recovered[1].ciphertext == b"abcdefgh"
        finally:
            provider.close()

    def test_channel_segments_read_missing_raises(self) -> None:
        provider, root = self._make_root()
        try:
            with pytest.raises(KeyError, match="not found"):
                io.read_channel_segments(root, "ghost")
        finally:
            provider.close()

    def test_au_header_segments_round_trip(self) -> None:
        provider, root = self._make_root()
        try:
            segments = [
                SimpleNamespace(
                    iv=b"\x10" * 12, tag=b"\x20" * 16,
                    ciphertext=b"\x00" * 36,
                ),
            ]
            io.write_au_header_segments(root, "headers", segments)
            recovered = io.read_au_header_segments(root, "headers")
            assert len(recovered) == 1
            assert recovered[0].iv == b"\x10" * 12
            assert recovered[0].tag == b"\x20" * 16
            assert len(recovered[0].ciphertext) == 36
        finally:
            provider.close()

    def test_au_header_segments_read_missing_raises(self) -> None:
        provider, root = self._make_root()
        try:
            with pytest.raises(KeyError, match="not found"):
                io.read_au_header_segments(root, "ghost")
        finally:
            provider.close()


# --------------- _row_value_to_bytes branches ---


class TestRowValueToBytes:
    def test_bytes_passthrough(self) -> None:
        assert io._row_value_to_bytes(b"hello") == b"hello"

    def test_bytearray_to_bytes(self) -> None:
        assert io._row_value_to_bytes(bytearray(b"hi")) == b"hi"

    def test_uint8_array(self) -> None:
        arr = np.array([1, 2, 3, 4], dtype=np.uint8)
        assert io._row_value_to_bytes(arr) == b"\x01\x02\x03\x04"


# ------------------------- _compression_for branch ---


class TestCompressionFor:
    def test_unsupported_label_raises(self) -> None:
        with pytest.raises(ValueError, match="unsupported signal_compression"):
            io._compression_for("zstd")


# ------------- _write_byte_channel_with_codec branches ---


class TestWriteByteChannelWithCodec:
    def _make_root(self):
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://bcc_{id(self)}", mode="w"
        )
        return provider, provider.root_group()

    def test_no_override_delegates_to_uint8(self) -> None:
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(20, dtype=np.uint8)
            io._write_byte_channel_with_codec(
                sig, "ch", data, "gzip", None
            )
            assert sig.has_child("ch")
        finally:
            provider.close()

    def test_rans_order0_override(self) -> None:
        from ttio.enums import Compression
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.array([0, 1, 2, 3, 0, 1, 2, 3] * 32, dtype=np.uint8)
            io._write_byte_channel_with_codec(
                sig, "ch", data, "gzip", Compression.RANS_ORDER0
            )
            ds = sig.open_dataset("ch")
            assert ds.has_attribute("compression")
        finally:
            provider.close()

    def test_rans_order1_override(self) -> None:
        from ttio.enums import Compression
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.array([0, 1] * 50, dtype=np.uint8)
            io._write_byte_channel_with_codec(
                sig, "ch", data, "gzip", Compression.RANS_ORDER1
            )
            assert sig.has_child("ch")
        finally:
            provider.close()

    def test_unknown_override_raises(self) -> None:
        from ttio.enums import Compression
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(10, dtype=np.uint8)
            # ZLIB is a valid Compression but not a supported codec
            # override → falls into the else branch.
            with pytest.raises(ValueError, match="signal_codec_overrides"):
                io._write_byte_channel_with_codec(
                    sig, "ch", data, "gzip", Compression.ZLIB
                )
        finally:
            provider.close()


# ----------- _write_int_channel_with_codec branches ---


class TestWriteIntChannelWithCodec:
    def _make_root(self):
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://icc_{id(self)}", mode="w"
        )
        return provider, provider.root_group()

    def test_no_override_positions(self) -> None:
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(10, dtype=np.int64)
            io._write_int_channel_with_codec(
                sig, "positions", data, "gzip", None
            )
            assert sig.has_child("positions")
        finally:
            provider.close()

    def test_no_override_flags(self) -> None:
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(10, dtype=np.uint32)
            io._write_int_channel_with_codec(
                sig, "flags", data, "gzip", None
            )
            assert sig.has_child("flags")
        finally:
            provider.close()

    def test_no_override_mapping_qualities(self) -> None:
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(10, dtype=np.uint8)
            io._write_int_channel_with_codec(
                sig, "mapping_qualities", data, "gzip", None
            )
            assert sig.has_child("mapping_qualities")
        finally:
            provider.close()

    def test_no_override_unknown_channel_name_raises(self) -> None:
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(5, dtype=np.int64)
            with pytest.raises(ValueError, match="unknown integer"):
                io._write_int_channel_with_codec(
                    sig, "unknown_ch", data, "gzip", None
                )
        finally:
            provider.close()

    def test_unsupported_override_raises(self) -> None:
        from ttio.enums import Compression
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(5, dtype=np.int64)
            with pytest.raises(ValueError, match="signal_codec_overrides"):
                io._write_int_channel_with_codec(
                    sig, "positions", data, "gzip", Compression.ZLIB
                )
        finally:
            provider.close()

    def test_rans_override_with_unknown_channel_name_raises(self) -> None:
        from ttio.enums import Compression
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(5, dtype=np.int64)
            with pytest.raises(ValueError, match="no dtype registered"):
                io._write_int_channel_with_codec(
                    sig, "unknown_ch", data, "gzip", Compression.RANS_ORDER0
                )
        finally:
            provider.close()

    def test_rans_order0_on_positions(self) -> None:
        from ttio.enums import Compression
        provider, root = self._make_root()
        try:
            sig = root.create_group("signal_channels")
            data = np.arange(100, dtype=np.int64)
            io._write_int_channel_with_codec(
                sig, "positions", data, "gzip", Compression.RANS_ORDER0
            )
            assert sig.has_child("positions")
        finally:
            provider.close()


# ------------------- _write_uint64_channel ---


class TestWriteUint64Channel:
    def test_round_trip(self) -> None:
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://u64_{id(self)}", mode="w"
        )
        try:
            sig = provider.root_group().create_group("signal_channels")
            data = np.array([1, 2, 3, 4], dtype=np.uint64)
            io._write_uint64_channel(sig, "offsets", data, "gzip")
            assert sig.has_child("offsets")
            recovered = np.asarray(sig.open_dataset("offsets").read())
            np.testing.assert_array_equal(recovered, data)
        finally:
            provider.close()

    def test_dtype_coerced_when_input_not_uint64(self) -> None:
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://u64c_{id(self)}", mode="w"
        )
        try:
            sig = provider.root_group().create_group("signal_channels")
            data = np.array([1, 2, 3], dtype=np.int64)  # not uint64
            io._write_uint64_channel(sig, "offsets", data, "none")
            recovered = np.asarray(sig.open_dataset("offsets").read())
            np.testing.assert_array_equal(
                recovered, np.array([1, 2, 3], dtype=np.uint64)
            )
        finally:
            provider.close()
