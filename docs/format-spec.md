# MPEG-O `.mpgo` File Format Specification — v0.4.0

This document specifies the on-disk layout of an `.mpgo` file as written
by libMPGO v0.4.0 (ObjC reference implementation). It is detailed enough
for a reader implemented in a different language (Python, Java, Rust, Go)
to open, validate, and fully decode a file without consulting the
reference source. As of v0.5.0, three interoperable implementations
(ObjC, Python, Java) read and write this format.

v0.3 is a strict superset of v0.2 on disk: every v0.2 fixture remains
readable, and new content (compound per-run provenance, `v2:`
canonical signatures, LZ4 / Numpress-delta compression codecs) is
gated behind feature flags described alongside each section.

A conforming `.mpgo` file is a plain HDF5 file (format 1.x) with the
group, dataset, and attribute hierarchy described below. Any program
that can read HDF5 can introspect an `.mpgo` file with `h5dump`.

---

## 1. Versioning

Every v0.2+ file carries two attributes on the root group `/`:

| Attribute                | Type              | Value                              |
|--------------------------|-------------------|------------------------------------|
| `mpeg_o_format_version`  | fixed-len string  | `"1.1"` (major.minor)              |
| `mpeg_o_features`        | fixed-len string  | JSON array of feature strings      |

**Version semantics:**

- **Major** (`1.x -> 2.0`): backward-incompatible layout changes.
  Readers that only support 1.x must refuse to open 2.0 files.
- **Minor** (`1.0 -> 1.1`): backward-compatible additions. Existing
  readers may ignore new attributes/datasets they do not understand.

**v0.1 detection:** files written by v0.1 code carry
`@mpeg_o_version = "1.0.0"` instead and have no `@mpeg_o_features`.
v0.2 readers detect the absence of `@mpeg_o_features` and fall back
to the v0.1 JSON metadata path (see §5).

**Feature flags** are documented in
[`feature-flags.md`](feature-flags.md). Features without an `opt_`
prefix are **required**: a reader must refuse to open a file that
lists a required feature it does not support. `opt_`-prefixed features
are informational; readers may ignore them.

---

## 2. Top-level layout

```
/                                       (root group)
├── @mpeg_o_format_version              ("1.1")
├── @mpeg_o_features                    (JSON array)
├── @encrypted                          ("aes-256-gcm") — optional
├── @access_policy_json                 (JSON) — optional
└── study/                              (group, required)
    ├── @title                          (string)
    ├── @isa_investigation_id           (string)
    ├── @transitions_json               (string) — optional
    ├── ms_runs/                        (group, always present)
    │   ├── @_run_names                 (comma-separated run names)
    │   └── <run_name>/                 (one group per run)
    ├── nmr_runs/                       (group, always present)
    │   ├── @_run_names                 (comma-separated run names)
    │   └── <run_name>/                 (legacy NMR runs)
    ├── identifications                 (compound dataset) — optional
    ├── quantifications                 (compound dataset) — optional
    ├── provenance                      (compound dataset) — optional
    ├── identifications_sealed          (encrypted byte blob) — optional
    ├── identifications_sealed_iv       (3 × int32) — optional
    ├── identifications_sealed_tag      (4 × int32) — optional
    ├── identifications_sealed_bytes    (1 × uint32) — optional
    ├── quantifications_sealed          (encrypted byte blob) — optional
    ├── quantifications_sealed_iv       (3 × int32) — optional
    ├── quantifications_sealed_tag      (4 × int32) — optional
    ├── quantifications_sealed_bytes    (1 × uint32) — optional
    └── image_cube/                     (group) — optional, MSImage only
```

Runs under `/study/ms_runs/` may contain any spectrum subclass, not
just mass spectra, despite the legacy name. NMR runs written via
`MPGOSpectralDataset.msRuns` (the post-M10 idiom) land here. The
`/study/nmr_runs/` dict is retained for backward compatibility with
files written by pre-M10 code.

---

## 3. Acquisition run layout

Each `/study/ms_runs/<name>/` group contains:

```
<run_name>/
├── @acquisition_mode                   (int64; MPGOAcquisitionMode enum)
├── @spectrum_count                     (int64)
├── @spectrum_class                     (string)  e.g. "MPGOMassSpectrum"
├── @nucleus_type                       (string) — optional, NMR only
├── @provenance_json                    (string) — optional
├── @provenance_signature               (base64 HMAC) — optional
├── _spectrometer_freq_mhz              (1 × float64) — optional, NMR only
├── instrument_config/                  (group with string attrs)
├── spectrum_index/                     (group, described in §4)
├── signal_channels/                    (group, described in §5)
└── chromatograms/                      (group, optional, M24 v0.4, described in §5a)
```

**Spectrum classes** currently recognized:

| String                  | Meaning                                           |
|-------------------------|---------------------------------------------------|
| `MPGOMassSpectrum`      | MS spectra; required channels `mz` + `intensity` |
| `MPGONMRSpectrum`       | 1-D NMR; required channels `chemical_shift` + `intensity` |

Absence of `@spectrum_class` triggers v0.1 fallback: the reader
assumes `MPGOMassSpectrum` and hardcoded `mz_values`/`intensity_values`
channel names.

**Instrument config** holds only string attributes
(`manufacturer`, `model`, `serial_number`, `source_type`,
`analyzer_type`, `detector_type`), any of which may be empty.

---

## 4. `spectrum_index/`

Parallel 1-D datasets, one per field. All datasets have length
`spectrum_count`.

| Dataset               | Type            | Semantics                              |
|-----------------------|-----------------|----------------------------------------|
| `offsets`             | uint64[N]       | Starting element in signal channel     |
| `lengths`             | uint32[N]       | Number of elements per spectrum        |
| `retention_times`     | float64[N]      | Scan time in seconds                   |
| `ms_levels`           | int32[N]        | MS level (1, 2, …); 0 for non-MS       |
| `polarities`          | int32[N]        | 1 = +, -1 = -, 0 = unknown             |
| `precursor_mzs`       | float64[N]      | Precursor m/z; 0 for non-tandem        |
| `precursor_charges`   | int32[N]        | Precursor charge state; 0 if unknown   |
| `base_peak_intensities`| float64[N]     | Max intensity per spectrum             |
| `headers`             | compound[N]     | Optional `opt_compound_headers` view   |

All parallel datasets are chunked (chunk = 1024) and `zlib -6`
compressed. `@count` (int64) on the `spectrum_index/` group mirrors
`spectrum_count` for quick access.

The **optional compound `headers` dataset** packs all of the above
into one rank-1 dataset of compound records for external tooling
readability. Layout:

```
struct {
    uint64   offset;
    uint32   length;
    float64  retention_time;
    uint8    ms_level;
    int8     polarity;
    float64  precursor_mz;
    int32    precursor_charge;
    float64  base_peak_intensity;
}
```

---

## 5. `signal_channels/`

Name-driven channel storage.

| Attribute / dataset        | Type              | Notes                            |
|----------------------------|-------------------|----------------------------------|
| `@channel_names`           | fixed-len string  | Comma-separated channel names    |
| `<channel>_values`         | float64[N_total]  | Concatenation of all spectra     |
| `<channel>_values_encrypted` | int32[M]        | Present if channel is encrypted  |
| `<channel>_iv`             | int32[3]          | 12-byte IV (if encrypted)        |
| `<channel>_tag`            | int32[4]          | 16-byte GCM auth tag             |
| `@<channel>_ciphertext_bytes` | int64          | Exact ciphertext size            |
| `@<channel>_original_count`| int64             | Original element count           |
| `@<channel>_algorithm`     | string            | e.g. `"AES-256-GCM"`             |
| `@mpgo_signature`          | string (base64)   | HMAC-SHA256 if signed            |

For an MS run the channels are `{mz, intensity}` producing
`mz_values` and `intensity_values`. For an NMR run they are
`{chemical_shift, intensity}` producing `chemical_shift_values` and
`intensity_values`. Channel data is chunked (chunk = 16384) with
`zlib -6`.

Each channel's concatenated dataset is indexed by `offsets[i]` and
`lengths[i]` from `spectrum_index/`: spectrum `i`'s contents for
channel `c` is `<c>_values[offsets[i] .. offsets[i] + lengths[i])`.

---

## 5a. Chromatograms (M24, v0.4)

