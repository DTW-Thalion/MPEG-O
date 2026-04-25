#ifndef TTIO_TWO_D_COS_H
#define TTIO_TWO_D_COS_H

#import <Foundation/Foundation.h>

@class TTIOAxisDescriptor;
@class TTIOTwoDimensionalCorrelationSpectrum;

/**
 * 2D-COS compute primitives — Noda synchronous/asynchronous
 * decomposition via the Hilbert-transform approach (M77).
 *
 * All matrices are row-major float64 buffers. The dynamic-spectra
 * input is ``(m, n)``: m perturbation points x n spectral variables.
 *
 * Cross-language equivalents:
 *   Python: ttio.analysis.two_d_cos
 *   Java:   com.dtwthalion.ttio.analysis.TwoDCos
 */
@interface TTIOTwoDCos : NSObject

/**
 * Return the Hilbert-Noda transform matrix of order ``m`` as row-major
 * float64 bytes (length = m * m * sizeof(double)). N[j, k] = 0 if
 * j==k else 1 / (pi * (k - j)). The matrix is antisymmetric.
 * Returns nil and sets error on ``m < 1``.
 */
+ (NSData *)hilbertNodaMatrixOfOrder:(NSUInteger)m
                                error:(NSError **)error;

/**
 * Compute the mean-centered 2D-COS decomposition.
 *
 * @param dynamicSpectra  row-major float64 NSData of length m*n*8.
 * @param m               perturbation points (rows).
 * @param n               spectral variables (cols).
 * @param reference       length-n float64 baseline (nil = column mean).
 * @param variableAxis    forwarded to the returned spectrum (may be nil).
 * @param perturbation    forwarded (may be nil; treated as "").
 * @param perturbationUnit forwarded (may be nil; treated as "").
 * @param sourceModality  forwarded (may be nil; treated as "").
 * @param error           out-parameter on failure.
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
 * Return |Phi|/(|Phi|+|Psi|) element-wise as row-major float64 bytes.
 * Cells where both matrices vanish return NaN. Both inputs must have
 * identical length. On length mismatch returns nil and sets error.
 */
+ (NSData *)disrelationSpectrumFromSynchronous:(NSData *)synchronous
                                   asynchronous:(NSData *)asynchronous
                                          error:(NSError **)error;

@end

#endif
