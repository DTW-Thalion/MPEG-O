# MPEG-O Feature Flag Registry

Feature flags are declared on the HDF5 root group as the
`@mpeg_o_features` attribute, which holds a JSON array of strings.
Files written by libMPGO v0.2.0 always emit the full set of v0.2
features so downstream readers can detect capabilities at a glance.

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

## v0.3+ reserved flags

The following feature strings are reserved for planned work and
must not be re-used for other purposes:

- `opt_canonical_signatures` — v0.3 canonical-byte-order HMAC (see
  HANDOFF.md, Milestone 14 deferred subsection).
- `compound_per_run_provenance` — future migration of per-run
  provenance from the `@provenance_json` string attribute to a
  compound dataset under each run group.
- `opt_key_rotation` — envelope-style multi-key wrapping and
  rotation metadata.
