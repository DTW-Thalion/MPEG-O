#ifndef TTIO_CHROMATOGRAM_H
#define TTIO_CHROMATOGRAM_H

#import "TTIOSpectrum.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOSignalArray;

/**
 * Chromatogram: time-vs-intensity trace, with TIC, XIC, or SRM type.
 * For XIC the targetMz field is meaningful; for SRM the precursorMz +
 * productMz fields apply (transition); both are zero for TIC.
 *
 * Cross-language equivalents:
 *   Python: ttio.chromatogram.Chromatogram
 *   Java:   global.thalion.ttio.Chromatogram
 */
@interface TTIOChromatogram : TTIOSpectrum

@property (readonly, strong) TTIOSignalArray *timeArray;
@property (readonly, strong) TTIOSignalArray *intensityArray;
@property (readonly) TTIOChromatogramType type;
@property (readonly) double targetMz;        // XIC
@property (readonly) double precursorProductMz; // SRM precursor
@property (readonly) double productMz;       // SRM product

- (instancetype)initWithTimeArray:(TTIOSignalArray *)time
                   intensityArray:(TTIOSignalArray *)intensity
                             type:(TTIOChromatogramType)type
                         targetMz:(double)targetMz
                      precursorMz:(double)precursorMz
                        productMz:(double)productMz
                            error:(NSError **)error;

@end

#endif
