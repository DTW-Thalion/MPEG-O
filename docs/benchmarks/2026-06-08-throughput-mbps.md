# Cross-SDK throughput (MB/s) — Python / Java / ObjC

**Date:** 2026-06-08
**Source:** `tools/perf/baseline.json` (the manual perf-suite baseline), `n=100000`, `peaks=16`,
**min-of-7** timing, captured on the maintainer's dev box (WSL/Windows). Derived as
`size ÷ time`. These are local, hardware-specific numbers — **treat the cross-SDK ratios as the
signal, not the absolute MB/s**. Re-derive after any `run_perf_ci.sh --update-baseline`.

> **MB/s is meaningless without a size basis**, so it is stated per section. Some ops are
> *throughput-bound* (true line-rate); others are *per-AU / I-O-overhead-bound*, where the MB/s is
> "effective dataset throughput", not codec/crypto speed. `MB = 10⁶ bytes`; byte-codec rows use
> `MiB = 2²⁰`.

## Storage read/write — basis: 25.6 MB logical MS dataset (mz+intensity, float64)
| op | Python | Java | ObjC |
|---|--:|--:|--:|
| HDF5 write / read | 53 / 662 | 55 / 852 | 55 / 672 |
| SQLite write / read | 257 / 1702 | 324 / 1518 | 319 / **12145** |
| Zarr write / read | 91 / 184 | 480 / 567 | 125 / 707 |
| Memory write / read | 10941 / 26664 | **107518 / 56190** | 3021 / **214298** |

## Transport `.mots` encode/decode — basis: produced `.mots` stream (plain ~35.7 MB, compressed ~23.5 MB)
| op | Python | Java | ObjC |
|---|--:|--:|--:|
| plain encode / decode | 14 / 11 | **215 / 69** | 57 / 46 |
| compressed encode / decode | 10 / 9 | 23 / 35 | 16 / 27 |

*(encode is per-AU-serialize-bound, not line-rate.)*

## Encryption
| op | Python | Java | ObjC | basis |
|---|--:|--:|--:|---|
| **AES-GCM genomic** encrypt / decrypt | 1267 / 1319 | 381 / 821 | **2251 / 2262** | 64 MiB raw — *true crypto throughput* |
| spectral per-AU encrypt / decrypt | 11 / 19 | 93 / 141 | 45 / 39 | 25.6 MB logical — *per-AU/I-O-bound* |

The genomic row is the real AES line-rate: **ObjC ~2.2 GB/s** (OpenSSL AES-NI), **Python ~1.3 GB/s**
(cryptography/OpenSSL), **Java ~0.4 GB/s** (JCE software). The spectral row is 20–100× lower
because it is dominated by 100K per-AU object/HDF5 overhead, not crypto.

## Byte codecs — basis: 1 MiB input (MiB/s)
| codec | Python | Java | ObjC |
|---|--:|--:|--:|
| rANS o0 enc / dec | 172 / 219 | 156 / 221 | 222 / 244 |
| rANS o1 enc / dec | 76 / 42 | 118 / 38 | 128 / 86 |
| base_pack enc / dec | 61 / 218 | 99 / 187 | **1028 / 5000** |
| quality_binned enc / dec | 68 / 1348 | 1222 / 2241 | **5887 / 5512** |

## Genomic codecs — basis: input payload (ref_diff & fqzcomp 10 MB, delta_rans 0.8 MB int64)
| codec | Python | Java | ObjC |
|---|--:|--:|--:|
| ref_diff enc / dec | 62 / 91 | 89 / 112 | 106 / 137 |
| fqzcomp enc / dec | 21 / 26 | 24 / 26 | 27 / 29 |
| delta_rans enc / dec | 5 / 35 | 38 / 40 | 44 / 15 |

## How to read it
- **rANS o0 and fqzcomp are at cross-SDK parity** (same native `libttio_rans` / algorithm) — the
  three columns agree, which is the conformance signal.
- **ObjC leads** on raw native paths (AES-GCM, base_pack, quality_binned, SQLite/Memory read).
- **Java leads** on JIT/allocation-bound paths (transport encode, Memory/Zarr write, spectral
  encryption) — the JVM allocator beats GNUstep Foundation on per-object loops.
- **Python's soft spots** are the pure-Python codec wrappers (base_pack/quality_binned encode,
  `delta_rans` encode — the residual numpy-zigzag). `delta_rans` *decode* is at parity (35 vs
  40/15) after the 2026-06 Cython work; reads (`HDF5 read`, etc.) are competitive after the
  bulk-read fix.
- Excluded (variable/ill-defined size): `name_tokenized` (10K names), `mate_info_v2`,
  `streaming.*` and `genomic write/read` (per-SDK on-disk size differs); see `baseline.json` for
  their raw timings.

## Caveats
- Absolute numbers are dev-box-specific (WSL/Windows, shared host); not a hardware benchmark.
- Spectral `encryption` and `transport.encode` are overhead/I-O-bound — their MB/s reflects the
  100K-AU dataset round-trip cost, not crypto/codec line-rate. The 64 MiB `encryption.genomic`
  row is the metric to cite for actual AES throughput.
- Sizes: MS logical = `n·peaks·2·8` = 25.6 MB; byte codecs = 1 MiB; ref_diff/fqzcomp payloads =
  `100000·100` = 10 MB; delta_rans = `100000` int64 = 0.8 MB; genomic AES = 64 MiB.
