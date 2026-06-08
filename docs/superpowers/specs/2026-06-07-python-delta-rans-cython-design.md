# Python delta_rans Cython acceleration — Design

**Date:** 2026-06-07
**Origin:** Python-perf parity follow-up. `codecs.genomic.delta_rans` encode/decode is Python
336/271ms vs Java/ObjC ~21ms (~16×). Profiling shows the gap is **pure-Python wrapper loops**,
NOT the rANS body (native `_rans` Cython, ~12-15ms) or the wire format.
**Scope:** Cython-accelerate the pure-Python hot loops in `python/src/ttio/codecs/delta_rans.py`,
mirroring the existing `_rans`/`_fqzcomp_nx16_z` Cython modules. **HARD invariant: byte-identical
`DRA0` output (cross-SDK + round-trip conformance), graceful pure-Python fallback when the C
extension is absent, no wire/format change, no public-API change.**

## Confirmed hot loops (profiled, n=100000 int64 / 10 MiB)
- **encode:** serial LEB128 **varint emit** loop (`delta_rans.py:102-105`, `_varint_encode`
  `:51-58`) ≈ 252ms. (zigzag-encode `:110-148` is already numpy-vectorized; rANS body native.)
- **decode:** serial **varint decode** (`_varint_decode_all` `:60-77`) ≈ 164ms + the **int64
  prefix-sum/zigzag-decode serial fallback** (`:183-188`) ≈ 115ms. The vectorized
  zigzag-decode+cumsum (`:193-203`) only handles element sizes **1 and 4**, so int64 (size 8)
  drops to the serial loop.

## Design
Add a Cython module `src/ttio/codecs/_delta_rans/_delta_rans.pyx` (+ `__init__.py`) exposing fast
equivalents of the inherently-serial loops, used by `delta_rans.py` when importable:
1. `varint_encode_all(zz)` — take a contiguous unsigned-int array (the zigzag deltas) and emit the
   LEB128 byte stream in C. Byte-for-byte identical to the current `_varint_encode` concatenation.
2. `varint_decode_all(buf)` — parse the LEB128 stream to an array of unsigned ints in C. Identical
   results + the same truncation `ValueError` on a bad/short varint (`:69`).
3. (If it cleanly belongs here) the int64 zigzag-decode + prefix-sum, OR — simpler and preferred —
   **extend the existing numpy-vectorized branch (`:193-203`) to element size 8** so int64 uses
   `np.cumsum` like sizes 1/4 (no Cython needed for that half; numpy handles it). Pick whichever
   keeps the code simplest while removing the serial fallback for int64. The encode-side zigzag
   (`_encode_zigzag`) is already numpy — leave it.

**Integration (mirror `_rans`):**
- `delta_rans.py`: `try: from ._delta_rans import _delta_rans as _c; _HAVE_C_EXTENSION = True
  except ImportError: _HAVE_C_EXTENSION = False`. Use `_c.varint_encode_all/decode_all` when
  available; else the existing pure-Python loops (keep them as the fallback — do NOT delete).
- `setup.py`: add `("ttio.codecs._delta_rans._delta_rans",
  "src/ttio/codecs/_delta_rans/_delta_rans.pyx")` to `_CYTHON_TARGETS` (the build is already
  graceful when Cython/the .pyx is absent).
- Keep the `DRA0` magic + header + native-rANS body path unchanged. The varint bytes fed to
  `rans.encode` and produced by `rans.decode` must be identical to today.

## Why byte-identical
LEB128 varint encoding is a deterministic function of the integer values; the Cython emit/decode
must produce the exact same bytes/ints as the Python loops (same masking, same little-endian
7-bit grouping). The `DRA0` header, the zigzag transform, and the rANS order-0 body are untouched.
Extending the numpy cumsum to size 8 yields the same integers as the serial prefix-sum. So the
encoded `.tio`/blob bytes are identical → cross-SDK + round-trip conformance unaffected.

## Invariants & verification
- Python product code + build wiring only (`delta_rans.py`, new `_delta_rans/`, `setup.py`).
- **Byte-identity (critical):** for a range of inputs (int8/int32/int64, signed/unsigned, empty,
  single element, large random, the existing test vectors), `encode()` output is byte-identical
  C-ext vs pure-Python, and `decode(encode(x)) == x`. The existing delta_rans round-trip +
  cross-SDK conformance tests (Python-encoded blob decodes in Java/ObjC and vice versa) MUST stay
  green.
- **Fallback:** with the C extension NOT built, the pure-Python path still works and is selected
  (test by importing with the .so removed / `_HAVE_C_EXTENSION = False`).
- Build the extension in this venv (`cd python && pip install -e .` or the cython build step) so
  the perf run uses it.
- pytest green incl `--cov` gate (≥0.84) if enforced; the pure-Python fallback lines stay covered
  (or are marked) so coverage doesn't drop.
- Perf: re-measure `codecs.genomic.delta_rans_encode/_decode` (FORCE the C ext to be built/loaded
  first; `TTIO_RANS_LIB_PATH=...`); target ~336/271ms → toward Java's ~21ms. Re-baseline Python.

## Success criteria
`_delta_rans` Cython module accelerates the varint (and int64 prefix-sum) hot loops; delta_rans
encode/decode drop materially toward Java/ObjC; byte-identical `DRA0` + conformance green;
pure-Python fallback intact; Python re-baselined. One PR.

## Out of scope
The algorithmic bulk-read fixes (transport.encode / ms.read / streaming.read / genomic.read —
higher leverage, separate follow-on); streaming.write; transport.plain.decode.
