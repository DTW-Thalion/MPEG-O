"""
Cross-language byte-equivalence tests for the workbench handshake.

The Python and Java workbench clients are both expected to produce
the same exact JSON bytes for the same handshake inputs. The Java
side asserts the literal in `WorkbenchHandshakeTest.uploadHandshakeMinimal`;
this file asserts the same literal here. If either test drifts, both
fail -- the literals are the cross-language anchor.
"""
from __future__ import annotations

import json

from ttio.workbench.transport.handshake import (
    build_download_handshake,
    build_upload_handshake,
)


# These are the exact strings the Java
# `WorkbenchHandshakeTest.{uploadHandshakeMinimal, downloadHandshakeMinimal}`
# methods assert on. Pinning both sides catches drift early.
EXPECTED_UPLOAD_MINIMAL = (
    '{"type":"handshake",'
    '"owner":"alice",'
    '"project":"alpha",'
    '"container_uri":"uri:tio:demo-001"}'
)

EXPECTED_DOWNLOAD_MINIMAL = (
    '{"type":"handshake",'
    '"mode":"download",'
    '"container_uri":"uri:tio:demo-001",'
    '"output_mode":"binary"}'
)


def test_upload_handshake_byte_equivalent_to_java():
    dict_form = build_upload_handshake(
        owner="alice", project="alpha", container_uri="uri:tio:demo-001")
    wire = json.dumps(dict_form, separators=(",", ":"))
    assert wire == EXPECTED_UPLOAD_MINIMAL


def test_download_handshake_byte_equivalent_to_java():
    dict_form = build_download_handshake(container_uri="uri:tio:demo-001")
    wire = json.dumps(dict_form, separators=(",", ":"))
    assert wire == EXPECTED_DOWNLOAD_MINIMAL
