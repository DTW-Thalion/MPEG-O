"""Phase 2c-T storage-provider parity for bulk-mode v2 blob carriage.

Verifies that ``WrittenGenomicRun.bulk_v2_blobs`` is honored by the
HDF5, memory, sqlite, and zarr write paths — i.e. the v2 codec
encode is skipped and the wire blob bytes land verbatim in
``mate_info/inline_v2`` and ``read_names``.

Complements ``test_phase_2c_t_bulk_mode.py`` which only exercises
the HDF5 fast path through the transport encode/decode CLIs.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import h5py
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent))
from test_cross_language_smoke import _REPO_ROOT  # type: ignore[import-not-found]

from ttio import SpectralDataset, WrittenGenomicRun
from ttio.providers import open_provider
from ttio.written_genomic_run import BulkV2Blobs


def _native_lib_available() -> bool:
    rans = os.environ.get("TTIO_RANS_LIB_PATH", "")
    if rans and os.path.isfile(rans):
        return True
    candidate = _REPO_ROOT / "native" / "_build" / "libttio_rans.so"
    if candidate.is_file():
        os.environ.setdefault("TTIO_RANS_LIB_PATH", str(candidate))
        return True
    return False


pytestmark = pytest.mark.skipif(
    not _native_lib_available(),
    reason="bulk-mode storage-provider parity needs libttio_rans",
)


def _build_run(n: int = 5) -> WrittenGenomicRun:
    seq = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qual = np.frombuffer(bytes([30] * 8 * n), dtype=np.uint8)
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="S",
        positions=np.arange(n, dtype=np.int64) * 100,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 3, dtype=np.uint32),
        sequences=seq,
        qualities=qual,
        offsets=np.arange(n, dtype=np.uint64) * 8,
        lengths=np.full(n, 8, dtype=np.uint32),
        cigars=["8M"] * n,
        read_names=[f"r_{i:02d}" for i in range(n)],
        mate_chromosomes=(["=", "chr2", "=", "chr3", "chr1"][:n]),
        mate_positions=np.arange(n, dtype=np.int64) * 200,
        template_lengths=np.array(
            [100 * (i % 3) for i in range(n)], dtype=np.int32,
        ),
        chromosomes=["chr1"] * n,
        # blocks_v1 read support in Java and ObjC lands with their
        # streaming specs; until then the cross-language genomic
        # fixtures use the v1.8 whole-channel layout.
        opt_legacy_whole_channel=True,
    )


def _extract_blobs(hdf5_path: str) -> tuple[bytes, list[str], bytes]:
    with h5py.File(hdf5_path, "r") as f:
        sc = "/study/genomic_runs/g_0001/signal_channels"
        mate_blob = bytes(f[f"{sc}/mate_info/inline_v2"][:].tobytes())
        chrom_names = [
            (r[0].decode() if isinstance(r[0], bytes) else r[0])
            for r in f[f"{sc}/mate_info/chrom_names"][:]
        ]
        name_blob = bytes(f[f"{sc}/read_names"][:].tobytes())
    return mate_blob, chrom_names, name_blob


def _read_blobs_from_provider(sp) -> tuple[bytes, bytes]:
    """Read the verbatim mate_info/inline_v2 + read_names blobs from
    a fresh-written provider. Returns ``(mate_blob, name_blob)``."""
    sc = (sp.root_group()
            .open_group("study")
            .open_group("genomic_runs")
            .open_group("g_0001")
            .open_group("signal_channels"))
    mate_ds = sc.open_group("mate_info").open_dataset("inline_v2")
    mate = bytes(mate_ds.read(offset=0, count=int(mate_ds.length)))
    names_ds = sc.open_dataset("read_names")
    names = bytes(names_ds.read(offset=0, count=int(names_ds.length)))
    return mate, names


def _zarr_available() -> bool:
    try:
        import zarr  # noqa: F401
        return True
    except ImportError:
        return False


_PROVIDERS = ["memory", "sqlite"]
if _zarr_available():
    _PROVIDERS.append("zarr")


@pytest.mark.parametrize("provider", _PROVIDERS)
def test_bulk_v2_blobs_storage_provider_parity(
    provider: str, tmp_path: Path,
) -> None:
    """Bulk-mode short-circuit lands verbatim blob bytes on each
    non-HDF5 storage provider."""
    # Source: HDF5-encoded run to extract canonical blob bytes.
    src_run = _build_run()
    src_path = str(tmp_path / "src.tio")
    SpectralDataset.write_minimal(
        src_path,
        title="src",
        isa_investigation_id="isa",
        runs={},
        genomic_runs={"g_0001": src_run},
    )
    src_mate, src_chroms, src_names = _extract_blobs(src_path)

    # Bulk-mode write into the provider.
    bulk_run = WrittenGenomicRun(
        acquisition_mode=src_run.acquisition_mode,
        reference_uri=src_run.reference_uri,
        platform=src_run.platform,
        sample_name=src_run.sample_name,
        positions=src_run.positions,
        mapping_qualities=src_run.mapping_qualities,
        flags=src_run.flags,
        sequences=src_run.sequences,
        qualities=src_run.qualities,
        offsets=src_run.offsets,
        lengths=src_run.lengths,
        cigars=src_run.cigars,
        read_names=src_run.read_names,
        mate_chromosomes=src_run.mate_chromosomes,
        mate_positions=src_run.mate_positions,
        template_lengths=src_run.template_lengths,
        chromosomes=src_run.chromosomes,
        # blocks_v1 read support in Java and ObjC lands with their
        # streaming specs; until then the cross-language genomic
        # fixtures use the v1.8 whole-channel layout.
        opt_legacy_whole_channel=True,
        bulk_v2_blobs=BulkV2Blobs(
            mate_info_blob=src_mate,
            mate_info_chrom_names=src_chroms,
            name_tok_blob=src_names,
        ),
    )

    if provider == "sqlite":
        url = f"sqlite://{tmp_path / 'bulk.tio'}"
    elif provider == "zarr":
        url = f"zarr://{tmp_path / 'bulk.tio.zarr'}"
    else:
        url = "memory://bulk.tio"

    sp = open_provider(url, provider=provider, mode="w")
    SpectralDataset.write_minimal(
        url,
        title="bulk",
        isa_investigation_id="isa",
        runs={},
        genomic_runs={"g_0001": bulk_run},
        provider=sp,
    )

    mate, names = _read_blobs_from_provider(sp)
    assert mate == src_mate, (
        f"{provider}: mate_info/inline_v2 blob bytes diverged from source "
        f"({len(mate)} vs {len(src_mate)})"
    )
    assert names == src_names, (
        f"{provider}: read_names blob bytes diverged from source "
        f"({len(names)} vs {len(src_names)})"
    )
