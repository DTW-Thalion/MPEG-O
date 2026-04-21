#ifndef MPGO_IR_SPECTRUM_H
#define MPGO_IR_SPECTRUM_H

#import "MPGOSpectrum.h"
#import "ValueClasses/MPGOEnums.h"

@class MPGOSignalArray;

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
 *   Java:   com.dtwthalion.mpgo.IRSpectrum
 *   Python: mpeg_o.ir_spectrum.IRSpectrum
 */
@interface MPGOIRSpectrum : MPGOSpectrum

@property (readonly, strong) MPGOSignalArray *wavenumberArray;
@property (readonly, strong) MPGOSignalArray *intensityArray;
@property (readonly)         MPGOIRMode mode;
@property (readonly)         double resolutionCmInv;
@property (readonly)         NSUInteger numberOfScans;

- (instancetype)initWithWavenumberArray:(MPGOSignalArray *)wavenumbers
                         intensityArray:(MPGOSignalArray *)intensity
                                   mode:(MPGOIRMode)mode
                        resolutionCmInv:(double)resolutionCmInv
                          numberOfScans:(NSUInteger)numberOfScans
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
