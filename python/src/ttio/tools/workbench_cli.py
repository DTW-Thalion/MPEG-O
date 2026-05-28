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
    """Handle ``ttio login`` — authenticate against a workbench server
    and emit the resulting session token + project list as JSON on
    stdout.

    Returns ``0`` on success; raises :class:`WorkbenchAuthError` (caught
    by :func:`main` for exit code ``1``) when auth fails.
    """
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
    """Handle ``ttio upload`` — push a local ``.tio`` file to a
    workbench project and report the new container URI + uploaded
    byte count as JSON on stdout.

    Returns ``0`` on success, ``1`` on transport failure, ``3`` when
    the local input file is missing.
    """
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
    """Handle ``ttio download`` — materialise a remote container to a
    local ``.tio`` file. Thin wrapper around :func:`_download_impl`
    in binary, output-required mode.
    """
    return _download_impl(args, output_mode=OutputModeLiteral.BINARY.value,
                            output_required=True)


# ----------------------------------------------------------------
# `ttio stream` -- save the raw .tis bytes (no materialisation)
# ----------------------------------------------------------------

def cmd_stream(args) -> int:
    """Handle ``ttio stream`` — save a remote container's raw ``.tis``
    bytes verbatim, without local materialisation. Same wire as
    :func:`cmd_download`; the only delta is the user signals they
    want the ``.tis`` stream as-is.
    """
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
    """Handle ``ttio inspect`` — request a stats-only download for the
    container and print every stats frame plus the terminal frame as
    JSON on stdout. No data bytes are written to disk.

    Returns ``0`` on success, ``1`` on transport failure.
    """
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
    """Handle ``ttio encode`` — convert one or more input files of a
    given source format into a ``.tio`` container.

    FASTA and FASTQ delegate to their richer dedicated CLIs (which
    surface reference/unaligned modes and PHRED options); other
    formats dispatch through :mod:`ttio.importers.registry`.

    Returns ``0`` on success, ``2`` on tool failure, ``3`` when the
    requested format is unsupported.
    """
    # FASTA / FASTQ keep their richer dedicated CLIs (reference vs.
    # unaligned modes, PHRED options); everything else dispatches
    # through the format registry, which mirrors the GUI's
    # ImportFormatRegistry. The format set is the registry + the two
    # CLI-delegated formats.
    from ttio.importers import registry
    fmt = registry.normalize(args.format)
    if fmt == "fastq":
        from ttio.tools import fastq_import_cli as backend
        return _delegate_to(backend, ["--input"] + args.input +
                              ["--output", args.output] + (args.extra or []))
    if fmt == "fasta":
        from ttio.tools import fasta_import_cli as backend
        return _delegate_to(backend, ["--input"] + args.input +
                              ["--output", args.output] + (args.extra or []))
    if registry.is_registry_format(fmt):
        try:
            registry.encode(fmt, args.input, args.output)
        except registry.UnknownFormatError:
            return _encode_unsupported(args.format)
        except Exception as e:  # importer/runtime-tool failure
            print(f"{PROG}: encode failed ({args.format}): {e}",
                  file=sys.stderr)
            return 2
        print(f"encoded {', '.join(args.input)} -> {args.output} "
              f"(format {args.format})")
        return 0
    return _encode_unsupported(args.format)


def _encode_unsupported(fmt: str) -> int:
    from ttio.importers import registry
    supported = ", ".join(registry.supported_encode_formats())
    print(
        f"{PROG}: unsupported --format {fmt!r}. Supported: {supported}.",
        file=sys.stderr)
    return 3


