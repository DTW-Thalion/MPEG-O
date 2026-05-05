#ifndef TTIO_TWO_D_CORRELATION_SPECTRUM_H
#define TTIO_TWO_D_CORRELATION_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOAxisDescriptor;

/**
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em>
 * Spectra/TTIOTwoDimensionalCorrelationSpectrum.h</p>
 *
 * <p>Noda 2-D correlation spectrum (2D-COS): a synchronous
 * (in-phase) and an asynchronous (quadrature) rank-2 correlation
 * matrix keyed on a single spectral-variable axis (&#957;<sub>1</sub>
 * == &#957;<sub>2</sub>). Both matrices are
 * <code>matrixSize &#215; matrixSize</code> row-major float64
 * buffers.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python:
 * <code>ttio.two_dimensional_correlation_spectrum.TwoDimensionalCorrelationSpectrum</code><br/>
 * Java:
 * <code>global.thalion.ttio.TwoDimensionalCorrelationSpectrum</code></p>
 */
@interface TTIOTwoDimensionalCorrelationSpectrum : TTIOSpectrum

/** Row-major float64 synchronous (in-phase) correlation matrix. */
@property (readonly, copy) NSData *synchronousMatrix;

/** Row-major float64 asynchronous (quadrature) correlation matrix. */
@property (readonly, copy) NSData *asynchronousMatrix;

/** <code>n</code> such that both matrices are
 *  <code>n &#215; n</code>. */
@property (readonly) NSUInteger matrixSize;

/** Shared spectral-variable axis (F<sub>1</sub> = F<sub>2</sub>). */
@property (readonly, strong) TTIOAxisDescriptor *variableAxis;

/** Perturbation identifier (e.g. <code>@"temperature"</code>). */
@property (readonly, copy) NSString *perturbation;

/** Perturbation unit string (UCUM-compatible). */
@property (readonly, copy) NSString *perturbationUnit;

/** Source modality for the underlying spectra (e.g.
 *  <code>@"raman"</code>, <code>@"ir"</code>,
 *  <code>@"uv-vis"</code>). */
@property (readonly, copy) NSString *sourceModality;

/**
 * Designated initialiser.
 *
 * @param sync             Synchronous matrix bytes.
 * @param asyn             Asynchronous matrix bytes.
 * @param size             Matrix dimension <code>n</code>.
 * @param axis             Shared spectral-variable axis.
 * @param perturbation     Perturbation identifier.
 * @param perturbationUnit Perturbation unit string.
 * @param sourceModality   Source modality identifier.
 * @param indexPosition    Position in parent run.
 * @param error            Out-parameter populated on failure.
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
- (instancetype)initWithSynchronousMatrix:(NSData *)sync
                       asynchronousMatrix:(NSData *)asyn
                               matrixSize:(NSUInteger)size
                             variableAxis:(TTIOAxisDescriptor *)axis
                             perturbation:(NSString *)perturbation
                         perturbationUnit:(NSString *)perturbationUnit
                           sourceModality:(NSString *)sourceModality
                            indexPosition:(NSUInteger)indexPosition
                                    error:(NSError **)error;

@end

#endif
