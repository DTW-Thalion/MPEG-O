"""Fixture downloader for MPEG-O integration tests.

Fetches large reference fixtures from public repositories (PRIDE,
MetaboLights, BMRB, imzml.org, opentims) into an XDG-aware cache
directory and verifies their SHA-256 checksums against
``checksums.json``.

Design notes
------------

* No fixture > 1 MB is committed to the repo (per binding decision 48).
  Everything > 1 MB lives in the cache and is fetched on demand.
* Each fixture entry in :data:`FIXTURES` declares ``url``, ``relpath``
  (path under the cache root), ``sha256`` (or ``None`` if not yet
  pinned), ``description`` and an optional ``required`` flag.
* On first fetch with ``sha256 is None``, the script downloads the
  file, computes the hash, prints it to stderr, and writes it back
  to ``checksums.json`` so subsequent runs verify it.
* On subsequent runs the SHA is enforced; mismatch is a hard error.
* CI defaults skip ``requires_network`` tests, so this script only
  runs in the nightly job or when a developer asks for it.

CLI
---

* ``python download.py --list`` — print all fixtures and their state
* ``python download.py --fetch <name>`` — fetch a single fixture
* ``python download.py --all`` — fetch every required fixture
* ``python download.py --pin <name>`` — refresh the recorded SHA-256
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

CHECKSUMS_PATH = Path(__file__).resolve().parent / "checksums.json"


def _xdg_cache_home() -> Path:
    explicit = os.environ.get("XDG_CACHE_HOME")
    if explicit:
        return Path(explicit)
    return Path.home() / ".cache"


CACHE_ROOT = _xdg_cache_home() / "mpgo-test-fixtures"
_REPO_ROOT = Path(__file__).resolve().parents[3]


@dataclass(frozen=True)
class FixtureSpec:
    """A fixture that the test suite may load.

    Either ``url`` (network-fetched into :data:`CACHE_ROOT`) or
    ``in_repo_path`` (a path relative to the repo root) must be set
    — never both. URL fixtures get a SHA-256 pin in
    ``checksums.json``; in-repo fixtures resolve immediately and
    track integrity through git.
    """
    name: str
    url: str | None
    relpath: str
    description: str
    required: bool = True
    notes: str = ""
    in_repo_path: str | None = None


# Registry of fixtures consumed by the integration / stress / validation
# suites. URL stability matters more than recency — prefer GitHub raw
# from upstream PSI/HUPO repos and stable archive FTP paths over
# project pages whose layout changes. v0.9 follow-up to M61 pinned
# every previously-TBD slot to a verified source.
FIXTURES: list[FixtureSpec] = [
    # Tiny mzML reference (in-repo since v0.4 + GitHub mirror for nightly CI).
    FixtureSpec(
        name="tiny_pwiz_mzml",
        url="https://raw.githubusercontent.com/HUPO-PSI/mzML/master/examples/tiny.pwiz.1.1.mzML",
        relpath="mzml/tiny.pwiz.1.1.mzML",
        description="Tiny PSI reference mzML produced by ProteoWizard (~25 KB).",
        required=True,
        in_repo_path="objc/Tests/Fixtures/tiny.pwiz.1.1.mzML",
    ),
    # 1-minute mzML run committed in-repo by the ObjC suite.
    FixtureSpec(
        name="onemin_mzml",
        url=None,
        relpath="mzml/1min.mzML",
        description="1-minute MS run (~318 KB) — covers RT-range queries and the chromatogram path.",
        required=True,
        in_repo_path="objc/Tests/Fixtures/1min.mzML",
    ),
    # Real BSA tryptic digest mzML from the pymzML test corpus
    # (gzip-compressed, ~5.5 MB; GitHub-hosted). Used by the BSA
    # proteomics workflow when network-gated tests run.
    FixtureSpec(
        name="bsa_digest_mzml",
        url="https://raw.githubusercontent.com/pymzml/pymzML/dev/tests/data/BSA1.mzML.gz",
        relpath="mzml/BSA1.mzML.gz",
        description=(
            "BSA tryptic digest from the pymzML test corpus (~5.5 MB, gzipped). "
            "Larger BSA fixture than tiny_pwiz_mzml; for nightly-CI BSA pipeline tests."
        ),
        required=False,
    ),
    # BMRB nmrML reference committed in-repo (~180 KB).
    FixtureSpec(
        name="bmse000325_nmrml",
        url=None,
        relpath="nmrml/bmse000325.nmrML",
        description="BMRB bmse000325 1H NMR (~180 KB) — real-world nmrML structure.",
        required=True,
        in_repo_path="objc/Tests/Fixtures/bmse000325.nmrML",
    ),
    # imzml.org reference suite — pinned to the pyimzML test corpus
    # on GitHub (Apache-2.0 licensed). Both modes + their .ibd
    # companions; total ~1 MB.
    FixtureSpec(
        name="imzml_continuous",
        url="https://raw.githubusercontent.com/alexandrovteam/pyimzML/master/tests/data/Example_Continuous.imzML",
        relpath="imzml/Example_Continuous.imzML",
        description="Continuous-mode reference imzML (~24 KB) from the pyimzML test corpus.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_continuous_ibd",
        url="https://raw.githubusercontent.com/alexandrovteam/pyimzML/master/tests/data/Example_Continuous.ibd",
        relpath="imzml/Example_Continuous.ibd",
        description="Companion .ibd (~336 KB) for Example_Continuous.imzML.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_processed",
        url="https://raw.githubusercontent.com/alexandrovteam/pyimzML/master/tests/data/Example_Processed.imzML",
        relpath="imzml/Example_Processed.imzML",
        description="Processed-mode reference imzML (~24 KB) from the pyimzML test corpus.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_processed_ibd",
        url="https://raw.githubusercontent.com/alexandrovteam/pyimzML/master/tests/data/Example_Processed.ibd",
        relpath="imzml/Example_Processed.ibd",
        description="Companion .ibd (~605 KB) for Example_Processed.imzML.",
        required=False,
    ),
    # Optional fixtures intentionally NOT pinned:
    #  - BMRB nmrML files are not first-class FTP entries; we ship
    #    bmse000325.nmrML in-repo via objc/Tests/Fixtures/.
    #  - MetaboLights MTBLS1 paths are dataset-specific and require
    #    per-file URL pinning; defer to a milestone that needs it.
    #  - opentims-bruker-bridge bundles its test .d as a Python
    #    package resource; resolve via importlib in the milestone
    #    that needs it (see tests/test_bruker_tdf.py +
    #    MPGO_BRUKER_TDF_FIXTURE).
]


def load_checksums() -> dict[str, str]:
    if CHECKSUMS_PATH.is_file():
        return json.loads(CHECKSUMS_PATH.read_text())
    return {}


def save_checksums(checksums: dict[str, str]) -> None:
    CHECKSUMS_PATH.write_text(json.dumps(dict(sorted(checksums.items())), indent=2) + "\n")


def cache_path(spec: FixtureSpec) -> Path:
    """Return the path the fixture lives at — in-repo for committed
    files, in :data:`CACHE_ROOT` for network-fetched files."""
    if spec.in_repo_path is not None:
        return _REPO_ROOT / spec.in_repo_path
    return CACHE_ROOT / spec.relpath


def _sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    print(f"  fetching {url}", file=sys.stderr)
    with urllib.request.urlopen(url) as resp, tmp.open("wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    tmp.replace(dest)


def fetch(spec: FixtureSpec, *, pin: bool = False) -> Path:
    """Resolve ``spec`` to a path, fetching from the network if needed.

    In-repo fixtures resolve immediately (no SHA pin — git tracks
    integrity). Network fixtures download into :data:`CACHE_ROOT` on
    first use; the SHA-256 is auto-pinned in ``checksums.json``.
    Subsequent calls verify the recorded hash.
    """
    dest = cache_path(spec)
    if spec.in_repo_path is not None:
        if not dest.is_file():
            raise FileNotFoundError(
                f"in-repo fixture '{spec.name}' not found at {dest} — "
                f"run from a checked-out repo"
            )
        return dest
    if spec.url is None:
        raise RuntimeError(f"fixture '{spec.name}' has no URL pinned yet ({spec.notes or 'set spec.url'})")
    if not dest.is_file():
        _download(spec.url, dest)
    digest = _sha256_of(dest)
    checksums = load_checksums()
    recorded = checksums.get(spec.name)
    if recorded is None or pin:
        checksums[spec.name] = digest
        save_checksums(checksums)
        action = "pinned" if recorded is None else "repinned"
        print(f"  {action} {spec.name} sha256={digest}", file=sys.stderr)
    elif recorded != digest:
        raise RuntimeError(
            f"checksum mismatch for {spec.name}: expected {recorded}, got {digest}"
        )
    return dest


def get(name: str) -> Path | None:
    """Return the cached path for fixture ``name`` or ``None`` if absent.

    Used by conftest.py to skip tests cleanly when a fixture has not
    been downloaded.
    """
    spec = _by_name(name)
    path = cache_path(spec)
    return path if path.is_file() else None


def _by_name(name: str) -> FixtureSpec:
    for spec in FIXTURES:
        if spec.name == name:
            return spec
    raise KeyError(f"unknown fixture: {name}")


def cmd_list(_: argparse.Namespace) -> int:
    checksums = load_checksums()
    for spec in FIXTURES:
        present = "[present]" if cache_path(spec).is_file() else "[absent ]"
        if spec.in_repo_path is not None:
            source = "in-repo "
            pinned = "n/a   "
        else:
            source = "network "
            pinned = "pinned" if spec.name in checksums else "unpin "
        flag = "req" if spec.required else "opt"
        print(f"  {spec.name:24s} {present} {source} {pinned} {flag} -- {spec.description}")
    return 0


def cmd_fetch(args: argparse.Namespace) -> int:
    spec = _by_name(args.name)
    fetch(spec)
    return 0


def cmd_all(_: argparse.Namespace) -> int:
    failures: list[str] = []
    for spec in FIXTURES:
        if not spec.required:
            continue
        try:
            fetch(spec)
        except Exception as exc:  # noqa: BLE001 — surfaced to operator
            failures.append(f"{spec.name}: {exc}")
    if failures:
        print("\nFailures:", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


def cmd_pin(args: argparse.Namespace) -> int:
    spec = _by_name(args.name)
    fetch(spec, pin=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="MPEG-O fixture downloader")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="show every fixture and its cache/pin/URL state")
    p_fetch = sub.add_parser("fetch", help="fetch a single fixture")
    p_fetch.add_argument("name")
    sub.add_parser("all", help="fetch every required fixture")
    p_pin = sub.add_parser("pin", help="re-record SHA-256 after intentional update")
    p_pin.add_argument("name")
    ns = parser.parse_args(argv)
    return {
        "list": cmd_list,
        "fetch": cmd_fetch,
        "all": cmd_all,
        "pin": cmd_pin,
    }[ns.cmd](ns)


if __name__ == "__main__":
    raise SystemExit(main())
