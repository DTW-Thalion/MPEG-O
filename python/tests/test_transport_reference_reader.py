"""Stage 1 / Task 2.3 (transport-spec v0.11): exercise
:meth:`TransportReader.read_to_dataset` on a stream that carries only
REFERENCE_GROUP_HEADER (0x10) + REFERENCE_CHROMOSOME (0x11) +
END_OF_REFERENCE_GROUP (0x12) packets and verify the decoded
:class:`ReferenceImport` round-trips byte-for-byte through the
materialised :class:`SpectralDataset`.

Python parity for Java's ``TransportReaderReferenceTest`` (commit
``7f3dec46``). Exercises both encoding=0 (raw, < 4 KiB) and
encoding=1 (zlib, >= 4 KiB) paths via two chromosomes of contrasting
size.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
from pathlib import Path

from ttio.genomic.reference_import import ReferenceImport
from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import TransportReader, TransportWriter


def _build_reference() -> ReferenceImport:
    """Build a ReferenceImport that forces BOTH encoding paths:
    one chromosome below the 4 KiB threshold (encoding=0 raw) and
    one above it (encoding=1 zlib)."""
    alphabet = b"ACGT"
    # 8 KiB chromosome — forces encoding=1.
    big = bytes(alphabet[i & 3] for i in range(8192))
    # 12 B chromosome — encoding=0.
    return ReferenceImport(
        uri="reader-test-ref-v1",
        chromosomes=["chrA", "chrB"],
        sequences=[b"ACGTACGTACGT", big],
    )


def test_read_to_dataset_decodes_reference_group_round_trip(
    tmp_path: Path,
) -> None:
    """A wire stream carrying StreamHeader + ReferenceGroup + EOS
    materialises into a ``.tio`` whose ``references`` accessor returns
    a :class:`ReferenceImport` byte-equal to the source."""
    src_ref = _build_reference()

    # Encode: StreamHeader -> RefGroupHeader -> N x RefChromosome
    # -> EndOfRefGroup -> EndOfStream.
    buf = io.BytesIO()
    with TransportWriter(buf) as w:
        w.write_stream_header(
            format_version="1.2",
            title="reader-ref-test",
            isa_investigation="ISA-T2-3",
            features=[],
            n_datasets=0,
        )
        w.write_reference_group(src_ref)
        w.write_end_of_stream()

    # Decode the stream and materialise to a .tio.
    out_path = tmp_path / "rt.tio"
    with TransportReader(io.BytesIO(buf.getvalue())) as r:
        ds = r.read_to_dataset(output_path=out_path)
        ds.close()

    # Re-open the materialised .tio and verify the reference round-trips.
    with SpectralDataset.open(out_path) as ds_back:
        refs = ds_back.references
        assert list(refs.keys()) == [src_ref.uri], (
            f"expected single reference {src_ref.uri!r}, got "
            f"{list(refs.keys())!r}"
        )
        rt_ref = refs[src_ref.uri]

    # Same uri, chromosomes (alphabetically sorted on disk), bytes,
    # totals, and MD5.
    assert rt_ref.uri == src_ref.uri
    assert sorted(rt_ref.chromosomes) == sorted(src_ref.chromosomes)
    for name in src_ref.chromosomes:
        assert rt_ref.chromosome(name) == src_ref.chromosome(name), (
            f"chromosome {name!r} byte content mismatch"
        )
    assert rt_ref.total_bases == src_ref.total_bases
    assert rt_ref.md5 == src_ref.md5
    assert len(rt_ref.md5) == 16
