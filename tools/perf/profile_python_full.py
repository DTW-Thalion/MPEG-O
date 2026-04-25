"""Multi-function Python perf harness for TTI-O.

Covers every major function introduced through v0.11.1:

* **ms**           — MS write/read across all four storage providers
                     (HDF5, Memory, SQLite, Zarr).
* **transport**    — ``.tis`` encode + decode (plain and compressed).
* **encryption**   — per-AU AES-256-GCM encrypt + decrypt.
* **signatures**   — HMAC-SHA256 sign + verify.
* **jcamp**        — JCAMP-DX write + read (AFFN and SQZ/DIF compressed).
* **spectra**      — Raman / IR / UV-Vis / 2D-COS build + persist.

Each benchmark reports a ``name → {phase: ms}`` block and the combined
run emits a human-readable table at the end. Workload sizes are kept
small-but-representative so the full sweep fits in a single CI run,
and they match the Java and ObjC harnesses so cross-language deltas
are meaningful.

Usage:
    python3 tools/perf/profile_python_full.py [--n 10000] [--peaks 16]
                                                [--only ms,transport]
                                                [--out DIR]
"""
from __future__ import annotations

import argparse
import gc
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import numpy as np

from ttio import (
    AxisDescriptor,
    IRSpectrum,
    RamanSpectrum,
    SignalArray,
    SpectralDataset,
    TwoDimensionalCorrelationSpectrum,
    UVVisSpectrum,
    WrittenRun,
)
from ttio.encryption_per_au import (
    decrypt_per_au_file,
    encrypt_per_au_file,
)
from ttio.enums import IRMode
from ttio.exporters.jcamp_dx import (
    write_ir_spectrum,
    write_raman_spectrum,
    write_uv_vis_spectrum,
)
from ttio.importers.jcamp_dx import read_spectrum as jcamp_read_spectrum
from ttio.signatures import sign_dataset, verify_dataset
from ttio.transport import file_to_transport, transport_to_file

# ---------------------------------------------------------------------------
# Workload helpers
# ---------------------------------------------------------------------------


def _build_ms_run(n: int, peaks: int) -> WrittenRun:
    """Varying-per-spectrum MS run (matches Java/ObjC harnesses)."""
    ii = np.repeat(np.arange(n, dtype=np.float64), peaks)
    jj = np.tile(np.arange(peaks, dtype=np.float64), n)
    mz = 100.0 + ii + jj * 0.1
    ij = np.repeat(np.arange(n, dtype=np.int64), peaks) * 31 \
         + np.tile(np.arange(peaks, dtype=np.int64), n)
    intensity = 1000.0 + (ij % 1000).astype(np.float64)
    offsets = np.arange(n, dtype=np.uint64) * peaks
    lengths = np.full(n, peaks, dtype=np.uint32)
    rts = np.arange(n, dtype=np.float64) * 0.06
    ms_levels = np.ones(n, dtype=np.int32)
    polarities = np.ones(n, dtype=np.int32)
    precursor_mzs = np.zeros(n, dtype=np.float64)
    precursor_charges = np.zeros(n, dtype=np.int32)
    base_peak = intensity.reshape(n, peaks).max(axis=1)
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=0,
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peak,
    )


def _timed(fn, *args, **kwargs) -> tuple[float, Any]:
    gc.collect()
    t0 = time.perf_counter()
    result = fn(*args, **kwargs)
    return time.perf_counter() - t0, result


# ---------------------------------------------------------------------------
# Benchmarks (each returns {phase: seconds})
# ---------------------------------------------------------------------------


