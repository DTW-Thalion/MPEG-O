# MPEG-O Feature Flag Registry

Feature flags are declared on the HDF5 root group as the
`@mpeg_o_features` attribute, which holds a JSON array of strings.
Files written by libMPGO v0.2+ always emit the full set of supported
features so downstream readers can detect capabilities at a glance.
Later versions layer additional features on top:

- **v0.3.0** — compound per-run provenance, canonical byte-order
  signatures, LZ4 / Numpress-delta compression codecs.
- **v0.4.0** — envelope encryption + key rotation, anonymization.
- **v0.7.0** — versioned wrapped-key blob format (`wrapped_key_v2`).
- **v0.8.0** — post-quantum crypto preview (`opt_pqc_preview`):
  ML-KEM-1024 envelope wrapping (FIPS 203), ML-DSA-87 dataset
  signatures (`v3:` prefix, FIPS 204). See `docs/pqc.md`.

The on-disk `mpeg_o_format_version` attribute is **"1.2"** for files
written by v0.7+ writers (was `"1.1"` in v0.2 through v0.6). Readers
treat the major/minor parts as documented in `docs/format-spec.md §1`
— the minor bump is backward-compatible; v0.6 readers parse a v0.7
file unless it carries a required flag they don't recognise.

## Semantics

| Prefix  | Meaning                                                        |
|---------|----------------------------------------------------------------|
| none    | **Required.** Readers that do not recognize the feature MUST refuse to open the file. |
| `opt_`  | **Optional.** Readers may ignore the feature; files without corresponding data still parse. |

A v0.1 file carries no `@mpeg_o_features` attribute at all. v0.2
readers detect this and fall back to the v0.1 JSON-attribute metadata
path (see §11 of `format-spec.md`).

## Registry

| Flag                         | Required? | Since        | Semantics                                                                                          |
|------------------------------|-----------|--------------|----------------------------------------------------------------------------------------------------|
| `base_v1`                    | required  | M11          | Core file format: `/study/` group, `ms_runs` layout, spectrum_index parallel arrays, signal_channels. |
| `compound_identifications`   | required  | M11          | `/study/identifications` is an HDF5 compound dataset (5-field struct with VL strings).             |
| `compound_quantifications`   | required  | M11          | `/study/quantifications` is an HDF5 compound dataset (4-field struct with VL strings).             |
| `compound_provenance`        | required  | M11          | `/study/provenance` is an HDF5 compound dataset (5-field dataset-level chain).                    |
| `opt_compound_headers`       | optional  | M11          | Each `spectrum_index/` group carries a rank-1 `headers` compound dataset alongside the parallel arrays. |
| `opt_native_2d_nmr`          | optional  | M12          | `MPGONMR2DSpectrum` stores its matrix as a native rank-2 HDF5 dataset (`intensity_matrix_2d`) with dimension scales. |
| `opt_native_msimage_cube`    | optional  | M12          | `MPGOMSImage` cubes live at `/study/image_cube/` as rank-3 datasets (v0.1 location was `/image_cube/` at root). |
| `opt_dataset_encryption`     | optional  | M11 add-on   | Dataset-level AES-256-GCM sealing reserved for files that set `@encrypted` on the root.           |
| `opt_digital_signatures`     | optional  | M14          | File contains one or more HMAC-SHA256 signatures in `@mpgo_signature` / `@provenance_signature` attributes. |
| `compound_per_run_provenance`| required  | M17 (v0.3)   | Per-run provenance is stored as a compound HDF5 dataset at `/study/ms_runs/<run>/provenance/steps` using the same 5-field type as dataset-level `/study/provenance`. v0.2 readers fall back to the `@provenance_json` legacy mirror, which the writer keeps in place for signature compatibility. |
| `opt_canonical_signatures`   | optional  | M18 (v0.3)   | HMAC-SHA256 signatures are computed over a canonical little-endian byte stream (atomic numeric datasets via LE mem types, compound datasets field-by-field with VL strings emitted as `u32_le(len) \|\| bytes`). Stored as `"v2:" + base64(mac)`; unprefixed v0.2 signatures remain verifiable via a fallback path. |

## Adding a new feature

1. Add a new `+featureXxx` class method on `MPGOFeatureFlags` that
   returns the string constant.
2. Decide whether the new feature is required or optional. Prefer
   optional unless the feature changes existing layout in a way a
   naive reader would mishandle.
3. Add the string to the default feature list emitted from
   `MPGOSpectralDataset.writeToFilePath:` if (and only if) it is
   unconditional for every written file. Otherwise emit it
   conditionally from the writer that introduces the new content.
4. Append a row to the registry table above, including the
   introducing milestone.
5. Update `format-spec.md` with the data-layout section describing
   the new content.

## Compression codecs (M21, v0.3)

Compression codecs are carried by individual signal-channel datasets
rather than by root-level feature flags — readers detect them from the
dataset's filter list or from a per-channel attribute — but they are
documented here so implementers know what to expect.

| Codec                  | Transport                                                                                                                                             |
|------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| zlib (default)         | HDF5 `H5P_DEFLATE` filter at level 6. Lossless. Readable by every HDF5 library.                                                                       |
| LZ4                    | HDF5 filter id **32004**. Requires the LZ4 plugin to be loadable at runtime (`libh5lz4.so` on disk, `HDF5_PLUGIN_PATH` pointing at it). Lossless.     |
| Numpress-delta         | Per-channel transform, **not** an HDF5 filter. The dataset stores `int64` first differences and the signal_channels group carries a `@<channel>_numpress_fixed_point` int64 attribute with the scaling factor. Lossy, sub-ppm relative error for typical m/z. |

