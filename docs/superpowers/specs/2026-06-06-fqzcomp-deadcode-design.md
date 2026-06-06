# fqzcomp Dead-Code Removal + Live-Path Tests (R3) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-coverage-analysis.md` recommendation R3.
**Scope:** Remove the dead V1/V2/V3 fqzcomp (M94.Z) quality-codec implementations from all
three SDKs (Python/Java/ObjC), then add targeted tests for the live V4 path. The "low
coverage" (Python 28%, Java 19%) is an artifact of dead code, not missing tests.

## Background

The M94.Z quality-score codec was reduced to a single live path during the v1.0 reset
(Phase 2c): `encode` emits only **V4** (a thin wrapper over native `libttio_rans`), and
`decode` for version bytes 1/2/3 **throws/errors** ("no longer supported in v1.0"). The
old pure-language V1/V2 (and Python-only V3) rANS implementations were removed from
dispatch but left physically in the files, inflating the coverage denominator with
unreachable code.

**Verified safe to delete (read-only investigation, 2026-06-06):**
- No external callers: the codec registry, `__init__`, and sibling codecs use only the V4
  entrypoints + the shared native loader. Java `encodeV2Native`/`decodeV2*` have zero live
  callers; ObjC `z_*` V1/V2 statics are unreachable from the V4-only live path.
- No backward-compat decode: all three SDKs reject v1/2/3 blobs with an error; existing
  tests *assert* that rejection (using runtime-tampered V4 blobs, not on-disk fixtures).
- No active test/fixture needs v1/2/3 decode. The v1/2/3 `.bin` corpora are orphaned
  (their consuming test sources were already deleted in Phase 2c).
- Cross-language conformance exchanges only V4 blobs (`blob[4] == 4`).

## Goals

1. Delete the unreachable V1/V2/V3 code in all three SDKs so coverage reflects live code.
2. Keep the v1/2/3 **rejection** branches in `decode` (unchanged behavior).
3. Add tests for the live V4 wrapper's edge/error branches to lock in honest coverage.
4. Restore 3-language parity (all three become V4-only).

## Non-goals
No change to the live V4 wire format, the native `libttio_rans` core, the codec registry
API, or any `.tio`/transport format. No reflection-based testing of dead code.

## Changes by SDK

### Python — `python/src/ttio/codecs/fqzcomp_nx16_z.py`
Remove the dead bodies + helpers: `_encode_body`/`_decode_body`, `_encode_one_step`/
`_decode_one_step`, `_build_context_seq`/`_build_context_seq_arr_vec`/
`_vectorize_first_encounter`, `_serialize_freq_tables`/`_deserialize_freq_tables`,
`_encode_read_lengths`/`_decode_read_lengths`, all three `_pack/_unpack_codec_header*`
pairs, `normalise_to_total`, `cumulative`, `m94z_context`, `position_bucket_pbits`,
`pack_context_params`/`unpack_context_params`, and the `ContextParams`/`CodecHeader`
dataclasses + their now-unused constants (`VERSION`, `VERSION_V2_NATIVE`,
`VERSION_V3_ADAPTIVE`, `ADAPTIVE_STEP`, `ADAPTIVE_T_MAX`). Trim `__all__` to the live
surface (`encode`, `decode_with_metadata`, `get_backend_name`, `MAGIC`,
`VERSION_V4_FQZCOMP`, and the V4 sizing constants actually used). Keep: the V4 ctypes
wrappers (`_encode_v4_native`, `_decode_v4_via_native`), `encode`,
`decode_with_metadata` (including its v1/2/3 `raise ValueError` rejection), the native
loader (`_load_native_lib`, `_HAVE_NATIVE_LIB`, `get_backend_name`).

### Java — `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
Remove `encodeV2Native`, `decodeV2`, `decodeV2PureJava`, `decodeV2ViaNativeStreaming`
(+ its resolver lambda + `decodeV2ForceNativeStreamingForTest`), `buildContextSeq`,
`serializeFreqTables`/`deserializeFreqTables`, the header `pack/unpack` pairs, and the
now-unused helpers `m94zContext`, `positionBucketPbits`, `packContextParams`/
`unpackContextParams`, `encodeReadLengths`/`decodeReadLengths`, `normaliseToTotal`,
`cumulative` (+ the `ContextParams` nested type if it becomes unused). Keep: the public
`encode`/`decode` overloads, `EncodeOptions`, `DecodeResult`, `encodeV4Internal`/
`decodeV4Internal`, `getBackendName`, live constants, and the v1/2/3 rejection in
`decode`. In `FqzcompNx16ZUnitTest.java`, delete the test methods that exercised the
removed helpers (`positionBucketPbitsBasics`, `contextBitPackBasics`,
`contextParamsRoundTrip`, `readLengthsRoundTrip*`) and the dead `fixtureA..H` builders;
keep `constantsMatchSpec`, `magicIsM94Z`, `unpackRejectsBadMagic` (if still applicable),
and the JNI-gated V4 round-trips.

