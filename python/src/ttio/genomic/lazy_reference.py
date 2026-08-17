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
            subprocess.run(["samtools", "faidx", str(self._path)], check=True)
        self._entries: dict[str, tuple[int, int, int, int]] = {}
        for line in fai.read_text().splitlines():
            f = line.split("\t")
            if len(f) < 5:
                continue
            # name, length, offset, line bases, line width (bytes)
            self._entries[f[0]] = (int(f[1]), int(f[2]), int(f[3]), int(f[4]))
        self._cache: OrderedDict[str, bytes] = OrderedDict()
        self._cache_n = max(1, int(cache_chroms))

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
