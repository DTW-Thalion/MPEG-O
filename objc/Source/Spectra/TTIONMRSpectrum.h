#ifndef TTIO_NMR_SPECTRUM_H
#define TTIO_NMR_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOSignalArray;

/**
 * <heading>TTIONMRSpectrum</heading>
 *
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIONMRSpectrum.h</p>
 *
 * <p>1-D NMR spectrum: chemical-shift + intensity arrays plus
 * nucleus type (e.g. <code>@"1H"</code>, <code>@"13C"</code>) and
 * spectrometer frequency in MHz.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.nmr_spectrum.NMRSpectrum</code><br/>
 * Java: <code>global.thalion.ttio.NMRSpectrum</code></p>
 */
@interface TTIONMRSpectrum : TTIOSpectrum

/** Chemical-shift values (ppm). */
@property (readonly, strong) TTIOSignalArray *chemicalShiftArray;

/** Intensity values. */
@property (readonly, strong) TTIOSignalArray *intensityArray;

/** Nucleus identifier (e.g. <code>@"1H"</code>). */
@property (readonly, copy) NSString *nucleusType;

/** Spectrometer frequency in MHz. */
@property (readonly) double spectrometerFrequencyMHz;

/**
 * Designated initialiser.
 *
 * @param cs            Chemical-shift values.
 * @param intensity     Intensity values; must match
 *                      <code>cs.length</code>.
 * @param nucleus       Nucleus identifier.
 * @param freq          Spectrometer frequency in MHz.
 * @param indexPosition Position in parent run.
 * @param scanTime      Scan time in seconds.
 * @param error         Out-parameter populated on failure.
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
- (instancetype)initWithChemicalShiftArray:(TTIOSignalArray *)cs
                            intensityArray:(TTIOSignalArray *)intensity
                               nucleusType:(NSString *)nucleus
                  spectrometerFrequencyMHz:(double)freq
                             indexPosition:(NSUInteger)indexPosition
                           scanTimeSeconds:(double)scanTime
                                     error:(NSError **)error;

@end

#endif