def cmd_export(args) -> int:
    """Handle ``ttio export`` — emit one layer of a ``.tio`` container
    in a supported external format.

    FASTA and FASTQ delegate to their richer dedicated CLIs (which
    surface line-width / PHRED options); other formats dispatch
    through :mod:`ttio.exporters.registry`.

    Returns ``0`` on success, ``2`` on tool failure, ``3`` when the
    requested format is unsupported.
    """
    # FASTA / FASTQ keep their richer dedicated CLIs (reference vs.
    # run modes, line-width / PHRED options); everything else
    # dispatches through the export registry.
    from ttio.exporters import registry
    fmt = registry.normalize(args.format)
    if fmt == "fastq":
        from ttio.tools import fastq_export_cli as backend
        return _delegate_to(backend, ["--input", args.input,
                                       "--output", args.output,
                                       "--layer", args.layer] + (args.extra or []))
    if fmt == "fasta":
        from ttio.tools import fasta_export_cli as backend
        return _delegate_to(backend, ["--input", args.input,
                                       "--output", args.output,
                                       "--layer", args.layer] + (args.extra or []))
    if registry.is_registry_format(fmt):
        try:
            registry.export(fmt, args.input, args.layer, args.output,
                            **_parse_export_opts(args.extra))
        except registry.UnknownFormatError:
            return _export_unsupported(args.format)
        except Exception as e:  # exporter / runtime-tool / missing-layer failure
            print(f"{PROG}: export failed ({args.format}): {e}", file=sys.stderr)
            return 2
        print(f"exported {args.input} -> {args.output} (format {args.format})")
        return 0
    return _export_unsupported(args.format)


def _parse_export_opts(extra) -> dict:
    """Pull recognised key/value options out of `--extra` (e.g.
    `--reference <fasta>` for CRAM)."""
    opts: dict = {}
    if not extra:
        return opts
    it = iter(extra)
    for tok in it:
        if tok == "--reference":
            opts["reference"] = next(it, None)
    return opts


def _export_unsupported(fmt: str) -> int:
    from ttio.exporters import registry
    supported = ", ".join(registry.supported_export_formats())
    print(
        f"{PROG}: unsupported --format {fmt!r}. Supported: {supported}.",
        file=sys.stderr)
    return 3


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
# W3 subcommands: query / submit / jobs / pipelines / provenance
# ----------------------------------------------------------------

def _load_predicate_json(args) -> dict | None:
    """Load the predicate JSON from --predicate-json (inline) or
    --predicate-file (path)."""
    if args.predicate_json and args.predicate_file:
        print(f"{PROG}: pass --predicate-json OR --predicate-file, not both",
              file=sys.stderr)
        return None
    if args.predicate_file:
        with open(args.predicate_file, "r", encoding="utf-8") as f:
            return json.load(f)
    if args.predicate_json:
        return json.loads(args.predicate_json)
    return None


def cmd_query(args) -> int:
    """Handle ``ttio query`` — run a cohort query against a workbench
    server and emit the JSON response.

    The predicate is sourced from ``--predicate-json`` or
    ``--predicate-file``; ``--no-predicate`` opts out of the predicate
    requirement (used for unbounded counts). The optional
    ``--count-only`` flag routes through the ``preview-count``
    endpoint instead of the full cohort query.

    Returns ``0`` on success, ``1`` on remote failure, ``2`` on bad
    predicate or missing required arguments.
    """
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)
    try:
        predicate_json = _load_predicate_json(args)
    except (OSError, ValueError) as e:
        print(f"{PROG}: bad predicate: {e}", file=sys.stderr)
        return 2
    if predicate_json is None and not args.no_predicate:
        print(f"{PROG}: --predicate-json or --predicate-file required "
              f"(use --no-predicate to query without one)", file=sys.stderr)
        return 2

    body: dict = {"select": args.select, "limit": args.limit}
    if predicate_json is not None:
        body["predicate"] = predicate_json
    if args.cursor:
        body["cursor"] = args.cursor

    from ttio.workbench._http import WorkbenchHttpError, http_json
    try:
        endpoint_args = {
            "host": client.host, "port": client.port,
            "scheme": client.http_scheme,
            "token": client.session.token,
        }
        path = "/v1/cohorts/preview-count" if args.count_only else "/v1/cohorts/query"
        status, resp = http_json("POST", path=path, body=body, **endpoint_args)
        if status != 200:
            raise WorkbenchHttpError(
                f"POST {path} failed: {status}", status=status, body=resp)
    except WorkbenchHttpError as e:
        print(f"{PROG}: query failed: {e}", file=sys.stderr)
        return 1
    print(json.dumps(resp, indent=2, sort_keys=True))
    return 0


