# MPEG-O Test Fixtures

This directory contains fixture management code (`download.py`,
`generate.py`) and a SHA-256 manifest (`checksums.json`). Per binding
decision 48 (HANDOFF.md), no fixture larger than 1 MB is committed
to the repo: large reference files live in
`$XDG_CACHE_HOME/mpgo-test-fixtures/` (default `~/.cache/mpgo-test-fixtures/`)
and are pulled on demand.

## Quick start

```bash
cd python
pip install -e ".[test,import,crypto,zarr,integration]"
python tests/fixtures/download.py list           # show all fixtures + state
python tests/fixtures/download.py fetch tiny_pwiz_mzml
python tests/fixtures/download.py all            # fetch everything required
```

The first time a fixture is fetched its SHA-256 is computed and
written to `checksums.json`. On subsequent runs the recorded hash is
enforced — a mismatch aborts the download. Use `download.py pin <name>`
to update a pinned hash deliberately.

## Synthetic fixtures

`generate.py` produces small `.mpgo` containers that are entirely
deterministic (seeded RNG, `np.random.default_rng(42)`) so benchmarks
are comparable across runs:

| Fixture                    | Contents                                                  |
|----------------------------|-----------------------------------------------------------|
| `synth_bsa.mpgo`           | 500 MS1 + 200 MS2 + 50 BSA peptide identifications        |
| `synth_multimodal.mpgo`    | 100 MS spectra + 10 NMR spectra + linked identifications  |
| `synth_100k.mpgo`          | 100 000 spectra for stress benchmarks                     |
| `synth_saav.mpgo`          | 5 SAAV-flagged identifications for anonymization tests    |
| `synth_metabolites.mpgo`   | 5 rare-metabolite identifications for masking tests       |

```bash
python tests/fixtures/generate.py --out tests/fixtures/_generated
```

The `_generated/` directory is gitignored (output is reproducible).

## Provenance

| Fixture            | Source                                                          | License                       |
|--------------------|-----------------------------------------------------------------|-------------------------------|
| tiny_pwiz_mzml     | HUPO-PSI/mzML GitHub examples                                   | CC0                           |
| bsa_digest_mzml    | PRIDE PXD000561 (BSA tryptic digest)                            | PRIDE — see archive license   |
| mtbls1_nmr         | MetaboLights MTBLS1                                             | EBI Open Data                 |
| bmrb_glucose       | BMRB metabolomics entry bmse000297                              | CC-BY                         |
| opentims_test_d    | opentims-bruker-bridge bundled test data                        | MIT                           |
| imzml_*            | imzml.org reference suite                                       | CC-BY                         |

URLs marked as `url-TBD` in `download.py list` need to be filled in
during the milestone that first depends on them (see HANDOFF.md
M58/M59).
