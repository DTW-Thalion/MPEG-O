# Compression benchmark suite

Measures whole real datasets as TTI-O vs CRAM 3.0 / 3.1 vs MPEG-G
(genie), and vs mzML.gz / mzML+numpress for mass spectrometry. Every
size in REPORT.md has a passing decode-verify. Design:
docs/superpowers/specs/2026-08-16-compression-suite-design.md.

Prerequisites (WSL Ubuntu): samtools 1.19 or later, podman with the
docker.io/muefab/genie image pinned in tools/genie_image.txt,
sra-tools (tools/install_sra_tools.sh), /usr/bin/time, the project
venv with pyyaml, psims, pynumpress, pyteomics and lxml.

    export TTIO_BENCH_DATA=$HOME/ttio-bench-data
    PY=python/.venv/bin/python
    $PY tools/perf/compression_suite/suite.py fetch
    $PY tools/perf/compression_suite/suite.py prepare
    $PY tools/perf/compression_suite/suite.py encode --smoke
    $PY tools/perf/compression_suite/suite.py encode
    $PY tools/perf/compression_suite/suite.py report

Stages are idempotent: a result JSON is reused when its input sha256,
the tool version and the format module source are unchanged. Every
format encodes the whole corpus file; the TTI-O importers and
exporters stream, so nothing is sharded. `--smoke` runs the corpora
whose source is a local file.

## Smoke run (2026-08-17)

The five on-disk corpora (three chr22 slices, the unaligned HG002 HiFi
subset, PXD000001) through every format: encode stage 76 minutes at one
thread on an i9-13950HX, WSL2, 31 GB RAM. TTI-O peak RSS 1.6 to 3.7 GB
on the chr22 slices with the hs37d5 and hg19 references and 10.6 GB on
the HG002 2x250 slice against the 3.2 GB GRCh38 FASTA (the reference
index and the working set of a 10.6 M-read block). Headline sizes for
the 11-column inputs, bytes: NA12878 chr22 low coverage BAM 150.8 M,
CRAM 3.1 small 81.0 M, TTI-O 73.5 M; NA12878 WES chr22 BAM 66.4 M, CRAM
3.1 small 32.0 M, TTI-O 64.1 M; HG002 2x250 chr22 BAM 1,475 M, CRAM 3.1
small 825 M, TTI-O 1,613 M; HG002 HiFi subset (unaligned) BAM 188.4 M,
CRAM 3.1 small 168.7 M, TTI-O 169.8 M; PXD000001 mzML.gz 298.7 M, TTI-O
175.8 M. The WES and 2x250 TTI-O numbers are the BASE_PACK fallback
described under known issues.

## What each format is given

Aligned corpora: the untouched BAM (`bam_full`, CRAM and MPEG-G only)
and the same BAM cut to SAM columns 1-11 with its header kept
(`bam11`, every format). TTI-O writes the run against the external
reference (`ttio encode --reference`, sequences as REF_DIFF_V2, the
reference not embedded) and exports through `REF_PATH`, the same
footing as CRAM with an external reference. The chr22 slices on disk
keep every `@SQ` line of the genome they were cut from, so their
reference is that whole genome (hs37d5, hg19): genie's transcode-sam
refuses a FASTA that lacks a header contig.

Unaligned corpora: one plain FASTQ per run (`_1` then `_2` for paired
runs). MS corpora: the mzML as fetched.

## Verification

Aligned: SAM columns 1-11 of every record, sorted, md5. Unaligned:
(name, sequence, quality) triples, sorted, md5. MS: the m/z and
intensity arrays of every spectrum in file order as float64, md5;
numpress rows record the maximum relative error instead. A row whose
decode differs is `verify: FAIL`, carries no size in the headline and
per-corpus tables, and is listed with its unverified bytes and the
reason under "Rows that failed verification".

## Known issues found while building the suite

- A blocks_v1 block that holds any unmapped read (FLAG 0x4, CIGAR `*`,
  including reads placed on their mate's contig) codes its sequences
  with BASE_PACK, not REF_DIFF_V2: the v1.8 rule "REF_DIFF_V2 cannot
  encode unmapped reads, fall back on the whole channel" survives per
  block, and placed-unmapped reads sit inside mapped blocks. The NA12878
  WES chr22 slice has 839 such reads in 992,974 (0.08 percent) and its
  single block codes 23.9 MB of sequences as BASE_PACK; the HG002 2x250
  chr22 slice has 176,368 in 10,633,980. On those two corpora TTI-O is
  close to or larger than BAM, while on the mapped-only NA12878
  low-coverage slice REF_DIFF_V2 engages and TTI-O is the smallest
  format. The fix is in the codec (treat CIGAR `*` as all soft clip),
  not in this suite; the numbers here are the writer as it stands.
- genie (MPEG-G reference software) is not lossless on SAM columns
  1-11: it drops unmapped records that have no adjacent mate, clears
  FLAG 0x20 and 0x8 and writes TLEN 0 (NA12878 chr22 low coverage: 28
  records missing, TLEN differs in 1,736,970). Name-sorted input
  changes nothing. It also refuses a FASTA that lacks any header
  contig, cannot take unaligned SAM (a dummy -r gets past the option
  check, then every unmapped record is dropped) or reads longer than
  511 bases in that mode, and `genie run` segfaulted on the NA12878
  WES mgrec. Aligned MPEG-G rows are therefore `verify: FAIL` with
  the reason; unaligned FASTQ round-trips through genie exactly.
- mzML+numpress on PXD000001 records a maximum relative error of
  9.4e-2 (small intensities); the row is lossy and marked FAIL at the
  1e-3 threshold, with the error in the JSON.
- The TTI-O mzML exporter renumbers spectrum ids as scan=1..n; the
  native ids are not preserved. The verifier compares arrays only.
- Before #294 a run written against an external FASTA with more than
  one contig could not be decoded from that FASTA (the resolver
  compared the reference-set md5 with one chromosome's md5).
- `ttio export --format fastq|fasta` passed the wrong flags to the
  dedicated CLIs and exited 2 (fixed on this branch).
