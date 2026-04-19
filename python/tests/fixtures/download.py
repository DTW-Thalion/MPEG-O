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


@dataclass(frozen=True)
class FixtureSpec:
    name: str
    url: str | None
    relpath: str
    description: str
    required: bool = True
    notes: str = ""


# Registry of fixtures consumed by the integration / stress / validation
# suites. URL stability matters more than recency — prefer GitHub raw
# from upstream PSI/HUPO repos and stable archive FTP paths over
# project pages whose layout changes.
FIXTURES: list[FixtureSpec] = [
    FixtureSpec(
        name="tiny_pwiz_mzml",
        url="https://raw.githubusercontent.com/HUPO-PSI/mzML/master/examples/tiny.pwiz.1.1.mzML",
        relpath="mzml/tiny.pwiz.1.1.mzML",
        description="Tiny PSI reference mzML produced by ProteoWizard. ~12 KB.",
        required=True,
    ),
    FixtureSpec(
        name="bsa_digest_mzml",
        url=None,  # PXD000561 file URL — pin during M58 with verified checksum.
        relpath="mzml/bsa_digest.mzML",
        description=(
            "BSA tryptic digest from PRIDE PXD000561 (or equivalent). "
            "~15 MB. Used by the BSA proteomics pipeline workflow."
        ),
        required=False,
        notes="Set url to a stable PRIDE archive URL before nightly CI.",
    ),
    FixtureSpec(
        name="mtbls1_nmr",
        url=None,  # MetaboLights ftp URL — pin during M58.
        relpath="nmrml/mtbls1_sample.nmrML",
        description="One MTBLS1 1H NMR sample, ~5 MB.",
        required=False,
    ),
    FixtureSpec(
        name="bmrb_glucose",
        url=None,  # BMRB bmse000297 — pin during M58.
        relpath="nmrml/bmse000297.nmrML",
        description="BMRB metabolomics reference glucose entry, ~200 KB.",
        required=False,
    ),
    FixtureSpec(
        name="opentims_test_d",
        url=None,  # ships with opentims-bruker-bridge package; resolve via import in M58.
        relpath="bruker/opentims_test.d.tar.gz",
        description="opentims-bruker-bridge bundled test .d directory, ~50 MB.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_continuous",
        url=None,  # imzml.org example files — verify URL during M59.
        relpath="imzml/example_continuous.imzML",
        description="imzml.org continuous-mode reference imzML.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_continuous_ibd",
        url=None,
        relpath="imzml/example_continuous.ibd",
        description="Companion .ibd for example_continuous.imzML.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_processed",
        url=None,
        relpath="imzml/example_processed.imzML",
        description="imzml.org processed-mode reference imzML.",
        required=False,
    ),
    FixtureSpec(
        name="imzml_processed_ibd",
        url=None,
        relpath="imzml/example_processed.ibd",
        description="Companion .ibd for example_processed.imzML.",
        required=False,
    ),
]


def load_checksums() -> dict[str, str]:
    if CHECKSUMS_PATH.is_file():
        return json.loads(CHECKSUMS_PATH.read_text())
    return {}


def save_checksums(checksums: dict[str, str]) -> None:
    CHECKSUMS_PATH.write_text(json.dumps(dict(sorted(checksums.items())), indent=2) + "\n")


def cache_path(spec: FixtureSpec) -> Path:
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
    """Download ``spec`` if absent, then verify its checksum.

    If ``pin`` is true (or no checksum is recorded yet) the computed
    SHA-256 is written back to ``checksums.json``.
    """
    if spec.url is None:
        raise RuntimeError(f"fixture '{spec.name}' has no URL pinned yet ({spec.notes or 'set spec.url'})")
    dest = cache_path(spec)
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
        present = "[cached]" if cache_path(spec).is_file() else "[absent]"
        pinned = "pinned" if spec.name in checksums else "unpinned"
        url_state = "url-set" if spec.url else "url-TBD"
        flag = "req" if spec.required else "opt"
        print(f"  {spec.name:28s} {present} {pinned:8s} {url_state:8s} {flag} -- {spec.description}")
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
