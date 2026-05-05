# REF_DIFF v1 codec — REMOVED in v1.0

> **REMOVED in v1.0.** The REF_DIFF v1 codec (codec id 9) was
> removed in the v1.0 reset. The `sequences` channel now uses
> [REF_DIFF_V2](ref_diff_v2.md) (codec id 14) as the only supported
> reference-aligned encoding. v1.0 readers reject codec id 9 with a
> migration error.

The v1 algorithm specification (single-bitstream M-op flags + I/S
literals, slice-based with rANS body) is no longer applicable. See
git history (`git log -- docs/codecs/ref_diff.md`) for the full
historical text if you need to decode legacy v1 fixtures.

For the current reference-aligned sequence codec wire format, see
[`ref_diff_v2.md`](ref_diff_v2.md). The embedded-reference storage
layout under `/study/references/<reference_uri>/` is documented in
`docs/format-spec.md` §10.10.
