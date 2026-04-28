"""M90.10: UINT8 wire compression via M86 codecs.

Closes the M89.2 deferred scope on wire compression for genomic
channels. The existing zlib-on-wire path is FLOAT64-only (used by
MS); for genomic UINT8 channels (sequences/qualities) we use the
M86 codec family (RANS_ORDER0/1 + BASE_PACK).

Design choice (option c from gap analysis): the writer propagates
the source channel's ``@compression`` attribute to the wire — if the
source ``.tio`` was written with ``signal_codec_overrides={"sequences":
Compression.BASE_PACK}``, the wire emits each AU's slice
re-encoded with BASE_PACK. The reader inspects the wire channel's
``compression`` byte and dispatches to the matching decoder. M82-
vintage genomic data (no ``@compression`` attr) stays uncompressed
on the wire — backward compatible.
"""
from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio import SpectralDataset
from ttio.enums import Compression
from ttio.transport.codec import file_to_transport, transport_to_file
from ttio.transport.packets import AccessUnit, ChannelData, PacketType
from ttio.transport.codec import TransportReader
from ttio.written_genomic_run import WrittenGenomicRun


def _make_genomic_dataset(
    path: Path,
    *,
    sequences_codec: Compression | None = None,
    qualities_codec: Compression | None = None,
) -> Path:
    n = 4
    L = 8
    # Pure ACGT sequences so BASE_PACK can give the 2-bit win.
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
    overrides: dict[str, Compression] = {}
    if sequences_codec is not None:
        overrides["sequences"] = sequences_codec
    if qualities_codec is not None:
        overrides["qualities"] = qualities_codec
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"read_{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
        signal_codec_overrides=overrides,
    )
    SpectralDataset.write_minimal(
        path,
        title="M90.10 wire-codec fixture",
        isa_investigation_id="ISA-M90-10",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


def _au_compressions_per_channel(buffer: io.BytesIO) -> dict[str, list[int]]:
    """Read the .tis stream and return {channel_name: [compression_byte_per_AU]}."""
    out: dict[str, list[int]] = {}
    buffer.seek(0)
    with TransportReader(buffer) as tr:
        for header, payload in tr.iter_packets():
            if int(header.packet_type) != int(PacketType.ACCESS_UNIT):
                continue
            au = AccessUnit.from_bytes(payload)
            for ch in au.channels:
                out.setdefault(ch.name, []).append(int(ch.compression))
    return out


class TestSourceCodecPropagation:

    def test_no_codec_source_emits_uncompressed_wire(self, tmp_path):
        """Backward compat: M82-vintage genomic (no @compression) stays
        compression=NONE on the wire."""
        src = _make_genomic_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        wire_codecs = _au_compressions_per_channel(buffer)
        assert wire_codecs["sequences"] == [0, 0, 0, 0]  # NONE
        assert wire_codecs["qualities"] == [0, 0, 0, 0]

    def test_base_pack_source_emits_base_pack_wire(self, tmp_path):
        src = _make_genomic_dataset(
            tmp_path / "bp.tio",
            sequences_codec=Compression.BASE_PACK,
        )
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        wire_codecs = _au_compressions_per_channel(buffer)
        # Sequences: BASE_PACK on every AU.
        assert wire_codecs["sequences"] == [int(Compression.BASE_PACK)] * 4
        # Qualities: not opted into a codec → NONE.
        assert wire_codecs["qualities"] == [0, 0, 0, 0]

    def test_rans_order0_source_emits_rans_wire(self, tmp_path):
        src = _make_genomic_dataset(
            tmp_path / "r0.tio",
            qualities_codec=Compression.RANS_ORDER0,
        )
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        wire_codecs = _au_compressions_per_channel(buffer)
        assert wire_codecs["qualities"] == [int(Compression.RANS_ORDER0)] * 4


class TestRoundTrip:

    @pytest.mark.parametrize("codec", [
        Compression.BASE_PACK,
        Compression.RANS_ORDER0,
        Compression.RANS_ORDER1,
    ])
    def test_round_trip_preserves_bytes(self, tmp_path, codec):
        src = _make_genomic_dataset(
            tmp_path / f"rt_{int(codec)}.tio",
            sequences_codec=codec,
        )
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        rt = transport_to_file(buffer, tmp_path / f"out_{int(codec)}.tio")
        try:
            gr = rt.genomic_runs["genomic_0001"]
            for i in range(len(gr)):
                assert gr[i].sequence == "ACGTACGT", (
                    f"codec={codec.name} read {i} sequence mismatch"
                )
                assert gr[i].qualities == bytes([30] * 8)
        finally:
            rt.close()

    def test_compressed_wire_smaller_than_uncompressed(self, tmp_path):
        """Sanity check: BASE_PACK on pure-ACGT sequences should produce
        a meaningfully smaller .tis than uncompressed for a non-trivial
        fixture."""
        # 100-read fixture with 150-base reads — ~15kB sequences.
        n = 100
        L = 150
        sequences = np.frombuffer(b"ACGTACGT" * (n * L // 8), dtype=np.uint8)
        qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
        chroms = ["chr1"] * n
        run_kwargs = dict(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.full(n, 100, dtype=np.int64),
            mapping_qualities=np.full(n, 60, dtype=np.uint8),
            flags=np.full(n, 0x0003, dtype=np.uint32),
            sequences=sequences,
            qualities=qualities,
            offsets=np.arange(n, dtype=np.uint64) * L,
            lengths=np.full(n, L, dtype=np.uint32),
            cigars=[f"{L}M"] * n,
            read_names=[f"r{i}" for i in range(n)],
            mate_chromosomes=[""] * n,
            mate_positions=np.full(n, -1, dtype=np.int64),
            template_lengths=np.zeros(n, dtype=np.int32),
            chromosomes=chroms,
        )
        run_plain = WrittenGenomicRun(**run_kwargs)
        run_packed = WrittenGenomicRun(
            **run_kwargs,
            signal_codec_overrides={"sequences": Compression.BASE_PACK},
        )
        plain_path = tmp_path / "plain.tio"
        packed_path = tmp_path / "packed.tio"
        SpectralDataset.write_minimal(
            plain_path, title="x", isa_investigation_id="x",
            runs={}, genomic_runs={"genomic_0001": run_plain},
        )
        SpectralDataset.write_minimal(
            packed_path, title="x", isa_investigation_id="x",
            runs={}, genomic_runs={"genomic_0001": run_packed},
        )
        plain_tis = io.BytesIO()
        packed_tis = io.BytesIO()
        file_to_transport(plain_path, plain_tis)
        file_to_transport(packed_path, packed_tis)
        # BASE_PACK on pure ACGT is ~25% of plaintext, but per-AU
        # encoding adds ~13 bytes of header per call AND the .tis
        # stream's other framing (genomic_index, qualities,
        # per-AU prefix, channel framing, etc.) is uncompressed, so
        # the achievable .tis-level reduction is ~20% — not the
        # codec's headline ~75% on raw data. Assert the codec is
        # doing SOMETHING (>10% reduction) without overclaiming.
        plain_size = plain_tis.tell()
        packed_size = packed_tis.tell()
        assert packed_size < plain_size * 0.90, (
            f"BASE_PACK didn't compress meaningfully: "
            f"plain={plain_size}, packed={packed_size}"
        )
