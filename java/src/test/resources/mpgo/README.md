# Reference `.mpgo` fixtures (v0.2.0)

Deterministic reference files produced by `objc/Tools/MakeFixtures`.
Third-party reader implementations (Python, Rust, Go, …) can smoke-
test their parsers against these files without running the full
Objective-C build.

Regenerate at any time from a green tree via:

```bash
./build.sh                        # ensure libMPGO + Tools are built
LD_LIBRARY_PATH="$PWD/objc/Source/obj:$LD_LIBRARY_PATH" \
  objc/Tools/obj/MakeFixtures objc/Tests/Fixtures/mpgo
```

HDF5 embeds a modification timestamp in newly created files, so byte-
for-byte equality is not guaranteed across regeneration — only the
logical content is stable. Compare via `h5dump` output if you need a
deterministic diff.

## File inventory

| File               | Contents                                                                               |
|--------------------|----------------------------------------------------------------------------------------|
| `minimal_ms.mpgo`  | 1 MS run, 10 spectra of 8 peaks. No idents/quants/prov. Smallest conformant file.      |
| `full_ms.mpgo`     | 1 MS run, 12 spectra, 10 compound identifications, 5 compound quantifications, 2 compound provenance records. |
| `nmr_1d.mpgo`      | 1 NMR run stored under `msRuns` (M10 modality-agnostic), 5 MPGONMRSpectrum of 64 chemical shift points, 1H @ 600.13 MHz. |
| `encrypted.mpgo`   | Dataset-level AES-256-GCM encrypted: both intensity channel and any compound datasets sealed. Root `@encrypted = "aes-256-gcm"`. |
| `signed.mpgo`      | HMAC-SHA256 signatures on both `mz_values` and `intensity_values` of `run_0001`. Root feature flag `opt_digital_signatures` present. |

## Canonical key material

The encrypted and signed fixtures use a fixed 32-byte key derived as:

```c
for (int i = 0; i < 32; i++) raw[i] = (uint8_t)(0xA5 ^ (i * 3));
```

Third-party readers that want to verify can reconstruct the same
key. Do not use this value for anything other than fixture
verification — it is public.

## Invariants

All fixtures satisfy:

- Root `@mpeg_o_format_version == "1.1"`
- Root `@mpeg_o_features` is a JSON array of strings including
  `base_v1`, `compound_identifications`, `compound_quantifications`,
  `compound_provenance`, `opt_compound_headers`,
  `opt_native_2d_nmr`, `opt_native_msimage_cube`
- `/study/` group with non-empty `@title` and `@isa_investigation_id`
- `/study/ms_runs/` group with `@_run_names` attribute
- Each run group carries `@spectrum_class` identifying its contents

## Conformance checklist

A new reader should open each fixture and verify at minimum:

1. **`minimal_ms.mpgo`** — opens without error; reports 10 mass
   spectra in `run_0001`; can read spectrum 5's mz+intensity arrays.
2. **`full_ms.mpgo`** — reads 10 identifications, 5 quantifications,
   2 provenance records via the compound datasets under `/study/`.
3. **`nmr_1d.mpgo`** — `run = msRuns["nmr_run"]` materializes as
   an NMR run with `spectrum_class == "MPGONMRSpectrum"`; each
   spectrum has `chemical_shift` and `intensity` channels.
4. **`encrypted.mpgo`** — root `@encrypted` attribute present;
   `/study/ms_runs/run_0001/signal_channels/intensity_values`
   is absent; `intensity_values_encrypted` dataset is present.
5. **`signed.mpgo`** — `mz_values` and `intensity_values` carry
   `@mpgo_signature` (base64 string); feature list includes
   `opt_digital_signatures`.
