#ifndef MPGO_CHROMATOGRAM_H
#define MPGO_CHROMATOGRAM_H

#import "MPGOSpectrum.h"
#import "ValueClasses/MPGOEnums.h"

@class MPGOSignalArray;

/**
 * Chromatogram: time-vs-intensity trace, with TIC, XIC, or SRM type.
 * For XIC the targetMz field is meaningful; for SRM the precursorMz +
 * productMz fields apply (transition); both are zero for TIC.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.chromatogram.Chromatogram
 *   Java:   com.dtwthalion.mpgo.Chromatogram
 */
@interface MPGOChromatogram : MPGOSpectrum

@property (readonly, strong) MPGOSignalArray *timeArray;
@property (readonly, strong) MPGOSignalArray *intensityArray;
@property (readonly) MPGOChromatogramType type;
@property (readonly) double targetMz;        // XIC
@property (readonly) double precursorProductMz; // SRM precursor
@property (readonly) double productMz;       // SRM product

- (instancetype)initWithTimeArray:(MPGOSignalArray *)time
                   intensityArray:(MPGOSignalArray *)intensity
                             type:(MPGOChromatogramType)type
                         targetMz:(double)targetMz
                      precursorMz:(double)precursorMz
                        productMz:(double)productMz
                            error:(NSError **)error;

@end

#endif
