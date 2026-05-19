"""
ttio.tools.workbench_cli -- `ttio` umbrella command.

Implements the spec section 8.2 CLI shape verbatim. Subcommands:

    ttio login    --server <url> [--username U --password P --totp T |
                                    --staging-root <path>]
    ttio upload   --file <path> --server <url> --project P
                  [--container-uri uri:tio:...] [--token T | --staging-root <path>]
    ttio download --server <url> --container <uri> [--filter k=v]...
                  [--output <path>] [--max-au N]
                  [--token T | --staging-root <path>]
    ttio stream   --server <url> --container <uri> [--filter k=v]...
                  --output <.tis path>
                  [--token T | --staging-root <path>]
    ttio inspect  --server <url> --container <uri>
                  [--token T | --staging-root <path>]
    ttio encode   --input <path>... --format <fmt> --output <path> ...
                  -- delegates to ttio.tools.{fastq,fasta}_import_cli
    ttio export   --input <path> --layer <name> --format <fmt> --output <path>
                  -- delegates to ttio.tools.{fastq,fasta}_export_cli

    ttio query / submit / jobs / sessions / cohorts
                  -- W3/W4 surfaces; today these print a clear
                  "available in W3" / "W4" message + exit 2.

The umbrella delegates to the SDK (`ttio.workbench.connect`,
`UploadClient`, `DownloadClient`) for everything network-facing.
Format-specific CLIs stay reachable via their existing import
paths; the umbrella `encode`/`export` subcommands dispatch by
detected format.

Exit codes:
    0  success
    1  remote / SDK failure (auth, transport, server-side error)
    2  usage error (bad CLI flags, future-milestone subcommand)
    3  local file / format error (input missing, unknown format)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from typing import Iterable, Optional

import ttio
from ttio.workbench import (
    BearerAuth,
    BootstrapAdminAuth,
    OIDCAuth,           # noqa: F401 -- exposed via top-level for spec parity
    PasswordTotpAuth,
    Session,
    WorkbenchAuthError,
    WorkbenchClient,
    parse_filter_kv,
)
from ttio.workbench.transport.errors import TransportError
from ttio.workbench.transport.handshake import OutputModeLiteral


PROG = "ttio"
__version__ = ttio.__version__


# ----------------------------------------------------------------
# auth resolution shared across subcommands
# ----------------------------------------------------------------

def _resolve_auth(args) -> ttio.workbench.AuthProvider:
    """Pick the right `AuthProvider` from CLI flags.

    Mutually exclusive: `--token` + owner OR `--staging-root` OR
    `--username` + `--password` + `--totp`. The argparse layer
    rejects no-auth-mode-given; here we just map the flags to
    a provider.
    """
    if args.token:
        if not args.owner:
            print(
                f"{PROG}: --token requires --owner so the daemon can "
                f"attribute uploads correctly", file=sys.stderr)
            raise SystemExit(2)
        return BearerAuth(token=args.token, username_=args.owner)
    if args.staging_root:
        return BootstrapAdminAuth(staging_root=args.staging_root)
    if args.username and args.password and args.totp:
        return PasswordTotpAuth(
            username_=args.username,
            password=args.password,
            totp=args.totp,
        )
    print(
        f"{PROG}: pick exactly one auth mode: --token + --owner, "
        f"--staging-root, or --username + --password + --totp",
        file=sys.stderr)
    raise SystemExit(2)


def _add_server_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--server", required=True,
                    help='Workbench server URL, e.g. '
                         '"wss://biobank.example.com:8443/transport". '
                         '"ws://"/"http://" accepted for development; '
                         '"host:port" defaults to ws://host:port.')


def _add_auth_args(p: argparse.ArgumentParser) -> None:
    g = p.add_argument_group("auth (pick exactly one mode)")
    g.add_argument("--token",
                    help="Pre-acquired bearer (ttiowbs_...). Pair with --owner.")
    g.add_argument("--owner",
                    help="Username to attribute uploads to. Required with --token.")
    g.add_argument("--staging-root",
                    help='Daemon staging-root path containing '
                         '"bootstrap-credentials.json". Smoke / dev only.')
    g.add_argument("--username", help="Interactive login username.")
    g.add_argument("--password", help="Interactive login password.")
    g.add_argument("--totp",     help="Current RFC 6238 TOTP code.")


# ----------------------------------------------------------------
# `ttio login`
# ----------------------------------------------------------------

def cmd_login(args) -> int:
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)
    out = {
        "token":        client.session.token,
        "username":     client.session.username,
        "user_id":      client.session.user_id,
        "capabilities": sorted(client.session.capabilities),
        "projects":     list(client.session.projects),
        "expires_at":   client.session.expires_at,
        "provider":     client.session.provider,
        "session_id":   client.session.session_id,
    }
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


# ----------------------------------------------------------------
# `ttio upload`
# ----------------------------------------------------------------

def cmd_upload(args) -> int:
    if not os.path.isfile(args.file):
        print(f"{PROG}: --file not found: {args.file}", file=sys.stderr)
        return 3
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)

    with open(args.file, "rb") as f:
        data = f.read()

    uri = args.container_uri or f"uri:tio:{os.path.basename(args.file)}"

    async def _run():
        return await client.upload_bytes(
            project=args.project, container_uri=uri, data=data)

    try:
        result = asyncio.run(_run())
    except TransportError as e:
        print(f"{PROG}: upload failed: {e}", file=sys.stderr)
        return 1

    print(json.dumps({
        "container_uri":          result.container_uri,
        "last_acked_au_sequence": result.last_acked_au_sequence,
        "resume_handle":          result.resume_handle,
        "uploaded_bytes":         len(data),
    }, indent=2, sort_keys=True))
    return 0


# ----------------------------------------------------------------
# `ttio download` -- materialise to .tio
# ----------------------------------------------------------------

def cmd_download(args) -> int:
    return _download_impl(args, output_mode=OutputModeLiteral.BINARY.value,
                            output_required=True)


# ----------------------------------------------------------------
# `ttio stream` -- save the raw .tis bytes (no materialisation)
# ----------------------------------------------------------------

def cmd_stream(args) -> int:
    # Same wire as download; the only delta is the user signalled
    # they want the raw .tis bytes on disk rather than a
    # materialised .tio. Today both code paths write the received
    # bytes verbatim -- the workbench server emits the .tis stream
    # and the client never materialises locally in v1.0 (W6's
    # materialise() helper handles that). `stream` is the operator-
    # honest verb for "save the .tis as-is".
    return _download_impl(args, output_mode=OutputModeLiteral.BINARY.value,
                            output_required=True, stream_mode=True)


def _download_impl(args, *, output_mode: str, output_required: bool,
                     stream_mode: bool = False) -> int:
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)

    try:
        filters = parse_filter_kv(args.filter or [])
    except ValueError as e:
        print(f"{PROG}: {e}", file=sys.stderr)
        return 2

    async def _run():
        return await client.download_bytes(
            container_uri=args.container,
            filters=filters or None,
            output_mode=output_mode,
            max_au=args.max_au or 0,
        )

    try:
        result = asyncio.run(_run())
    except TransportError as e:
        print(f"{PROG}: download failed: {e}", file=sys.stderr)
        return 1

    if output_required and not args.output:
        print(f"{PROG}: --output is required", file=sys.stderr)
        return 2
    if args.output:
        with open(args.output, "wb") as f:
            f.write(result.payload)
    print(json.dumps({
        "container_uri":      result.container_uri,
        "bytes":              len(result.payload),
        "binary_frame_count": result.binary_frame_count,
        "stats_frame_count":  len(result.stats_frames),
        "output_path":        args.output,
        "stream_mode":        stream_mode,
    }, indent=2, sort_keys=True))
    return 0


# ----------------------------------------------------------------
# `ttio inspect` -- container manifest via stats-only download
# ----------------------------------------------------------------

def cmd_inspect(args) -> int:
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)

    async def _run():
        return await client.download_bytes(
            container_uri=args.container,
            filters=None,
            output_mode=OutputModeLiteral.STATS_ONLY.value,
            max_au=args.max_au or 0,
        )

    try:
        result = asyncio.run(_run())
    except TransportError as e:
        print(f"{PROG}: inspect failed: {e}", file=sys.stderr)
        return 1

    print(json.dumps({
        "container_uri":      result.container_uri,
        "stats_frame_count":  len(result.stats_frames),
        "stats_frames":       result.stats_frames,
        "terminal_frame":     result.terminal_frame,
    }, indent=2, sort_keys=True))
    return 0


# ----------------------------------------------------------------
# `ttio encode` / `ttio export` -- dispatch to existing CLIs
# ----------------------------------------------------------------

def cmd_encode(args) -> int:
    # The encode path stays a thin dispatch into the existing
    # format-specific CLIs. We detect the format from --format
    # (required by the spec section 8.2 sample) and delegate
    # argument handling to that CLI's existing argparse, passing
    # the remaining args through.
    fmt = args.format.lower()
    if fmt == "fastq":
        from ttio.tools import fastq_import_cli as backend
    elif fmt == "fasta":
        from ttio.tools import fasta_import_cli as backend
    else:
        print(
            f"{PROG}: unsupported --format {fmt!r}; v1.0 supports "
            f"fastq | fasta. Additional formats (BAM/CRAM, VCF, "
            f"mzML, IDAT, OME-TIFF, etc.) land in W6.",
            file=sys.stderr)
        return 3
    # Pass the spec-shaped flags through to the backend CLI. The
    # backends have their own argparse so we hand off via sys.argv
    # substitution (cleaner than building a positional argv).
    return _delegate_to(backend, ["--input"] + args.input +
                          ["--output", args.output] +
                          (args.extra or []))


def cmd_export(args) -> int:
    fmt = args.format.lower()
    if fmt == "fastq":
        from ttio.tools import fastq_export_cli as backend
    elif fmt == "fasta":
        from ttio.tools import fasta_export_cli as backend
    else:
        print(
            f"{PROG}: unsupported --format {fmt!r}; v1.0 supports "
            f"fastq | fasta. Additional formats land in W6.",
            file=sys.stderr)
        return 3
    return _delegate_to(backend, ["--input", args.input,
                                     "--output", args.output,
                                     "--layer", args.layer] +
                          (args.extra or []))


def _delegate_to(module, argv: list[str]) -> int:
    """Run a format-specific CLI's `main()` with a synthetic argv.

    Each CLI module exposes `main(argv=None)`. We set sys.argv so
    the backend's argparse sees the substituted args; restore on
    finish.
    """
    saved = sys.argv[:]
    try:
        sys.argv = [module.__name__] + argv
        result = module.main()
        return int(result) if result is not None else 0
    finally:
        sys.argv = saved


# ----------------------------------------------------------------
# W3 / W4 placeholder subcommands
# ----------------------------------------------------------------

def cmd_w3_placeholder(args) -> int:
    print(
        f"{PROG}: `{args.subcommand}` is a W3 surface (cohort + "
        f"pipeline + jobs). The v1.0 client ships W1 + W2 (auth + "
        f"transport + CLI umbrella + SDK foundation). See "
        f"docs/workbench-client-workplan.md.",
        file=sys.stderr)
    return 2


def cmd_w4_placeholder(args) -> int:
    print(
        f"{PROG}: `{args.subcommand}` is a W4 surface (interactive "
        f"sessions). The v1.0 client ships W1 + W2. See "
        f"docs/workbench-client-workplan.md.",
        file=sys.stderr)
    return 2


# ----------------------------------------------------------------
# argparse plumbing
# ----------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog=PROG,
        description="TTI-O Workbench client. Spec section 8.2 CLI "
                     "surface. See `ttio <subcommand> --help` for "
                     "per-subcommand options.")
    p.add_argument("--version", action="version", version=f"{PROG} {__version__}")

    sub = p.add_subparsers(dest="subcommand", required=True,
                            metavar="<subcommand>")

    # login
    pl = sub.add_parser(
        "login",
        help="Resolve credentials, print the auth response JSON.")
    _add_server_args(pl)
    _add_auth_args(pl)
    pl.set_defaults(func=cmd_login)

    # upload
    pu = sub.add_parser(
        "upload",
        help="Upload a .tio container via WS .tis transport.")
    _add_server_args(pu)
    _add_auth_args(pu)
    pu.add_argument("--file", required=True,
                     help=".tio container to upload.")
    pu.add_argument("--project", required=True,
                     help="Project the container belongs to.")
    pu.add_argument("--container-uri",
                     help="Container URI on the server "
                          "(e.g. uri:tio:demo-001). Defaults to "
                          "uri:tio:<basename(file)>.")
    pu.set_defaults(func=cmd_upload)

    # download
    pd = sub.add_parser(
        "download",
        help="Download a container (binary mode); save as .tio.")
    _add_server_args(pd)
    _add_auth_args(pd)
    pd.add_argument("--container", required=True,
                     help="Container URI to download.")
    pd.add_argument("--filter", action="append",
                     help="Selective-access predicate `k=v`; "
                          "repeatable. Allowed keys: ms_level, "
                          "polarity, retention_time_min, "
                          "retention_time_max, precursor_mz_min, "
                          "precursor_mz_max, precursor_charge, "
                          "max_au.")
    pd.add_argument("--output", required=True,
                     help="Write the downloaded bytes here.")
    pd.add_argument("--max-au", type=int, default=0,
                     help="Cap emitted AU count (0 = no cap).")
    pd.set_defaults(func=cmd_download)

    # stream
    ps = sub.add_parser(
        "stream",
        help="Download as a raw .tis stream (no materialisation).")
    _add_server_args(ps)
    _add_auth_args(ps)
    ps.add_argument("--container", required=True)
    ps.add_argument("--filter", action="append")
    ps.add_argument("--output", required=True)
    ps.add_argument("--max-au", type=int, default=0)
    ps.set_defaults(func=cmd_stream)

    # inspect
    pi = sub.add_parser(
        "inspect",
        help="Stats-only download; print per-AU summary frames.")
    _add_server_args(pi)
    _add_auth_args(pi)
    pi.add_argument("--container", required=True)
    pi.add_argument("--max-au", type=int, default=0)
    pi.set_defaults(func=cmd_inspect)

    # encode
    pe = sub.add_parser(
        "encode",
        help="Encode source files into a local .tio container.")
    pe.add_argument("--input", nargs="+", required=True,
                     help="Source file(s).")
    pe.add_argument("--format", required=True,
                     help="Source-file format. v1.0 supports "
                          "fastq | fasta; W6 adds the spec section "
                          "4.2-4.7 entries.")
    pe.add_argument("--output", required=True,
                     help="Target .tio path.")
    pe.add_argument("--extra", nargs=argparse.REMAINDER,
                     help="Extra args forwarded to the format-specific CLI.")
    pe.set_defaults(func=cmd_encode)

    # export
    px = sub.add_parser(
        "export",
        help="Export a layer from a .tio container to a source format.")
    px.add_argument("--input", required=True,
                     help="Source .tio container.")
    px.add_argument("--layer", required=True,
                     help="Layer name to export.")
    px.add_argument("--format", required=True,
                     help="Target export format; v1.0 supports "
                          "fastq | fasta. W6 adds the spec section "
                          "4.2-4.7 entries.")
    px.add_argument("--output", required=True)
    px.add_argument("--extra", nargs=argparse.REMAINDER)
    px.set_defaults(func=cmd_export)

    # W3 / W4 placeholders (registered so help renders them, but
    # each surfaces the milestone deferral on invocation).
    for name in ("query", "submit", "jobs", "cohorts"):
        sp = sub.add_parser(name, help=f"(W3) -- not yet implemented.")
        sp.set_defaults(func=cmd_w3_placeholder)
    for name in ("sessions",):
        sp = sub.add_parser(name, help=f"(W4) -- not yet implemented.")
        sp.set_defaults(func=cmd_w4_placeholder)

    return p


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except WorkbenchAuthError as e:
        print(f"{PROG}: auth failed: {e}", file=sys.stderr)
        return 1
    except SystemExit:
        raise
    except KeyboardInterrupt:
        print(f"{PROG}: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
