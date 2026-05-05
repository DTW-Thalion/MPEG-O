# Bruker `.d` (TDF) test fixture

`diaPASEF.d/` is the upstream Bruker timsTOF test fixture from
[ProteoWizard](https://github.com/ProteoWizard/pwiz/tree/master/pwiz/data/vendor_readers/Bruker/Reader_Bruker_Test.data/diaPASEF.d).
It is **Apache-2.0 licensed** and redistributable.

## Properties

| File                    | Size          | Role                                  |
|-------------------------|--------------:|---------------------------------------|
| `analysis.tdf`          |  192,512 B    | SQLite metadata DB (frames, scans)    |
| `analysis.tdf_bin`      |  815,105 B    | Binary frame payload                  |
| **Total**               | ~1.0 MB       |                                        |

SHA-256 hashes are pinned in `diaPASEF.d.sha256`.

## Usage

The directory is **not committed** to the repo. Fetch it with:

```bash
scripts/fetch-vendor-fixtures.sh bruker
```

…or manually:

```bash
mkdir -p ~/fixtures/bruker/diaPASEF.d
base="https://raw.githubusercontent.com/ProteoWizard/pwiz/master/pwiz/data/vendor_readers/Bruker/Reader_Bruker_Test.data/diaPASEF.d"
curl -sL -o ~/fixtures/bruker/diaPASEF.d/analysis.tdf      "$base/analysis.tdf"
curl -sL -o ~/fixtures/bruker/diaPASEF.d/analysis.tdf_bin  "$base/analysis.tdf_bin"
( cd ~/fixtures/bruker && \
  sha256sum -c $REPO/data/vendor/bruker/diaPASEF.d.sha256 )
export TTIO_BRUKER_TDF_FIXTURE=~/fixtures/bruker/diaPASEF.d
```

Once the env var is set and `pip install -e ".[bruker]"` (or the
broader `[test]` extra) has provided `opentimspy` +
`opentims-bruker-bridge`, `python/tests/test_bruker_tdf.py` and
`python/tests/integration/test_bruker_tdf_integration.py` run the
real-fixture round-trip.
