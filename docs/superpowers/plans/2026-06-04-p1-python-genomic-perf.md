# P1 Python Genomic Perf (DELTA_RANS + signal-channels handle) — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Two parity-neutral Python perf optimizations from the OO assessment: **P1.3** numpy-vectorize `DELTA_RANS` encode/decode (was scalar pure-Python — the slowest interpreted codec); **P1.4** cache the `signal_channels` group handle on `GenomicRun` (re-opened ~10× per record today).

**Architecture:** Both are pure optimizations — **byte-identical output, faster**. No wire/format change, no public-API change.

**Tech Stack:** Python 3.12, numpy. Test: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args>`.

**Hard invariant (both):** **byte-for-byte identical output to the current implementation.** DELTA_RANS especially: the two's-complement delta wraparound for element_size 1/4 must match exactly — verified by an old-vs-new differential test over edge inputs.

**Reference:** OO assessment `docs/architecture/2026-06-02-oo-design-assessment.md` (P1.3, P1.4). Codec: `python/src/ttio/codecs/delta_rans.py`. Run: `python/src/ttio/genomic_run.py`. Tests: `python/tests/test_m95_delta_rans.py`, `test_m82_genomic_run.py`.

---

### Task PT1: Vectorize `DELTA_RANS` encode + decode

**Files:**
- Modify: `python/src/ttio/codecs/delta_rans.py`
- Test: `python/tests/test_delta_rans_vectorization.py`

Replace the scalar `for v in values` (encode, `:97-107`) and `for zz in zigzag_values` (decode, `:143-156`) loops with numpy, keeping only the variable-length varint emit/parse serial. Byte-exact.

**Approach (must match the existing scalar semantics exactly):**
- **encode:** `vals = np.frombuffer(data, dtype=<int8|int32|int64 per element_size>)`. Delta-from-prev (prev starts 0) = `np.diff(vals, prepend=<0 in dtype>)` — in the *signed* width dtype this wraps in two's complement, matching the manual `if delta < -(1<<(bits-1)): delta += 1<<bits` branch. Zigzag vectorized in the *unsigned* width: `zz = ((delta << 1) ^ (delta >> (bits-1)))` computed on the unsigned view, masked to `bits`. Then `zz_list = zz.tolist()` and keep the existing serial `for zz in zz_list: varint_buf.extend(_varint_encode(zz))` (varint stays serial — variable length). Then `rans.encode(...)` unchanged.
- **decode:** `varint_bytes = rans.decode(...)`; `_varint_decode_all(...)` stays serial (variable length) → `zz_arr = np.array(zigzag_values, dtype=uint<bits>)`. Vectorize zigzag-decode: `delta = (zz_arr >> 1) ^ -(zz_arr & 1)` (in signed width). Cumulative sum `np.cumsum(delta)` in the signed width wraps in two's complement, matching `v = prev + delta` + the `v &= mask; if v>=half: v-=1<<bits` normalization. Then `struct.pack`/`tobytes` to the output bytes. (For element_size 8, the int64 path: numpy int64 overflow is UB-ish — verify it still matches; if numpy int64 cumsum diverges from Python's arbitrary-precision wrap, keep the int64 case on the scalar path and vectorize only 1/4, OR use uint64 arithmetic with explicit masking. Pick whichever is byte-exact and note it.)
- Keep `_zigzag_encode`/`_decode`/`_varint_*` helpers (still used / for reference). The empty-input + header paths unchanged.

- [ ] **Step 1: Write the differential fence test** `test_delta_rans_vectorization.py`:
  - Capture the CURRENT behavior as golden: for a battery of inputs — empty; single value; ascending positions; random int8/int32/int64 arrays incl. negatives, min/max boundary values (e.g. `-(1<<31)`, `(1<<31)-1` for size 4), and values that force delta wraparound — assert `decode(encode(data, es)) == data` (round-trip) AND assert `encode(data, es)` equals a hardcoded/recomputed golden for a few fixed vectors. Crucially, **before changing the code, run the test against the current implementation to record that round-trips hold**; the round-trip + boundary cases are the byte-exact fence.
  - Use `np.random` with a fixed seed for the random battery; cover all three element sizes.
- [ ] **Step 2: Run the test against the CURRENT code** — it must PASS (establishes the baseline the refactor must preserve). `.venv/bin/pytest tests/test_delta_rans_vectorization.py -q`
- [ ] **Step 3: Implement the numpy vectorization** in `delta_rans.py` (encode then decode), per the approach above.
- [ ] **Step 4: Run the fence + the existing codec tests** — all green, byte-identical:
  `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_delta_rans_vectorization.py tests/test_m95_delta_rans.py -q`
  If ANY byte differs, the wraparound/dtype handling is wrong — fix until byte-exact (do NOT weaken the test).
- [ ] **Step 5: Quick microbench** (report only, not gated): time encode+decode of a ~1M-element int32 ascending array old-vs-new (you can stash the old via `git stash`, time, unstash) — report the speedup in the commit body. If numpy isn't faster for some path, note it.
- [ ] **Step 6: Commit** `perf(py-codec): vectorize DELTA_RANS encode/decode (byte-identical)`.

---

### Task PT2: Cache the `signal_channels` group handle on `GenomicRun`

**Files:**
- Modify: `python/src/ttio/genomic_run.py`
- Test: `python/tests/test_genomic_run_signal_group_cache.py`

`GenomicRun` re-opens `self.group.open_group("signal_channels")` on every uncached dataset access (`_signal_dataset`, `:330`) and in the ref_diff path (`:411`). Open it once and reuse. `GenomicRun` is `@dataclass(slots=True)` with no `close()` — the cached handle GC's with the instance (same lifecycle, fewer opens).

- [ ] **Step 1: Study** every `self.group.open_group("signal_channels")` call site (`grep -n 'open_group("signal_channels")' python/src/ttio/genomic_run.py`) — `:330`, `:411`, and any others.
- [ ] **Step 2: Write the failing/behavioral test** `test_genomic_run_signal_group_cache.py`: build a small genomic `.tio` (reuse the `test_m82_genomic_run.py` fixture pattern), open the `GenomicRun`, access ≥2 different signal channels + (if applicable) a ref_diff path, and assert the results are correct (channel data round-trips). To prove the cache: monkeypatch/spy `self.group.open_group` (or count calls) and assert `signal_channels` is opened **at most once** across multiple channel accesses. (If spying is awkward, assert behavior-correctness + that a `_signal_group` attribute is populated after first access.)
- [ ] **Step 3: Implement** — add a `_signal_group` slot (default `None`, `field(default=None, repr=False, compare=False)`), and a helper `def _signal_channels_group(self): if self._signal_group is None: self._signal_group = self.group.open_group("signal_channels"); return self._signal_group`. Replace the `self.group.open_group("signal_channels")` call sites with `self._signal_channels_group()`. Add the new slot to `@dataclass(slots=True)` fields. Do NOT change `open()`'s eager `sig` local at `:301` unless trivially (it can also use the cached helper, but `open()` is a classmethod building the instance — leave it or wire after construction; keep it simple + correct).
- [ ] **Step 4: Run** the new test + the full genomic suite — green:
  `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_genomic_run_signal_group_cache.py tests/test_m82_genomic_run.py -q`
- [ ] **Step 5: Commit** `perf(py-genomic): cache signal_channels group handle on GenomicRun`.

---

### Task PT3: Regression + CHANGELOG

- [ ] **Step 1: Full genomic + codec regression:**
  `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_m95_delta_rans.py tests/test_m82_genomic_run.py tests/test_compression_benchmark.py tests/test_codec_registry.py tests/integration -q`
  All green. (Fix real regressions in impl, not tests.) Note: the cross-language Java/ObjC integration tests may fail locally on the JDK-21-vs-22 class-file mismatch — that's the known environmental issue, not this change; confirm any failures are that signature.
- [ ] **Step 2: CHANGELOG** under `## [Unreleased]`:
  ```markdown
  ### Performance — Vectorized DELTA_RANS + cached signal-channels handle (Python)

  `DELTA_RANS` encode/decode now compute delta + zigzag via numpy (only the
  variable-length varint stream stays serial), and `GenomicRun` caches the
  `signal_channels` group handle instead of re-opening it per channel access.
  Byte-identical output; no wire/format change. (OO-assessment P1.3 + P1.4.)
  ```
- [ ] **Step 3: Commit** `docs: changelog for Python genomic perf (P1.3/P1.4)`.

---

## Self-review notes (author)
- **Byte-exact is the bar.** PT1's differential fence (round-trip + boundary/wraparound vectors over all 3 element sizes) is mandatory; if int64 numpy arithmetic can't match Python's arbitrary-precision wrap byte-for-byte, keep size-8 scalar and vectorize 1/4 (report). PT2 is behavior-preserving (fewer opens, same data).
- **No wire/API change** — `encode`/`decode` signatures + output bytes unchanged; `GenomicRun` public surface unchanged (new field is private `_signal_group`).
- This is a Python-only PR; P1.2 (Java/ObjC region-query vectorization) is a separate follow-on PR.