## v0.4 flags

| Flag                         | Required? | Since        | Semantics                                                                                          |
|------------------------------|-----------|--------------|----------------------------------------------------------------------------------------------------|
| `opt_key_rotation`           | optional  | M25 (v0.4)   | Envelope encryption: a DEK wraps signal data, a KEK wraps the DEK. `/protection/key_info/` holds the 60-byte `dek_wrapped` dataset (32 cipher + 12 IV + 16 tag), `@kek_id`, `@kek_algorithm`, `@wrapped_at`, and `@key_history_json`. Rotation re-wraps without re-encrypting data. |
| `opt_anonymized`             | optional  | M28 (v0.4)   | The file has been through the anonymization pipeline. A ProvenanceRecord documents which policies ran, how many spectra/values were affected, and the timestamp. |

## v0.7 flags

| Flag                 | Required? | Since        | Semantics                                                                                          |
|----------------------|-----------|--------------|----------------------------------------------------------------------------------------------------|
| `wrapped_key_v2`     | optional  | M47 (v0.7)   | `/protection/key_info/dek_wrapped` uses the versioned v1.2 envelope: `[magic "MW" (2) \| version 0x02 (1) \| algorithm_id (2, BE) \| ciphertext_len (4, BE) \| metadata_len (2, BE) \| metadata \| ciphertext]`. Algorithm IDs: `0x0000 = AES-256-GCM` (default), `0x0001 = ML-KEM-1024` (reserved for M49). For AES-GCM the metadata section is `[iv (12) \| tag (16)]` and ciphertext holds the 32-byte wrapped DEK. Writers emit v1.2 when this flag is present; readers that see the flag accept both v1.1 (60-byte legacy) and v1.2 blobs. v1.1-only readers silently read pre-v0.7 files that lack the flag. Binding decision 38. |

Algorithm discriminators:

- `0x0000` — AES-256-GCM (shipped v0.7)
- `0x0001` — **ML-KEM-1024** (post-quantum, v0.8 M49 — ACTIVE; see `docs/pqc.md`)
- `0x0002` — reserved

`docs/format-spec.md §10b` specifies the v1.2 blob layout byte-by-byte.

## v0.8 flags

| Flag                 | Required? | Since        | Semantics                                                                                          |
|----------------------|-----------|--------------|----------------------------------------------------------------------------------------------------|
| `opt_pqc_preview`    | optional  | M49 (v0.8)   | File uses post-quantum crypto: ML-KEM-1024 envelope wrapping (`algorithm_id=0x0001` in the v1.2 wrapped-key blob) and/or ML-DSA-87 dataset signatures (`v3:` prefix on `@mpgo_signature`). Set automatically whenever either primitive is used on writes. Readers without PQC support can still open the file and read unencrypted / classically-signed datasets; they raise `UnsupportedAlgorithmError` on PQC-specific operations. See `docs/pqc.md` for the full library-choice rationale (Python/ObjC use liboqs; Java uses Bouncy Castle). |

## v1.0 flags

| Flag                       | Required? | Since | Semantics |
|----------------------------|-----------|-------|-----------|
| `opt_per_au_encryption`    | optional  | v1.0  | Signal channels encrypt per-spectrum (per-Access-Unit) instead of channel-granular. Replaces the v0.x `<channel>_values_encrypted`/`_iv`/`_tag` layout with a single compound `<channel>_segments` dataset — one row per spectrum carrying `{offset, length, iv[12], tag[16], ciphertext}`. Required for streaming encrypted datasets through transport. See `docs/transport-encryption-design.md`. |
| `opt_encrypted_au_headers` | optional  | v1.0  | Additionally encrypts the AU semantic filter fields (`ms_level`, `polarity`, `retention_time`, `precursor_mz`, `precursor_charge`, `ion_mobility`, `base_peak_intensity`, and pixel coords for MSImage). Requires `opt_per_au_encryption`. Disables server-side filtering — clients filter after decrypt. On disk, the plaintext `spectrum_index/*` arrays are omitted and replaced by `spectrum_index/au_header_segments` (one encrypted 36-byte row per spectrum). |

## v0.7 storage + crypto surface (non-flag)

Some v0.7 additions are API-level and don't carry a feature flag —
they apply uniformly to every file regardless of when the file was
written:

- **`StorageDataset.read_canonical_bytes()` (M43)** — byte-level
  protocol method consumed by signatures + encryption. Canonical
  stream is little-endian across backends and hosts, so a signed
  dataset verifies identically whether it was written via
  `Hdf5Provider`, `SqliteProvider`, `MemoryProvider`, or `ZarrProvider`.
- **`CipherSuite` catalog (M48)** — static allow-list of algorithms
  (`aes-256-gcm`, `hmac-sha256`, plus reserved PQC identifiers).
  `encrypt_bytes(..., algorithm=...)` / `sign_dataset(..., algorithm=...)`
  / `enable_envelope_encryption(..., algorithm=...)` pass through the
  catalog's validation. No on-disk change relative to the default.
- **`create_dataset_nd` on Memory / SQLite / Zarr (M45/M46)** — full
  N-D support via flat BLOB + `@__shape_<name>__` attribute on the
  Hdf5/Sqlite/Zarr adapters so byte-level parity with HDF5's native
  rank survives the backend swap.
