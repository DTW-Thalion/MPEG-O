"""Stage 1 / Task 2.2 (transport-spec v0.11): exercise
:meth:`TransportWriter.write_reference_group` and verify the emitted
packet sequence matches §4.13-§4.15 of the transport spec.

Python parity for Java's ``TransportWriterReferenceTest`` (commit
``622aa8bd``). All multi-byte integers are LITTLE-ENDIAN per spec
§1.7. The chromosome index rides in the packet header's
``au_sequence`` field. Encoding=0 (raw) when the sequence is shorter
than 4 KiB, encoding=1 (zlib) otherwise.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import struct
import zlib

from ttio.genomic.reference_import import ReferenceImport
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType


def test_write_reference_group_emits_header_chromosomes_eof_in_order() -> None:
    """Two short chromosomes (< 4 KiB) ride uncompressed; au_sequence
    in the REFERENCE_CHROMOSOME header carries the 0-based chromosome
    index; EOR payload echoes the chromosome count."""
    ref = ReferenceImport(
        uri="fixture-test-ref-v1",
        chromosomes=["chr1", "chr2"],
        sequences=[b"ACGT", b"TTTTCC"],
    )

    out = io.BytesIO()
    with TransportWriter(out) as w:
        w.write_stream_header(
            format_version="1.2",
            title="ref-test",
            isa_investigation="isa",
            features=[],
            n_datasets=0,
        )
        w.write_reference_group(ref)
        w.write_end_of_stream()

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    # Expected sequence: StreamHeader, RefGroupHeader, 2x RefChromosome,
    # EOR, EOS.
    assert len(records) == 6, f"expected 6 packets, got {len(records)}"
    assert records[0].header.packet_type == int(PacketType.STREAM_HEADER)
    assert records[1].header.packet_type == int(
        PacketType.REFERENCE_GROUP_HEADER
    )
    assert records[2].header.packet_type == int(PacketType.REFERENCE_CHROMOSOME)
    assert records[3].header.packet_type == int(PacketType.REFERENCE_CHROMOSOME)
    assert records[4].header.packet_type == int(
        PacketType.END_OF_REFERENCE_GROUP
    )
    assert records[5].header.packet_type == int(PacketType.END_OF_STREAM)

    # REFERENCE_GROUP_HEADER (0x10) payload (LE per spec §1.7):
    #   uint16 uri_len + uri[uri_len] + uint32 chromosome_count
    #   + uint64 total_bases + md5_hex[32]
    payload = records[1].payload
    off = 0
    (uri_len,) = struct.unpack_from("<H", payload, off)
    off += 2
    assert payload[off:off + uri_len] == b"fixture-test-ref-v1"
    off += uri_len
    (chrom_count,) = struct.unpack_from("<I", payload, off)
    off += 4
    assert chrom_count == 2
    (total_bases,) = struct.unpack_from("<Q", payload, off)
    off += 8
    assert total_bases == 10  # 4 + 6
    md5_hex = payload[off:off + 32].decode("ascii")
    off += 32
    assert md5_hex == ref.md5.hex()
    assert off == len(payload)

    # REFERENCE_CHROMOSOME (0x11) chr1 — uncompressed (length 4 < 4096).
    p1 = records[2].payload
    off = 0
    (n1,) = struct.unpack_from("<H", p1, off)
    off += 2
    assert p1[off:off + n1] == b"chr1"
    off += n1
    (seq_len1,) = struct.unpack_from("<Q", p1, off)
    off += 8
    assert seq_len1 == 4
    enc1 = p1[off]
    off += 1
    assert enc1 == 0, "encoding=0 raw for short chromosome"
    (dlen1,) = struct.unpack_from("<I", p1, off)
    off += 4
    assert dlen1 == 4
    assert p1[off:off + dlen1] == b"ACGT"
    off += dlen1
    assert off == len(p1)
    # au_sequence carries the 0-based chromosome index.
    assert records[2].header.au_sequence == 0

    # REFERENCE_CHROMOSOME (0x11) chr2 — also uncompressed (6 < 4096).
    p2 = records[3].payload
    off = 0
    (n2,) = struct.unpack_from("<H", p2, off)
    off += 2
    assert p2[off:off + n2] == b"chr2"
    off += n2
    (seq_len2,) = struct.unpack_from("<Q", p2, off)
    off += 8
    assert seq_len2 == 6
    enc2 = p2[off]
    off += 1
    assert enc2 == 0
    (dlen2,) = struct.unpack_from("<I", p2, off)
    off += 4
    assert dlen2 == 6
    assert p2[off:off + dlen2] == b"TTTTCC"
    off += dlen2
    assert off == len(p2)
    assert records[3].header.au_sequence == 1

    # END_OF_REFERENCE_GROUP (0x12) payload: uint32 chromosome_count.
    eor = records[4].payload
    (eor_count,) = struct.unpack_from("<I", eor, 0)
    assert eor_count == 2
    assert len(eor) == 4


def test_write_reference_group_zlib_path_above_threshold() -> None:
    """A >= 4 KiB chromosome rides as encoding=1 (zlib)."""
    # 8 KiB of cycling ACGT bytes — large enough to force the zlib
    # path AND varied enough to compress non-trivially.
    alphabet = b"ACGT"
    big = bytes(alphabet[i & 3] for i in range(8192))
    assert len(big) == 8192

    ref = ReferenceImport(
        uri="ref-large",
        chromosomes=["chrL"],
        sequences=[big],
    )

    out = io.BytesIO()
    with TransportWriter(out) as w:
        w.write_stream_header(
            format_version="1.2",
            title="ref-test",
            isa_investigation="isa",
            features=[],
            n_datasets=0,
        )
        w.write_reference_group(ref)
        w.write_end_of_stream()

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    assert len(records) == 5
    assert records[2].header.packet_type == int(PacketType.REFERENCE_CHROMOSOME)

    p1 = records[2].payload
    off = 0
    (n1,) = struct.unpack_from("<H", p1, off)
    off += 2
    assert p1[off:off + n1] == b"chrL"
    off += n1
    (seq_len1,) = struct.unpack_from("<Q", p1, off)
    off += 8
    assert seq_len1 == 8192
    enc1 = p1[off]
    off += 1
    assert enc1 == 1, "encoding=1 zlib for >= 4096 bytes"
    (dlen1,) = struct.unpack_from("<I", p1, off)
    off += 4
    assert dlen1 < 8192, "zlib should compress repeating ACGT bytes"
    data1 = p1[off:off + dlen1]
    off += dlen1
    assert off == len(p1)

    # Round-trip inflate and verify the bytes match the source.
    decoded = zlib.decompress(data1)
    assert len(decoded) == 8192
    assert decoded == big