def cmd_submit(args) -> int:
    """Handle ``ttio submit`` — enqueue a new pipeline job on a
    workbench server.

    Reads ``--inputs-file`` (required JSON map of pipeline-input
    names to container URIs) and the optional ``--params-file``
    (JSON map of free-form parameters), then calls
    :meth:`Jobs.submit`.

    Returns ``0`` on success, ``1`` on remote failure, ``2`` when
    the inputs/params files are unreadable or invalid JSON.
    """
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)
    try:
        with open(args.inputs_file, "r", encoding="utf-8") as f:
            inputs = json.load(f)
        params = {}
        if args.params_file:
            with open(args.params_file, "r", encoding="utf-8") as f:
                params = json.load(f)
    except (OSError, ValueError) as e:
        print(f"{PROG}: bad inputs/params file: {e}", file=sys.stderr)
        return 2

    try:
        job = client.jobs().submit(
            pipeline_id=args.pipeline,
            inputs=inputs,
            params=params or None,
        )
    except Exception as e:  # surface server-side errors verbatim
        print(f"{PROG}: submit failed: {e}", file=sys.stderr)
        return 1
    print(json.dumps({
        "job_id":      job.job_id,
        "pipeline_id": job.pipeline_id,
        "status":      job.status,
        "queued_at":   job.queued_at,
    }, indent=2, sort_keys=True))
    return 0


def cmd_jobs(args) -> int:
    """Handle ``ttio jobs`` — list, inspect, cancel, or stream events
    for pipeline jobs on a workbench server. Dispatches on
    ``args.action`` (one of ``ls``, ``status``, ``cancel``,
    ``events``).

    Returns ``0`` on success, ``1`` on remote failure, ``2`` for an
    unknown action.
    """
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)
    jobs = client.jobs()
    try:
        if args.action == "ls":
            rows = jobs.list(status_filter=args.status, limit=args.limit)
            print(json.dumps(
                [_job_to_dict(j) for j in rows],
                indent=2, sort_keys=True))
            return 0
        if args.action == "status":
            job = jobs.get(args.job_id)
            print(json.dumps(_job_to_dict(job), indent=2, sort_keys=True))
            return 0
        if args.action == "cancel":
            jobs.cancel(args.job_id)
            print(json.dumps({"job_id": args.job_id, "cancelled": True},
                             indent=2, sort_keys=True))
            return 0
        if args.action == "events":
            import asyncio
            async def _stream():
                async for ev in jobs.events(args.job_id):
                    print(json.dumps({
                        "event": ev.event, "data": dict(ev.data)},
                        sort_keys=True))
                    if (ev.event == "job.state"
                            and ev.data.get("status") in
                            ("completed", "failed", "cancelled")):
                        break
            asyncio.run(_stream())
            return 0
    except Exception as e:
        print(f"{PROG}: jobs {args.action} failed: {e}", file=sys.stderr)
        return 1
    print(f"{PROG}: unknown jobs action {args.action!r}", file=sys.stderr)
    return 2


def _job_to_dict(job) -> dict:
    return {
        "job_id":            job.job_id,
        "pipeline_id":       job.pipeline_id,
        "status":            job.status,
        "project":           job.project,
        "owner":             job.owner,
        "queued_at":         job.queued_at,
        "started_at":        job.started_at,
        "completed_at":      job.completed_at,
        "engine_identifier": job.engine_identifier,
        "exit_code":         job.exit_code,
        "error_message":     job.error_message,
    }


