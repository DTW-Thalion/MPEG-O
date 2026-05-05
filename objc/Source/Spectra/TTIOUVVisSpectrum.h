#ifndef TTIO_UV_VIS_SPECTRUM_H
#define TTIO_UV_VIS_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOSignalArray;

/**
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIOUVVisSpectrum.h</p>
 *
 * <p>1-D UV-visible absorption spectrum: wavelength (nm) +
 * absorbance arrays plus optical-path-length (cm) and solvent
 * metadata.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.uv_vis_spectrum.UVVisSpectrum</code><br/>
 * Java: <code>global.thalion.ttio.UVVisSpectrum</code></p>
 */
@interface TTIOUVVisSpectrum : TTIOSpectrum

/** Wavelength values (nm). */
@property (readonly, strong) TTIOSignalArray *wavelengthArray;

/** Absorbance values. */
@property (readonly, strong) TTIOSignalArray *absorbanceArray;

/** Optical path length in cm. */
@property (readonly) double pathLengthCm;

/** Solvent identifier. */
@property (readonly, copy) NSString *solvent;

/**
 * Designated initialiser.
 *
 * @param wavelengths   Wavelength values (nm).
 * @param absorbance    Absorbance values; same length.
 * @param pathLengthCm  Optical path length in cm.
 * @param solvent       Solvent identifier.
 * @param indexPosition Position in parent run.
 * @param scanTime      Scan time in seconds.
 * @param error         Out-parameter populated on failure.
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
- (instancetype)initWithWavelengthArray:(TTIOSignalArray *)wavelengths
                        absorbanceArray:(TTIOSignalArray *)absorbance
                           pathLengthCm:(double)pathLengthCm
                                solvent:(NSString *)solvent
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
