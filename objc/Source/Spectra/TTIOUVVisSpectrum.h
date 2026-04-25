#ifndef TTIO_UV_VIS_SPECTRUM_H
#define TTIO_UV_VIS_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOSignalArray;

/**
 * 1-D UV-visible absorption spectrum: wavelength (nm) + absorbance
 * arrays plus optical-path-length and solvent metadata.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.ttio.UVVisSpectrum
 *   Python: ttio.uv_vis_spectrum.UVVisSpectrum
 */
@interface TTIOUVVisSpectrum : TTIOSpectrum

@property (readonly, strong) TTIOSignalArray *wavelengthArray;
@property (readonly, strong) TTIOSignalArray *absorbanceArray;
@property (readonly)         double   pathLengthCm;
@property (readonly, copy)   NSString *solvent;

- (instancetype)initWithWavelengthArray:(TTIOSignalArray *)wavelengths
                        absorbanceArray:(TTIOSignalArray *)absorbance
                           pathLengthCm:(double)pathLengthCm
                                solvent:(NSString *)solvent
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
