# TTI-O `.tio` File Format Specification — v0.10.0

This document specifies the on-disk layout of an `.tio` file as written
by libTTIO v0.10.0. It is detailed enough for a reader implemented in a
different language (Python, Java, Rust, Go) to open, validate, and fully
decode a file without consulting the reference source. Three
interoperable implementations (ObjC, Python, Java) read and write this
format; SQLite and Zarr ship as alternative chunked-array container
backends (see `docs/providers.md`).

Each point release is a strict superset of the previous release on
disk:

- **v0.3** — compound per-run provenance, `v2:` canonical signatures,
  LZ4 / Numpress-delta compression codecs.
- **v0.4** — envelope encryption + key rotation, spectral anonymization,
  nmrML writer, chromatogram API.
- **v0.7** — `ttio_format_version` bumps from `"1.1"` to `"1.2"`; the
  versioned wrapped-key blob (§10b) replaces the fixed 60-byte v1.1
  blob; `read_canonical_bytes` becomes the byte-level contract for
  signatures and encryption (§10c).
- **v0.8** — post-quantum crypto preview (`opt_pqc_preview`:
  ML-KEM-1024 for KEM, ML-DSA-87 for signatures); see `docs/pqc.md`.
- **v0.9** — provider abstraction hardening: SQLite and Zarr v3
  backends in all three languages.
- **v0.10** — streaming transport layer (`.tis`; see
  `docs/transport-spec.md`) and v1.0 per-Access-Unit encryption
  (`opt_per_au_encryption`, optional `opt_encrypted_au_headers`).
  Adds the `VL_BYTES` compound field kind and the
  `<channel>_segments` / `spectrum_index/au_header_segments`
  compound layouts (§9.1). The file format version remains `"1.2"`;
  per-AU encryption is additive and feature-flagged.

Every feature added after v0.2 is gated by a feature flag (see
`docs/feature-flags.md`) so readers can detect capability support at
open time.

A conforming `.tio` file is a plain HDF5 file (format 1.x) with the
group, dataset, and attribute hierarchy described below. Any program
that can read HDF5 can introspect an `.tio` file with `h5dump`.

---

## 1. Versioning

Every v0.2+ file carries two attributes on the root group `/`:

| Attribute                | Type              | Value                              |
|--------------------------|-------------------|------------------------------------|
| `ttio_format_version`  | fixed-len string  | `"1.2"` in v0.7; `"1.1"` in v0.2–v0.6 (major.minor) |
| `ttio_features`        | fixed-len string  | JSON array of feature strings      |

**Version semantics:**

- **Major** (`1.x -> 2.0`): backward-incompatible layout changes.
  Readers that only support 1.x must refuse to open 2.0 files.
- **Minor** (`1.0 -> 1.1`): backward-compatible additions. Existing
  readers may ignore new attributes/datasets they do not understand.

**v0.1 detection:** files written by v0.1 code carry
`@ttio_version = "1.0.0"` instead and have no `@ttio_features`.
v0.2 readers detect the absence of `@ttio_features` and fall back
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
├── @ttio_format_version              ("1.1")
├── @ttio_features                    (JSON array)
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
`TTIOSpectralDataset.msRuns` (the post-M10 idiom) land here. The
`/study/nmr_runs/` dict is retained for backward compatibility with
files written by pre-M10 code.

---

## 3. Acquisition run layout

Each `/study/ms_runs/<name>/` group contains:

```
<run_name>/
├── @acquisition_mode                   (int64; TTIOAcquisitionMode enum)
├── @spectrum_count                     (int64)
├── @spectrum_class                     (string)  e.g. "TTIOMassSpectrum"
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
| `TTIOMassSpectrum`      | MS spectra; required channels `mz` + `intensity` |
| `TTIONMRSpectrum`       | 1-D NMR; required channels `chemical_shift` + `intensity` |

Absence of `@spectrum_class` triggers v0.1 fallback: the reader
assumes `TTIOMassSpectrum` and hardcoded `mz_values`/`intensity_values`
channel names.

**Instrument config** holds only string attributes
(`manufacturer`, `model`, `serial_number`, `source_type`,
`analyzer_type`, `detector_type`), any of which may be empty.

---

## 3a. Run modality (M79, v0.11)

Each run group MAY carry an optional `@modality` UTF-8 string
attribute identifying the omics modality the run represents. The
attribute is purely informational at v0.11 — readers continue to
dispatch on `@spectrum_class` for record decoding — but it scopes
which downstream metadata + analytics apply to the run.

| `@modality`           | Meaning                                                                       |
|-----------------------|-------------------------------------------------------------------------------|
| `mass_spectrometry`   | Default. Mass-spec, NMR, vibrational, UV-Vis runs (every v0.10 / pre-v0.11 file). |
| `genomic_sequencing`  | Genomic short-read / long-read runs. Reserved for the v0.11 genomic milestones (M74+). |

Absence of `@modality` MUST be interpreted as `mass_spectrometry`
so v0.10 files load unchanged. Future modality strings (proteomic,
metabolomic, …) MAY be added without a format-version bump because
unrecognised values surface as the literal string at the API layer.

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
    ├── types                            (int32[count]; TTIOChromatogramType enum)
    ├── target_mzs                       (float64[count]; XIC target m/z, 0.0 otherwise)
    ├── precursor_mzs                    (float64[count]; SRM precursor, 0.0 otherwise)
    └── product_mzs                      (float64[count]; SRM product, 0.0 otherwise)
```

Chromatogram `i`'s time/intensity slice is
`time_values[offsets[i] .. offsets[i] + lengths[i])`.

**TTIOChromatogramType enum**: 0 = TIC, 1 = XIC, 2 = SRM.

---

## 5b. Envelope encryption key info (M25, v0.4; v1.2 blob in v0.7)

The `opt_key_rotation` feature flag gates the `/protection/key_info/`
group. When present:

```
/protection/key_info/
├── @kek_id                             (string, caller-supplied KEK identifier)
├── @kek_algorithm                      (string, "aes-256-gcm" default; identifies the KEK cipher)
├── @wrapped_at                         (string, ISO-8601 timestamp)
├── @key_history_json                   (string, JSON array of prior entries)
├── @dek_wrapped_bytes                  (int64, actual blob length — v0.7+, see below)
└── dek_wrapped                         (uint8[N]; layout depends on the blob version)
```

### 5b.1 v1.1 wrapped-key layout (pre-v0.7 writers)

Fixed 60 bytes, AES-256-GCM-only:

```
offset  len  field
0       32   AES-256-GCM ciphertext (wrapped 32-byte DEK)
32      12   IV
44      16   auth tag
```

v0.7+ readers accept this layout indefinitely (binding decision 38);
the dispatch rule is **"if blob length == 60 and magic bytes are not
`'M','W'`, treat as v1.1"**.

### 5b.2 v1.2 versioned wrapped-key blob (v0.7, `wrapped_key_v2` flag)

When the `wrapped_key_v2` feature flag is present, `dek_wrapped` is a
variable-length blob:

```
offset  len  field
0       2    magic         = 0x4D 0x57  ('M','W' — TTIO Wrap)
2       1    version       = 0x02
3       2    algorithm_id  (big-endian)
               0x0000 = AES-256-GCM
               0x0001 = ML-KEM-1024 (v0.8 M49 — active; FIPS 203)
               0x0002 = reserved
5       4    ciphertext_len (big-endian, u32)
9       2    metadata_len   (big-endian, u16)
11      M    metadata       (algorithm-specific — see below)
11+M    C    ciphertext     (algorithm-specific — see below)
```

Algorithm-specific metadata/ciphertext layouts:

| `algorithm_id` | metadata                                        | ciphertext          | total blob |
|----------------|-------------------------------------------------|---------------------|-----------:|
| `0x0000` AES-GCM  | `iv(12) \|\| tag(16)` = 28                    | wrapped DEK = 32    | 71 bytes   |
| `0x0001` ML-KEM-1024 (v0.8) | `kem_ct(1568) \|\| aes_iv(12) \|\| aes_tag(16)` = 1596 | AES-GCM-wrapped DEK = 32 | 1639 bytes |

