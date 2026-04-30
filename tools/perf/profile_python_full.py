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
import hashlib
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

# P4 (perf workplan): isolated codec microbenchmarks.
from ttio.codecs import base_pack as _bp
from ttio.codecs import name_tokenizer as _nt
from ttio.codecs import quality as _qb
from ttio.codecs import rans as _rans

# V10: genomic codec benchmarks.
from ttio.codecs.ref_diff import encode as _ref_diff_encode, decode as _ref_diff_decode
from ttio.codecs.fqzcomp_nx16 import encode as _fqzcomp_encode
from ttio.codecs.fqzcomp_nx16 import decode as _fqzcomp_decode
from ttio.codecs.fqzcomp_nx16_z import encode as _fqzcomp_z_encode
from ttio.codecs.fqzcomp_nx16_z import decode_with_metadata as _fqzcomp_z_decode
from ttio.codecs.delta_rans import encode as _delta_rans_encode, decode as _delta_rans_decode

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


def bench_codecs(_tmp: Path, _n: int) -> dict[str, float]:
    """Isolated encode/decode timings for each genomic codec.

    Fixed-size payloads (1 MiB byte codecs, 10K names for the
    name tokenizer) so cross-language comparisons are meaningful.
    Uses deterministic seeds so re-runs are reproducible (no
    random-jitter headroom in the regression-detection budget).

    Per docs/verification-workplan.md §V2 / P4 follow-up.
    """
    rng = np.random.default_rng(42)
    one_mib = 1024 * 1024  # 1 MiB

    # rANS: random byte payload.
    rans_in = rng.integers(0, 256, size=one_mib, dtype=np.uint8).tobytes()

    t_o0_enc, rans_o0 = _timed(_rans.encode, rans_in, 0)
    t_o0_dec, _       = _timed(_rans.decode, rans_o0)
    t_o1_enc, rans_o1 = _timed(_rans.encode, rans_in, 1)
    t_o1_dec, _       = _timed(_rans.decode, rans_o1)

    # BASE_PACK: pure-ACGT 1 MiB stream — best case for the codec.
    bp_in = bytes(rng.choice(list(b"ACGT"), size=one_mib).tolist())
    t_bp_enc, bp_enc = _timed(_bp.encode, bp_in)
    t_bp_dec, _      = _timed(_bp.decode, bp_enc)

    # QUALITY_BINNED: random Phred bytes (0-93 like real Illumina).
    qb_in = bytes(rng.integers(0, 94, size=one_mib, dtype=np.uint8).tolist())
    t_qb_enc, qb_enc = _timed(_qb.encode, qb_in)
    t_qb_dec, _      = _timed(_qb.decode, qb_enc)

    # NAME_TOKENIZED: 10K Illumina-style names (~ stable size).
    names = [
        f"M88_{i:08d}:{rng.integers(0, 1000):03d}:{rng.integers(0, 100):02d}"
        for i in range(10_000)
    ]
    t_nt_enc, nt_enc = _timed(_nt.encode, names)
    t_nt_dec, _      = _timed(_nt.decode, nt_enc)

    # Throughput (MiB/s) for byte codecs is informational only;
    # downstream regression check still keys off the raw timings.
    def mibps(secs: float, n_bytes: int) -> float:
        return (n_bytes / one_mib) / secs if secs > 0 else 0.0

    # Informational throughput summary printed to stdout but kept
    # OUT of the returned dict — the regression comparator treats
    # every dict value as a timing in seconds, so adding constants
    # like "1.0 MiB input" pollutes the diff. Keys returned here
    # are timings only.
    print(f"  [codec throughput] rans_o0  enc={mibps(t_o0_enc, one_mib):6.1f} MiB/s  dec={mibps(t_o0_dec, one_mib):6.1f} MiB/s")
    print(f"  [codec throughput] rans_o1  enc={mibps(t_o1_enc, one_mib):6.1f} MiB/s  dec={mibps(t_o1_dec, one_mib):6.1f} MiB/s")
    print(f"  [codec throughput] base_pk  enc={mibps(t_bp_enc, one_mib):6.1f} MiB/s  dec={mibps(t_bp_dec, one_mib):6.1f} MiB/s")
    print(f"  [codec throughput] qual_bn  enc={mibps(t_qb_enc, one_mib):6.1f} MiB/s  dec={mibps(t_qb_dec, one_mib):6.1f} MiB/s")
    print(f"  [codec throughput] name_tk  10K names enc={t_nt_enc*1000:.1f} ms  dec={t_nt_dec*1000:.1f} ms")

    return {
        "rans_o0_encode": t_o0_enc,
        "rans_o0_decode": t_o0_dec,
        "rans_o1_encode": t_o1_enc,
        "rans_o1_decode": t_o1_dec,
        "base_pack_encode": t_bp_enc,
        "base_pack_decode": t_bp_dec,
        "quality_binned_encode": t_qb_enc,
        "quality_binned_decode": t_qb_dec,
        "name_tokenized_encode": t_nt_enc,
        "name_tokenized_decode": t_nt_dec,
    }


