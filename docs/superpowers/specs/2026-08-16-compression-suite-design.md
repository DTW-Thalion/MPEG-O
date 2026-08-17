# Compression benchmark suite: TTI-O vs CRAM 3.1 vs MPEG-G (and mzML for MS)

> **Status (2026-08-16).** Design approved; implementation follows the
> plan at `docs/superpowers/plans/2026-08-16-compression-suite.md`.
> The suite lives in `tools/perf/compression_suite/` and produces a
> committed `REPORT.md`. It does not run in CI.

> **Out of scope:** Docker packaging (add later without redesign), CI
> wiring, a lossy TTI-O tier (audit R7 is undecided), mzMLb / mz5
> comparators, speed tuning of the comparators beyond their documented
> profiles.

## 0. Why this spec exists

The 2026-08 compression audit measured TTI-O against its own history
and against isolated codecs (CRAM's fqzcomp qualities, htscodecs
byte-equality). There is no end-to-end, real-file measurement of a
complete `.tio` container against the two formats a genomics reader
will compare it to, CRAM 3.1 and MPEG-G, nor against the mzML
interchange baseline on the mass-spectrometry side. The suite closes
that gap with reproducible, decode-verified numbers on whole real
datasets, and stays rerunnable so every later codec change can be
re-measured with one command.

## 1. Goal

For each corpus in a manifest, produce the container size, encode and
decode wall time, and peak RSS of every format under test, verify each
output decodes back to the same information as the input, and render
one report. Every input is a real public dataset named by accession
and checksum. Information content is held constant across formats
(§4), and any output that fails verification is reported as a failure,
never as a size.

## 2. Layout

```
tools/perf/compression_suite/
  README.md            how to run, prerequisites, expected runtime
  manifest.yaml        corpora (§3): id, tier, source, sha256, reference
  suite.py             driver: fetch | prepare | encode | report
  formats/             one module per format family (§5)
    __init__.py
    bam_cram.py        BAM, CRAM 3.0, CRAM 3.1 profiles (samtools)
    mpegg.py           MPEG-G via genie
    ttio_fmt.py        TTI-O via `ttio encode` / `ttio export`
    fastq.py           FASTQ.gz baseline
    mzml.py            mzML.gz, mzML+numpress.gz (psims)
  verify.py            normalised-md5 comparators (§6)
  report.py            JSON -> REPORT.md
  tools/               build scripts: genie, sra-tools install notes
  results/             <corpus>/<format>[.<profile>].json (committed)
  REPORT.md            generated (committed)
```

Data lives outside the repo under `$TTIO_BENCH_DATA`
(default `~/ttio-bench-data`): `raw/`, `prepared/`, `out/`.

Each stage is idempotent and keyed on the sha256 of its input plus the
tool version, so a rerun after a TTI-O change re-encodes only the
TTI-O rows.

## 3. Corpora

Manifest fields: `id`, `tier` (`aligned` | `unaligned` | `ms`),
`source` (URL or SRA accession), `sha256` (of the fetched file; filled
on first fetch, then enforced), `reference` (aligned tier), `notes`.

Aligned tier (real BAMs; NCBI-hosted GIAB / 1000 Genomes):

| id | source | on disk |
|---|---|---|
| na12878_chr22_lowcov | 1000G NA12878 low-coverage, chr22 slice | yes |
| na12878_wes_chr22 | NIST NA12878 WES, chr22 slice | yes |
| hg002_2x250_chr22 | GIAB HG002 Illumina 2x250, chr22 slice | yes |
| hg002_2x250_full | GIAB HG002 GRCh38 2x250, whole BAM | fetch |
| hg002_hifi_full | GIAB HG002 PacBio HiFi, whole BAM | fetch |

References: hs37 chr22 and hg19 chr22 (on disk), GRCh38 primary
assembly and GRCh37 (fetched, sha256 recorded).

Unaligned tier (NCBI SRA, whole runs, `prefetch` + `fasterq-dump`):

| id | source |
|---|---|
| hg002_illumina_wgs_sra | one HG002 Illumina WGS run |
| hg002_hifi_sra | one HG002 PacBio HiFi run |

