# Thermo `.raw` test fixture

`small.RAW` is the upstream test fixture from
[`compomics/ThermoRawFileParser`](https://github.com/compomics/ThermoRawFileParser/tree/master/ThermoRawFileParserTest/Data).
It is **MIT-licensed** and redistributable.

## Properties

| Property      | Value                                                              |
|---------------|--------------------------------------------------------------------|
| Source        | `https://raw.githubusercontent.com/compomics/ThermoRawFileParser/master/ThermoRawFileParserTest/Data/small.RAW` |
| Size          | 1,504,354 bytes (~1.5 MB)                                          |
| SHA-256       | see `small.RAW.sha256`                                             |
| License       | MIT (per upstream repository LICENSE)                              |

## Usage

The file is **not committed** to the repo. Fetch it with:

```bash
scripts/fetch-vendor-fixtures.sh thermo
```

…or manually:

```bash
mkdir -p ~/fixtures/thermo
curl -sL -o ~/fixtures/thermo/small.RAW \
  https://raw.githubusercontent.com/compomics/ThermoRawFileParser/master/ThermoRawFileParserTest/Data/small.RAW
sha256sum -c data/vendor/thermo/small.RAW.sha256 \
  --strict --quiet --status \
  --check < <(sed "s|small\.RAW|$HOME/fixtures/thermo/small.RAW|" \
              data/vendor/thermo/small.RAW.sha256)
export TTIO_THERMO_RAW_FIXTURE=~/fixtures/thermo/small.RAW
```

Once the env var is set and `ThermoRawFileParser` is on `PATH`,
`python/tests/integration/test_thermo_delegation.py::test_thermo_raw_to_ttio_delegation`
runs. See `docs/test-strategy.md` for the matching CLI install steps.
