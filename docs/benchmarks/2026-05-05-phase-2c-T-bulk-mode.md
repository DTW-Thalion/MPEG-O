# Phase 2c-T bulk-mode perf measurement

**Date:** 2026-05-05
**Hardware:** WSL2 Ubuntu 22.04 on Windows 11, single core, no warmup.
**Build:** HEAD `b414613`, `libttio_rans.so` from `native/_build/`.

Compares per-AU mode against bulk mode on synthetic genomic fixtures
of varying scale. The receiver-side decode is the primary win — bulk
mode skips the v2 codec encode pass on the receiver and writes the
verbatim wire blobs directly to disk.

## Fixture A — 10K reads × 100bp, uniform `mate_chrom="="`

Total sequence + quality bytes: 1.0 MB + 1.0 MB.

| Phase  | Per-AU  | Bulk    | Speedup  |
|--------|---------|---------|----------|
| Encode | 1.042 s | 1.008 s | 1.03×    |
| Decode | 0.185 s | 0.134 s | **1.39×**|

Wire size (`.tis`): per-AU 4.06 MB, bulk 4.22 MB (+3.9%).

## Fixture B — 50K reads × 100bp, mate_chrom varied across 25 chroms

Total sequence + quality bytes: 5.0 MB + 5.0 MB. Mate chromosomes
distributed across `chr1`–`chr22`, `chrX`, `chrY`, `chrM`, and `=`,
exercising the v2 mate-info codec's chromosome-id encoding.

| Phase  | Per-AU  | Bulk    | Speedup  |
|--------|---------|---------|----------|
| Encode | 4.996 s | 4.966 s | 1.01×    |
| Decode | 0.901 s | 0.628 s | **1.43×**|

Wire size (`.tis`): per-AU 20.34 MB, bulk 21.15 MB (+4.0%).

## Interpretation

- **Decode speedup (1.36×–1.43×) is the bulk-mode win.** Per-AU mode
  re-encodes via `MATE_INLINE_V2`, `NAME_TOKENIZED_V2`, and (when
  applicable) `REF_DIFF_V2` on the receiver side; bulk mode writes
  the wire blob bytes directly. The savings scale linearly with read
  count.
- **Encode is near-parity** (≤3% delta) because both modes walk the
  same per-AU loop emitting one `AccessUnit` packet per read. Bulk
  mode adds three `BlobV2*` packets per genomic dataset_id — a small
  fixed cost.
- **Wire size grows ~4%** because bulk mode is *additive*: it ships
  per-AU AUs **and** the v2 blobs. Selective access (filter-by-
  chromosome on `AUFilter`) still works on bulk-mode streams because
  the per-AU AUs carry the filter keys. A future "bulk-only" mode
  that drops the per-AU AUs is possible but loses live-streaming
  selective-access semantics.
- **Real-world scale projection.** A full human WGS at 30× coverage
  is ~100M reads. At a constant ~1.4× decode speedup, the receiver
  saves on the order of (per-AU baseline) × 0.3 of the receive-side
  CPU time.

## Caveats

- Single-core, single-run measurement; no warmup, no statistical
  averaging. Treat the numbers as order-of-magnitude.
- The fixtures use uniform sequence content (`ACGT…ACGT`) and
  constant qualities (Phred 30). Real input would have richer
  distributions; codec output sizes would shift but the relative
  encode/decode timings should be similar.
- Bulk mode is currently wired through the HDF5 fast path AND the
  storage-protocol path on the receiver (CHANGELOG entry updated
  2026-05-05). Memory / SQLite / Zarr receivers also honor bulk mode
  per `python/tests/validation/test_phase_2c_t_storage_providers.py`.

## Reproduction

```python
from ttio.transport.codec import file_to_transport, transport_to_file

# Per-AU baseline:
file_to_transport(src_tio, tis_au, use_bulk_mode=False)
transport_to_file(tis_au, dst_au).close()

# Bulk mode:
file_to_transport(src_tio, tis_bulk, use_bulk_mode=True)
transport_to_file(tis_bulk, dst_bulk).close()
```

Or via the CLI:

```bash
python -m ttio.tools.transport_encode_cli --bulk src.tio out.tis
python -m ttio.tools.transport_decode_cli out.tis dst.tio
```
