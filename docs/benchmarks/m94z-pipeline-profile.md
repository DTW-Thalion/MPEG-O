# M94.Z chr22 Pipeline Profile — Where the 95% Goes

cProfile catalog of the TTI-O Python encode/decode wall time for
`na12878.chr22.lean.mapped.bam` (1,766,433 reads) with the v1.2 + M94.Z
codec stack wired in. Goal: separate "expected multi-omics overhead"
from "fixable Python slowness".

- Branch: `main` @ 2026-04-29
- Codecs: REF_DIFF (sequences), FQZCOMP_NX16_Z (qualities), RANS_ORDER1
  (cigars), NAME_TOKENIZED (read_names + mate_info_chrom), HDF5 zlib
  on remaining int channels.
- BAM: 1,766,433 reads, output `.tio` 169,173,358 bytes.
- Profile artifacts: `~/profile_run/chr22_encode.prof`,
  `~/profile_run/chr22_decode.prof` (throwaway).

> **Note on cProfile overhead**: cProfile inflates wall by ~2.6× on
> encode (130s vs 48.77s native) and ~2.2× on decode (306s vs 141.66s
> native), but the *relative* breakdown by function is preserved.
> Percentages below are of the cProfile wall (130s / 306s). Native
> seconds are derived by scaling each bucket by the cProfile ratio.

---

## 1. Headline numbers

### Encode (native 48.77s, profiled 130.5s, ratio 2.68×)

| Bucket                             | Profiled s | Native s | % wall |
|------------------------------------|-----------:|---------:|-------:|
| **M93 REF_DIFF encode (sequences)**| 79.4       | 29.7     | 60.9 % |
| **NAME_TOKENIZED encode**          | 22.2       | 8.3      | 17.0 % |
| **BamReader.to_genomic_run (BAM read)** | 11.2  | 4.2      |  8.6 % |
| **RANS_ORDER1 encode (cigars)**    | 8.5        | 3.2      |  6.5 % |
| **mate_info subgroup writer**      | 6.8        | 2.5      |  5.2 % |
| **FQZCOMP_NX16_Z encode (qualities)** | 3.1     | 1.1      |  2.4 % |
| **HDF5 dataset writes (h5py)**     | ~3.6       | 1.3      |  2.8 % |
| **GenomicIndex.write**             | 3.8        | 1.4      |  2.9 % |
| reference FASTA load               | 0.7        | 0.3      |  0.5 % |

The codec the user said is "only ~4%" (M94.Z FQZCOMP_NX16_Z) is correct
at **2.4%** of encode wall. The dominant cost is **M93 REF_DIFF**, also
a codec, accounting for ~61% of encode wall — that is *codec compute*,
not "framework overhead".

### Decode (native 141.66s, profiled 306.3s, ratio 2.16×)

| Bucket                                        | Profiled s | Native s | % wall |
|-----------------------------------------------|-----------:|---------:|-------:|
| **`_mate_info_is_subgroup()` × 3 per read**   | 155.6      | 71.9     | 50.8 % |
| **M93 REF_DIFF decode (sequences)**           | 95.5       | 44.1     | 31.2 % |
| **NAME_TOKENIZED decode (read_names + mate_chrom)** | 9.9 |  4.6      |  3.2 % |
| **FQZCOMP_NX16_Z decode (qualities)**         |  6.9       |  3.2      |  2.3 % |
| **RANS_ORDER1 decode (cigars)**               |  5.7       |  2.6      |  1.9 % |
| **`__getitem__` per-read iteration overhead** |  6.7 self  |  3.1      |  2.2 % |
| **SAM-shaped output write loop**              |  3.7 self  |  1.7      |  1.2 % |

This is the buried lede. **Half of decode wall** is HDF5 group-lookup
churn from a redundant probe in `genomic_run.py`. The probe was added
for §128/§141 link-type dispatch but is invoked 3 times per read with
no caching.

The codec compute share (REF_DIFF + NAME_TOKENIZED + FQZCOMP_NX16_Z +
RANS) is **~38% of decode wall**, of which M93 alone is 31%.

The user's "M94.Z is ~4%" claim about the FQZCOMP-Z codec proper holds
for both directions. The other ~95% is mostly **REF_DIFF (also a
codec) plus a single fixable framework hot loop**.