def cmd_pipelines(args) -> int:
    """Handle ``ttio pipelines`` — list, inspect, or register
    pipelines on a workbench server. Dispatches on ``args.action``
    (one of ``ls``, ``get``, ``register``).

    Returns ``0`` on success, ``1`` on remote failure, ``2`` for an
    unknown action.
    """
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)
    pipelines = client.pipelines()
    try:
        if args.action == "ls":
            rows = pipelines.list()
            print(json.dumps(
                [_pipeline_to_dict(p) for p in rows],
                indent=2, sort_keys=True))
            return 0
        if args.action == "get":
            pipeline = pipelines.get(args.pipeline_id)
            print(json.dumps(_pipeline_to_dict(pipeline),
                             indent=2, sort_keys=True))
            return 0
        if args.action == "register":
            with open(args.definition_file, "r", encoding="utf-8") as f:
                definition = f.read()
            pipeline = pipelines.register(
                identifier=args.identifier,
                version=args.version,
                project=args.project,
                definition=definition,
                engine_pin=args.engine_pin,
            )
            print(json.dumps(_pipeline_to_dict(pipeline),
                             indent=2, sort_keys=True))
            return 0
    except Exception as e:
        print(f"{PROG}: pipelines {args.action} failed: {e}",
              file=sys.stderr)
        return 1
    print(f"{PROG}: unknown pipelines action {args.action!r}", file=sys.stderr)
    return 2


def _pipeline_to_dict(p) -> dict:
    return {
        "pipeline_id":    p.pipeline_id,
        "identifier":     p.identifier,
        "version":        p.version,
        "project":        p.project,
        "owner":          p.owner,
        "engine_pin":     p.engine_pin,
        "definition":     p.definition,
        "inputs_schema":  dict(p.inputs_schema),
        "outputs_schema": dict(p.outputs_schema),
    }


def cmd_provenance(args) -> int:
    """Handle ``ttio provenance`` — provenance lookup for a container.

    Today this requires a server-side endpoint that is not exposed;
    the handler prints a workaround note (query the
    ``provenance_edges`` table directly) and returns ``2``.
    """
    print(
        f"{PROG}: `provenance` requires a server-side endpoint "
        f"(`GET /v1/containers/{{uri}}/provenance`) that is not yet "
        f"exposed. Workaround: query the `provenance_edges` table "
        f"directly.",
        file=sys.stderr)
    return 2


def cmd_sessions(args) -> int:
    """Handle ``ttio sessions`` — list, inspect, terminate, create, or
    attach interactive analysis sessions on a workbench server.
    Dispatches on ``args.action`` (one of ``ls``, ``status``,
    ``terminate``, ``create``, ``attach``).

    Returns ``0`` on success, ``1`` on remote failure, ``2`` for an
    unknown action.
    """
    auth = _resolve_auth(args)
    client = ttio.connect(args.server, auth=auth)
    sessions = client.sessions()
    try:
        if args.action == "ls":
            rows = sessions.list(status_filter=args.status, limit=args.limit)
            print(json.dumps([_session_to_dict(s) for s in rows],
                             indent=2, sort_keys=True))
            return 0
        if args.action == "status":
            session = sessions.get(args.session_id)
            print(json.dumps(_session_to_dict(session),
                             indent=2, sort_keys=True))
            return 0
        if args.action == "terminate":
            sessions.terminate(args.session_id)
            print(json.dumps({
                "session_id": args.session_id, "terminated": True},
                indent=2, sort_keys=True))
            return 0
        if args.action == "create":
            return _cmd_session_create(client, sessions, args)
        if args.action == "attach":
            return _cmd_session_attach(client, args)
    except Exception as e:
        print(f"{PROG}: sessions {args.action} failed: {e}",
              file=sys.stderr)
        return 1
    print(f"{PROG}: unknown sessions action {args.action!r}",
          file=sys.stderr)
    return 2


def _cmd_session_create(client, sessions, args) -> int:
    bind_mounts = None
    if args.bind_mount:
        bind_mounts = {}
        for spec in args.bind_mount:
            if ":" not in spec:
                print(f"{PROG}: --bind-mount expects host:container, got {spec!r}",
                      file=sys.stderr)
                return 2
            host, container = spec.split(":", 1)
            bind_mounts[host] = container
    env = None
    if args.env:
        env = {}
        for spec in args.env:
            if "=" not in spec:
                print(f"{PROG}: --env expects KEY=VALUE, got {spec!r}",
                      file=sys.stderr)
                return 2
            k, v = spec.split("=", 1)
            env[k] = v
    command = args.command if args.command else None

    session = sessions.create(
        project=args.project,
        engine_pin=args.engine,
        image=args.image,
        command=command,
        env=env,
        bind_mounts=bind_mounts,
    )
    print(json.dumps(_session_to_dict(session), indent=2, sort_keys=True))
    return 0