For ML-KEM-1024 the outer envelope contains a classical KEM + AEAD
construction: `ML_KEM.encapsulate(recipient_pk) → (kem_ct,
shared_secret)`, then `shared_secret` (32 bytes) is used as the AES-
256-GCM key to wrap the DEK. Decryption reverses the chain; AES-GCM
authenticates end-to-end (ML-KEM decapsulation on its own is
unauthenticated). See `docs/pqc.md` for the full story including the
language-specific library choices (Python/ObjC use liboqs;
Java uses Bouncy Castle).

Total length = `11 + metadata_len + ciphertext_len`. For AES-256-GCM
this equals 11 + 28 + 32 = **71 bytes**; for ML-KEM-1024 it equals
11 + 1596 + 32 = **1639 bytes**. The `@dek_wrapped_bytes`
attribute records the exact length so readers can avoid relying on
dataset-size probes through storage adapters that pad to a fixed
width.

Writers default to v1.2 when the feature flag is set; readers fall
back to v1.1 for any blob that doesn't start with the `'M','W'` magic.
`docs/feature-flags.md §v0.7` has the flag definition; `CipherSuite`
(M48) is the runtime dispatch catalog that maps `algorithm_id` to a
concrete cipher.

The DEK wraps signal data via AES-256-GCM (same as
`opt_dataset_encryption`). The KEK wraps the DEK. Rotation re-wraps
only the DEK — signal datasets are not touched, so rotation cost is
O(1) in file size.

---

## 6. Compound metadata datasets

All compound datasets live directly under `/study/`. Fields use HDF5
variable-length C strings (`H5Tvar_str`) where marked **VL**.

**Supported compound field kinds** (provider capability floor, all
three languages expose the same set):

| Kind        | HDF5 mapping                                      | Added   |
| ----------- | ------------------------------------------------- | ------- |
| `UINT32`    | `H5T_NATIVE_UINT32`                               | v0.3    |
| `INT64`     | `H5T_NATIVE_INT64`                                | v0.3    |
| `FLOAT64`   | `H5T_NATIVE_DOUBLE`                               | v0.3    |
| `VL_STRING` | `H5Tcopy(H5T_C_S1) + H5Tset_size(H5T_VARIABLE)`   | v0.3    |
| `VL_BYTES`  | `H5Tvlen_create(H5T_NATIVE_UCHAR)` (hvl_t slot)   | v0.10   |

`VL_BYTES` carries the {IV, tag, ciphertext} triplet of per-AU
encryption (§9.1). Providers that can't serialise `hvl_t` inside a
compound (SQLite + Zarr as of v0.10) raise
`NotImplementedError`/`UnsupportedOperationException` at the
`create_compound_dataset` boundary.

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

`/study/image_cube/` is present when the dataset is an `TTIOMSImage`.

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

## 7a. Vibrational imaging cubes (M73, v0.11)

`/study/raman_image_cube/` is present when the dataset carries an
`TTIORamanImage`, and `/study/ir_image_cube/` when it carries an
`TTIOIRImage`. Both groups share the MSImage cube layout but add
the modality-specific scalars and a shared wavenumber axis.

```
raman_image_cube/ (or ir_image_cube/)
├── @width                     (int64)
├── @height                    (int64)
├── @spectral_points           (int64)
├── @tile_size                 (int64)
├── @pixel_size_x              (float64)
├── @pixel_size_y              (float64)
├── @scan_pattern              (VL string)
├── @excitation_wavelength_nm  (float64)   ← raman_image_cube only
├── @laser_power_mw            (float64)   ← raman_image_cube only
├── @ir_mode                   (VL string) ← ir_image_cube only  ("ABSORBANCE" / "TRANSMITTANCE")
├── @resolution_cm_inv         (float64)   ← ir_image_cube only
├── intensity                  (float64[H][W][SP])
└── wavenumbers                (float64[SP])
```

