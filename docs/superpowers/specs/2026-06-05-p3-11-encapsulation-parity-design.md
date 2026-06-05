# P3.11 — Encapsulation parity — Design

> OO-assessment (`docs/architecture/2026-06-02-oo-design-assessment.md`) P3.11
> (recommendation #11, evidence at lines 60–61, 100). NO `.tio` wire / transport
> change. Cross-language conformance is the gate. Touches return-value *semantics*
> (read-only enforcement), not API shape.

## Goal

Close the three encapsulation gaps the audit identified, bringing Python and Java
in line with ObjC (which already does `(readonly, copy) NSData` — **out of scope**,
already compliant):

1. **Python `Run`** is a "Provisional," structural Protocol (`protocols/run.py:17`)
   even though Java/ObjC treat the run abstraction as first-class. → promote to
   **Stable**.
2. **Python `SignalArray.data`** is a public, mutable `np.ndarray` field
   (`signal_array.py:44`) aliased to internal state — callers can corrupt a value
   object in place. → store it as a **zero-copy read-only view**
   (`flags.writeable=False`), per the audit's explicit "read-only array *views*
   rather than deep copies to preserve zero-copy."
3. **Java `SignalArray.asDoubles()/asFloats()/asInts()/asLongs()`** return the
   backing array by reference (`SignalArray.java:102-104`), contradicting Java's
   immutable-with-copies philosophy. → return a **defensive `clone()`**.

## Hard invariants

- No `.tio`/wire/transport change. No public API *shape* change (method names,
  signatures, return types unchanged — `asDoubles()` still returns `double[]`;
  `sa.data` is still an `np.ndarray`).
- The only behavioral change is that returned arrays can no longer be used to
  mutate internal state (Python: read-only view raises on write; Java: callers
  mutate a copy, not the original).
- Cross-language conformance + each SDK's full suite stay green.

## Architecture — two PRs

### PR-1 — Python (`Run` promotion + read-only `SignalArray.data`)

**1a. Promote `Run` out of Provisional.** In `python/src/ttio/protocols/run.py`,
change the module docstring `API status: Provisional (Phase 1 abstraction polish,
post-M91).` (line 17) to `API status: Stable.`, and update any class-level wording
that calls it provisional/unenforced. Grep the codebase + docs for other
references describing `Run` as provisional and update them. The Protocol is already
`@runtime_checkable`; no surface change — this is a stability promotion. Confirm
the method set matches what `AcquisitionRun`/`GenomicRun` actually implement (so
"Stable" is honest).

**1b. Freeze `SignalArray.data` as a read-only view.** In
`python/src/ttio/signal_array.py`, ensure every constructed `SignalArray` stores
`data` as a `writeable=False` view:
- Add/extend `__post_init__` (the class is a dataclass) to replace `self.data`
  with a read-only view of an **owned, contiguous** array. Mechanism:
  ```python
  arr = np.ascontiguousarray(self.data)
  if arr is self.data:           # ascontiguousarray may return the input as-is
      arr = arr.view()           # a distinct view object we can freeze without
                                 # touching the caller's writeable flag
  arr.flags.writeable = False
  object.__setattr__(self, "data", arr)   # object.__setattr__ in case frozen
  ```
  (Adapt to the actual dataclass flavor — frozen vs slots. If not frozen, plain
  assignment works; if frozen, use `object.__setattr__`.)
- `from_numpy` already calls `np.ascontiguousarray`; the freeze in `__post_init__`
  covers BOTH the `from_numpy` path and direct `SignalArray(data=...)`
  construction, so it's the single chokepoint.
- **Zero-copy semantics (documented trade-off):** a view shares the buffer, so
  reads are zero-copy and `sa.data[i] = x` raises. A caller that retained the
  *source* array could still mutate the shared buffer; that's accepted (the audit
  chose views over copies for zero-copy). Update the `data` field docstring to say
  it is read-only.

**1c. Audit + refactor internal in-place mutation of `SignalArray.data`.** This is
the real risk. Grep the codec/transport/decode/assembly paths for in-place writes
to a `SignalArray`'s data (`.data[` assignment, `.data +=`, `np.func(..., out=…data)`,
`.data.sort()`, etc.). Any internal code that builds a `SignalArray` then mutates
its `.data` must be refactored to build the ndarray fully, THEN construct the
`SignalArray`. The full test suite is the safety net (a frozen-array write raises
loudly).

**1d. (Secondary sweep, low-risk only)** Grep for other PUBLIC accessors that
return a raw internal `np.ndarray` aliased to state (e.g. genomic index arrays,
image-cube accessors). Where one clearly aliases internal state and adding a
`writeable=False` view is safe + non-breaking, apply the same pattern. If a
candidate is risky or ambiguous, leave it and note it as a follow-up rather than
expand scope. SignalArray.data is the definite target; this sweep is opportunistic.

**Fence:** full pytest suite green; new test asserting `sa.data.flags.writeable is
False` and that `sa.data[0] = x` raises `ValueError`; round-trip tests unaffected.

### PR-2 — Java (`SignalArray.asX()` defensive clone)

In `java/src/main/java/global/thalion/ttio/SignalArray.java`, change the four typed
accessors to return a defensive copy:
- `asDoubles()` → `return ((double[]) buffer).clone();` (keep the `instanceof`
  type-guard + `ClassCastException` on mismatch — clone only the matched branch).
- Same for `asFloats()`, `asInts()`, `asLongs()`.
- Leave `buffer()` unchanged — it is the explicitly-documented raw escape hatch
  ("raw backing array; caller must cast").
- Update each accessor's javadoc: `@return a defensive copy of the backing array
  as double[]` (etc.).

**Fence:** `mvn -o -B verify` green (jacoco ≥0.84); the existing `ofDoubles→asDoubles`
/ `ofFloats→asFloats` round-trip tests still pass (clone has identical values); add
an encapsulation test: `double[] a = sa.asDoubles(); a[0] = 999.0;
assertNotEquals(999.0, sa.asDoubles()[0]);` (mutating the returned array must not
affect the SignalArray).

## Out of scope

- **ObjC** — already compliant (`(readonly, copy) NSData`, `Core/TTIOSignalArray.h`).
- Any `.tio`/wire/transport change; any public API-shape change.
- A broad "make all Python dataclasses immutable" sweep — only the cited
  `SignalArray.data` exposure + the opportunistic low-risk secondary sweep (1d).
- P3.8 (spectrum_class enum) — separate item.

## Testing summary

| PR | Fence |
|----|-------|
| PR-1 Python | full pytest; `writeable is False` + write-raises test; round-trips unaffected; internal-mutation refactor verified by suite |
| PR-2 Java | `mvn verify` (jacoco ≥0.84); round-trip tests + new mutate-the-copy encapsulation test |

## PR sequence

PR-1 (Python) → PR-2 (Java). Each its own branch off main, CI-green, merged before
the next.
