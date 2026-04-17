#ifndef MPGO_NMR_SPECTRUM_H
#define MPGO_NMR_SPECTRUM_H

#import "MPGOSpectrum.h"

@class MPGOSignalArray;

/**
 * 1-D NMR spectrum: chemical-shift + intensity arrays plus nucleus type
 * (e.g. "1H", "13C") and spectrometer frequency in MHz.
 */
@interface MPGONMRSpectrum : MPGOSpectrum

@property (readonly, strong) MPGOSignalArray *chemicalShiftArray;
@property (readonly, strong) MPGOSignalArray *intensityArray;
@property (readonly, copy)   NSString *nucleusType;
@property (readonly)         double spectrometerFrequencyMHz;

- (instancetype)initWithChemicalShiftArray:(MPGOSignalArray *)cs
                            intensityArray:(MPGOSignalArray *)intensity
                               nucleusType:(NSString *)nucleus
                  spectrometerFrequencyMHz:(double)freq
                             indexPosition:(NSUInteger)indexPosition
                           scanTimeSeconds:(double)scanTime
                                     error:(NSError **)error;

@end

/*
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.mpgo.NMRSpectrum
 *   Python: mpeg_o.nmr_spectrum.NMRSpectrum
 */

#endif