`intensity` is chunked at `(tile_size, tile_size, spectral_points)`
with `zlib -6`, matching the MSImage convention so reading a
`(tileSize × tileSize)` tile hits exactly one chunk. `wavenumbers`
is a rank-1 companion that names the spectral axis and is
identical across all pixels — store once, not per-pixel.

The two groups are mutually exclusive per study; a file is either
a Raman map or an IR map, not both.

---

## 7b. UV-Vis spectra (M73.1, v0.11.1)

`TTIOUVVisSpectrum` is a plain `TTIOSpectrum` subclass — no new
group layout is required. It rides the generic `Spectrum`
persistence path, keyed by the following named signal arrays:

```
spec_NNNNNN/
├── @mpgo_class = "TTIOUVVisSpectrum"
├── @path_length_cm   (float64, optional)
├── @solvent          (VL string, optional)
└── arrays/
    ├── wavelength    (float64[N], nm)
    └── absorbance    (float64[N])
```

No feature flag — pre-v0.11.1 readers open the group as a generic
`Spectrum` and retain the two channels unchanged.

---

## 7c. Two-dimensional correlation spectra (M73.1, v0.11.1)

`TTIOTwoDimensionalCorrelationSpectrum` is an `TTIOSpectrum`
subclass that carries a 1-D variable axis and two rank-2
correlation matrices of equal size.

```
spec_NNNNNN/
├── @mpgo_class = "TTIOTwoDimensionalCorrelationSpectrum"
├── arrays/
│   ├── variable_axis  (float64[N])
│   ├── synchronous    (float64[N][N], row-major; in-phase, symmetric)
│   └── asynchronous   (float64[N][N], row-major; quadrature, antisymmetric)
```

