# NAME_TOKENIZED v1 codec — REMOVED in v1.0

> **REMOVED in v1.0.** The NAME_TOKENIZED v1 codec (codec id 8) was
> removed in the v1.0 reset. The `read_names` channel now uses
> [NAME_TOKENIZED_V2](name_tokenizer_v2.md) (codec id 15) as the
> only supported encoding. v1.0 readers reject codec id 8 with a
> migration error.

The v1 algorithm specification (lean two-token-type columnar codec
with numeric-digit-runs + string-non-digit-runs, per-column type
detection, columnar / verbatim modes) is no longer applicable. See
git history (`git log -- docs/codecs/name_tokenizer.md`) for the
full historical text if you need to decode legacy v1 fixtures.

For the current read-name codec wire format, see
[`name_tokenizer_v2.md`](name_tokenizer_v2.md).