The `chromatograms/` group is **optional** — v0.3 files lack it and
readers return an empty list. When present:

```
chromatograms/
├── @count                              (int64, number of chromatograms)
├── time_values                         (float64[total_points], concatenated)
├── intensity_values                    (float64[total_points], concatenated)
└── chromatogram_index/                 (subgroup, parallel metadata arrays)
    ├── offsets                          (int64[count])
    ├── lengths                          (uint32[count])
    ├── types                            (int32[count]; MPGOChromatogramType enum)
    ├── target_mzs                       (float64[count]; XIC target m/z, 0.0 otherwise)
    ├── precursor_mzs                    (float64[count]; SRM precursor, 0.0 otherwise)
    └── product_mzs                      (float64[count]; SRM product, 0.0 otherwise)
```

Chromatogram `i`'s time/intensity slice is
`time_values[offsets[i] .. offsets[i] + lengths[i])`.

**MPGOChromatogramType enum**: 0 = TIC, 1 = XIC, 2 = SRM.

---

## 5b. Envelope encryption key info (M25, v0.4)

The `opt_key_rotation` feature flag gates the `/protection/key_info/`
group. When present:

```
/protection/key_info/
├── @kek_id                             (string, caller-supplied KEK identifier)
├── @kek_algorithm                      (string, "aes-256-gcm" in v0.4)
├── @wrapped_at                         (string, ISO-8601 timestamp)
├── @key_history_json                   (string, JSON array of prior entries)
└── dek_wrapped                         (uint8[60] = 32 cipher + 12 IV + 16 tag)
```

The DEK wraps signal data via AES-256-GCM (same as `opt_dataset_encryption`).
The KEK wraps the DEK. Rotation re-wraps only the DEK — signal datasets
are not touched, so rotation cost is O(1) in file size.

---

## 6. Compound metadata datasets

All compound datasets live directly under `/study/`. Fields use HDF5
variable-length C strings (`H5Tvar_str`) where marked **VL**.

### 6.1 `identifications`

```
struct {
    VL string  run_name;
    uint32     spectrum_index;
    VL string  chemical_entity;
    float64    confidence_score;
    VL string  evidence_chain_json;  (JSON array of ref strings)
}
```

Feature flag: `compound_identifications`.

### 6.2 `quantifications`

```
struct {
    VL string  chemical_entity;
    VL string  sample_ref;
    float64    abundance;
    VL string  normalization_method;  (empty string = null)
}
```

Feature flag: `compound_quantifications`.

### 6.3 `provenance` (dataset-level)

```
struct {
    int64      timestamp_unix;
    VL string  software;
    VL string  parameters_json;      (JSON dict)
    VL string  input_refs_json;      (JSON array of refs)
    VL string  output_refs_json;     (JSON array of refs)
}
```

Feature flag: `compound_provenance`.

### 6.4 Per-run provenance

v0.3 (M17) migrates per-run provenance from the v0.2 `@provenance_json`
string attribute to a native compound HDF5 dataset at
`/study/ms_runs/<run>/provenance/steps`. The dataset uses the same
5-field compound type as the dataset-level `/study/provenance`
described in §6.3 above.

The v0.3 writer emits **both** forms during the transition window: the
compound dataset is the primary record, and the `@provenance_json`
legacy mirror is kept in place so the v0.2 signature manager (which
hashes the UTF-8 bytes of the JSON attribute) keeps working. A future
release will drop the legacy mirror once canonical-byte-order
signatures (§10 below) are wired to the compound dataset directly.

The v0.3 reader prefers the compound subgroup when present and falls
back to the `@provenance_json` attribute only when the subgroup is
absent; a run with neither form decodes to an empty provenance chain.

Feature flag: `compound_per_run_provenance`.

---

## 7. Image cube (MSImage)

`/study/image_cube/` is present when the dataset is an `MPGOMSImage`.

```
image_cube/
├── @width               (int64)
├── @height              (int64)
├── @spectral_points     (int64)
├── @tile_size           (int64)
├── @pixel_size_x        (float64)
├── @pixel_size_y        (float64)
├── @scan_pattern        (VL string)
└── intensity            (float64[H][W][SP])
```

