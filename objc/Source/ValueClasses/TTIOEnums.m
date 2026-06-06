/*
 * TTIOEnums.m
 *
 * String-mapping helpers for the shared TTI-O enums. Currently this
 * carries only the TTIOSpectrumKind <-> persisted @spectrum_class
 * string table (P3.8); the persisted strings are the shared fixed
 * contract across the Python / Java / Objective-C SDKs and remain the
 * on-disk source of truth.
 *
 * Cross-language equivalents:
 *   Python: ttio.enums.SpectrumKind
 *   Java:   global.thalion.ttio.Enums.SpectrumKind
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */

#import "ValueClasses/TTIOEnums.h"

// Single source of truth for the persisted @spectrum_class vocabulary.
// Index == TTIOSpectrumKind ordinal; TTIOSpectrumKindUnknown maps to "".
static NSString *const kTTIOSpectrumKindPersisted[] = {
    @"TTIOMassSpectrum",        // TTIOSpectrumKindMass
    @"TTIONMRSpectrum",         // TTIOSpectrumKindNMR
    @"TTIONMR2DSpectrum",       // TTIOSpectrumKindNMR2D
    @"TTIOIRSpectrum",          // TTIOSpectrumKindIR
    @"TTIORamanSpectrum",       // TTIOSpectrumKindRaman
    @"TTIOUVVisSpectrum",       // TTIOSpectrumKindUVVis
    @"TTIOFreeInductionDecay",  // TTIOSpectrumKindFreeInductionDecay
    @"TTIOMSImagePixel",        // TTIOSpectrumKindMSImagePixel
    @""                         // TTIOSpectrumKindUnknown
};

TTIOSpectrumKind TTIOSpectrumKindFromPersisted(NSString *s)
{
    if (s == nil || s.length == 0) {
        return TTIOSpectrumKindMass;  // v0.1 fallback.
    }
    for (NSInteger k = TTIOSpectrumKindMass;
         k <= TTIOSpectrumKindMSImagePixel; k++) {
        if ([kTTIOSpectrumKindPersisted[k] isEqualToString:s]) {
            return (TTIOSpectrumKind)k;
        }
    }
    return TTIOSpectrumKindUnknown;
}

NSString *TTIOSpectrumKindPersisted(TTIOSpectrumKind k)
{
    if (k < TTIOSpectrumKindMass || k > TTIOSpectrumKindUnknown) {
        return @"";
    }
    return kTTIOSpectrumKindPersisted[k];
}