---

## 2. Encode — top 40 by cumulative time

```
ncalls         tottime  cumtime  func                                                              category
1              0.598    118.091  spectral_dataset.py:write_minimal                                 framework (driver)
1              1.089    115.421  spectral_dataset.py:_write_genomic_run                            framework (driver)
1              0.660     80.514  spectral_dataset.py:_write_sequences_ref_diff                     codec dispatch (REF_DIFF)
1              0.045     79.427  codecs/ref_diff.py:encode                                         CODEC (REF_DIFF)
177            1.386     79.379  codecs/ref_diff.py:encode_slice                                   CODEC (REF_DIFF)
1766433       23.324     37.321  codecs/ref_diff.py:pack_read_diff_bitstream                       CODEC (REF_DIFF) **HOT**
1766433       21.102     34.021  codecs/ref_diff.py:walk_read_against_reference                    CODEC (REF_DIFF) **HOT**
372166127     25.114     25.114  list.append                                                       (driven by REF_DIFF + NAME_TOKENIZED bit/list builds)
2              0.998     22.168  codecs/name_tokenizer.py:encode                                   CODEC (NAME_TOKENIZED)
3532866       11.472     15.535  codecs/name_tokenizer.py:_tokenize                                CODEC (NAME_TOKENIZED) **HOT**
1              6.495     11.165  importers/bam.py:to_genomic_run                                   I/O (BAM read via pysam)
178            0.003      8.462  codecs/rans.py:encode                                             CODEC (RANS_ORDER1)
1              0.987      6.803  spectral_dataset.py:_write_mate_info_subgroup                     framework (driver — M86 Phase F)
177            5.560      6.420  codecs/rans.py:_encode_order0                                     CODEC (RANS_ORDER1) **HOT**
1              1.294      3.815  genomic_index.py:write                                            framework (index build/write)
1              1.612      3.660  codecs/name_tokenizer.py:_encode_columnar                         CODEC (NAME_TOKENIZED)
1              0.261      3.063  spectral_dataset.py:_write_qualities_fqzcomp_nx16_z               codec dispatch (FQZCOMP_NX16_Z)
35211095       2.993      2.993  bytearray.append                                                  (codec inner-loop bit builds)
16             0.000      2.795  providers/hdf5.py:write                                           HDF5 (chunked write)
16             2.793      2.795  h5py.../dataset.py:__setitem__                                    HDF5 (chunk/zlib write)
1              2.235      2.719  codecs/fqzcomp_nx16_z.py:encode                                   CODEC (FQZCOMP_NX16_Z) — only 2.7s!
2              0.907      2.108  _hdf5_io.py:write_compound_dataset                                HDF5 (compound dtype)
1              0.000      2.068  spectral_dataset.py:_embed_references_for_runs                   framework (REF_DIFF embedded ref)
1              1.646      2.024  codecs/rans.py:_encode_order1                                     CODEC (RANS_ORDER1)
21004685       1.771      1.771  bytearray.extend                                                  (codec inner loops)
26902453       1.567      1.567  builtins.len                                                      (driven by codec hot loops)
12378339       1.386      1.386  re.Match.group                                                    (NAME_TOKENIZED tokenize regex)
3532864        0.747      1.197  codecs/name_tokenizer.py:_svarint_encode                          CODEC (NAME_TOKENIZED)
1              0.533      0.955  codecs/name_tokenizer.py:_encode_verbatim                         CODEC (NAME_TOKENIZED)
1766932        0.919      0.919  str.split                                                         (NAME_TOKENIZED tokenize)
3              0.639      0.848  _hdf5_io.py:_write_int_channel_with_codec                        framework (codec dispatch)
8832334        0.837      0.837  str.encode                                                        (codec name table builds)
18             0.000      0.810  h5py.../group.py:create_dataset                                   HDF5 (dataset creation)
18             0.808      0.809  h5py.../dataset.py:make_new_dset                                  HDF5 (dataset creation)
1              0.353      0.677  formats.py:_load_reference_chroms                                 I/O (reference FASTA)
3532866        0.657      0.657  re.Pattern.finditer                                               (NAME_TOKENIZED)
1766488        0.657      0.657  re.Pattern.findall                                                (NAME_TOKENIZED)
```