The `intensity` dataset is rank-3, chunked with shape
`(tile_size, tile_size, spectral_points)`, and `zlib -6` compressed.
This chunking ensures that reading a `(tileSize × tileSize)` tile
hits exactly one chunk.

Files written by v0.1 code have the equivalent layout at the root
group (`/image_cube/`) instead of `/study/image_cube/`. v0.2 readers
auto-detect both locations.

Feature flag (opt_): `opt_native_msimage_cube`.

---

## 8. Native 2-D NMR

An `MPGONMR2DSpectrum` group (written via the generic
`MPGOSpectrum` persistence path under
`/study/nmr_runs/<run>/spec_NNNNNN/`) carries:

```
spec_NNNNNN/
├── @mpgo_class = "MPGONMR2DSpectrum"
├── @matrix_width, @matrix_height
├── @nucleus_f1, @nucleus_f2
├── arrays/
│   └── intensity_matrix (1-D flattened; v0.1 fallback)
├── intensity_matrix_2d  (float64[H][W])           ← v0.2 addition
├── f1_scale             (float64[H])  H5T_SCALE
└── f2_scale             (float64[W])  H5T_SCALE
```

`intensity_matrix_2d` is the native rank-2 dataset, chunked at
`(min(128, H), min(128, W))` with `zlib -6`. `f1_scale` and
`f2_scale` are attached via `H5DSattach_scale` to dimensions 0 and 1
respectively so `h5dump` renders them as dimension labels.

Feature flag (opt_): `opt_native_2d_nmr`.

v0.2 readers prefer `intensity_matrix_2d` when present and fall back
to the flattened `intensity_matrix` in `arrays/` otherwise.

---

## 9. Encryption

`MPGOSpectralDataset.encryptWithKey:level:error:` performs two
operations in a single call:

1. **Per-run intensity channel encryption.** For each run under
   `/study/ms_runs/`, the plaintext `<channel>_values` dataset is
   read, encrypted with AES-256-GCM via OpenSSL, and replaced by
   `<channel>_values_encrypted` (int32-padded byte blob) alongside
   `<channel>_iv`, `<channel>_tag`, and the sizing attributes listed
   in §5.

2. **Compound dataset sealing.** If `/study/identifications` or
   `/study/quantifications` exist, each is read back into memory,
   serialized to JSON, encrypted with AES-256-GCM, and written as
   `<name>_sealed` (int32-padded bytes) plus `_iv`, `_tag`, and
   `_bytes` sibling datasets. The original compound dataset is
   deleted.

After encryption the root group carries:

- `@encrypted = "aes-256-gcm"`
- `@access_policy_json` (JSON representation of `MPGOAccessPolicy`)

`decryptWithKey:` reverses both operations.

Feature flag (opt_): `opt_dataset_encryption`. Required features may
also list `compound_identifications`/`compound_quantifications` even
after encryption, since those compound datasets will be restored on
decrypt.

---

## 10. Digital signatures

`MPGOSignatureManager.signDataset:inFile:withKey:error:` computes an
HMAC-SHA256 over a canonical byte stream derived from the target
dataset and stores a **prefixed** base64 MAC in `@mpgo_signature`.
Provenance chain signing stores its MAC in `@provenance_signature`
on the run group, computed over the UTF-8 bytes of
`@provenance_json` (legacy v0.2 path, kept for v0.2 compatibility).

### 10.1 v2 canonical signatures (M18, v0.3 default)

Stored as `"v2:" + base64(mac)`. The canonical byte stream is:

- **Atomic numeric datasets** (float / int / uint, 1–8 bytes) — read
  via an explicit little-endian HDF5 memory type
  (`H5T_IEEE_F64LE`, `H5T_STD_U32LE`, ...). The resulting byte buffer
  is canonical on any host architecture.
- **Compound datasets** — each record is walked in declaration order.
  Numeric members are read via a packed memory type that maps each
  atomic member to its LE equivalent. Variable-length string members
  are emitted as `u32_le(byte_length) || utf8_bytes`, so struct
  padding and pointer layouts cannot influence the hash.
- **Other classes** (fixed strings, enums, nested compounds) — fall
  back to the native-bytes path, matching v0.2 behaviour.

The v0.3 signer adds both `opt_digital_signatures` and
`opt_canonical_signatures` to the root feature list on first sign.

