# FQZCOMP_NX16 v1 codec — REMOVED in v1.0

> **REMOVED in v1.0.** FQZCOMP_NX16 (the v1 codec at slot 10) was
> removed in the v1.0 reset. The `qualities` channel now uses
> [FQZCOMP_NX16_Z](fqzcomp_nx16_z.md) (codec id 12, V4 wire format)
> as the only supported lossless quality encoding. v1.0 readers
> reject codec id 10 with a migration error.

The v1 algorithm specification (per-symbol adaptive arithmetic
coding with SplitMix64 context hashing, magic `FQZN`) is no longer
applicable. The v1 implementation was too slow (~0.16 MB/s vs CRAM
3.1's ~3 GB/s) to ship; the static-per-block FQZCOMP_NX16_Z V4
codec replaces it.

For the current quality codec wire format, see
[`fqzcomp_nx16_z.md`](fqzcomp_nx16_z.md).
