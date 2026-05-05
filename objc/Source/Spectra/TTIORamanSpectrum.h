#ifndef TTIO_RAMAN_SPECTRUM_H
#define TTIO_RAMAN_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOSignalArray;

/**
 * <heading>TTIORamanSpectrum</heading>
 *
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIORamanSpectrum.h</p>
 *
 * <p>1-D Raman spectrum: wavenumber (cm<sup>-1</sup>) + intensity
 * arrays plus excitation laser wavelength, laser power, and
 * detector integration time.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.raman_spectrum.RamanSpectrum</code><br/>
 * Java: <code>global.thalion.ttio.RamanSpectrum</code></p>
 */
@interface TTIORamanSpectrum : TTIOSpectrum

/** Wavenumber values (cm<sup>-1</sup>). */
@property (readonly, strong) TTIOSignalArray *wavenumberArray;

/** Intensity values; same length as <code>wavenumberArray</code>. */
@property (readonly, strong) TTIOSignalArray *intensityArray;

/** Excitation laser wavelength in nm. */
@property (readonly) double excitationWavelengthNm;

/** Laser power in milliwatts. */
@property (readonly) double laserPowerMw;

/** Detector integration time in seconds. */
@property (readonly) double integrationTimeSec;

/**
 * Designated initialiser.
 *
 * @param wavenumbers     Wavenumber values.
 * @param intensity       Intensity values; same length.
 * @param excitationNm    Excitation wavelength in nm.
 * @param laserPowerMw    Laser power in mW.
 * @param integrationTime Detector integration time in seconds.
 * @param indexPosition   Position in parent run.
 * @param scanTime        Scan time in seconds.
 * @param error           Out-parameter populated on failure.
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
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