### 10.2 v1 native-byte signatures (v0.2 compatibility)

Signatures without the `v2:` prefix are treated as v0.2 native-byte
HMACs and verified by hashing `H5Dread` output in the dataset's
native type. This is how the v0.2 `signed.mpgo` reference fixture
continues to verify under v0.3 readers.

### 10.3 Cross-language parity

The MPGO Objective-C and Python implementations produce byte-identical
`v2:` MACs for the same input (see the `MpgoSign` CLI test harness
under `objc/Tools/` and `python/tests/test_canonical_signatures.py`).

Feature flags: `opt_digital_signatures` (first sign), plus
`opt_canonical_signatures` when any `v2:` signature is present.

---

## 10.4 Compression codecs (M21, v0.3)

Signal-channel datasets carry their compression codec via either the
HDF5 filter pipeline or a dedicated per-channel attribute:

| Codec                  | Transport                                                                                                                                                                     |
|------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **zlib** (default)     | `H5P_DEFLATE` filter at level 6. Lossless. Readable by any HDF5 library without extra plugins.                                                                                |
| **LZ4**                | HDF5 filter id **32004**. Requires the LZ4 filter plugin (`libh5lz4.so`) to be loadable at runtime via `HDF5_PLUGIN_PATH`. Lossless. ~35× faster write / ~2× faster read than zlib, at ~20% larger files on random data. |
| **Numpress-delta**     | Per-channel transform implemented inside MPGO, **not** an HDF5 filter. The dataset stores an `int64` array of first differences of a fixed-point quantised signal. The signal_channels group carries `@<channel>_numpress_fixed_point` (int64) giving the scaling factor. Readers detect the codec via that attribute. Lossy, sub-ppm relative error for typical mass-spectrometry m/z. Clean-room implementation from Teleman et al., *MCP* 13(6), 2014. |

### Numpress-delta algorithm

1. Compute scale `S = floor((2^62 - 1) / max|v|)`; degenerate ranges
   default to `S = 1`.
2. Quantise: `q[i] = llround(v[i] * S)` (IEEE-754 round-to-even).
3. Emit `deltas[0] = q[0]`, `deltas[i] = q[i] - q[i-1]` for `i ≥ 1`.
4. Store `deltas` as the `<channel>_values` int64 HDF5 dataset with
   zlib on top.

Decoding is the exact inverse: cumsum the int64 array, cast to
double, divide by the scale. The MPGO ObjC and Python encoders agree
byte-for-byte on any input (see `test_numpress_scale_matches_objc_formula`).

## 11. Backward compatibility

A v0.2 reader recognizes a v0.1 file by the absence of
`@mpeg_o_features`. The fallback paths:

| v0.2 location                              | v0.1 fallback                              |
|--------------------------------------------|--------------------------------------------|
| `/study/identifications` compound dataset  | `/study/@identifications_json` string attr |
| `/study/quantifications` compound dataset  | `/study/@quantifications_json` string attr |
| `/study/provenance` compound dataset       | `/study/@provenance_json` string attr      |
| `/study/image_cube/` group                 | `/image_cube/` at root                     |
| `spectrum_index/headers` compound dataset  | parallel 1-D datasets only (still present) |
| `intensity_matrix_2d` rank-2 dataset       | `arrays/intensity_matrix` flattened 1-D    |

All v0.1 files written by libMPGO v0.1.0-alpha are readable by v0.2.0
code without modification.

### 11.1 Compound JSON mirror (v0.6 / M37)

All three writers (ObjC, Python, Java) emit the `*_json` string
attribute <em>alongside</em> the `/study/{identifications,quantifications,provenance}`
compound dataset. The attribute carries the same records as the
compound, encoded as a JSON array of objects:

```
[{"run_name": "...", "spectrum_index": 0, "chemical_entity": "...",
  "confidence_score": 0.95, "evidence_chain": ["..."]}, ...]
```

The mirror exists because the HDF5 Java binding JHI5 1.10.x (the
version on current apt/homebrew HDF5 packages) cannot marshal
variable-length-string fields out of a compound dataset: the JNI
rejects any H5Dread whose mem-type contains `H5T_STRING` or
`H5T_VLEN`. Java therefore prefers the JSON attribute on read and
only falls back to primitive-field projection of the compound when
the mirror is absent, which yields empty strings for every VL field.

