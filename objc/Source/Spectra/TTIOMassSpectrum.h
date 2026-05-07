#ifndef TTIO_MASS_SPECTRUM_H
#define TTIO_MASS_SPECTRUM_H

#import "TTIOSpectrum.h"
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOIsolationWindow.h"

@class TTIOSignalArray;

/**
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIOMassSpectrum.h</p>
 *
 * <p>A mass spectrum: m/z + intensity arrays plus MS level,
 * polarity, scan window, and optional precursor activation /
 * isolation metadata. Construction enforces equal-length m/z and
 * intensity arrays; mismatched lengths return <code>nil</code> and
 * populate <code>error</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.mass_spectrum.MassSpectrum</code><br/>
 * Java: <code>global.thalion.ttio.MassSpectrum</code></p>
 */
@interface TTIOMassSpectrum : TTIOSpectrum

/** m/z values. */
@property (readonly, strong) TTIOSignalArray *mzArray;

/** Intensity values; same length as <code>mzArray</code>. */
@property (readonly, strong) TTIOSignalArray *intensityArray;

/** MS level (<code>1</code>, <code>2</code>, <code>3</code>, ...). */
@property (readonly) NSUInteger msLevel;

/** Scan polarity. */
@property (readonly) TTIOPolarity polarity;

/** Optional scan-window m/z range; <code>nil</code> when not
 *  reported. */
@property (readonly, strong) TTIOValueRange *scanWindow;

/** Activation method for MS2+ scans;
 *  <code>TTIOActivationMethodNone</code> for MS1 or unreported. */
@property (readonly) TTIOActivationMethod activationMethod;

/** Optional isolation window for tandem MS; <code>nil</code> when
 *  not reported. */
@property (readonly, strong) TTIOIsolationWindow *isolationWindow;

/** <code>YES</code> if this spectrum is centroided (mzML
 *  MS:1000127), <code>NO</code> for profile mode (MS:1000128) or
 *  when the centroided column is absent in the source file. Set by
 *  <code>TTIOAcquisitionRun</code> at materialisation time from the
 *  parent <code>TTIOSpectrumIndex</code>; default is <code>NO</code>.
 *
 *  <p>Cross-language equivalents: Java
 *  <code>MassSpectrum.isCentroided()</code>, Python
 *  <code>MassSpectrum.is_centroided</code>.</p>
 */
@property (nonatomic) BOOL isCentroided;

/**
 * Designated initialiser.
 *
 * @param mz                m/z values.
 * @param intensity         Intensity values; must match
 *                          <code>mz.length</code>.
 * @param msLevel           MS level (1, 2, 3, ...).
 * @param polarity          Scan polarity.
 * @param scanWindow        Optional scan window; pass
 *                          <code>nil</code> when not reported.
 * @param activationMethod  Activation method for MS2+;
 *                          pass <code>TTIOActivationMethodNone</code>
 *                          for MS1.
 * @param isolationWindow   Optional isolation window.
 * @param indexPosition     Position in parent run.
 * @param scanTime          Scan time in seconds.
 * @param precursorMz       Precursor m/z; <code>0</code> for MS1.
 * @param precursorCharge   Precursor charge; <code>0</code> if
 *                          unknown.
 * @param error             Out-parameter populated on failure
 *                          (e.g. mismatched array lengths).
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
- (instancetype)initWithMzArray:(TTIOSignalArray *)mz
                 intensityArray:(TTIOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(TTIOPolarity)polarity
                     scanWindow:(TTIOValueRange *)scanWindow
               activationMethod:(TTIOActivationMethod)activationMethod
                isolationWindow:(TTIOIsolationWindow *)isolationWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error;

/**
 * Convenience initialiser without activation / isolation metadata.
 * Defaults <code>activationMethod</code> to
 * <code>TTIOActivationMethodNone</code> and
 * <code>isolationWindow</code> to <code>nil</code>.
 */
- (instancetype)initWithMzArray:(TTIOSignalArray *)mz
                 intensityArray:(TTIOSignalArray *)intensity
                        msLevel:(NSUInteger)msLevel
                       polarity:(TTIOPolarity)polarity
                     scanWindow:(TTIOValueRange *)scanWindow
                  indexPosition:(NSUInteger)indexPosition
                scanTimeSeconds:(double)scanTime
                    precursorMz:(double)precursorMz
                precursorCharge:(NSUInteger)precursorCharge
                          error:(NSError **)error;

@end

#endif