def _cmd_session_attach(client, args) -> int:
    import asyncio
    import sys as _sys

    proxy = client.session_proxy(args.session_id, path=args.path or "/")

    async def _run():
        async with proxy as p:
            result = await p.run(
                stdin_reader=_sys.stdin.buffer,
                stdout_writer=_sys.stdout.buffer,
            )
            print(
                f"\n{PROG}: session attach closed code={result.close_code} "
                f"reason={result.close_reason!r} "
                f"bytes_to_backend={result.bytes_to_backend} "
                f"bytes_from_backend={result.bytes_from_backend}",
                file=_sys.stderr)
    asyncio.run(_run())
    return 0


def _session_to_dict(s) -> dict:
    return {
        "session_id":        s.session_id,
        "status":            s.status,
        "project":           s.project,
        "owner":             s.owner,
        "engine_identifier": s.engine_identifier,
        "host_port":         s.host_port,
        "pid":               s.pid,
        "started_at":        s.started_at,
        "ready_at":          s.ready_at,
        "last_seen_at":      s.last_seen_at,
        "terminated_at":     s.terminated_at,
        "exit_code":         s.exit_code,
        "error_message":     s.error_message,
        "image":             s.image,
        "command":           list(s.command),
        "env":               dict(s.env),
        "bind_mounts":       dict(s.bind_mounts),
    }


