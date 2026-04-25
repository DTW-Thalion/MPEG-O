#ifndef TTIO_NMR_SPECTRUM_H
#define TTIO_NMR_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOSignalArray;

/**
 * 1-D NMR spectrum: chemical-shift + intensity arrays plus nucleus type
 * (e.g. "1H", "13C") and spectrometer frequency in MHz.
 */
@interface TTIONMRSpectrum : TTIOSpectrum

@property (readonly, strong) TTIOSignalArray *chemicalShiftArray;
@property (readonly, strong) TTIOSignalArray *intensityArray;
@property (readonly, copy)   NSString *nucleusType;
@property (readonly)         double spectrometerFrequencyMHz;

- (instancetype)initWithChemicalShiftArray:(TTIOSignalArray *)cs
                            intensityArray:(TTIOSignalArray *)intensity
                               nucleusType:(NSString *)nucleus
                  spectrometerFrequencyMHz:(double)freq
                             indexPosition:(NSUInteger)indexPosition
                           scanTimeSeconds:(double)scanTime
                                     error:(NSError **)error;

@end

/*
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.tio.NMRSpectrum
 *   Python: ttio.nmr_spectrum.NMRSpectrum
 */

#endif