def bench_codecs_genomic(_tmp: Path, _n: int) -> dict[str, float]:
    """Isolated encode/decode for the 4 genomic codecs (V10).

    Production-scale inputs (~10 MiB each) so inner loops are hot for
    seconds. Deterministic seeds for cross-language parity.
    """
    rng = np.random.default_rng(42)

    # ── REF_DIFF: 100K reads × 100bp against a 100Kbp reference ──
    ref_len = 100_000
    ref_seq = bytes(rng.choice(list(b"ACGT"), size=ref_len).tolist())
    ref_md5 = hashlib.md5(ref_seq).digest()
    n_reads_rd = 100_000
    read_len = 100
    sequences_rd: list[bytes] = []
    for i in range(n_reads_rd):
        start = i % (ref_len - read_len)
        seq = bytearray(ref_seq[start:start + read_len])
        # ~2% mutation rate
        for j in range(read_len):
            if rng.random() < 0.02:
                seq[j] = rng.choice(list(b"ACGT"))
        sequences_rd.append(bytes(seq))
    cigars_rd = [f"{read_len}M"] * n_reads_rd
    positions_rd = sorted(rng.integers(1, ref_len - read_len, size=n_reads_rd).tolist())

    t_rd_enc, rd_encoded = _timed(
        _ref_diff_encode, sequences_rd, cigars_rd, positions_rd,
        ref_seq, ref_md5, "perf-ref")
    t_rd_dec, _ = _timed(
        _ref_diff_decode, rd_encoded, cigars_rd, positions_rd, ref_seq)

    # ── FQZCOMP_NX16: 100K × 100bp quality strings, Q20-Q40 LCG ──
    n_qual = 100_000 * 100
    qual_buf = bytearray(n_qual)
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for i in range(n_qual):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        qual_buf[i] = 33 + 20 + ((s >> 32) % 21)
    qualities = bytes(qual_buf)
    read_lengths = [100] * 100_000
    revcomp_flags = [0] * 100_000

    t_fqz_enc, fqz_encoded = _timed(
        _fqzcomp_encode, qualities, read_lengths, revcomp_flags)
    t_fqz_dec, _ = _timed(_fqzcomp_decode, fqz_encoded)

    # ── FQZCOMP_NX16_Z: same quality input ──
    revcomp_flags_z = [(1 if (i & 7) == 0 else 0) for i in range(100_000)]
    t_fqz_z_enc, fqz_z_encoded = _timed(
        _fqzcomp_z_encode, qualities, read_lengths, revcomp_flags_z)
    t_fqz_z_dec, _ = _timed(
        _fqzcomp_z_decode, fqz_z_encoded, revcomp_flags_z)

    # ── DELTA_RANS: 1.25M sorted int64 positions, LCG deltas 100-500 ──
    n_pos = 1_250_000
    pos_vals = np.empty(n_pos, dtype=np.int64)
    pos_vals[0] = 1000
    s = 0xBEEF
    for i in range(1, n_pos):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        delta = 100 + ((s >> 32) % 401)  # 100..500
        pos_vals[i] = pos_vals[i - 1] + delta
    dr_input = pos_vals.astype("<i8").tobytes()

    t_dr_enc, dr_encoded = _timed(_delta_rans_encode, dr_input, 8)
    t_dr_dec, _ = _timed(_delta_rans_decode, dr_encoded)

    raw_mb_rd = sum(len(sq) for sq in sequences_rd) / 1e6
    print(f"  [genomic codec] ref_diff   {raw_mb_rd:.1f} MiB  "
          f"enc={t_rd_enc:.2f}s  dec={t_rd_dec:.2f}s")
    print(f"  [genomic codec] fqzcomp    {n_qual/1e6:.1f} MiB  "
          f"enc={t_fqz_enc:.2f}s  dec={t_fqz_dec:.2f}s")
    print(f"  [genomic codec] fqzcomp_z  {n_qual/1e6:.1f} MiB  "
          f"enc={t_fqz_z_enc:.2f}s  dec={t_fqz_z_dec:.2f}s")
    print(f"  [genomic codec] delta_rans {len(dr_input)/1e6:.1f} MiB  "
          f"enc={t_dr_enc:.2f}s  dec={t_dr_dec:.2f}s")

    return {
        "ref_diff_encode": t_rd_enc,
        "ref_diff_decode": t_rd_dec,
        "fqzcomp_nx16_encode": t_fqz_enc,
        "fqzcomp_nx16_decode": t_fqz_dec,
        "fqzcomp_nx16_z_encode": t_fqz_z_enc,
        "fqzcomp_nx16_z_decode": t_fqz_z_dec,
        "delta_rans_encode": t_dr_enc,
        "delta_rans_decode": t_dr_dec,
    }


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
    "codecs":         lambda tmp, a: bench_codecs(tmp, a.n),
    "codecs.genomic": lambda tmp, a: bench_codecs_genomic(tmp, a.n),
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
