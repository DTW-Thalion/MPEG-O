#ifndef MPGO_MASS_SPECTRUM_H
#define MPGO_MASS_SPECTRUM_H

#import "MPGOSpectrum.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOIsolationWindow.h"

@class MPGOSignalArray;

/**
 * A mass spectrum: m/z + intensity arrays plus MS level, polarity, scan
 * window, and optional precursor activation / isolation metadata.
 * Construction enforces equal-length m/z and intensity arrays.
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
@property (readonly) MPGOActivationMethod activationMethod;  // M74; None=MS1/unreported
@property (readonly, strong) MPGOIsolationWindow *isolationWindow;  // M74; nullable

/**
 * Designated initializer (M74). Returns nil and populates `error` if mz
 * and intensity have different lengths.
 */
- (instancetype)initWithMzArray:(MPGOSignalArray *)mz
                 intensityArray:(MPGOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(MPGOPolarity)polarity
                     scanWindow:(MPGOValueRange *)scanWindow
               activationMethod:(MPGOActivationMethod)activationMethod
                isolationWindow:(MPGOIsolationWindow *)isolationWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error;

/**
 * Backward-compatible initializer (pre-M74): defaults
 * `activationMethod` to `MPGOActivationMethodNone` and
 * `isolationWindow` to `nil`.
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
