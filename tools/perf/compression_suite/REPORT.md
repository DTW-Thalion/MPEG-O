# Compression benchmark report

Generated 2026-08-17 on 13th Gen Intel(R) Core(TM) i9-13950HX; 31 GB RAM; 6.6.87.2-microsoft-standard-WSL2.
Every size in the headline and per-corpus tables has a passing decode-verify. Rows marked FAIL show no size there; each corpus section lists its failed rows with the reason.

## Headline

| corpus | format | kind | bytes | ratio vs baseline | verify |
|---|---|---|---:|---:|---|
| hg002_2x250_chr22 | cram31_small | bam11 | 824,784,595 | 1.79 | PASS |
| hg002_2x250_chr22 | cram31_small | bam_full | 989,076,450 | 1.49 | PASS |
| hg002_2x250_chr22 | mpegg | bam11 |  |  | FAIL |
| hg002_2x250_chr22 | mpegg | bam_full |  |  | FAIL |
| hg002_2x250_chr22 | ttio | bam11 | 1,613,312,428 | 0.91 | PASS |
| hg002_hifi_subset | cram31_small | bam11 | 168,713,472 | 1.12 | PASS |
| hg002_hifi_subset | cram31_small | bam_full | 168,713,399 | 1.12 | PASS |
| hg002_hifi_subset | mpegg | bam11 |  |  | FAIL |
| hg002_hifi_subset | mpegg | bam_full |  |  | FAIL |
| hg002_hifi_subset | ttio | bam11 | 169,842,684 | 1.11 | PASS |
| na12878_chr22_lowcov | cram31_small | bam11 | 81,004,381 | 1.86 | PASS |
| na12878_chr22_lowcov | cram31_small | bam_full | 81,004,049 | 1.86 | PASS |
| na12878_chr22_lowcov | mpegg | bam11 |  |  | FAIL |
| na12878_chr22_lowcov | mpegg | bam_full |  |  | FAIL |
| na12878_chr22_lowcov | ttio | bam11 | 73,490,254 | 2.05 | PASS |
| na12878_wes_chr22 | cram31_small | bam11 | 32,034,197 | 2.07 | PASS |
| na12878_wes_chr22 | cram31_small | bam_full | 64,120,479 | 1.04 | PASS |
| na12878_wes_chr22 | mpegg | bam11 |  |  | FAIL |
| na12878_wes_chr22 | mpegg | bam_full |  |  | FAIL |
| na12878_wes_chr22 | ttio | bam11 | 64,093,415 | 1.04 | PASS |
| pxd000001_orbitrap | mzml_gz | mzml | 298,727,810 | 1.00 | PASS |
| pxd000001_orbitrap | mzml_numpress_gz | mzml |  |  | FAIL |
| pxd000001_orbitrap | ttio_mzml | mzml | 175,789,980 | 1.70 | PASS |

## hg002_2x250_chr22

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 1,475,133,932 | 1.00 | 0.5578 | 79.0 | 78.9 | 45 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 1,635,690,809 | 0.90 | 0.6185 | 85.0 | 84.9 | 46 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 919,052,499 | 1.61 | 0.3475 | 32.3 | 82.6 | 247 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 1,083,659,571 | 1.36 | 0.4098 | 37.5 | 89.9 | 247 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 811,418,951 | 1.82 | 0.3068 | 143.9 | 132.1 | 565 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 975,427,571 | 1.51 | 0.3688 | 144.1 | 136.3 | 596 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 889,972,397 | 1.66 | 0.3365 | 39.5 | 82.4 | 247 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 1,054,572,085 | 1.40 | 0.3988 | 44.0 | 88.9 | 246 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 824,784,595 | 1.79 | 0.3119 | 95.8 | 132.6 | 247 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 989,076,450 | 1.49 | 0.3740 | 99.5 | 138.5 | 246 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 0.0 | 0.0 | 0 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 0.0 | 0.0 | 0 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 1,613,312,428 | 0.91 | 0.6100 | 460.5 | 313.4 | 10616 | no | ttio 1.7.1 @590162cd | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 0 | genie transcode-sam failed (rc=0, output empty): [ERROR,      0.287s, App/TranscodeSam]: /genie/src/genie/format/sam/importer.cc::249: Did not find ref chrUn_KN707606v1_decoy |
| mpegg | bam_full | 0 | genie transcode-sam failed (rc=0, output empty): [ERROR,     19.199s, App/TranscodeSam]: /genie/src/genie/format/sam/importer.cc::249: Did not find ref chrUn_KN707606v1_decoy |

