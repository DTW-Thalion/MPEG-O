# Compression benchmark report

Generated 2026-08-17 on 13th Gen Intel(R) Core(TM) i9-13950HX; 31 GB RAM; 6.6.87.2-microsoft-standard-WSL2.
Every size in the headline and per-corpus tables has a passing decode-verify. Rows marked FAIL show no size there; each corpus section lists its failed rows with the reason.

## Headline

| corpus | format | kind | bytes | ratio vs baseline | verify |
|---|---|---|---:|---:|---|
| hg002_2x250_chr22 | cram31_small | bam11 | 824,779,258 | 1.79 | PASS |
| hg002_2x250_chr22 | cram31_small | bam_full | 989,071,004 | 1.49 | PASS |
| hg002_2x250_chr22 | mpegg | bam11 |  |  | FAIL |
| hg002_2x250_chr22 | mpegg | bam_full |  |  | FAIL |
| hg002_2x250_chr22 | ttio | bam11 | 1,613,312,428 | 0.91 | PASS |
| hg002_hifi_subset | cram31_small | bam11 | 168,713,472 | 1.12 | PASS |
| hg002_hifi_subset | cram31_small | bam_full | 168,713,399 | 1.12 | PASS |
| hg002_hifi_subset | mpegg | bam11 |  |  | FAIL |
| hg002_hifi_subset | mpegg | bam_full |  |  | FAIL |
| hg002_hifi_subset | ttio | bam11 | 169,842,684 | 1.11 | PASS |
| na12878_chr22_lowcov | cram31_small | bam11 | 81,004,384 | 1.86 | PASS |
| na12878_chr22_lowcov | cram31_small | bam_full | 81,004,052 | 1.86 | PASS |
| na12878_chr22_lowcov | mpegg | bam11 |  |  | FAIL |
| na12878_chr22_lowcov | mpegg | bam_full |  |  | FAIL |
| na12878_chr22_lowcov | ttio | bam11 | 73,490,254 | 2.05 | PASS |
| na12878_wes_chr22 | cram31_small | bam11 | 32,034,195 | 2.07 | PASS |
| na12878_wes_chr22 | cram31_small | bam_full | 64,120,481 | 1.04 | PASS |
| na12878_wes_chr22 | mpegg | bam11 |  |  | FAIL |
| na12878_wes_chr22 | mpegg | bam_full |  |  | FAIL |
| na12878_wes_chr22 | ttio | bam11 | 64,093,415 | 1.04 | PASS |
| pxd000001_orbitrap | mzml_gz | mzml | 298,727,810 | 1.00 | PASS |
| pxd000001_orbitrap | mzml_numpress_gz | mzml |  |  | FAIL |
| pxd000001_orbitrap | ttio_mzml | mzml | 175,789,980 | 1.70 | PASS |