Exact accessions are chosen at manifest-writing time from the GIAB
index and recorded with checksums; the spec fixes the selection
criteria (HG002, whole run, one short-read, one long-read).

MS tier (PRIDE):

| id | source |
|---|---|
| pxd000001_orbitrap | PXD000001 TMT_Erwinia mzML (on disk) |
| orbitrap_exploris | one recent Orbitrap Exploris DDA run, mzML |
| timstof_pasef | one timsTOF diaPASEF/ddaPASEF run, mzML |

## 4. Information held constant

TTI-O's SAM/BAM importer keeps SAM columns 1-11 and drops aux tags.
The primary aligned comparison therefore runs every format on an
11-column input: `prepare` writes `<id>.11col.bam` (`samtools view -h
| cut -f1-11 | samtools view -b`, header kept). A secondary column
encodes the untouched BAM with CRAM and MPEG-G only, so the report
shows what TTI-O does not carry.

Unaligned tier: names, sequences and qualities; all formats lossless.

MS tier: m/z and intensity arrays, spectrum metadata. mzML+numpress
rows are lossy and marked; TTI-O rows are lossless.

## 5. Formats and profiles

Aligned: BAM (baseline, samtools default), CRAM 3.0, CRAM 3.1
`normal`, `small`, `archive` (`samtools view -O cram,version=3.1,
<profile>`), MPEG-G via `genie` (reference software, built from
source, lossless: qualities and names preserved, aligned mode with
reference), TTI-O default writer (`ttio encode --format bam`).

Unaligned: FASTQ.gz level 6 (baseline), CRAM 3.1 `small` unaligned,
genie lossless unaligned, TTI-O `ttio encode --format fastq`.

MS: mzML.gz level 6, mzML+numpress linear/slof .gz via psims (lossy,
marked), TTI-O default (`ttio encode --format mzml`).

Every format module implements `encode(input, out) -> path`,
`decode(out) -> path` and `version() -> str`. Tool versions are
recorded in each result JSON.

## 6. Measurement and verification

Per encode: output bytes, wall time, peak RSS via `/usr/bin/time -v`,
threads fixed at 1 for the size runs. Decode is timed the same way.

Verification before a size counts:

- BAM/CRAM/MPEG-G: decode to SAM, project columns 1-11, sort by
  (name, flag), md5. Must equal the input's.
- TTI-O aligned: `ttio export --format sam`, same projection and md5.
- Unaligned: FASTQ normalised to (name, seq, qual) triples, md5.
- MS: m/z and intensity arrays bit-exact against the input mzML for
  lossless rows; numpress rows record max relative error instead.

A verification mismatch marks the row `verify: FAIL` and the report
prints no size for it.

## 7. Report

`report.py` reads `results/**.json` and writes `REPORT.md`:

- One table per corpus: format, profile, bytes, ratio vs baseline,
  bytes/base, bytes/quality, bytes/name where the format exposes a
  breakdown (CRAM via `samtools cram_size` if available, TTI-O via
  `h5ls -v` dataset storage sizes), encode s, decode s, peak RSS MB,
  tool version, verify status.
- A headline table: TTI-O vs CRAM 3.1 small vs MPEG-G per corpus,
  primary (11-column) column, with the secondary full-tag CRAM /
  MPEG-G sizes beside it.
- Environment: CPU, RAM, kernel, tool versions, date.

Plain tables and one-sentence notes only.

## 8. Validation plan

- Unit tests for `verify.py` normalisers and `report.py` on tiny
  fixtures (the repo's synthetic BAM and a 3-spectrum mzML).
- A `--smoke` run over the on-disk chr22 slices and PXD000001 that
  finishes in minutes and exercises every format module end to end,
  including the decode-verify path, before any full-size fetch.
- The full run, then `REPORT.md` and `results/` committed.

## 9. Open items

- genie build: pin the git tag; record it in `tools/`.
- If `samtools cram_size` is not present in 1.19, the CRAM breakdown
  column is omitted rather than approximated.
- SRA and PRIDE accession choice is recorded in the manifest with a
  one-line rationale each.
