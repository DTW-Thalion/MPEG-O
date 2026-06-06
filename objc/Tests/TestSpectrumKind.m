// TestSpectrumKind.m — P3.8 (PR 3/3, ObjC).
//
// Round-trip coverage for the TTIOSpectrumKind dispatch enum and its
// persisted-string helpers. The persisted @spectrum_class strings are
// the shared fixed contract across the Python / Java / ObjC SDKs and
// remain the on-disk source of truth; this enum is an in-code dispatch
// key only.
//
//   * Every persisted string maps to its expected member and the
//     member round-trips back to the SAME string.
//   * nil / empty -> TTIOSpectrumKindMass (v0.1 fallback).
//   * An unrecognised string -> TTIOSpectrumKindUnknown.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/TTIOEnums.h"

void testSpectrumKind(void)
{
    // ── 1. Each persisted string maps to its member and round-trips ──
    struct { NSString *s; TTIOSpectrumKind k; } cases[] = {
        { @"TTIOMassSpectrum",       TTIOSpectrumKindMass },
        { @"TTIONMRSpectrum",        TTIOSpectrumKindNMR },
        { @"TTIONMR2DSpectrum",      TTIOSpectrumKindNMR2D },
        { @"TTIOIRSpectrum",         TTIOSpectrumKindIR },
        { @"TTIORamanSpectrum",      TTIOSpectrumKindRaman },
        { @"TTIOUVVisSpectrum",      TTIOSpectrumKindUVVis },
        { @"TTIOFreeInductionDecay", TTIOSpectrumKindFreeInductionDecay },
        { @"TTIOMSImagePixel",       TTIOSpectrumKindMSImagePixel },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        TTIOSpectrumKind got = TTIOSpectrumKindFromPersisted(cases[i].s);
        PASS(got == cases[i].k,
             "P3.8: %s -> expected member", [cases[i].s UTF8String]);
        NSString *back = TTIOSpectrumKindPersisted(cases[i].k);
        PASS([back isEqualToString:cases[i].s],
             "P3.8: %s round-trips to the same persisted string",
             [cases[i].s UTF8String]);
    }

    // ── 2. nil / empty -> Mass (v0.1 fallback) ─────────────────────
    PASS(TTIOSpectrumKindFromPersisted(nil) == TTIOSpectrumKindMass,
         "P3.8: nil -> Mass (v0.1 fallback)");
    PASS(TTIOSpectrumKindFromPersisted(@"") == TTIOSpectrumKindMass,
         "P3.8: empty string -> Mass (v0.1 fallback)");

    // ── 3. Unrecognised -> Unknown ─────────────────────────────────
    PASS(TTIOSpectrumKindFromPersisted(@"TTIOFutureSpectrum")
             == TTIOSpectrumKindUnknown,
         "P3.8: unrecognised string -> Unknown");

    // ── 4. Unknown maps to the empty persisted string ──────────────
    PASS([TTIOSpectrumKindPersisted(TTIOSpectrumKindUnknown)
             isEqualToString:@""],
         "P3.8: Unknown -> empty persisted string");
}
