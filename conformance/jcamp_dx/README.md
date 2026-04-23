# JCAMP-DX Compressed-Writer Conformance Fixtures (M76)

Byte-parity-identical golden files for the PAC / SQZ / DIF compressed
forms of the JCAMP-DX 5.01 writer. The Python, Java, and Objective-C
writers each ship a test that opens the matching `.jdx` file and
compares the writer output byte-for-byte against it.

Any change to the encoding algorithm — the YFACTOR heuristic, the
rounding rule, the values-per-line constant, the Y-check convention,
or the AFFN header ordering — must be applied to **all three**
writers and the fixtures regenerated via the Python reference impl
(see `generate.py` in this directory).

## Canonical Input

- Class: `UVVisSpectrum`
- Title: `m76 ramp-25`
- Solvent: `water`
- Path length: `1` cm
- Wavelength grid: 25 points, `200.0 ≤ wl ≤ 440.0` nm, step `10.0` nm
- Absorbance: symmetric triangle `min(i, 24 - i)` for `i ∈ [0, 24]`,
  giving values `{0, 1, 2, …, 12, 11, 10, …, 0}`.

The triangle shape exercises three compression characteristics the
all-zero or strictly-monotone fixtures would miss:

1. Zero-valued Y at each end (SQZ `@`).
2. Constant-slope runs on the rising and falling limbs (DIF `J`, `j`).
3. A single plateau apex (DIF `%` zero-delta) at the peak.

## Files

| File | Mode | Lines |
|------|------|-------|
| `uvvis_ramp25_pac.jdx` | PAC | 3 data lines |
| `uvvis_ramp25_sqz.jdx` | SQZ | 3 data lines |
| `uvvis_ramp25_dif.jdx` | DIF | 3 data lines |

All three files share an identical header (the same 15 LDRs in the
same order) and differ only in the `##XYDATA=` body.

## Regenerating

    cd python
    python ../conformance/jcamp_dx/generate.py

Fails if the files already differ from what the current Python
writer produces — that signals a breaking encoder change that needs
conscious attention and a Java + ObjC follow-through.
