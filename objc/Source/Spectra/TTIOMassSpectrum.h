#ifndef TTIO_MASS_SPECTRUM_H
#define TTIO_MASS_SPECTRUM_H

#import "TTIOSpectrum.h"
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOIsolationWindow.h"

@class TTIOSignalArray;

/**
 * A mass spectrum: m/z + intensity arrays plus MS level, polarity, scan
 * window, and optional precursor activation / isolation metadata.
 * Construction enforces equal-length m/z and intensity arrays.
 *
 * Cross-language equivalents:
 *   Python  — ttio.mass_spectrum.MassSpectrum
 *   Java    — global.thalion.ttio.MassSpectrum
 */
@interface TTIOMassSpectrum : TTIOSpectrum

@property (readonly, strong) TTIOSignalArray *mzArray;
@property (readonly, strong) TTIOSignalArray *intensityArray;
@property (readonly) NSUInteger msLevel;       // 1, 2, 3, ...
@property (readonly) TTIOPolarity polarity;
@property (readonly, strong) TTIOValueRange *scanWindow;  // nullable
@property (readonly) TTIOActivationMethod activationMethod;  // M74; None=MS1/unreported
@property (readonly, strong) TTIOIsolationWindow *isolationWindow;  // M74; nullable

/**
 * Designated initializer (M74). Returns nil and populates `error` if mz
 * and intensity have different lengths.
 */
- (instancetype)initWithMzArray:(TTIOSignalArray *)mz
                 intensityArray:(TTIOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(TTIOPolarity)polarity
                     scanWindow:(TTIOValueRange *)scanWindow
               activationMethod:(TTIOActivationMethod)activationMethod
                isolationWindow:(TTIOIsolationWindow *)isolationWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error;

/**
 * Backward-compatible initializer (pre-M74): defaults
 * `activationMethod` to `TTIOActivationMethodNone` and
 * `isolationWindow` to `nil`.
 */
- (instancetype)initWithMzArray:(TTIOSignalArray *)mz
                 intensityArray:(TTIOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(TTIOPolarity)polarity
                     scanWindow:(TTIOValueRange *)scanWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error;

@end

#endif
