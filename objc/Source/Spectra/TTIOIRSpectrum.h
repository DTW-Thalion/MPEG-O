#ifndef TTIO_IR_SPECTRUM_H
#define TTIO_IR_SPECTRUM_H

#import "TTIOSpectrum.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOSignalArray;

/**
 * 1-D mid-IR spectrum: wavenumber (cm^-1) + either transmittance or
 * absorbance array, the mode enum that disambiguates them, a spectral
 * resolution in cm^-1, and an optional scan count (FTIR averaging).
 *
 * The second signal array is always named `"intensity"` in the
 * HDF5 layout regardless of mode; the `mode` attribute tells a reader
 * how to interpret the values.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.tio.IRSpectrum
 *   Python: ttio.ir_spectrum.IRSpectrum
 */
@interface TTIOIRSpectrum : TTIOSpectrum

@property (readonly, strong) TTIOSignalArray *wavenumberArray;
@property (readonly, strong) TTIOSignalArray *intensityArray;
@property (readonly)         TTIOIRMode mode;
@property (readonly)         double resolutionCmInv;
@property (readonly)         NSUInteger numberOfScans;

- (instancetype)initWithWavenumberArray:(TTIOSignalArray *)wavenumbers
                         intensityArray:(TTIOSignalArray *)intensity
                                   mode:(TTIOIRMode)mode
                        resolutionCmInv:(double)resolutionCmInv
                          numberOfScans:(NSUInteger)numberOfScans
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