# ----------------------------------------------------------------
# argparse plumbing
# ----------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    """Construct the top-level argparse tree for the ``ttio`` CLI.

    Each subcommand is registered with its handler via
    ``set_defaults(func=...)``; the dispatch happens in :func:`main`.

    Returns
    -------
    argparse.ArgumentParser
        A fully-configured parser ready to consume an argv list.
    """
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
                     help="Source-file format: fastq | fasta | mzml | "
                          "mztab | imzml | nmrml | bam | sam | cram | "
                          "thermo-raw | waters-masslynx | bruker-timstof "
                          "(aliases: thermo, waters, bruker, timstof).")
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
                     help="Target export format: fastq | fasta | mzml | "
                          "mztab | isa | bam | cram. (CRAM needs "
                          "--extra --reference <fasta>.)")
    px.add_argument("--output", required=True)
    px.add_argument("--extra", nargs=argparse.REMAINDER)
    px.set_defaults(func=cmd_export)

    # query
    pq = sub.add_parser(
        "query",
        help="POST /v1/cohorts/query (or preview-count).")
    _add_server_args(pq)
    _add_auth_args(pq)
    pq.add_argument("--select", default="containers",
                     choices=["containers", "subjects", "samples"])
    pq.add_argument("--predicate-json",
                     help="Predicate AST as a JSON string.")
    pq.add_argument("--predicate-file",
                     help="Path to a file with the predicate AST.")
    pq.add_argument("--no-predicate", action="store_true",
                     help="Allow a query with no predicate "
                          "(returns everything in scope).")
    pq.add_argument("--limit", type=int, default=100)
    pq.add_argument("--cursor",
                     help="Opaque cursor from a prior response.")
    pq.add_argument("--count-only", action="store_true",
                     help="Hit /v1/cohorts/preview-count instead.")
    pq.set_defaults(func=cmd_query)

    # submit
    ps = sub.add_parser(
        "submit",
        help="POST /v1/jobs against a registered pipeline.")
    _add_server_args(ps)
    _add_auth_args(ps)
    ps.add_argument("--pipeline", required=True,
                     help="pipeline_id to submit against.")
    ps.add_argument("--inputs-file", required=True,
                     help="JSON file with the inputs slot map. Slot "
                          "values may be container URIs or "
                          "{\"cohort_query\": ...} envelopes.")
    ps.add_argument("--params-file",
                     help="Optional JSON file with the params map.")
    ps.set_defaults(func=cmd_submit)

    # jobs (verb subcommand: ls / status / cancel / events)
    pj = sub.add_parser(
        "jobs",
        help="Job tracking: ls / status / cancel / events.")
    _add_server_args(pj)
    _add_auth_args(pj)
    pj.add_argument("action", choices=["ls", "status", "cancel", "events"])
    pj.add_argument("job_id", nargs="?",
                     help="Job ID (required for status / cancel / events).")
    pj.add_argument("--status", help="Filter by status (ls only).")
    pj.add_argument("--limit", type=int, help="Row cap (ls only).")
    pj.set_defaults(func=cmd_jobs)

    # pipelines (verb subcommand: ls / get / register)
    pp = sub.add_parser(
        "pipelines",
        help="Pipeline registry: ls / get / register.")
    _add_server_args(pp)
    _add_auth_args(pp)
    pp.add_argument("action", choices=["ls", "get", "register"])
    pp.add_argument("pipeline_id", nargs="?",
                     help="pipeline_id (required for get).")
    pp.add_argument("--identifier")
    pp.add_argument("--version", dest="version")
    pp.add_argument("--project")
    pp.add_argument("--definition-file",
                     help="Path to the engine-native pipeline definition.")
    pp.add_argument("--engine-pin",
                     help="Engine identifier override.")
    pp.set_defaults(func=cmd_pipelines)

    # cohorts: alias for `query` (matches spec section 8.2's mention
    # of "saved cohort" terminology; v1.0 server has no saved
    # cohorts so this is just `query` under another name).
    pc = sub.add_parser(
        "cohorts",
        help="Alias for `query` (saved-cohort API not in v1).")
    _add_server_args(pc)
    _add_auth_args(pc)
    pc.add_argument("--select", default="containers",
                     choices=["containers", "subjects", "samples"])
    pc.add_argument("--predicate-json")
    pc.add_argument("--predicate-file")
    pc.add_argument("--no-predicate", action="store_true")
    pc.add_argument("--limit", type=int, default=100)
    pc.add_argument("--cursor")
    pc.add_argument("--count-only", action="store_true")
    pc.set_defaults(func=cmd_query)

    # provenance: not exposed by v1.0 server -- surfaces a clear
    # deferral message rather than a confusing 404.
    pr = sub.add_parser(
        "provenance",
        help="(deferred) -- v1.0 server doesn't expose this endpoint.")
    pr.add_argument("container", nargs="?")
    pr.set_defaults(func=cmd_provenance)

    # sessions (W4 live: create / ls / status / attach / terminate)
    pss = sub.add_parser(
        "sessions",
        help="Interactive sessions: create / ls / status / attach / terminate.")
    _add_server_args(pss)
    _add_auth_args(pss)
    pss.add_argument("action",
                       choices=["create", "ls", "status", "attach", "terminate"])
    pss.add_argument("session_id", nargs="?",
                       help="session_id (required for status / attach / terminate).")
    pss.add_argument("--engine", help="engine_pin (create).")
    pss.add_argument("--project", help="project (create).")
    pss.add_argument("--image", help="container image (create).")
    pss.add_argument("--command", nargs="+",
                       help="command + args to execute (create).")
    pss.add_argument("--env", action="append",
                       help="K=V env var (repeatable; create).")
    pss.add_argument("--bind-mount", action="append",
                       help="host:container bind mount (repeatable; create).")
    pss.add_argument("--status", help="status filter (ls).")
    pss.add_argument("--limit", type=int, help="row cap (ls).")
    pss.add_argument("--path", help="attach path inside the engine (attach); default /.")
    pss.set_defaults(func=cmd_sessions)

    return p


def main(argv: Optional[Iterable[str]] = None) -> int:
    """Dispatch a ``ttio`` umbrella-command invocation.

    Builds the argparse tree via :func:`build_parser`, parses
    ``argv``, then calls the subcommand handler stored under
    ``args.func``.

    Parameters
    ----------
    argv : Iterable[str], optional
        Argument vector. Defaults to ``sys.argv[1:]`` when ``None``.

    Returns
    -------
    int
        The subcommand handler's return code: ``0`` success, ``1``
        remote / SDK failure (including auth), ``2`` usage error,
        ``3`` local file / format error, ``130`` keyboard interrupt.
    """
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