The mirror is <em>not</em> emitted for the per-run `<run>/provenance/steps`
compound dataset (§6.4) — per-run provenance was added after the
v0.2 attribute fallback and Java's reader does not descend into
run-level compound metadata.

Sealing (§10): encryption moves the compound dataset into
`*_sealed` blobs; the sealing code deletes the matching `*_json`
attribute so sealed files stay opaque without the key.

A future release will remove the mirror once Java's HDF5 binding
gains compound-with-VL read support, at which point every reader
will go through the compound dataset directly.

---

## 12. Example `h5dump` output (minimal MS file)

```
HDF5 "minimal_ms.mpgo" {
GROUP "/" {
   ATTRIBUTE "mpeg_o_format_version" { DATATYPE H5T_STRING ... DATA { "1.1" } }
   ATTRIBUTE "mpeg_o_features" { DATA { "[\"base_v1\",\"compound_identifications\",...]" } }
   GROUP "study" {
      ATTRIBUTE "title" { ... }
      GROUP "ms_runs" {
         ATTRIBUTE "_run_names" { DATA { "run_0001" } }
         GROUP "run_0001" {
            ATTRIBUTE "acquisition_mode"  { DATA { 0 } }
            ATTRIBUTE "spectrum_count"    { DATA { 10 } }
            ATTRIBUTE "spectrum_class"    { DATA { "MPGOMassSpectrum" } }
            GROUP "instrument_config" { ... }
            GROUP "spectrum_index" {
               DATASET "offsets"               { DATATYPE H5T_STD_U64LE ... }
               DATASET "lengths"               { DATATYPE H5T_STD_U32LE ... }
               DATASET "retention_times"       { DATATYPE H5T_IEEE_F64LE ... }
               DATASET "ms_levels"             { DATATYPE H5T_STD_I32LE ... }
               DATASET "polarities"            { DATATYPE H5T_STD_I32LE ... }
               DATASET "precursor_mzs"         { DATATYPE H5T_IEEE_F64LE ... }
               DATASET "precursor_charges"     { DATATYPE H5T_STD_I32LE ... }
               DATASET "base_peak_intensities" { DATATYPE H5T_IEEE_F64LE ... }
               DATASET "headers"               { DATATYPE H5T_COMPOUND { ... } }
            }
            GROUP "signal_channels" {
               ATTRIBUTE "channel_names" { DATA { "mz,intensity" } }
               DATASET "mz_values"        { DATATYPE H5T_IEEE_F64LE ... }
               DATASET "intensity_values" { DATATYPE H5T_IEEE_F64LE ... }
            }
         }
      }
      GROUP "nmr_runs" { ATTRIBUTE "_run_names" { DATA { "" } } }
   }
}
}
```

---

## 13. Conformance checklist for a new reader

1. Open the file with any HDF5 library.
2. Read `@mpeg_o_format_version`. If absent, treat as v0.1.
3. Read `@mpeg_o_features` as a JSON array. Refuse the file if any
   non-`opt_`-prefixed feature is unknown.
4. Open `/study/`. Read `@title`, `@isa_investigation_id`.
5. Enumerate runs under `/study/ms_runs/` via the `_run_names`
   attribute.
6. For each run, read `@spectrum_class` (default
   `MPGOMassSpectrum`). Read `spectrum_index/` parallel datasets.
7. Read `signal_channels/@channel_names` (default `"mz,intensity"`).
8. For random access to spectrum `i`: slice each
   `<channel>_values[offsets[i] : offsets[i] + lengths[i]]` and
   reconstruct the spectrum from the resulting buffers plus the
   index metadata.
9. For identifications/quantifications/provenance, prefer the
   compound datasets if the feature flags are set; fall back to the
   JSON attributes otherwise.
10. If `@encrypted` is set and no key is available, report the file
    as read-only-with-restrictions and skip the encrypted channels.

A conforming reader need not implement writing. The spec is
deliberately write-once: the Objective-C reference implementation
handles the complex sealing and compound marshalling paths, and
third-party readers are expected to consume files written by it.