Both matrices share the single variable axis — `nu_1 == nu_2`, so
no separate F1/F2 dimension scales are attached (differs from
§8's native 2-D NMR layout). Construction validates squareness
(`synchronous.shape == asynchronous.shape == (N, N)`).

Feature flag (opt_): `opt_native_2d_cos`. Pre-v0.11.1 readers
without the flag see the three arrays as opaque channels on a
generic `Spectrum` and round-trip them unchanged.

---

## 8. Native 2-D NMR

An `TTIONMR2DSpectrum` group (written via the generic
`TTIOSpectrum` persistence path under
`/study/nmr_runs/<run>/spec_NNNNNN/`) carries:

```
spec_NNNNNN/
├── @mpgo_class = "TTIONMR2DSpectrum"
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

`TTIOSpectralDataset.encryptWithKey:level:error:` performs two
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
- `@access_policy_json` (JSON representation of `TTIOAccessPolicy`)

`decryptWithKey:` reverses both operations.

Feature flag (opt_): `opt_dataset_encryption`. Required features may
also list `compound_identifications`/`compound_quantifications` even
after encryption, since those compound datasets will be restored on
decrypt.

### 9.1 Per-AU encryption (v1.0, `opt_per_au_encryption`)

v0.x encryption (above) encrypts an entire channel as a single
AES-GCM operation, which is incompatible with the per-Access-Unit
streaming transport introduced in v0.10. v1.0 adds a
per-spectrum encryption mode gated on the
`opt_per_au_encryption` feature flag.

New on-disk layout, one compound dataset per channel under
`/study/ms_runs/<run>/signal_channels/`:

```
<channel>_segments          HDF5 compound, spectrum_count rows
    offset     uint64        index into the plaintext element stream
    length     uint32        plaintext element count
    iv         uint8[12]     per-row AES-256-GCM IV
    tag        uint8[16]     per-row GCM tag
    ciphertext VL[uint8]     ciphertext bytes
@<channel>_algorithm        "aes-256-gcm"
@<channel>_wrapped_dek      VL uint8
@<channel>_kek_algorithm    "rsa-oaep-sha256" | "ml-kem-1024" | …
```

Each row's AES-GCM operation uses authenticated data
`dataset_id (u16 LE) || row_index (u32 LE) || channel_name_utf8`
so ciphertext cannot be replayed against a different spectrum
or channel.

When `opt_encrypted_au_headers` is also set, the plaintext
`spectrum_index/*` arrays from §4 are **omitted** and replaced
with:

```
spectrum_index/au_header_segments   HDF5 compound, one row per spectrum
    iv         uint8[12]
    tag        uint8[16]
    ciphertext uint8[36]     fixed-length plaintext (36 bytes):
        acquisition_mode(u8) || ms_level(u8) || polarity(u8)
        || retention_time(f64) || precursor_mz(f64)
        || precursor_charge(u8) || ion_mobility(f64)
        || base_peak_intensity(f64)
@wrapped_dek                 same DEK as the channel segments
```

AAD for the header row = `dataset_id || row_index || "header"`.

No v0.x back-compat: files using the v0.x channel-grained
encryption layout cannot be opened by v1.0 encryption paths.
The legacy decryption code remains for migration; see the
`--transcode` flow described in
`docs/transport-encryption-design.md` §6.

---

## 10. Digital signatures

`TTIOSignatureManager.signDataset:inFile:withKey:error:` computes an
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
native type. This is how the v0.2 `signed.tio` reference fixture
continues to verify under v0.3 readers.

### 10.2b v3 post-quantum signatures (v0.8 M49)

ML-DSA-87 (FIPS 204) signatures are stored as:

```
"v3:" + base64(ml_dsa_87_signature_bytes)
```

The signature covers the same canonical little-endian byte stream
as v2, so a file can carry either flavor without format changes
beyond the prefix. A reader that sees a `v3:` prefix but does not
support PQC raises `UnsupportedAlgorithmError` — it does not
silently pass verification. The presence of any v3 signature on a
file causes `opt_pqc_preview` to be added to the root feature
list; see `docs/pqc.md` and `docs/feature-flags.md §v0.8` for the
full story.

### 10.3 Cross-language parity

The TTIO Objective-C and Python implementations produce byte-identical
`v2:` MACs for the same input (see the `TtioSign` CLI test harness
under `objc/Tools/` and `python/tests/test_canonical_signatures.py`).

Feature flags: `opt_digital_signatures` (first sign), plus
`opt_canonical_signatures` when any `v2:` signature is present.

---

## 10c. Byte-level protocol contract (M43, v0.7)

All cryptographic paths — signatures and dataset / envelope encryption
— consume their input through the `StorageDataset.read_canonical_bytes`
method defined by the protocol abstraction
(`TTIOStorageDataset`, `global.thalion.ttio.providers.StorageDataset`,
`ttio.providers.base.StorageDataset`). The canonical stream is:

- **Primitive numeric datasets** — little-endian packed values.
- **Compound datasets** — rows in storage order; fields in declaration
  order. Variable-length strings encoded as `u32_le(length) ||
  utf-8_bytes`. Numeric fields little-endian.

On big-endian hosts the conversion is an explicit byteswap (HDF5's
automatic type conversion is **not** relied on). Every provider that
ships with v0.7 (`Hdf5Provider`, `MemoryProvider`, `SqliteProvider`,
`ZarrProvider`) emits bit-equal bytes for the same logical data;
cross-backend round-trip tests in
`python/tests/test_canonical_bytes_cross_backend.py` and
`python/tests/test_zarr_provider.py::test_compound_canonical_bytes_matches_hdf5`
lock that guarantee.

Binding decision 37: a signed or encrypted dataset verifies
identically regardless of which provider wrote it.

---

## 10.4 Compression codecs (M21, v0.3)

Signal-channel datasets carry their compression codec via either the
HDF5 filter pipeline or a dedicated per-channel attribute:

| Codec                  | Transport                                                                                                                                                                     |
|------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **zlib** (default)     | `H5P_DEFLATE` filter at level 6. Lossless. Readable by any HDF5 library without extra plugins.                                                                                |
| **LZ4**                | HDF5 filter id **32004**. Requires the LZ4 filter plugin (`libh5lz4.so`) to be loadable at runtime via `HDF5_PLUGIN_PATH`. Lossless. ~35× faster write / ~2× faster read than zlib, at ~20% larger files on random data. |
| **Numpress-delta**     | Per-channel transform implemented inside TTIO, **not** an HDF5 filter. The dataset stores an `int64` array of first differences of a fixed-point quantised signal. The signal_channels group carries `@<channel>_numpress_fixed_point` (int64) giving the scaling factor. Readers detect the codec via that attribute. Lossy, sub-ppm relative error for typical mass-spectrometry m/z. Clean-room implementation from Teleman et al., *MCP* 13(6), 2014. |
| **rANS-order0**        | Range-asymmetric numeral systems entropy coder, order-0 (per-byte) frequency model. Codec id `4`. **Implemented in M83** (v0.12 unreleased) across all three languages — clean-room from Duda 2014, no htslib source consulted. Wire format, deterministic frequency-table normalisation, and cross-language conformance contract specified in `docs/codecs/rans.md`. Standalone primitive only; signal-channel pipeline wiring lands in M86. |
| **rANS-order1**        | Order-1 (preceding-byte context) rANS variant. Codec id `5`. **Implemented in M83** alongside order-0 — same wire format, per-context frequency tables (256 of them) with run-length-encoded sparse rows. See `docs/codecs/rans.md`. |
| **base-pack**          | 2-bit ACGT packed-base codec for genomic read sequences. Codec id `6`. Lossless on the full byte alphabet via a sparse position+byte sidecar mask: bases that are uppercase `{A,C,G,T}` pack into 2-bit slots (4 bases per output byte, big-endian within byte), everything else (`N`, IUPAC ambiguity codes, lowercase soft-masking, gaps) is recorded in the mask alongside its input position so the decoder restores it byte-for-byte. **Implemented in M84** (v0.12 unreleased) across all three languages — clean-room implementation, no htslib / CRAM tools-Java / jbzip source consulted. Wire format and case-sensitivity rationale in `docs/codecs/base_pack.md`. Standalone primitive only; signal-channel pipeline wiring lands in M86. |
| **quality-binned**     | Illumina-style quality-score binning that maps 40+ raw Phred levels onto 8 bins (CRUMBLE-derived bin table, fixed in v0 of scheme `0x00`). 4-bit-packed bin indices, big-endian within byte. Codec id `7`. Lossy by construction (decode returns the bin centre, not the original Phred). **Implemented in M85 Phase A** (v0.12 unreleased) across all three languages — clean-room implementation, no htslib / CRUMBLE / NCBI SRA toolkit source consulted. Wire format and bin table specified in `docs/codecs/quality.md`. Standalone primitive only; signal-channel pipeline wiring is a future M86 phase. |
| **name-tokenized**     | Read-name tokenisation: each name is split into numeric and string tokens, per-column type detection picks columnar (delta-encoded numerics + dictionary-encoded strings) or verbatim mode. Codec id `8`. Lossless. **Implemented in M85 Phase B** (v0.12 unreleased) across all three languages — clean-room lean implementation, no htslib / CRAM tools-Java / samtools / SRA toolkit / Bonfield 2022 reference source consulted. Wire format and tokenisation rules in `docs/codecs/name_tokenizer.md`. Standalone primitive only; signal-channel pipeline wiring is a future M86 phase. The lean implementation achieves ~3-7:1 compression on structured Illumina names; reaching the original ≥ 20:1 target requires the full Bonfield 2022 token-type set and is a future optimisation milestone. |

The five reserved codec ids (`4`–`8`) are committed to the disk
format in M79 so cross-language readers see a stable enum table
before encoders land. **As of v0.12.x (post-M85 Phase B) all
five (rANS order-0, rANS order-1, base-pack, quality-binned,
name-tokenized) ship as standalone primitives in all three
languages — the genomic codec library is conceptually complete.**

Ids `4`, `5`, `6` are also wired into the genomic signal-channel
write/read pipeline for the `sequences` and `qualities` byte
channels (M86 Phase A) — see §10.5 for the `@compression`
attribute scheme. Ids `7` (quality-binned) and `8`
(name-tokenized) ship as primitives only; the pipeline-wiring
branches that interpret `@compression == 7` on a `qualities`
dataset and `@compression == 8` on a `read_names` dataset are
future M86 phases. Integer channels (`positions`, `flags`,
`mapping_qualities`) and remaining VL_STRING channels (`cigars`,
`mate_info`) continue to use HDF5-filter ZLIB; the channel-codec
applicability table will grow as future M86 phases land.

> **Note on CRAM 3.1 specifically.** The reserved names above map
> to CRAM-3.0-era codecs. CRAM 3.1 adds the rANS-Nx16 streams (four
> variants — order 0/1 × stripe/RLE), the fqzcomp-derived quality
> codec, and adaptive arithmetic. **None of those CRAM-3.1-specific
> codecs are reserved or implemented.** Adding them would require
> additional enum slots (codec ids `9`+) plus encoders, decoders,
> and a cross-language conformance harness. Tracked under "Genomic
> codec milestone" in WORKPLAN.

## 10.5 `@compression` attribute on signal-channel datasets (M86)

Genomic signal-channel datasets (`signal_channels/sequences` and
`signal_channels/qualities` under `/study/genomic_runs/<name>/`)
that use a TTI-O internal compression codec (rANS order-0, rANS
order-1, BASE_PACK) carry a `@compression` attribute holding the
M79 codec id. The attribute type is `H5T_NATIVE_UINT8` (one byte).
The dataset bytes ARE the self-contained codec stream specified in
`docs/codecs/rans.md` (ids `4`, `5`) or `docs/codecs/base_pack.md`
(id `6`). **No HDF5 filter is applied to such datasets** — the
codec output is high-entropy and would not benefit from deflate.

Absence of the attribute, or value `0` (`Compression.NONE`), means
the dataset is stored as-is and any HDF5 filter applies (typically
zlib level 6, the default for genomic byte channels). The attribute
is written ONLY when an override is in effect; uncompressed channels
have no `@compression` attribute at all.

Pre-M86 readers that ignore `@compression` will silently
misinterpret a v0.12-encoded channel: the read path slices into a
non-sliceable codec stream and returns garbage for any read whose
offset/length walks past the encoded payload boundary. The
attribute is the canonical signal for codec dispatch — any
TTI-O-conformant reader from M86 onwards must check it before
slicing.

M86 wires this attribute scheme for the **byte channels only**:
`sequences` and `qualities`. Integer channels (`positions`,
`flags`, `mapping_qualities`) and VL_STRING channels (`cigars`,
`read_names`, `mate_info`) do not yet support TTI-O codecs; they
ignore `@compression` if set and stay on HDF5-filter ZLIB. Lifting
that restriction (integer-channel codecs, plus M85's
name-tokenizer for read_names) is a future milestone.

### Read-side dispatch (informative)

When opening a `sequences` or `qualities` dataset, an M86 reader:

1. Checks for the `@compression` attribute. If absent or `0`, uses
   the existing slice-based read path (no change from M82).
2. If `4`, `5`, or `6`, reads ALL dataset bytes, decodes the whole
   stream through the corresponding `decode()` function, and
   caches the decoded buffer on the open `GenomicRun` instance.
   Subsequent per-read access slices the cached buffer in memory.

This decode-once-cache strategy is the natural shape for the
M83/M84 codecs, which produce non-sliceable byte streams. The
memory cost is one decoded channel per open run instance —
acceptable for typical sequencing workloads.

### Precision additions (M79, v0.11)

`TTIOPrecision` gains `UINT8` (id `6`) for byte-typed datasets —
genomic packed-base buffers, quality-score arrays, and any future
per-element symbol stream that does not need wider integers. The
existing storage providers (HDF5, Memory, SQLite, Zarr) honour
`UINT8` byte-exactly; canonical bytes for a `UINT8` dataset are the
raw payload (endian-neutral).

### Numpress-delta algorithm

1. Compute scale `S = floor((2^62 - 1) / max|v|)`; degenerate ranges
   default to `S = 1`.
2. Quantise: `q[i] = llround(v[i] * S)` (IEEE-754 round-to-even).
3. Emit `deltas[0] = q[0]`, `deltas[i] = q[i] - q[i-1]` for `i ≥ 1`.
4. Store `deltas` as the `<channel>_values` int64 HDF5 dataset with
   zlib on top.

Decoding is the exact inverse: cumsum the int64 array, cast to
double, divide by the scale. The TTIO ObjC and Python encoders agree
byte-for-byte on any input (see `test_numpress_scale_matches_objc_formula`).

## 11. Backward compatibility

A v0.2 reader recognizes a v0.1 file by the absence of
`@ttio_features`. The fallback paths:

| v0.2 location                              | v0.1 fallback                              |
|--------------------------------------------|--------------------------------------------|
| `/study/identifications` compound dataset  | `/study/@identifications_json` string attr |
| `/study/quantifications` compound dataset  | `/study/@quantifications_json` string attr |
| `/study/provenance` compound dataset       | `/study/@provenance_json` string attr      |
| `/study/image_cube/` group                 | `/image_cube/` at root                     |
| `spectrum_index/headers` compound dataset  | parallel 1-D datasets only (still present) |
| `intensity_matrix_2d` rank-2 dataset       | `arrays/intensity_matrix` flattened 1-D    |

All v0.1 files written by libTTIO v0.1.0-alpha are readable by v0.2.0
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

### 11.2 Per-AU encrypted layout (v0.10+)

A v0.10 reader recognises a per-AU-encrypted file by
`opt_per_au_encryption` in `@ttio_features`. The channel layout
under `signal_channels/` flips from plaintext `<channel>_values`
to the `<channel>_segments` compound (§9.1) with VL_BYTES members
for `iv` / `tag` / `ciphertext`. Pre-v0.10 readers without
VL_BYTES compound support will refuse to open the file (the flag
is non-optional when set).

When `opt_encrypted_au_headers` is also present, the six plaintext
index arrays (retention_times, ms_levels, polarities,
precursor_mzs, precursor_charges, base_peak_intensities) are
absent; the semantic header travels in the
`spectrum_index/au_header_segments` compound instead. `offsets`
and `lengths` remain plaintext because they frame the compound
rows.

Migration: `python -m ttio.tools.per_au_cli transcode` rewrites
a plaintext or previously-encrypted file through the v0.10 path,
with optional `--rekey`. v0.x `opt_dataset_encryption` files must
be decrypted via the v0.x `SpectralDataset.decrypt()` API first —
channel-level AES-GCM cannot be converted in place (the plaintext
must be materialised to re-slice per-spectrum).

---

## 12. Example `h5dump` output (minimal MS file)

```
HDF5 "minimal_ms.tio" {
GROUP "/" {
   ATTRIBUTE "ttio_format_version" { DATATYPE H5T_STRING ... DATA { "1.1" } }
   ATTRIBUTE "ttio_features" { DATA { "[\"base_v1\",\"compound_identifications\",...]" } }
   GROUP "study" {
      ATTRIBUTE "title" { ... }
      GROUP "ms_runs" {
         ATTRIBUTE "_run_names" { DATA { "run_0001" } }
         GROUP "run_0001" {
            ATTRIBUTE "acquisition_mode"  { DATA { 0 } }
            ATTRIBUTE "spectrum_count"    { DATA { 10 } }
            ATTRIBUTE "spectrum_class"    { DATA { "TTIOMassSpectrum" } }
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
2. Read `@ttio_format_version`. If absent, treat as v0.1.
3. Read `@ttio_features` as a JSON array. Refuse the file if any
   non-`opt_`-prefixed feature is unknown.
4. Open `/study/`. Read `@title`, `@isa_investigation_id`.
5. Enumerate runs under `/study/ms_runs/` via the `_run_names`
   attribute.
6. For each run, read `@spectrum_class` (default
   `TTIOMassSpectrum`). Read `spectrum_index/` parallel datasets.
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
