#ifndef MPGO_MASS_SPECTRUM_H
#define MPGO_MASS_SPECTRUM_H

#import "MPGOSpectrum.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOValueRange.h"

@class MPGOSignalArray;

/**
 * A mass spectrum: m/z + intensity arrays plus MS level, polarity, and
 * an optional scan window. Construction enforces equal-length m/z and
 * intensity arrays.
 *
 * Cross-language equivalents:
 *   Python  — mpeg_o.mass_spectrum.MassSpectrum
 *   Java    — com.dtwthalion.mpgo.MassSpectrum
 */
@interface MPGOMassSpectrum : MPGOSpectrum

@property (readonly, strong) MPGOSignalArray *mzArray;
@property (readonly, strong) MPGOSignalArray *intensityArray;
@property (readonly) NSUInteger msLevel;       // 1, 2, 3, ...
@property (readonly) MPGOPolarity polarity;
@property (readonly, strong) MPGOValueRange *scanWindow;  // nullable

/**
 * Designated convenience initializer. Returns nil and populates `error`
 * if mz and intensity have different lengths.
 */
- (instancetype)initWithMzArray:(MPGOSignalArray *)mz
                 intensityArray:(MPGOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(MPGOPolarity)polarity
                     scanWindow:(MPGOValueRange *)scanWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error;

@end

#endif
