"""``LazyReference``: a chromosome-name -> sequence-bytes mapping over an
indexed FASTA that loads a chromosome on first access and keeps only a
few in memory. Suits the streaming importers, where a whole-genome
reference (3 G bases) must not be resident at once.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import subprocess
from collections import OrderedDict
from collections.abc import Mapping
from pathlib import Path


class LazyReference(Mapping):
    """Mapping over ``<fasta>.fai`` entries; values are upper-case-preserving
    raw sequence bytes (newlines removed)."""

    def __init__(self, fasta_path, *, cache_chroms: int = 2):
        self._path = Path(fasta_path)
        if not self._path.exists():
            raise FileNotFoundError(str(self._path))
        fai = Path(str(self._path) + ".fai")
        if not fai.exists():
            try:
                subprocess.run(["samtools", "faidx", str(self._path)], check=True,
                               capture_output=True)
            except (OSError, subprocess.CalledProcessError):
                fai.write_text(build_fai_text(self._path))
        self._entries: dict[str, tuple[int, int, int, int]] = {}
        for line in fai.read_text().splitlines():
            f = line.split("\t")
            if len(f) < 5:
                continue
            # name, length, offset, line bases, line width (bytes)
            self._entries[f[0]] = (int(f[1]), int(f[2]), int(f[3]), int(f[4]))
        self._cache: OrderedDict[str, bytes] = OrderedDict()
        self._cache_n = max(1, int(cache_chroms))
        self._set_md5: bytes | None = None

    @property
    def path(self) -> Path:
        return self._path

    def __len__(self) -> int:
        return len(self._entries)

    def __iter__(self):
        return iter(self._entries)

    def __contains__(self, key) -> bool:
        return key in self._entries

    def length_of(self, name: str) -> int:
        return self._entries[name][0]

    def __getitem__(self, name: str) -> bytes:
        seq = self._cache.get(name)
        if seq is not None:
            self._cache.move_to_end(name)
            return seq
        if name not in self._entries:
            raise KeyError(name)
        length, offset, line_bases, line_width = self._entries[name]
        if length == 0:
            return b""
        n_full = length // line_bases
        rest = length - n_full * line_bases
        n_bytes = n_full * line_width + rest
        with open(self._path, "rb") as f:
            f.seek(offset)
            raw = f.read(n_bytes)
        seq = raw.replace(b"\r", b"").replace(b"\n", b"")
        if len(seq) != length:
            raise ValueError(f"reference {name}: read {len(seq)} bases, .fai says {length}")
        self._cache[name] = seq
        while len(self._cache) > self._cache_n:
            self._cache.popitem(last=False)
        return seq

    def set_md5(self) -> bytes:
        """MD5 of the concatenated case-preserved sequences of every
        chromosome in alphabetic order of name: the reference-set digest
        every writer records (docs/format-spec.md section 10.10, "MD5
        computation"). Streams one chromosome at a time, once: the digest
        is cached in ``<fasta>.ttio-md5`` as ``<hex> <size> <mtime_s>``
        (the same sidecar the Java and ObjC readers use) and reused while
        the FASTA's size and modification time are unchanged. A sidecar
        that cannot be written is skipped; the digest is still cached in
        the process."""
        if self._set_md5 is not None:
            return self._set_md5
        st = self._path.stat()
        stamp = f"{st.st_size} {int(st.st_mtime)}"
        sidecar = Path(str(self._path) + ".ttio-md5")
        try:
            parts = sidecar.read_text().split()
            if len(parts) == 3 and parts[1] + " " + parts[2] == stamp and len(parts[0]) == 32:
                self._set_md5 = bytes.fromhex(parts[0])
                return self._set_md5
        except (OSError, ValueError):
            pass
        import hashlib
        h = hashlib.md5()
        for name in sorted(self._entries):
            h.update(self[name])
        self._set_md5 = h.digest()
        try:
            sidecar.write_text(f"{self._set_md5.hex()} {stamp}\n")
        except OSError:
            pass
        return self._set_md5


def build_fai_text(fasta: Path) -> str:
    """samtools faidx text for ``fasta`` (name, length, offset of the
    first base, bases per line, bytes per line), for hosts without
    samtools. Requires the fixed line width samtools requires."""
    rows = []
    name = None
    length = line_bases = line_width = 0
    offset = 0
    with open(fasta, "rb") as f:
        pos = 0
        for raw in f:
            n = len(raw)
            if raw.startswith(b">"):
                if name is not None:
                    rows.append(f"{name}\t{length}\t{offset}\t{line_bases}\t{line_width}")
                name = raw[1:].split()[0].decode("ascii") if len(raw) > 1 else ""
                length = line_bases = line_width = 0
                offset = pos + n
            elif name is not None:
                bases = len(raw.rstrip(b"\r\n"))
                if line_bases == 0 and bases:
                    line_bases, line_width = bases, n
                length += bases
            pos += n
    if name is not None:
        rows.append(f"{name}\t{length}\t{offset}\t{line_bases}\t{line_width}")
    return "\n".join(rows) + ("\n" if rows else "")
