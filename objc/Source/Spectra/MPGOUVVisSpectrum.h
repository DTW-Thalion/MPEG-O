#ifndef MPGO_UV_VIS_SPECTRUM_H
#define MPGO_UV_VIS_SPECTRUM_H

#import "MPGOSpectrum.h"

@class MPGOSignalArray;

/**
 * 1-D UV-visible absorption spectrum: wavelength (nm) + absorbance
 * arrays plus optical-path-length and solvent metadata.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.mpgo.UVVisSpectrum
 *   Python: mpeg_o.uv_vis_spectrum.UVVisSpectrum
 */
@interface MPGOUVVisSpectrum : MPGOSpectrum

@property (readonly, strong) MPGOSignalArray *wavelengthArray;
@property (readonly, strong) MPGOSignalArray *absorbanceArray;
@property (readonly)         double   pathLengthCm;
@property (readonly, copy)   NSString *solvent;

- (instancetype)initWithWavelengthArray:(MPGOSignalArray *)wavelengths
                        absorbanceArray:(MPGOSignalArray *)absorbance
                           pathLengthCm:(double)pathLengthCm
                                solvent:(NSString *)solvent
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
