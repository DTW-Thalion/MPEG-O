"""
Unit tests for the W2 `ttio` CLI umbrella.

Tests argparse plumbing + the auth-mode resolver. Subcommand
network paths (login/upload/download/stream/inspect) are
integration-tested in a follow-up; here we cover the structural
contract: every spec section 8.2 verb is registered, helpful
errors fire for bad flags, and the W3/W4 placeholder
subcommands exit cleanly with the milestone deferral message.
"""
from __future__ import annotations

import io
import json

import pytest

from ttio.tools.workbench_cli import build_parser, main


# ---------------------------------------------------- argparse surface

def test_help_lists_every_spec_subcommand(capsys):
    # Spec section 8.2 names the verbs: encode, upload, download,
    # stream, export, plus the auth-related login + the
    # control-plane query/submit/jobs/sessions/cohorts. The W2
    # parser must register all of them so `ttio --help` doesn't
    # mislead.
    with pytest.raises(SystemExit):
        main(["--help"])
    out = capsys.readouterr().out
    for verb in (
        "login", "upload", "download", "stream", "inspect",
        "encode", "export",
        "query", "submit", "jobs", "cohorts", "sessions",
    ):
        assert verb in out, f"missing subcommand {verb!r} from --help"


def test_subcommand_required(capsys):
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args([])


def test_version_flag(capsys):
    with pytest.raises(SystemExit):
        main(["--version"])
    out = capsys.readouterr().out
    assert out.startswith("ttio ")


# ---------------------------------------------------- per-subcommand help

@pytest.mark.parametrize("subcommand", [
    "login", "upload", "download", "stream", "inspect", "encode", "export",
])
def test_subcommand_help(capsys, subcommand):
    with pytest.raises(SystemExit):
        main([subcommand, "--help"])
    out = capsys.readouterr().out
    assert subcommand in out


# ---------------------------------------------------- W3 / W4 dispatch

@pytest.mark.parametrize("subcommand", ["query", "submit", "jobs", "cohorts"])
def test_w3_subcommands_are_registered(capsys, subcommand):
    # W3 promotes these from W2-era placeholders to live
    # implementations. `--help` returns 0 and lists the
    # subcommand-specific flags (including --server, since they
    # all need auth + REST endpoint config).
    with pytest.raises(SystemExit):
        main([subcommand, "--help"])
    out = capsys.readouterr().out
    assert subcommand in out
    assert "--server" in out


def test_pipelines_subcommand_registered(capsys):
    with pytest.raises(SystemExit):
        main(["pipelines", "--help"])
    out = capsys.readouterr().out
    assert "ls" in out and "register" in out and "get" in out


def test_provenance_surfaces_v1_deferral(capsys):
    # Provenance HTTP endpoint isn't exposed by the v1.0 server;
    # CLI surfaces a clear deferral message + exit 2.
    rc = main(["provenance"])
    assert rc == 2
    err = capsys.readouterr().err
    assert "v1.0" in err


def test_w4_sessions_subcommand_registered(capsys):
    # W4 promoted `sessions` from W3-era placeholder to live
    # implementation. `--help` returns 0 and lists the action
    # positional + the create/ls/attach flags.
    with pytest.raises(SystemExit):
        main(["sessions", "--help"])
    out = capsys.readouterr().out
    assert "sessions" in out
    assert "--server" in out
    assert "create" in out and "attach" in out and "terminate" in out


# ---------------------------------------------------- auth-mode resolver

def test_login_requires_auth_mode(capsys):
    # No --token, no --staging-root, no --username/--password/--totp.
    # argparse accepts (all optional individually); the resolver
    # surfaces "pick exactly one auth mode".
    with pytest.raises(SystemExit):
        main(["login", "--server", "ws://localhost:8443"])
    err = capsys.readouterr().err
    assert "auth mode" in err


def test_token_without_owner_rejected(capsys):
    with pytest.raises(SystemExit):
        main(["login",
              "--server", "ws://localhost:8443",
              "--token", "ttiowbs_abc"])
    err = capsys.readouterr().err
    assert "--token requires --owner" in err


def test_partial_password_totp_rejected(capsys):
    # Only --username given, no --password / --totp.
    with pytest.raises(SystemExit):
        main(["login",
              "--server", "ws://localhost:8443",
              "--username", "alice"])
    err = capsys.readouterr().err
    assert "auth mode" in err


# ---------------------------------------------------- filter flag plumbing

def test_download_filter_repeatable():
    parser = build_parser()
    args = parser.parse_args([
        "download",
        "--server", "ws://localhost:8443",
        "--token", "ttiowbs_abc", "--owner", "alice",
        "--container", "uri:tio:demo",
        "--filter", "ms_level=2",
        "--filter", "polarity=positive",
        "--output", "/tmp/out.tio",
    ])
    assert args.filter == ["ms_level=2", "polarity=positive"]
    assert args.container == "uri:tio:demo"
    assert args.output == "/tmp/out.tio"


def test_download_no_filter_is_fine():
    parser = build_parser()
    args = parser.parse_args([
        "download",
        "--server", "ws://localhost:8443",
        "--token", "ttiowbs_abc", "--owner", "alice",
        "--container", "uri:tio:demo",
        "--output", "/tmp/out.tio",
    ])
    assert args.filter is None


# ---------------------------------------------------- encode dispatch

def test_encode_unsupported_format_exits_3(capsys):
    rc = main([
        "encode",
        "--input", "in.bam",
        "--format", "bam",
        "--output", "out.tio",
    ])
    assert rc == 3
    err = capsys.readouterr().err
    assert "unsupported --format" in err
    assert "W6" in err  # points to the format-expansion milestone