## hg002_hifi_subset

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 188,391,118 | 1.00 | 0.7131 | 6.4 | 6.3 | 46 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 188,391,071 | 1.00 | 0.7131 | 6.4 | 6.4 | 45 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 176,115,861 | 1.07 | 0.6666 | 4.0 | 6.9 | 73 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 176,115,788 | 1.07 | 0.6666 | 4.0 | 7.0 | 72 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 168,273,177 | 1.12 | 0.6369 | 73.5 | 11.0 | 579 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 168,273,104 | 1.12 | 0.6369 | 73.6 | 11.0 | 513 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 175,361,984 | 1.07 | 0.6638 | 4.7 | 6.6 | 81 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 175,361,914 | 1.07 | 0.6638 | 4.7 | 6.6 | 73 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 168,713,472 | 1.12 | 0.6386 | 13.3 | 10.5 | 272 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 168,713,399 | 1.12 | 0.6386 | 13.4 | 10.5 | 228 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 0.0 | 0.0 | 0 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 0.0 | 0.0 | 0 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 169,842,684 | 1.11 | 0.6429 | 25.8 | 24.1 | 3577 | no | ttio 1.7.1 @590162cd | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 0 | genie transcode-sam failed (rc=0, output missing): [ERROR,      0.000s, App/TranscodeSam]: /genie/src/apps/genie/transcode-sam/program_options.cc::300: You did not pass a reference file. Reference based compression might not work and record |
| mpegg | bam_full | 0 | genie transcode-sam failed (rc=0, output missing): [ERROR,      0.001s, App/TranscodeSam]: /genie/src/apps/genie/transcode-sam/program_options.cc::300: You did not pass a reference file. Reference based compression might not work and record |

## na12878_chr22_lowcov

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 150,752,932 | 1.00 | 0.8450 | 5.7 | 5.4 | 46 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 151,415,873 | 1.00 | 0.8487 | 5.4 | 5.4 | 45 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 88,073,215 | 1.71 | 0.4937 | 2.5 | 6.6 | 74 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 88,072,456 | 1.71 | 0.4937 | 2.7 | 6.1 | 73 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 77,123,324 | 1.95 | 0.4323 | 16.4 | 12.8 | 385 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 77,123,200 | 1.95 | 0.4323 | 16.4 | 12.8 | 393 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 86,095,220 | 1.75 | 0.4826 | 3.2 | 6.3 | 86 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 86,094,464 | 1.75 | 0.4826 | 3.2 | 6.0 | 77 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 81,004,381 | 1.86 | 0.4540 | 9.9 | 13.5 | 188 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 81,004,049 | 1.86 | 0.4540 | 9.8 | 13.5 | 171 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 22.1 | 24.3 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 21.7 | 19.8 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 73,490,254 | 2.05 | 0.4119 | 46.3 | 44.8 | 1826 | no | ttio 1.7.1 @590162cd | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 93,879,106 | 28 records missing from output; columns differing: FLAG(0x20) in 2766, FLAG(0x28) in 7369, FLAG(0x8) in 7323, TLEN in 1736970 |
| mpegg | bam_full | 93,879,106 | 28 records missing from output; columns differing: FLAG(0x20) in 2766, FLAG(0x28) in 7369, FLAG(0x8) in 7323, TLEN in 1736970 |

## na12878_wes_chr22

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 66,369,043 | 1.00 | 0.6984 | 3.4 | 3.4 | 45 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 72,803,470 | 0.91 | 0.7661 | 3.8 | 3.8 | 45 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 36,635,717 | 1.81 | 0.3855 | 7.7 | 3.8 | 246 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 68,758,030 | 0.97 | 0.7235 | 8.0 | 4.2 | 246 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 30,941,927 | 2.14 | 0.3256 | 19.0 | 5.9 | 394 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 63,001,461 | 1.05 | 0.6629 | 19.3 | 6.4 | 353 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 34,403,882 | 1.93 | 0.3620 | 8.2 | 3.9 | 246 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 66,524,122 | 1.00 | 0.7000 | 8.5 | 4.3 | 246 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 32,034,197 | 2.07 | 0.3371 | 11.9 | 6.1 | 246 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 64,120,479 | 1.04 | 0.6747 | 12.2 | 6.5 | 246 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 16.8 | 0.0 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 18.5 | 0.0 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 64,093,415 | 1.04 | 0.6744 | 34.4 | 13.7 | 2321 | no | ttio 1.7.1 @590162cd | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 43,005,088 | genie run failed (rc=139, segfault, output empty):  [log: [INFO,      0.022s, Mgb]: Progress: 10% of file read / [INFO,      0.022s, Mgb]: Progress: 15% of file read / [INFO,      0.022s, Mgb]: Progress: 20% of file read / [INFO,      0.022 |
| mpegg | bam_full | 43,005,088 | genie run failed (rc=139, segfault, output empty):  [log: [INFO,      0.022s, Mgb]: Progress: 10% of file read / [INFO,      0.022s, Mgb]: Progress: 15% of file read / [INFO,      0.022s, Mgb]: Progress: 20% of file read / [INFO,      0.022 |

## pxd000001_orbitrap

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| mzml_gz | mzml | 298,727,810 | 1.00 |  | 36.7 | 2.3 | 763 | no | psims 1.4.0, gzip | PASS |
| mzml_numpress_gz | mzml |  |  |  | 20.7 | 1.0 | 1011 | yes (max rel err 9.4e-02) | psims 1.4.0, gzip | FAIL |
| ttio_mzml | mzml | 175,789,980 | 1.70 |  | 15.0 | 2.2 | 1008 | no | ttio 1.7.1 @590162cd | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mzml_numpress_gz | mzml | 72,886,350 | decode differs from input |

