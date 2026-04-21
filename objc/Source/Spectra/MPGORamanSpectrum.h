#ifndef MPGO_RAMAN_SPECTRUM_H
#define MPGO_RAMAN_SPECTRUM_H

#import "MPGOSpectrum.h"

@class MPGOSignalArray;

/**
 * 1-D Raman spectrum: wavenumber (cm^-1) + intensity arrays plus
 * excitation laser wavelength, laser power, and detector integration
 * time.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.mpgo.RamanSpectrum
 *   Python: mpeg_o.raman_spectrum.RamanSpectrum
 */
@interface MPGORamanSpectrum : MPGOSpectrum

@property (readonly, strong) MPGOSignalArray *wavenumberArray;
@property (readonly, strong) MPGOSignalArray *intensityArray;
@property (readonly)         double excitationWavelengthNm;
@property (readonly)         double laserPowerMw;
@property (readonly)         double integrationTimeSec;

- (instancetype)initWithWavenumberArray:(MPGOSignalArray *)wavenumbers
                         intensityArray:(MPGOSignalArray *)intensity
                 excitationWavelengthNm:(double)excitationNm
                           laserPowerMw:(double)laserPowerMw
                     integrationTimeSec:(double)integrationTime
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
