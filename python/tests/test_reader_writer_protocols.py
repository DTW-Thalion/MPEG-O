from __future__ import annotations

from ttio.importers.base import Reader
from ttio.importers.imported_dataset import ImportedDataset
from ttio.exporters.base import Writer


class _OkReader:
    def read(self, inputs, opts, progress=None) -> ImportedDataset:
        return ImportedDataset()


class _OkWriter:
    def write(self, ds, layer, output, opts) -> None:
        pass


class _NotReader:
    pass


def test_reader_protocol_membership():
    assert isinstance(_OkReader(), Reader)
    assert not isinstance(_NotReader(), Reader)


def test_writer_protocol_membership():
    assert isinstance(_OkWriter(), Writer)
    assert not isinstance(_NotReader(), Writer)
