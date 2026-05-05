#ifndef TTIO_CHROMATOGRAM_H
#define TTIO_CHROMATOGRAM_H

#import "TTIOSpectrum.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOSignalArray;

/**
 * <heading>TTIOChromatogram</heading>
 *
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIOChromatogram.h</p>
 *
 * <p>Chromatogram: time-vs-intensity trace, with TIC, XIC, or SRM
 * type. For XIC the <code>targetMz</code> field is meaningful; for
 * SRM the <code>precursorProductMz</code> + <code>productMz</code>
 * fields apply (transition); both are zero for TIC.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.chromatogram.Chromatogram</code><br/>
 * Java: <code>global.thalion.ttio.Chromatogram</code></p>
 */
@interface TTIOChromatogram : TTIOSpectrum

/** Time values (typically retention time in seconds). */
@property (readonly, strong) TTIOSignalArray *timeArray;

/** Intensity values. */
@property (readonly, strong) TTIOSignalArray *intensityArray;

/** Trace type (TIC / XIC / SRM). */
@property (readonly) TTIOChromatogramType type;

/** Target m/z for XIC traces; <code>0</code> for TIC / SRM. */
@property (readonly) double targetMz;

/** Precursor m/z for SRM transitions. */
@property (readonly) double precursorProductMz;

/** Product m/z for SRM transitions. */
@property (readonly) double productMz;

/**
 * Designated initialiser.
 *
 * @param time         Time values.
 * @param intensity    Intensity values; same length.
 * @param type         Trace type.
 * @param targetMz     XIC target m/z (or <code>0</code>).
 * @param precursorMz  SRM precursor m/z (or <code>0</code>).
 * @param productMz    SRM product m/z (or <code>0</code>).
 * @param error        Out-parameter populated on failure.
 * @return An initialised chromatogram, or <code>nil</code> on
 *         failure.
 */
- (instancetype)initWithTimeArray:(TTIOSignalArray *)time
                   intensityArray:(TTIOSignalArray *)intensity
                             type:(TTIOChromatogramType)type
                         targetMz:(double)targetMz
                      precursorMz:(double)precursorMz
                        productMz:(double)productMz
                            error:(NSError **)error;

@end

#endif