### Encode self-time hot list (where the CPU literally is)

```
372,166,127  25.11s   list.append                              REF_DIFF M-op flag bits + NAME_TOKENIZED token bits
  1,766,433  23.32s   ref_diff.pack_read_diff_bitstream        bit-packing per read (Python loop)
  1,766,433  21.10s   ref_diff.walk_read_against_reference     CIGAR walk + diff extraction (Python loop)
  3,532,866  11.47s   name_tokenizer._tokenize                 regex-based token splitting per name (×2: read_names + mate_chrom)
          1   6.50s   bam.py.to_genomic_run                    pysam BAM iteration + buffer build
        177   5.56s   rans._encode_order0                      pure-Python rANS frequency renorm loop
 35,211,095   2.99s   bytearray.append
         16   2.79s   h5py.dataset.__setitem__                 zlib chunk write (kernel + libz)
          1   2.24s   fqzcomp_nx16_z.encode                    Cython-accelerated rANS-Nx16 (M94.Z)
         18   0.81s   h5py.dataset.make_new_dset
```

---

## 3. Decode — top 40 by cumulative time

```
ncalls          tottime    cumtime   func                                                          category
1               3.743     306.259   formats.py:ttio_decompress                                    framework (driver — per-read SAM dump loop)
1,766,433       6.669     297.463   genomic_run.py:__getitem__                                    framework (per-read accessor)
5,299,299       9.287     155.583   genomic_run.py:_mate_info_is_subgroup                         framework **DEFECT — REPEATED HDF5 PROBE**
10,598,610      6.662     144.266   providers/hdf5.py:open_group                                  HDF5
10,598,634      7.030     136.137   h5py/group.py:__getitem__                                     HDF5
10,598,636     71.310     129.108   h5py/group.py:_get                                            HDF5 (the actual link-type lookup)
3,532,866       1.036     107.030   genomic_run.py:_byte_channel_slice                            framework (byte-channel cache)
1               0.167      98.684   genomic_run.py:_decode_ref_diff_sequences                     codec dispatch (REF_DIFF)
1               0.034      95.480   codecs/ref_diff.py:decode                                     CODEC (REF_DIFF)
177             5.068      95.433   codecs/ref_diff.py:decode_slice                               CODEC (REF_DIFF)
1,766,433       2.975      58.957   genomic_run.py:_mate_chrom_at                                 framework (mate chrom dispatch — calls is_subgroup)
1,766,433       3.374      56.014   genomic_run.py:_mate_pos_at                                   framework (mate pos dispatch — calls is_subgroup)
1,766,433       3.304      55.732   genomic_run.py:_mate_tlen_at                                  framework (mate tlen dispatch — calls is_subgroup)
1,766,433      32.064      52.645   codecs/ref_diff.py:_unpack_read_diff_with_consumed            CODEC (REF_DIFF) **HOT**
1,766,433      19.507      31.751   codecs/ref_diff.py:reconstruct_read_from_walk                 CODEC (REF_DIFF) **HOT**
10,598,910      5.570      12.889   weakref.__setitem__                                           HDF5 (h5py weakref bookkeeping)
10,598,638     11.046      12.633   h5py/group.py:__init__                                        HDF5
185,175,599    12.438      12.438   list.append                                                   (REF_DIFF inner loop)
21,197,556      7.701      11.767   importlib._handle_fromlist                                    Python import system (driven by repeated `from ttio.codecs import name_tokenizer`)
161,034,989    11.070      11.070   bytearray.append                                              (REF_DIFF inner loop)
2               0.015       9.916   codecs/name_tokenizer.py:decode                               CODEC (NAME_TOKENIZED)
165,439,921     8.935       8.935   builtins.divmod                                               (REF_DIFF bit unpack)
1,766,433       0.159       8.498   genomic_run.py:_read_name_at                                  framework
10,598,677      5.647       8.487   h5py/base.py:_e                                               HDF5 (utf-8 encode of group names)
1               3.933       8.321   codecs/name_tokenizer.py:_decode_columnar                     CODEC (NAME_TOKENIZED)
21,197,971      5.371       8.311   importlib._bootstrap.parent                                   Python import system (same as above)
1               0.155       6.913   genomic_run.py:_decode_fqzcomp_nx16_z_qualities               codec dispatch (FQZCOMP_NX16_Z)
1               6.477       6.758   codecs/fqzcomp_nx16_z.py:decode_with_metadata                 CODEC (FQZCOMP_NX16_Z) — only 6.8s!
91,874,560      6.648       6.648   builtins.isinstance                                           (mostly h5py + REF_DIFF)
178             0.003       5.685   codecs/rans.py:decode                                         CODEC (RANS_ORDER1)
177             4.342       4.365   codecs/rans.py:_decode_order0                                 CODEC (RANS_ORDER1)
10,598,910      2.288       3.972   weakref.__new__                                               HDF5
10,598,828      2.634       3.855   weakref.remove                                                HDF5
10,598,910      3.347       3.347   weakref.__init__                                              HDF5
21,199,021      2.940       2.940   str.rpartition                                                Python import system
1,766,434       0.894       2.891   genomic_run.py:_cigar_at                                      framework
1               0.000       2.696   genomic_run.py:_all_cigars                                    framework (cached cigar decode)
```

