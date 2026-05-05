#ifndef TTIO_TWO_D_COS_H
#define TTIO_TWO_D_COS_H

#import <Foundation/Foundation.h>

@class TTIOAxisDescriptor;
@class TTIOTwoDimensionalCorrelationSpectrum;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Analysis/TTIOTwoDCos.h</p>
 *
 * <p>Two-dimensional correlation spectroscopy (2D-COS) compute
 * primitives. Implements Noda synchronous / asynchronous
 * decomposition via the Hilbert-transform approach.</p>
 *
 * <p>All matrices are row-major float64 buffers. The dynamic-spectra
 * input is <code>(m, n)</code>: <em>m</em> perturbation points by
 * <em>n</em> spectral variables.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.analysis.two_d_cos</code><br/>
 * Java: <code>global.thalion.ttio.analysis.TwoDCos</code></p>
 */
@interface TTIOTwoDCos : NSObject

/**
 * Returns the Hilbert-Noda transform matrix of order <code>m</code>
 * as row-major float64 bytes
 * (length = <code>m * m * sizeof(double)</code>).
 * <code>N[j, k] = 0</code> if <code>j == k</code>, else
 * <code>1 / (pi * (k - j))</code>. The matrix is antisymmetric.
 *
 * @param m     Matrix order.
 * @param error Out-parameter populated when <code>m &lt; 1</code>.
 * @return The matrix bytes, or <code>nil</code> on invalid input.
 */
+ (NSData *)hilbertNodaMatrixOfOrder:(NSUInteger)m
                                error:(NSError **)error;

/**
 * Computes the mean-centred 2D-COS decomposition.
 *
 * @param dynamicSpectra   Row-major float64 <code>NSData</code> of
 *                         length <code>m * n * 8</code>.
 * @param m                Perturbation points (rows).
 * @param n                Spectral variables (cols).
 * @param reference        Length-<em>n</em> float64 baseline
 *                         (<code>nil</code> = column mean).
 * @param variableAxis     Forwarded to the returned spectrum (may
 *                         be <code>nil</code>).
 * @param perturbation     Forwarded (may be <code>nil</code>;
 *                         treated as <code>@""</code>).
 * @param perturbationUnit Forwarded (may be <code>nil</code>).
 * @param sourceModality   Forwarded (may be <code>nil</code>).
 * @param error            Out-parameter populated on failure.
 * @return The decomposed correlation spectrum, or <code>nil</code>
 *         on failure.
 */
+ (TTIOTwoDimensionalCorrelationSpectrum *)computeWithDynamicSpectra:(NSData *)dynamicSpectra
                                                    perturbationPoints:(NSUInteger)m
                                                     spectralVariables:(NSUInteger)n
                                                             reference:(NSData *)reference
                                                          variableAxis:(TTIOAxisDescriptor *)variableAxis
                                                          perturbation:(NSString *)perturbation
                                                      perturbationUnit:(NSString *)perturbationUnit
                                                        sourceModality:(NSString *)sourceModality
                                                                 error:(NSError **)error;

/**
 * Returns <code>|Phi| / (|Phi| + |Psi|)</code> element-wise as
 * row-major float64 bytes. Cells where both matrices vanish return
 * NaN. Both inputs must have identical length.
 *
 * @param synchronous  Synchronous correlation matrix bytes.
 * @param asynchronous Asynchronous correlation matrix bytes.
 * @param error        Out-parameter populated on length mismatch.
 * @return The disrelation matrix bytes, or <code>nil</code> on
 *         failure.
 */
+ (NSData *)disrelationSpectrumFromSynchronous:(NSData *)synchronous
                                   asynchronous:(NSData *)asynchronous
                                          error:(NSError **)error;

@end

#endif
