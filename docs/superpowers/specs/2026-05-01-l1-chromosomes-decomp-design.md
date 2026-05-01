# L1 — Decompose `genomic_index/chromosomes` into ID + name table

**Task:** #82 Phase B.1
**Status:** spec → implementation
**Wire impact:** minor break, intra-v1.5 (no format-version bump; pre-publication)

## 1. Problem

`genomic_index/chromosomes` is currently an HDF5 compound dataset of
shape `(N,)` with a single VL-string field. Per Phase A diagnostic
(`docs/benchmarks/2026-05-01-chr22-byte-breakdown.md`), each of its
432 chunks (at 4096 reads/chunk for N=1.77M reads) is followed by a
~98 KB HDF5 fractal-heap block. Total framework overhead: **42.6 MB
on chr22 — 25% of the file**.

For chr22-only WGS data, all 1.77M entries are the byte-string
`b'22'`, so we're spending 42 MB to repeat one short string 1.77M
times in a VL-string compound.

## 2. Solution

Replace the single compound dataset with two sibling datasets under
`genomic_index/`:

```
/study/genomic_runs/<run>/genomic_index/
    chromosome_ids     uint16, shape (N,), gzip compression
    chromosome_names   compound [(name, VL_str)], shape (K,)  K = #unique chroms
    ... (offsets, lengths, positions, mapping_qualities, flags unchanged)
```

The id column maps `chromosome_ids[i] → chromosome_names[id].name`.

Why **uint16** ids: covers up to 65,536 unique reference contigs
— comfortably above any real reference (GRCh38 has ~3,000 contigs;
pan-genome references push higher but stay << 65K). uint8 is too
small (255 max). uint32 wastes bytes.

Why a **sibling dataset** for names instead of an attribute:
attributes have practical size limits on group metadata (~64 KB per
attribute); a small compound dataset is uniform with the rest of
the index layout and is what `mate_info` / `signal_channels` already
use for VL-string columns.

**API contract (unchanged for callers):**
`GenomicIndex.chromosomes` stays a `list[str]` of length N. The
write/read methods materialize the id+names round-trip transparently.

## 3. Wire format (per-language byte-exact)

Writer pseudocode:

```
def write(idx_group, index):
    # ... (offsets, lengths, positions, mapping_qualities, flags as before)
    name_to_id = {}
    ids = np.empty(len(index.chromosomes), dtype=np.uint16)
    names_in_order = []
    for i, name in enumerate(index.chromosomes):
        if name not in name_to_id:
            name_to_id[name] = len(names_in_order)
            names_in_order.append(name)
        ids[i] = name_to_id[name]
    if len(names_in_order) > 65535:
        raise ValueError("genomic_index: > 65,535 unique chromosomes")
    write_uint16_dataset(idx_group, "chromosome_ids", ids, gzip=6)
    write_compound_dataset(
        idx_group, "chromosome_names",
        [{"name": n} for n in names_in_order],
        [("name", vl_str())])
```

Reader pseudocode:

```
def read(idx_group):
    # ... other columns as before
    ids = idx_group["chromosome_ids"]            # uint16[N]
    names = read_compound(idx_group, "chromosome_names")  # K rows × {name}
    name_table = [r["name"] for r in names]
    chromosomes = [name_table[id] for id in ids]
    return GenomicIndex(..., chromosomes=chromosomes, ...)
```

The encounter-order ID assignment (first occurrence gets the next
unused id) is the byte-exact contract. All three languages must
produce identical id/name datasets for the same input order.

## 4. What breaks

- **Existing chr22 fixture** at `tools/benchmarks/_work/chr22_*/ttio/*.tio`
  — must be regenerated.
- **Cross-language byte-exact fixtures** under
  `python/tests/fixtures/`/`java/.../resources/`/`objc/Tests/Fixtures/`
  if they include genomic_index — must be regenerated.
- **Java + ObjC `GenomicIndex` writers/readers** — must be updated
  alongside Python before cross-language tests pass.
- The `chromosomes` dataset name is GONE — readers that probe its
  presence directly (vs going through `GenomicIndex.read`) need
  updating. Probe sites: encryption_per_au.py (per-AU dispatch),
  transport/encrypted.py, anonymization.py.

## 5. Expected savings

Phase A measurement: 42.57 MB residual concentrated on chr22.
Replacing with `uint16[N] + compound[K]`:

| Component | chr22 | WGS-multichrom |
|-----------|-------|----------------|
| chromosome_ids (uint16, gzip) | ~few KB (all 22s gzip well) | ~3.5 MB (1.77M × 2 bytes uncompressed) |
| chromosome_names (compound) | ~100 B (1 entry) | ~1 KB (~25 entries) |
| **Total per-AU overhead** | **~few KB** | **~3.5 MB** |

For chr22 specifically, expect file size to drop from 169.17 MB to
**~127 MB (1.48× CRAM)** — closing 60% of the gap to the 1.15×
target.

## 6. Implementation order

1. Python writer + reader (`genomic_index.py`)
2. Python probe-site updates (encryption_per_au, transport, anonymization)
3. Regenerate chr22 fixture, verify savings, update breakdown doc
4. Java equivalent (`GenomicIndex.java`)
5. ObjC equivalent (`TTIOGenomicIndex.m`)
6. Cross-language fixture regen + tests
7. Spec doc updates (format-spec.md)

Each step is a separate commit. Step 3 is the "is this worth it" gate
— if savings are <30 MB instead of the projected ~42, we reassess
before paying for the Java/ObjC port.

## 7. Out of scope

- Touching `mate_info/chrom` — already flat uint8 + NAME_TOKENIZED;
  separate task if its 5.3 MB needs further reduction.
- `genomic_index/positions` duplicate (L4) — separate.
- `genomic_index/offsets` encoding (L5) — separate.