### ObjC — `objc/Source/Codecs/TTIOFqzcompNx16Z.m` (+ `.h`)
Remove the dead `z_*` V1/V2 statics: `z_encode_full`, `z_decode_full`,
`z_encode_v2_native`, `z_decode_v2`/`z_decode_v2_via_native_streaming` (+ resolver cb),
`z_normalise_to_total`, `z_build_context_seq`, `z_serialize_freq_tables`/
`z_deserialize_freq_tables`, `z_encode_read_lengths`/`z_decode_read_lengths`,
`z_context`, `z_pos_bucket`. Keep the V4-only live path (`encodeV4WithQualities:`/
`decodeV4Data:`), the public `encode/decode` that route to V4, the v1/2/3 rejection
(error 203), and `backendName`. Fix the stale "silently downgraded to V1" comments in
`.m` (lines ~24-25, ~943-945), the `.h` `…:options:error:` doc, and
`TestM94ZV4Dispatch.m:11-12`. Remove any `…:options:error:` V1/V2-selection doc that no
longer matches behavior. If `encodeWithQualities:…options:error:` overloads still expose
V1/V2 selection params that are now no-ops, keep the signatures (ABI parity) but document
them as accepted-and-ignored, matching Python's kwarg handling.

### Orphaned fixtures
Delete `python/tests/fixtures/codecs/m94z_{a,b,c,d,f,g,h}.bin` (v3) and
`java/src/test/resources/ttio/codecs/m94z_{a,b,c,d,f,g,h}.bin` (v1). Leave the separate
`FQZN`-magic `fqzcomp_nx16_*.bin` files (different codec). Confirm no active source reads
the deleted files before removing.

## Add: live V4 edge/error tests
Add tests (each SDK, in its existing fqzcomp test file, gated on native availability as
today) covering the live wrapper branches not already hit:
- Input validation: `readLengths`/`revcompFlags` length mismatch; `sum(readLengths) !=
  len(qualities)`; (Python) type errors. Assert the documented exception/return.
- Edge inputs: empty qualities (minimal-header short-circuit), single read, multi-read
  mixed revcomp, padding for non-multiple-of-4 length.
- Decode errors: truncated blob, bad magic, bad/zero version, and **v1/2/3 rejection**
  (tamper a V4 blob's version byte → expect the reject error). Keep/strengthen the
  existing rejection assertions.
- `EncodeOptions`/`v4StrategyHint` variants where they select distinct live branches.
Only add tests that aren't already covered by `test_m94z_v4_dispatch.py` /
`FqzcompNx16ZV4DispatchTest` / `TestM94ZV4Dispatch.m` — extend those files.

## Public-API note
The removed Java public helpers (`m94zContext`, `positionBucketPbits`,
`packContextParams`, read-length codec) and Python `__all__` exports are technically
public, but their only consumers are the dead code, their own tests, and unshipped
`tools/perf` prototypes — not the SDK's dataset/transport/codec-registry contract.
Removal is approved as internal cleanup, not a meaningful API break. Sweep
`tools/perf/m94z_v4_prototype/` for now-dangling imports (dev-only, not in CI; fix or
note).

## Invariants & verification
- No live V4 wire/`.tio`/transport change; v1/2/3 rejection behavior unchanged.
- Cross-language V4 conformance preserved.
- Per-SDK gates green:
  - Python: `cd python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q --cov=src/ttio --cov-fail-under=84` (coverage of the file rises; total ≥84).
  - Java: **full** `cd java && JAVA_HOME=~/jdk25 mvn -o -B verify` (JaCoCo BUNDLE LINE ≥0.84 — deleting dead code + its tests is net-neutral-to-positive; verify).
  - ObjC: `cd objc && ./build.sh check` (and `--coverage check` locally if llvm present).
- CI: all gated jobs + "Cross-language parity (ObjC ⇄ Python ⇄ Java)".

## Success criteria
fqzcomp source files contain only live (V4 + shared) code; the three codec files' coverage
reflects live code (materially higher %); all gated suites + cross-language parity green;
no behavior change to the live path. One PR, three SDKs.

## Out of scope (tracked separately)
R2 (ObjC gate enforcement + lcov scope), R4 (Java branch gate), R5/R6 (per-class floor +
ratchet), R7/R8 (live-daemon + native coverage).
