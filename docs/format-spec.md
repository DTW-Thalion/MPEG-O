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
| **ref-diff**           | Reference-based sequence-diff codec. Codec id `9`. **Context-aware** — encoder/decoder consume sibling channels (`positions`, `cigars`) and an external reference resolver alongside the channel bytes. For each cigar M-op base, a single bit records match-vs-substitution (1 = sub, with the actual base following as 8 bits MSB-first). I/S-op bases are appended verbatim; D/H/N/P ops carry no payload. The resulting bitstream is rANS-order-0-encoded per 10K-read slice (CRAM-aligned). **Implemented in M93** (v1.2.0) across all three languages — clean-room implementation modelled on the published CRAM 3.1 spec, no htslib / tools-Java source consulted. Wire format, slice strategy, embedded reference layout, and binding decisions in `docs/codecs/ref_diff.md`. Sequence-channel pipeline wiring lands in M93 (this milestone). Falls back to BASE_PACK silently when the reference is unavailable at write (Q5b in design spec); hard error on read when reference is unresolvable (Q5c). |
| **fqzcomp-nx16**       | ~~Lossless quality-score codec, codec id `10`. Context-modeled adaptive arithmetic coding with SplitMix64 context hashing.~~ **REMOVED in Phase 10 (2026-04-30)** — too slow (~0.16 MB/s vs CRAM 3.1's ~3 GB/s) to ship. Java preserves enum ordinal 10 as `_RESERVED_10` (`@Deprecated`); ObjC uses `TTIOCompressionReserved10`. The default v1.5 quality codec is now `fqzcomp-nx16-z` (codec id `12`); the v1 codec was never released outside development and no .tio files in the wild used it. |
| **fqzcomp-nx16-z**     | Lossless quality-score codec, CRAM-mimic variant. Codec id `12`. Magic `M94Z`. Static-per-block frequency tables (build pass + frozen encode pass), 16-bit renormalisation (`B = 16`, `b = 2^16`), `T = 4096` fixed (12-bit shift). `T` divides `b*L = 2^31` exactly, making byte-pairing mathematically guaranteed (see `docs/codecs/fqzcomp_nx16_z.md` §8). Bit-pack context model: 12 bits `prev_q` + 2 bits position bucket + 1 bit revcomp, masked to `2^14` slots. 4-way interleaved rANS states. Header carries the freq tables (zlib-deflated) so the decoder skips the build pass. **Implemented in M94.Z** (v1.2.0) across all three languages — clean-room implementation of CRAM 3.1 `rANS-Nx16` discipline (htscodecs master), no htslib / tools-Java source consulted. **Two on-disk shapes share magic + codec id, distinguished by version byte:** version `1` (canonical for v1.5 files; pure-language rANS body, four contiguous substreams) and version `2` (Phase 10 / 2026-04-30; opt-in via `prefer_native` or `TTIO_M94Z_USE_NATIVE=1`; libttio_rans byte layout `[4×states LE][4×lane_sizes LE][per-lane data]` with no trailer). Both versions decode in pure language; native decode for V2 is wired but off by default (callback-overhead bottleneck — see `docs/native-rans-library.md` §4). Wire format and binding decisions §90a–§90e in `docs/codecs/fqzcomp_nx16_z.md`. **Default for v1.5 quality channels** when a run already qualifies as v1.5 (any v1.5 codec already in use elsewhere on the run). |

The five reserved codec ids (`4`–`8`) are committed to the disk
format in M79 so cross-language readers see a stable enum table
before encoders land. **As of v0.12.x (post-M86 Phase D) all
five (rANS order-0, rANS order-1, base-pack, quality-binned,
name-tokenized) ship as standalone primitives in all three
languages — the genomic codec library is conceptually complete.**

**v1.2 / M93 adds codec id `9` (REF_DIFF)** — the first
context-aware codec, applicable to the `sequences` channel of
reference-aligned `WrittenGenomicRun` instances. **v1.2 / M94
adds codec id `10` (FQZCOMP_NX16)** — lossless quality codec
with context-modeled adaptive arithmetic coding + 4-way rANS,
applicable to the `qualities` channel. M95 (codec id `11`,
DELTA_RANS_ORDER0) extends the table further; see
`docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md`.
**v1.2 / M94.Z adds codec id `12` (FQZCOMP_NX16_Z)** — a
CRAM-mimic FQZCOMP_NX16 variant with static-per-block freq
tables, 16-bit renormalisation, and `T = 4096` fixed power-of-2
total (`T | b*L` exactly), making byte-pairing mathematically
guaranteed. Codec id 10 is RETAINED for backward compatibility
with v1.1.x M94 v1 fixtures and in-flight files; the v1.5
default codec stack uses id `12` for new files on the
`qualities` channel. See
`docs/codecs/fqzcomp_nx16_z.md` and
`docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md`.

Ids `4`, `5`, `6`, `7`, and `8` are all wired into the genomic
signal-channel write/read pipeline. The codec applicability per
channel is:

- Ids `4`, `5`, `6` apply to both `sequences` and `qualities`
  byte channels (M86 Phase A).
- Id `7` (quality-binned) applies to the `qualities` byte
  channel only — validation rejects QUALITY_BINNED on
  `sequences` because Phred-bin quantisation would silently
  destroy ACGT data (M86 Phase D).
- Id `8` (name-tokenized) applies to the `read_names` channel
  (M86 Phase E) AND the `cigars` channel (M86 Phase C) —
  validation rejects NAME_TOKENIZED on sequences/qualities/
  integer channels because the codec tokenises UTF-8 strings,
  not binary byte streams. Both channels use a schema-lift
  pattern (compound → flat uint8).
- Ids `4` and `5` (rANS order-0/1) also apply to the **integer
  channels** `positions` (int64), `flags` (uint32), and
  `mapping_qualities` (uint8) via the int↔byte serialisation
  contract in §10.7 (M86 Phase B). Validation rejects ids `6`,
  `7`, `8` on integer channels.
- Ids `4` and `5` ALSO apply to the **cigars channel** via a
  length-prefix-concat serialisation contract — see §10.8 for
  the codec-selection guidance (rANS is the recommended
  default; NAME_TOKENIZED is the niche choice for uniform
  CIGARs).
- The **mate_info channel** (M82 compound: chrom + pos + tlen)
  is decomposed into three per-field virtual channels
  (`mate_info_chrom`, `mate_info_pos`, `mate_info_tlen`) when
  any per-field override is set — see §10.9 for the subgroup
  schema and per-field codec applicability. The chrom field
  takes the same codec set as cigars
  ({RANS_ORDER0/1, NAME_TOKENIZED}); pos/tlen take the
  integer-channel set ({RANS_ORDER0/1}).

See §10.5 for the byte-channel `@compression` attribute
scheme, §10.6 for the `read_names` schema-lift pattern, §10.7
for the integer-channel serialisation contract, §10.8 for the
cigars channel and codec-selection guidance, and §10.9 for the
mate_info subgroup and per-field decomposition.

**The genomic codec pipeline-wiring is now complete for ALL
M82 channels.** Every channel under `signal_channels/`
supports at least one codec choice; every M79 codec slot
(4–8) is wired into its applicable channels with cross-
language byte-exact conformance.

> **Note on CRAM 3.1 specifically.** v1.2 begins parity with CRAM
> 3.1's compression characteristics: REF_DIFF (codec id `9`, M93)
> matches CRAM's reference-based sequence diff, and the M94/M95
> milestones add fqzcomp-Nx16 quality coding (id `10`) and
> delta-encoded sorted integer channels (id `11`). With the M93/M94/M95
> trio shipped, TTI-O closes the architectural compression gap to
> CRAM 3.1's lossless profile.

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

## 10.6 `read_names` schema lift under NAME_TOKENIZED (M86 Phase E)

`signal_channels/read_names` has two on-disk layouts depending
on whether the M85-Phase-B NAME_TOKENIZED codec was selected at
write time via `signal_codec_overrides`:

- **No override (M82 default):** compound dataset of shape
  `[n_reads]` with field `{value: VL_STRING}`. Backward
  compatible with M82 readers.
- **NAME_TOKENIZED override active:** flat 1-D `UINT8` dataset
  of length = `name_tokenizer.encode()` output size, with the
  `@compression` attribute set to `8`. The dataset bytes are
  the self-contained NAME_TOKENIZED stream specified in
  `docs/codecs/name_tokenizer.md` §2. **No HDF5 filter** is
  applied (the codec output is high-entropy).

The two layouts are mutually exclusive within a single run and
share the same dataset name. Readers MUST dispatch on dataset
shape — a compound dataset uses the M82 read path; a 1-D
`UINT8` dataset requires the codec dispatch path. The
`@compression` attribute is the canonical secondary signal: if
present and equal to `8`, decode through `name_tokenizer`. If
present with any other value, the dataset is malformed (no
other codec applies to `read_names` in M86 Phase E).

**Pre-M86-Phase-E reader behaviour:** A v0.12 file with the
override is **unreadable** by pre-M86 readers — they expect
the M82 compound layout and will silently misinterpret the
flat-uint8 dataset as a corrupt compound. Discipline matches
M80 / M82 / M86 Phase A (write-forward, no back-compat shim).
Files written without the override remain identical to M82
output and are read identically by all reader versions.

The other VL_STRING channels (`cigars`, `mate_info`) do NOT
currently support a codec override; they remain in compound
storage. `cigars` would want an RLE-then-rANS pipeline (no
codec match in M79); `mate_info` is an integer-tuple compound
with no codec match.

## 10.7 Integer-channel codec wiring under `signal_channels/` (v1.5 LEGACY — REMOVED in v1.6)

> **Status: REMOVED in v1.6 (L4, 2026-05-03).** v1.5 and earlier wrote
> `positions` (int64), `flags` (uint32), and `mapping_qualities`
> (uint8) under `signal_channels/` AS WELL AS under `genomic_index/`.
> v1.6 drops the `signal_channels/` copies — they were dead bytes
> (no reader path actually consumed them) provisioned for an
> aspirational "streaming reader prefers signal_channels" future that
> contradicted MS's `spectrum_index/` pattern. Per-record integer
> metadata is now stored exclusively under `genomic_index/`,
> mirroring MS exactly: `<run>/genomic_index/` = per-record metadata
> (eagerly loaded), `<run>/signal_channels/` = bulk per-base /
> variable-length data.
>
> **Override behaviour in v1.6+:** Setting
> `signal_codec_overrides[positions|flags|mapping_qualities]` raises
> a `ValueError` (Python) / `IllegalArgumentException` (Java) /
> `NSInvalidArgumentException` (Objective-C) at write time, with a
> message pointing at this section.
>
> **Backward compatibility:** v1.6+ readers continue to read v1.5
> files correctly — the reader path uses `genomic_index/` (which is
> unchanged across versions). The `signal_channels/` duplicates in
> v1.5 files are simply ignored.

The remainder of this section describes the on-disk layout that v1.5
files MAY contain under `signal_channels/` for these three channels,
kept here for legacy decode reference. v1.6+ writers do not emit; v1.6+
readers do not decode (the canonical source is `genomic_index/`).

Integer channels under `signal_channels/` (`positions` int64,
`flags` uint32, `mapping_qualities` uint8) accepted
`@compression` values of `4` (RANS_ORDER0) or `5`
(RANS_ORDER1). When set:

- The dataset was stored as a flat 1-D `UINT8` of length =
  `Rans.encode()` output size, with no HDF5 filter.
- The bytes were the rANS-coded **little-endian** byte
  representation of the original integer array. For an int64
  array of N elements, the input to the codec was `N × 8` bytes
  in LE order; for uint32, `N × 4` bytes; for uint8, `N` bytes
  (LE serialisation is a no-op for single-byte elements).
- The reader determined the original dtype by **channel-name
  lookup**: `positions → int64`, `flags → uint32`,
  `mapping_qualities → uint8`. No on-disk dtype attribute.

Other codec ids (`6` = BASE_PACK, `7` = QUALITY_BINNED, `8` =
NAME_TOKENIZED) were rejected on integer channels at write-time
validation — they are content-specific codecs (ACGT packing,
Phred-bin quantisation, string tokenisation) and would not
preserve integer values.

The endianness convention (little-endian) was fixed and
non-negotiable across all three implementations (Python: numpy
dtype strings `<i8`, `<u4`, `<u1`; ObjC:
`OSSwapHostToLittleInt64`/`htole64` etc.; Java:
`ByteBuffer.LITTLE_ENDIAN` with `putLong`/`putInt`/`put`).
This is preserved in the still-active `mate_info_pos` and
`mate_info_tlen` integer-channel codec wiring under §10.9.

## 10.8 cigars channel codec wiring (M86 Phase C)

The `cigars` channel under `signal_channels/` accepts THREE
codec choices via `@compression`. Each uses the same
schema-lift pattern as `read_names` (compound → flat 1-D
uint8) but with three possible decode paths.

### 10.8.1 On-disk schema

**No override (M82 default):** compound dataset of shape
`[n_reads]` with field `{value: VL_STRING}`. Backward
compatible with M82 readers.

**Override active (any of the three accepted codecs):** flat
1-D `UINT8` dataset of length = encoded byte count, with
`@compression` attribute set to the codec id. **No HDF5
filter** is applied.

| `@compression` | Codec          | Decode path |
|----------------|----------------|-------------|
| `4`            | RANS_ORDER0    | `Rans.decode(stream)` → walk varint-length-prefix entries → `list[str]` |
| `5`            | RANS_ORDER1    | same as above |
| `8`            | NAME_TOKENIZED | `NameTokenizer.decode(stream)` → `list[str]` (codec's own self-describing wire format) |

The same dataset name (`cigars`) is used in all three cases;
the `@compression` value disambiguates the decode path. A
1-D `UINT8` dataset with an `@compression` value not in
{4, 5, 8} is malformed.

### 10.8.2 The rANS-on-cigars serialisation contract

When the override is `RANS_ORDER0` or `RANS_ORDER1`, the
encoder serialises the `list[str]` of CIGARs to a flat byte
stream using length-prefix concatenation:

```
For each cigar in cigars:
    emit varint(len(cigar.encode('ascii')))
    emit cigar.encode('ascii')
```

Varints are unsigned LEB128 (low 7 bits + continuation
flag — same as M85 Phase B's NAME_TOKENIZED varints). The
serialised buffer is then encoded via `Rans.encode(buf,
order)`. The decoder reverses: `Rans.decode(stream)` → byte
buffer → walk varint-length-prefix entries until exhausted.

CIGAR strings are 7-bit ASCII per the SAM spec; encoders
reject non-ASCII input.

This is **wire-level distinct from NAME_TOKENIZED's verbatim
mode** (which has a 7-byte NAME_TOKENIZED header before the
length-prefix entries). The rANS-on-cigars path uses raw
length-prefix-concat directly because rANS's own
self-contained header already records the original byte
count.

### 10.8.3 Codec selection guidance

Different CIGAR distributions favour different codecs:

| Workload                              | Best choice      |
|---------------------------------------|------------------|
| All reads identical CIGAR (synthetic) | `NAME_TOKENIZED` |
| Tiny dataset (< 100 reads), uniform   | `NAME_TOKENIZED` |
| **Mixed token-count (real WGS)**      | **`RANS_ORDER1`** |
| Large dataset (> 1000 reads)          | **`RANS_ORDER1`** |
| Unknown / general default             | **`RANS_ORDER1`** |

NAME_TOKENIZED's columnar mode wins big on uniform-CIGAR
inputs (single dictionary entry + delta=0 numeric column
gives ~2 bytes per read). But mixed token-count input (real
WGS data with indels and clips) sends NAME_TOKENIZED to its
verbatim fallback mode — essentially raw bytes with a tiny
header, no compression.

**rANS is the recommended default for real data** because it
exploits byte-level repetition over the limited CIGAR
alphabet (digits 0-9 + ~9 operator letters MIDNSHP=X)
regardless of token-count uniformity. Empirical numbers
(measured byte-identical across Python / ObjC / Java via
M83 + M85B conformance, 1000-read mixed CIGARs):

- M82 compound (no override): ~18-29 KB depending on HDF5
  filter behaviour.
- NAME_TOKENIZED (verbatim mode kicks in): **5307 bytes**.
- RANS_ORDER1: **1111 bytes** (~17× smaller than baseline).

### 10.8.4 Read-side dispatch

Readers MUST inspect dataset shape (compound vs 1-D uint8)
before assuming the M82 layout. If 1-D uint8, dispatch on
`@compression`:
- 4 or 5: `Rans.decode` then walk varint-length-prefix.
- 8: `NameTokenizer.decode`.
- Other or absent: malformed (raise).

Pre-M86-Phase-C readers that hard-code the compound layout
will fail when they hit the flat-uint8 layout. Discipline
matches M80 / M82 / M86 Phase A/E (write-forward, no
back-compat shim).

## 10.9 mate_info per-field decomposition (M86 Phase F — v1.7 OPT-OUT only)

> **v1.7 status:** This v1 layout is no longer the default. v1.7 ships
> the inline_v2 codec (§10.9b) as the default. The v1 per-field
> decomposition is reachable only via
> `WrittenGenomicRun.opt_disable_inline_mate_info_v2 = True`
> (Python) / `optDisableInlineMateInfoV2 = YES` (ObjC) /
> `.optDisableInlineMateInfoV2(true)` (Java).

The mate_info channel under `signal_channels/` has TWO on-disk
layouts depending on whether any `mate_info_*` per-field
override is set in `signal_codec_overrides`.

### 10.9.1 On-disk schema

**No override (M82 default):** COMPOUND dataset of shape
`[n_reads]` with three fields:

```
signal_channels/mate_info: COMPOUND[n_reads] {
    chrom: VL_STRING,
    pos:   INT64,
    tlen:  INT32
}
```

Backward compatible with M82 readers.

**Any mate_info_* override active:** SUBGROUP containing three
child datasets:

```
signal_channels/mate_info/             # GROUP, not dataset
    chrom: <one of three layouts>
        VL_STRING[n_reads]  (HDF5 ZLIB)        # if no chrom override
        UINT8[encoded_len]  @compression=4|5   # if rANS chrom override
        UINT8[encoded_len]  @compression=8     # if NAME_TOK chrom override
    pos:   <one of two layouts>
        INT64[n_reads]      (HDF5 ZLIB)        # if no pos override
        UINT8[encoded_len]  @compression=4|5   # if rANS pos override
    tlen:  <one of two layouts>
        INT32[n_reads]      (HDF5 ZLIB)        # if no tlen override
        UINT8[encoded_len]  @compression=4|5   # if rANS tlen override
```

The `mate_info` link type (group vs dataset) is the primary
read-side dispatch signal. Each per-field child dataset
carries its own `@compression` attribute (or lacks one,
indicating natural-dtype storage). Partial overrides are
allowed: any one of the three per-field overrides triggers
the subgroup layout, and un-overridden fields use natural-
dtype HDF5 ZLIB storage inside the subgroup.

### 10.9.2 API: per-field virtual channel names

The override is exposed as three flat-dict keys in
`signal_codec_overrides`:

| Key                | Allowed codecs                          |
|--------------------|------------------------------------------|
| `mate_info_chrom`  | RANS_ORDER0, RANS_ORDER1, NAME_TOKENIZED |
| `mate_info_pos`    | RANS_ORDER0, RANS_ORDER1                 |
| `mate_info_tlen`   | RANS_ORDER0, RANS_ORDER1                 |

The bare key `"mate_info"` is **rejected** at write-time
validation with a message pointing at the three per-field
keys. (NAME_TOKENIZED is wrong-content for the integer fields
pos and tlen; BASE_PACK and QUALITY_BINNED are wrong-content
for all three.)

### 10.9.3 Per-field serialisation contracts

The `chrom` field's rANS path uses **length-prefix-concat
serialisation** (the same contract as the cigars channel
from §10.8.2): each chrom is emitted as `varint(len) +
ascii bytes`, the concatenated buffer is fed to
`Rans.encode(buf, order)`. The NAME_TOKENIZED path calls
`NameTokenizer.encode(chroms)` directly.

The `pos` (int64) and `tlen` (int32) fields' rANS paths use
the **integer-channel LE byte serialisation** from §10.7:
each array is converted to little-endian byte representation
(`<i8` for pos, `<i4` for tlen), concatenated, then fed to
`Rans.encode(buf, order)`. The reader interprets the decoded
bytes via the channel-name → dtype lookup (`pos → int64`,
`tlen → int32`).

### 10.9.4 Read-side dispatch

Readers MUST inspect the `signal_channels/mate_info` link
type before assuming the M82 layout:

- `H5O_TYPE_DATASET` (or equivalent): M82 compound path.
  Existing read code unchanged.
- `H5O_TYPE_GROUP`: Phase F subgroup path. For each requested
  field, open the child dataset and dispatch on
  `@compression`:
  - `0` (no attribute): read directly as the natural dtype
    (VL_STRING for chrom; INT64 for pos; INT32 for tlen).
  - `4`/`5`: read all bytes; `Rans.decode`; for chrom, walk
    varint-length-prefix to recover `list[str]`; for pos/tlen,
    interpret bytes as the natural dtype (LE).
  - `8` (chrom only): `NameTokenizer.decode` → `list[str]`.

Pre-M86-Phase-F readers that hard-code the compound layout
will fail when they hit the subgroup. Discipline matches
M80 / M82 / M86 Phase A/E/C (write-forward, no back-compat
shim).

### 10.9.5 Why the chrom field commonly wins big with NAME_TOKENIZED

Mate chromosome alphabets are tiny in practice — typically
fewer than 30 distinct values across the whole run
(`chr1`..`chr22`, `chrX`, `chrY`, `chrM`, plus `*` for
unmapped mates). For paired sequencing data where most mates
are on the same chromosome as the read, the columnar
dictionary is a one-or-two-entry win that crushes the chrom
stream to a few bytes regardless of read count. The
NAME_TOKENIZED path is the default recommendation for
`mate_info_chrom`; the rANS path is available for unusual
inputs (e.g. heavily-fragmented chromosome assignments).

## 10.9b mate_info v2 inline codec (#11 v1.7, codec id 13)

**Default in v1.7+.** Encodes the full mate triple (mate_chrom_id,
mate_pos, tlen) as a single CRAM-style inline blob exploiting SAM
mate-pair invariants. Saves ~6.8 MB on chr22 vs the v1 per-field
layout from §10.9 (full-stack context); ~47.9 MB vs the M82 compound
baseline in the isolation gate (see
`docs/benchmarks/2026-05-03-mate-info-v2-results.md`).

### 10.9b.1 On-disk schema

Two sibling datasets under `signal_channels/mate_info/`:

```
signal_channels/mate_info/
├── inline_v2     uint8 1-D blob, @compression = 13 (MATE_INLINE_V2)
└── chrom_names   compound[(name, VL_STRING)], one row per chrom_id
```

The `inline_v2` blob carries a 34-byte container header + 4 substreams
(MF / NS / NP / TS); full wire format spec at
`docs/superpowers/specs/2026-05-03-mate-info-v2-design.md` §4.

The `chrom_names` sidecar is a compound dataset that maps chrom_ids
(row index) to chromosome names. **This is necessary because mate
chromosomes can reference chroms that no own-read uses** (e.g. a
properly aligned read on chr22 with a cross-chrom mate on chr11
where no other read aligns to chr11). The L1 `genomic_index/chromosome_names`
table only covers chroms that appear as own_chrom; mate-only chroms
would be lost without `chrom_names`.

The chrom_id assignment is encounter-order over `(own_chromosomes ∪
mate_chromosomes)`, with own chroms enumerated first. The `'='`
SAM shortcut is canonicalised at write time to the record's own
chrom_id; `'*'` maps to -1.

The 4-substream container wire format:

| Substream | Content | Encoding |
|-----------|---------|----------|
| MF | Per-record mate-flag (0=SAME_CHROM_NEARBY, 1=SAME_CHROM_FAR, 2=NO_MATE, 3=DIFF_CHROM) | raw-pack or rANS-O0 (auto-pick) |
| NS | Chrom_id for DIFF_CHROM records (0 elsewhere) | varint + rANS-O0 auto-pick |
| NP | Mate_pos: zigzag-varint delta for SAME_CHROM_NEARBY, absolute for DIFF_CHROM; 0 for others | varint + rANS-O0 auto-pick |
| TS | Template_length (zigzag-varint); 0 for NO_MATE | varint + rANS-O0 auto-pick |

Container header (34 bytes): 4-byte magic `b"MIv2"` + 1-byte version
`\x01` + 1-byte flags `\x00` + 4 × uint64 LE substream byte lengths.

### 10.9b.2 Reader-side dependency

Decoding `inline_v2` requires `genomic_index/positions` and
`genomic_index/chromosome_ids` to be loaded first. The decoder needs
own_pos and own_chrom_id per record to reconstruct mate_pos for
SAME_CHROM records (which use a delta encoding) and to validate the
MF taxonomy.

Readers must enforce this read order; the v1.7+ Python/Java/ObjC
implementations do so transparently.

### 10.9b.3 Backward compatibility

A v1.6 reader on a v1.7 file fails with "unknown compression id 13"
when it encounters the `inline_v2` dataset. The user must upgrade
the reader OR write the source file with
`opt_disable_inline_mate_info_v2 = True` to keep the v1 layout
from §10.9.

A v1.7 reader on a v1.6 file finds no `inline_v2` dataset and falls
through to the v1 layout transparently — the reader dispatches on
whether the subgroup contains `inline_v2` before checking for the
v1 per-field children.

### 10.9b.4 signal_codec_overrides interaction

Setting `signal_codec_overrides[mate_info_chrom / mate_info_pos /
mate_info_tlen]` when `opt_disable_inline_mate_info_v2 == False`
raises a write-time error pointing at the opt-out flag. The v1
per-field codec dispatch from §10.9 is only available under the
opt-out path.

### 10.9b.5 Cross-language byte-exact

The encode/decode primitives are implemented as a shared C kernel
in libttio_rans (`ttio_mate_info_v2_encode` / `ttio_mate_info_v2_decode`
entry points in `native/src/mate_info_v2.{c,h}`). All three language
implementations (Python ctypes, Java JNI, ObjC direct link) call
the same C functions, so the encoded byte stream is byte-exact
identical regardless of which language wrote the file. Verified at
test time by `python/tests/integration/test_mate_info_v2_cross_language.py`
(4 corpora × 3 languages = 12 byte-exact assertions, all PASS).

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

## 10.10 REF_DIFF codec — reference storage and pipeline integration (M93)

The REF_DIFF codec (codec id `9`, M93) is the first **context-aware**
codec in TTI-O: encoder and decoder consume sibling channels and an
external reference resolver alongside the channel bytes. This section
documents the on-disk layout that supports it; the codec algorithm
and wire format are specified in `docs/codecs/ref_diff.md`.

### Reference storage group `/study/references/<reference_uri>/`

When `WrittenGenomicRun.embed_reference == True` (the default) and
the run uses REF_DIFF on its `sequences` channel, the writer embeds
the covered chromosome sequences at:

```
/study/references/<reference_uri>/
  @md5             : fixed-length string — 32-char hex of md5(concat(
                     sorted_chromosomes_in_uri_order))
  @reference_uri   : fixed-length string — the URI itself
  chromosomes/
    <chrom_name>/
      @length      : int64 — chromosome length in bases
      data         : 1-D uint8 dataset of uppercase ACGTN bytes
                     (zlib-compressed)
```

**Auto-deduplication** (binding decision §80b): when multiple runs
in the same `.tio` file share a `reference_uri`, the writer embeds
the reference at this path **once**. Subsequent runs that name the
same URI link by reference; their `@reference_uri` attribute matches
the embedded group's URI. A second run with the same URI but a
different MD5 raises `ValueError` at write time — the URI–MD5 binding
is one-to-one within a file.

### Sequences channel under REF_DIFF

The `signal_channels/sequences` dataset under
`/study/genomic_runs/<run>/` carries `@compression == 9` and a flat
1-D `uint8` body (the rANS-encoded slice bodies + slice index +
codec header — see `docs/codecs/ref_diff.md`). The dataset has **no
HDF5 filter applied** (binding decision §87 — codec output is high-
entropy, double-compression is a CPU loss).

### Format-version gating

The presence of any REF_DIFF-encoded run bumps `@ttio_format_version`
on the root from `"1.4"` (M82) to `"1.5"` (M93). M82-only files
written by v1.2 implementations stay at `"1.4"` for byte-parity with
existing M82 fixture-based regression tests. v1.1.x readers reject
1.5 files at the format-version check (existing M82 schema gate; no
new logic).

### Default codec selection (Q5a = B, no feature flag)

When a run has `signal_compression="gzip"` (the default) AND
`signal_codec_overrides` is empty AND `reference_chrom_seqs` is
provided, the v1.5 default-codecs table (see
`python/src/ttio/genomic/_default_codecs.py` and language
equivalents) auto-applies REF_DIFF on the `sequences` channel.

Without a reference, the default lookup is skipped silently and the
channel falls through to the legacy `signal_compression` path
(BASE_PACK fallback per binding decision §80b is invoked only when
the user had explicitly requested REF_DIFF).

## 10.11 FQZCOMP_NX16_Z codec — CRAM-mimic quality codec (M94.Z)

The FQZCOMP_NX16_Z codec (codec id `12`, M94.Z) is the v1.5 default
codec for the `qualities` channel. It is a clean-room implementation of
CRAM 3.1's `rANS-Nx16` discipline (htscodecs master) — see
`docs/codecs/fqzcomp_nx16_z.md` for the full algorithm and wire
format and
`docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md` for the
design proof.

### Coexistence with M94 v1

Codec id `10` (FQZCOMP_NX16, M94 v1, magic `FQZN`) and codec id `12`
(FQZCOMP_NX16_Z, M94.Z, magic `M94Z`) coexist in the codebase. The
on-disk `@compression` attribute carries the codec id; the reader
dispatches by attribute and (defensively) by magic. **Existing v1.1.x
M94 v1 fixtures and in-flight files continue to decode unchanged** —
v1.2 readers retain the M94 v1 decoder path. New files written under
the v1.5 default codec stack use id `12` for the `qualities` channel.

There is no automatic migration from id `10` to id `12`; rewriting an
existing M94 v1 file to M94.Z is a roundtrip decode-then-encode
operation at the application layer.

### On-disk schema

The `signal_channels/qualities` dataset under
`/study/genomic_runs/<run>/` carries `@compression == 12` and a flat
1-D `uint8` body (the M94.Z codec stream — header + body + trailer as
specified in `docs/codecs/fqzcomp_nx16_z.md` §2). The dataset has **no
HDF5 filter applied** (binding decision §87 — codec output is
high-entropy, double-compression is a CPU loss).

### Format-version gating

The presence of any FQZCOMP_NX16_Z-encoded run participates in the
v1.5 candidacy check alongside REF_DIFF (codec id `9`) and
FQZCOMP_NX16 (codec id `10`): if any of those three codecs is in use
on a run, `@ttio_format_version` on the root is bumped from `"1.4"`
(M82) to `"1.5"`. M82-only files without any of the three v1.5
codecs stay at `"1.4"` for byte-parity with existing M82 fixture-based
regression tests.

### Default codec selection

When a run has `signal_compression="gzip"` (the default) AND the
`signal_codec_overrides["qualities"]` slot is empty AND the run
already qualifies as v1.5 (i.e. another v1.5 codec is already in
use on the run, e.g. REF_DIFF on `sequences`), the v1.5 default
codecs table auto-applies FQZCOMP_NX16_Z on the `qualities`
channel. M94 v1 (id `10`) is no longer auto-selected for new files.

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
