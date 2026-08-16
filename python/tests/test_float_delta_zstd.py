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