### Decode self-time hot list

```
10,598,636  71.31s   h5py.group._get                          link-type lookup, called from is_subgroup probe
1,766,433  32.06s   ref_diff._unpack_read_diff_with_consumed  REF_DIFF bit unpack (Python loop)
1,766,433  19.51s   ref_diff.reconstruct_read_from_walk        REF_DIFF read reconstruct (Python loop)
185,175,599  12.44s list.append                                REF_DIFF flag_bits + sub_buf builds
161,034,989  11.07s bytearray.append                            REF_DIFF inner loops
10,598,638  11.05s  h5py.group.__init__                         HDF5 group object alloc per probe
5,299,299    9.29s  _mate_info_is_subgroup                      ← root cause: 3× per read
21,197,556   7.70s  importlib._handle_fromlist                  ← repeated `from .codecs import ...` inside hot accessors
        1   6.48s   fqzcomp_nx16_z.decode_with_metadata         (M94.Z native — only 2% of wall)
10,598,677   5.65s  h5py.base._e                                str-name UTF-8 encode for group lookups
        1   3.93s   name_tokenizer._decode_columnar             pure-Python varint + dict
```

---

## 4. Categorized breakdown

### 4.1 Codec compute (the "real work")

| Codec               | Encode (profiled / native) | Decode (profiled / native) | Notes                                                                             |
|---------------------|----------------------------:|----------------------------:|-----------------------------------------------------------------------------------|
| M93 REF_DIFF        | 79.4s / 29.7s               | 95.5s / 44.1s               | **Pure Python**. Bit-twiddling in Python list-of-ints; biggest single cost.       |
| M83 RANS_ORDER0/1   |  8.5s /  3.2s               |  5.7s /  2.6s               | Pure Python. cigars channel only (~177 slices).                                    |
| NAME_TOKENIZED      | 22.2s /  8.3s               |  9.9s /  4.6s               | Pure Python; regex tokenizer + varint loops. read_names + mate_info_chrom.         |
| M94.Z FQZCOMP_NX16_Z|  3.1s /  1.1s               |  6.9s /  3.2s               | **Cython-accelerated** (the only fast codec on this stack). User's "~4%" claim.    |
| Subtotal codec      | 113.2s / 42.3s = **86.7%** of encode | 118.0s / 54.5s = **38.5%** of decode |                                                                                    |

**Take-away**: on encode, codecs *are* 87% of wall — REF_DIFF dominates,
not the framework. On decode, codecs are only 38% because half of
decode wall is the redundant `_mate_info_is_subgroup()` probe.

### 4.2 HDF5 framework (h5py + provider)

| Direction | Profiled | Native | %     | What                                                                            |
|-----------|---------:|-------:|------:|---------------------------------------------------------------------------------|
| Encode    |   ~3.6s  |  1.3s  | 2.8%  | `dataset.__setitem__` (zlib chunk writes) + `make_new_dset`                     |
| Decode (genuine) | ~3s |  1.4s  | 1.0%  | Compound dataset reads + chunk reads — small if you don't probe in a loop.      |
| Decode (defect-driven) | 144s | 66s | 47%  | 10.6M `open_group` + 10.6M `h5py.group.__getitem__` from the is_subgroup probe. |

