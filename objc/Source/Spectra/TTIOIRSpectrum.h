#ifndef TTIO_IR_SPECTRUM_H
#define TTIO_IR_SPECTRUM_H

#import "TTIOSpectrum.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOSignalArray;

/**
 * <heading>TTIOIRSpectrum</heading>
 *
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIOIRSpectrum.h</p>
 *
 * <p>1-D mid-IR spectrum: wavenumber (cm<sup>-1</sup>) + either
 * transmittance or absorbance array, the mode enum that
 * disambiguates them, a spectral resolution in cm<sup>-1</sup>,
 * and an optional scan count (FTIR averaging).</p>
 *
 * <p>The second signal array is always named
 * <code>@"intensity"</code> in the storage layout regardless of
 * mode; the <code>mode</code> attribute tells a reader how to
 * interpret the values.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.ir_spectrum.IRSpectrum</code><br/>
 * Java: <code>global.thalion.ttio.IRSpectrum</code></p>
 */
@interface TTIOIRSpectrum : TTIOSpectrum

/** Wavenumber values (cm<sup>-1</sup>). */
@property (readonly, strong) TTIOSignalArray *wavenumberArray;

/** Transmittance or absorbance values per
 *  <code>mode</code>. */
@property (readonly, strong) TTIOSignalArray *intensityArray;

/** Whether <code>intensityArray</code> holds transmittance or
 *  absorbance. */
@property (readonly) TTIOIRMode mode;

/** Spectral resolution in cm<sup>-1</sup>. */
@property (readonly) double resolutionCmInv;

/** Number of accumulated scans (FTIR averaging); <code>0</code>
 *  for single-shot. */
@property (readonly) NSUInteger numberOfScans;

/**
 * Designated initialiser.
 *
 * @param wavenumbers      Wavenumber values.
 * @param intensity        Intensity values per <code>mode</code>.
 * @param mode             Transmittance or absorbance.
 * @param resolutionCmInv  Spectral resolution.
 * @param numberOfScans    Accumulated-scan count.
 * @param indexPosition    Position in parent run.
 * @param scanTime         Scan time in seconds.
 * @param error            Out-parameter populated on failure.
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
- (instancetype)initWithWavenumberArray:(TTIOSignalArray *)wavenumbers
                         intensityArray:(TTIOSignalArray *)intensity
                                   mode:(TTIOIRMode)mode
                        resolutionCmInv:(double)resolutionCmInv
                          numberOfScans:(NSUInteger)numberOfScans
                          indexPosition:(NSUInteger)indexPosition
                        scanTimeSeconds:(double)scanTime
                                  error:(NSError **)error;

@end

#endif