## hg002_2x250_chr22

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 1,475,133,935 | 1.00 | 0.5578 | 79.0 | 79.0 | 45 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 1,635,690,806 | 0.90 | 0.6185 | 84.9 | 85.0 | 45 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 919,047,095 | 1.61 | 0.3475 | 32.3 | 82.5 | 248 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 1,083,654,161 | 1.36 | 0.4098 | 36.1 | 89.9 | 248 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 811,413,623 | 1.82 | 0.3068 | 145.1 | 129.4 | 505 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 975,422,219 | 1.51 | 0.3688 | 145.7 | 136.3 | 476 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 889,966,985 | 1.66 | 0.3365 | 39.6 | 82.5 | 248 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 1,054,566,667 | 1.40 | 0.3988 | 43.5 | 90.1 | 248 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 824,779,258 | 1.79 | 0.3119 | 94.5 | 132.2 | 248 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 989,071,004 | 1.49 | 0.3740 | 98.6 | 139.5 | 248 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 0.0 | 0.0 | 0 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 0.0 | 0.0 | 0 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 1,613,312,428 | 0.91 | 0.6100 | 459.9 | 312.6 | 10624 | no | ttio 1.7.1 | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 0 | command failed rc=1: ['/home/toddw/TTI-O/python/.venv/bin/python', '-c', '\nimport sys; from pathlib import Path\nsys.path.insert(0, \'/home/toddw/TTI-O/tools/perf/compression_suite\')\nimport formats; reg = formats.load_all()\nkey, inp, work, ref = sys.argv[1:5]\nout = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)\n(Path(work) / "enc.path").write_text(str(out))\n', 'mpegg', '/home/toddw/ttio-bench-data/prepared/hg002_2x250_chr22/hg002_illumina.chr22.11col.bam', '/home/toddw/ttio-bench-data/out/hg002_2x250_chr22.mpegg.zpvu5q68', '/home/toddw/ttio-bench-data/raw/reference/hg19.fa']
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 59, in encode
    genie("transcode-sam", ["-i", str(sam.resolve()), "-o", str(mgrec.resolve()),
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 33, in genie
    raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
RuntimeError: genie transcode-sam failed (rc=0): [ERROR,      0.007s, App/TranscodeSam]: /genie/src/genie/format/sam/importer.cc::249: Did not find ref chr1_KI270706v1_random
Command exited with non-zero status 1
import sys; from pathlib import Path
sys.path.insert(0, '/home/toddw/TTI-O/tools/perf/compression_suite')
import formats; reg = formats.load_all()
key, inp, work, ref = sys.argv[1:5]
out = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)
(Path(work) / "enc.path").write_text(str(out))
 mpegg /home/toddw/ttio-bench-data/prepared/hg002_2x250_chr22/hg002_illumina.chr22.11col.bam /home/toddw/ttio-bench-data/out/hg002_2x250_chr22.mpegg.zpvu5q68 /home/toddw/ttio-bench-data/raw/reference/hg19.fa" |
| mpegg | bam_full | 0 | command failed rc=1: ['/home/toddw/TTI-O/python/.venv/bin/python', '-c', '\nimport sys; from pathlib import Path\nsys.path.insert(0, \'/home/toddw/TTI-O/tools/perf/compression_suite\')\nimport formats; reg = formats.load_all()\nkey, inp, work, ref = sys.argv[1:5]\nout = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)\n(Path(work) / "enc.path").write_text(str(out))\n', 'mpegg', '/home/toddw/TTI-O/data/genomic/hg002_illumina/hg002_illumina.chr22.bam', '/home/toddw/ttio-bench-data/out/hg002_2x250_chr22.mpegg.3fclt7xm', '/home/toddw/ttio-bench-data/raw/reference/hg19.fa']
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 59, in encode
    genie("transcode-sam", ["-i", str(sam.resolve()), "-o", str(mgrec.resolve()),
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 33, in genie
    raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
RuntimeError: genie transcode-sam failed (rc=0): [ERROR,      0.007s, App/TranscodeSam]: /genie/src/genie/format/sam/importer.cc::249: Did not find ref chr1_KI270706v1_random
Command exited with non-zero status 1
import sys; from pathlib import Path
sys.path.insert(0, '/home/toddw/TTI-O/tools/perf/compression_suite')
import formats; reg = formats.load_all()
key, inp, work, ref = sys.argv[1:5]
out = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)
(Path(work) / "enc.path").write_text(str(out))
 mpegg /home/toddw/TTI-O/data/genomic/hg002_illumina/hg002_illumina.chr22.bam /home/toddw/ttio-bench-data/out/hg002_2x250_chr22.mpegg.3fclt7xm /home/toddw/ttio-bench-data/raw/reference/hg19.fa" |

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
| ttio | bam11 | 169,842,684 | 1.11 | 0.6429 | 25.4 | 24.0 | 3578 | no | ttio 1.7.1 | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 0 | command failed rc=1: ['/home/toddw/TTI-O/python/.venv/bin/python', '-c', '\nimport sys; from pathlib import Path\nsys.path.insert(0, \'/home/toddw/TTI-O/tools/perf/compression_suite\')\nimport formats; reg = formats.load_all()\nkey, inp, work, ref = sys.argv[1:5]\nout = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)\n(Path(work) / "enc.path").write_text(str(out))\n', 'mpegg', '/home/toddw/ttio-bench-data/prepared/hg002_hifi_subset/hg002_pacbio.subset.11col.bam', '/home/toddw/ttio-bench-data/out/hg002_hifi_subset.mpegg.om55x0mg', '']
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 59, in encode
    genie("transcode-sam", ["-i", str(sam.resolve()), "-o", str(mgrec.resolve()),
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 33, in genie
    raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
RuntimeError: genie transcode-sam failed (rc=0): [ERROR,      0.000s, App/TranscodeSam]: /genie/src/apps/genie/transcode-sam/program_options.cc::300: You did not pass a reference file. Reference based compression might not work and record classes N 
Command exited with non-zero status 1
import sys; from pathlib import Path
sys.path.insert(0, '/home/toddw/TTI-O/tools/perf/compression_suite')
import formats; reg = formats.load_all()
key, inp, work, ref = sys.argv[1:5]
out = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)
(Path(work) / "enc.path").write_text(str(out))
 mpegg /home/toddw/ttio-bench-data/prepared/hg002_hifi_subset/hg002_pacbio.subset.11col.bam /home/toddw/ttio-bench-data/out/hg002_hifi_subset.mpegg.om55x0mg " |
| mpegg | bam_full | 0 | command failed rc=1: ['/home/toddw/TTI-O/python/.venv/bin/python', '-c', '\nimport sys; from pathlib import Path\nsys.path.insert(0, \'/home/toddw/TTI-O/tools/perf/compression_suite\')\nimport formats; reg = formats.load_all()\nkey, inp, work, ref = sys.argv[1:5]\nout = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)\n(Path(work) / "enc.path").write_text(str(out))\n', 'mpegg', '/home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam', '/home/toddw/ttio-bench-data/out/hg002_hifi_subset.mpegg.qctmonrd', '']
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 59, in encode
    genie("transcode-sam", ["-i", str(sam.resolve()), "-o", str(mgrec.resolve()),
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 33, in genie
    raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
RuntimeError: genie transcode-sam failed (rc=0): [ERROR,      0.000s, App/TranscodeSam]: /genie/src/apps/genie/transcode-sam/program_options.cc::300: You did not pass a reference file. Reference based compression might not work and record classes N 
Command exited with non-zero status 1
import sys; from pathlib import Path
sys.path.insert(0, '/home/toddw/TTI-O/tools/perf/compression_suite')
import formats; reg = formats.load_all()
key, inp, work, ref = sys.argv[1:5]
out = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)
(Path(work) / "enc.path").write_text(str(out))
 mpegg /home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam /home/toddw/ttio-bench-data/out/hg002_hifi_subset.mpegg.qctmonrd " |

## na12878_chr22_lowcov

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 150,752,931 | 1.00 | 0.8450 | 5.5 | 5.5 | 45 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 151,415,873 | 1.00 | 0.8487 | 5.4 | 5.5 | 45 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 88,073,214 | 1.71 | 0.4937 | 2.6 | 6.1 | 86 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 88,072,458 | 1.71 | 0.4937 | 2.6 | 6.1 | 73 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 77,123,321 | 1.95 | 0.4323 | 16.5 | 13.0 | 340 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 77,123,201 | 1.95 | 0.4323 | 16.7 | 13.1 | 292 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 86,095,222 | 1.75 | 0.4826 | 3.1 | 6.0 | 78 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 86,094,466 | 1.75 | 0.4826 | 3.4 | 6.1 | 78 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 81,004,384 | 1.86 | 0.4540 | 10.0 | 13.7 | 173 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 81,004,052 | 1.86 | 0.4540 | 10.0 | 13.8 | 179 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 21.9 | 24.0 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 24.1 | 25.7 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 73,490,254 | 2.05 | 0.4119 | 46.5 | 45.5 | 1826 | no | ttio 1.7.1 | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 93,879,106 | 28 records missing from output; columns differing: FLAG(0x20) in 2766, FLAG(0x28) in 7369, FLAG(0x8) in 7323, TLEN in 1736970 |
| mpegg | bam_full | 93,879,106 | 28 records missing from output; columns differing: FLAG(0x20) in 2766, FLAG(0x28) in 7369, FLAG(0x8) in 7323, TLEN in 1736970 |

## na12878_wes_chr22

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| bam | bam11 | 66,369,041 | 1.00 | 0.6984 | 3.4 | 3.4 | 45 | no | samtools 1.19.2 | PASS |
| bam | bam_full | 72,803,473 | 0.91 | 0.7661 | 3.9 | 3.8 | 45 | no | samtools 1.19.2 | PASS |
| cram30 | bam11 | 36,635,717 | 1.81 | 0.3855 | 7.7 | 3.8 | 246 | no | samtools 1.19.2 | PASS |
| cram30 | bam_full | 68,758,030 | 0.97 | 0.7235 | 8.2 | 4.2 | 246 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam11 | 30,941,924 | 2.14 | 0.3256 | 19.2 | 5.9 | 299 | no | samtools 1.19.2 | PASS |
| cram31_archive | bam_full | 63,001,462 | 1.05 | 0.6629 | 19.3 | 6.3 | 350 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam11 | 34,403,882 | 1.93 | 0.3620 | 8.2 | 3.9 | 246 | no | samtools 1.19.2 | PASS |
| cram31_normal | bam_full | 66,524,122 | 1.00 | 0.7000 | 8.5 | 4.3 | 246 | no | samtools 1.19.2 | PASS |
| cram31_small | bam11 | 32,034,195 | 2.07 | 0.3371 | 11.9 | 6.1 | 246 | no | samtools 1.19.2 | PASS |
| cram31_small | bam_full | 64,120,481 | 1.04 | 0.6747 | 12.2 | 6.5 | 246 | no | samtools 1.19.2 | PASS |
| mpegg | bam11 |  |  |  | 14.1 | 0.0 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| mpegg | bam_full |  |  |  | 15.0 | 0.0 | 45 | no | genie (docker.io/muefab/genie@sha256:c3112a3879cc18061bbab5ed8f76dec255ab1be46e2133cd59320dd5ba98ef89) | FAIL |
| ttio | bam11 | 64,093,415 | 1.04 | 0.6744 | 35.1 | 13.8 | 2321 | no | ttio 1.7.1 | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mpegg | bam11 | 43,005,088 | command failed rc=1: ['/home/toddw/TTI-O/python/.venv/bin/python', '-c', '\nimport sys; from pathlib import Path\nsys.path.insert(0, \'/home/toddw/TTI-O/tools/perf/compression_suite\')\nimport formats; reg = formats.load_all()\nkey, enc, out, ref = sys.argv[1:5]\ndec = reg[key].decode(Path(enc), Path(out), Path(ref) if ref else None)\n(Path(out).parent / "dec.path").write_text(str(dec))\n', 'mpegg', '/home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.5lrljfhn/na12878_wes.chr22.11col.bam.mpegg.mgb', '/home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.5lrljfhn/dec', '/home/toddw/ttio-bench-data/raw/reference/hg19.fa']
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 86, in decode
    genie("run", ["-i", str(enc.resolve()), "-o", str(mgrec.resolve()),
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 33, in genie
    raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
RuntimeError: genie run failed (rc=139): 
Command exited with non-zero status 1
import sys; from pathlib import Path
sys.path.insert(0, '/home/toddw/TTI-O/tools/perf/compression_suite')
import formats; reg = formats.load_all()
key, enc, out, ref = sys.argv[1:5]
dec = reg[key].decode(Path(enc), Path(out), Path(ref) if ref else None)
(Path(out).parent / "dec.path").write_text(str(dec))
 mpegg /home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.5lrljfhn/na12878_wes.chr22.11col.bam.mpegg.mgb /home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.5lrljfhn/dec /home/toddw/ttio-bench-data/raw/reference/hg19.fa" |
| mpegg | bam_full | 43,005,088 | command failed rc=1: ['/home/toddw/TTI-O/python/.venv/bin/python', '-c', '\nimport sys; from pathlib import Path\nsys.path.insert(0, \'/home/toddw/TTI-O/tools/perf/compression_suite\')\nimport formats; reg = formats.load_all()\nkey, enc, out, ref = sys.argv[1:5]\ndec = reg[key].decode(Path(enc), Path(out), Path(ref) if ref else None)\n(Path(out).parent / "dec.path").write_text(str(dec))\n', 'mpegg', '/home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.sllo5kpi/na12878_wes.chr22.bam.mpegg.mgb', '/home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.sllo5kpi/dec', '/home/toddw/ttio-bench-data/raw/reference/hg19.fa']
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 86, in decode
    genie("run", ["-i", str(enc.resolve()), "-o", str(mgrec.resolve()),
  File "/home/toddw/TTI-O/tools/perf/compression_suite/formats/mpegg.py", line 33, in genie
    raise RuntimeError(f"genie {op} failed (rc={p.returncode}): "
RuntimeError: genie run failed (rc=139): 
Command exited with non-zero status 1
import sys; from pathlib import Path
sys.path.insert(0, '/home/toddw/TTI-O/tools/perf/compression_suite')
import formats; reg = formats.load_all()
key, enc, out, ref = sys.argv[1:5]
dec = reg[key].decode(Path(enc), Path(out), Path(ref) if ref else None)
(Path(out).parent / "dec.path").write_text(str(dec))
 mpegg /home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.sllo5kpi/na12878_wes.chr22.bam.mpegg.mgb /home/toddw/ttio-bench-data/out/na12878_wes_chr22.mpegg.sllo5kpi/dec /home/toddw/ttio-bench-data/raw/reference/hg19.fa" |

## pxd000001_orbitrap

| format | kind | bytes | ratio | bytes/base | encode s | decode s | peak RSS MB | lossy | tool | verify |
|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| mzml_gz | mzml | 298,727,810 | 1.00 |  | 36.7 | 2.3 | 763 | no | psims 1.4.0, gzip | PASS |
| mzml_numpress_gz | mzml |  |  |  | 20.7 | 1.0 | 1011 | yes (max rel err 9.4e-02) | psims 1.4.0, gzip | FAIL |
| ttio_mzml | mzml | 175,789,980 | 1.70 |  | 15.0 | 2.1 | 1008 | no | ttio 1.7.1 | PASS |

Rows that failed verification (bytes shown for reference only, not comparable):

| format | kind | bytes | reason |
|---|---|---:|---|
| mzml_numpress_gz | mzml | 72,886,350 | decode differs from input |

