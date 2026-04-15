# MPEG-O Container Design

MPEG-O files use the `.mpgo` extension and are valid HDF5 files. Any tool that reads HDF5 (h5py, h5dump, HDFView, matlab) can inspect them. MPEG-O adds semantic structure on top of HDF5's generic group/dataset/attribute model.

---

## File Layout

```
file.mpgo  (HDF5 root)
├── @mpeg_o_version                     (attr: string)
├── @created_utc                        (attr: string, ISO8601)
├── @writer_software                    (attr: string)
│
├── study/                              (group)
│   ├── @isa_investigation_id           (attr: string)
│   ├── @title                          (attr: string)
│   ├── metadata/
│   │   └── cv_params                   (compound dataset)
│   │
│   ├── run_0001/                       (group — = MPGOAcquisitionRun)
│   │   ├── @acquisition_mode           (attr: int — MPGOAcquisitionMode enum)
│   │   ├── @spectrum_count             (attr: uint64)
│   │   ├── instrument_config           (compound dataset, single row)
│   │   ├── provenance/
│   │   │   └── steps                   (compound dataset)
│   │   ├── signal_channels/
│   │   │   ├── mz_values               (float64[N_total], chunked, zlib-6)
│   │   │   ├── intensity_values        (float32[N_total], chunked, zlib-6)
│   │   │   ├── ion_mobility_values     (float64[N_total], chunked, zlib-6, optional)
│   │   │   └── scan_metadata           (compound[spectrum_count])
│   │   ├── spectrum_index/
│   │   │   ├── offsets                 (uint64[spectrum_count])
│   │   │   ├── lengths                 (uint32[spectrum_count])
│   │   │   └── headers                 (compound[spectrum_count])
│   │   └── chromatograms/
│   │       ├── tic_time                (float64[])
│   │       └── tic_intensity           (float32[])
│   │
│   ├── run_0002/                       (same structure)
│   │   └── ...
│   │
│   ├── identifications/
│   │   ├── spectrum_refs               (uint32[])
│   │   ├── chemical_entities           (variable-length string[])
│   │   ├── scores                      (float64[])
│   │   └── evidence                    (compound[])
│   │
│   └── quantifications/
│       ├── abundance_values            (float64[])
│       └── sample_refs                 (variable-length string[])
│
└── protection/
    ├── access_policies                 (variable-length string — JSON)
    └── key_info                        (compound dataset; no secret material)
```

---

## Compound Types

### `cv_params`

```c
typedef struct {
    char ontology_ref[16];       // "MS", "UO", "nmrCV", "CHEBI", "BFO"
    char accession[32];          // "MS:1000514"
    char name[128];              // "m/z array"
    char value[128];             // stringified value; empty if none
    char unit[32];               // unit accession; empty if none
} mpgo_cv_param_t;
```

### `scan_metadata`

```c
typedef struct {
    double   retention_time_s;   // seconds from run start
    uint8_t  ms_level;           // 1, 2, 3, ...
    int8_t   polarity;           // +1 positive, -1 negative, 0 unknown
    double   precursor_mz;       // 0 if not tandem
    uint8_t  precursor_charge;   // 0 if unknown
    double   base_peak_mz;
    float    base_peak_intensity;
    double   total_ion_current;
} mpgo_scan_metadata_t;
```

### `spectrum_index/headers`

Mirrors `scan_metadata` with the addition of `offset` and `length` for O(1) lookup. In practice the `offsets` and `lengths` array datasets carry those fields and the `headers` dataset carries the queryable metadata columns. Queries scan `headers` only.

### `instrument_config`

```c
typedef struct {
    char manufacturer[64];
    char model[64];
    char serial_number[64];
    char source_type[64];        // e.g. "ESI", "MALDI", "NMR_probe"
    char analyzer_type[64];      // e.g. "Orbitrap", "TOF", "FT-NMR"
    char detector_type[64];
} mpgo_instrument_config_t;
```

### `provenance/steps`

```c
typedef struct {
    char   input_refs[512];      // newline-separated URIs
    char   software[128];        // "ProteoWizard msconvert 3.0.21"
    char   parameters[1024];     // JSON-encoded parameter map
    char   output_refs[512];     // newline-separated URIs
    int64_t timestamp_unix;      // seconds since epoch
} mpgo_provenance_step_t;
```

---

## Signal-Channel Layout

For a run with `N` spectra and `n_i` data points in spectrum `i`:

- `mz_values` has total length `N_total = Σ n_i`.
- `intensity_values` has length `N_total` and is aligned element-for-element with `mz_values`.
- `spectrum_index/offsets[i]` is the starting index (in elements, not bytes) of spectrum `i` within `mz_values`.
- `spectrum_index/lengths[i] = n_i`.

Reading spectrum `k` is a two-step hyperslab selection:
1. Read `offsets[k]` and `lengths[k]` from `spectrum_index`.
2. Issue two HDF5 `H5Sselect_hyperslab` reads of length `lengths[k]` at offset `offsets[k]` from `mz_values` and `intensity_values`.

---

## Chunking Strategy

Default chunk size for signal channels: **16,384 elements** (~128 KiB for float64, ~64 KiB for float32). This is small enough that typical queries read only the chunks overlapping their selected spectra, yet large enough that zlib compression achieves typical mass spectrometry ratios of 2–4×.

`spectrum_index/headers` is chunked at **1,024 rows** so a full-run scan touches few chunks.

---

## Versioning

The file-level `@mpeg_o_version` attribute uses semantic versioning. Readers must:

- Accept any file with matching major version.
- Warn on newer minor version (may contain unknown optional groups).
- Refuse to open files with a different major version.

Version `1.0.0` is the baseline established by this reference implementation.