The HDF5 *framework itself* is fine. The h5py wall on decode is almost
entirely driven by the framework defect in §4.4.

### 4.3 BAM read (pysam)

- Encode: `BamReader.to_genomic_run` cumulative 11.2s / 4.2s native = **8.6% of encode wall**.
  - 6.5s of that is "self time" (the per-read iteration loop in
    `bam.py`); the rest is pysam C extension. With 1.77M reads this is
    ~2.4 µs/read native, which is reasonable for the pysam iterator.

### 4.4 Per-read iteration overhead (decode)

This is the "fixable" bucket:

| Function                              | Calls     | Cumulative | What it does                                          |
|---------------------------------------|----------:|-----------:|-------------------------------------------------------|
| `genomic_run.__getitem__`             | 1,766,433 | 297.5s     | Top-level per-read accessor.                          |
| `_mate_info_is_subgroup`              | **5,299,299** | **155.6s** | Probes HDF5 link type by trying `open_group` and catching KeyError. **Called 3× per read** (once each from `_mate_chrom_at`, `_mate_pos_at`, `_mate_tlen_at`).|
| `_mate_chrom_at` + `_mate_pos_at` + `_mate_tlen_at` | 3 × 1,766,433 | 170.7s combined | Each unconditionally calls `_mate_info_is_subgroup()`.|
| `providers/hdf5.py:open_group`         | 10,598,610 | 144.3s     | Cumulative consequence of the probe.                  |
| `_byte_channel_slice`                  | 3,532,866  | 107.0s     | Slices into cached decoded byte channel; cumulative time mostly REF_DIFF decode pulled in via the cache fill on first call. (Self time is only 1.0s — the wrapper itself is cheap.) |

