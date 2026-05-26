"""Encode a .tio file as a .tis transport stream ().

Parallel to Java {@code global.thalion.ttio.tools.TransportEncodeCli}
and ObjC {@code TtioTransportEncode}.

Usage:
    python -m ttio.tools.transport_encode_cli <input.tio> <output.tis>
        [--checksum] [--bulk] [--image-processed]
"""
from __future__ import annotations

import argparse
import sys

from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import (
    TRANSPORT_V0_11_FEATURE,
    TransportWriter,
    file_to_transport,
)


def _encode_image_processed(input_path: str, output_path: str) -> None:
    """Stage 5 / Task 5.6 (Deferral 1): emit a v0.11 stream carrying
    only the input's MSImage, encoded via ``write_image_processed``
    (opt-in sparse wire mode) instead of ``write_image``. Used by the
    cross-language conformance harness to exercise the processed-mode
    wire shape end-to-end. Other content on the input is intentionally
    ignored — this CLI flag is a focused affordance for the
    MS_IMAGE_PROCESSED accessor matrix cell, not a general-purpose
    encode override."""
    with SpectralDataset.open(input_path) as ds:
        with open(output_path, "wb") as out:
            with TransportWriter(out) as w:
                w.write_stream_header(
                    format_version="1.2",
                    title=ds.title or "",
                    isa_investigation=ds.isa_investigation_id or "",
                    features=[TRANSPORT_V0_11_FEATURE],
                    n_datasets=0,
                )
                w.write_image_processed(ds.image)
                w.write_end_of_stream()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Encode a .tio file as an TTI-O transport stream."
    )
    parser.add_argument("input", help="path to a .tio file")
    parser.add_argument("output", help="path to write the .tis stream")
    parser.add_argument("--checksum", action="store_true",
                        help="emit per-packet CRC-32C checksums")
    parser.add_argument(
        "--bulk", action="store_true",
        help="enable Phase 2c-T bulk mode: ship verbatim v2 codec "
             "blobs (mate_info, read_names, refdiff_v2) for genomic "
             "runs so transport round-trips preserve SAM mate "
             "sentinels (=, '') byte-for-byte. No effect on "
             "MS-only inputs.",
    )
    parser.add_argument(
        "--image-processed", action="store_true",
        help="Stage 5 / Task 5.6 (Deferral 1): emit the input's "
             "MSImage via write_image_processed (sparse wire mode) "
             "in place of write_image (continuous). Used by the "
             "cross-language MS_IMAGE_PROCESSED accessor matrix cell. "
             "Other dataset content is ignored when this flag is set.",
    )
    args = parser.parse_args(argv)
    if args.image_processed:
        _encode_image_processed(args.input, args.output)
    else:
        file_to_transport(
            args.input, args.output,
            use_checksum=args.checksum,
            use_bulk_mode=args.bulk,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
