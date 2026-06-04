import pytest
from ttio.importers import bruker_tdf
from ttio.importers.imported_dataset import ImportedDataset

pytestmark = pytest.mark.skipif(
    not hasattr(bruker_tdf, "read_dataset"), reason="read_dataset not present")


def test_read_dataset_signature_exists():
    assert callable(bruker_tdf.read_dataset)
