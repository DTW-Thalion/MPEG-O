"""FLOAT_DELTA_ZSTD (codec id 17) — codec round-trips, the golden
decode fixture, and the .tio write/read dispatch."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import float_delta_zstd as fdz

FIXTURE = Path(__file__).parent / "fixtures" / "float_delta_zstd_golden.bin"


def _edge_arrays() -> dict[str, np.ndarray]:
    rng = np.random.default_rng(3)
    b = fdz.BLOCK_SIZE
    return {
        "empty": np.array([], dtype=np.float64),
        "single": np.array([3.14159], dtype=np.float64),
        "all_identical": np.full(10_000, 7.5),
        "monotone_grid": np.linspace(100.0, 2000.0, 50_000),
        "noise": rng.normal(0, 1e6, 50_000),
        "specials": np.array(
            [0.0, -0.0, np.inf, -np.inf, np.nan,
             np.float64.fromhex("0x1.fffffffffffffp+1023"),
             5e-324, -5e-324] * 100),
        "nan_payloads": np.frombuffer(
            rng.integers(0, 2**63, 4096, dtype=np.uint64)
            .astype(np.uint64).tobytes(), dtype=np.float64).copy(),
        "block_minus_1": rng.normal(0, 1, b - 1),
        "block_exact": rng.normal(0, 1, b),
        "block_plus_1": rng.normal(0, 1, b + 1),
    }


class TestCodecRoundTrip:
    @pytest.mark.parametrize("name", sorted(_edge_arrays()))
    def test_bit_exact(self, name: str) -> None:
        arr = _edge_arrays()[name]
        back = fdz.decode(fdz.encode(arr))
        assert np.array_equal(back.view(np.uint64), arr.view(np.uint64)), name

    def test_selector_uses_both_transforms(self) -> None:
        grid = np.linspace(0.0, 1.0, 100_000)      # delta wins
        noise = np.random.default_rng(1).normal(0, 1, 100_000)  # none wins
        assert fdz.encode(grid)[fdz.HEADER_LEN] == fdz.TRANSFORM_DELTA
        assert fdz.encode(noise)[fdz.HEADER_LEN] == fdz.TRANSFORM_NONE

    def test_bad_magic_rejected(self) -> None:
        with pytest.raises(ValueError, match="FDZ1"):
            fdz.decode(b"NOPE" + bytes(18))

    def test_truncation_rejected(self) -> None:
        enc = fdz.encode(np.linspace(0, 1, 1000))
        with pytest.raises(ValueError):
            fdz.decode(enc[:-3])

    def test_trailing_garbage_rejected(self) -> None:
        enc = fdz.encode(np.linspace(0, 1, 1000))
        with pytest.raises(ValueError, match="trailing"):
            fdz.decode(enc + b"x")


class TestGoldenFixture:
    """The DECODE side is the cross-language contract (spec §4,
    Option B): this exact stream must decode to these exact bits in
    all three languages. Java: FloatDeltaZstdTest.goldenFixture.
    ObjC: TestFloatDeltaZstd.m."""

    def test_golden_decodes(self) -> None:
        stream = FIXTURE.read_bytes()
        arr = fdz.decode(stream)
        expected = golden_values()
        assert np.array_equal(arr.view(np.uint64), expected.view(np.uint64))


def golden_values() -> np.ndarray:
    """The golden fixture's plaintext: deterministic, covers both
    transforms and the specials. Identical generator constants in the
    Java and ObjC tests."""
    n = 4096
    grid = 100.0 + 0.25 * np.arange(n)              # delta-friendly
    lcg = np.empty(n, dtype=np.uint64)
    x = np.uint64(88172645463325252)
    for i in range(n):                               # xorshift64
        x ^= (x << np.uint64(13)) & np.uint64(0xFFFFFFFFFFFFFFFF)
        x ^= x >> np.uint64(7)
        x ^= (x << np.uint64(17)) & np.uint64(0xFFFFFFFFFFFFFFFF)
        lcg[i] = x
    noise = lcg.view(np.float64).copy()
    specials = np.array([0.0, -0.0, np.inf, -np.inf, np.nan, 5e-324])
    return np.concatenate([grid, noise, specials])


class TestTioDispatch:
    def test_write_read_round_trip(self, tmp_path: Path) -> None:
        from ttio.spectral_dataset import SpectralDataset, WrittenRun
        from ttio.enums import AcquisitionMode, Polarity

        n_spectra, points = 8, 512
        total = n_spectra * points
        rng = np.random.default_rng(5)
        mz = np.sort(rng.uniform(100, 2000, total)).reshape(
            n_spectra, points).ravel()
        intensity = rng.lognormal(8, 2, total)
        run = WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.arange(0, total, points, dtype="<u8"),
            lengths=np.full(n_spectra, points, dtype="<u4"),
            retention_times=np.arange(n_spectra, dtype="<f8"),
            ms_levels=np.ones(n_spectra, dtype="<i4"),
            polarities=np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4"),
            precursor_mzs=np.zeros(n_spectra, dtype="<f8"),
            precursor_charges=np.zeros(n_spectra, dtype="<i4"),
            base_peak_intensities=np.ones(n_spectra, dtype="<f8"),
            signal_compression="float_delta_zstd",
        )
        p = tmp_path / "fdz.tio"
        SpectralDataset.write_minimal(
            p, title="fdz", isa_investigation_id="FDZ001",
            runs={"run_0001": run},
        )

        # On disk: flat uint8 stream with @compression = 17, and it is
        # smaller than the raw channel.
        import h5py
        with h5py.File(p, "r") as f:
            ds = f["/study/ms_runs/run_0001/signal_channels/mz_values"]
            assert ds.dtype == np.uint8
            assert int(ds.attrs["compression"]) == 17
            assert ds.shape[0] < total * 8

        with SpectralDataset.open(p) as back:
            r = back.all_runs["run_0001"]
            for i in range(n_spectra):
                sp = r[i]
                got_mz = np.asarray(sp.signal_array("mz").data)
                got_it = np.asarray(sp.signal_array("intensity").data)
                assert np.array_equal(got_mz, mz[i * points:(i + 1) * points])
                assert np.array_equal(
                    got_it, intensity[i * points:(i + 1) * points])

    def test_transport_round_trip_from_fdz_source(self, tmp_path: Path) -> None:
        """The transport writer must emit decoded float64 from a
        codec-17 source (it reads the eager cache)."""
        from ttio.spectral_dataset import SpectralDataset, WrittenRun
        from ttio.enums import AcquisitionMode, Polarity
        from ttio.transport.codec import file_to_transport, transport_to_file

        total = 4 * 64
        rng = np.random.default_rng(9)
        run = WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": np.sort(rng.uniform(100, 900, total)),
                          "intensity": rng.lognormal(5, 1, total)},
            offsets=np.arange(0, total, 64, dtype="<u8"),
            lengths=np.full(4, 64, dtype="<u4"),
            retention_times=np.arange(4, dtype="<f8"),
            ms_levels=np.ones(4, dtype="<i4"),
            polarities=np.full(4, int(Polarity.POSITIVE), dtype="<i4"),
            precursor_mzs=np.zeros(4, dtype="<f8"),
            precursor_charges=np.zeros(4, dtype="<i4"),
            base_peak_intensities=np.ones(4, dtype="<f8"),
            signal_compression="float_delta_zstd",
        )
        src = tmp_path / "src.tio"
        SpectralDataset.write_minimal(
            src, title="t", isa_investigation_id="I", runs={"r": run})
        tis = tmp_path / "s.tis"
        file_to_transport(src, tis)
        rt = transport_to_file(tis, tmp_path / "rt.tio")
        try:
            assert len(rt.all_runs["r"]) == 4
        finally:
            rt.close()


def _flip_run(spectrum_class: str = "TTIOMassSpectrum", **overrides):
    """A minimal 4-spectrum WrittenRun for the Phase 2 default tests."""
    from ttio.spectral_dataset import WrittenRun
    from ttio.enums import AcquisitionMode, Polarity

    total = 4 * 64
    rng = np.random.default_rng(11)
    fields = dict(
        spectrum_class=spectrum_class,
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.sort(rng.uniform(100, 900, total)),
                      "intensity": rng.lognormal(5, 1, total)},
        offsets=np.arange(0, total, 64, dtype="<u8"),
        lengths=np.full(4, 64, dtype="<u4"),
        retention_times=np.arange(4, dtype="<f8"),
        ms_levels=np.ones(4, dtype="<i4"),
        polarities=np.full(4, int(Polarity.POSITIVE), dtype="<i4"),
        precursor_mzs=np.zeros(4, dtype="<f8"),
        precursor_charges=np.zeros(4, dtype="<i4"),
        base_peak_intensities=np.ones(4, dtype="<f8"),
    )
    fields.update(overrides)
    return WrittenRun(**fields)


def _write_one(tmp_path: Path, run) -> Path:
    from ttio.spectral_dataset import SpectralDataset
    p = tmp_path / "flip.tio"
    SpectralDataset.write_minimal(
        p, title="flip", isa_investigation_id="F001", runs={"r": run})
    return p


class TestDefaultFlip:
    """Phase 2 (spec §5): MS float64 channels default to codec id 17.

    ``signal_compression="gzip"`` (the default) on a TTIOMassSpectrum
    run now selects FLOAT_DELTA_ZSTD. ``opt_disable_float_delta=True``
    preserves the chunked-zlib layout; non-MS runs and explicit codec
    strings are unchanged."""

    def test_ms_default_writes_codec_17(self, tmp_path: Path) -> None:
        import h5py
        run = _flip_run()
        p = _write_one(tmp_path, run)
        with h5py.File(p, "r") as f:
            for ch in ("mz", "intensity"):
                ds = f[f"/study/ms_runs/r/signal_channels/{ch}_values"]
                assert ds.dtype == np.uint8, ch
                assert int(ds.attrs["compression"]) == 17, ch

    def test_ms_default_round_trips(self, tmp_path: Path) -> None:
        from ttio.spectral_dataset import SpectralDataset
        run = _flip_run()
        mz = run.channel_data["mz"].copy()
        p = _write_one(tmp_path, run)
        with SpectralDataset.open(p) as back:
            sp = back.all_runs["r"][1]
            got = np.asarray(sp.signal_array("mz").data)
            assert np.array_equal(got, mz[64:128])

    def test_opt_disable_preserves_zlib(self, tmp_path: Path) -> None:
        import h5py
        run = _flip_run(opt_disable_float_delta=True)
        p = _write_one(tmp_path, run)
        with h5py.File(p, "r") as f:
            ds = f["/study/ms_runs/r/signal_channels/mz_values"]
            assert ds.dtype == np.float64
            assert ds.compression == "gzip"
            assert "compression" not in ds.attrs

    def test_nmr_default_unchanged(self, tmp_path: Path) -> None:
        import h5py
        run = _flip_run(
            spectrum_class="TTIONMRSpectrum",
            channel_data={
                "chemical_shift": np.linspace(0, 12, 256),
                "intensity": np.random.default_rng(2).normal(0, 1, 256)},
            offsets=np.arange(0, 256, 64, dtype="<u8"),
        )
        p = _write_one(tmp_path, run)
        with h5py.File(p, "r") as f:
            ds = f["/study/ms_runs/r/signal_channels/chemical_shift_values"]
            assert ds.dtype == np.float64
            assert ds.compression == "gzip"

    def test_explicit_none_still_honoured(self, tmp_path: Path) -> None:
        import h5py
        run = _flip_run(signal_compression="none")
        p = _write_one(tmp_path, run)
        with h5py.File(p, "r") as f:
            ds = f["/study/ms_runs/r/signal_channels/mz_values"]
            assert ds.dtype == np.float64
            assert ds.compression is None


class TestPlainTransform:
    """Bit 1 of the transform keeps the values as little-endian uint64
    instead of byte planes. It wins on m/z arrays, where the transpose
    costs 31%."""

    @staticmethod
    def _bodies(u: np.ndarray, d: np.ndarray) -> dict[int, bytes]:
        import zstandard

        comp = zstandard.ZstdCompressor(level=1)
        return {
            fdz.TRANSFORM_NONE: comp.compress(fdz._transpose(u)),
            fdz.TRANSFORM_DELTA: comp.compress(fdz._transpose(d)),
            fdz.TRANSFORM_PLAIN: comp.compress(fdz._plain(u)),
            fdz.TRANSFORM_PLAIN | fdz.TRANSFORM_DELTA: comp.compress(fdz._plain(d)),
        }

    def test_every_transform_decodes(self) -> None:
        rng = np.random.default_rng(11)
        arr = np.ascontiguousarray(rng.normal(0, 1e3, 5000))
        u = arr.view(np.uint64)
        d = np.empty_like(u)
        d[0] = u[0]
        np.subtract(u[1:], u[:-1], out=d[1:])

        for transform, body in self._bodies(u, d).items():
            stream = fdz.header_bytes(len(arr), 1) + fdz.block_bytes(transform, body)
            np.testing.assert_array_equal(fdz.decode(stream), arr)
            block = fdz.decode_block_bytes(transform, body, len(arr))
            np.testing.assert_array_equal(block, arr)

    def test_transform_above_the_mask_is_rejected(self) -> None:
        arr = np.ascontiguousarray(np.linspace(1.0, 2.0, 64))
        u = arr.view(np.uint64)
        d = np.empty_like(u)
        d[0] = u[0]
        np.subtract(u[1:], u[:-1], out=d[1:])
        body = self._bodies(u, d)[fdz.TRANSFORM_NONE]
        stream = fdz.header_bytes(len(arr), 1) + fdz.block_bytes(0x04, body)
        with pytest.raises(ValueError, match="unknown FDZ1 transform"):
            fdz.decode(stream)
        with pytest.raises(ValueError, match="unknown FDZ1 transform"):
            fdz.decode_block_bytes(0x04, body, len(arr))

    @pytest.mark.parametrize("name", sorted(_edge_arrays()))
    def test_never_larger_than_a_transpose_only_encoder(self, name: str) -> None:
        import zstandard

        arr = _edge_arrays()[name]
        if len(arr) == 0 or len(arr) > fdz.BLOCK_SIZE:
            pytest.skip("encode_block takes 1..BLOCK_SIZE values")
        arr = np.ascontiguousarray(arr)
        u = arr.view(np.uint64)
        d = np.empty_like(u)
        d[0] = u[0]
        np.subtract(u[1:], u[:-1], out=d[1:])
        comp = zstandard.ZstdCompressor(level=fdz.ZSTD_LEVEL)
        transpose_only = min(len(comp.compress(fdz._transpose(u))),
                             len(comp.compress(fdz._transpose(d))))
        _, body = fdz.encode_block(arr)
        assert len(body) <= transpose_only
