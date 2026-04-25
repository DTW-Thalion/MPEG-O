#ifndef TTIO_RAMAN_SPECTRUM_H
#define TTIO_RAMAN_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOSignalArray;

/**
 * 1-D Raman spectrum: wavenumber (cm^-1) + intensity arrays plus
 * excitation laser wavelength, laser power, and detector integration
 * time.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.ttio.RamanSpectrum
 *   Python: ttio.raman_spectrum.RamanSpectrum
 */
@interface TTIORamanSpectrum : TTIOSpectrum

@property (readonly, strong) TTIOSignalArray *wavenumberArray;
@property (readonly, strong) TTIOSignalArray *intensityArray;
@property (readonly)         double excitationWavelengthNm;
@property (readonly)         double laserPowerMw;
@property (readonly)         double integrationTimeSec;

- (instancetype)initWithWavenumberArray:(TTIOSignalArray *)wavenumbers
                         intensityArray:(TTIOSignalArray *)intensity
                 excitationWavelengthNm:(double)excitationNm
                           laserPowerMw:(double)laserPowerMw
                     integrationTimeSec:(double)integrationTime
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