def bench_ms(tmp: Path, n: int, peaks: int,
             provider: str) -> dict[str, float]:
    """Write+read a MS dataset on the given provider."""
    run = _build_ms_run(n, peaks)

    if provider == "hdf5":
        url: str = str(tmp / f"ms-{provider}.tio")
    elif provider == "memory":
        url = f"memory://ms-bench-{os.getpid()}-{id(run):x}"
    elif provider == "sqlite":
        url = f"sqlite://{tmp / 'ms-sqlite.tio.sqlite'}"
    elif provider == "zarr":
        url = f"zarr://{tmp / 'ms-zarr.tio.zarr'}"
    else:
        raise ValueError(provider)

    t_write, _ = _timed(
        SpectralDataset.write_minimal,
        url, title="stress", isa_investigation_id="ISA-PERF",
        runs={"r": run}, provider=provider,
    )

    def _read() -> int:
        with SpectralDataset.open(url) as ds:
            r = ds.ms_runs["r"]
            total = 0
            step = max(1, n // 100)  # sample ~100 spectra
            for i in range(0, n, step):
                total += r[i].signal_arrays["mz"].data.size
        return total
    t_read, _ = _timed(_read)

    if provider == "memory":
        from ttio.providers.memory import MemoryProvider
        MemoryProvider.discard_store(url)

    return {"write": t_write, "read": t_read}


def bench_transport(tmp: Path, n: int, peaks: int,
                    use_compression: bool) -> dict[str, float]:
    """Encode a .tio file to .tis and decode it back."""
    src = tmp / "xport.tio"
    SpectralDataset.write_minimal(
        src, title="xport", isa_investigation_id="ISA-XPORT",
        runs={"r": _build_ms_run(n, peaks)},
    )
    mots = tmp / ("xport-c.tis" if use_compression else "xport.tis")
    t_enc, _ = _timed(
        file_to_transport, src, mots,
        use_compression=use_compression, use_checksum=True,
    )
    rt = tmp / ("rt-c.tio" if use_compression else "rt.tio")
    t_dec, _ = _timed(transport_to_file, mots, rt)
    return {"encode": t_enc, "decode": t_dec,
            "src_mb": src.stat().st_size / 1e6,
            "mots_mb": mots.stat().st_size / 1e6}


def bench_per_au_encryption(tmp: Path, n: int,
                            peaks: int) -> dict[str, float]:
    src = tmp / "enc.tio"
    SpectralDataset.write_minimal(
        src, title="enc", isa_investigation_id="ISA-ENC",
        runs={"r": _build_ms_run(n, peaks)},
    )
    key = bytes(range(32))

    # The encrypt_per_au_file API encrypts a copy in place; make a fresh
    # copy for the decrypt phase so both measurements start from the
    # same plaintext state.
    import shutil
    copy = tmp / "enc-copy.tio"
    shutil.copy(src, copy)
    t_enc, _ = _timed(encrypt_per_au_file, str(copy), key)
    t_dec, _ = _timed(decrypt_per_au_file, str(copy), key)
    return {"encrypt": t_enc, "decrypt": t_dec,
            "bytes_mb": src.stat().st_size / 1e6}


def bench_signatures(tmp: Path, n: int, peaks: int) -> dict[str, float]:
    src = tmp / "sig.tio"
    SpectralDataset.write_minimal(
        src, title="sig", isa_investigation_id="ISA-SIG",
        runs={"r": _build_ms_run(n, peaks)},
    )
    key = bytes(range(32))

    # sign_dataset operates on a StorageDataset (signal channel), not
    # the whole SpectralDataset — we measure the intensity channel's
    # HMAC since that's the hottest-path channel in real pipelines.
    def _sign() -> str:
        with SpectralDataset.open(src, writable=True) as ds:
            run = ds.ms_runs["r"]
            ch = run.group.open_group("signal_channels").open_dataset(
                "intensity_values")
            return sign_dataset(ch, key)

    def _verify() -> bool:
        with SpectralDataset.open(src) as ds:
            run = ds.ms_runs["r"]
            ch = run.group.open_group("signal_channels").open_dataset(
                "intensity_values")
            return verify_dataset(ch, key)

    t_sign, _ = _timed(_sign)
    t_verify, _ = _timed(_verify)
    return {"sign": t_sign, "verify": t_verify}


def _make_ir_spectrum(n: int) -> IRSpectrum:
    wavenumber = np.linspace(4000.0, 400.0, n)
    intensity = 0.5 + 0.4 * np.sin(wavenumber / 50.0)
    return IRSpectrum(
        signal_arrays={
            IRSpectrum.WAVENUMBER: SignalArray.from_numpy(
                wavenumber, axis=AxisDescriptor("wavenumber", "1/cm")),
            IRSpectrum.INTENSITY: SignalArray.from_numpy(
                intensity, axis=AxisDescriptor("absorbance", "")),
        },
        mode=IRMode.ABSORBANCE,
        resolution_cm_inv=4.0,
        number_of_scans=32,
    )


def _make_raman_spectrum(n: int) -> RamanSpectrum:
    wavenumber = np.linspace(100.0, 3200.0, n)
    intensity = 10.0 + 100.0 * np.exp(-((wavenumber - 1500.0) / 300.0) ** 2)
    return RamanSpectrum(
        signal_arrays={
            RamanSpectrum.WAVENUMBER: SignalArray.from_numpy(
                wavenumber, axis=AxisDescriptor("raman shift", "1/cm")),
            RamanSpectrum.INTENSITY: SignalArray.from_numpy(
                intensity, axis=AxisDescriptor("intensity", "counts")),
        },
        excitation_wavelength_nm=785.0,
        laser_power_mw=20.0,
        integration_time_sec=5.0,
    )


def _make_uvvis_spectrum(n: int) -> UVVisSpectrum:
    wl = np.linspace(200.0, 800.0, n)
    absorb = np.exp(-((wl - 450.0) / 40.0) ** 2)
    return UVVisSpectrum(
        signal_arrays={
            UVVisSpectrum.WAVELENGTH: SignalArray.from_numpy(
                wl, axis=AxisDescriptor("wavelength", "nm")),
            UVVisSpectrum.ABSORBANCE: SignalArray.from_numpy(
                absorb, axis=AxisDescriptor("absorbance", "")),
        },
        path_length_cm=1.0,
        solvent="methanol",
    )


def _make_2dcos(m: int) -> TwoDimensionalCorrelationSpectrum:
    # Noda-style synthetic sync/async matrices.
    v = np.linspace(1000.0, 1800.0, m)
    sync = np.outer(np.cos(v / 100.0), np.cos(v / 100.0))
    async_m = np.outer(np.sin(v / 100.0), np.cos(v / 100.0))
    return TwoDimensionalCorrelationSpectrum(
        synchronous_matrix=sync,
        asynchronous_matrix=async_m,
        variable_axis=AxisDescriptor("wavenumber", "1/cm"),
        perturbation="temperature",
        perturbation_unit="K",
        source_modality="IR",
    )


def bench_jcamp(tmp: Path, n: int) -> dict[str, float]:
    """JCAMP-DX AFFN + compressed (SQZ/DIF) write+read."""
    ir = _make_ir_spectrum(n)
    jdx = tmp / "ir.jdx"

    t_w_ir, _ = _timed(write_ir_spectrum, ir, jdx, "perf IR")
    t_r_ir, _ = _timed(jcamp_read_spectrum, jdx)

    raman = _make_raman_spectrum(n)
    jdx_r = tmp / "raman.jdx"
    t_w_raman, _ = _timed(write_raman_spectrum, raman, jdx_r, "perf Raman")
    t_r_raman, _ = _timed(jcamp_read_spectrum, jdx_r)

    uvvis = _make_uvvis_spectrum(n)
    jdx_u = tmp / "uvvis.jdx"
    t_w_uv, _ = _timed(write_uv_vis_spectrum, uvvis, jdx_u, "perf UV-Vis")
    t_r_uv, _ = _timed(jcamp_read_spectrum, jdx_u)

    # Compressed read path: hand-roll a SQZ fixture of length n.
    # SQZ alphabet: @=0, A=1..I=9 (positive); a=-1..i=-9 (negative).
    values = np.arange(n, dtype=np.float64) % 10  # 0..9
    sqz = "@ABCDEFGHI"  # index = absolute value
    lines = []
    i = 0
    line_x = 100.0
    while i < n:
        chunk = values[i:i + 10]
        encoded = "".join(sqz[int(v)] for v in chunk)
        lines.append(f"{int(line_x)} {encoded}")
        line_x += len(chunk)
        i += 10
    jdx_c = tmp / "compressed.jdx"
    jdx_c.write_text(
        "##TITLE=perf-compressed\n"
        "##JCAMP-DX=5.01\n"
        "##DATA TYPE=INFRARED ABSORBANCE\n"
        "##XUNITS=1/CM\n##YUNITS=ABSORBANCE\n"
        f"##FIRSTX=100\n##LASTX={100 + n - 1}\n##NPOINTS={n}\n"
        "##XFACTOR=1\n##YFACTOR=1\n"
        "##XYDATA=(X++(Y..Y))\n"
        + "\n".join(lines) + "\n##END=\n",
        encoding="utf-8",
    )
    t_r_comp, _ = _timed(jcamp_read_spectrum, jdx_c)

    return {
        "ir_write":  t_w_ir,  "ir_read":    t_r_ir,
        "raman_write": t_w_raman, "raman_read": t_r_raman,
        "uvvis_write": t_w_uv, "uvvis_read": t_r_uv,
        "compressed_read": t_r_comp,
    }


def bench_spectra_inmemory(n: int) -> dict[str, float]:
    """Build-time costs for the v0.11+ spectrum classes (no I/O).

    Measures the cost of constructing the signal arrays + wrapper
    object — useful when something needs to emit thousands of these
    (e.g. imaging cube post-processing)."""
    t_ir, _    = _timed(_make_ir_spectrum, n)
    t_raman, _ = _timed(_make_raman_spectrum, n)
    t_uv, _    = _timed(_make_uvvis_spectrum, n)
    # 2D-COS uses m=sqrt(n) so storage is ~ n scalars.
    m = max(8, int(np.sqrt(n)))
    t_2d, _    = _timed(_make_2dcos, m)
    return {"ir_build": t_ir, "raman_build": t_raman,
            "uvvis_build": t_uv, "2dcos_build": t_2d}


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


BENCHMARKS: dict[str, Any] = {
    # Name : (callable(tmp, args) -> dict, label)
    "ms.hdf5":        lambda tmp, a: bench_ms(tmp, a.n, a.peaks, "hdf5"),
    "ms.memory":      lambda tmp, a: bench_ms(tmp, a.n, a.peaks, "memory"),
    "ms.sqlite":      lambda tmp, a: bench_ms(tmp, a.n, a.peaks, "sqlite"),
    "ms.zarr":        lambda tmp, a: bench_ms(tmp, a.n, a.peaks, "zarr"),
    "transport.plain": lambda tmp, a: bench_transport(tmp, a.n, a.peaks, False),
    "transport.compressed":
                       lambda tmp, a: bench_transport(tmp, a.n, a.peaks, True),
    "encryption":     lambda tmp, a: bench_per_au_encryption(tmp, a.n, a.peaks),
    "signatures":     lambda tmp, a: bench_signatures(tmp, a.n, a.peaks),
    "jcamp":          lambda tmp, a: bench_jcamp(tmp, a.n),
    "spectra.build":  lambda tmp, a: bench_spectra_inmemory(a.n),
}


def _print_result(name: str, result: dict[str, float]) -> None:
    print(f"\n[{name}]")
    for phase, value in result.items():
        if phase.endswith("_mb"):
            print(f"  {phase:<20s} {value:10.2f} MB")
        else:
            print(f"  {phase:<20s} {value * 1000:10.1f} ms")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10000,
                    help="spectrum count (ms/transport/encryption/signatures)")
    ap.add_argument("--peaks", type=int, default=16)
    ap.add_argument("--only", type=str, default="",
                    help="comma-separated benchmark names to run; "
                         f"available: {', '.join(BENCHMARKS)}")
    ap.add_argument("--skip", type=str, default="",
                    help="comma-separated benchmark names to skip")
    ap.add_argument("--json", type=Path, default=None,
                    help="also dump results as JSON to this file")
    ap.add_argument("--out", type=Path,
                    default=Path("/tmp/mpgo_profile_python_full"))
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    only = {s.strip() for s in args.only.split(",") if s.strip()}
    skip = {s.strip() for s in args.skip.split(",") if s.strip()}
    selected = [k for k in BENCHMARKS
                if (not only or k in only) and k not in skip]

    print("=" * 78)
    print(f"Python multi-function perf  n={args.n}  peaks={args.peaks}")
    print(f"  running: {', '.join(selected)}")
    print("=" * 78)

    all_results: dict[str, dict[str, float]] = {}
    for name in selected:
        tmp = Path(tempfile.mkdtemp(prefix=f"ttio-{name.replace('.', '-')}-",
                                      dir=str(args.out)))
        try:
            fn = BENCHMARKS[name]
            result = fn(tmp, args)
            all_results[name] = result
            _print_result(name, result)
        except Exception as e:
            print(f"\n[{name}] FAILED: {type(e).__name__}: {e}")
            all_results[name] = {"error": str(e)}

    print("\n" + "=" * 78)
    print("SUMMARY (milliseconds)")
    print("=" * 78)
    for name, res in all_results.items():
        if "error" in res:
            print(f"  {name:<28s} FAILED: {res['error']}")
            continue
        times_ms = [(p, v * 1000) for p, v in res.items()
                    if not p.endswith("_mb")]
        total_ms = sum(v for _, v in times_ms)
        phases = "  ".join(f"{p}={v:.1f}" for p, v in times_ms)
        print(f"  {name:<28s} total={total_ms:7.1f}   {phases}")

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        with args.json.open("w") as f:
            json.dump({
                "n": args.n, "peaks": args.peaks,
                "results": all_results,
            }, f, indent=2, default=str)
        print(f"\nJSON dump: {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