The `_mate_info_is_subgroup` cost is **not intrinsic to multi-omics
abstraction**. The probe result is invariant for the lifetime of a
`GenomicRun` (the on-disk layout doesn't change). Caching it once on
the run instance is a single-line `functools.cached_property` fix.

### 4.5 Other Python overhead

| Source                                            | Cumulative | Note                                                                                  |
|---------------------------------------------------|-----------:|---------------------------------------------------------------------------------------|
| `importlib._handle_fromlist` + `_bootstrap.parent`| ~20s decode | Driven by `from .codecs import name_tokenizer as _nt` etc. inside per-read accessors. Should be hoisted to module top. |
| `weakref.*` (h5py-driven)                         | ~25s decode | Tied to h5py group object construction during is_subgroup probes — disappears with the cache fix. |
| `divmod`, `len`, `isinstance`                     | ~25s decode | Driven by REF_DIFF pure-Python loops.                                                  |
| List/bytearray append in REF_DIFF                 | ~270M calls, ~24s decode | The REF_DIFF inner loops use list-of-ints + bytearray.append; vectorising with numpy bit ops would collapse this to single-digit seconds. |

### 4.6 Object construction

`SpectralDataset`, `GenomicRun`, `WrittenGenomicRun`, `AlignedRead`
construction does **not** appear anywhere in the top 40 of either
direction. `AlignedRead` is constructed 1.77M times in decode but
its dataclass `__init__` doesn't surface — the per-read cost is
swamped by the HDF5 probe. Dataset/Run construction is one-shot
(<0.5s per direction). **Object construction is not a bottleneck.**

---

## 5. Expected vs fixable

### Expected multi-omics overhead (do not optimize)

| Cost                                                   | Why "expected"                                                      |
|--------------------------------------------------------|---------------------------------------------------------------------|
| HDF5 chunked I/O (3.6s encode + 3s decode)             | Self-describing storage, container random access — paying for the substrate. |
| Compound-dtype writes for index/provenance (~2s encode)| Mandated by spec layout for `genomic_index` + provenance.           |
| `GenomicIndex.write` (3.8s encode)                     | One-time index materialisation; trivially amortised.                |
| Per-channel codec dispatch in `_hdf5_io._write_int_channel_with_codec` (~0.85s) | Tiny, linear in #channels. |
| BAM read via pysam (~4s native)                        | Lower bound — pysam is already C.                                    |
| Reference-FASTA load for REF_DIFF (~0.3s native)       | Necessary for REF_DIFF to apply.                                     |
| **Total expected overhead**                            | **~12s encode + ~10s decode** = ~25% of encode, ~7% of decode native. |

This is the genuine "multi-omics cost" — well under the user's 95%.
The framework abstraction itself is cheap. Almost all of the 95% is
either (a) codec compute (which is the actual job) or (b) one specific
fixable defect on decode.

### Fixable Python slowness (rank-ordered targets)

| ID  | Target                                          | Profiled cost saved | Native cost saved | Difficulty |
|-----|-------------------------------------------------|--------------------:|------------------:|------------|
| F1  | Cache `_mate_info_is_subgroup` per `GenomicRun` |             ~155s   |        **~70s**   | **Trivial** (1 line, `@cached_property`) |
| F2  | Cythonise / numpy-vectorise REF_DIFF inner loops (encode `pack_read_diff_bitstream` + `walk_read_against_reference`; decode `_unpack_read_diff_with_consumed` + `reconstruct_read_from_walk`) | ~58s enc / ~84s dec | ~22s enc / ~39s dec | Moderate (matches existing M94.Z Cython pattern) |
| F3  | Cythonise / regex-replace NAME_TOKENIZED `_tokenize` + columnar encode/decode | ~18s enc / ~9s dec | ~7s enc / ~4s dec | Moderate |
| F4  | Hoist `from .codecs import ...` out of per-read accessors in `genomic_run.py` | ~20s decode | ~9s decode | Trivial (move imports to module top) |
| F5  | Cythonise `_encode_order0` / `_decode_order0` in `rans.py` (already exists in fqzcomp_nx16_z impl — pattern proven) | ~6s enc / ~5s dec | ~2s enc / ~2s dec | Moderate |

After F1+F4 alone (both trivial), decode native wall would drop from
141.66s → ~62s, with the same M93/codec mix.

After F1+F2+F4, decode would be ~22s (mostly M94.Z + RANS + NAME +
HDF5 + iteration), and encode would be ~25s (mostly REF_DIFF Cython +
NAME + RANS + BAM + HDF5).

---

## 6. Top 5 optimization opportunities (ranked by wall-time win)

### Rank 1 — Cache `_mate_info_is_subgroup()` on the run
- **Saves**: ~70s decode native (50% of decode wall). Single biggest
  win in the whole catalog.
- **What**: `genomic_run.py:721`. The method probes the HDF5 link type
  via `open_group` + `KeyError` catch. Result is invariant for the
  lifetime of the `GenomicRun` (the on-disk file is read-only in this
  path). Replace with `@cached_property` or memoize on first call.
- **Risk**: zero — read-only dataset, layout doesn't change.
- **Difficulty**: 1-line change.

### Rank 2 — Cythonise REF_DIFF encode/decode inner loops
- **Saves**: ~22s encode native + ~39s decode native ≈ **45% of encode
  wall + 28% of decode wall**.
- **What**:
  - Encode: `ref_diff.py:294 pack_read_diff_bitstream` (Python list-of-bits + nested loop) and `ref_diff.py:161 walk_read_against_reference` (CIGAR walk).
  - Decode: `ref_diff.py:348 _unpack_read_diff_with_consumed` (bit unpack via divmod) and `ref_diff.py:237 reconstruct_read_from_walk`.
- **Pattern**: identical structure to the M94.Z Cython codec under
  `python/src/ttio/codecs/_fqzcomp_nx16_z/`. The M94.Z encode is only
  2.7s for 76M qualities — REF_DIFF could match that order of magnitude.
- **Risk**: needs a bit-exact Cython port (covered by existing test
  vectors).
- **Difficulty**: moderate. Same template as `_fqzcomp_nx16_z`.

### Rank 3 — Cythonise NAME_TOKENIZED hot paths
- **Saves**: ~7s encode + ~4s decode ≈ **11% of encode wall + 3% of
  decode wall**.
- **What**: `name_tokenizer.py:195 _tokenize` (Python regex iter +
  list-build per name × 1.77M reads × 2 channels = 3.5M calls);
  `_encode_columnar` (1.6s self) and `_decode_columnar` (3.9s self).
- **Risk**: low if the existing tokenization tests cover the column
  cases.
- **Difficulty**: moderate. Tokenizer regex inner loop is amenable to
  a Cython rewrite that processes raw bytes.

### Rank 4 — Hoist codec imports out of per-read accessors
- **Saves**: ~9s decode native ≈ **6% of decode wall**.
- **What**: `genomic_run.py` accessors do `from .codecs import
  name_tokenizer as _nt` (and similar for ref_diff, rans, fqzcomp)
  inside each per-read code path. Even though Python caches modules in
  `sys.modules`, `_handle_fromlist` still runs on every call, costing
  ~20s profiled / ~9s native.
- **Risk**: zero — pure module-level hoist.
- **Difficulty**: trivial. Search-and-replace.

### Rank 5 — Cythonise RANS_ORDER0/ORDER1
- **Saves**: ~2s encode + ~2s decode ≈ **4% encode + 1% decode**.
- **What**: `rans.py:190 _encode_order0`, `rans.py:308 _encode_order1`,
  `rans.py:244 _decode_order0`, `rans.py:360 _decode_order1`. Pure
  Python frequency renorm + arith-coding loop. Only ~177 slices but
  several MB each.
- **Risk**: low — bit-exact reference vectors exist for M83.
- **Difficulty**: moderate. Smallest of the codec port projects.

### Honourable mention — the M94.Z FQZCOMP_NX16_Z codec
The user's "~4%" claim is verified: M94.Z encode is 2.7s profiled
(2% of encode wall) and decode is 6.8s profiled (2% of decode wall).
**Don't optimise it further — it's already Cython and already small.**

---

## Appendix — what NOT to optimize

- **HDF5 chunked I/O**: only 3-4s combined wall. Below the noise floor.
- **`SpectralDataset.write_minimal` / `_write_genomic_run` driver
  code**: the cumulative time on these (115s encode) is **all
  delegated to codecs and channel writers** — the driver self-time is
  <2s.
- **`AlignedRead` dataclass construction**: 1.77M instantiations in
  decode but does not surface in the top 40. Don't bother.
- **`GenomicIndex.write`**: 1.4s native. Not worth the complexity.
- **Reference FASTA load**: 0.3s native. Negligible.
- **BAM read via pysam**: already C-accelerated; further gains require
  htslib-level work.

---

## Reproducing this report

```bash
# Encode profile
wsl -d Ubuntu -- bash -c "cd ~/TTI-O && python3 -c '
import cProfile
from tools.benchmarks.formats import ttio_compress
from pathlib import Path
import os
out = os.path.expanduser(\"~/profile_run\")
os.makedirs(out, exist_ok=True)
bam = Path(\"/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam\")
ref = Path(\"/home/toddw/TTI-O/data/genomic/reference/hs37.chr22.fa\")
cProfile.run(\"ttio_compress(bam, ref, Path(f\\\"{out}/chr22_m94z_prof.tio\\\"))\",
             f\"{out}/chr22_encode.prof\")
'"

# Decode profile (run after encode)
wsl -d Ubuntu -- bash -c "cd ~/TTI-O && python3 -c '
import cProfile
from tools.benchmarks.formats import ttio_decompress
from pathlib import Path
import os
out = os.path.expanduser(\"~/profile_run\")
cProfile.run(\"ttio_decompress(Path(f\\\"{out}/chr22_m94z_prof.tio\\\"),
              Path(\\\"/home/toddw/TTI-O/data/genomic/reference/hs37.chr22.fa\\\"),
              Path(f\\\"{out}/chr22_m94z_decode.sam\\\"))\",
             f\"{out}/chr22_decode.prof\")
'"

# Analyse
python3 -c 'import pstats; pstats.Stats("~/profile_run/chr22_encode.prof").sort_stats("cumulative").print_stats(40)'
python3 -c 'import pstats; pstats.Stats("~/profile_run/chr22_decode.prof").sort_stats("cumulative").print_stats(40)'
```
